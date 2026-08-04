/*-------------------------------------------------------------------------
 *
 * pgcolumnar_index.c
 *		Index maintenance for callers that insert rows without an executor.
 *
 * PostgreSQL puts index maintenance in the executor, not in the table access
 * method: ExecInsertIndexTuples is what puts an entry in each index, and
 * table_tuple_insert only writes the row. Anything that inserts rows by calling
 * table_tuple_insert directly therefore has to maintain the indexes itself, or
 * the indexes silently stop describing the table and an index scan returns rows
 * that are not there and misses rows that are.
 *
 * Two callers are in that position: the online rewrite in pgcolumnar_vacuum.c,
 * which moves live rows into fresh groups, and the Arrow and Parquet importers,
 * which load rows from a file. The importers did not maintain indexes at all
 * (issue #153): an index scan over an imported table returned nothing, and a
 * unique index accepted the same key twice.
 *
 * The difference between the two callers is whether constraints are enforced,
 * and it is large enough that they take different routes rather than sharing
 * one with a flag.
 *
 * An import inserts genuinely new rows, so it enforces constraints, and it does
 * that by using the executor's own index maintenance: a real EState and
 * ResultRelInfo, ExecOpenIndices, ExecInsertIndexTuples and
 * ExecARInsertTriggers, inside an after-trigger query level of its own.
 *
 * That is not a stylistic preference. This file used to re-implement what the
 * executor does -- which indexes are ready, whether a partial index covers the
 * row, unique checking, exclusion constraints -- and every one of those is a
 * place the copy can drift from core as core changes. Issues #153 and #167 were
 * both that drift found late. Deferrable constraints (#168) were a third: the
 * hand-rolled path enforced them at insert time where the executor defers them
 * to commit, so an import that transiently collided with a row the same
 * transaction removed failed where an ordinary INSERT succeeded.
 *
 * Going through the executor fixes all three by not owning them.
 * ExecInsertIndexTuples picks UNIQUE_CHECK_PARTIAL for a non-immediate index by
 * itself and ExecARInsertTriggers queues the recheck, so deferral is core's
 * behaviour rather than ours to reproduce.
 *
 * Two preconditions are easy to miss and both abort on an assert build rather
 * than misbehave quietly, which is how they were found:
 *
 *   slot->tts_tableOid   ExecInsertIndexTuples asserts the slot names its
 *                        relation; MakeSingleTupleTableSlot does not set it
 *   the relation's lock  a queued after-trigger event is fired at commit by
 *                        ExecGetTriggerResultRel, which reopens the relation
 *                        with NoLock on the assumption the queuing statement
 *                        still holds one -- so the importers close with NoLock
 *
 * A rewrite is the other case: it moves rows that already satisfied every
 * constraint, and the row it is replacing is still visible while it does, so a
 * conflict check there would find the row against itself. It must enforce
 * nothing, and ExecInsertIndexTuples has no mode for that, so it keeps the
 * hand-rolled loop -- index_insert with UNIQUE_CHECK_NO, honouring partial
 * index predicates. That path stays deliberately, not by omission.
 *
 * Written fresh for pgColumnar from the public PostgreSQL index API.
 *
 *-------------------------------------------------------------------------
 */
#include "columnar.h"

#include "access/genam.h"
#include "access/table.h"
#include "catalog/index.h"
#include "executor/executor.h"
#include "nodes/execnodes.h"
#include "utils/rel.h"
#include "commands/trigger.h"
#include "nodes/parsenodes.h"

/*
 * PgColumnarIndexInsertBegin
 *		Prepare to maintain the relation's indexes for a run of inserted rows.
 *
 * enforceConstraints selects the route: an importer gets the executor's index
 * maintenance and an after-trigger query level, a rewrite gets the hand-rolled
 * loop that checks nothing. The caller must hold a lock on rel that permits
 * insertion, and -- when enforcing -- must keep holding it until commit, since
 * a deferred constraint queued here is fired after the caller has returned.
 */
PgColumnarIndexInsertState *
PgColumnarIndexInsertBegin(Relation rel, bool enforceConstraints)
{
	PgColumnarIndexInsertState *st = palloc0(sizeof(PgColumnarIndexInsertState));
	List	   *oids;
	int			cap;
	ListCell   *lc;

	st->enforcing = enforceConstraints;
	st->estate = CreateExecutorState();
	st->slot = MakeSingleTupleTableSlot(RelationGetDescr(rel), &TTSOpsVirtual);

	if (st->enforcing)
	{
		RangeTblEntry *rte = makeNode(RangeTblEntry);
		COLUMNAR_RTE_PERMINFO_DECL(perm);

		/*
		 * The executor resolves a result relation through the range table, so
		 * it needs one even though there is no query here. No permissions are
		 * requested: the importer has already checked its caller's.
		 */
		rte->rtekind = RTE_RELATION;
		rte->relid = RelationGetRelid(rel);
		rte->relkind = rel->rd_rel->relkind;
		rte->rellockmode = RowExclusiveLock;
		COLUMNAR_RTE_PERMINFO_INIT(rte, perm, RelationGetRelid(rel));
		COLUMNAR_EXEC_INIT_RANGE_TABLE(st->estate, rte, perm);

		st->rri = makeNode(ResultRelInfo);
		InitResultRelInfo(st->rri, rel, 1, NULL, 0);
		ExecOpenIndices(st->rri, false);
		st->estate->es_opened_result_relations =
			lappend(st->estate->es_opened_result_relations, st->rri);

		/*
		 * The load gets an after-trigger query level of its own. Without one
		 * there is no level for a deferred constraint's recheck to be queued
		 * against, which is what made this path enforce deferrable constraints
		 * immediately (#168).
		 */
		AfterTriggerBeginQuery();
		st->queryLevel = true;

		return st;
	}

	oids = RelationGetIndexList(rel);
	cap = Max(list_length(oids), 1);
	st->n = 0;
	st->rels = palloc(cap * sizeof(Relation));
	st->infos = palloc(cap * sizeof(IndexInfo *));
	st->predicates = palloc(cap * sizeof(ExprState *));

	foreach(lc, oids)
	{
		Oid			ioid = lfirst_oid(lc);
		Relation	irel = index_open(ioid, RowExclusiveLock);
		IndexInfo  *info;

		/*
		 * indisready alone, which is the test the executor applies:
		 * BuildIndexInfo passes indisready as ii_ReadyForInserts and
		 * ExecInsertIndexTuples skips on that, never consulting indisvalid.
		 *
		 * The difference is the whole point of indisready. CREATE INDEX
		 * CONCURRENTLY sets it before its second scan precisely so that
		 * concurrent writers maintain the index while the build runs -- the
		 * builder is not responsible for rows written after it started, so
		 * skipping an indisready index loses them rather than avoiding a
		 * double insert.
		 *
		 * Not reachable through CREATE INDEX CONCURRENTLY today, because
		 * pgcolumnar_index_validate_scan is unsupported and the build fails
		 * before the index becomes valid. It is reachable as debris: a failed
		 * concurrent build leaves the index ready but invalid until someone
		 * drops or reindexes it, and in that state an ordinary INSERT
		 * maintains it while this path would not.
		 */
		if (!irel->rd_index->indisready)
		{
			index_close(irel, RowExclusiveLock);
			continue;
		}
		info = BuildIndexInfo(irel);
		st->rels[st->n] = irel;
		st->infos[st->n] = info;
		st->predicates[st->n] = (info->ii_Predicate != NIL)
			? ExecPrepareQual(info->ii_Predicate, st->estate)
			: NULL;
		st->n++;
	}

	return st;
}

/*
 * PgColumnarIndexInsertRow
 *		Put one row into every open index, under the row number's synthetic item
 *		pointer.
 */
void
PgColumnarIndexInsertRow(PgColumnarIndexInsertState *st, Relation rel,
					   Datum *values, bool *isnull, uint64 rowNumber)
{
	int			natts = RelationGetDescr(rel)->natts;
	ExprContext *econtext = GetPerTupleExprContext(st->estate);
	ItemPointerData tid;
	int			i;

	if (!st->enforcing && st->n == 0)
		return;

	PgColumnarRowNumberToItemPointer(rowNumber, &tid);

	ExecClearTuple(st->slot);
	memcpy(st->slot->tts_values, values, natts * sizeof(Datum));
	memcpy(st->slot->tts_isnull, isnull, natts * sizeof(bool));
	ExecStoreVirtualTuple(st->slot);
	st->slot->tts_tid = tid;
	econtext->ecxt_scantuple = st->slot;

	if (st->enforcing)
	{
		List	   *recheck;

		/*
		 * ExecInsertIndexTuples asserts the slot names its own relation, and
		 * MakeSingleTupleTableSlot leaves tts_tableOid invalid. On a non-assert
		 * build the mismatch is silent rather than absent.
		 */
		st->slot->tts_tableOid = RelationGetRelid(rel);

		recheck = COLUMNAR_EXEC_INSERT_INDEX_TUPLES(st->rri, st->slot, st->estate);

		/*
		 * A non-immediate index comes back in recheck rather than having been
		 * checked; this is what turns it into a constraint event fired at
		 * commit. It is also what makes an exclusion constraint and a partial
		 * index correct here without this file knowing about either.
		 */
		ExecARInsertTriggers(st->estate, st->rri, st->slot, recheck, NULL);
		list_free(recheck);
		ResetPerTupleExprContext(st->estate);
		return;
	}

	for (i = 0; i < st->n; i++)
	{
		Datum		ivalues[INDEX_MAX_KEYS];
		bool		inulls[INDEX_MAX_KEYS];

		/* skip rows a partial index does not cover */
		if (st->predicates[i] != NULL && !ExecQual(st->predicates[i], econtext))
			continue;

		FormIndexDatum(st->infos[i], st->slot, st->estate, ivalues, inulls);
		index_insert(st->rels[i], ivalues, inulls, &tid, rel,
					 UNIQUE_CHECK_NO, false, st->infos[i]);

	}
	ResetPerTupleExprContext(st->estate);
}

/*
 * PgColumnarIndexInsertEnd
 *		Close the indexes and free the state. The locks are held until the end of
 *		the transaction, as index_close with RowExclusiveLock leaves them.
 */
void
PgColumnarIndexInsertEnd(PgColumnarIndexInsertState *st)
{
	int			i;

	/*
	 * Close the query level before anything it might reach is freed. Deferred
	 * events survive this: they fire at commit against state the trigger
	 * machinery builds for itself, which is why the importers must leave the
	 * relation locked.
	 */
	if (st->queryLevel)
	{
		AfterTriggerEndQuery(st->estate);
		st->queryLevel = false;
	}
	if (st->rri != NULL)
		ExecCloseIndices(st->rri);

	for (i = 0; i < st->n; i++)
		index_close(st->rels[i], RowExclusiveLock);

	if (st->slot != NULL)
		ExecDropSingleTupleTableSlot(st->slot);
	if (st->estate != NULL)
		FreeExecutorState(st->estate);
}

/*
 * PgColumnarRelationHasIndexes
 *		Does this relation have any index at all? Used by the importers to skip
 *		the machinery entirely on the common bulk-load-into-a-bare-table case.
 */
bool
PgColumnarRelationHasIndexes(Relation rel)
{
	return RelationGetIndexList(rel) != NIL;
}
