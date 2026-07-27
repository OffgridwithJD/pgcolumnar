/*-------------------------------------------------------------------------
 *
 * columnar_index.c
 *		Index maintenance for callers that insert rows without an executor.
 *
 * PostgreSQL puts index maintenance in the executor, not in the table access
 * method: ExecInsertIndexTuples is what puts an entry in each index, and
 * table_tuple_insert only writes the row. Anything that inserts rows by calling
 * table_tuple_insert directly therefore has to maintain the indexes itself, or
 * the indexes silently stop describing the table and an index scan returns rows
 * that are not there and misses rows that are.
 *
 * Two callers are in that position: the online rewrite in columnar_vacuum.c,
 * which moves live rows into fresh groups, and the Arrow and Parquet importers,
 * which load rows from a file. The importers did not maintain indexes at all
 * (issue #153): an index scan over an imported table returned nothing, and a
 * unique index accepted the same key twice.
 *
 * The difference between the two callers is whether constraints are enforced. A
 * rewrite moves rows that already satisfied every constraint, and the row it is
 * replacing is still visible while it does, so a conflict check there would find
 * the row against itself; it enforces nothing. An import inserts genuinely new
 * rows, so it enforces both kinds:
 *
 *   unique indexes     UNIQUE_CHECK_YES, which index_insert applies itself
 *   exclusion          check_exclusion_constraint after the entry goes in,
 *                      because index_insert does not enforce one
 *
 * The second was missing when this file was first written, so an import could
 * leave a table in a state an ordinary INSERT would have refused. That is a
 * parameter rather than a second implementation.
 *
 * A deferrable unique constraint is still enforced immediately here, where the
 * executor would defer it to commit. Tracked as issue #168, which carries the
 * measurement and the UNIQUE_CHECK_PARTIAL plus queued-recheck sketch; enforcing
 * early is over-strict rather than unsound, which is the safe direction to be
 * wrong in while it is open.
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

/*
 * ColumnarIndexInsertBegin
 *		Open every ready and valid index on the relation and prepare the state
 *		needed to form index tuples. The caller must hold a lock on rel that
 *		permits insertion; the indexes are opened with RowExclusiveLock, which is
 *		what an ordinary insert takes.
 */
ColumnarIndexInsertState *
ColumnarIndexInsertBegin(Relation rel)
{
	ColumnarIndexInsertState *st = palloc0(sizeof(ColumnarIndexInsertState));
	List	   *oids = RelationGetIndexList(rel);
	int			cap = Max(list_length(oids), 1);
	ListCell   *lc;

	st->n = 0;
	st->rels = palloc(cap * sizeof(Relation));
	st->infos = palloc(cap * sizeof(IndexInfo *));
	st->predicates = palloc(cap * sizeof(ExprState *));
	st->estate = CreateExecutorState();
	st->slot = MakeSingleTupleTableSlot(RelationGetDescr(rel), &TTSOpsVirtual);

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
		 * columnar_index_validate_scan is unsupported and the build fails
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
 * ColumnarIndexInsertRow
 *		Put one row into every open index, under the row number's synthetic item
 *		pointer. enforceUnique decides whether a unique index checks for a
 *		conflict: an importer wants that, a rewrite of rows that already exist
 *		does not.
 */
void
ColumnarIndexInsertRow(ColumnarIndexInsertState *st, Relation rel,
					   Datum *values, bool *isnull, uint64 rowNumber,
					   bool enforceUnique)
{
	int			natts = RelationGetDescr(rel)->natts;
	ExprContext *econtext = GetPerTupleExprContext(st->estate);
	ItemPointerData tid;
	int			i;

	if (st->n == 0)
		return;

	ColumnarRowNumberToItemPointer(rowNumber, &tid);

	ExecClearTuple(st->slot);
	memcpy(st->slot->tts_values, values, natts * sizeof(Datum));
	memcpy(st->slot->tts_isnull, isnull, natts * sizeof(bool));
	ExecStoreVirtualTuple(st->slot);
	econtext->ecxt_scantuple = st->slot;

	for (i = 0; i < st->n; i++)
	{
		Datum		ivalues[INDEX_MAX_KEYS];
		bool		inulls[INDEX_MAX_KEYS];
		IndexUniqueCheck check = UNIQUE_CHECK_NO;

		/* skip rows a partial index does not cover */
		if (st->predicates[i] != NULL && !ExecQual(st->predicates[i], econtext))
			continue;

		if (enforceUnique && st->rels[i]->rd_index->indisunique)
			check = UNIQUE_CHECK_YES;

		FormIndexDatum(st->infos[i], st->slot, st->estate, ivalues, inulls);
		index_insert(st->rels[i], ivalues, inulls, &tid, rel,
					 check, false, st->infos[i]);

		/*
		 * An exclusion constraint is not a unique index and index_insert does
		 * not enforce it: the executor inserts the entry and then scans for a
		 * conflicting one. Without this an import could put a table into a
		 * state an ordinary INSERT would have refused -- entries present, the
		 * constraint violated, and nothing raised, which is the shape of the
		 * defect #153 was about.
		 *
		 * Only when the caller is enforcing constraints at all. A rewrite moves
		 * rows that already satisfied this one, and the row it replaces is
		 * still visible, so checking there would find the row against itself.
		 */
		if (enforceUnique && st->infos[i]->ii_ExclusionOps != NULL)
			check_exclusion_constraint(rel, st->rels[i], st->infos[i], &tid,
									   ivalues, inulls, st->estate, false);
	}
	ResetPerTupleExprContext(st->estate);
}

/*
 * ColumnarIndexInsertEnd
 *		Close the indexes and free the state. The locks are held until the end of
 *		the transaction, as index_close with RowExclusiveLock leaves them.
 */
void
ColumnarIndexInsertEnd(ColumnarIndexInsertState *st)
{
	int			i;

	for (i = 0; i < st->n; i++)
		index_close(st->rels[i], RowExclusiveLock);

	if (st->slot != NULL)
		ExecDropSingleTupleTableSlot(st->slot);
	if (st->estate != NULL)
		FreeExecutorState(st->estate);
}

/*
 * ColumnarRelationHasIndexes
 *		Does this relation have any index at all? Used by the importers to skip
 *		the machinery entirely on the common bulk-load-into-a-bare-table case.
 */
bool
ColumnarRelationHasIndexes(Relation rel)
{
	return RelationGetIndexList(rel) != NIL;
}
