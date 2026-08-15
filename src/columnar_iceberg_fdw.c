/*-------------------------------------------------------------------------
 * columnar_iceberg_fdw.c
 *		A read-only foreign-data wrapper over an Apache Iceberg table (#388).
 *
 * iceberg_scan() is a bare set-returning function: no query predicate reaches
 * it, so it cannot prune. This FDW gives Iceberg a predicate-bearing scan node.
 * Its first job is IDENTITY-PARTITION PRUNING: a qual on an identity-partitioned
 * column removes whole data files -- whose partition value is read from the
 * manifest, already decoded and typed -- before they are opened. Everything
 * downstream (field-id projection, all delete kinds, name mapping, vended creds)
 * is the shared read path (PgColumnarIcebergScanCore); this file only captures
 * quals and filters the file list. Pruning is only ever an optimization: a file
 * that is not pruned is read normally, so a qual this FDW cannot decide never
 * changes the rows returned.
 *
 * See design/ISSUE_388_PRUNING.md. Non-identity transforms and data-file
 * min/max metrics pruning are later increments; until then such files are read.
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <sys/stat.h>

#include "access/reloptions.h"
#include "catalog/pg_authid_d.h"
#include "catalog/pg_foreign_table.h"
#include "catalog/pg_type_d.h"
#include "commands/defrem.h"
#if PG_VERSION_NUM >= 180000
#include "commands/explain_format.h"
#include "commands/explain_state.h"
#else
#include "commands/explain.h"
#endif
#include "fmgr.h"
#include "foreign/fdwapi.h"
#include "foreign/foreign.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "optimizer/optimizer.h"
#include "optimizer/pathnode.h"
#include "optimizer/planmain.h"
#include "optimizer/restrictinfo.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/rel.h"
#include "utils/tuplestore.h"

#include "columnar_avro.h"
#include "columnar_compat.h"
#include "columnar_iceberg.h"

typedef struct IceFdwState
{
	char	   *metadata_path;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	TupleTableSlot *readslot;	/* minimal-tuple slot to drain the tuplestore */
	bool		started;		/* the read+prune pass has run */

	/* pruning, compiled once in Begin */
	ForeignScanState *node;
	int		   *partAttno;		/* per partition-tuple position -> attno, or 0 */
	int			npart;
	int32		specid;			/* current spec; a file with another spec is read */
	List	   *partQuals;		/* compiled quals over identity-partition columns */
	TupleTableSlot *partSlot;
	int64		filesPruned;
}			IceFdwState;

/* a named option of a foreign table, or NULL */
static char *
ice_fdw_get_option(Oid foreigntableid, const char *name)
{
	ForeignTable *ft = GetForeignTable(foreigntableid);
	ListCell   *lc;

	foreach(lc, ft->options)
	{
		DefElem    *def = (DefElem *) lfirst(lc);

		if (strcmp(def->defname, name) == 0)
			return defGetString(def);
	}
	return NULL;
}

/* ------------------------------------------------------------------ planner */

static void
icefdwGetForeignRelSize(PlannerInfo *root, RelOptInfo *baserel,
						Oid foreigntableid)
{
	baserel->rows = 1000.0;		/* a planning ballpark; the scan reads real rows */
}

static void
icefdwGetForeignPaths(PlannerInfo *root, RelOptInfo *baserel,
					  Oid foreigntableid)
{
	add_path(baserel, (Path *)
			 COLUMNAR_CREATE_FOREIGNSCAN_PATH(root, baserel,
											  NULL, baserel->rows,
											  0, baserel->rows,
											  NIL, NULL, NULL, NIL));
}

static ForeignScan *
icefdwGetForeignPlan(PlannerInfo *root, RelOptInfo *baserel,
					 Oid foreigntableid, ForeignPath *best_path,
					 List *tlist, List *scan_clauses, Plan *outer_plan)
{
	/*
	 * Clause evaluation stays with the executor: pruning here only drops whole
	 * files a partition value cannot match, so every clause is still recheckable
	 * and must remain in the plan qual.
	 */
	scan_clauses = extract_actual_clauses(scan_clauses, false);
	return make_foreignscan(tlist, scan_clauses, baserel->relid,
							NIL, NIL, NIL, NIL, outer_plan);
}

/* ------------------------------------------------------------------- pruning */

/*
 * Compile the scan quals that reference ONLY identity-partition columns and hold
 * no volatile function -- the ones a file's partition value alone can decide.
 */
static List *
ice_fdw_partition_quals(ForeignScanState *node, TupleDesc tupdesc,
						const bool *partMask)
{
	ForeignScan *fs = (ForeignScan *) node->ss.ps.plan;
	List	   *compiled = NIL;
	ListCell   *lc;

	foreach(lc, fs->scan.plan.qual)
	{
		Node	   *clause = (Node *) lfirst(lc);
		Bitmapset  *attrs = NULL;
		bool		partitionOnly = true;
		int			x = -1;

		pull_varattnos(clause, fs->scan.scanrelid, &attrs);
		if (bms_is_empty(attrs))
			continue;
		while ((x = bms_next_member(attrs, x)) >= 0)
		{
			int			attno = x + FirstLowInvalidHeapAttributeNumber;

			if (attno < 1 || attno > tupdesc->natts || !partMask[attno - 1])
			{
				partitionOnly = false;
				break;
			}
		}
		if (!partitionOnly)
			continue;
		if (contain_volatile_functions(clause))
			continue;
		compiled = lappend(compiled, ExecInitQual(list_make1(clause),
												  (PlanState *) node));
	}
	return compiled;
}

/* Is `typid` an identity-partition column type this increment can prune on? Only
 * these are put in the partition mask, so a qual over, say, a date-partitioned
 * column is never compiled and its files are read in full (sound). */
static bool
ice_fdw_type_supported(Oid typid)
{
	switch (typid)
	{
		case TEXTOID:
		case VARCHAROID:
		case INT2OID:
		case INT4OID:
		case INT8OID:
		case BOOLOID:
			return true;
		default:
			return false;
	}
}

/* Convert one already-transformed partition cell to a Datum of `typid`, for the
 * identity types this increment prunes. Sets *ok=false for a cell it cannot
 * convert (a type mismatch or an incomparable value); the caller must then treat
 * the file as UNDECIDABLE and not prune it -- a present-but-unconverted value is
 * unknown, NOT null, so a qual on it must never drop the file. */
static Datum
ice_fdw_cell_datum(const PgColumnarAvroPartCell *c, Oid typid, bool *ok)
{
	*ok = true;
	if (!c->comparable)
	{
		*ok = false;
		return (Datum) 0;
	}
	switch (typid)
	{
		case TEXTOID:
		case VARCHAROID:
			if (!c->is_bytes)
				break;
			return PointerGetDatum(cstring_to_text_with_len(c->bytes, c->blen));
		case INT2OID:
			if (c->is_bytes)
				break;
			return Int16GetDatum((int16) c->ival);
		case INT4OID:
			if (c->is_bytes)
				break;
			return Int32GetDatum((int32) c->ival);
		case INT8OID:
			if (c->is_bytes)
				break;
			return Int64GetDatum(c->ival);
		case BOOLOID:
			if (c->is_bytes)
				break;
			return BoolGetDatum(c->ival != 0);
		default:
			break;
	}
	*ok = false;
	return (Datum) 0;
}

/*
 * The per-file filter passed to PgColumnarIcebergScanCore: return true to prune
 * (skip) a data file whose identity-partition values make every candidate qual
 * false. A file written under a different partition spec than the current one,
 * or with an incomparable/unsupported partition cell, is never pruned.
 */
static bool
ice_fdw_file_excludes(void *arg, const PgColumnarAvroPartCell *cells,
					  int ncells, int32 spec_id)
{
	IceFdwState *st = (IceFdwState *) arg;
	ExprContext *econtext = st->node->ss.ps.ps_ExprContext;
	TupleDesc	tupdesc = st->tupdesc;
	ListCell   *lc;
	int			i;
	int			k;

	if (st->partQuals == NIL || spec_id != st->specid || ncells != st->npart)
		return false;

	ExecClearTuple(st->partSlot);
	for (i = 0; i < tupdesc->natts; i++)
	{
		st->partSlot->tts_values[i] = (Datum) 0;
		st->partSlot->tts_isnull[i] = true;
	}
	for (k = 0; k < st->npart; k++)
	{
		int			a = st->partAttno[k];
		Oid			typid;
		bool		ok;
		Datum		d;

		if (a <= 0 || a > tupdesc->natts)
			continue;
		if (cells[k].isnull)
		{
			st->partSlot->tts_isnull[a - 1] = true;	/* a real NULL: prunable */
			continue;
		}
		typid = TupleDescAttr(tupdesc, a - 1)->atttypid;
		d = ice_fdw_cell_datum(&cells[k], typid, &ok);
		if (!ok)
		{
			/*
			 * A present value we cannot convert (a type mismatch or an
			 * incomparable cell) is UNKNOWN, not null. Leaving it null would let
			 * a qual like "col = X" evaluate NULL -> false and prune a file that
			 * may well match: dropped rows. So do not prune this file at all --
			 * it is read and its rows are re-filtered by the recheckable qual.
			 * (The compile-time type filter already keeps unsupported-type
			 * columns out of the mask; this covers a per-file mismatch.)
			 */
			return false;
		}
		st->partSlot->tts_values[a - 1] = d;
		st->partSlot->tts_isnull[a - 1] = false;
	}
	ExecStoreVirtualTuple(st->partSlot);

	econtext->ecxt_scantuple = st->partSlot;
	foreach(lc, st->partQuals)
	{
		if (!ExecQual((ExprState *) lfirst(lc), econtext))
			return true;		/* this file's partition value excludes a qual */
	}
	return false;
}

/* --------------------------------------------------------------- executor */

static void
icefdwBeginForeignScan(ForeignScanState *node, int eflags)
{
	Relation	rel = node->ss.ss_currentRelation;
	TupleDesc	tupdesc = RelationGetDescr(rel);
	IceFdwState *st;
	bool	   *partMask;
	int			k;
	bool		any;

	if (eflags & EXEC_FLAG_EXPLAIN_ONLY)
		return;

	if (!has_privs_of_role(GetUserId(), ROLE_PG_READ_SERVER_FILES))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser or a member of the pg_read_server_files role to read an Iceberg table")));

	st = (IceFdwState *) palloc0(sizeof(IceFdwState));
	st->node = node;
	st->tupdesc = tupdesc;
	st->metadata_path = ice_fdw_get_option(RelationGetRelid(rel), "metadata_path");
	if (st->metadata_path == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_FDW_OPTION_NAME_NOT_FOUND),
				 errmsg("foreign table \"%s\" has no \"metadata_path\" option",
						RelationGetRelationName(rel))));

	/* the identity-partition -> column map, and the current spec id */
	PgColumnarIcebergIdentityPartMap(st->metadata_path, NULL, tupdesc,
									 &st->partAttno, &st->npart, &st->specid);

	partMask = (bool *) palloc0(sizeof(bool) * tupdesc->natts);
	any = false;
	for (k = 0; k < st->npart; k++)
	{
		int			a = st->partAttno[k];

		/*
		 * Only mask a column whose type this increment can convert a partition
		 * cell to. A column of an unsupported type (date, timestamp, numeric,
		 * uuid, ...) is left unmasked, so no qual over it is compiled and its
		 * files are read in full -- correct, if not yet optimized. This is the
		 * compile-time half of the "never over-prune" guarantee; the filter
		 * covers a per-file mismatch of a supported-type column at read time.
		 */
		if (a >= 1 && a <= tupdesc->natts &&
			ice_fdw_type_supported(TupleDescAttr(tupdesc, a - 1)->atttypid))
		{
			partMask[a - 1] = true;
			any = true;
		}
	}
	if (any)
	{
		st->partQuals = ice_fdw_partition_quals(node, tupdesc, partMask);
		st->partSlot = MakeSingleTupleTableSlot(tupdesc, &TTSOpsVirtual);
	}

	st->tupstore = tuplestore_begin_heap(false, false, work_mem);
	st->readslot = MakeSingleTupleTableSlot(tupdesc, &TTSOpsMinimalTuple);
	st->started = false;
	node->fdw_state = st;
}

static TupleTableSlot *
icefdwIterateForeignScan(ForeignScanState *node)
{
	IceFdwState *st = (IceFdwState *) node->fdw_state;
	TupleTableSlot *slot = node->ss.ss_ScanTupleSlot;
	MemoryContext oldcxt;
	bool		got;

	if (st == NULL)
		return ExecClearTuple(slot);

	if (!st->started)
	{
		/* read the surviving files (pruned by the filter) into the tuplestore */
		st->filesPruned = PgColumnarIcebergScanCore(st->metadata_path, st->tupdesc,
													NULL, st->tupstore,
													st->partQuals != NIL ?
													ice_fdw_file_excludes : NULL,
													st);
		st->started = true;
	}

	/*
	 * Drain into the minimal-tuple readslot in a context that outlives the row
	 * (ExecScan resets the per-tuple context before every fetch), then copy into
	 * the scan slot, which for a foreign table is a heap-tuple slot.
	 */
	oldcxt = MemoryContextSwitchTo(node->ss.ps.state->es_query_cxt);
	got = tuplestore_gettupleslot(st->tupstore, true, false, st->readslot);
	MemoryContextSwitchTo(oldcxt);
	if (!got)
		return ExecClearTuple(slot);
	return ExecCopySlot(slot, st->readslot);
}

static void
icefdwReScanForeignScan(ForeignScanState *node)
{
	IceFdwState *st = (IceFdwState *) node->fdw_state;

	if (st == NULL)
		return;
	tuplestore_clear(st->tupstore);
	st->started = false;
	st->filesPruned = 0;
}

static void
icefdwEndForeignScan(ForeignScanState *node)
{
	IceFdwState *st = (IceFdwState *) node->fdw_state;

	if (st == NULL)
		return;
	if (st->tupstore != NULL)
		tuplestore_end(st->tupstore);
	if (st->readslot != NULL)
		ExecDropSingleTupleTableSlot(st->readslot);
	if (st->partSlot != NULL)
		ExecDropSingleTupleTableSlot(st->partSlot);
}

static void
icefdwExplainForeignScan(ForeignScanState *node, ExplainState *es)
{
	IceFdwState *st = (IceFdwState *) node->fdw_state;

	if (st == NULL)
		return;
	ExplainPropertyInteger("Files Pruned", NULL, st->filesPruned, es);
}

/* -------------------------------------------------------------------- SQL */

PG_FUNCTION_INFO_V1(pgcolumnar_iceberg_fdw_handler);

Datum
pgcolumnar_iceberg_fdw_handler(PG_FUNCTION_ARGS)
{
	FdwRoutine *r = makeNode(FdwRoutine);

	r->GetForeignRelSize = icefdwGetForeignRelSize;
	r->GetForeignPaths = icefdwGetForeignPaths;
	r->GetForeignPlan = icefdwGetForeignPlan;
	r->BeginForeignScan = icefdwBeginForeignScan;
	r->IterateForeignScan = icefdwIterateForeignScan;
	r->ReScanForeignScan = icefdwReScanForeignScan;
	r->ExplainForeignScan = icefdwExplainForeignScan;
	r->EndForeignScan = icefdwEndForeignScan;
	PG_RETURN_POINTER(r);
}

PG_FUNCTION_INFO_V1(pgcolumnar_iceberg_fdw_validator);

Datum
pgcolumnar_iceberg_fdw_validator(PG_FUNCTION_ARGS)
{
	List	   *options = untransformRelOptions(PG_GETARG_DATUM(0));
	Oid			catalog = PG_GETARG_OID(1);
	ListCell   *lc;

	foreach(lc, options)
	{
		DefElem    *def = (DefElem *) lfirst(lc);

		if (catalog == ForeignTableRelationId)
		{
			if (strcmp(def->defname, "metadata_path") != 0)
				ereport(ERROR,
						(errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
						 errmsg("invalid option \"%s\" for a pgcolumnar_iceberg foreign table",
								def->defname),
						 errhint("Valid table option: metadata_path.")));
		}
		else if (def->defname != NULL)
			ereport(ERROR,
					(errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
					 errmsg("invalid option \"%s\" for pgcolumnar_iceberg",
							def->defname)));
	}
	PG_RETURN_VOID();
}
