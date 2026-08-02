/*-------------------------------------------------------------------------
 *
 * columnar_vector.c
 *		Vectorized execution for pgColumnar (spec 9): a column-at-a-time filter
 *		and vectorized aggregates over decoded chunk-group arrays.
 *
 * Two things live here. First, a shared filter: a plan's simple "column op
 * const" restriction clauses are turned into predicates that are evaluated
 * column-at-a-time over a decoded chunk group to build a selection vector.
 * Second, a vectorized aggregate custom scan: for the common shape
 * SELECT agg(col) FROM t [WHERE ...] with no GROUP BY or HAVING, a custom path
 * on the grouping upper relation computes count, sum, avg, min and max from the
 * zone-map metadata, or by scanning when the group has deletes, skipping the
 * per-tuple executor path.
 *
 * Correctness is the invariant. The vectorized aggregate is only chosen when
 * every aggregate, every column type, and every filter clause is one this module
 * fully supports; anything else falls back to the ordinary scalar Agg plan. The
 * accumulation reproduces PostgreSQL's own aggregate semantics exactly (integer
 * sum overflow behaviour, average as numeric via numeric_div, min/max by the
 * type's default ordering), so a vectorized result equals the scalar result for
 * every query. The toggle columnar.enable_vectorization disables this path so
 * tests can assert that equality.
 *
 * The aggregate custom scan reuses the same registered CustomScanMethods as the
 * base custom scan (so both show as "Custom Scan (ColumnarScan)"); the shared
 * create-state callback in columnar_customscan.c dispatches to the aggregate
 * variant when the plan is a scanrelid==0 upper node.
 *
 * Independent MIT implementation built from
 * design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md and the public PostgreSQL API (the
 * custom-scan provider contract, create_upper_paths_hook, and the documented
 * aggregate result types) only.
 *
 *-------------------------------------------------------------------------
 */
#include "columnar.h"

#include <math.h>

#include "miscadmin.h"
#include "access/relation.h"
#include "access/table.h"
#include "catalog/pg_aggregate.h"
#include "catalog/pg_namespace.h"
#include "catalog/pg_type.h"
#include "commands/explain.h"
#if PG_VERSION_NUM >= 180000
/* PG18 split the ExplainProperty* helpers out into explain_format.h. */
#include "commands/explain_format.h"
#endif
#include "executor/executor.h"
#include "executor/tuptable.h"
#include "nodes/execnodes.h"
#include "nodes/extensible.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "nodes/pathnodes.h"
#include "nodes/plannodes.h"
#include "optimizer/optimizer.h"
#include "optimizer/pathnode.h"
#include "optimizer/planner.h"
#include "optimizer/cost.h"
#include "optimizer/restrictinfo.h"
#include "optimizer/tlist.h"
#include "access/sysattr.h"
#include "utils/selfuncs.h"
#include "utils/builtins.h"
#include "utils/snapmgr.h"
#include "utils/datum.h"
#include "utils/fmgrprotos.h"
#include "utils/lsyscache.h"
#include "access/stratnum.h"
#include "access/tupmacs.h"
#include "common/hashfn.h"
#include "utils/rel.h"
#include "utils/typcache.h"

/* GUC: use the vectorized aggregate path (spec 8.3 scan control) */
bool		columnar_enable_vectorization = true;

/*
 * GUC: extend the vectorized aggregate to GROUP BY (#289). Default off while the
 * grouped path is built out incrementally; the ungrouped path is unaffected.
 * groupagg_max_groups caps the ACTUAL group count at execution time; exceeding
 * it raises an error (see columnar_groupagg_lookup) rather than routing to core
 * HashAgg. It is not a plan-time gate.
 */
bool		columnar_enable_group_vectorization = false;
int			columnar_groupagg_max_groups = 1000000;

/*
 * GUC: extend the ungrouped vectorized aggregate to the shapes a zone map cannot
 * answer -- an aggregate with a WHERE filter, or sum/avg over int8/float/numeric
 * (#289). Those fall to the row-wise core Agg today; this folds them in one pass
 * over the columnar scan instead. Default off while the path is proven and
 * benchmarked; the metadata-answerable no-filter path is unaffected.
 */
bool		columnar_enable_ungrouped_vector_agg = false;

/* -------------------------------------------------------------------------
 * shared column-at-a-time filter
 * ------------------------------------------------------------------------- */

/*
 * One convertible "column op const" restriction clause. Scratch only: it is
 * filled to decide whether a clause converts and discarded, and nothing stores
 * an array of these. The machinery that evaluated them over a decoded chunk
 * group had no call site and is deleted (issue #200).
 */
typedef struct ColumnarVecPredicate
{
	int			attidx;			/* 0-based column index */
	bool		varOnLeft;		/* column op const, else const op column */
	FmgrInfo	opFn;			/* the operator function (returns bool) */
	Datum		constValue;
	Oid			collation;
} ColumnarVecPredicate;


/*
 * columnar_clause_to_predicate
 *		Turn one "column op const" (or "const op column") clause into a predicate
 *		we can evaluate row by row. Requires a strict boolean operator and a
 *		non-null constant, so that a null column value or a failed comparison
 *		excludes the row, matching SQL WHERE semantics. Returns false for any
 *		other clause.
 */
static bool
columnar_clause_to_predicate(Node *clause, Index scanrelid, TupleDesc tupdesc,
							 ColumnarVecPredicate *pred)
{
	OpExpr	   *op;
	Node	   *leftop;
	Node	   *rightop;
	Var		   *var;
	Const	   *con;
	bool		varOnLeft;
	Oid			opfuncid;

	if (!IsA(clause, OpExpr))
		return false;
	op = (OpExpr *) clause;
	if (list_length(op->args) != 2)
		return false;
	if (op->opresulttype != BOOLOID)
		return false;

	leftop = (Node *) linitial(op->args);
	rightop = (Node *) lsecond(op->args);
	if (IsA(leftop, RelabelType))
		leftop = (Node *) ((RelabelType *) leftop)->arg;
	if (IsA(rightop, RelabelType))
		rightop = (Node *) ((RelabelType *) rightop)->arg;

	if (IsA(leftop, Var) && IsA(rightop, Const))
	{
		var = (Var *) leftop;
		con = (Const *) rightop;
		varOnLeft = true;
	}
	else if (IsA(rightop, Var) && IsA(leftop, Const))
	{
		var = (Var *) rightop;
		con = (Const *) leftop;
		varOnLeft = false;
	}
	else
		return false;

	if (var->varno != scanrelid)
		return false;
	if (var->varattno < 1 || var->varattno > tupdesc->natts)
		return false;
	if (con->constisnull)
		return false;

	opfuncid = get_opcode(op->opno);
	if (!OidIsValid(opfuncid) || !func_strict(opfuncid))
		return false;

	pred->attidx = var->varattno - 1;
	pred->varOnLeft = varOnLeft;
	fmgr_info(opfuncid, &pred->opFn);
	pred->constValue = con->constvalue;
	pred->collation = op->inputcollid;
	return true;
}

static void
ColumnarCountConvertibleQuals(List *qual, Index scanrelid, TupleDesc tupdesc,
							  int *nconvertible, bool *allConvertible)
{
	ListCell   *lc;
	int			n = 0;

	*nconvertible = 0;
	*allConvertible = true;
	if (qual == NIL)
		return;

	foreach(lc, qual)
	{
		ColumnarVecPredicate scratch;

		if (columnar_clause_to_predicate((Node *) lfirst(lc), scanrelid, tupdesc,
										 &scratch))
			n++;
		else
			*allConvertible = false;
	}

	*nconvertible = n;
}


/*
 * The branch-free typed comparison loops that lived here built a selection
 * vector, and were reached only from a function that had no call site anywhere
 * in the tree; both are deleted (issue #200). Recoverable from history if a
 * filtered aggregate path is ever built. What should not be recovered with them is their gating, which
 * was none: the scalar path's predicates are gated on
 * pgcolumnar.enable_qual_pushdown inside ColumnarBeginRead and these never were,
 * so wiring them up as they stood would have filtered rows while EXPLAIN
 * reported no pushdown at all.
 */


/* -------------------------------------------------------------------------
 * vectorized aggregate: classification
 * ------------------------------------------------------------------------- */

typedef enum ColumnarAggKind
{
	COLUMNAR_AGG_COUNT_STAR,
	COLUMNAR_AGG_COUNT_COL,
	COLUMNAR_AGG_SUM_INT,
	COLUMNAR_AGG_AVG_INT,
	COLUMNAR_AGG_MIN,
	COLUMNAR_AGG_MAX,
	/*
	 * Extended kinds used by the grouped path and the ungrouped scan-fold path
	 * (#289). The metadata-fold path (columnar_fill_native_metadata_agg) still
	 * never produces these: a query using one is routed to scan-fold instead.
	 */
	COLUMNAR_AGG_SUM_INT8,		/* sum(int8) -> numeric */
	COLUMNAR_AGG_SUM_FLOAT,		/* sum(float4/float8) -> float8 */
	COLUMNAR_AGG_SUM_NUMERIC,	/* sum(numeric) -> numeric */
	COLUMNAR_AGG_AVG_INT8,		/* avg(int8) -> numeric */
	COLUMNAR_AGG_AVG_FLOAT,		/* avg(float4/float8) -> float8 */
	COLUMNAR_AGG_AVG_NUMERIC	/* avg(numeric) -> numeric */
} ColumnarAggKind;

typedef struct ColumnarAggSpec
{
	ColumnarAggKind kind;
	int			attidx;			/* 0-based column, or -1 for count(*) */
	Oid			inputType;		/* column type (min/max/sum/avg) */

	/* min/max helpers */
	FmgrInfo	cmpFn;			/* type default btree comparison */
	Oid			collation;
	bool		byval;
	int16		typlen;

	/* accumulators */
	int64		count;			/* count(*), count(col), avg count */
	int64		sum;			/* integer sum / avg sum */
	bool		sawValue;		/* any non-null value contributed */
	Datum		extreme;		/* min/max running value (in resultContext) */
	float8		fsum;			/* float running sum (scan order, like float8_accum) */
	float8		fsxx;			/* avg(float): Youngs-Cramer Sxx, for overflow parity */
	Datum		nsum;			/* numeric running total (in resultContext) */
	bool		nsumSet;		/* nsum initialized */
} ColumnarAggSpec;

/*
 * columnar_classify_aggref
 *		Decide whether an Aggref is one we can compute vectorized, and if so fill
 *		its spec. expectedVarno is the scan relation's range-table index at plan
 *		time (to check the argument Var), or a negative value at execution time
 *		where only the attribute number matters. Returns false to force the
 *		scalar fallback.
 */
static bool
columnar_classify_aggref(Aggref *agg, int expectedVarno, bool allowExtended,
						 ColumnarAggSpec *spec)
{
	char	   *name;
	Oid			nsp;
	Var		   *argVar = NULL;

	if (agg->aggorder != NIL || agg->aggdistinct != NIL ||
		agg->aggfilter != NULL || agg->aggvariadic ||
		agg->aggkind != AGGKIND_NORMAL || agg->aggsplit != AGGSPLIT_SIMPLE)
		return false;

	nsp = get_func_namespace(agg->aggfnoid);
	if (nsp != PG_CATALOG_NAMESPACE)
		return false;
	name = get_func_name(agg->aggfnoid);
	if (name == NULL)
		return false;

	/* recover the single column argument, when there is one */
	if (list_length(agg->args) == 1)
	{
		TargetEntry *tle = (TargetEntry *) linitial(agg->args);
		Node	   *arg = (Node *) tle->expr;

		if (IsA(arg, RelabelType))
			arg = (Node *) ((RelabelType *) arg)->arg;
		if (IsA(arg, Var))
			argVar = (Var *) arg;
	}

	memset(spec, 0, sizeof(*spec));
	spec->attidx = -1;

	if (strcmp(name, "count") == 0)
	{
		if (agg->aggstar || list_length(agg->args) == 0)
		{
			spec->kind = COLUMNAR_AGG_COUNT_STAR;
			return true;
		}
		if (argVar == NULL)
			return false;
		if (expectedVarno >= 0 && argVar->varno != (Index) expectedVarno)
			return false;
		spec->kind = COLUMNAR_AGG_COUNT_COL;
		spec->attidx = argVar->varattno - 1;
		return spec->attidx >= 0;
	}

	if (argVar == NULL)
		return false;
	if (expectedVarno >= 0 && argVar->varno != (Index) expectedVarno)
		return false;
	if (argVar->varattno < 1)
		return false;
	spec->attidx = argVar->varattno - 1;
	spec->inputType = argVar->vartype;

	if (strcmp(name, "sum") == 0)
	{
		if (spec->inputType == INT2OID || spec->inputType == INT4OID)
		{
			spec->kind = COLUMNAR_AGG_SUM_INT;
			return true;
		}
		if (allowExtended)
		{
			if (spec->inputType == INT8OID)
				spec->kind = COLUMNAR_AGG_SUM_INT8;
			else if (spec->inputType == FLOAT4OID || spec->inputType == FLOAT8OID)
				spec->kind = COLUMNAR_AGG_SUM_FLOAT;
			else if (spec->inputType == NUMERICOID)
				spec->kind = COLUMNAR_AGG_SUM_NUMERIC;
			else
				return false;
			return true;
		}
		return false;			/* ungrouped: int8/float/numeric fall back */
	}

	if (strcmp(name, "avg") == 0)
	{
		if (spec->inputType == INT2OID || spec->inputType == INT4OID)
		{
			spec->kind = COLUMNAR_AGG_AVG_INT;
			return true;
		}
		if (allowExtended)
		{
			if (spec->inputType == INT8OID)
				spec->kind = COLUMNAR_AGG_AVG_INT8;
			else if (spec->inputType == FLOAT4OID || spec->inputType == FLOAT8OID)
				spec->kind = COLUMNAR_AGG_AVG_FLOAT;
			else if (spec->inputType == NUMERICOID)
				spec->kind = COLUMNAR_AGG_AVG_NUMERIC;
			else
				return false;
			return true;
		}
		return false;
	}

	if (strcmp(name, "min") == 0 || strcmp(name, "max") == 0)
	{
		TypeCacheEntry *tce = lookup_type_cache(spec->inputType,
												TYPECACHE_CMP_PROC_FINFO);

		if (!OidIsValid(tce->cmp_proc_finfo.fn_oid))
			return false;
		spec->kind = (name[1] == 'i') ? COLUMNAR_AGG_MIN : COLUMNAR_AGG_MAX;
		return true;
	}

	return false;
}

/*
 * columnar_group_key_unsupported_walker
 *		Reject any node in a candidate GROUP BY key the grouped path cannot
 *		evaluate against a bare base-relation slot: aggregates, grouping-set
 *		constructs, window functions, sublinks/subplans, external parameters,
 *		and whole-row or system-column Vars. Everything the executor's ordinary
 *		expression machinery can evaluate from scan columns alone (Const, real
 *		Vars, OpExpr, FuncExpr, CoerceViaIO, CaseExpr, ...) is accepted, subject
 *		to the volatility and varno checks the caller also applies.
 */
static bool
columnar_group_key_unsupported_walker(Node *node, void *context)
{
	if (node == NULL)
		return false;

	switch (nodeTag(node))
	{
		case T_Var:
			{
				Var		   *var = (Var *) node;

				/* whole-row and system columns are not projectable here */
				if (var->varattno <= 0)
					return true;
				return false;
			}
		case T_Aggref:
		case T_GroupingFunc:
		case T_WindowFunc:
		case T_SubLink:
		case T_SubPlan:
		case T_AlternativeSubPlan:
		case T_Param:
			return true;
		default:
			break;
	}

	return expression_tree_walker(node, columnar_group_key_unsupported_walker,
								  context);
}

/*
 * columnar_classify_group_keys
 *		Decide whether every GROUP BY key can be computed and grouped by the
 *		grouped vectorized path, and if so return copies of the key expressions
 *		(original varnos, one per grouping column). A key must be computable from
 *		this relation alone, non-volatile, not set-returning, free of the node
 *		kinds above, and have both a hash function and an equality operator; a
 *		collatable key must use a deterministic collation, because grouping then
 *		matches the byte-exact semantics the scalar path would produce. Returns
 *		false (add no path, run the ordinary Agg) on anything unsupported.
 */
static bool
columnar_classify_group_keys(PlannerInfo *root, RelOptInfo *input_rel,
							 List **keysOut)
{
	Query	   *parse = root->parse;
	List	   *keys = NIL;
	ListCell   *lc;

	foreach(lc, parse->groupClause)
	{
		SortGroupClause *sgc = lfirst_node(SortGroupClause, lc);
		Node	   *expr = get_sortgroupclause_expr(sgc, parse->targetList);
		Oid			type;
		Oid			coll;
		TypeCacheEntry *tce;

		if (expr == NULL)
			return false;

		/*
		 * Do NOT strip a wrapping RelabelType: it carries the cast's result type
		 * and collation. Stripping it would read the type/collation from the
		 * underlying value instead, which for an explicit COLLATE defeats the
		 * deterministic-collation check below and could group with the wrong
		 * equality. Group by the expression exactly as written.
		 */
		if (!bms_is_subset(pull_varnos(root, expr), input_rel->relids))
			return false;
		if (contain_volatile_functions(expr))
			return false;
		if (expression_returns_set(expr))
			return false;
		if (columnar_group_key_unsupported_walker(expr, NULL))
			return false;

		type = exprType(expr);
		coll = exprCollation(expr);
		tce = lookup_type_cache(type,
								TYPECACHE_HASH_PROC_FINFO |
								TYPECACHE_EQ_OPR_FINFO);
		if (!OidIsValid(tce->hash_proc_finfo.fn_oid))
			return false;
		if (!OidIsValid(tce->eq_opr_finfo.fn_oid))
			return false;
		if (OidIsValid(coll) && !ColumnarCollationIsDeterministic(coll))
			return false;

		keys = lappend(keys, copyObject(expr));
	}

	if (keys == NIL)
		return false;
	*keysOut = keys;
	return true;
}

/* -------------------------------------------------------------------------
 * vectorized aggregate: executor state
 * ------------------------------------------------------------------------- */

typedef struct ColumnarAggScanState
{
	CustomScanState css;

	Oid			relid;			/* base relation to scan */
	List	   *quals;			/* restriction clauses (original varnos) */
	Index		scanrelid;		/* their range-table index */

	ColumnarAggSpec *specs;
	int			naggs;

	int			npreds;			/* pushed-down predicate count, for EXPLAIN */

	MemoryContext resultContext;	/* holds min/max running values */
	bool		done;			/* the single result row was emitted */

	/*
	 * Scan-fold mode (#289): the aggregate has a WHERE filter, or a sum/avg a
	 * zone map cannot answer, so the node scans and folds every surviving row
	 * instead of answering from metadata. NULL whereState means no residual
	 * recheck (a pure extended aggregate with no filter).
	 */
	bool		scanFold;
	Bitmapset  *projected;		/* base columns the scan must return */
	TupleTableSlot *baseSlot;	/* holds each read row for the qual recheck */
	ExprState  *whereState;		/* residual WHERE recheck, or NULL */

	/*
	 * Batch fold (#289): when every aggregate and the whole WHERE are
	 * batch-eligible, fold the decoded column buffer column-at-a-time instead of
	 * one Datum tuple per row. batchEligible is decided at Begin (a shape
	 * property, for EXPLAIN); batchFolded records that the fold actually ran.
	 */
	bool		batchEligible;
	bool		batchFolded;

	/* chunk-group skip counters captured for EXPLAIN */
	bool		haveStats;
	uint64		groupsRead;
	uint64		groupsSkipped;
	uint64		groupsTotal;
} ColumnarAggScanState;

static const CustomExecMethods columnar_agg_exec_methods;

/* -------------------------------------------------------------------------
 * grouped vectorized aggregate (#289): executor state
 *
 * Fires for SELECT <keys>, agg(col) ... [WHERE ...] GROUP BY <keys> over a
 * single columnar relation. The reader (ColumnarReadNextRow) applies WHERE
 * pushdown for group/vector skipping; each surviving row is rechecked against
 * the full WHERE, its group keys are evaluated, and it is scattered into an
 * open-addressing hash table whose per-group accumulators fold in scan order --
 * byte-identical to the scalar Agg the planner would otherwise run. Grouping
 * uses each key type's own hash and equality functions, so -0.0/NaN, numeric
 * scale, and deterministic-collation text all group exactly as core does.
 * ------------------------------------------------------------------------- */

typedef struct ColumnarGroupKey
{
	Expr	   *expr;			/* key expression (original varnos) */
	ExprState  *exprState;		/* evaluates it against the base slot */
	Oid			type;
	Oid			collation;
	int16		typlen;
	bool		byval;
	FmgrInfo	hashFn;			/* type hash function */
	FmgrInfo	eqFn;			/* type equality operator function */
} ColumnarGroupKey;

typedef struct ColumnarGroupEntry
{
	uint32		hash;
	bool		used;
	Datum	   *keys;			/* nkeys key values, in keyContext */
	bool	   *keyNulls;		/* nkeys null flags */
	ColumnarAggSpec *specs;		/* naggs accumulators, in specContext */
} ColumnarGroupEntry;

typedef struct ColumnarGroupAggScanState
{
	CustomScanState css;

	Oid			relid;			/* base relation to scan */
	List	   *quals;			/* WHERE clauses (original varnos) */
	Index		scanrelid;		/* their range-table index */

	int			nkeys;
	ColumnarGroupKey *keys;

	int			naggs;
	ColumnarAggSpec *aggTemplate;	/* classified once; copied per new group */

	int			nout;			/* output tuple width */
	int		   *outMap;			/* per output pos: >=0 key index, else agg -(v)-1 */

	Bitmapset  *projected;		/* base columns the reader must return */
	TupleTableSlot *baseSlot;	/* holds each read row for key/qual eval */
	ExprState  *whereState;		/* residual WHERE recheck, or NULL */

	ColumnarGroupEntry *entries;	/* open-addressing table (power-of-two) */
	int			capacity;
	int			nGroups;
	int			maxGroups;		/* GUC cap enforced at execution (columnar_groupagg_lookup) */

	MemoryContext keyContext;	/* copied key Datums */
	MemoryContext specContext;	/* per-group specs + running min/max/numeric */
	MemoryContext hashContext;	/* the entries array itself */

	bool		started;		/* scan + build completed */
	int			emitPos;		/* next entry index to emit */

	/* EXPLAIN */
	int			npreds;
	bool		haveStats;
	uint64		groupsRead;
	uint64		groupsSkipped;
	uint64		groupsTotal;
} ColumnarGroupAggScanState;

static const CustomExecMethods columnar_groupagg_exec_methods;
static void ColumnarTryGroupAggPath(PlannerInfo *root, RelOptInfo *input_rel,
									RelOptInfo *output_rel);
static bool columnar_batch_shape_eligible(ColumnarAggScanState *state,
										  TupleDesc tupdesc, ScanKey *keysOut,
										  int *nkeysOut);

/* -------------------------------------------------------------------------
 * vectorized aggregate: planning
 * ------------------------------------------------------------------------- */

static Plan *
ColumnarPlanAggPath(PlannerInfo *root, RelOptInfo *rel, CustomPath *best_path,
					List *tlist, List *clauses, List *custom_plans)
{
	CustomScan *cscan = makeNode(CustomScan);

	cscan->scan.plan.targetlist = tlist;
	cscan->scan.plan.qual = NIL;	/* WHERE is applied inside the scan */
	cscan->scan.scanrelid = 0;		/* not a base-relation scan */
	cscan->flags = best_path->flags;
	cscan->custom_plans = NIL;
	cscan->custom_exprs = NIL;
	cscan->custom_private = best_path->custom_private;
	cscan->custom_scan_tlist = tlist;	/* defines the output tuple shape */
	cscan->methods = &columnar_scan_methods;	/* shared registered methods */

	return &cscan->scan.plan;
}

static const CustomPathMethods columnar_agg_path_methods = {
	.CustomName = "ColumnarAgg",
	.PlanCustomPath = ColumnarPlanAggPath,
	.ReparameterizeCustomPathByChild = NULL,
};

static create_upper_paths_hook_type prev_create_upper_paths_hook = NULL;

/*
 * columnar_agg_metadata_answerable
 *		True when this aggregate kind is answerable from whole-chunk zone maps
 *		with no data scan: count, count(col), sum/avg over int2/int4 (the zone
 *		stores an int sum), min and max. The extended kinds (sum/avg over
 *		int8/float/numeric) are not, so a query using one must scan and fold. See
 *		columnar_fill_native_metadata_agg.
 */
static bool
columnar_agg_metadata_answerable(ColumnarAggKind kind)
{
	switch (kind)
	{
		case COLUMNAR_AGG_COUNT_STAR:
		case COLUMNAR_AGG_COUNT_COL:
		case COLUMNAR_AGG_SUM_INT:
		case COLUMNAR_AGG_AVG_INT:
		case COLUMNAR_AGG_MIN:
		case COLUMNAR_AGG_MAX:
			return true;
		case COLUMNAR_AGG_SUM_INT8:
		case COLUMNAR_AGG_SUM_FLOAT:
		case COLUMNAR_AGG_SUM_NUMERIC:
		case COLUMNAR_AGG_AVG_INT8:
		case COLUMNAR_AGG_AVG_FLOAT:
		case COLUMNAR_AGG_AVG_NUMERIC:
			return false;
	}
	return false;
}

/*
 * ColumnarCreateUpperPaths
 *		create_upper_paths_hook: for a plain SELECT agg(col) FROM columnar_table
 *		[WHERE simple quals] with no grouping or HAVING, add a custom path that
 *		computes the aggregates vectorized. Every aggregate, column type and
 *		filter clause must be fully supported, or we add nothing and the ordinary
 *		Agg plan runs, so results are never at risk.
 */
static void
ColumnarCreateUpperPaths(PlannerInfo *root, UpperRelationKind stage,
						 RelOptInfo *input_rel, RelOptInfo *output_rel,
						 void *extra)
{
	Query	   *parse = root->parse;
	RangeTblEntry *rte;
	Oid			relid;
	List	   *tlist = output_rel->reltarget->exprs;
	ListCell   *lc;
	int			naggs;
	int			i;
	ColumnarAggSpec *specs;
	List	   *quals;
	int			npreds;
	bool		allConvertible;
	bool		needsScan;
	Path	   *cheapest;
	CustomPath *cpath;

	if (prev_create_upper_paths_hook)
		prev_create_upper_paths_hook(root, stage, input_rel, output_rel, extra);

	if (stage != UPPERREL_GROUP_AGG)
		return;
	if (!columnar_enable_vectorization || !columnar_enable_custom_scan)
		return;

	if (!parse->hasAggs)
		return;

	/*
	 * GROUP BY: try the grouped vectorized path (#289). It handles a plain
	 * grouped aggregate over one columnar relation, with an optional WHERE, and
	 * no grouping sets / HAVING / DISTINCT / window / SRF. Anything else, or an
	 * unsupported key or aggregate, adds no path and the ordinary Agg runs.
	 */
	if (parse->groupClause != NIL || parse->groupingSets != NIL ||
		parse->havingQual != NULL || parse->distinctClause != NIL ||
		parse->hasWindowFuncs || parse->hasTargetSRFs)
	{
		if (columnar_enable_group_vectorization &&
			parse->groupClause != NIL &&
			parse->groupingSets == NIL &&
			parse->havingQual == NULL &&
			parse->distinctClause == NIL &&
			!parse->hasWindowFuncs &&
			!parse->hasTargetSRFs)
			ColumnarTryGroupAggPath(root, input_rel, output_rel);
		return;
	}

	/* plain, ungrouped aggregation only (spec 9) */

	/* a single columnar base relation with no joins */
	if (input_rel->reloptkind != RELOPT_BASEREL)
		return;
	if (bms_membership(input_rel->relids) != BMS_SINGLETON)
		return;
	if (input_rel->relid == 0 ||
		input_rel->relid >= (Index) root->simple_rel_array_size)
		return;
	rte = root->simple_rte_array[input_rel->relid];
	if (rte == NULL || rte->rtekind != RTE_RELATION ||
		rte->relkind != RELKIND_RELATION)
		return;
	if (!OidIsValid(rte->relid) || !ColumnarIsColumnarRelation(rte->relid))
		return;
	relid = rte->relid;

	/* every target entry must be a bare, supported aggregate */
	naggs = list_length(tlist);
	if (naggs == 0)
		return;
	specs = (ColumnarAggSpec *) palloc0(sizeof(ColumnarAggSpec) * naggs);
	i = 0;
	foreach(lc, tlist)
	{
		Node	   *expr = (Node *) lfirst(lc);

		if (!IsA(expr, Aggref))
			return;
		if (!columnar_classify_aggref((Aggref *) expr, (int) input_rel->relid,
									  true, &specs[i]))
			return;
		i++;
	}

	/*
	 * The whole WHERE, rechecked per row in scan-fold mode; NIL with no filter.
	 * A native table answers an ungrouped aggregate from its zone maps with no
	 * data scan (native spec 7.1), but only with no filter and every aggregate
	 * zone-map answerable. A filter, or a sum/avg over int8/float/numeric, needs
	 * the scan-fold path instead (#289).
	 */
	quals = extract_actual_clauses(input_rel->baserestrictinfo, false);

	needsScan = (quals != NIL);
	for (i = 0; i < naggs; i++)
		if (!columnar_agg_metadata_answerable(specs[i].kind))
			needsScan = true;

	if (needsScan)
	{
		/*
		 * Scan-fold path (#289): the ungrouped sibling of the grouped path. It
		 * scans every surviving row once and folds it, so it handles a filter and
		 * the extended sum/avg kinds a zone map cannot. Opt-in while it is proven.
		 */
		ListCell   *rc;
		Bitmapset  *whereAtts = NULL;
		int			m = -1;

		if (!columnar_enable_ungrouped_vector_agg)
			return;

		/*
		 * A pseudoconstant (gating) qual is a one-time filter, not a per-row
		 * predicate; the recheck this path relies on runs per row and would never
		 * apply it, so a false gate would wrongly return a row. Rare; fall back.
		 * (Mirrors the grouped path.)
		 */
		foreach(rc, input_rel->baserestrictinfo)
			if (lfirst_node(RestrictInfo, rc)->pseudoconstant)
				return;

		/*
		 * A WHERE on a system column or a whole-row Var cannot be evaluated from
		 * the projected data columns the recheck reads; fall back rather than
		 * evaluate it against unset slot values.
		 */
		pull_varattnos((Node *) quals, input_rel->relid, &whereAtts);
		while ((m = bms_next_member(whereAtts, m)) >= 0)
			if (m + FirstLowInvalidHeapAttributeNumber <= 0)
				return;

		npreds = 0;				/* the EXPLAIN count is filled at execution */
	}
	else
	{
		Relation	rel = table_open(relid, AccessShareLock);
		TupleDesc	tupdesc = RelationGetDescr(rel);

		ColumnarCountConvertibleQuals(quals, input_rel->relid, tupdesc,
									  &npreds, &allConvertible);
		table_close(rel, AccessShareLock);
		if (!allConvertible)
			return;
	}

	cheapest = input_rel->cheapest_total_path;
	if (cheapest == NULL)
		return;

	cpath = makeNode(CustomPath);
	cpath->path.pathtype = T_CustomScan;
	cpath->path.parent = output_rel;
	cpath->path.pathtarget = output_rel->reltarget;
	cpath->path.param_info = NULL;
	cpath->path.parallel_aware = false;
	cpath->path.parallel_safe = false;
	cpath->path.parallel_workers = 0;
	cpath->path.rows = 1;

	/*
	 * Cost what this path actually reads.
	 *
	 * Pricing it at the cheapest scan's cost, as this did, is not merely
	 * pessimistic: it loses. A parallel Agg divides that same scan cost across
	 * workers and comes out cheaper, so the planner reads the whole table to
	 * compute what this path takes from row-group metadata (issue #133).
	 *
	 * The executor answers a clean row group from its metadata and reads no data
	 * pages for it; it reads only the groups that have deletes (issue #149). So
	 * the price is one metadata entry per row group, plus a scan of the fraction
	 * of the table that is deleted-in.
	 *
	 * Pricing the whole path at the scan cost the moment any row anywhere is
	 * deleted, as this did, gives the planner back the choice this path exists to
	 * take away: one deleted row out of six million made a parallel Agg look
	 * cheaper again and #133 came back. The probe below asks the same question
	 * execution asks; if the answer changes between planning and execution the
	 * plan is mispriced, never wrong.
	 */
	if (needsScan)
	{
		/*
		 * A full columnar scan, priced from the cheapest non-index path (an index
		 * scan cannot serve this node), plus a token per-row bump so this opt-in
		 * accelerator is chosen over the ordinary Agg-over-scan when it is enabled.
		 */
		Path	   *scanp = NULL;
		ListCell   *pc;
		Cost		cost;

		foreach(pc, input_rel->pathlist)
		{
			Path	   *p = (Path *) lfirst(pc);

			if (p->pathtype == T_IndexScan || p->pathtype == T_IndexOnlyScan ||
				p->pathtype == T_BitmapHeapScan)
				continue;
			if (scanp == NULL || p->total_cost < scanp->total_cost)
				scanp = p;
		}
		if (scanp == NULL)
			scanp = cheapest;
		cost = scanp->total_cost + cpu_tuple_cost;
		cpath->path.startup_cost = cost;
		cpath->path.total_cost = cost;
	}
	else
	{
		ColumnarOptions opts;
		int			limit = columnar_stripe_row_limit;
		double		rows = input_rel->tuples;
		double		ngroups;
		double		dirtyFraction = 0.0;
		Snapshot	snap = GetActiveSnapshot();
		Cost		cost;

		/*
		 * Row groups are governed by stripe_row_limit, not chunk_group_row_limit:
		 * the latter sets the vector size within a group. Dividing by the vector
		 * size overstated the group count by the ratio between them -- at the
		 * default limits, 60 computed groups against 4 actual. The estimate was
		 * clamped below the scan cost so it still chose right, but it was a wrong
		 * model getting a right answer, and it stops being harmless as soon as the
		 * clamp is not what decides.
		 */
		if (ColumnarReadOptions(relid, &opts) &&
			opts.stripeRowLimitSet && opts.stripeRowLimit > 0)
			limit = opts.stripeRowLimit;
		if (limit <= 0)
			limit = 1;

		/*
		 * A never-analyzed relation has no row estimate. Deriving one from the
		 * page count keeps the cost tied to something real, so a missing estimate
		 * cannot make this path look free.
		 */
		if (rows < 0)
			rows = (input_rel->pages > 0)
				? (double) input_rel->pages * 100.0
				: 1000.0;
		ngroups = ceil(rows / (double) limit);
		if (ngroups < 1)
			ngroups = 1;

		/*
		 * What fraction of the groups must actually be read. Counting them exactly
		 * would mean a delete-vector lookup per group at planning time, which is
		 * the per-group catalog traffic this path exists to avoid paying. The
		 * storage-wide probe is one lookup and distinguishes the case that matters
		 * -- nothing deleted at all -- from the case where something is. When
		 * something is, assume one group in four is affected rather than all of
		 * them: wrong in both directions by a bounded factor, where the previous
		 * all-or-nothing was wrong by the whole table.
		 */
		if (snap != NULL)
		{
			Relation	frel = table_open(relid, AccessShareLock);

			if (ColumnarStorageHasDeleteVector(ColumnarStorageId(frel),
											   ColumnarCatalogSnapshot(snap)))
				dirtyFraction = 0.25;
			table_close(frel, AccessShareLock);
		}
		else
			dirtyFraction = 0.25;

		cost = cpu_tuple_cost * 10;		/* getting to the catalog */
		cost += ngroups * (cpu_tuple_cost +
						   cpu_operator_cost * (double) naggs);
		cost += dirtyFraction * cheapest->total_cost;

		/* reading metadata is never dearer than reading the table */
		if (cost > cheapest->total_cost)
			cost = cheapest->total_cost;

		/*
		 * One row comes out, and only after every row group is folded in, so
		 * there is no partial result to start up cheaply with.
		 */
		cpath->path.startup_cost = cost;
		cpath->path.total_cost = cost;
	}
	cpath->path.pathkeys = NIL;
	cpath->flags = 0;
	cpath->custom_paths = NIL;
#if PG_VERSION_NUM >= 170000
	cpath->custom_restrictinfo = NIL;
#endif
	cpath->custom_private =
		list_make3(makeInteger((int) input_rel->relid),
				   copyObject(quals),
				   makeConst(OIDOID, -1, InvalidOid, sizeof(Oid),
							 ObjectIdGetDatum(relid), false, true));
	cpath->methods = &columnar_agg_path_methods;

	add_path(output_rel, &cpath->path);
}

/*
 * ColumnarTryGroupAggPath
 *		Add a grouped vectorized aggregate path (#289) when the query is one we
 *		can answer exactly: a single columnar base relation, an optional WHERE,
 *		every output entry either a supported aggregate or a bare reference to a
 *		supported GROUP BY key. On anything unsupported it adds nothing and the
 *		ordinary Agg plan runs. The group-count cap is enforced only at
 *		execution (columnar_groupagg_lookup).
 */
static void
ColumnarTryGroupAggPath(PlannerInfo *root, RelOptInfo *input_rel,
						RelOptInfo *output_rel)
{
	RangeTblEntry *rte;
	Oid			relid;
	List	   *groupKeys = NIL;
	List	   *outMap = NIL;
	List	   *quals;
	List	   *groupExprs;
	ListCell   *lc;
	int			naggs = 0;
	int			aggIdx = 0;
	double		dNumGroups;
	Path	   *cheapest;
	CustomPath *cpath;

	/* a single columnar base relation with no joins */
	if (input_rel->reloptkind != RELOPT_BASEREL)
		return;
	if (bms_membership(input_rel->relids) != BMS_SINGLETON)
		return;
	if (input_rel->relid == 0 ||
		input_rel->relid >= (Index) root->simple_rel_array_size)
		return;
	rte = root->simple_rte_array[input_rel->relid];
	if (rte == NULL || rte->rtekind != RTE_RELATION ||
		rte->relkind != RELKIND_RELATION)
		return;
	/*
	 * A legacy inheritance parent is a plain RELKIND_RELATION with rte->inh set;
	 * its children hold rows this single-relation scan would never see. Leave the
	 * whole tree to the ordinary Append + Agg plan.
	 */
	if (rte->inh)
		return;
	if (!OidIsValid(rte->relid) || !ColumnarIsColumnarRelation(rte->relid))
		return;
	relid = rte->relid;

	/* every GROUP BY key must be one we can evaluate and group exactly */
	if (!columnar_classify_group_keys(root, input_rel, &groupKeys))
		return;

	/*
	 * Every output entry is either a supported aggregate or a bare reference to
	 * one of the group keys. An output expression built on top of a key (a
	 * function of a grouping column) is not handled here and forces the fallback.
	 * outMap records, per output position, the key index (>=0) or, encoded
	 * negative, the aggregate index in output order.
	 */
	foreach(lc, output_rel->reltarget->exprs)
	{
		Node	   *oexpr = (Node *) lfirst(lc);

		if (IsA(oexpr, Aggref))
		{
			ColumnarAggSpec spec;

			if (!columnar_classify_aggref((Aggref *) oexpr,
										  (int) input_rel->relid, true, &spec))
				return;
			outMap = lappend(outMap, makeInteger(-(aggIdx + 1)));
			aggIdx++;
			naggs++;
		}
		else
		{
			ListCell   *kc;
			int			k = 0;
			int			found = -1;

			/*
			 * Match the output expression against a group key exactly as written
			 * (no RelabelType stripping): the classifier stores keys un-stripped
			 * too, and both come from the same target list, so equal() lines them
			 * up. An output built on top of a key (not a bare reference) matches
			 * nothing and forces the fallback.
			 */
			foreach(kc, groupKeys)
			{
				if (equal(oexpr, (Node *) lfirst(kc)))
				{
					found = k;
					break;
				}
				k++;
			}
			if (found < 0)
				return;
			outMap = lappend(outMap, makeInteger(found));
		}
	}
	if (naggs == 0)
		return;					/* no aggregate: leave it to the ordinary plan */

	/*
	 * estimate_num_groups only sizes the path's row estimate; it is deliberately
	 * NOT a gate. For an expression key such as date_trunc(...) the planner
	 * cannot estimate distinctness and returns a count near the input row count
	 * (here ~8.4M estimated against 48k actual), which would wrongly disable this
	 * path on exactly the large tables it helps. The unbounded-hash-table guard
	 * is the execution-time cap on the actual group count
	 * (pgcolumnar.groupagg_max_groups), which errors with guidance -- see
	 * columnar_groupagg_lookup -- rather than silently declining the feature.
	 */
	groupExprs = groupKeys;
	dNumGroups = estimate_num_groups(root, groupExprs,
									 input_rel->rows > 0 ? input_rel->rows : 1.0,
									 NULL, NULL);

	/*
	 * Pseudoconstant (gating) quals -- e.g. WHERE (SELECT false) -- are one-time
	 * filters, not per-row predicates. The residual ExecQual recheck this path
	 * relies on runs per row and would never apply them, so a false gate would
	 * wrongly return rows. They are rare; leave such a query to the ordinary plan.
	 */
	foreach(lc, input_rel->baserestrictinfo)
	{
		if (lfirst_node(RestrictInfo, lc)->pseudoconstant)
			return;
	}

	/*
	 * WHERE is carried whole and rechecked per row, so correctness never depends
	 * on which clauses become scan keys; the scan keys only prune groups.
	 */
	quals = extract_actual_clauses(input_rel->baserestrictinfo, false);

	/*
	 * A WHERE clause referencing a system column or a whole-row Var cannot be
	 * answered from the projected data columns this path reads, so fall back
	 * rather than evaluate it against unset slot values.
	 */
	{
		Bitmapset  *whereAtts = NULL;
		int			m = -1;

		pull_varattnos((Node *) quals, input_rel->relid, &whereAtts);
		while ((m = bms_next_member(whereAtts, m)) >= 0)
			if (m + FirstLowInvalidHeapAttributeNumber <= 0)
				return;
	}

	/*
	 * Cost from a full columnar scan, not input_rel->cheapest_total_path: the
	 * cheapest overall path may be an index scan, but this node always performs a
	 * full columnar scan, so pricing it from an index scan would understate it.
	 * Take the cheapest non-index path (the columnar custom or sequential scan).
	 */
	cheapest = NULL;
	foreach(lc, input_rel->pathlist)
	{
		Path	   *p = (Path *) lfirst(lc);

		if (p->pathtype == T_IndexScan || p->pathtype == T_IndexOnlyScan ||
			p->pathtype == T_BitmapHeapScan)
			continue;
		if (cheapest == NULL || p->total_cost < cheapest->total_cost)
			cheapest = p;
	}
	if (cheapest == NULL)
		cheapest = input_rel->cheapest_total_path;
	if (cheapest == NULL)
		return;

	cpath = makeNode(CustomPath);
	cpath->path.pathtype = T_CustomScan;
	cpath->path.parent = output_rel;
	cpath->path.pathtarget = output_rel->reltarget;
	cpath->path.param_info = NULL;
	cpath->path.parallel_aware = false;
	cpath->path.parallel_safe = false;
	cpath->path.parallel_workers = 0;
	cpath->path.rows = (dNumGroups < 1.0) ? 1.0 : dNumGroups;

	/*
	 * Price just above the scan the reader already does. The fold is one hash
	 * probe per row inside that scan, always cheaper than a separate Agg node's
	 * per-row advance over the same scan, so a negligible fixed bump keeps this
	 * reliably below the ordinary Agg-over-scan plan whenever the feature is
	 * enabled. This is an opt-in accelerator: when it is on it should be the
	 * plan, not a coin-flip against a HashAggregate whose cost is close. An
	 * earlier version charged per output group, which let autoanalyze flip the
	 * choice on large inputs -- so the node sometimes did not run at all. One row
	 * per group comes out only after the whole scan is folded, so there is no
	 * cheap partial start-up.
	 */
	{
		Cost		cost = cheapest->total_cost + cpu_tuple_cost;

		cpath->path.startup_cost = cost;
		cpath->path.total_cost = cost;
	}
	cpath->path.pathkeys = NIL;
	cpath->flags = 0;
	cpath->custom_paths = NIL;
#if PG_VERSION_NUM >= 170000
	cpath->custom_restrictinfo = NIL;
#endif

	/*
	 * custom_private (length 5 marks the grouped path for the shared create-state
	 * dispatch): rti, WHERE quals, relid, group-key expressions, output map. The
	 * planner leaves custom_private untouched by setrefs, so the key and qual
	 * expressions keep their original varnos and evaluate against a base slot.
	 */
	cpath->custom_private =
		list_make5(makeInteger((int) input_rel->relid),
				   copyObject(quals),
				   makeConst(OIDOID, -1, InvalidOid, sizeof(Oid),
							 ObjectIdGetDatum(relid), false, true),
				   groupKeys,
				   outMap);
	cpath->methods = &columnar_agg_path_methods;

	add_path(output_rel, &cpath->path);
}

/* -------------------------------------------------------------------------
 * vectorized aggregate: execution
 * ------------------------------------------------------------------------- */

Node *
ColumnarCreateAggScanState(CustomScan *cscan)
{
	ColumnarAggScanState *state =
		(ColumnarAggScanState *) palloc0(sizeof(ColumnarAggScanState));
	int			naggs = list_length(cscan->custom_scan_tlist);
	ListCell   *lc;
	int			i = 0;

	state->css.ss.ps.type = T_CustomScanState;
	state->css.methods = &columnar_agg_exec_methods;

	/* custom_private: rti (Integer), quals (List), relid (Const OIDOID) */
	state->scanrelid = (Index) intVal(linitial(cscan->custom_private));
	state->quals = (List *) lsecond(cscan->custom_private);
	state->relid = DatumGetObjectId(((Const *) lthird(cscan->custom_private))->constvalue);

	/* rebuild the aggregate specs from the output tuple's aggregates */
	state->naggs = naggs;
	state->specs = (ColumnarAggSpec *) palloc0(sizeof(ColumnarAggSpec) * naggs);
	foreach(lc, cscan->custom_scan_tlist)
	{
		TargetEntry *tle = (TargetEntry *) lfirst(lc);

		/* classified successfully at plan time; -1 skips the varno check */
		(void) columnar_classify_aggref((Aggref *) tle->expr, -1, true,
										&state->specs[i]);
		i++;
	}

	/*
	 * Scan-fold mode (#289) matches the planner's routing: a residual filter, or
	 * any aggregate a zone map cannot answer. The metadata-answerable no-filter
	 * case keeps the zone-map path in ColumnarExecAggScan.
	 */
	state->scanFold = (state->quals != NIL);
	for (i = 0; i < naggs; i++)
		if (!columnar_agg_metadata_answerable(state->specs[i].kind))
			state->scanFold = true;

	return (Node *) state;
}

static void
ColumnarBeginAggScan(CustomScanState *node, EState *estate, int eflags)
{
	ColumnarAggScanState *state = (ColumnarAggScanState *) node;
	Relation	rel;
	TupleDesc	tupdesc;
	bool		allConvertible;
	int			a;

	state->resultContext = AllocSetContextCreate(estate->es_query_cxt,
												 "columnar vec agg result",
												 ALLOCSET_SMALL_SIZES);
	state->done = false;
	state->haveStats = false;

	rel = table_open(state->relid, AccessShareLock);
	tupdesc = RelationGetDescr(rel);

	/*
	 * Batch eligibility is a shape property; decide it before the EXPLAIN-only
	 * return so a plain EXPLAIN reports whether the batch fold will run.
	 */
	if (state->scanFold)
		state->batchEligible =
			columnar_batch_shape_eligible(state, tupdesc, NULL, NULL);

	if (eflags & EXEC_FLAG_EXPLAIN_ONLY)
	{
		table_close(rel, AccessShareLock);
		return;
	}

	/*
	 * Guard the native format version before folding any aggregate (#240). The
	 * plain read path checks it in ColumnarBeginReadWithStorage, but the
	 * zone-map-only aggregate path answers count/min/max from metadata without
	 * ever opening a read state, so the check must also sit here -- otherwise an
	 * unsupported-format table answers from bytes this build may not decode
	 * correctly. ColumnarStorageId reads the metapage, so its version is checked
	 * here too.
	 */
	ColumnarCheckNativeFormatVersion(ColumnarStorageId(rel),
									 RelationGetRelationName(rel));

	/* finish setting up min/max comparison info now that we have the tupdesc */
	for (a = 0; a < state->naggs; a++)
	{
		ColumnarAggSpec *spec = &state->specs[a];

		if (spec->kind == COLUMNAR_AGG_MIN || spec->kind == COLUMNAR_AGG_MAX)
		{
			Form_pg_attribute att = TupleDescAttr(tupdesc, spec->attidx);
			TypeCacheEntry *tce = lookup_type_cache(att->atttypid,
													TYPECACHE_CMP_PROC_FINFO);

			fmgr_info_copy(&spec->cmpFn, &tce->cmp_proc_finfo, estate->es_query_cxt);
			spec->collation = att->attcollation;
			spec->byval = att->attbyval;
			spec->typlen = att->attlen;
		}
	}

	/*
	 * Only the count survives, and only EXPLAIN reads it. The predicate array was
	 * stored here and never read: what would have applied it had no call site
	 * anywhere in the tree and is deleted (issue #200).
	 *
	 * The call stays rather than the count being hardcoded to zero. This path is
	 * only chosen when the relation has no quals, so the count is always zero
	 * today and the call looks redundant, but that is an inference from a
	 * planner early return several hundred lines away, and it is the kind that
	 * stops being true without anyone noticing. Computing it costs one walk of
	 * an empty list.
	 */
	ColumnarCountConvertibleQuals(state->quals, state->scanrelid, tupdesc,
								  &state->npreds, &allConvertible);

	/*
	 * Scan-fold mode reads and rechecks every surviving row (#289): a virtual
	 * base slot to hold each row, the residual WHERE recheck (scan keys only
	 * prune groups and vectors), and the set of columns the aggregates and the
	 * WHERE reference so the reader returns them.
	 */
	if (state->scanFold)
	{
		Bitmapset  *proj = NULL;
		int			x;

		state->baseSlot = MakeSingleTupleTableSlot(CreateTupleDescCopy(tupdesc),
												   &TTSOpsVirtual);
		state->whereState = (state->quals != NIL)
			? ExecInitQual(state->quals, &node->ss.ps)
			: NULL;

		pull_varattnos((Node *) state->quals, state->scanrelid, &proj);
		x = -1;
		while ((x = bms_next_member(proj, x)) >= 0)
		{
			AttrNumber	attno = x + FirstLowInvalidHeapAttributeNumber;

			if (attno > 0)
				state->projected = bms_add_member(state->projected, attno - 1);
		}
		for (a = 0; a < state->naggs; a++)
			if (state->specs[a].attidx >= 0)
				state->projected = bms_add_member(state->projected,
												  state->specs[a].attidx);
		if (state->projected == NULL)
			state->projected = bms_make_singleton(0);
	}

	table_close(rel, AccessShareLock);
}

/*
 * Running float additions that reproduce core's float4pl/float8pl exactly,
 * including the overflow error: core raises "value out of range: overflow" when a
 * finite + finite addition produces an infinity, and the grouped accumulators
 * must do the same rather than silently carrying an Infinity the scalar Agg would
 * never have produced. Same compiler and flags as the server (PGXS), so the
 * arithmetic is bit-for-bit what float4pl/float8pl compute.
 */
static inline float8
columnar_float8_pl(float8 a, float8 b)
{
	float8		r = a + b;

	if (unlikely(isinf(r)) && !isinf(a) && !isinf(b))
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("value out of range: overflow")));
	return r;
}

static inline float4
columnar_float4_pl(float4 a, float4 b)
{
	float4		r = a + b;

	if (unlikely(isinf(r)) && !isinf(a) && !isinf(b))
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("value out of range: overflow")));
	return r;
}

/*
 * columnar_apply_one
 *		Fold one value (or a null) into an aggregate accumulator. This is the
 *		reference per-row semantics, shared by the ungrouped scan path
 *		(columnar_native_scan_agg) and the grouped path (columnar_groupagg_build).
 */
static void
columnar_apply_one(MemoryContext resultContext, ColumnarAggSpec *spec,
				   Datum val, bool isnull)
{
	switch (spec->kind)
	{
		case COLUMNAR_AGG_COUNT_STAR:
			spec->count++;
			break;

		case COLUMNAR_AGG_COUNT_COL:
			if (!isnull)
				spec->count++;
			break;

		case COLUMNAR_AGG_SUM_INT:
			if (!isnull)
			{
				int64		v = (spec->inputType == INT2OID)
					? (int64) DatumGetInt16(val)
					: (int64) DatumGetInt32(val);

				spec->sum += v;
				spec->sawValue = true;
			}
			break;

		case COLUMNAR_AGG_AVG_INT:
			if (!isnull)
			{
				int64		v = (spec->inputType == INT2OID)
					? (int64) DatumGetInt16(val)
					: (int64) DatumGetInt32(val);

				spec->sum += v;
				spec->count++;
			}
			break;

		case COLUMNAR_AGG_SUM_FLOAT:
			if (!isnull)
			{
				/*
				 * sum(real) accumulates in real (core float4pl) and returns real;
				 * sum(double precision) accumulates in float8 (core float8pl). Core's
				 * sum has a strict transfn with a null initial state, so it assigns
				 * the FIRST non-null value directly -- preserving a signed zero --
				 * rather than adding it to +0.0. Match that, then fold the rest with
				 * float4pl/float8pl semantics. For the float4 case fsum always holds
				 * a value exactly representable as float4, so the round-trip through
				 * (float4) reproduces float4pl step for step.
				 */
				if (!spec->sawValue)
					spec->fsum = (spec->inputType == FLOAT4OID)
						? (float8) DatumGetFloat4(val)
						: DatumGetFloat8(val);
				else if (spec->inputType == FLOAT4OID)
					spec->fsum = (float8) columnar_float4_pl((float4) spec->fsum,
															 DatumGetFloat4(val));
				else
					spec->fsum = columnar_float8_pl(spec->fsum,
													DatumGetFloat8(val));
				spec->sawValue = true;
			}
			break;

		case COLUMNAR_AGG_AVG_FLOAT:
			if (!isnull)
			{
				/*
				 * avg is Sx/N, but core's float4_accum/float8_accum keep the
				 * Youngs-Cramer Sxx as well and raise overflow when EITHER Sx or Sxx
				 * goes finite+finite -> inf. Track Sxx only to reproduce that error
				 * exactly (Sxx can overflow on finite inputs while Sx stays finite);
				 * the returned average is Sx/N and is unaffected by it.
				 */
				float8		v = (spec->inputType == FLOAT4OID)
					? (float8) DatumGetFloat4(val)
					: DatumGetFloat8(val);
				float8		n = (float8) spec->count;	/* N before this value */
				float8		newN = n + 1.0;
				float8		newSx = spec->fsum + v;

				if (spec->count > 0)
				{
					float8		tmp = v * newN - newSx;
					float8		newSxx = spec->fsxx + tmp * tmp / (n * newN);

					if ((isinf(newSx) || isinf(newSxx)) &&
						!isinf(spec->fsum) && !isinf(v))
						ereport(ERROR,
								(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
								 errmsg("value out of range: overflow")));
					spec->fsxx = newSxx;
				}
				spec->fsum = newSx;
				spec->count++;
				spec->sawValue = true;
			}
			break;

		case COLUMNAR_AGG_SUM_INT8:
		case COLUMNAR_AGG_AVG_INT8:
		case COLUMNAR_AGG_SUM_NUMERIC:
		case COLUMNAR_AGG_AVG_NUMERIC:
			if (!isnull)
			{
				bool		is_int8 = (spec->kind == COLUMNAR_AGG_SUM_INT8 ||
									   spec->kind == COLUMNAR_AGG_AVG_INT8);
				MemoryContext old = MemoryContextSwitchTo(resultContext);
				Datum		nv = is_int8
					? DirectFunctionCall1(int8_numeric, val)
					: val;

				/*
				 * Keep live memory O(groups), not O(rows): free the previous
				 * running sum and each per-row int8->numeric intermediate. Without
				 * this every scanned row leaked one or two numerics into the
				 * per-group context, which is not reset until end of scan -- O(rows)
				 * on exactly the 100M-row shape this path targets.
				 */
				if (!spec->nsumSet)
				{
					/* int8: nv is freshly allocated and becomes the running sum;
					 * numeric: nv is borrowed from the reader, so copy it. */
					spec->nsum = is_int8 ? nv : datumCopy(nv, false, -1);
					spec->nsumSet = true;
				}
				else
				{
					Datum		newsum = DirectFunctionCall2(numeric_add,
															 spec->nsum, nv);

					pfree(DatumGetPointer(spec->nsum));
					spec->nsum = newsum;
					if (is_int8)
						pfree(DatumGetPointer(nv));
				}
				spec->count++;
				spec->sawValue = true;
				MemoryContextSwitchTo(old);
			}
			break;

		case COLUMNAR_AGG_MIN:
		case COLUMNAR_AGG_MAX:
			if (!isnull)
			{
				bool		take;

				if (!spec->sawValue)
					take = true;
				else
				{
					int32		cmp = DatumGetInt32(
						FunctionCall2Coll(&spec->cmpFn, spec->collation,
										  val, spec->extreme));

					/*
					 * On a tie, take the later value, matching core's larger and
					 * smaller comparators (transfn(state, newval) returns newval
					 * when equal). Observable for numeric 1.0 vs 1.00, which tie
					 * by value but differ in display scale.
					 */
					take = (spec->kind == COLUMNAR_AGG_MIN)
						? (cmp <= 0) : (cmp >= 0);
				}

				if (take)
				{
					MemoryContext old =
						MemoryContextSwitchTo(resultContext);

					if (spec->sawValue && !spec->byval)
						pfree(DatumGetPointer(spec->extreme));
					spec->extreme = datumCopy(val, spec->byval, spec->typlen);
					spec->sawValue = true;
					MemoryContextSwitchTo(old);
				}
			}
			break;
	}
}


/*
 * columnar_agg_finalize
 *		Turn one accumulator into its output Datum, reproducing PostgreSQL's
 *		aggregate result types and empty-input behaviour exactly.
 */
static Datum
columnar_agg_finalize(ColumnarAggSpec *spec, bool *isnull)
{
	*isnull = false;

	switch (spec->kind)
	{
		case COLUMNAR_AGG_COUNT_STAR:
		case COLUMNAR_AGG_COUNT_COL:
			return Int64GetDatum(spec->count);

		case COLUMNAR_AGG_SUM_INT:
			if (!spec->sawValue)
			{
				*isnull = true;
				return (Datum) 0;
			}
			return Int64GetDatum(spec->sum);	/* sum(int2/int4) -> int8 */

		case COLUMNAR_AGG_AVG_INT:
			if (spec->count == 0)
			{
				*isnull = true;
				return (Datum) 0;
			}
			else
			{
				/* avg(int) -> numeric, exactly as int8_avg: sum/count in numeric */
				Datum		sumd = DirectFunctionCall1(int8_numeric,
													   Int64GetDatum(spec->sum));
				Datum		cntd = DirectFunctionCall1(int8_numeric,
													   Int64GetDatum(spec->count));

				return DirectFunctionCall2(numeric_div, sumd, cntd);
			}

		case COLUMNAR_AGG_SUM_FLOAT:
			if (!spec->sawValue)
			{
				*isnull = true;
				return (Datum) 0;
			}
			/* sum(real) -> real; sum(double precision) -> double precision */
			return (spec->inputType == FLOAT4OID)
				? Float4GetDatum((float4) spec->fsum)
				: Float8GetDatum(spec->fsum);

		case COLUMNAR_AGG_AVG_FLOAT:
			if (spec->count == 0)
			{
				*isnull = true;
				return (Datum) 0;
			}
			return Float8GetDatum(spec->fsum / (float8) spec->count);

		case COLUMNAR_AGG_SUM_INT8:
		case COLUMNAR_AGG_SUM_NUMERIC:
			if (!spec->nsumSet)
			{
				*isnull = true;
				return (Datum) 0;
			}
			return spec->nsum;

		case COLUMNAR_AGG_AVG_INT8:
		case COLUMNAR_AGG_AVG_NUMERIC:
			if (spec->count == 0 || !spec->nsumSet)
			{
				*isnull = true;
				return (Datum) 0;
			}
			return DirectFunctionCall2(numeric_div, spec->nsum,
									   DirectFunctionCall1(int8_numeric,
														   Int64GetDatum(spec->count)));

		case COLUMNAR_AGG_MIN:
		case COLUMNAR_AGG_MAX:
			if (!spec->sawValue)
			{
				*isnull = true;
				return (Datum) 0;
			}
			return spec->extreme;
	}

	*isnull = true;
	return (Datum) 0;
}

/*
 * columnar_group_deleted_count
 *		How many of this row group's rows are deleted, under the given catalog
 *		snapshot. A group can have several delete_vector rows, whose bitmaps
 *		overlap, so they are OR'd before counting rather than summed -- summing
 *		deletedCount across entries would double-count a row deleted twice (spec
 *		7.5, and the same combining the reader does when it builds a group's mask).
 *		Bits past the group's row count are ignored.
 */
static uint64
columnar_group_deleted_count(uint64 storageId, NativeRowGroupMetadata *rg,
							 Snapshot snap)
{
	uint32		want = (uint32) ((rg->rowCount + 7) / 8);
	char	   *mask;
	List	   *rml;
	ListCell   *mc;
	uint64		deleted = 0;
	uint32		b;

	rml = ColumnarReadDeleteVectorList(storageId, rg->groupNumber, snap);
	if (rml == NIL)
		return 0;

	mask = palloc0(want > 0 ? want : 1);
	foreach(mc, rml)
	{
		DeleteVectorMetadata *rm = (DeleteVectorMetadata *) lfirst(mc);

		if (rm->bitmap == NULL || rm->bitmapLen == 0)
			continue;
		for (b = 0; b < rm->bitmapLen && b < want; b++)
			mask[b] |= rm->bitmap[b];
	}

	/*
	 * Count set bits only up to rowCount. The last byte of the bitmap can carry
	 * bits beyond the group's final row, and counting those would report more
	 * rows deleted than the group holds.
	 */
	for (b = 0; b < want; b++)
	{
		uint64		base = (uint64) b * 8;
		int			i;

		for (i = 0; i < 8; i++)
			if (base + i < rg->rowCount && ((mask[b] >> i) & 1))
				deleted++;
	}

	pfree(mask);
	return deleted;
}

/*
 * columnar_fill_native_metadata_agg
 *		Answer an ungrouped, unfiltered aggregate over a native (PGCN v1) table
 *		from its whole-chunk zone maps (native spec 7.1, D5b): count(*) from
 *		row-group row counts, count(col) and the avg count from value_count, sum
 *		and the avg sum from the zone int sum (int2/int4), and min/max from the
 *		zone min/max. The upper-path hook adds this path only when every aggregate
 *		is so answerable and there is no filter.
 *
 *		Deletes are handled per row group rather than per storage (issue #149). A
 *		zone map describes every row written into its group, deleted ones
 *		included, so a group with deletes cannot be folded from its zone map. It
 *		used to be that one deleted row anywhere disabled this path for the whole
 *		table, and a six-million-row table lost a 0.02 ms count(*) to a 222 ms scan
 *		because a single row was gone. Deletion is a property of a group, so the
 *		decision belongs there: clean groups fold from their zone maps, and only
 *		the groups that actually have deletes are read.
 *
 *		Returns the groups that must be scanned, by group number, with *ndirty set
 *		to their count. A count(*)-only query never returns any: count(*) over a
 *		group is rowCount minus the deleted count, which is exact and needs no
 *		data pages even when the group has deletes.
 */
static uint64 *
columnar_fill_native_metadata_agg(ColumnarAggScanState *state, int *ndirty)
{
	EState	   *estate = state->css.ss.ps.state;
	Relation	rel;
	TupleDesc	tupdesc;
	Snapshot	snap;
	uint64		storageId;
	List	   *groups;
	ListCell   *lc;
	bool		needZones = false;
	bool		anyDeletes;
	uint64	   *dirty;
	int			na;

	/*
	 * count(*) comes from the row group's own stored row count. Every other
	 * aggregate here reads a zone map, and reading them means one catalog lookup
	 * per row group returning an entry for every column, whether the query names
	 * that column or not. For a count(*) on its own that is all waste, and it is
	 * the whole cost of the query: at 6,000,000 rows and the default limits it
	 * measured 5.2 ms over 40 row groups, and 1.4 ms over 10 (issue #133).
	 */
	for (na = 0; na < state->naggs; na++)
	{
		if (state->specs[na].kind != COLUMNAR_AGG_COUNT_STAR)
		{
			needZones = true;
			break;
		}
	}

	ColumnarFlushWriteStateForRelation(state->relid);
	rel = table_open(state->relid, AccessShareLock);
	tupdesc = RelationGetDescr(rel);
	snap = ColumnarCatalogSnapshot(estate->es_snapshot);
	storageId = ColumnarStorageId(rel);

	/*
	 * One storage-wide probe first. When nothing is deleted no group can have
	 * deletes, so the per-group delete lookup below is pure cost; skipping it
	 * keeps a clean table at exactly the catalog traffic it had before this
	 * change, which for a count(*) is the row group list and nothing else.
	 */
	anyDeletes = ColumnarStorageHasDeleteVector(storageId, snap);

	groups = ColumnarReadRowGroupList(storageId, snap);
	dirty = palloc(sizeof(uint64) * (list_length(groups) > 0
									 ? list_length(groups) : 1));
	*ndirty = 0;

	foreach(lc, groups)
	{
		NativeRowGroupMetadata *rg = (NativeRowGroupMetadata *) lfirst(lc);
		NativeZoneMapMetadata **byCol = NULL;
		uint64		deleted = 0;
		int			a;

		if (anyDeletes)
			deleted = columnar_group_deleted_count(storageId, rg, snap);

		if (deleted > 0)
		{
			/*
			 * This group's zone maps describe deleted rows too, so they cannot
			 * answer anything that reads a value. count(*) is the exception: the
			 * live row count is exactly rowCount - deleted, so a count(*)-only
			 * query stays on metadata even here. Anything else defers the whole
			 * group to the scan, which folds every aggregate for it -- including
			 * count(*), so nothing is counted twice.
			 */
			if (!needZones)
			{
				for (a = 0; a < state->naggs; a++)
				{
					Assert(state->specs[a].kind == COLUMNAR_AGG_COUNT_STAR);
					state->specs[a].count += (int64) (rg->rowCount - deleted);
				}
			}
			else
				dirty[(*ndirty)++] = rg->groupNumber;
			continue;
		}

		if (needZones)
		{
			List	   *zones = ColumnarReadZoneMapList(storageId,
														rg->groupNumber, snap);
			ListCell   *zc;

			byCol = palloc0(sizeof(NativeZoneMapMetadata *) * tupdesc->natts);
			foreach(zc, zones)
			{
				NativeZoneMapMetadata *z = (NativeZoneMapMetadata *) lfirst(zc);

				if (z->columnIndex >= 0 && z->columnIndex < tupdesc->natts)
					byCol[z->columnIndex] = z;
			}
		}

		/*
		 * A column added by ALTER TABLE ADD COLUMN has no chunk, and so no zone
		 * map, in any row group written before it existed. Its value for those
		 * rows is the attribute's missing value, which the reader supplies
		 * through getmissingattr -- but a zone map cannot, because there is
		 * none. Folding such a group from its zone maps silently dropped every
		 * one of those rows: count(col) came back 0 where a scan returned the
		 * full row count, and sum, min and max came back null.
		 *
		 * Rather than reconstruct the missing value here, the group joins the
		 * ones that have to be read. The scan path already produces missing
		 * values correctly, and a group predating the column is exactly a group
		 * whose contents the metadata cannot describe.
		 */
		if (needZones)
		{
			bool		missingColumn = false;

			for (a = 0; a < state->naggs; a++)
			{
				int			ai = state->specs[a].attidx;

				if (state->specs[a].kind == COLUMNAR_AGG_COUNT_STAR)
					continue;
				if (ai < 0 || ai >= tupdesc->natts)
					continue;
				if (byCol[ai] == NULL)
				{
					missingColumn = true;
					break;
				}
			}

			if (missingColumn)
			{
				dirty[(*ndirty)++] = rg->groupNumber;
				continue;
			}
		}

		for (a = 0; a < state->naggs; a++)
		{
			ColumnarAggSpec *spec = &state->specs[a];
			NativeZoneMapMetadata *z =
				(byCol != NULL && spec->attidx >= 0 &&
				 spec->attidx < tupdesc->natts)
				? byCol[spec->attidx] : NULL;

			switch (spec->kind)
			{
				case COLUMNAR_AGG_COUNT_STAR:
					spec->count += (int64) rg->rowCount;
					break;
				case COLUMNAR_AGG_COUNT_COL:
					if (z != NULL)
						spec->count += (int64) z->valueCount;
					break;
				case COLUMNAR_AGG_SUM_INT:
					if (z != NULL && z->hasSum)
					{
						spec->sum += DatumGetInt64(
							DirectFunctionCall1(numeric_int8, z->sum));
						if (z->valueCount > 0)
							spec->sawValue = true;
					}
					break;
				case COLUMNAR_AGG_AVG_INT:
					if (z != NULL)
					{
						if (z->hasSum)
							spec->sum += DatumGetInt64(
								DirectFunctionCall1(numeric_int8, z->sum));
						spec->count += (int64) z->valueCount;
					}
					break;
				case COLUMNAR_AGG_MIN:
				case COLUMNAR_AGG_MAX:
					if (z != NULL && z->hasMinMax)
					{
						Form_pg_attribute att = TupleDescAttr(tupdesc, spec->attidx);
						MemoryContext oldcx =
							MemoryContextSwitchTo(state->resultContext);
						char	   *cur = (spec->kind == COLUMNAR_AGG_MIN)
							? (char *) z->minimum : (char *) z->maximum;
						Datum		v = ColumnarDecodeValue(att, &cur,
														state->resultContext);

						if (!spec->sawValue)
						{
							spec->extreme = v;
							spec->sawValue = true;
						}
						else
						{
							int32		c = DatumGetInt32(
								FunctionCall2Coll(&spec->cmpFn, spec->collation,
												  v, spec->extreme));

							if ((spec->kind == COLUMNAR_AGG_MIN && c < 0) ||
								(spec->kind == COLUMNAR_AGG_MAX && c > 0))
								spec->extreme = v;
						}
						MemoryContextSwitchTo(oldcx);
					}
					break;
				default:

					/*
					 * The extended int8/float/numeric sum/avg kinds are produced
					 * only for the grouped path; the ungrouped classifier rejects
					 * them, so they never reach this metadata fold.
					 */
					Assert(false);
					break;
			}
		}
	}

	table_close(rel, AccessShareLock);
	return dirty;
}

/* -------------------------------------------------------------------------
 * ungrouped batch fold (#289)
 *
 * The row-at-a-time path materializes every projected column into a Datum tuple,
 * resets a per-row memory context, and hands the tuple to ExecQual and the fold,
 * once per row. For a full-scan ungrouped aggregate that per-row tax is the whole
 * cost. The batch fold instead walks each loaded group's packed value streams,
 * evaluates a pushable WHERE inline, and folds each surviving value through the
 * same columnar_apply_one -- so accumulators are byte-identical to the row path,
 * floats included -- with none of the per-row Datum, context, or executor cost.
 * It runs only when every aggregate and the whole WHERE are batch-eligible; a
 * false return means it folded nothing and the caller runs the always-correct
 * row path.
 * ------------------------------------------------------------------------- */

/* PostgreSQL's float total order: NaN sorts above every non-NaN, NaN == NaN, and
 * -0.0 == 0.0, matching float8_cmp_internal so an inline compare equals the
 * operator ExecQual would call. */
static inline int
columnar_batch_float_cmp(double a, double b)
{
	if (isnan(a))
		return isnan(b) ? 0 : 1;
	if (isnan(b))
		return -1;
	return (a < b) ? -1 : (a > b) ? 1 : 0;
}

/* Whether one fixed-width numeric column value (known non-null) satisfies one
 * btree scan key. */
static bool
columnar_batch_key_pass(Oid coltype, Datum val, StrategyNumber strat, Datum arg)
{
	int			c;

	switch (coltype)
	{
		case INT2OID:
			{ int16 a = DatumGetInt16(val), b = DatumGetInt16(arg); c = (a < b) ? -1 : (a > b) ? 1 : 0; break; }
		case INT4OID:
			{ int32 a = DatumGetInt32(val), b = DatumGetInt32(arg); c = (a < b) ? -1 : (a > b) ? 1 : 0; break; }
		case INT8OID:
			{ int64 a = DatumGetInt64(val), b = DatumGetInt64(arg); c = (a < b) ? -1 : (a > b) ? 1 : 0; break; }
		case FLOAT4OID:
			c = columnar_batch_float_cmp((double) DatumGetFloat4(val), (double) DatumGetFloat4(arg)); break;
		case FLOAT8OID:
			c = columnar_batch_float_cmp(DatumGetFloat8(val), DatumGetFloat8(arg)); break;
		default:
			return false;
	}
	switch (strat)
	{
		case BTLessStrategyNumber: return c < 0;
		case BTLessEqualStrategyNumber: return c <= 0;
		case BTEqualStrategyNumber: return c == 0;
		case BTGreaterEqualStrategyNumber: return c >= 0;
		case BTGreaterStrategyNumber: return c > 0;
		default: return false;
	}
}

/* A fixed-width by-value numeric column type the batch fold can read directly. */
static bool
columnar_batch_type_ok(Oid typ)
{
	return typ == INT2OID || typ == INT4OID || typ == INT8OID ||
		typ == FLOAT4OID || typ == FLOAT8OID;
}

/* An aggregate kind the batch fold accumulates (folded via columnar_apply_one
 * over a fixed-width by-value numeric column, or count). int8/numeric sum/avg and
 * min/max stay on the row path. */
static bool
columnar_batch_agg_ok(ColumnarAggKind kind)
{
	switch (kind)
	{
		case COLUMNAR_AGG_COUNT_STAR:
		case COLUMNAR_AGG_COUNT_COL:
		case COLUMNAR_AGG_SUM_INT:
		case COLUMNAR_AGG_AVG_INT:
		case COLUMNAR_AGG_SUM_FLOAT:
		case COLUMNAR_AGG_AVG_FLOAT:
			return true;
		default:
			return false;
	}
}

/*
 * columnar_batch_shape_eligible
 *		Whether this aggregate's shape can use the batch fold: every aggregate is
 *		batch-accumulable, the whole WHERE converts to scan keys (no residual), and
 *		every key is a supported btree comparison on a batch-readable column. When
 *		keysOut is non-NULL the built scan keys are returned for the fold to reuse;
 *		otherwise they are only inspected. Deterministic from the query shape, so
 *		Begin can report it in EXPLAIN before execution.
 */
static bool
columnar_batch_shape_eligible(ColumnarAggScanState *state, TupleDesc tupdesc,
							  ScanKey *keysOut, int *nkeysOut)
{
	ScanKey		keys;
	int			nkeys = 0;
	int			npred;
	bool		allConvertible;
	int			a;
	int			k;
	bool		ok = true;

	for (a = 0; a < state->naggs; a++)
		if (!columnar_batch_agg_ok(state->specs[a].kind))
			return false;

	ColumnarCountConvertibleQuals(state->quals, state->scanrelid, tupdesc,
								  &npred, &allConvertible);
	if (!allConvertible)
		return false;

	keys = ColumnarBuildScanKeys(state->quals, state->scanrelid, tupdesc, &nkeys);
	for (k = 0; k < nkeys; k++)
	{
		ScanKey		key = &keys[k];
		int			attidx = key->sk_attno - 1;
		Oid			coltype;

		if (key->sk_flags != 0 || attidx < 0 || attidx >= tupdesc->natts)
			{ ok = false; break; }
		coltype = TupleDescAttr(tupdesc, attidx)->atttypid;
		if (!columnar_batch_type_ok(coltype))
			{ ok = false; break; }
		if (key->sk_subtype != InvalidOid && key->sk_subtype != coltype)
			{ ok = false; break; }
		if (key->sk_strategy < BTLessStrategyNumber ||
			key->sk_strategy > BTGreaterStrategyNumber)
			{ ok = false; break; }
	}
	if (!ok)
		return false;

	if (keysOut != NULL)
	{
		*keysOut = keys;
		*nkeysOut = nkeys;
	}
	return true;
}

/* Reset the accumulators to their initial state (for a clean fall-back). */
static void
columnar_agg_specs_reset(ColumnarAggScanState *state)
{
	int			a;

	MemoryContextReset(state->resultContext);
	for (a = 0; a < state->naggs; a++)
	{
		ColumnarAggSpec *spec = &state->specs[a];

		spec->count = 0;
		spec->sum = 0;
		spec->sawValue = false;
		spec->extreme = (Datum) 0;
		spec->fsum = 0;
		spec->fsxx = 0;
		spec->nsum = (Datum) 0;
		spec->nsumSet = false;
	}
}

/*
 * columnar_native_batch_fold
 *		Fold the whole scan column-at-a-time. Returns false (having folded and
 *		reset nothing that the caller cannot redo) when the shape is not eligible
 *		or a group is missing a needed column, so the caller runs the row path.
 */
static bool
columnar_native_batch_fold(ColumnarAggScanState *state, Relation rel,
						   TupleDesc tupdesc)
{
	EState	   *estate = state->css.ss.ps.state;
	ScanKey		keys = NULL;
	int			nkeys = 0;
	int			a;
	int			k;
	int			col;
	int			natts = tupdesc->natts;
	ColumnarReadState *rs;
	const char **cvalidity = (const char **) palloc0(sizeof(char *) * natts);
	const char **cpacked = (const char **) palloc0(sizeof(char *) * natts);
	int16	   *cattlen = (int16 *) palloc0(sizeof(int16) * natts);
	uint64	   *cpresent = (uint64 *) palloc0(sizeof(uint64) * natts);
	bool	   *cneeded = (bool *) palloc0(sizeof(bool) * natts);
	Datum	   *cval = (Datum *) palloc0(sizeof(Datum) * natts);
	bool	   *cisnull = (bool *) palloc0(sizeof(bool) * natts);

	if (!columnar_batch_shape_eligible(state, tupdesc, &keys, &nkeys))
		return false;

	col = -1;
	while ((col = bms_next_member(state->projected, col)) >= 0)
		if (col >= 0 && col < natts)
			cneeded[col] = true;

	/*
	 * No scan keys are pushed to the reader: the WHERE is applied inline per value
	 * below. For a zone-map-selective filter, pushing keys would also prune whole
	 * vectors; that is a later refinement (it needs present-index skipping) and
	 * only helps a filter the vector min/max can rule out.
	 */
	rs = ColumnarBeginRead(rel, estate->es_snapshot, NULL, state->projected, 0, NULL);

	while (ColumnarReadFoldNextGroup(rs))
	{
		uint64		nrows;
		const char *dmask;
		uint32		dlen;
		const bool *skipVec;
		const uint32 *vecStart;
		int			vcount;
		uint64		r;

		ColumnarReadFoldGroupInfo(rs, &nrows, &dmask, &dlen,
								  &skipVec, &vecStart, &vcount);

		for (col = 0; col < natts; col++)
		{
			const char *vbits;
			const char *pk;
			int16		al;
			const uint32 *vrl;

			cpresent[col] = 0;
			if (!cneeded[col])
				continue;
			if (!ColumnarReadFoldColumn(rs, col, &vbits, &pk, &al, &vrl))
			{
				/*
				 * The column is absent from this group (a later ADD COLUMN). The
				 * batch path cannot supply its missing value, so reset and fall
				 * back to the row path for the whole scan, which handles it.
				 */
				ColumnarEndRead(rs);
				columnar_agg_specs_reset(state);
				return false;
			}
			cvalidity[col] = vbits;
			cpacked[col] = pk;
			cattlen[col] = al;
		}

		for (r = 0; r < nrows; r++)
		{
			bool		del;
			bool		pass = true;

			CHECK_FOR_INTERRUPTS();

			/* gather needed values at each column's present index; advance it */
			for (col = 0; col < natts; col++)
			{
				if (!cneeded[col])
					continue;
				if ((cvalidity[col][r >> 3] >> (r & 7)) & 1)
				{
					cval[col] = fetch_att(cpacked[col] + cpresent[col] * cattlen[col],
										  true, cattlen[col]);
					cisnull[col] = false;
					cpresent[col]++;
				}
				else
					cisnull[col] = true;
			}

			del = (dmask != NULL && (r >> 3) < dlen &&
				   (dmask[r >> 3] & (1 << (r & 7))) != 0);
			if (del)
				continue;			/* value slots already consumed above */

			for (k = 0; k < nkeys; k++)
			{
				ScanKey		key = &keys[k];
				int			attidx = key->sk_attno - 1;

				if (cisnull[attidx] ||
					!columnar_batch_key_pass(TupleDescAttr(tupdesc, attidx)->atttypid,
											 cval[attidx], key->sk_strategy,
											 key->sk_argument))
				{
					pass = false;
					break;
				}
			}
			if (!pass)
				continue;

			for (a = 0; a < state->naggs; a++)
			{
				ColumnarAggSpec *spec = &state->specs[a];

				if (spec->attidx >= 0)
					columnar_apply_one(state->resultContext, spec,
									   cval[spec->attidx], cisnull[spec->attidx]);
				else
					columnar_apply_one(state->resultContext, spec, (Datum) 0, true);
			}
		}
	}

	ColumnarReadStats(rs, &state->groupsRead, &state->groupsSkipped,
					  &state->groupsTotal);
	state->haveStats = true;
	state->batchFolded = true;
	ColumnarEndRead(rs);
	return true;
}

/*
 * columnar_native_scan_agg
 *		Fold an ungrouped, unfiltered aggregate over a native table by scanning it
 *		one row at a time (ColumnarReadNextRow applies the delete mask), for the
 *		case where the zone-map-only path cannot be used because the storage has
 *		deletes (D6b). No quals: the upper-path hook only adds the native agg path
 *		when there is no filter.
 *
 *		When restrictGroups is non-NULL the scan is confined to those row groups
 *		(issue #149), so only the groups that have deletes are read; the rest were
 *		already folded from their zone maps by the caller.
 */
static void
columnar_native_scan_agg(ColumnarAggScanState *state,
						 const uint64 *restrictGroups, int nRestrictGroups)
{
	EState	   *estate = state->css.ss.ps.state;
	ExprContext *econtext = state->css.ss.ps.ps_ExprContext;
	Relation	rel = table_open(state->relid, AccessShareLock);
	TupleDesc	tupdesc = RelationGetDescr(rel);
	Bitmapset  *projected;
	ColumnarReadState *rs;
	ScanKey		keys = NULL;
	int			nScanKeys = 0;
	Datum	   *values = (Datum *) palloc(sizeof(Datum) * tupdesc->natts);
	bool	   *nulls = (bool *) palloc(sizeof(bool) * tupdesc->natts);
	uint64		rowNumber;
	int			a;

	/*
	 * Scan-fold mode carries the projected set (aggregate plus WHERE columns) and
	 * a base slot for the per-row recheck; the dirty-groups metadata path passes
	 * neither and projects only the aggregate columns.
	 */
	if (state->scanFold)
		projected = state->projected;
	else
	{
		projected = NULL;
		for (a = 0; a < state->naggs; a++)
			if (state->specs[a].attidx >= 0)
				projected = bms_add_member(projected, state->specs[a].attidx);
		if (projected == NULL)
			projected = bms_make_singleton(0);	/* count(*) only: one column */
	}

	ColumnarFlushWriteStateForRelation(state->relid);
	ColumnarFlushDeleteVectorForRelation(rel);

	/*
	 * Batch fold when the shape allows it (#289): the whole scan folds
	 * column-at-a-time, which is the point of this path. Only the full scan uses
	 * it; the dirty-groups metadata tail (restrictGroups != NULL) stays on the
	 * row path.
	 */
	if (state->scanFold && restrictGroups == NULL &&
		columnar_native_batch_fold(state, rel, tupdesc))
	{
		table_close(rel, AccessShareLock);
		return;
	}

	/* push the WHERE down for group and vector pruning; the recheck is exact */
	if (state->scanFold && state->quals != NIL)
		keys = ColumnarBuildScanKeys(state->quals, state->scanrelid, tupdesc,
									 &nScanKeys);

	rs = ColumnarBeginRead(rel, estate->es_snapshot, NULL, projected,
						   nScanKeys, keys);
	if (restrictGroups != NULL)
		ColumnarReadRestrictToGroups(rs, restrictGroups, nRestrictGroups);

	/* columns outside the projection stay null in the recheck slot */
	if (state->whereState != NULL)
		memset(state->baseSlot->tts_isnull, true, sizeof(bool) * tupdesc->natts);

	while (ColumnarReadNextRow(rs, values, nulls, &rowNumber))
	{
		/*
		 * Recheck the whole WHERE per row: the scan keys only prune groups and
		 * vectors, so a surviving row may still fail the predicate.
		 */
		if (state->whereState != NULL)
		{
			int			x = -1;

			ResetExprContext(econtext);
			ExecClearTuple(state->baseSlot);
			while ((x = bms_next_member(state->projected, x)) >= 0)
			{
				state->baseSlot->tts_values[x] = values[x];
				state->baseSlot->tts_isnull[x] = nulls[x];
			}
			ExecStoreVirtualTuple(state->baseSlot);
			econtext->ecxt_scantuple = state->baseSlot;
			if (!ExecQual(state->whereState, econtext))
				continue;
		}

		for (a = 0; a < state->naggs; a++)
		{
			ColumnarAggSpec *spec = &state->specs[a];

			if (spec->attidx >= 0)
				columnar_apply_one(state->resultContext, spec,
								   values[spec->attidx], nulls[spec->attidx]);
			else
				columnar_apply_one(state->resultContext, spec, (Datum) 0, true);
		}
	}

	if (state->scanFold)
	{
		ColumnarReadStats(rs, &state->groupsRead, &state->groupsSkipped,
						  &state->groupsTotal);
		state->haveStats = true;
	}

	ColumnarEndRead(rs);
	table_close(rel, AccessShareLock);
}

static TupleTableSlot *
ColumnarExecAggScan(CustomScanState *node)
{
	ColumnarAggScanState *state = (ColumnarAggScanState *) node;
	TupleTableSlot *scanSlot = node->ss.ss_ScanTupleSlot;
	ExprContext *econtext = node->ss.ps.ps_ExprContext;
	TupleTableSlot *result;
	int			a;
	Relation	frel;
	uint64	   *dirtyGroups;
	int			nDirtyGroups;

	if (state->done)
		return NULL;
	state->done = true;

	/*
	 * A native table answers from zone maps (native spec 7.1): the upper-path
	 * hook added this path only when every aggregate is zone-map answerable and
	 * there is no filter. A zone map covers deleted rows too, so a row group with
	 * deletes cannot be folded from it; those groups are scanned instead, and only
	 * those (issue #149).
	 *
	 * The delete vector must be flushed before any of this. A delete made earlier
	 * in this transaction can still be sitting in the per-relation buffer, and a
	 * group whose deletes are unflushed reads as clean -- which would fold it from
	 * a zone map that counts the rows this transaction has already removed.
	 */
	frel = table_open(state->relid, AccessShareLock);
	ColumnarFlushWriteStateForRelation(state->relid);
	ColumnarFlushDeleteVectorForRelation(frel);
	table_close(frel, AccessShareLock);

	if (state->scanFold)
	{
		/*
		 * A filter, or a sum/avg no zone map answers (#289): scan every row once
		 * and fold it. columnar_native_scan_agg builds the scan keys, rechecks the
		 * WHERE, and captures the EXPLAIN stats.
		 */
		columnar_native_scan_agg(state, NULL, 0);
	}
	else
	{
		dirtyGroups = columnar_fill_native_metadata_agg(state, &nDirtyGroups);
		if (nDirtyGroups > 0)
			columnar_native_scan_agg(state, dirtyGroups, nDirtyGroups);
		state->haveStats = false;
	}

	/* build the single result row from the finalized aggregates */
	ExecClearTuple(scanSlot);
	for (a = 0; a < state->naggs; a++)
		scanSlot->tts_values[a] =
			columnar_agg_finalize(&state->specs[a], &scanSlot->tts_isnull[a]);
	ExecStoreVirtualTuple(scanSlot);

	/*
	 * Project to the result tuple when the executor built a projection; when the
	 * output matches the scan tuple exactly it left ps_ProjInfo NULL and the scan
	 * slot is the result.
	 */
	if (node->ss.ps.ps_ProjInfo != NULL)
	{
		econtext->ecxt_scantuple = scanSlot;
		result = ExecProject(node->ss.ps.ps_ProjInfo);
	}
	else
		result = scanSlot;

	return result;
}

static void
ColumnarEndAggScan(CustomScanState *node)
{
	ColumnarAggScanState *state = (ColumnarAggScanState *) node;

	if (state->baseSlot != NULL)
		ExecDropSingleTupleTableSlot(state->baseSlot);
	state->baseSlot = NULL;
	/* the reader is ended inside ColumnarExecAggScan; the memory contexts are
	 * children of es_query_cxt and freed with it */
}

static void
ColumnarReScanAggScan(CustomScanState *node)
{
	ColumnarAggScanState *state = (ColumnarAggScanState *) node;
	int			a;

	state->done = false;
	state->haveStats = false;
	state->batchFolded = false;
	MemoryContextReset(state->resultContext);
	for (a = 0; a < state->naggs; a++)
	{
		ColumnarAggSpec *spec = &state->specs[a];

		spec->count = 0;
		spec->sum = 0;
		spec->sawValue = false;
		spec->extreme = (Datum) 0;
		/*
		 * Also clear the running float/numeric accumulators. resultContext was
		 * just reset, so nsum's storage is gone; leaving nsumSet true would make
		 * the next scan add to (and free) a dangling pointer. Scan-fold mode
		 * classifies these extended kinds (#289), so this reset is load-bearing on
		 * a rescan, not only defensive.
		 */
		spec->fsum = 0;
		spec->fsxx = 0;
		spec->nsum = (Datum) 0;
		spec->nsumSet = false;
	}
}

static void
ColumnarExplainAggScan(CustomScanState *node, List *ancestors, ExplainState *es)
{
	ColumnarAggScanState *state = (ColumnarAggScanState *) node;

	ExplainPropertyInteger("Columnar Vectorized Aggregates", NULL,
						   state->naggs, es);
	ExplainPropertyInteger("Columnar Pushed-Down Filters", NULL,
						   state->npreds, es);
	if (state->scanFold)
		ExplainPropertyText("Columnar Batch Fold",
							state->batchEligible ? "yes" : "no", es);

	if (state->haveStats)
	{
		ExplainPropertyInteger("Columnar Chunk Groups Total", NULL,
							   (int64) state->groupsTotal, es);
		ExplainPropertyInteger("Columnar Chunk Groups Read", NULL,
							   (int64) state->groupsRead, es);
		ExplainPropertyInteger("Columnar Chunk Groups Removed by Filter", NULL,
							   (int64) state->groupsSkipped, es);
	}
}

static const CustomExecMethods columnar_agg_exec_methods = {
	.CustomName = "ColumnarScan",
	.BeginCustomScan = ColumnarBeginAggScan,
	.ExecCustomScan = ColumnarExecAggScan,
	.EndCustomScan = ColumnarEndAggScan,
	.ReScanCustomScan = ColumnarReScanAggScan,
	.ExplainCustomScan = ColumnarExplainAggScan,
};

/* -------------------------------------------------------------------------
 * grouped vectorized aggregate (#289): execution
 * ------------------------------------------------------------------------- */

Node *
ColumnarCreateGroupAggScanState(CustomScan *cscan)
{
	ColumnarGroupAggScanState *state =
		(ColumnarGroupAggScanState *) palloc0(sizeof(ColumnarGroupAggScanState));
	List	   *groupKeys;
	List	   *outMapList;
	ListCell   *lc;
	int			i;
	int			naggs = 0;

	state->css.ss.ps.type = T_CustomScanState;
	state->css.methods = &columnar_groupagg_exec_methods;

	/* custom_private: rti, quals, relid, group-key exprs, output map (length 5) */
	state->scanrelid = (Index) intVal(linitial(cscan->custom_private));
	state->quals = (List *) lsecond(cscan->custom_private);
	state->relid =
		DatumGetObjectId(((Const *) lthird(cscan->custom_private))->constvalue);
	groupKeys = (List *) lfourth(cscan->custom_private);
	outMapList = (List *) list_nth(cscan->custom_private, 4);

	state->nkeys = list_length(groupKeys);
	state->keys = (ColumnarGroupKey *)
		palloc0(sizeof(ColumnarGroupKey) * Max(state->nkeys, 1));
	i = 0;
	foreach(lc, groupKeys)
		state->keys[i++].expr = (Expr *) lfirst(lc);

	/* rebuild the aggregate template from the output tuple's aggregates */
	foreach(lc, cscan->custom_scan_tlist)
		if (IsA(((TargetEntry *) lfirst(lc))->expr, Aggref))
			naggs++;
	state->naggs = naggs;
	state->aggTemplate = (ColumnarAggSpec *)
		palloc0(sizeof(ColumnarAggSpec) * Max(naggs, 1));
	i = 0;
	foreach(lc, cscan->custom_scan_tlist)
	{
		TargetEntry *tle = (TargetEntry *) lfirst(lc);

		if (IsA(tle->expr, Aggref))
		{
			(void) columnar_classify_aggref((Aggref *) tle->expr, -1, true,
											&state->aggTemplate[i]);
			i++;
		}
	}

	state->nout = list_length(outMapList);
	state->outMap = (int *) palloc(sizeof(int) * Max(state->nout, 1));
	i = 0;
	foreach(lc, outMapList)
		state->outMap[i++] = intVal(lfirst(lc));

	state->maxGroups = columnar_groupagg_max_groups;
	state->capacity = 0;
	state->nGroups = 0;
	state->entries = NULL;

	return (Node *) state;
}

static void
ColumnarBeginGroupAggScan(CustomScanState *node, EState *estate, int eflags)
{
	ColumnarGroupAggScanState *state = (ColumnarGroupAggScanState *) node;
	Relation	rel;
	TupleDesc	basedesc;
	Bitmapset  *proj = NULL;
	Bitmapset  *projected = NULL;
	List	   *keyExprList = NIL;
	bool		allConvertible;
	int			k;
	int			a;
	int			x;

	state->specContext = AllocSetContextCreate(estate->es_query_cxt,
											   "columnar groupagg specs",
											   ALLOCSET_SMALL_SIZES);
	state->keyContext = AllocSetContextCreate(estate->es_query_cxt,
											  "columnar groupagg keys",
											  ALLOCSET_SMALL_SIZES);
	state->hashContext = AllocSetContextCreate(estate->es_query_cxt,
											   "columnar groupagg table",
											   ALLOCSET_DEFAULT_SIZES);
	state->started = false;
	state->emitPos = 0;
	state->nGroups = 0;
	state->capacity = 0;
	state->entries = NULL;
	state->haveStats = false;

	rel = table_open(state->relid, AccessShareLock);
	basedesc = RelationGetDescr(rel);

	/*
	 * Count pushable filters for EXPLAIN before the EXPLAIN-only early return, so
	 * a plain EXPLAIN reports the real pushed-down filter count instead of 0.
	 */
	ColumnarCountConvertibleQuals(state->quals, state->scanrelid, basedesc,
								  &state->npreds, &allConvertible);

	if (eflags & EXEC_FLAG_EXPLAIN_ONLY)
	{
		table_close(rel, AccessShareLock);
		return;
	}

	/* guard the native format before decoding any value (#240) */
	ColumnarCheckNativeFormatVersion(ColumnarStorageId(rel),
									 RelationGetRelationName(rel));

	/* a virtual slot holding each read row for key and qual evaluation */
	state->baseSlot = MakeSingleTupleTableSlot(CreateTupleDescCopy(basedesc),
											   &TTSOpsVirtual);

	/* group-key ExprStates and their hash/equality machinery */
	for (k = 0; k < state->nkeys; k++)
	{
		ColumnarGroupKey *key = &state->keys[k];
		Oid			type = exprType((Node *) key->expr);
		TypeCacheEntry *tce = lookup_type_cache(type,
												TYPECACHE_HASH_PROC_FINFO |
												TYPECACHE_EQ_OPR_FINFO);

		key->exprState = ExecInitExpr(key->expr, &node->ss.ps);
		key->type = type;
		key->collation = exprCollation((Node *) key->expr);
		get_typlenbyval(type, &key->typlen, &key->byval);
		fmgr_info_copy(&key->hashFn, &tce->hash_proc_finfo, estate->es_query_cxt);
		fmgr_info_copy(&key->eqFn, &tce->eq_opr_finfo, estate->es_query_cxt);
		keyExprList = lappend(keyExprList, key->expr);
	}

	/* residual WHERE recheck (the scan keys only prune groups) */
	state->whereState = (state->quals != NIL)
		? ExecInitQual(state->quals, &node->ss.ps)
		: NULL;

	/* finish min/max comparison setup on the per-agg template */
	for (a = 0; a < state->naggs; a++)
	{
		ColumnarAggSpec *spec = &state->aggTemplate[a];

		if (spec->kind == COLUMNAR_AGG_MIN || spec->kind == COLUMNAR_AGG_MAX)
		{
			Form_pg_attribute att = TupleDescAttr(basedesc, spec->attidx);
			TypeCacheEntry *tce = lookup_type_cache(att->atttypid,
													TYPECACHE_CMP_PROC_FINFO);

			fmgr_info_copy(&spec->cmpFn, &tce->cmp_proc_finfo,
						   estate->es_query_cxt);
			spec->collation = att->attcollation;
			spec->byval = att->attbyval;
			spec->typlen = att->attlen;
		}
	}

	/* project the columns the keys, WHERE and aggregates reference */
	pull_varattnos((Node *) keyExprList, state->scanrelid, &proj);
	pull_varattnos((Node *) state->quals, state->scanrelid, &proj);
	x = -1;
	while ((x = bms_next_member(proj, x)) >= 0)
	{
		AttrNumber	attno = x + FirstLowInvalidHeapAttributeNumber;

		if (attno > 0)
			projected = bms_add_member(projected, attno - 1);
	}
	for (a = 0; a < state->naggs; a++)
		if (state->aggTemplate[a].attidx >= 0)
			projected = bms_add_member(projected, state->aggTemplate[a].attidx);
	if (projected == NULL)
		projected = bms_make_singleton(0);	/* count(*) with no keys touched */
	state->projected = projected;

	table_close(rel, AccessShareLock);
}

/*
 * columnar_groupagg_keys_equal
 *		Whether a probing row's keys match a stored group's, by SQL grouping
 *		semantics: two nulls are equal, and non-nulls compare with the key type's
 *		equality operator (with collation) -- exactly how core groups.
 */
static bool
columnar_groupagg_keys_equal(ColumnarGroupAggScanState *state,
							 ColumnarGroupEntry *e,
							 Datum *keyvals, bool *keynulls)
{
	int			k;

	for (k = 0; k < state->nkeys; k++)
	{
		if (e->keyNulls[k] != keynulls[k])
			return false;
		if (keynulls[k])
			continue;
		if (!DatumGetBool(FunctionCall2Coll(&state->keys[k].eqFn,
											state->keys[k].collation,
											e->keys[k], keyvals[k])))
			return false;
	}
	return true;
}

/*
 * columnar_groupagg_grow
 *		Double the open-addressing table and reinsert live entries. Entry structs
 *		(and the key/spec pointers they carry) move by value; the pointed-at key
 *		Datums and accumulators stay put in their own contexts.
 */
static void
columnar_groupagg_grow(ColumnarGroupAggScanState *state)
{
	int			oldCap = state->capacity;
	int			newCap = (oldCap <= 0) ? 1024 : oldCap * 2;
	ColumnarGroupEntry *newEntries;
	MemoryContext old;
	int			i;

	if (newCap > (1 << 30))
		newCap = 1 << 30;
	if (newCap <= oldCap)
		return;					/* already at the ceiling; let probing lengthen */

	/*
	 * The table can grow past what a plain palloc allows (MaxAllocSize is 1 GB;
	 * this array reaches it well before the 1<<30 entry ceiling), so allocate it
	 * as a huge, zeroed chunk. Memory is still bounded by the actual group count
	 * via pgcolumnar.groupagg_max_groups.
	 */
	old = MemoryContextSwitchTo(state->hashContext);
	newEntries = (ColumnarGroupEntry *)
		MemoryContextAllocExtended(state->hashContext,
								   sizeof(ColumnarGroupEntry) * (Size) newCap,
								   MCXT_ALLOC_HUGE | MCXT_ALLOC_ZERO);
	MemoryContextSwitchTo(old);

	for (i = 0; i < oldCap; i++)
	{
		ColumnarGroupEntry *e = &state->entries[i];
		uint32		idx;

		if (!e->used)
			continue;
		idx = e->hash & (uint32) (newCap - 1);
		while (newEntries[idx].used)
			idx = (idx + 1) & (uint32) (newCap - 1);
		newEntries[idx] = *e;
	}

	if (state->entries != NULL)
		pfree(state->entries);
	state->entries = newEntries;
	state->capacity = newCap;
}

/*
 * columnar_groupagg_lookup
 *		Find the group for this row's keys, inserting a fresh one (with the key
 *		Datums copied into keyContext and accumulators seeded from the template)
 *		when it is new.
 */
static ColumnarGroupEntry *
columnar_groupagg_lookup(ColumnarGroupAggScanState *state,
						 Datum *keyvals, bool *keynulls)
{
	uint32		hash = 0;
	uint32		idx;
	int			k;
	ColumnarGroupEntry *e;

	/* grow before probing so the index is computed against the final table */
	if ((int64) (state->nGroups + 1) * 10 >= (int64) state->capacity * 7)
		columnar_groupagg_grow(state);

	for (k = 0; k < state->nkeys; k++)
	{
		uint32		h;

		if (keynulls[k])
			h = 0x9e3779b9u;	/* fixed contribution for a null key */
		else
			h = DatumGetUInt32(FunctionCall1Coll(&state->keys[k].hashFn,
												 state->keys[k].collation,
												 keyvals[k]));
		hash = hash_combine(hash, h);
	}

	idx = hash & (uint32) (state->capacity - 1);
	for (;;)
	{
		e = &state->entries[idx];
		if (!e->used)
			break;
		if (e->hash == hash &&
			columnar_groupagg_keys_equal(state, e, keyvals, keynulls))
			return e;
		idx = (idx + 1) & (uint32) (state->capacity - 1);
	}

	/*
	 * A new group. Bounding the actual group count keeps this no-spill hash table
	 * from growing without limit; over the cap we stop with guidance rather than
	 * exhaust memory, since the plan cannot fall back mid-scan.
	 */
	if (state->nGroups >= state->maxGroups)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("grouped vectorized aggregate exceeded pgcolumnar.groupagg_max_groups (%d)",
						state->maxGroups),
				 errhint("Raise pgcolumnar.groupagg_max_groups, or set "
						 "pgcolumnar.enable_group_vectorization = off.")));

	/* insert a new group here */
	e->used = true;
	e->hash = hash;
	{
		MemoryContext oldc = MemoryContextSwitchTo(state->keyContext);

		e->keys = (Datum *) palloc(sizeof(Datum) * Max(state->nkeys, 1));
		e->keyNulls = (bool *) palloc(sizeof(bool) * Max(state->nkeys, 1));
		for (k = 0; k < state->nkeys; k++)
		{
			e->keyNulls[k] = keynulls[k];
			if (keynulls[k])
				e->keys[k] = (Datum) 0;
			else
				e->keys[k] = datumCopy(keyvals[k], state->keys[k].byval,
									   state->keys[k].typlen);
		}
		MemoryContextSwitchTo(oldc);
	}
	{
		MemoryContext oldc = MemoryContextSwitchTo(state->specContext);

		e->specs = (ColumnarAggSpec *)
			palloc(sizeof(ColumnarAggSpec) * Max(state->naggs, 1));
		memcpy(e->specs, state->aggTemplate,
			   sizeof(ColumnarAggSpec) * state->naggs);
		MemoryContextSwitchTo(oldc);
	}
	state->nGroups++;
	return e;
}

/*
 * columnar_groupagg_build
 *		Scan the relation once and fold every surviving row into its group. The
 *		reader prunes groups and vectors with the pushed-down WHERE; each row is
 *		rechecked against the whole WHERE, its keys evaluated, and its values
 *		folded in scan order so accumulators match the scalar Agg byte for byte.
 */
static void
columnar_groupagg_build(ColumnarGroupAggScanState *state)
{
	EState	   *estate = state->css.ss.ps.state;
	ExprContext *econtext = state->css.ss.ps.ps_ExprContext;
	Relation	rel = table_open(state->relid, AccessShareLock);
	TupleDesc	basedesc = RelationGetDescr(rel);
	int			natts = basedesc->natts;
	Datum	   *values = (Datum *) palloc(sizeof(Datum) * natts);
	bool	   *nulls = (bool *) palloc(sizeof(bool) * natts);
	Datum	   *keyvals = (Datum *) palloc(sizeof(Datum) * Max(state->nkeys, 1));
	bool	   *keynulls = (bool *) palloc(sizeof(bool) * Max(state->nkeys, 1));
	ColumnarReadState *rs;
	ScanKey		keys;
	int			nScanKeys = 0;
	uint64		rowNumber;

	ColumnarFlushWriteStateForRelation(state->relid);
	ColumnarFlushDeleteVectorForRelation(rel);

	keys = ColumnarBuildScanKeys(state->quals, state->scanrelid, basedesc,
								 &nScanKeys);
	rs = ColumnarBeginRead(rel, estate->es_snapshot, NULL, state->projected,
						   nScanKeys, keys);

	/* columns outside the projection stay null in the base slot */
	memset(state->baseSlot->tts_isnull, true, sizeof(bool) * natts);

	while (ColumnarReadNextRow(rs, values, nulls, &rowNumber))
	{
		int			x;
		int			k;
		int			a;
		ColumnarGroupEntry *e;

		ResetExprContext(econtext);

		/* stage the projected columns into the base slot */
		ExecClearTuple(state->baseSlot);
		x = -1;
		while ((x = bms_next_member(state->projected, x)) >= 0)
		{
			state->baseSlot->tts_values[x] = values[x];
			state->baseSlot->tts_isnull[x] = nulls[x];
		}
		ExecStoreVirtualTuple(state->baseSlot);
		econtext->ecxt_scantuple = state->baseSlot;

		/* recheck the full WHERE against this row */
		if (state->whereState != NULL && !ExecQual(state->whereState, econtext))
			continue;

		/*
		 * Evaluate the group keys in the per-tuple context (reset each row at the
		 * top of this loop), not the query context ExecEvalExpr would use, so a
		 * byref key does not leak one allocation per scanned row. Datums that
		 * start a new group are datumCopy'd into keyContext by the lookup.
		 */
		for (k = 0; k < state->nkeys; k++)
			keyvals[k] = ExecEvalExprSwitchContext(state->keys[k].exprState,
												   econtext, &keynulls[k]);

		e = columnar_groupagg_lookup(state, keyvals, keynulls);

		/* fold this row's values into the group's accumulators */
		for (a = 0; a < state->naggs; a++)
		{
			ColumnarAggSpec *spec = &e->specs[a];

			if (spec->attidx >= 0)
				columnar_apply_one(state->specContext, spec,
								   values[spec->attidx], nulls[spec->attidx]);
			else
				columnar_apply_one(state->specContext, spec, (Datum) 0, true);
		}
	}

	ColumnarReadStats(rs, &state->groupsRead, &state->groupsSkipped,
					  &state->groupsTotal);
	state->haveStats = true;

	ColumnarEndRead(rs);
	table_close(rel, AccessShareLock);
}

static TupleTableSlot *
ColumnarExecGroupAggScan(CustomScanState *node)
{
	ColumnarGroupAggScanState *state = (ColumnarGroupAggScanState *) node;
	TupleTableSlot *scanSlot = node->ss.ss_ScanTupleSlot;
	ExprContext *econtext = node->ss.ps.ps_ExprContext;

	if (!state->started)
	{
		columnar_groupagg_build(state);
		state->started = true;
		state->emitPos = 0;
	}

	while (state->emitPos < state->capacity)
	{
		ColumnarGroupEntry *e = &state->entries[state->emitPos++];
		int			p;

		if (!e->used)
			continue;

		ResetExprContext(econtext);
		ExecClearTuple(scanSlot);
		for (p = 0; p < state->nout; p++)
		{
			int			m = state->outMap[p];

			if (m >= 0)
			{
				scanSlot->tts_values[p] = e->keys[m];
				scanSlot->tts_isnull[p] = e->keyNulls[m];
			}
			else
			{
				int			a = -(m) - 1;

				scanSlot->tts_values[p] =
					columnar_agg_finalize(&e->specs[a], &scanSlot->tts_isnull[p]);
			}
		}
		ExecStoreVirtualTuple(scanSlot);

		if (node->ss.ps.ps_ProjInfo != NULL)
		{
			econtext->ecxt_scantuple = scanSlot;
			return ExecProject(node->ss.ps.ps_ProjInfo);
		}
		return scanSlot;
	}

	return NULL;
}

static void
ColumnarEndGroupAggScan(CustomScanState *node)
{
	ColumnarGroupAggScanState *state = (ColumnarGroupAggScanState *) node;

	if (state->baseSlot != NULL)
		ExecDropSingleTupleTableSlot(state->baseSlot);
	state->baseSlot = NULL;
	/* the memory contexts are children of es_query_cxt and freed with it */
}

static void
ColumnarReScanGroupAggScan(CustomScanState *node)
{
	ColumnarGroupAggScanState *state = (ColumnarGroupAggScanState *) node;

	state->started = false;
	state->emitPos = 0;
	state->nGroups = 0;
	state->capacity = 0;
	state->entries = NULL;
	state->haveStats = false;
	MemoryContextReset(state->keyContext);
	MemoryContextReset(state->specContext);
	MemoryContextReset(state->hashContext);
}

static void
ColumnarExplainGroupAggScan(CustomScanState *node, List *ancestors,
							ExplainState *es)
{
	ColumnarGroupAggScanState *state = (ColumnarGroupAggScanState *) node;

	ExplainPropertyInteger("Columnar Vectorized Group Keys", NULL,
						   state->nkeys, es);
	ExplainPropertyInteger("Columnar Vectorized Aggregates", NULL,
						   state->naggs, es);
	ExplainPropertyInteger("Columnar Pushed-Down Filters", NULL,
						   state->npreds, es);

	if (state->haveStats)
	{
		ExplainPropertyInteger("Columnar Chunk Groups Total", NULL,
							   (int64) state->groupsTotal, es);
		ExplainPropertyInteger("Columnar Chunk Groups Read", NULL,
							   (int64) state->groupsRead, es);
		ExplainPropertyInteger("Columnar Chunk Groups Removed by Filter", NULL,
							   (int64) state->groupsSkipped, es);
	}
}

static const CustomExecMethods columnar_groupagg_exec_methods = {
	.CustomName = "ColumnarScan",
	.BeginCustomScan = ColumnarBeginGroupAggScan,
	.ExecCustomScan = ColumnarExecGroupAggScan,
	.EndCustomScan = ColumnarEndGroupAggScan,
	.ReScanCustomScan = ColumnarReScanGroupAggScan,
	.ExplainCustomScan = ColumnarExplainGroupAggScan,
};

/* -------------------------------------------------------------------------
 * registration
 * ------------------------------------------------------------------------- */

void
ColumnarVectorInit(void)
{
	prev_create_upper_paths_hook = create_upper_paths_hook;
	create_upper_paths_hook = ColumnarCreateUpperPaths;
}
