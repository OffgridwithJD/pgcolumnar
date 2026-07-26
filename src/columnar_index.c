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
 * The difference between the two callers is uniqueness. A rewrite moves rows
 * that already satisfied every constraint, and the row it is replacing is still
 * visible while it does, so checking uniqueness there would conflict with the
 * row being replaced; it passes UNIQUE_CHECK_NO. An import inserts genuinely new
 * rows, so a duplicate has to be caught, and it passes UNIQUE_CHECK_YES for the
 * unique indexes. That is the only behavioural difference, and it is a
 * parameter rather than a second implementation.
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
		 * An index that is not ready or not valid is one a concurrent build has
		 * not finished with. That build is responsible for the rows it covers,
		 * so inserting into it here would double-insert.
		 */
		if (!irel->rd_index->indisready || !irel->rd_index->indisvalid)
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
