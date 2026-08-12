/*-------------------------------------------------------------------------
 *
 * pgcolumnar_reader.c
 *		The columnar reader: a sequential scan that reads all columns of all
 *		stripes and reconstructs rows (spec 4, 6). Also holds the value-stream
 *		codec shared with the writer.
 *
 * The native format encodes value streams per vector and optionally block-
 * compresses them; the reader reverses both. Each chunk carries an exists
 * (null bitmap) stream of one bit per row (a validity bitmap); present rows
 * draw their value from the value stream in order.
 *
 *-------------------------------------------------------------------------
 */
#include "columnar.h"

#include "columnar_delete_vector.h"
#include "columnar_metadata.h"
#include "columnar_reader.h"
#include "columnar_storage.h"
#include "fmgr.h"
#include "access/detoast.h"
#include "access/htup_details.h"
#include "access/nbtree.h"
#include "access/relscan.h"
#include "access/tupmacs.h"
#include "access/xact.h"
#include "catalog/pg_am.h"
#include "commands/defrem.h"
#include "miscadmin.h"
#include "utils/lsyscache.h"
#include "port/atomics.h"
#include "port/pg_bitutils.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/typcache.h"

/*
 * One pushed-down comparison predicate used for chunk-group skipping. Built
 * from a scan key of the form "column btree-op constant" (spec 9). The
 * comparison proc is the column type's default btree comparison, matching the
 * proc used to build the stored min/max, so skipping is conservative and
 * correct: a group is skipped only when its min/max prove no row can match.
 */
typedef struct SkipPredicate
{
	int			attidx;			/* 0-based column index */
	StrategyNumber strategy;	/* BTLess/LessEqual/Equal/GreaterEqual/Greater */
	Datum		compareValue;	/* the constant */
	FmgrInfo	cmpFn;			/* column type's default btree comparison */
	Oid			collation;

	/* bloom-filter probe for equality (I7, gap 25): set for a hashable equality
	 * predicate on a safe collation, matching how the filter was built */
	bool		hasHash;
	FmgrInfo	hashFn;
	Oid			hashCollation;
} SkipPredicate;

struct PgColumnarReadState
{
	Relation	rel;
	Snapshot	snapshot;
	Snapshot	metaSnapshot;	/* catalog reads: sees our own writes (spec 9) */
	TupleDesc	tupdesc;
	int			natts;
	uint64		storageId;

	/*
	 * Per-column "missing" value for columns added by ALTER TABLE ADD COLUMN
	 * after a stripe was written (spec 6). Such a stripe has no chunk for the
	 * new column; the reader then produces the attribute's missing value
	 * (attmissingval when the add carried a constant default, otherwise NULL),
	 * matching the semantics heap gives via its fast-default mechanism.
	 */
	Datum	   *missingValues;		/* [natts] */
	bool	   *missingIsnull;		/* [natts] */

	Bitmapset  *projectedColumns;	/* 0-based; NULL means all columns */

	/*
	 * Column projection (#338). colWanted[c] is true when column c must actually
	 * be read and decoded; it is the flattened form of projectedColumns, so the
	 * per-row and per-chunk tests are an array index rather than a bitmapset
	 * probe. A NULL projectedColumns means every column is wanted, which is what
	 * every caller outside the custom scan and the vectorized aggregates passes,
	 * so those paths keep reading whole groups exactly as before.
	 */
	bool	   *colWanted;			/* [natts] */
	bool		allColumnsWanted;	/* true when colWanted is all true */

	SkipPredicate *predicates;		/* [numPredicates], in readContext */
	int			numPredicates;

	/*
	 * Optional restriction to a set of row groups (issue #149). When
	 * restrictGroups is non-NULL only groups whose groupNumber appears in it are
	 * read; the rest are passed over without their bytes being touched, exactly as
	 * a zone-map non-match is. Sorted ascending, in readContext, so the claim loop
	 * can binary search. The metadata aggregate path uses this to scan only the
	 * row groups that have deleted rows, folding the others from their zone maps.
	 */
	uint64	   *restrictGroups;		/* [numRestrictGroups], sorted, or NULL */
	int			numRestrictGroups;

	bool		started;
	bool		exhausted;

	ParallelTableScanDesc parallelScan;

	/*
	 * Parallel scan work claiming (gap 23). When non-NULL, this shared atomic
	 * hands out the next row group across all workers; each worker scans the row
	 * groups it claims. NULL for a serial scan, which walks rowGroupIndex.
	 */
	pg_atomic_uint32 *parallelCounter;

	/* current group row count and position, shared by the native producer */
	uint64		groupRowCount;
	uint64		rowInGroup;

	/* chunk-group skip counters over the groups reached so far (spec 9) */
	uint64		groupsRead;
	uint64		groupsSkipped;

	/*
	 * Native format (PGCN v1) read state. The scan reads row groups and column
	 * chunks from the native catalog. The current row group's bytes are read into
	 * nativeBuffer (in groupContext) -- whole, or only the projected columns'
	 * ranges (#338); nativeValidity[c] points at each column chunk's validity
	 * bitmap and nativeValueCursor[c] advances through its uncompressed values.
	 * Both stay NULL for a column that was not read.
	 */
	List	   *rowGroupList;		/* NativeRowGroupMetadata* */
	int			rowGroupIndex;		/* next row group to load */
	NativeRowGroupMetadata *nativeGroup;
	char	   *nativeBuffer;		/* whole current row group, in groupContext */
	char	  **nativeValidity;		/* [natts]; NULL if the column is absent */
	char	  **nativeValueCursor;	/* [natts]; advancing values cursor */

	/*
	 * Per-vector (1024-row) skipping within a loaded group (Phase D5b). When any
	 * predicate's per-vector zone map rules a vector out, its rows are neither
	 * decoded nor emitted. nativeSkipVec[v] flags a ruled-out vector;
	 * nativeVecRawLen[c][v] is column c's decoded byte length for vector v, used to
	 * step the value cursor past a skipped vector. Both NULL when per-vector
	 * skipping is inactive (no predicates or no per-vector zone maps).
	 */
	bool	   *nativeSkipVec;		/* [nativeVectorCount] or NULL */
	int			nativeVectorCount;
	uint32	  **nativeVecRawLen;	/* [natts][nativeVectorCount] or NULL */
	uint32	   *nativeVecStart;		/* [nativeVectorCount+1] cumulative row spans */
	int			nativeCurVec;		/* vector containing rowInGroup */
	uint64		vectorsSkipped;		/* for EXPLAIN */
	uint64		vectorsDecoded;		/* for EXPLAIN; see PgColumnarGroupStats */
	uint64		vectorDecodes;		/* (vector, column) pairs; see PgColumnarGroupStats */
	uint64		vectorsRuledOutByValue;	/* subset of vectorsSkipped; #452 1b-ii */

	/*
	 * Late materialization (#452 Phase 1a). Rows whose qual columns were decoded,
	 * the qual then rejected them, and whose remaining projected columns were
	 * therefore never built -- their cursors advanced without a
	 * MemoryContextAlloc or a memcpy. For EXPLAIN.
	 */
	uint64		rowsFilteredEarly;

	/*
	 * Late materialization for an UNPRUNABLE qual (#452 phase 2). When the qual
	 * is not a SkipPredicate (numPredicates == 0) these carry the executor's
	 * per-row filter into the group load, so a vector no row can pass is masked
	 * BEFORE its payload columns are decoded. All NULL on every non-filtered read
	 * path -- the fold path and PgColumnarReadNextRow both leave them NULL -- and
	 * that NULL is what turns the between-pass evaluator off. nativeQualValues
	 * and nativeQualNulls are the scan slot's own arrays, the same ones the
	 * filter reads when it stores the slot as a virtual tuple.
	 */
	const bool *nativeQualCols;			/* [natts] executor qual columns, or NULL */
	PgColumnarRowFilter nativeQualFilter;	/* the node's qual (counts rejects), or NULL */
	PgColumnarRowFilter nativeQualFilterNoCount; /* same qual, no InstrCountFiltered1 */
	void	   *nativeQualFilterArg;
	Datum	   *nativeQualValues;		/* scan slot tts_values, or NULL */
	bool	   *nativeQualNulls;		/* scan slot tts_isnull, or NULL */
	bool		nativeQualCounted;		/* the phase-2 evaluator counted this group's rejects */

	/*
	 * Did loading this group skip the DECODE of any vector (#512)?
	 *
	 * False always, today: pgcolumnar_native_decode_chunk takes no skip mask and
	 * produces every vector. It exists so the batch fold can refuse a group it
	 * cannot read safely the day that changes -- see PgColumnarReadFoldGroupInfo
	 * and the check in columnar_vector.c.
	 */
	bool		decodeSkippedVectors;

	/*
	 * Native delete visibility (Phase D6b): the current row group's combined
	 * delete mask (one bit per row-in-group, set = deleted), from
	 * pgcolumnar.delete_vector keyed by group number. NULL when the group has no
	 * deletes.
	 */
	char	   *nativeDeleteMask;
	uint32		nativeDeleteMaskLen;

	MemoryContext readContext;		/* whole scan */
	MemoryContext stripeContext;	/* reset per stripe */
	MemoryContext groupContext;		/* reset per chunk group (decompressed) */
	MemoryContext rowContext;		/* reset per row */
	MemoryContext skipContext;		/* scratch for skip-list evaluation */
};

static void pgcolumnar_build_predicates(PgColumnarReadState *readState,
									  int nkeys, ScanKey keys);
static int64 pgcolumnar_next_group_index(PgColumnarReadState *readState);

/* qsort comparator for the row group restriction set */
static int
pgcolumnar_uint64_cmp(const void *a, const void *b)
{
	uint64		x = *(const uint64 *) a;
	uint64		y = *(const uint64 *) b;

	return (x < y) ? -1 : (x > y) ? 1 : 0;
}

/*
 * pgcolumnar_group_is_restricted_in
 *		Is this group number in the read state's restriction set? Binary search
 *		over the sorted array set by PgColumnarReadRestrictToGroups. Only called
 *		when restrictGroups is non-NULL.
 */
static bool
pgcolumnar_group_is_restricted_in(PgColumnarReadState *rs, uint64 groupNumber)
{
	int			lo = 0;
	int			hi = rs->numRestrictGroups - 1;

	while (lo <= hi)
	{
		int			mid = lo + (hi - lo) / 2;

		if (rs->restrictGroups[mid] == groupNumber)
			return true;
		else if (rs->restrictGroups[mid] < groupNumber)
			lo = mid + 1;
		else
			hi = mid - 1;
	}
	return false;
}

/* -------------------------------------------------------------------------
 * value stream codec (shared with the writer)
 * ------------------------------------------------------------------------- */

/*
 * PgColumnarEncodeValue
 *		Append a non-null value to a column's value stream. Fixed-length
 *		values are stored as their raw bytes; varlena values are detoasted
 *		and stored with a full 4-byte header so the reader can size them.
 */
void
PgColumnarEncodeValue(StringInfo buf, Form_pg_attribute att, Datum value)
{
	if (att->attbyval)
	{
		char		tmp[8];

		Assert(att->attlen >= 1 && att->attlen <= 8);
		store_att_byval(tmp, value, att->attlen);
		appendBinaryStringInfo(buf, tmp, att->attlen);
	}
	else if (att->attlen > 0)
	{
		appendBinaryStringInfo(buf, DatumGetPointer(value), att->attlen);
	}
	else if (att->attlen == -1)
	{
		struct varlena *detoasted =
			pg_detoast_datum((struct varlena *) DatumGetPointer(value));

		appendBinaryStringInfo(buf, (char *) detoasted, VARSIZE(detoasted));
		if ((Pointer) detoasted != DatumGetPointer(value))
			pfree(detoasted);
	}
	else
	{
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("columnar phase 1 does not support column type with attlen %d",
						att->attlen)));
	}
}

/*
 * PgColumnarDecodeValue
 *		Read one value from a column's value stream, advancing *cursor.
 *		By-reference values are copied into targetContext so they outlive the
 *		stripe buffer's next reset.
 */
Datum
PgColumnarDecodeValue(Form_pg_attribute att, char **cursor,
					MemoryContext targetContext)
{
	char	   *p = *cursor;
	Datum		result;

	if (att->attbyval)
	{
		result = fetch_att(p, true, att->attlen);
		*cursor = p + att->attlen;
	}
	else if (att->attlen > 0)
	{
		char	   *copy = MemoryContextAlloc(targetContext, att->attlen);

		memcpy(copy, p, att->attlen);
		result = PointerGetDatum(copy);
		*cursor = p + att->attlen;
	}
	else
	{
		Size		len = PgColumnarVarSizeAnyUnaligned(p);
		char	   *copy = MemoryContextAlloc(targetContext, len);

		memcpy(copy, p, len);
		result = PointerGetDatum(copy);
		*cursor = p + len;
	}

	return result;
}

/*
 * pgcolumnar_skip_value
 *		Advance one column's cursor past a present value WITHOUT building it.
 *
 * The whole of late materialization (#452) is the difference between this and
 * PgColumnarDecodeValue directly above: same cursor arithmetic, no
 * MemoryContextAlloc and no memcpy. For a rejected row that is the entire cost
 * avoided, and it is why the feature needs neither batching nor random access --
 * the cursor still walks every row, it just stops copying the ones nothing will
 * read.
 *
 * Deliberately mirrors PgColumnarDecodeValue's three cases in the same order,
 * and sits next to it so a change to that cursor arithmetic cannot miss this.
 */
static inline void
pgcolumnar_skip_value(Form_pg_attribute att, char **cursor)
{
	char	   *p = *cursor;

	if (att->attbyval || att->attlen > 0)
		*cursor = p + att->attlen;
	else
		*cursor = p + PgColumnarVarSizeAnyUnaligned(p);
}

/*
 * pgcolumnar_row_read_column / pgcolumnar_row_skip_column
 *		One column of the current row: build its value, or step past it.
 *
 * Extracted from the producer's loop so late materialization (#452) can visit
 * the columns in two groups without restating the rules. The order of the tests
 * is load-bearing and is preserved exactly: not-projected is checked BEFORE
 * absent-from-this-group, because both leave nativeValidity NULL and they mean
 * different things -- falling through would hand back an ADD COLUMN default for
 * a column that was simply never fetched.
 *
 * Must be called with the row context current, and only from the producer, which
 * owns rowInGroup.
 */
static inline void
pgcolumnar_row_read_column(PgColumnarReadState *rs, int c, Datum *values, bool *nulls)
{
	Form_pg_attribute att = TupleDescAttr(rs->tupdesc, c);
	char	   *vbits = rs->nativeValidity[c];

	if (!rs->colWanted[c])
	{
		values[c] = (Datum) 0;
		nulls[c] = true;
		return;
	}
	if (vbits == NULL)
	{
		values[c] = rs->missingValues[c];
		nulls[c] = rs->missingIsnull[c];
		return;
	}

	if ((vbits[rs->rowInGroup >> 3] >> (rs->rowInGroup & 7)) & 1)
	{
		/* Fast path (#289): inline the attbyval decode, as the loop always has. */
		if (att->attbyval)
		{
			char	   *p = rs->nativeValueCursor[c];

			values[c] = fetch_att(p, true, att->attlen);
			rs->nativeValueCursor[c] = p + att->attlen;
		}
		else
			values[c] = PgColumnarDecodeValue(att, &rs->nativeValueCursor[c],
											rs->rowContext);
		nulls[c] = false;
	}
	else
	{
		values[c] = (Datum) 0;
		nulls[c] = true;
	}
}

static inline void
pgcolumnar_row_skip_column(PgColumnarReadState *rs, int c, Datum *values, bool *nulls)
{
	Form_pg_attribute att = TupleDescAttr(rs->tupdesc, c);
	char	   *vbits = rs->nativeValidity[c];

	/*
	 * Nothing above the scan may read this column for this row: the row is
	 * either about to be discarded or is deleted. An explicit NULL rather than a
	 * stale Datum, so a reader that does look finds an obvious value.
	 */
	values[c] = (Datum) 0;
	nulls[c] = true;

	/* No cursor to advance: never fetched, or absent from this group entirely. */
	if (!rs->colWanted[c] || vbits == NULL)
		return;

	if ((vbits[rs->rowInGroup >> 3] >> (rs->rowInGroup & 7)) & 1)
		pgcolumnar_skip_value(att, &rs->nativeValueCursor[c]);
}

/* -------------------------------------------------------------------------
 * sequential scan
 * ------------------------------------------------------------------------- */

PgColumnarReadState *
PgColumnarBeginRead(Relation rel, Snapshot snapshot,
				  ParallelTableScanDesc parallelScan,
				  Bitmapset *projectedColumns, int nkeys, ScanKey keys)
{
	return PgColumnarBeginReadWithStorage(rel, snapshot, PgColumnarStorageId(rel),
										RelationGetDescr(rel), parallelScan,
										projectedColumns, nkeys, keys);
}

PgColumnarReadState *
PgColumnarBeginReadWithStorage(Relation rel, Snapshot snapshot,
							 uint64 storageId, TupleDesc tupdesc,
							 ParallelTableScanDesc parallelScan,
							 Bitmapset *projectedColumns, int nkeys, ScanKey keys)
{
	PgColumnarReadState *readState;
	MemoryContext readContext;
	MemoryContext oldContext;

	readContext = AllocSetContextCreate(CurrentMemoryContext,
										"columnar read",
										ALLOCSET_DEFAULT_SIZES);
	oldContext = MemoryContextSwitchTo(readContext);

	readState = palloc0(sizeof(PgColumnarReadState));
	readState->rel = rel;
	readState->snapshot = snapshot;
	readState->metaSnapshot = PgColumnarCatalogSnapshot(snapshot);
	readState->tupdesc = tupdesc;
	readState->natts = readState->tupdesc->natts;
	readState->storageId = storageId;

	/*
	 * Reject a native data format version this build does not understand before
	 * any bytes are decoded (#240). The metapage version was already checked when
	 * PgColumnarStorageId read the metapage; this is the independent data-format
	 * stamp, catching a future encoding change that keeps the metapage layout.
	 */
	PgColumnarCheckNativeFormatVersion(storageId, RelationGetRelationName(rel));

	/*
	 * Resolve each column's missing value once, for stripes that predate an
	 * ADD COLUMN and therefore carry no chunk for the column (spec 6). A table
	 * with no added-with-default columns yields all-NULL here.
	 */
	readState->missingValues = palloc0(sizeof(Datum) * readState->natts);
	readState->missingIsnull = palloc0(sizeof(bool) * readState->natts);
	{
		int			mc;

		for (mc = 0; mc < readState->natts; mc++)
			readState->missingValues[mc] =
				getmissingattr(readState->tupdesc, mc + 1,
							   &readState->missingIsnull[mc]);
	}

	readState->projectedColumns = bms_copy(projectedColumns);

	/*
	 * Flatten the projection (#338). A NULL bitmap means "all columns" -- that is
	 * how pgcolumnar_projected_columns reports a whole-row Var, any system column,
	 * and a query referencing no column at all (count(*)), and it is what every
	 * caller that does not compute a projection passes.
	 */
	readState->colWanted = palloc(sizeof(bool) * readState->natts);
	readState->allColumnsWanted = (projectedColumns == NULL ||
								   !pgcolumnar_enable_column_projection);
	{
		int			pc;

		for (pc = 0; pc < readState->natts; pc++)
			readState->colWanted[pc] = readState->allColumnsWanted ||
				bms_is_member(pc, projectedColumns);
	}

	readState->started = false;
	readState->exhausted = false;
	readState->parallelScan = parallelScan;
	readState->readContext = readContext;
	readState->stripeContext = AllocSetContextCreate(readContext,
													 "columnar read stripe",
													 ALLOCSET_DEFAULT_SIZES);
	readState->groupContext = AllocSetContextCreate(readContext,
													"columnar read group",
													ALLOCSET_DEFAULT_SIZES);
	readState->rowContext = AllocSetContextCreate(readContext,
												  "columnar read row",
												  ALLOCSET_DEFAULT_SIZES);
	readState->skipContext = AllocSetContextCreate(readContext,
												   "columnar read skip",
												   ALLOCSET_DEFAULT_SIZES);

	if (pgcolumnar_enable_qual_pushdown)
		pgcolumnar_build_predicates(readState, nkeys, keys);

	MemoryContextSwitchTo(oldContext);
	return readState;
}


/*
 * pgcolumnar_make_predicates
 *		Translate ScanKeys into skip predicates for chunk-group filtering
 *		(spec 9), into caller-provided storage. Only simple btree comparison keys
 *		on an orderable column are used; anything else is ignored, so skipping
 *		stays conservative. Returns how many were built.
 *
 *		Separate from the read state so the PLANNER can build the same predicates
 *		to estimate how much a scan would prune (#461) without constructing a
 *		scan. The planner and the executor must decide "can this group match" by
 *		the same rule -- pricing a discount by one rule and taking it by another
 *		is how a plan gets chosen for a saving it never realises.
 */
static int
pgcolumnar_make_predicates(SkipPredicate *out, int nkeys, ScanKey keys,
						   TupleDesc tupdesc, int natts, MemoryContext cx)
{
	int			i;
	int			n = 0;

	if (nkeys <= 0 || keys == NULL)
		return 0;

	for (i = 0; i < nkeys; i++)
	{
		ScanKey		key = &keys[i];
		int			attidx;
		Form_pg_attribute att;
		TypeCacheEntry *tce;
		Oid			colType;
		Oid			argType;
		bool		crossType;

		/* only plain "column op const" comparison keys are usable */
		if (key->sk_flags & (SK_ISNULL | SK_ROW_HEADER | SK_ROW_MEMBER |
							 SK_ROW_END | SK_SEARCHNULL | SK_SEARCHNOTNULL |
							 SK_ORDER_BY))
			continue;
		if (key->sk_attno < 1 || key->sk_attno > natts)
			continue;
		if (key->sk_strategy < BTLessStrategyNumber ||
			key->sk_strategy > BTGreaterStrategyNumber)
			continue;

		attidx = key->sk_attno - 1;
		att = TupleDescAttr(tupdesc, attidx);

		/*
		 * Compare BASE types when deciding whether this key is cross-type
		 * (#483).
		 *
		 * A domain is not a different type for comparison purposes: it shares
		 * its base type's ordering, its comparison proc, and its physical
		 * representation. But a column declared over a domain has the domain's
		 * OID in atttypid while the constant beside it has the base type's, so
		 * comparing the OIDs directly called every such key cross-type, and the
		 * opfamily has no ordering proc for (domain, base). #478's fallback then
		 * dropped the key, which is right for a genuinely uncomparable pair and
		 * wrong here.
		 *
		 * The effect was that a domain column pruned NOTHING. Measured on
		 * identical values in one table over 20 row groups: int and bigint each
		 * removed 19 groups, a domain over either removed 0, and all three
		 * reported the filter as pushed down. The answers stayed correct because
		 * the executor re-applies the qual; the table was simply read whole.
		 *
		 * Both sides are resolved, not just the column, so that a domain
		 * compared against a value of a DIFFERENT domain over the same base type
		 * is also recognised as same-type rather than falling into the
		 * opfamily lookup that has no entry for either OID.
		 *
		 * This changes no comparison semantics. The cmp and hash procs come from
		 * lookup_type_cache(att->atttypid) below, which already resolves a domain
		 * through GetDefaultOpClass to its base type's procs, and the WRITER
		 * builds zone maps and bloom filters from that same expression
		 * (columnar_write_state.c). Reader and writer therefore agree on the
		 * ordering and the hash by construction, before and after this change.
		 */
		colType = getBaseType(att->atttypid);
		argType = OidIsValid(key->sk_subtype)
			? getBaseType(key->sk_subtype) : InvalidOid;

		crossType = (OidIsValid(argType) && argType != colType);

		tce = lookup_type_cache(att->atttypid,
								TYPECACHE_CMP_PROC_FINFO |
								TYPECACHE_HASH_PROC_FINFO);
		if (!OidIsValid(tce->cmp_proc_finfo.fn_oid))
			continue;

		/*
		 * A cross-type key needs the comparison proc for the PAIR of types, not
		 * the column type's default one (#477).
		 *
		 * This used to skip the key outright, with the comment "avoid cross-type
		 * comparisons that our column cmp proc cannot do". That was correct about
		 * the proc and wrong about the remedy: handing an int4 Datum to
		 * btint8cmp would read a value that is not there, so refusing was right,
		 * but refusing meant an int8 column compared against a bare integer
		 * literal skipped NOTHING. Measured on identical data in two columns:
		 * `idi > 16000` removed 7 chunk groups of 10, `seq > 16000` removed 0,
		 * and `seq > 16000::bigint` removed 7. That is ordinary SQL, not an edge
		 * case, and EXPLAIN still reported the filter as pushed down because that
		 * counter counts scan keys rather than predicates able to exclude.
		 *
		 * btree opfamilies carry exactly this: integer_ops supplies btint84cmp
		 * for (int8, int4). Ask the column's default opfamily for the ordering
		 * proc over both types, and where it has none, keep skipping the key --
		 * which is the old behaviour, still correct, now the fallback rather than
		 * the rule.
		 */
		if (crossType)
		{
			Oid			opclass = GetDefaultOpClass(colType, BTREE_AM_OID);
			Oid			opfamily;
			Oid			cmpProc;

			if (!OidIsValid(opclass))
				continue;
			opfamily = get_opclass_family(opclass);
			cmpProc = get_opfamily_proc(opfamily, colType, argType,
										BTORDER_PROC);
			if (!OidIsValid(cmpProc))
				continue;
			fmgr_info_cxt(cmpProc, &out[n].cmpFn,
						  cx);
		}
		else
			fmgr_info_copy(&out[n].cmpFn, &tce->cmp_proc_finfo,
						   cx);

		out[n].attidx = attidx;
		out[n].strategy = key->sk_strategy;
		out[n].compareValue = key->sk_argument;
		out[n].collation = att->attcollation;

		/*
		 * For an equality predicate on a hashable column with a safe collation,
		 * enable the bloom-filter probe (I7, gap 25), matching how the filter was
		 * built. The scan key already matches the column collation (a
		 * differently collated predicate is not pushed; see PgColumnarBuildScanKeys),
		 * so hashing the constant under the column collation is consistent.
		 *
		 * NOT for a cross-type key (#477). The filter was built by hashing
		 * COLUMN-type values, so hashing an int4 constant with the int8 hash proc
		 * probes a slot the writer never set and the group is skipped although it
		 * may hold the row: a wrong answer, where the min/max path above is only
		 * ever conservative. Cross-type equality therefore keeps min/max pruning
		 * and forgoes the bloom probe.
		 */
		out[n].hasHash = false;
		if (!crossType &&
			key->sk_strategy == BTEqualStrategyNumber &&
			OidIsValid(tce->hash_proc_finfo.fn_oid) &&
			PgColumnarCollationIsDeterministic(att->attcollation))
		{
			out[n].hasHash = true;
			fmgr_info_copy(&out[n].hashFn,
						   &tce->hash_proc_finfo, cx);
			out[n].hashCollation = att->attcollation;
		}
		n++;
	}

	return n;
}

/*
 * pgcolumnar_build_predicates
 *		Fill a read state's skip predicates from its scan keys. Runs in
 *		readContext.
 */
static void
pgcolumnar_build_predicates(PgColumnarReadState *readState, int nkeys, ScanKey keys)
{
	if (nkeys <= 0 || keys == NULL)
		return;

	readState->predicates = palloc0(sizeof(SkipPredicate) * nkeys);
	readState->numPredicates =
		pgcolumnar_make_predicates(readState->predicates, nkeys, keys,
								   readState->tupdesc, readState->natts,
								   readState->readContext);
}

/*
 * pgcolumnar_group_can_match
 *		Decide whether a chunk group could contain a row satisfying every
 *		pushed-down predicate, using the stored per-chunk min/max (spec 9). A
 *		return of false means the group can be skipped. Missing min/max, or a
 *		non-orderable column, is treated conservatively as "may match".
 */

/*
 * pgcolumnar_setup_group
 *		Position on a chunk group: decompress each projected column's value
 *		stream into the group context and point the column cursors at the
 *		decompressed bytes and the (uncompressed) exists bytes. Non-projected
 *		columns are left un-decoded (column projection, spec 9).
 */

/*
 * pgcolumnar_position_group
 *		Advance from the current groupIndex to the next chunk group that could
 *		match the pushed-down predicates, skipping groups whose min/max rule
 *		them out (spec 9). Returns true when positioned on a readable group,
 *		false when the stripe has no more matching groups.
 */

/*
 * pgcolumnar_load_stripe
 *		Read a stripe's metadata and data into memory and position at its
 *		first chunk group.
 */

/*
 * pgcolumnar_read_start
 *		Lazily load the stripe list on the first fetch. For a parallel scan a
 *		single worker claims the whole scan and the others see it exhausted,
 *		which is a correct (if not parallel-accelerated) behaviour.
 */
static void
pgcolumnar_read_start(PgColumnarReadState *readState)
{
	if (readState->started)
		return;

	readState->started = true;

	if (readState->parallelScan != NULL)
	{
		ParallelBlockTableScanDesc bpscan =
			(ParallelBlockTableScanDesc) readState->parallelScan;
		uint64		claim = pg_atomic_fetch_add_u64(&bpscan->phs_nallocated, 1);

		if (claim != 0)
			readState->exhausted = true;
	}

	if (!readState->exhausted)
	{
		MemoryContext oldContext = MemoryContextSwitchTo(readState->readContext);

		readState->rowGroupList =
			PgColumnarReadRowGroupList(readState->storageId,
									 readState->metaSnapshot);
		readState->rowGroupIndex = 0;
		MemoryContextSwitchTo(oldContext);
	}
}

/*
 * pgcolumnar_native_decode_chunk
 *		Reconstruct a native column chunk's raw present-value stream (D4) from its
 *		encoding descriptor. The on-disk values region is the per-1024-value-vector
 *		encoded streams concatenated, optionally block-compressed as a whole. This
 *		reverses the block codec, then decodes each vector with PgColumnarDecodeChunk
 *		into one raw buffer byte-identical to what the writer buffered, so the
 *		per-row producer walks it exactly as it walks the D2b baseline. Allocated
 *		in the group context. The descriptor lengths are cross-checked so a corrupt
 *		chunk cannot drive a decoder past its buffers.
 */
static char *
pgcolumnar_native_decode_chunk(MemoryContext cx, Form_pg_attribute att,
							 char *values, uint32 valuesLen,
							 const char *desc, uint32 descLen, int blockCodec,
							 uint32 **outVecRawLen, int *outVecCount,
							 const bool *skipVec, int *outVecDecoded)
{
	int			decodedCount = 0;
	uint32		vectorCount;
	uint32		v;
	const char *dp;
	uint64		encTotal = 0;
	uint64		rawTotal = 0;
	uint64		entriesEnd;
	uint32		sharedTableLen = 0;
	const char *sharedTable = NULL;
	const char *encRegion;
	const char *encCursor;
	char	   *rawBuf;
	char	   *rawCursor;
	uint32	   *vecRawLen;
	MemoryContext decodeScratch;

	if (descLen < COLUMNAR_NATIVE_ENCDESC_HEADER_LEN ||
		(uint8) desc[0] != COLUMNAR_NATIVE_ENCDESC_VERSION)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("pgcolumnar: unrecognized native encoding descriptor")));
	memcpy(&vectorCount, desc + 2, sizeof(uint32));

	/*
	 * Version 2 (E3b) appends a trailing region { uint32 sharedTableLen, bytes }
	 * after the per-vector entries: the chunk-shared FSST symbol table. Locate and
	 * validate it, so FSST vectors can be decoded against it.
	 */
	entriesEnd = (uint64) COLUMNAR_NATIVE_ENCDESC_HEADER_LEN +
		(uint64) vectorCount * COLUMNAR_NATIVE_ENCDESC_ENTRY_LEN;
	if ((uint64) descLen < entriesEnd + COLUMNAR_NATIVE_ENCDESC_SHARED_LEN_BYTES)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("pgcolumnar: native encoding descriptor length mismatch")));
	memcpy(&sharedTableLen, desc + entriesEnd, sizeof(uint32));
	if ((uint64) descLen != entriesEnd + COLUMNAR_NATIVE_ENCDESC_SHARED_LEN_BYTES +
		(uint64) sharedTableLen)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("pgcolumnar: native encoding descriptor length mismatch")));
	if (sharedTableLen > 0)
		sharedTable = desc + entriesEnd + COLUMNAR_NATIVE_ENCDESC_SHARED_LEN_BYTES;

	/* first pass: total encoded and raw lengths across the vectors */
	dp = desc + COLUMNAR_NATIVE_ENCDESC_HEADER_LEN;
	for (v = 0; v < vectorCount; v++)
	{
		uint32		rawLen;
		uint32		encLen;

		memcpy(&rawLen, dp + 1 + sizeof(uint32), sizeof(uint32));
		memcpy(&encLen, dp + 1 + 2 * sizeof(uint32), sizeof(uint32));
		encTotal += encLen;
		rawTotal += rawLen;
		dp += COLUMNAR_NATIVE_ENCDESC_ENTRY_LEN;
	}

	/*
	 * The decode's intermediates -- the decompressed encoded region and each
	 * vector's decoded buffer (memcpy'd into rawBuf below) -- are scratch, not
	 * results, but were allocated in cx. On the scan path cx is a group context
	 * reset every group so it did not matter; on the by-row-number fetch path cx
	 * is the statement-scoped cache entry that is NOT reset, so the scratch stayed
	 * live and roughly tripled the entry's measured size, pushing a wide group's
	 * projected prefix over the 32 MB fetch cap and forcing a re-decode on every
	 * fetch (#353). Put the scratch in a child context and delete it before
	 * returning, so cx keeps only rawBuf and vecRawLen.
	 */
	decodeScratch = AllocSetContextCreate(cx, "columnar decode scratch",
										  ALLOCSET_DEFAULT_SIZES);

	/* reverse the block codec to recover the concatenated encoded region */
	if (blockCodec != COLUMNAR_COMPRESSION_NONE)
		encRegion = PgColumnarDecompressValueStream(values, valuesLen, blockCodec,
												  (uint32) encTotal,
												  decodeScratch);
	else
	{
		if ((uint64) valuesLen != encTotal)
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("pgcolumnar: native chunk length does not match descriptor")));
		encRegion = values;
	}

	/* second pass: decode each vector into one raw present-value buffer */
	rawBuf = MemoryContextAlloc(cx, rawTotal > 0 ? rawTotal : 1);
	vecRawLen = (uint32 *) MemoryContextAlloc(cx,
											  sizeof(uint32) * (vectorCount > 0 ? vectorCount : 1));
	rawCursor = rawBuf;
	encCursor = encRegion;
	dp = desc + COLUMNAR_NATIVE_ENCDESC_HEADER_LEN;
	for (v = 0; v < vectorCount; v++)
	{
		uint8		encType;
		uint32		valueCount;
		uint32		rawLen;
		uint32		encLen;

		encType = (uint8) dp[0];
		memcpy(&valueCount, dp + 1, sizeof(uint32));
		memcpy(&rawLen, dp + 1 + sizeof(uint32), sizeof(uint32));
		memcpy(&encLen, dp + 1 + 2 * sizeof(uint32), sizeof(uint32));
		dp += COLUMNAR_NATIVE_ENCDESC_ENTRY_LEN;

		vecRawLen[v] = rawLen;
		if (rawLen > 0)
		{
			/*
			 * #452 phase 1b-i. A vector the caller's zone maps ruled out is not
			 * decoded: no PgColumnarDecodeChunk, no memcpy. Both cursors still
			 * advance by the descriptor's lengths, so every later vector lands
			 * at the same offset it would have without the skip, and vecRawLen
			 * still reports the full raw length so the row producer steps over
			 * the gap exactly as before.
			 *
			 * This LEAVES A HOLE in rawBuf: those rawLen bytes are whatever
			 * palloc handed back. That is safe only because nothing reads them.
			 * The row producer steps past skipped vectors, and the vectorized
			 * fold refuses a group whose decode skipped anything (#512, #523) --
			 * it reads this buffer directly and re-checks every value, so it
			 * would otherwise re-check uninitialized memory and return a wrong
			 * aggregate silently. Do not relax that guard without giving the
			 * fold the mask.
			 */
			if (skipVec != NULL && skipVec[v])
			{
				/*
				 * Poisoned in assert builds, and this is not decoration. Reading
				 * a hole is undefined behaviour whose SYMPTOM is data-dependent:
				 * whatever palloc last left here is usually rejected by the
				 * reader's own scan-key recheck, so a consumer that wrongly reads
				 * holes returns the right answer on most data and a wrong one on
				 * some. That is unfalsifiable by a test.
				 *
				 * A fixed poison makes the bug deterministic instead: the value
				 * is the same on every run, so a consumer that reads it can be
				 * caught by a predicate the poison satisfies. test/native_vecdecode.sh
				 * does exactly that, and without this the check passes against a
				 * fold that reads every hole.
				 */
#ifdef USE_ASSERT_CHECKING
				memset(rawCursor, 0xA5, rawLen);
#endif
				rawCursor += rawLen;
			}
			else
			{
				char	   *rawVec = PgColumnarDecodeChunk(encCursor, encLen, encType,
														 att, valueCount, rawLen,
														 sharedTable, sharedTableLen,
														 decodeScratch);

				memcpy(rawCursor, rawVec, rawLen);
				rawCursor += rawLen;
				decodedCount++;
			}
		}
		else if (!(skipVec != NULL && skipVec[v]))
		{
			/*
			 * An empty vector costs no decode, but it is not a saving either,
			 * and the group's vectors have to add up: the suite asserts decoded
			 * plus skipped is the vector count, and a rawLen == 0 vector that
			 * counted as neither would break that arithmetic on any column with
			 * an all-NULL vector.
			 */
			decodedCount++;
		}
		encCursor += encLen;
	}

	if (outVecRawLen != NULL)
		*outVecRawLen = vecRawLen;
	if (outVecCount != NULL)
		*outVecCount = (int) vectorCount;
	/*
	 * Reported from the loop that did the work, never derived from the mask the
	 * caller passed in. Deriving it is the first thing anyone writes here and it
	 * makes the counter unfalsifiable: it would report the saving whether or not
	 * decode honoured the mask, and a removal proof would pass. That is not a
	 * hypothetical -- this counter was written that way first, and the suite
	 * passed with the skip removed.
	 */
	if (outVecDecoded != NULL)
		*outVecDecoded = decodedCount;

	/* rawBuf and vecRawLen live in cx; the scratch above does not */
	MemoryContextDelete(decodeScratch);
	return rawBuf;
}

/*
 * native_is_qual_column
 *		Does any pushed-down predicate read this column? Decode order depends on
 *		it: qual columns must be decoded before exact selection can run, payload
 *		columns after, or there is nothing left to save.
 */
static bool
native_is_qual_column(PgColumnarReadState *rs, int col)
{
	int			p;

	for (p = 0; p < rs->numPredicates; p++)
		if (rs->predicates[p].attidx == col)
			return true;

	/*
	 * #452 phase 2: with no reader predicate, refine_skipvec can build no mask,
	 * so the columns the executor qual reads are the ones to decode first -- an
	 * unprunable qual (a leading-wildcard LIKE) can then gate the payload decode.
	 * Gated on numPredicates == 0 so 1b-ii's predicate-driven split is byte-for-
	 * byte unchanged whenever a predicate exists.
	 */
	if (rs->numPredicates == 0 && rs->nativeQualCols != NULL &&
		col >= 0 && col < rs->natts && rs->nativeQualCols[col])
		return true;

	return false;
}

/*
 * native_value_satisfies
 *		Does one decoded value satisfy one pushed-down predicate? The mirror of
 *		native_zone_excludes below, which asks the same question of a min/max pair
 *		rather than of a value.
 *
 *		Column first and constant second, like every other comparison here. The
 *		argument order is part of a cross-type proc's signature and getting it
 *		backwards is #477.
 *
 *		An unrecognised strategy returns true: "cannot rule this out" is the only
 *		safe answer, because the caller turns a false into a skipped vector.
 */
static bool
native_value_satisfies(SkipPredicate *pred, Datum val)
{
	int32		c = DatumGetInt32(FunctionCall2Coll(&pred->cmpFn, pred->collation,
													val, pred->compareValue));

	switch (pred->strategy)
	{
		case BTLessStrategyNumber:
			return (c < 0);
		case BTLessEqualStrategyNumber:
			return (c <= 0);
		case BTEqualStrategyNumber:
			return (c == 0);
		case BTGreaterEqualStrategyNumber:
			return (c >= 0);
		case BTGreaterStrategyNumber:
			return (c > 0);
		default:
			return true;
	}
}

/*
 * pgcolumnar_native_refine_skipvec
 *		Extend the skip vector from "the zone maps could not rule this vector out"
 *		to "no row in it actually matches" (#452 phase 1b-ii).
 *
 *		Called between the two decode passes: the qual columns are decoded, the
 *		payload columns are not yet, so a vector ruled out here costs the payload
 *		columns nothing. That ordering IS the optimisation. Run it after both
 *		passes and it saves nothing at all.
 *
 *		Predicates are grouped BY COLUMN and evaluated conjunctively within a
 *		column: a row keeps the vector alive only if it satisfies EVERY predicate
 *		on that column. Evaluating them one at a time instead is sound but
 *		useless, and uselessly in exactly the shape this is for -- `BETWEEN 51 AND
 *		59` is two predicates, and on a column holding multiples of ten some row
 *		satisfies `>= 51` and some other row satisfies `<= 59`, so neither alone
 *		is ever unsatisfied and no vector is ever ruled out. Measured that way
 *		first; it saved nothing.
 *
 *		Across columns it stays conservative: a vector is ruled out when SOME
 *		column's predicates are satisfied by no row in it. It can miss a vector
 *		where every row fails some predicate but no single column rules it out.
 *		Missing a skip costs time; taking a wrong one would cost rows, so the
 *		asymmetry runs the safe way.
 *
 *		A NULL never satisfies a btree comparison, so a NULL row cannot keep a
 *		vector alive. That matches what the executor does with it.
 */
static void
pgcolumnar_native_refine_skipvec(PgColumnarReadState *rs, int vecCount)
{
	MemoryContext scratch;
	MemoryContext old;
	int			p;

	if (rs->nativeSkipVec == NULL || rs->nativeVecStart == NULL ||
		rs->numPredicates == 0 || vecCount <= 0)
		return;

	scratch = AllocSetContextCreate(CurrentMemoryContext,
									"columnar exact selection",
									ALLOCSET_SMALL_SIZES);
	old = MemoryContextSwitchTo(scratch);

	for (p = 0; p < rs->numPredicates; p++)
	{
		int			col = rs->predicates[p].attidx;
		Form_pg_attribute att;
		const uint32 *vrl;
		char	   *cursor;
		int			v;
		int			q;
		bool		seen = false;

		if (col < 0 || col >= rs->natts)
			continue;

		/* one pass per COLUMN, not per predicate: take the first mention */
		for (q = 0; q < p; q++)
			if (rs->predicates[q].attidx == col)
				seen = true;
		if (seen)
			continue;
		/* not projected, or a baseline chunk with no per-vector structure */
		if (rs->nativeValueCursor[col] == NULL || rs->nativeVecRawLen[col] == NULL ||
			rs->nativeValidity[col] == NULL)
			continue;

		att = TupleDescAttr(rs->tupdesc, col);
		vrl = rs->nativeVecRawLen[col];
		cursor = rs->nativeValueCursor[col];

		for (v = 0; v < vecCount; v++)
		{
			char	   *vecCur = cursor;
			uint32		r0 = rs->nativeVecStart[v];
			uint32		r1 = rs->nativeVecStart[v + 1];
			uint32		r;
			bool		any = false;

			/*
			 * Advance to the next vector BEFORE the skip test. A skipped vector
			 * still occupies its full raw length; its bytes are simply a hole
			 * that 1b-i left undecoded, and in an assert build they are poison.
			 * Reading them is exactly the bug that change was careful about.
			 */
			cursor += vrl[v];
			if (rs->nativeSkipVec[v])
				continue;

			CHECK_FOR_INTERRUPTS();

			for (r = r0; r < r1; r++)
			{
				Datum		val;
				bool		ok;

				if (!((rs->nativeValidity[col][r >> 3] >> (r & 7)) & 1))
					continue;	/* NULL: satisfies no btree comparison */

				val = PgColumnarDecodeValue(att, &vecCur, scratch);

				/* every predicate on THIS column, conjunctively */
				ok = true;
				for (q = 0; q < rs->numPredicates; q++)
				{
					if (rs->predicates[q].attidx != col)
						continue;
					if (!native_value_satisfies(&rs->predicates[q], val))
					{
						ok = false;
						break;
					}
				}
				if (ok)
				{
					any = true;
					break;
				}
			}

			if (!any)
			{
				rs->nativeSkipVec[v] = true;
				rs->vectorsRuledOutByValue++;
			}
		}
	}

	MemoryContextSwitchTo(old);
	MemoryContextDelete(scratch);
}

/*
 * native_zone_excludes
 *		Return true when a zone map's min/max prove that no value in its range can
 *		satisfy the predicate (so the vector or chunk can be skipped). A missing or
 *		non-orderable zone map returns false (cannot prove empty). Shared by
 *		whole-chunk (group) and per-vector skipping (native spec 7.1). Decodes the
 *		stored min/max in cx.
 */
static bool
native_zone_excludes(SkipPredicate *pred, Form_pg_attribute att,
					 NativeZoneMapMetadata *z, MemoryContext cx)
{
	char	   *cur;
	Datum		minv;
	Datum		maxv;
	int32		c1;
	int32		c2;

	if (z == NULL || !z->hasMinMax)
		return false;

	cur = (char *) z->minimum;
	minv = PgColumnarDecodeValue(att, &cur, cx);
	cur = (char *) z->maximum;
	maxv = PgColumnarDecodeValue(att, &cur, cx);

	switch (pred->strategy)
	{
		case BTLessStrategyNumber:	/* col < const : skip if min >= const */
			c1 = DatumGetInt32(FunctionCall2Coll(&pred->cmpFn, pred->collation,
												 minv, pred->compareValue));
			return (c1 >= 0);
		case BTLessEqualStrategyNumber: /* col <= const : skip if min > const */
			c1 = DatumGetInt32(FunctionCall2Coll(&pred->cmpFn, pred->collation,
												 minv, pred->compareValue));
			return (c1 > 0);
		case BTEqualStrategyNumber: /* col = const : skip if min>const or max<const */

			/*
			 * Column first, constant second, like every other branch here.
			 *
			 * This read cmp(const, min) and cmp(const, max), which is equivalent
			 * for a same-type proc and WRONG for a cross-type one (#477): the
			 * argument order is part of a cross-type proc's signature, so
			 * btint84cmp(int8, int4) handed (int4, int8) reads both operands from
			 * the wrong widths. Same test, stated from the column's side.
			 */
			c1 = DatumGetInt32(FunctionCall2Coll(&pred->cmpFn, pred->collation,
												 minv, pred->compareValue));
			c2 = DatumGetInt32(FunctionCall2Coll(&pred->cmpFn, pred->collation,
												 maxv, pred->compareValue));
			return (c1 > 0 || c2 < 0);
		case BTGreaterEqualStrategyNumber:	/* col >= const : skip if max < const */
			c2 = DatumGetInt32(FunctionCall2Coll(&pred->cmpFn, pred->collation,
												 maxv, pred->compareValue));
			return (c2 < 0);
		case BTGreaterStrategyNumber:	/* col > const : skip if max <= const */
			c2 = DatumGetInt32(FunctionCall2Coll(&pred->cmpFn, pred->collation,
												 maxv, pred->compareValue));
			return (c2 <= 0);
		default:
			return false;
	}
}

/*
 * pgcolumnar_native_group_can_match
 *		Decide whether a native row group could hold a row satisfying every
 *		pushed-down predicate, using its whole-chunk zone maps (native spec 7.1,
 *		Phase D5b). Returns false when the group can be skipped. Mirrors the 2.2
 *		pgcolumnar_group_can_match, reading min/max from pgcolumnar.zone_map instead
 *		of the 2.2 chunk catalog. A missing or non-orderable zone map is treated
 *		conservatively as "may match". Runs in rs->skipContext (caller-reset).
 */
static bool
pgcolumnar_native_group_can_match(PgColumnarReadState *rs, uint64 groupNumber)
{
	List	   *zones;
	NativeZoneMapMetadata **byCol;
	NativeBloomMetadata **byColBloom = NULL;
	bool	   *bloomLookedUp = NULL;
	ListCell   *lc;
	int			p;

	if (rs->numPredicates == 0)
		return true;

	zones = PgColumnarReadZoneMapList(rs->storageId, groupNumber, rs->metaSnapshot);
	byCol = palloc0(sizeof(NativeZoneMapMetadata *) * rs->natts);
	foreach(lc, zones)
	{
		NativeZoneMapMetadata *z = (NativeZoneMapMetadata *) lfirst(lc);

		if (z->columnIndex >= 0 && z->columnIndex < rs->natts)
			byCol[z->columnIndex] = z;
	}

	for (p = 0; p < rs->numPredicates; p++)
	{
		SkipPredicate *pred = &rs->predicates[p];
		Form_pg_attribute att = TupleDescAttr(rs->tupdesc, pred->attidx);

		if (native_zone_excludes(pred, att, byCol[pred->attidx], rs->skipContext))
			return false;

		/*
		 * min/max did not rule the group out; for equality consult the per-chunk
		 * bloom filter (native spec 7.2), which prunes equality probes on unsorted
		 * columns that min/max cannot.
		 */
		if (pred->strategy == BTEqualStrategyNumber &&
			pgcolumnar_enable_bloom_filter && pred->hasHash)
		{
			NativeBloomMetadata *b;

			/*
			 * Fetch this column's bloom filter on first use: not up front, and
			 * not the whole group's.
			 *
			 * A bloom filter is only consulted for an equality predicate whose
			 * zone map did not already rule the group out, so a group that the
			 * zone map skips needs none of them (#310). And a predicate probes
			 * one column, so a group that is examined needs the filters of the
			 * columns carrying predicates and no others (#314).
			 *
			 * Neither saving is small. A filter holds one bitmap per column
			 * sized by the group's distinct values, so it is among the larger
			 * things in the catalog. Reading a whole group's worth cost 466
			 * buffers per skipped group out of 504 on 20 groups of 200,000 rows
			 * over 12 columns, and 464 of 715 buffers on a single group scanned
			 * whole with one predicate.
			 *
			 * bloomLookedUp records the fetch, not the result, so a column with
			 * no filter is looked up once rather than on every predicate.
			 */
			if (byColBloom == NULL)
			{
				byColBloom = palloc0(sizeof(NativeBloomMetadata *) * rs->natts);
				bloomLookedUp = palloc0(sizeof(bool) * rs->natts);
			}
			if (!bloomLookedUp[pred->attidx])
			{
				byColBloom[pred->attidx] =
					PgColumnarReadBloomForColumn(rs->storageId, groupNumber,
											   pred->attidx, rs->metaSnapshot);
				bloomLookedUp[pred->attidx] = true;
			}
			b = byColBloom[pred->attidx];

			if (b != NULL && b->filter != NULL)
			{
				uint32		h = DatumGetUInt32(
					FunctionCall1Coll(&pred->hashFn, pred->hashCollation,
									  pred->compareValue));

				if (!PgColumnarBloomProbe(b->filter, b->filterLen, h))
					return false;
			}
		}
	}

	return true;
}

/*
 * PgColumnarEstimatePruneSurvival
 *		The fraction of chunk groups a restricted scan would actually read, in
 *		(0, 1], estimated from a bounded SAMPLE of the groups' zone maps. One
 *		means nothing prunes; a missing or unusable predicate returns one.
 *
 *		Why this exists (#461). The cost model priced pruning from
 *		pg_stats.correlation, and pruning does not follow correlation.
 *		Correlation measures agreement between value order and physical order
 *		across the WHOLE relation; a zone map only needs each GROUP's min and max
 *		to be narrow, which is local. A table can be globally unsorted and locally
 *		tight at once, and batch-loaded time-series data -- the shape this engine
 *		is built for -- is exactly that. Measured on TSBS in #391: the `time`
 *		column had correlation 0.0133 and removed 82 percent of chunk groups, so a
 *		model reading rho^2 credited it with nothing. #381 made that mistake in
 *		documentation and #391 corrected it; the planner then reintroduced it.
 *
 *		So this asks the question the reader will ask, using the reader's own
 *		predicates and the reader's own min/max comparison, rather than inferring
 *		prunability from a statistic that cannot see it. The error direction of a
 *		proxy is unknowable; the error of a sample is just sampling error.
 *
 *		SAMPLED rather than exact, and the bound is the point. Evaluating every
 *		group is O(groups) catalog reads on every plan, including plans the
 *		planner discards -- 10,000 groups on a 100M-row table at the default group
 *		size. A fixed sample is constant work whatever the table's size, and
 *		costing does not need three digits: the decision this feeds is which of
 *		two plans is cheaper, and the floor below already guards the case where
 *		being wrong is expensive.
 *
 *		Group numbers are sampled evenly across [0, ngroups) rather than read from
 *		the row-group list, because reading that list is the O(groups) cost being
 *		avoided. A sampled number with no zone map rows (vacuumed away, or a stale
 *		ngroups estimate) is not counted rather than counted as surviving, so a
 *		sparse group space narrows the sample instead of biasing it toward 1.0.
 *
 *		The bloom filter is deliberately NOT consulted. Filters are among the
 *		larger things in the catalog and reading them per sampled group would cost
 *		more than the estimate is worth; min/max is the dominant effect and
 *		ignoring bloom can only UNDER-credit, which prices the columnar scan high
 *		and is the safe direction.
 */
double
PgColumnarEstimatePruneSurvival(uint64 storageId, TupleDesc tupdesc, List *qual,
								Index scanrelid, uint64 ngroups, int sampleTarget)
{
	ScanKey		keys;
	int			nkeys = 0;
	SkipPredicate *preds;
	int			npreds;
	Snapshot	snap;
	MemoryContext cx;
	MemoryContext old;
	int			nsample;
	int			i;
	int			examined = 0;
	int			survived = 0;
	double		survival;

	if (ngroups == 0 || tupdesc == NULL || qual == NIL)
		return 1.0;
	if (!pgcolumnar_enable_qual_pushdown)
		return 1.0;

	snap = GetActiveSnapshot();
	if (snap == NULL)
		return 1.0;

	cx = AllocSetContextCreate(CurrentMemoryContext,
							   "columnar prune estimate",
							   ALLOCSET_SMALL_SIZES);
	old = MemoryContextSwitchTo(cx);

	keys = PgColumnarBuildScanKeys(qual, scanrelid, tupdesc, &nkeys);
	if (nkeys <= 0)
	{
		MemoryContextSwitchTo(old);
		MemoryContextDelete(cx);
		return 1.0;
	}

	preds = palloc0(sizeof(SkipPredicate) * nkeys);
	npreds = pgcolumnar_make_predicates(preds, nkeys, keys, tupdesc,
										tupdesc->natts, cx);
	if (npreds == 0)
	{
		MemoryContextSwitchTo(old);
		MemoryContextDelete(cx);
		return 1.0;
	}

	nsample = (ngroups < (uint64) sampleTarget) ? (int) ngroups : sampleTarget;
	if (nsample <= 0)
	{
		MemoryContextSwitchTo(old);
		MemoryContextDelete(cx);
		return 1.0;
	}

	for (i = 0; i < nsample; i++)
	{
		uint64		g = (uint64) (((double) i * (double) ngroups) / (double) nsample);
		List	   *zones;
		NativeZoneMapMetadata **byCol;
		ListCell   *lc;
		bool		canMatch = true;
		int			p;

		CHECK_FOR_INTERRUPTS();

		zones = PgColumnarReadZoneMapList(storageId, g, snap);
		if (zones == NIL)
			continue;			/* no such group: narrow the sample, do not bias it */

		examined++;

		byCol = palloc0(sizeof(NativeZoneMapMetadata *) * tupdesc->natts);
		foreach(lc, zones)
		{
			NativeZoneMapMetadata *z = (NativeZoneMapMetadata *) lfirst(lc);

			if (z->columnIndex >= 0 && z->columnIndex < tupdesc->natts)
				byCol[z->columnIndex] = z;
		}

		for (p = 0; p < npreds; p++)
		{
			Form_pg_attribute att = TupleDescAttr(tupdesc, preds[p].attidx);

			if (native_zone_excludes(&preds[p], att, byCol[preds[p].attidx], cx))
			{
				canMatch = false;
				break;
			}
		}

		if (canMatch)
			survived++;
	}

	MemoryContextSwitchTo(old);

	/*
	 * No group could be examined -- every sampled number was absent. That is a
	 * failure to measure, not a measurement of "nothing prunes", so say the
	 * conservative thing rather than inventing a discount.
	 */
	survival = (examined > 0) ? ((double) survived / (double) examined) : 1.0;

	MemoryContextDelete(cx);

	return survival;
}

/*
 * pgcolumnar_native_build_skipvec
 *		Build the per-vector skip flags for a loaded row group (native spec 7.1,
 *		Phase D5b): vector v is skipped when any predicate's per-vector zone map
 *		proves no row in it can match. Also fills rs->nativeVecStart with the
 *		cumulative row spans (from the zone maps' value+null counts, so it is
 *		correct for any chunk-group size). Sets rs->nativeSkipVec (or NULL when
 *		nothing is skippable or no per-vector zone maps exist) and
 *		rs->nativeVectorCount. Runs in the group context (caller-switched); decodes
 *		min/max in rs->skipContext.
 */
static void
pgcolumnar_native_build_skipvec(PgColumnarReadState *rs, uint64 groupNumber, int vecCount)
{
	List	   *zones;
	NativeZoneMapMetadata ***byColVec;
	uint32	   *span;
	bool	   *skip;
	bool		any = false;
	ListCell   *lc;
	int			v;
	int			p;

	rs->nativeSkipVec = NULL;
	rs->nativeVecStart = NULL;
	rs->nativeVectorCount = vecCount;
	rs->nativeCurVec = 0;

	if (vecCount <= 0)
		return;

	/*
	 * Build the mask and the per-vector spans whenever something will CONSULT
	 * them: reader predicates (1b-ii), or an unprunable executor qual (#452
	 * phase 2), which sets nativeQualFilter. With neither, a mask is pure
	 * overhead and the plain scan path leaves both NULL exactly as before. The
	 * predicate-exclusion loop below is a no-op when numPredicates is 0, so the
	 * phase-2 case falls through it with an all-false mask for its evaluator to
	 * fill.
	 */
	if (rs->numPredicates == 0 && rs->nativeQualFilter == NULL)
		return;

	zones = PgColumnarReadZoneMapVectors(rs->storageId, groupNumber, rs->metaSnapshot);
	if (zones == NIL)
		return;					/* legacy: no per-vector zone maps */

	/* per-predicate-column lookup [column][vector] */
	byColVec = (NativeZoneMapMetadata ***)
		palloc0(sizeof(NativeZoneMapMetadata **) * rs->natts);
	for (p = 0; p < rs->numPredicates; p++)
	{
		int			col = rs->predicates[p].attidx;

		if (col >= 0 && col < rs->natts && byColVec[col] == NULL)
			byColVec[col] = (NativeZoneMapMetadata **)
				palloc0(sizeof(NativeZoneMapMetadata *) * vecCount);
	}

	span = (uint32 *) palloc0(sizeof(uint32) * vecCount);
	foreach(lc, zones)
	{
		NativeZoneMapMetadata *z = (NativeZoneMapMetadata *) lfirst(lc);

		if (z->vectorIndex < 0 || z->vectorIndex >= vecCount)
			continue;
		span[z->vectorIndex] = (uint32) (z->valueCount + z->nullCount);
		if (z->columnIndex >= 0 && z->columnIndex < rs->natts &&
			byColVec[z->columnIndex] != NULL)
			byColVec[z->columnIndex][z->vectorIndex] = z;
	}

	MemoryContextReset(rs->skipContext);
	skip = (bool *) palloc0(sizeof(bool) * vecCount);
	for (v = 0; v < vecCount; v++)
	{
		for (p = 0; p < rs->numPredicates; p++)
		{
			SkipPredicate *pred = &rs->predicates[p];
			Form_pg_attribute att = TupleDescAttr(rs->tupdesc, pred->attidx);
			NativeZoneMapMetadata *z = byColVec[pred->attidx]
				? byColVec[pred->attidx][v] : NULL;

			if (native_zone_excludes(pred, att, z, rs->skipContext))
			{
				skip[v] = true;
				any = true;
				break;
			}
		}
	}

	/* cumulative row spans, for mapping a row to its vector */
	rs->nativeVecStart = (uint32 *) palloc0(sizeof(uint32) * (vecCount + 1));
	for (v = 0; v < vecCount; v++)
		rs->nativeVecStart[v + 1] = rs->nativeVecStart[v] + span[v];

	/*
	 * Kept even when the zone maps ruled nothing out, which they usually do not.
	 *
	 * This was `any ? skip : NULL`, and returning NULL there was a fair
	 * optimisation while zone maps were the only thing that could set a bit: an
	 * all-false mask is pure overhead to consult. Exact selection (#452 phase
	 * 1b-ii) writes into this same mask AFTER this function returns, and the
	 * case it exists for is precisely the one where the zone maps found nothing.
	 * Returning NULL there left it nowhere to write, silently, and the suite
	 * measured no saving at all.
	 */
	rs->nativeSkipVec = skip;
	(void) any;
}

/* a half-open span of the row group's bytes, used to build coalesced reads */
typedef struct PgColumnarByteRange
{
	uint64		start;
	uint64		end;
} PgColumnarByteRange;

/*
 * pgcolumnar_byte_range_cmp
 *		Order byte ranges by start offset, so adjacent ones can be coalesced.
 */
static int
pgcolumnar_byte_range_cmp(const void *a, const void *b)
{
	uint64		sa = ((const PgColumnarByteRange *) a)->start;
	uint64		sb = ((const PgColumnarByteRange *) b)->start;

	if (sa < sb)
		return -1;
	if (sa > sb)
		return 1;
	return 0;
}

/*
 * pgcolumnar_native_read_projected
 *		Read only the byte ranges the projected columns occupy (#338), rather
 *		than the whole row group.
 *
 *		Ranges that touch or overlap in the file are coalesced, so a projection
 *		covering neighbouring columns costs one read rather than one per column.
 *		Chunks are written column-major (pgcolumnar_write_state.c), so in practice
 *		a projection is a small number of runs. Everything lands at its natural
 *		offset inside the full-size group buffer, leaving the rest untouched.
 */
static void
pgcolumnar_native_read_projected(PgColumnarReadState *rs,
							   NativeRowGroupMetadata *rg, List *chunks)
{
	PgColumnarByteRange *ranges;
	uint64		groupEnd = rg->fileOffset + rg->byteLength;
	uint64		minStart = groupEnd;
	uint64		maxEnd = rg->fileOffset;
	bool		sawChunk = false;
	int			n = 0;
	int			i;
	ListCell   *lc;

	if (chunks == NIL)
		return;

	ranges = (PgColumnarByteRange *)
		palloc(sizeof(PgColumnarByteRange) * list_length(chunks));

	foreach(lc, chunks)
	{
		NativeColumnChunkMetadata *cc = (NativeColumnChunkMetadata *) lfirst(lc);

		if (cc->columnIndex < 0 || cc->columnIndex >= rs->natts)
			continue;

		/*
		 * Track the extent of every chunk, wanted or not, so the group can be
		 * validated below.
		 */
		if (cc->pageLength > 0)
		{
			if (cc->pageOffset < minStart)
				minStart = cc->pageOffset;
			if (cc->pageOffset + cc->pageLength > maxEnd)
				maxEnd = cc->pageOffset + cc->pageLength;
			sawChunk = true;
		}

		if (!rs->colWanted[cc->columnIndex])
			continue;
		if (cc->pageLength == 0)
			continue;

		/*
		 * The chunk must lie inside the group it belongs to. The whole-group
		 * read never had to check this because it read the group as one span;
		 * reading per chunk turns a bad catalog row into an out-of-bounds write,
		 * so it is checked rather than assumed.
		 */
		if (cc->pageOffset < rg->fileOffset ||
			cc->pageOffset + cc->pageLength > groupEnd)
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("columnar chunk for column %d lies outside row group " UINT64_FORMAT,
							cc->columnIndex + 1, rg->groupNumber),
					 errdetail("Chunk spans [" UINT64_FORMAT ", " UINT64_FORMAT ") but the row group is ["
							   UINT64_FORMAT ", " UINT64_FORMAT ").",
							   cc->pageOffset, cc->pageOffset + cc->pageLength,
							   rg->fileOffset, groupEnd)));

		ranges[n].start = cc->pageOffset;
		ranges[n].end = cc->pageOffset + cc->pageLength;
		n++;
	}

	/*
	 * The chunks must exactly tile the row group they belong to: the writer
	 * lays them out column-major, back to back, and sets byte_length to their
	 * total, with no padding between them (verified across plain inserts, ADD
	 * COLUMN, stored generated columns, updates and deletes, compact,
	 * vacuum_sorted, block-compressed columns, and VACUUM FULL).
	 *
	 * Checking it here is what keeps a corrupt row_group.byte_length detectable.
	 * The whole-group read caught that incidentally, by trying to read a length
	 * that ran past the end of the relation; a projected read only touches the
	 * chunk ranges, so an inflated byte_length would otherwise go unnoticed and
	 * be silently tolerated. This is the more direct check anyway -- it names
	 * the inconsistency rather than surfacing as a short read.
	 *
	 * Reads with no projection keep the old path untouched, so
	 * pgcolumnar.enable_column_projection=off remains a way back if a layout
	 * this does not anticipate ever turns up.
	 */
	if (sawChunk && (maxEnd != groupEnd || minStart != rg->fileOffset))
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("columnar row group " UINT64_FORMAT " is inconsistent with its column chunks",
						rg->groupNumber),
				 errdetail("The group spans [" UINT64_FORMAT ", " UINT64_FORMAT ") but its chunks span ["
						   UINT64_FORMAT ", " UINT64_FORMAT ").",
						   rg->fileOffset, groupEnd, minStart, maxEnd)));

	/* every projected column postdates this group (ADD COLUMN): nothing to read */
	if (n == 0)
		return;

	qsort(ranges, n, sizeof(PgColumnarByteRange), pgcolumnar_byte_range_cmp);

	for (i = 0; i < n;)
	{
		uint64		start = ranges[i].start;
		uint64		end = ranges[i].end;
		int			j = i + 1;

		while (j < n && ranges[j].start <= end)
		{
			if (ranges[j].end > end)
				end = ranges[j].end;
			j++;
		}

		PgColumnarReadLogicalData(rs->rel, start,
								rs->nativeBuffer + (start - rg->fileOffset),
								end - start);
		i = j;
	}

	pfree(ranges);
}

/*
 * pgcolumnar_native_qual_probe_selective
 *		#595 prototype: before paying qual_skipvec's per-vector evaluation over the
 *		whole group, probe the first N vectors and report whether the qual is
 *		selective enough to be worth it. Read-only -- it evaluates the qual on the
 *		probed vectors but masks nothing, counts nothing, and saves/restores the
 *		qual columns' cursors exactly as qual_skipvec does, so it is invisible to
 *		everything downstream. Returns true when at least min_skip_pct percent of
 *		the probed vectors have no surviving row (so gating them skips real payload
 *		decode); false leaves gating off, sparing an unselective scan the
 *		whole-group evaluation that #595 measured as a 1.2-2x regression.
 */
static bool
pgcolumnar_native_qual_probe_selective(PgColumnarReadState *rs, int vecCount)
{
	char	  **saved;
	int			c;
	int			v;
	int			probeVecs = Min(vecCount, pgcolumnar_qual_skipvec_probe_vecs);
	int			nSkippable = 0;

	/* probe disabled: always gate, the pre-#595 behaviour */
	if (pgcolumnar_qual_skipvec_probe_vecs <= 0)
		return true;

	/*
	 * Uses the NO-COUNT filter: the probe only measures selectivity, it must not
	 * touch "Rows Removed by Filter". qual_skipvec, if we then run it, is the
	 * group's sole counter. Counting here too would double-count the probed
	 * vectors' rejects.
	 */
	if (rs->nativeSkipVec == NULL || rs->nativeVecStart == NULL ||
		rs->nativeQualFilterNoCount == NULL || rs->nativeQualValues == NULL ||
		probeVecs <= 0)
		return false;

	saved = (char **) palloc(sizeof(char *) * rs->natts);
	for (c = 0; c < rs->natts; c++)
		saved[c] = rs->nativeValueCursor[c];

	for (v = 0; v < probeVecs; v++)
	{
		uint32		r0 = rs->nativeVecStart[v];
		uint32		r1 = rs->nativeVecStart[v + 1];
		uint32		r;
		bool		anyPass = false;

		for (r = r0; r < r1; r++)
		{
			MemoryContext oldContext;
			bool		deleted;

			rs->rowInGroup = r;
			deleted = (rs->nativeDeleteMask != NULL &&
					   (r >> 3) < rs->nativeDeleteMaskLen &&
					   (rs->nativeDeleteMask[r >> 3] & (1 << (r & 7))) != 0);

			MemoryContextReset(rs->rowContext);
			oldContext = MemoryContextSwitchTo(rs->rowContext);
			for (c = 0; c < rs->natts; c++)
			{
				if (native_is_qual_column(rs, c))
					pgcolumnar_row_read_column(rs, c, rs->nativeQualValues,
											 rs->nativeQualNulls);
				else
				{
					rs->nativeQualValues[c] = (Datum) 0;
					rs->nativeQualNulls[c] = true;
				}
			}
			MemoryContextSwitchTo(oldContext);

			if (deleted)
				continue;
			if (rs->nativeQualFilterNoCount(rs->nativeQualFilterArg))
				anyPass = true;
		}
		if (!anyPass)
			nSkippable++;
	}

	for (c = 0; c < rs->natts; c++)
		rs->nativeValueCursor[c] = saved[c];

	return (nSkippable * 100 >= probeVecs * pgcolumnar_qual_skipvec_min_skip_pct);
}

/*
 * pgcolumnar_native_qual_skipvec
 *		Extend the skip vector from an UNPRUNABLE qual (#452 phase 2).
 *
 *		refine_skipvec turns min/max non-exclusion into "no row matches" for
 *		reader predicates; this does the same for a qual the reader never admitted
 *		as a predicate at all -- a leading-wildcard LIKE, whose numPredicates is 0.
 *		Called between the two decode passes: the qual columns are decoded (they
 *		are pass 0 once native_is_qual_column answers for the executor qualCols),
 *		the payload columns are not, so a vector ruled out here costs the payload
 *		columns no decode. That ordering IS the optimisation.
 *
 *		The evaluation reuses 1a's exact callback -- the same ExprState the row
 *		producer trusts -- so a vector is masked only when NO row in it passes.
 *		A surviving row keeps the whole vector's payload decoded, which is
 *		correct: decode granularity is the vector. Missing a skip costs time;
 *		taking a wrong one would drop rows, so the asymmetry runs the safe way.
 *
 *		The qual columns' value cursors are saved and restored: the producer reads
 *		them from where pass 0 left them, so this non-destructive walk must not
 *		advance them. rowInGroup is set per row here and reset to 0 by load_group
 *		after both passes, so it needs no restore.
 */
static void
pgcolumnar_native_qual_skipvec(PgColumnarReadState *rs, int vecCount)
{
	char	  **saved;
	int			c;
	int			v;

	if (rs->nativeSkipVec == NULL || rs->nativeVecStart == NULL ||
		rs->nativeQualFilter == NULL || rs->nativeQualValues == NULL ||
		vecCount <= 0)
		return;

	/*
	 * This evaluator becomes the group's SOLE counter of "Rows Removed by
	 * Filter": it walks every live row, so every rejection is counted here once,
	 * through the counting filter. The producer must then filter through the
	 * NON-counting variant on this path (nativeQualCounted tells it so), or a
	 * rejection in a surviving vector -- which the producer re-tests to find the
	 * rows to emit -- would be counted a second time.
	 */
	rs->nativeQualCounted = true;

	/* Stable across the per-row rowContext resets below: not in rowContext. */
	saved = (char **) palloc(sizeof(char *) * rs->natts);
	for (c = 0; c < rs->natts; c++)
		saved[c] = rs->nativeValueCursor[c];

	for (v = 0; v < vecCount; v++)
	{
		uint32		r0 = rs->nativeVecStart[v];
		uint32		r1 = rs->nativeVecStart[v + 1];
		uint32		r;
		bool		anyPass = false;
		uint64		liveRows = 0;

		/*
		 * Every live row of the vector is walked, even once one has passed:
		 * the qual columns' cursors are contiguous and the NEXT vector reads from
		 * where this one ends, so breaking early would leave the cursor short --
		 * and this is the one pass that counts each rejection.
		 */
		for (r = r0; r < r1; r++)
		{
			MemoryContext oldContext;
			bool		deleted;

			rs->rowInGroup = r;

			deleted = (rs->nativeDeleteMask != NULL &&
					   (r >> 3) < rs->nativeDeleteMaskLen &&
					   (rs->nativeDeleteMask[r >> 3] & (1 << (r & 7))) != 0);

			MemoryContextReset(rs->rowContext);
			oldContext = MemoryContextSwitchTo(rs->rowContext);

			for (c = 0; c < rs->natts; c++)
			{
				if (native_is_qual_column(rs, c))
					pgcolumnar_row_read_column(rs, c, rs->nativeQualValues,
											 rs->nativeQualNulls);
				else
				{
					/* payload is not decoded yet (pass 1); the qual never reads
					 * it, so a NULL placeholder completes the tuple harmlessly. */
					rs->nativeQualValues[c] = (Datum) 0;
					rs->nativeQualNulls[c] = true;
				}
			}

			MemoryContextSwitchTo(oldContext);

			/*
			 * A deleted row is invisible: it neither counts as filtered nor keeps
			 * the vector alive, though its cursors were advanced above so the walk
			 * stays aligned. Every live row is asked, and the counting filter
			 * records the ones it rejects.
			 */
			if (deleted)
				continue;
			liveRows++;
			if (rs->nativeQualFilter(rs->nativeQualFilterArg))
				anyPass = true;
		}

		/*
		 * A vector no live row passed is skipped: its payload columns are never
		 * decoded and the producer never reaches its rows. Those rows are
		 * filtered before materialization exactly as the producer's own rejects
		 * are, so they join that counter here, where they are ruled out (#542's
		 * principle: count the skip where it happens).
		 */
		if (!anyPass)
		{
			rs->nativeSkipVec[v] = true;
			rs->rowsFilteredEarly += liveRows;
		}
	}

	for (c = 0; c < rs->natts; c++)
		rs->nativeValueCursor[c] = saved[c];
}

/*
 * pgcolumnar_native_load_group
 *		Load the next native row group (PGCN v1, Phase D3): read the bytes of the
 *		projected columns into the group context and set each such column's
 *		validity-bitmap pointer and values cursor. Row groups the zone maps prove
 *		cannot match are skipped (Phase D5b). Returns false when no more row
 *		groups remain.
 *
 *		Without a projection this reads the group whole, as it always has. With
 *		one it reads and decodes only the wanted columns (#338); the others are
 *		left unmaterialised and the row loop emits NULL for them.
 */
static bool
pgcolumnar_native_load_group(PgColumnarReadState *rs)
{
	MemoryContext oldContext;
	NativeRowGroupMetadata *rg;
	List	   *chunks;
	ListCell   *lc;
	int			validityBytes;
	int			maxVecCount;
	int			groupVecDecoded;	/* measured in the decode loop, never derived */
	int			pass;
	bool		allDescriptor;

	/*
	 * Claim the next row group and advance past any the zone maps rule out
	 * (native spec 7.1). Under a parallel custom scan each worker claims distinct
	 * groups from the shared counter (pgcolumnar_next_group_index), so a group is
	 * read by exactly one backend; serially it walks rowGroupIndex. Without the
	 * counter every worker read every group and a parallel scan returned each row
	 * once per participating backend (D6e).
	 */
	rg = NULL;
	for (;;)
	{
		int64		gi = pgcolumnar_next_group_index(rs);
		bool		match = true;

		if (gi < 0)
			return false;

		rg = (NativeRowGroupMetadata *) list_nth(rs->rowGroupList, (int) gi);
		if (rs->restrictGroups != NULL &&
			!pgcolumnar_group_is_restricted_in(rs, rg->groupNumber))
			match = false;
		else if (rs->numPredicates > 0)
		{
			MemoryContext old = MemoryContextSwitchTo(rs->skipContext);

			MemoryContextReset(rs->skipContext);
			match = pgcolumnar_native_group_can_match(rs, rg->groupNumber);
			MemoryContextSwitchTo(old);
		}
		if (match)
			break;

		rs->groupsSkipped++;
	}

	rs->groupsRead++;

	MemoryContextReset(rs->groupContext);
	oldContext = MemoryContextSwitchTo(rs->groupContext);
	rs->nativeGroup = rg;

	/*
	 * Native delete visibility (D6b): combine this group's row-mask rows (keyed
	 * by group number, one bit per row-in-group) into a single delete mask that
	 * pgcolumnar_native_next_row consults to skip deleted rows.
	 *
	 * Built HERE, right after the group context is reset and re-entered, and NOT
	 * after the decode passes as it once was. #452 phase 2's between-pass
	 * evaluator reads this mask to keep deleted rows from counting toward "does
	 * any row pass" and the reject tally. Built later, the evaluator would read
	 * the PREVIOUS group's mask, which the reset above just freed -- a
	 * use-after-free that only a table with deleted rows under an unprunable qual
	 * could reach, and only on the second group onward. The mask is palloc0'd in
	 * groupContext, so this ordering also gives it the same lifetime it had.
	 */
	rs->nativeDeleteMask = NULL;
	rs->nativeDeleteMaskLen = 0;
	{
		List	   *maskList = PgColumnarReadDeleteVectorList(rs->storageId,
													   rg->groupNumber,
													   rs->metaSnapshot);
		ListCell   *mlc;
		uint32		want = (uint32) ((rg->rowCount + 7) / 8);

		foreach(mlc, maskList)
		{
			DeleteVectorMetadata *rm = (DeleteVectorMetadata *) lfirst(mlc);
			uint32		i;

			if (rm->bitmap == NULL || rm->bitmapLen == 0)
				continue;
			if (rs->nativeDeleteMask == NULL)
			{
				rs->nativeDeleteMask = palloc0(want > 0 ? want : 1);
				rs->nativeDeleteMaskLen = want;
			}
			for (i = 0; i < rm->bitmapLen && i < want; i++)
				rs->nativeDeleteMask[i] |= rm->bitmap[i];
		}
	}

	/*
	 * The chunk metadata is read before the data (#338) because it carries the
	 * per-column byte ranges the projected read needs. It is a catalog read and
	 * touches none of the group's data pages.
	 */
	chunks = PgColumnarReadColumnChunkList(rs->storageId, rg->groupNumber,
										 rs->metaSnapshot);

	/*
	 * Column projection (#338). The buffer is always allocated at full group
	 * size so the base = nativeBuffer + (pageOffset - fileOffset) arithmetic
	 * below stays valid for every chunk; only the wanted ranges are read into
	 * it. palloc does not touch the pages it hands back, so the regions that are
	 * never read cost no resident memory.
	 */
	rs->nativeBuffer = palloc(rg->byteLength > 0 ? rg->byteLength : 1);
	if (rg->byteLength > 0)
	{
		if (rs->allColumnsWanted)
			PgColumnarReadLogicalData(rs->rel, rg->fileOffset, rs->nativeBuffer,
									rg->byteLength);
		else
			pgcolumnar_native_read_projected(rs, rg, chunks);
	}

	rs->nativeValidity = palloc0(sizeof(char *) * rs->natts);
	rs->nativeValueCursor = palloc0(sizeof(char *) * rs->natts);
	rs->nativeVecRawLen = (uint32 **) palloc0(sizeof(uint32 *) * rs->natts);
	validityBytes = (int) ((rg->rowCount + 7) / 8);
	maxVecCount = 0;
	groupVecDecoded = 0;
	allDescriptor = (chunks != NIL);

	/*
	 * #452 phase 1b-i: the skip vector has to exist BEFORE the decode loop, or
	 * decode cannot honour it. It used to be built afterwards, from the vector
	 * count the decode returned, which is why every ruled-out vector was decoded
	 * in full and then merely not turned into Datums.
	 *
	 * Nothing about that ordering was necessary. The vector count lives in the
	 * encoding descriptor header, which is chunk METADATA already in hand, and
	 * build_skipvec's only other inputs are the predicates and the zone map
	 * catalog. So this pre-pass reads the count and decides allDescriptor without
	 * touching a single value byte.
	 */
	{
		ListCell   *pc;

		foreach(pc, chunks)
		{
			NativeColumnChunkMetadata *cc = (NativeColumnChunkMetadata *) lfirst(pc);
			uint32		vc;

			if (cc->columnIndex < 0 || cc->columnIndex >= rs->natts)
				continue;
			if (!rs->colWanted[cc->columnIndex])
				continue;

			if (cc->encodingDescriptorLen == 1 &&
				(uint8) cc->encodingDescriptor[0] == COLUMNAR_NATIVE_ENCDESC_BASELINE)
			{
				/* D2b baseline: no per-vector structure at all */
				allDescriptor = false;
				continue;
			}

			/*
			 * A descriptor too short to hold its own header is corrupt. Say
			 * nothing about it here and decode no fewer vectors for it: the
			 * decode below raises the proper error with the proper message, and
			 * a skip decided from a malformed header would be a silent wrong
			 * answer instead of a loud one.
			 */
			if (cc->encodingDescriptorLen < COLUMNAR_NATIVE_ENCDESC_HEADER_LEN ||
				(uint8) cc->encodingDescriptor[0] != COLUMNAR_NATIVE_ENCDESC_VERSION)
			{
				allDescriptor = false;
				continue;
			}

			memcpy(&vc, cc->encodingDescriptor + 2, sizeof(uint32));
			if ((int) vc > maxVecCount)
				maxVecCount = (int) vc;
		}
	}

	if (allDescriptor)
		pgcolumnar_native_build_skipvec(rs, rg->groupNumber, maxVecCount);
	else
	{
		rs->nativeSkipVec = NULL;
		rs->nativeVecStart = NULL;
		rs->nativeVectorCount = maxVecCount;
		rs->nativeCurVec = 0;
	}

	/*
	 * Two passes, and the order is the whole of #452 phase 1b-ii.
	 *
	 * Pass 0 decodes only the columns a pushed-down predicate reads. Exact
	 * selection then evaluates those predicates against the decoded values and
	 * turns "the zone maps could not rule this vector out" into "no row in it
	 * matches". Pass 1 decodes everything else against that sharpened mask, so a
	 * vector holding no matching row costs the payload columns nothing.
	 *
	 * Run as one pass, the refinement still produces a correct mask and saves
	 * exactly nothing, because the payload columns are already decoded by then.
	 */
	rs->nativeQualCounted = false;
	for (pass = 0; pass < 2; pass++)
	{
	if (pass == 1 && allDescriptor)
		pgcolumnar_native_refine_skipvec(rs, maxVecCount);

	/*
	 * #452 phase 2: refine_skipvec did nothing (no predicate to refine), so an
	 * unprunable qual gets its per-vector chance here, between the passes. Same
	 * guard shape as refine's, and mutually exclusive with it on numPredicates.
	 */
	if (pass == 1 && allDescriptor && rs->numPredicates == 0 &&
		pgcolumnar_native_qual_probe_selective(rs, maxVecCount))
		pgcolumnar_native_qual_skipvec(rs, maxVecCount);

	foreach(lc, chunks)
	{
		NativeColumnChunkMetadata *cc = (NativeColumnChunkMetadata *) lfirst(lc);
		char	   *base;

		/* decoding a column chunk is the expensive part of loading a group */
		CHECK_FOR_INTERRUPTS();

		if (cc->columnIndex < 0 || cc->columnIndex >= rs->natts)
			continue;

		/* pass 0 is the qual columns, pass 1 is the rest */
		if (native_is_qual_column(rs, cc->columnIndex) != (pass == 0))
			continue;

		/*
		 * Not projected (#338): its bytes were never read, so decoding it would
		 * read uninitialized buffer. Leaving nativeValidity NULL is what marks
		 * the column unmaterialised for the row loop, which emits an explicit
		 * NULL for it rather than the ADD COLUMN missing value.
		 */
		if (!rs->colWanted[cc->columnIndex])
			continue;

		base = rs->nativeBuffer + (cc->pageOffset - rg->fileOffset);
		rs->nativeValidity[cc->columnIndex] = base;

		if (cc->encodingDescriptorLen == 1 &&
			(uint8) cc->encodingDescriptor[0] == COLUMNAR_NATIVE_ENCDESC_BASELINE)
		{
			/* D2b baseline: raw present values follow the validity bitmap; no
			 * per-vector structure, so per-vector skipping is disabled below */
			rs->nativeValueCursor[cc->columnIndex] = base + validityBytes;
			allDescriptor = false;
		}
		else
		{
			Form_pg_attribute att = TupleDescAttr(rs->tupdesc, cc->columnIndex);
			uint32	   *vraw = NULL;
			int			vcount = 0;
			int			vdecoded = 0;

			/* D4: reconstruct the raw present-value stream from the descriptor */
			rs->nativeValueCursor[cc->columnIndex] =
				pgcolumnar_native_decode_chunk(rs->groupContext, att, base + validityBytes,
											 (uint32) (cc->pageLength - validityBytes),
											 cc->encodingDescriptor,
											 cc->encodingDescriptorLen,
											 cc->blockCodec, &vraw, &vcount,
											 rs->nativeSkipVec, &vdecoded);
			rs->nativeVecRawLen[cc->columnIndex] = vraw;
			if (vcount > maxVecCount)
				maxVecCount = vcount;
			/*
			 * Vector POSITIONS, so the max across columns rather than the sum:
			 * a group of 32 vectors over 5 projected columns decodes 32
			 * positions, not 160. That is the unit vectorsSkipped uses, and the
			 * suite's "decoded plus skipped is the group's vectors" is false in
			 * any other unit.
			 */
			if (vdecoded > groupVecDecoded)
				groupVecDecoded = vdecoded;
			/* pairs, so summed across columns rather than maxed */
			rs->vectorDecodes += (uint64) vdecoded;
		}
	}
	}
	rs->vectorsDecoded += (uint64) groupVecDecoded;

	/*
	 * Counted HERE, where the skipping is performed, and not where rows are
	 * produced (#542).
	 *
	 * It used to be incremented in pgcolumnar_native_skip_current_vector, which
	 * only the row path enters. The batch fold takes a group whole through
	 * PgColumnarReadFoldNextGroup and never produces rows one at a time, so it
	 * never reached that counter: a fold that decoded 1 of 59 vectors reported
	 * "Columnar Vectors Skipped: 0". That is worse than printing nothing, because
	 * it answers the question wrongly, and it is the number #522 added precisely
	 * so a plan could say whether per-vector skipping happened on the fold path.
	 *
	 * Decode is shared by both paths, and it is the only place the final mask
	 * exists.
	 *
	 * What this does to the scalar arm's total, stated exactly, because an
	 * earlier version of this comment claimed it was unchanged and that is only
	 * true of a scan that runs to completion:
	 *
	 *     query                                    before   after
	 *     WHERE k BETWEEN 30000 AND 30100              58      58
	 *     ... LIMIT 1                                  29      58
	 *
	 * The old counter incremented as the PRODUCER stepped over vectors, so a
	 * LIMIT that stopped it halfway counted half of them. This one counts what
	 * decode ruled out, which does not depend on how many rows were consumed. The
	 * new number is the one that satisfies the invariant this change exists for:
	 * on a 59-vector group the LIMIT row was 1 + 29 = 30, and is now 1 + 58 = 59.
	 * The old number conflated "ruled out by the mask" with "stepped over before
	 * we stopped", which is the same conflation #542 is about, one layer down.
	 *
	 * Counted from nativeSkipVec and NOT as (maxVecCount - groupVecDecoded).
	 * That subtraction looks equivalent and is not, because #452 phase 1b-ii made
	 * the loop two-pass: pass 0 decodes the qual columns against the mask the
	 * ZONE MAPS built, refine_skipvec then sharpens it to "no row in this vector
	 * matches", and pass 1 decodes the payload columns against the sharpened one.
	 * groupVecDecoded is the max across columns over BOTH passes, so on a
	 * zero-matching range it is the qual column's full 32 while the payload
	 * columns decoded nothing -- the subtraction yields 0 skipped for a group
	 * where every vector was ruled out. Measured: it made
	 * native_exact_selection's "zone maps rule out nothing" premise read -32.
	 *
	 * The mask is the thing that says what was skipped, so ask it.
	 */
	if (rs->nativeSkipVec != NULL && rs->nativeVectorCount > 0)
	{
		int			v;
		int			skipped = 0;

		for (v = 0; v < rs->nativeVectorCount; v++)
			if (rs->nativeSkipVec[v])
				skipped++;
		rs->vectorsSkipped += (uint64) skipped;
	}

	/*
	 * The #512 tripwire's input, and it is measured rather than inferred from
	 * the mask: a mask with nothing set in it skips nothing, and a decode that
	 * ignored the mask skipped nothing either. Both must read as false here, and
	 * only the decoded count can say so.
	 */
	rs->decodeSkippedVectors = (groupVecDecoded < maxVecCount);

	rs->groupRowCount = rg->rowCount;
	rs->rowInGroup = 0;

	MemoryContextSwitchTo(oldContext);
	return true;
}

/*
 * pgcolumnar_native_skip_current_vector
 *		Per-vector skipping (native spec 7.1, D5b): when rowInGroup sits at the
 *		start of a vector the zone maps rule out, step each column's value cursor
 *		past that vector's decoded bytes and jump rowInGroup to the next vector,
 *		neither decoding nor emitting its rows. Returns true when it advanced (the
 *		caller re-checks bounds), false when the current row must be emitted.
 */
static bool
pgcolumnar_native_skip_current_vector(PgColumnarReadState *rs)
{
	int			v = rs->nativeCurVec;
	int			V = rs->nativeVectorCount;
	int			c;

	while (v < V && rs->rowInGroup >= rs->nativeVecStart[v + 1])
		v++;
	rs->nativeCurVec = v;

	if (v >= V || !rs->nativeSkipVec[v] ||
		rs->rowInGroup != rs->nativeVecStart[v])
		return false;

	for (c = 0; c < rs->natts; c++)
		if (rs->nativeValueCursor[c] != NULL && rs->nativeVecRawLen[c] != NULL)
			rs->nativeValueCursor[c] += rs->nativeVecRawLen[c][v];

	rs->rowInGroup = rs->nativeVecStart[v + 1];
	rs->nativeCurVec = v + 1;
	/*
	 * vectorsSkipped is NOT incremented here any more (#542). This function is
	 * on the row path only, so counting here made the number a row-path counter
	 * wearing a plan-wide name: correct on a sequential scan, silently 0 on the
	 * batch fold. It is now counted in the group decode, which both paths share.
	 */
	return true;
}

/*
 * pgcolumnar_native_next_row
 *		Native-format sequential row production (Phase D3). Decodes one row from
 *		the current row group, reconstructing each column from its validity bit
 *		and, when present, the next value on its cursor. Vectors the zone maps rule
 *		out are stepped over without decoding (Phase D5b).
 *
 * Late materialization (#452 Phase 1a): when qualCols is non-NULL the row is
 * built in two passes. The columns the qual reads are decoded first, `filter` is
 * asked whether the row can survive, and the remaining projected columns are
 * decoded only if it can -- otherwise their cursors are advanced past the row
 * without allocating or copying anything. Each column carries its own cursor, so
 * visiting them in two groups within one row is free; only rowInGroup is shared,
 * and it advances once, after both passes.
 *
 * With qualCols NULL this is exactly the single-pass producer it has always
 * been, which is the path every other caller still takes.
 */
static bool
pgcolumnar_native_next_row(PgColumnarReadState *rs, Datum *values, bool *nulls,
						 uint64 *rowNumber,
						 const bool *qualCols,
						 PgColumnarRowFilter filter,
						 PgColumnarRowFilter filterNoCount, void *filterArg)
{
	MemoryContext oldContext;
	int			c;
	bool		keep = true;

	if (rs->exhausted)
		return false;

	/*
	 * Carry the filter into the group load so phase 2's between-pass evaluator
	 * can reach it (#452). NULL on the unfiltered path, which turns it off. Set
	 * every call: it is cheaper than a branch and always the same pointers.
	 */
	rs->nativeQualCols = qualCols;
	rs->nativeQualFilter = filter;
	rs->nativeQualFilterNoCount = filterNoCount;
	rs->nativeQualFilterArg = filterArg;
	rs->nativeQualValues = values;
	rs->nativeQualNulls = nulls;

	for (;;)
	{
		bool		deleted;

		/*
		 * This loop can run for a long time without producing a row: it skips
		 * whole vectors ruled out by the zone maps, skips deleted rows one at a
		 * time, and loads group after group. The executor only reaches its own
		 * interrupt check when a row is returned, and the vectorized aggregate
		 * path returns exactly one row for the whole scan, so without a check
		 * here a query is uncancellable for the length of a full scan.
		 */
		CHECK_FOR_INTERRUPTS();

		if (rs->nativeGroup == NULL || rs->rowInGroup >= rs->groupRowCount)
		{
			if (!pgcolumnar_native_load_group(rs))
			{
				rs->exhausted = true;
				return false;
			}
		}

		if (rs->nativeSkipVec != NULL &&
			pgcolumnar_native_skip_current_vector(rs))
			continue;			/* stepped past a ruled-out vector; re-check */

		/*
		 * Read the row, advancing each present column's value cursor. This happens
		 * even for a deleted row so the cursors stay aligned for the next row; a
		 * deleted row is simply not emitted (D6b).
		 */
		deleted = (rs->nativeDeleteMask != NULL &&
				   (rs->rowInGroup >> 3) < rs->nativeDeleteMaskLen &&
				   (rs->nativeDeleteMask[rs->rowInGroup >> 3] &
					(1 << (rs->rowInGroup & 7))) != 0);

		MemoryContextReset(rs->rowContext);
		oldContext = MemoryContextSwitchTo(rs->rowContext);

		if (qualCols != NULL)
		{
			/*
			 * A deleted row must never reach the filter. Nothing above the scan
			 * can see it, and the qual is arbitrary user expression: evaluating
			 * a cast or a division on an invisible row could raise an error the
			 * query has no business raising. Its cursors are advanced and it is
			 * dropped, which is also cheaper than the full build it used to get.
			 */
			if (deleted)
			{
				for (c = 0; c < rs->natts; c++)
					pgcolumnar_row_skip_column(rs, c, values, nulls);
			}
			else
			{
				/* Pass one: only what the qual reads. */
				for (c = 0; c < rs->natts; c++)
				{
					if (qualCols[c])
						pgcolumnar_row_read_column(rs, c, values, nulls);
					else
					{
						values[c] = (Datum) 0;
						nulls[c] = true;
					}
				}

				/*
				 * Ask outside the row context: the filter runs executor code that
				 * allocates in its own context. The pass-one values live in
				 * rowContext and stay valid -- it is reset per row, not here.
				 */
				MemoryContextSwitchTo(oldContext);

				/*
				 * When phase 2's evaluator already counted this group's rejects
				 * (it walks every row), the producer must not count them again as
				 * it re-tests a surviving vector for the rows to emit. It filters
				 * through the non-counting variant then; otherwise (1a with a
				 * predicate, or a group with no per-vector structure) it counts.
				 */
				if (rs->nativeQualCounted && rs->nativeQualFilterNoCount != NULL)
					keep = rs->nativeQualFilterNoCount(filterArg);
				else
					keep = filter(filterArg);
				MemoryContextSwitchTo(rs->rowContext);

				/* Pass two: the rest, built only if the row survived. */
				for (c = 0; c < rs->natts; c++)
				{
					if (qualCols[c])
						continue;
					if (keep)
						pgcolumnar_row_read_column(rs, c, values, nulls);
					else
						pgcolumnar_row_skip_column(rs, c, values, nulls);
				}
			}

			MemoryContextSwitchTo(oldContext);

			*rowNumber = rs->nativeGroup->firstRowNumber + rs->rowInGroup;
			rs->rowInGroup++;

			if (deleted)
				continue;
			if (!keep)
			{
				rs->rowsFilteredEarly++;
				continue;
			}
			return true;
		}

		/*
		 * The single-pass path every other caller takes: build every projected
		 * column, including for a deleted row so the cursors stay aligned.
		 */
		for (c = 0; c < rs->natts; c++)
			pgcolumnar_row_read_column(rs, c, values, nulls);

		MemoryContextSwitchTo(oldContext);

		*rowNumber = rs->nativeGroup->firstRowNumber + rs->rowInGroup;
		rs->rowInGroup++;

		if (deleted)
			continue;			/* row deleted: cursors advanced, do not emit */

		return true;
	}
}

bool
PgColumnarReadNextRow(PgColumnarReadState *readState, Datum *values, bool *nulls,
					uint64 *rowNumber)
{
	pgcolumnar_read_start(readState);
	return pgcolumnar_native_next_row(readState, values, nulls, rowNumber,
									NULL, NULL, NULL, NULL);
}

/*
 * PgColumnarReadNextRowFiltered
 *		Late materialization (#452 Phase 1a): produce the next row that survives
 *		`filter`, building the columns outside qualCols only for a row that does.
 *
 * qualCols is [natts] and marks the columns the filter reads. The filter is
 * called with only those decoded; it must not look at any other column, and it
 * must not assume anything about a row it rejects. Deleted rows are dropped
 * without consulting it.
 *
 * The caller keeps ownership of the qual and of whatever the filter closes over.
 */
bool
PgColumnarReadNextRowFiltered(PgColumnarReadState *readState,
							Datum *values, bool *nulls, uint64 *rowNumber,
							const bool *qualCols,
							PgColumnarRowFilter filter,
							PgColumnarRowFilter filterNoCount, void *filterArg)
{
	Assert(qualCols != NULL && filter != NULL && filterNoCount != NULL);
	pgcolumnar_read_start(readState);
	return pgcolumnar_native_next_row(readState, values, nulls, rowNumber,
									qualCols, filter, filterNoCount, filterArg);
}

/*
 * PgColumnarRowsFilteredEarly
 *		Rows whose payload columns were never built because the qual rejected
 *		them first. For EXPLAIN.
 */
uint64
PgColumnarRowsFilteredEarly(PgColumnarReadState *readState)
{
	return readState ? readState->rowsFilteredEarly : 0;
}

/* -------------------------------------------------------------------------
 * Batch-fold accessors (#289)
 *
 * These expose the current loaded group's decoded buffer so an ungrouped
 * aggregate can fold it column-at-a-time, without pgcolumnar_native_next_row
 * producing one Datum tuple per row. Correctness is the caller's: it must walk
 * each column's validity bitmap to map a row to its packed value (nulls have no
 * slot), honor the delete mask, and step the per-column present index past a
 * ruled-out vector. Only fixed-width by-value columns can be read this way; the
 * caller checks that from the tuple descriptor before using PgColumnarReadFoldColumn.
 * ------------------------------------------------------------------------- */

/*
 * Advance to the next row group to fold, loading it (and honoring restrict,
 * parallel and zone-map group skipping via pgcolumnar_native_load_group). Returns
 * false at end of scan; on true, the accessors below describe the loaded group.
 */
bool
PgColumnarReadFoldNextGroup(PgColumnarReadState *readState)
{
	pgcolumnar_read_start(readState);
	if (readState->exhausted)
		return false;
	if (!pgcolumnar_native_load_group(readState))
	{
		readState->exhausted = true;
		return false;
	}
	readState->rowInGroup = 0;
	return true;
}

/*
 * Group-level fold info: row count, the delete mask (row-indexed bits, NULL when
 * the group has no deletes) and its byte length, the per-vector skip flags and
 * vector row-start offsets (both NULL when per-vector skipping is inactive), and
 * the vector count.
 */
void
PgColumnarReadFoldGroupInfo(PgColumnarReadState *readState, uint64 *nrows,
						  const char **deleteMask, uint32 *deleteMaskLen,
						  const bool **skipVec, bool *decodeSkipped, const uint32 **vecStart,
						  int *vectorCount)
{
	*nrows = readState->groupRowCount;
	*deleteMask = readState->nativeDeleteMask;
	*deleteMaskLen = readState->nativeDeleteMaskLen;
	*skipVec = readState->nativeSkipVec;
	*decodeSkipped = readState->decodeSkippedVectors;
	*vecStart = readState->nativeVecStart;
	*vectorCount = readState->nativeVectorCount;
}

/*
 * Column attidx in the loaded group: its validity bitmap (row-indexed; LSB-first),
 * the base of its packed present values (contiguous, host-endian), the element
 * width, and its per-vector decoded byte lengths (NULL when per-vector skipping is
 * inactive, used to step the present index past a skipped vector). Returns false
 * when the column is absent from this group (added by a later ALTER TABLE ADD
 * COLUMN); the caller then folds it from the missing value or falls back.
 */
bool
PgColumnarReadFoldColumn(PgColumnarReadState *readState, int attidx,
					   const char **validity, const char **packed,
					   int16 *attlen, const uint32 **vecRawLen)
{
	if (attidx < 0 || attidx >= readState->natts ||
		readState->nativeValidity == NULL ||
		readState->nativeValidity[attidx] == NULL)
		return false;
	*validity = readState->nativeValidity[attidx];
	*packed = readState->nativeValueCursor[attidx];
	*attlen = TupleDescAttr(readState->tupdesc, attidx)->attlen;
	*vecRawLen = (readState->nativeVecRawLen != NULL)
		? readState->nativeVecRawLen[attidx] : NULL;
	return true;
}

/*
 * pgcolumnar_next_group_index
 *		The next native row group to scan, or -1 when none remain. The native
 *		counterpart of pgcolumnar_next_stripe_index: a parallel custom scan claims
 *		it from the shared atomic so each worker reads distinct row groups (gap
 *		23, D6e); a serial scan walks rowGroupIndex.
 */
static int64
pgcolumnar_next_group_index(PgColumnarReadState *readState)
{
	int			ngroups = list_length(readState->rowGroupList);
	uint32		gi;

	if (readState->parallelCounter != NULL)
		gi = pg_atomic_fetch_add_u32(readState->parallelCounter, 1);
	else
		gi = (uint32) readState->rowGroupIndex++;

	return (gi < (uint32) ngroups) ? (int64) gi : -1;
}

void
PgColumnarReadSetParallelCounter(PgColumnarReadState *readState,
							   pg_atomic_uint32 *counter)
{
	readState->parallelCounter = counter;
}

/*
 * PgColumnarReadSetProjection
 *		Narrow an already-opened reader to a set of columns (issue #413).
 *
 *		The table-AM scan interface has nowhere to put a projection, so a reader
 *		opened through pgcolumnar_scan_begin reads every column. A caller that
 *		does know which columns it needs -- an index build knows, from IndexInfo
 *		-- can say so here instead.
 *
 *		Only legal before the first read. colWanted drives what the group loader
 *		decodes, and a group already loaded under a wider projection would be
 *		reused under a narrower one, so changing it mid-scan would silently
 *		return unset values rather than fail. The caller is expected to do this
 *		immediately after obtaining the reader; the assertion states the rule and
 *		the early return keeps a release build honest.
 *
 *		A NULL set means "all columns", matching PgColumnarBeginRead.
 */
void
PgColumnarReadSetProjection(PgColumnarReadState *readState,
							Bitmapset *projectedColumns)
{
	int			pc;
	MemoryContext old;

	Assert(!readState->started);
	if (readState->started)
		return;

	/*
	 * Copy into the read state's own context, not the caller's. Nothing reads
	 * this field after the setter today, so this is consistency rather than a
	 * fixed bug -- PgColumnarBeginRead builds the same field in readContext and
	 * PgColumnarReadRestrictToGroups says so in its own comment. A field owned by
	 * two different contexts depending on which function set it is a trap for
	 * whoever reads it next.
	 */
	old = MemoryContextSwitchTo(readState->readContext);
	bms_free(readState->projectedColumns);
	readState->projectedColumns = bms_copy(projectedColumns);
	MemoryContextSwitchTo(old);
	readState->allColumnsWanted = (projectedColumns == NULL ||
								   !pgcolumnar_enable_column_projection);
	for (pc = 0; pc < readState->natts; pc++)
		readState->colWanted[pc] = readState->allColumnsWanted ||
			bms_is_member(pc, projectedColumns);
}

/*
 * PgColumnarReadProjectedCount
 *		How many columns this reader will actually decode.
 *
 *		Read from colWanted, the field the group loader consults, so a caller
 *		reporting a projection reports what the reader WILL DO rather than what
 *		the caller computed and may have failed to apply. That distinction is
 *		the whole point: a projection computed and then dropped on the floor is
 *		exactly the bug this accessor exists to make visible (#413).
 */
int
PgColumnarReadProjectedCount(PgColumnarReadState *readState)
{
	int			pc;
	int			n = 0;

	for (pc = 0; pc < readState->natts; pc++)
	{
		if (readState->colWanted[pc])
			n++;
	}
	return n;
}

/*
 * PgColumnarReadRestrictToGroups
 *		Restrict this scan to the given row group numbers (issue #149). Groups
 *		outside the set are skipped in the claim loop, so their bytes are never
 *		read and their column chunks never decoded. The array is copied into the
 *		read state's own context and sorted there, so the caller may free its own.
 *
 *		Must be called before the first PgColumnarReadNextRow. Passing ngroups == 0
 *		makes the scan return no rows, which is the honest reading of "restrict to
 *		nothing" and is what the aggregate path relies on when every group is
 *		clean.
 */
void
PgColumnarReadRestrictToGroups(PgColumnarReadState *readState,
							 const uint64 *groupNumbers, int ngroups)
{
	MemoryContext oldContext;

	Assert(!readState->started);

	oldContext = MemoryContextSwitchTo(readState->readContext);
	readState->restrictGroups = (uint64 *) palloc(sizeof(uint64) *
												  (ngroups > 0 ? ngroups : 1));
	readState->numRestrictGroups = ngroups;
	if (ngroups > 0)
	{
		memcpy(readState->restrictGroups, groupNumbers,
			   sizeof(uint64) * ngroups);
		qsort(readState->restrictGroups, ngroups, sizeof(uint64),
			  pgcolumnar_uint64_cmp);
	}
	MemoryContextSwitchTo(oldContext);
}

/* -------------------------------------------------------------------------
 * Liveness cache (gap 26, phase 4): a projection scan must test each row's base
 * row number for deletion/visibility. The cache reads the base row-group list
 * and delete vectors once (at the scan's snapshot) into memory, then answers each
 * test with a binary search over row groups plus a bitmap probe. Consistent
 * with the scan's fixed snapshot, the same way PgColumnarBeginRead reads those
 * lists once at begin.
 * ------------------------------------------------------------------------- */
typedef struct LiveStripeEntry
{
	uint64		firstRowNumber;
	uint64		rowCount;
	int			chunkRowCount;
	int			chunkGroupCount;
	char	  **masks;			/* [chunkGroupCount], deleted bitmap or NULL */
	uint32	   *maskLens;		/* [chunkGroupCount] */
} LiveStripeEntry;

struct PgColumnarLivenessCache
{
	LiveStripeEntry *stripes;	/* sorted ascending by firstRowNumber */
	int			nstripes;
	MemoryContext ctx;
};

static int
livestripe_cmp(const void *a, const void *b)
{
	const LiveStripeEntry *ea = (const LiveStripeEntry *) a;
	const LiveStripeEntry *eb = (const LiveStripeEntry *) b;

	if (ea->firstRowNumber < eb->firstRowNumber)
		return -1;
	if (ea->firstRowNumber > eb->firstRowNumber)
		return 1;
	return 0;
}

PgColumnarLivenessCache *
PgColumnarBuildLivenessCache(Relation rel, Snapshot snapshot)
{
	uint64		storageId = PgColumnarStorageId(rel);
	Snapshot	metaSnapshot = PgColumnarCatalogSnapshot(snapshot);
	MemoryContext ctx = AllocSetContextCreate(CurrentMemoryContext,
											  "columnar liveness cache",
											  ALLOCSET_DEFAULT_SIZES);
	MemoryContext oldContext = MemoryContextSwitchTo(ctx);
	List	   *rgList = PgColumnarReadRowGroupList(storageId, metaSnapshot);
	PgColumnarLivenessCache *cache = palloc0(sizeof(PgColumnarLivenessCache));
	ListCell   *lc;
	int			i = 0;

	/*
	 * Each native row group is one liveness entry with a single whole-group
	 * delete mask (the delete vector is keyed by group number, chunk id 0). Modeling
	 * it as chunkGroupCount 1 with chunkRowCount == rowCount makes the shared
	 * PgColumnarLivenessCacheIsLive map every row to chunk 0.
	 */
	cache->ctx = ctx;
	cache->nstripes = list_length(rgList);
	cache->stripes = palloc0(sizeof(LiveStripeEntry) * Max(cache->nstripes, 1));

	foreach(lc, rgList)
	{
		NativeRowGroupMetadata *rg = (NativeRowGroupMetadata *) lfirst(lc);
		LiveStripeEntry *e = &cache->stripes[i++];
		List	   *rml;
		ListCell   *mc;
		uint32		want = (uint32) ((rg->rowCount + 7) / 8);

		e->firstRowNumber = rg->firstRowNumber;
		e->rowCount = rg->rowCount;
		e->chunkRowCount = (int) rg->rowCount;
		e->chunkGroupCount = 1;
		e->masks = palloc0(sizeof(char *) * 1);
		e->maskLens = palloc0(sizeof(uint32) * 1);

		rml = PgColumnarReadDeleteVectorList(storageId, rg->groupNumber, metaSnapshot);
		foreach(mc, rml)
		{
			DeleteVectorMetadata *rm = (DeleteVectorMetadata *) lfirst(mc);
			uint32		b;

			if (rm->bitmap == NULL || rm->bitmapLen == 0)
				continue;
			if (e->masks[0] == NULL)
			{
				e->masks[0] = palloc0(want > 0 ? want : 1);
				e->maskLens[0] = want;
			}
			for (b = 0; b < rm->bitmapLen && b < want; b++)
				e->masks[0][b] |= rm->bitmap[b];
		}
	}

	if (cache->nstripes > 1)
		qsort(cache->stripes, cache->nstripes, sizeof(LiveStripeEntry),
			  livestripe_cmp);

	MemoryContextSwitchTo(oldContext);
	return cache;
}

bool
PgColumnarLivenessCacheIsLive(PgColumnarLivenessCache *cache, uint64 rowNumber)
{
	int			lo = 0;
	int			hi = cache->nstripes - 1;

	while (lo <= hi)
	{
		int			mid = (lo + hi) / 2;
		LiveStripeEntry *e = &cache->stripes[mid];

		if (rowNumber < e->firstRowNumber)
			hi = mid - 1;
		else if (rowNumber >= e->firstRowNumber + e->rowCount)
			lo = mid + 1;
		else
		{
			uint64		off = rowNumber - e->firstRowNumber;
			int			chunkId = (e->chunkRowCount > 0)
				? (int) (off / (uint64) e->chunkRowCount) : 0;
			uint64		inGroup = off - (uint64) chunkId * (uint64) e->chunkRowCount;

			if (chunkId >= 0 && chunkId < e->chunkGroupCount &&
				e->masks[chunkId] != NULL &&
				(inGroup >> 3) < e->maskLens[chunkId] &&
				(e->masks[chunkId][inGroup >> 3] & (1 << (inGroup & 7))) != 0)
				return false;	/* deleted */
			return true;		/* covered and not deleted */
		}
	}
	return false;				/* no covering stripe: not visible */
}

void
PgColumnarFreeLivenessCache(PgColumnarLivenessCache *cache)
{
	if (cache != NULL)
		MemoryContextDelete(cache->ctx);
}

/*
 * PgColumnarReadRowByNumber
 *		Fetch a single row addressed by its row number (spec 6). Used by the
 *		table AM's fetch-by-tid callback (UPDATE re-fetches the old row). Reads
 *		only the one chunk group that holds the row and decodes each column up
 *		to the row's position. Returns false when no stripe covers the row or
 *		the row is marked deleted in the delete vector (spec 7.5).
 */

/* -------------------------------------------------------------------------
 * Statement-scoped decoded row-group cache (issue #143).
 *
 * PgColumnarReadRowByNumber() read and decoded a whole row group to return one
 * row, so fetching N rows out of one group cost N times the group: measured at
 * 878 ms for 5,000 rows, 4,452 ms for 10,000 and 19,211 ms for 20,000, all in a
 * single group. Every index scan, bitmap scan, and index-driven UPDATE or DELETE
 * goes through this path.
 *
 * Correctness comes from the scope rather than from an invalidation protocol. A
 * row group's bytes are immutable once written, and four independent things keep
 * a stale entry from being used:
 *
 *   - the storage id is part of the key, so anything that allocates new storage
 *     (pgcolumnar.vacuum, and any rewrite that goes through a new relfilenode)
 *     misses rather than matching;
 *   - a rewrite retires group numbers rather than reusing them, so a compacted
 *     group never reappears under its old number with different content;
 *   - the geometry an entry was filled with is re-checked against the catalog on
 *     every hit, so a group number that did come back with a different shape is
 *     treated as a miss;
 *   - and an entry is only used within the command that filled it.
 *
 * Note it is NOT a lock argument. pgcolumnar.compact_rewrite runs under
 * ShareUpdateExclusiveLock and does not conflict with a reader, so a concurrent
 * compaction is possible while this cache is live; the reasons above are what
 * make that safe, and test/native_rewrite.sh pins the two of them that are
 * properties of the allocator rather than of this file.
 *
 * Visibility is unaffected because it is not cached. The delete vector, the
 * buffered delete marks and the validity bitmap are consulted per fetch; only
 * decoded column values are held here.
 *
 * Entries live in contexts under TopTransactionContext, so an abort or commit
 * frees them without a hook; PgColumnarDiscardFetchCache() clears the descriptors
 * to match.
 * ------------------------------------------------------------------------- */

/*
 * Four entries rather than one. A sequential UPDATE walks rows in row-number
 * order and stays inside one group, which one entry would serve, but an index
 * delivers TIDs in index order, and on a column uncorrelated with row order
 * consecutive fetches land in different groups. One entry hits about 1/G of the
 * time there; a handful covers it and costs nothing measurable.
 */
#define COLUMNAR_FETCH_CACHE_ENTRIES	4

/*
 * Cap on the decoded size held at once, measured with MemoryContextMemAllocated
 * rather than derived from the stored byte length: the stored form is encoded and
 * compressed, so a group of wide text decodes to many times its size on disk, and
 * sizing from disk would overshoot worst on exactly the tables this helps most.
 * COLUMNAR_FETCH_CACHE_MAX_BYTES is defined in columnar.h so the index-fetch cost
 * model (#355) can name the same cap.
 *
 * The cap is enforced per column, not per entry (issue #359). It used to drop the
 * whole entry, which made it a cliff: an entry one byte over was not retained at
 * all, so every fetch re-read the group and re-decoded every column it touched.
 * On the 100M fixture that was 2,833 ms at four aggregate columns and 134,147 at
 * five, flat either side -- a 47x step inside the space of ordinary queries.
 * Shrinking entries (#357 moved decode scratch out, ~3x) only moved the step.
 * Now the columns that fit stay resident and only the remainder is re-decoded, so
 * crossing the cap costs the overflow fraction rather than everything.
 */

typedef struct PgColumnarFetchGroup
{
	MemoryContext cx;			/* holds every pointer below; NULL when free */
	uint64		storageId;
	uint64		groupNumber;
	CommandId	cid;			/* the command that filled this entry */
	uint64		firstRowNumber;
	uint64		rowCount;
	uint64		fileOffset;
	int			natts;

	/*
	 * The validity bitmap of each touched column, read once and kept for as long
	 * as the entry lives (#433). It is (rowCount + 7) / 8 bytes, ~1.2 KB at the
	 * default stripe, and it is consulted on every fetch to decide whether the
	 * row is null. Keeping it is what lets an overflowed column stay cheap: the
	 * null test costs nothing, and only a non-null value pays for a re-read.
	 *
	 * There is deliberately no whole-group buffer here. Holding one was what
	 * made the cap a cliff -- see the comment on the cap below.
	 */
	char	  **vbits;			/* [natts]; NULL until that column is touched */

	NativeColumnChunkMetadata **ccForCol;	/* [natts] */
	char	  **rawBuf;			/* [natts]; NULL until that column is decoded */

	/*
	 * Position indexes, built with rawBuf and holding for as long as it does
	 * (issue #143). Reaching row r's value in a column used to mean counting the
	 * validity bits below r and then decoding and discarding that many values, so
	 * a hit was O(rows before r) and fetching a whole group stayed quadratic even
	 * though the group was decoded once.
	 *
	 * rankPrefix[c][b] is the number of present values before 64-row block b, so
	 * the rank of any row costs the prefix plus at most eight byte lookups.
	 * valOffset[c][k] is the byte offset of the k-th present value within
	 * rawBuf[c]; it is only built for varying-length columns, since a fixed-length
	 * column's k-th value is at k * attlen.
	 */
	uint32	  **rankPrefix;		/* [natts]; NULL until that column is decoded */
	uint32	  **valOffset;		/* [natts]; NULL for fixed-length columns */

	/*
	 * Per-column residency, so exceeding the cap costs proportionally rather
	 * than totally (issue #359).
	 *
	 * colCx[c] holds column c's decoded stream, one child context per column so
	 * a single column can be released without disturbing the rest of the entry.
	 * It is NULL only when the column is undecoded. Every resident column has
	 * one, baseline included: since #433 a baseline column's stream is its own
	 * allocation rather than an interior pointer into a shared group buffer.
	 *
	 * overflow[c] marks a column that was decoded, did not fit, and was
	 * released. Such a column decodes into per-fetch scratch from then on. The
	 * mark is never cleared: the resident set has to be *stable*, because the
	 * access pattern here is cyclic -- every fetch touches the same projected
	 * columns in attribute order -- and evicting the least recently used column
	 * against a cyclic pattern evicts precisely the column about to be needed,
	 * which is a 100% miss rate, i.e. the very behaviour this removes. First
	 * fit and then stop re-decodes only the columns that did not fit.
	 */
	MemoryContext *colCx;		/* [natts] */
	bool	   *overflow;		/* [natts] */
	uint64		lastUsed;
}			PgColumnarFetchGroup;

static PgColumnarFetchGroup columnarFetchCache[COLUMNAR_FETCH_CACHE_ENTRIES];
static uint64 columnarFetchClock = 0;

/*
 * Memoized native-format-version validation for the by-row-number fetch path
 * (#240). pgcolumnar_fetch_row runs once per row, so checking the storage's
 * format_version against a catalog row on every call would be a per-row systable
 * scan on a hot path. The value is immutable for a storage, so one check per
 * (command, storageId) is enough; this single slot is cleared in
 * PgColumnarDiscardFetchCache, the same command/transaction boundary the fetch
 * cache resets on.
 */
static uint64 columnarFetchFmtOkStorageId = 0;
static bool columnarFetchFmtOk = false;

/* rows covered by one rankPrefix entry */
#define COLUMNAR_RANK_BLOCK_ROWS 64
#define COLUMNAR_RANK_BLOCK_BYTES (COLUMNAR_RANK_BLOCK_ROWS / 8)

/*
 * pgcolumnar_build_rank_prefix
 *		Cumulative count of set validity bits at each 64-row boundary, so the
 *		number of present values before an arbitrary row can be had without
 *		walking to it. Entry b counts the bits below row b * 64; the array has one
 *		more entry than there are blocks, so the last holds the column's total
 *		present count. Bits at or past rowCount are ignored: the writer leaves the
 *		tail of the final byte undefined, and counting it would claim values the
 *		chunk does not hold.
 */
static uint32 *
pgcolumnar_build_rank_prefix(const char *vbits, uint64 rowCount)
{
	uint64		nblocks = (rowCount + COLUMNAR_RANK_BLOCK_ROWS - 1) /
		COLUMNAR_RANK_BLOCK_ROWS;
	uint32	   *prefix = (uint32 *) palloc(sizeof(uint32) * (nblocks + 1));
	uint32		running = 0;
	uint64		b;

	for (b = 0; b < nblocks; b++)
	{
		uint64		firstRow = b * COLUMNAR_RANK_BLOCK_ROWS;
		uint64		lastRow = firstRow + COLUMNAR_RANK_BLOCK_ROWS;
		uint64		byte;

		prefix[b] = running;
		if (lastRow > rowCount)
			lastRow = rowCount;

		for (byte = firstRow / 8; byte < (lastRow + 7) / 8; byte++)
		{
			unsigned char v = (unsigned char) vbits[byte];
			uint64		bitsHere = lastRow - byte * 8;

			/* the final byte of the final block can extend past rowCount */
			if (bitsHere < 8)
				v &= (unsigned char) ((1 << bitsHere) - 1);
			running += pg_number_of_ones[v];
		}
	}
	prefix[nblocks] = running;
	return prefix;
}

/*
 * pgcolumnar_rank_before
 *		How many values are present in this column before row `row` of the group.
 *		The block prefix plus at most eight byte lookups, in place of a loop over
 *		every earlier row.
 */
static inline uint64
pgcolumnar_rank_before(const char *vbits, const uint32 *prefix, uint64 row)
{
	uint64		blk = row / COLUMNAR_RANK_BLOCK_ROWS;
	uint64		rank = prefix[blk];
	uint64		byte = blk * COLUMNAR_RANK_BLOCK_BYTES;
	uint64		endByte = row / 8;

	for (; byte < endByte; byte++)
		rank += pg_number_of_ones[(unsigned char) vbits[byte]];

	if ((row & 7) != 0)
		rank += pg_number_of_ones[(unsigned char) vbits[endByte] &
								  (unsigned char) ((1 << (row & 7)) - 1)];
	return rank;
}

/*
 * pgcolumnar_build_val_offsets
 *		Byte offset of every present value in a decoded varying-length stream.
 *		One pass over the values, paid once per column per cached group, in place
 *		of a partial pass on every fetch. Fixed-length columns never call this:
 *		their k-th value is at k * attlen and needs no table.
 */
static uint32 *
pgcolumnar_build_val_offsets(Form_pg_attribute att, char *rawBuf, uint32 nvalues)
{
	uint32	   *offsets = (uint32 *) palloc(sizeof(uint32) * (nvalues + 1));
	char	   *cursor = rawBuf;
	uint32		k;

	for (k = 0; k < nvalues; k++)
	{
		offsets[k] = (uint32) (cursor - rawBuf);
		cursor += PgColumnarVarSizeAnyUnaligned(cursor);

		/*
		 * A chunk holds as many values as chunk_group_row_limit allows, which is
		 * a user-settable GUC, so this pass is bounded only by that. Check on the
		 * same stride the decoders use, for the reason #128 and #146 record: a
		 * long loop with no check is a query that cannot be cancelled.
		 */
		if ((k & 0xFFFF) == 0)
			CHECK_FOR_INTERRUPTS();
	}
	offsets[nvalues] = (uint32) (cursor - rawBuf);
	return offsets;
}

/* drop one entry and everything it holds */
static void
pgcolumnar_fetch_entry_reset(PgColumnarFetchGroup *e)
{
	if (e->cx != NULL)
		MemoryContextDelete(e->cx);
	memset(e, 0, sizeof(*e));
}

/*
 * PgColumnarDiscardFetchCache
 *		Forget every cached group. The contexts hang off TopTransactionContext
 *		and are already gone by the time this runs at transaction end, so this
 *		only clears the descriptors that pointed at them.
 */
void
PgColumnarDiscardFetchCache(void)
{
	memset(columnarFetchCache, 0, sizeof(columnarFetchCache));
	columnarFetchClock = 0;
	columnarFetchFmtOk = false;
}

/*
 * Find the entry for this group in this command, or prepare an empty one.
 * Returns NULL when nothing should be cached, in which case the caller decodes
 * into its own scratch context exactly as before.
 */
static PgColumnarFetchGroup *
pgcolumnar_fetch_group_slot(uint64 storageId, uint64 groupNumber, bool *hit)
{
	CommandId	cid = GetCurrentCommandId(false);
	PgColumnarFetchGroup *victim = NULL;
	int			i;

	*hit = false;

	for (i = 0; i < COLUMNAR_FETCH_CACHE_ENTRIES; i++)
	{
		PgColumnarFetchGroup *e = &columnarFetchCache[i];

		if (e->cx == NULL)
		{
			if (victim == NULL)
				victim = e;
			continue;
		}
		/* an entry from an earlier command can never be used again */
		if (e->cid != cid)
		{
			pgcolumnar_fetch_entry_reset(e);
			if (victim == NULL)
				victim = e;
			continue;
		}
		if (e->storageId == storageId && e->groupNumber == groupNumber)
		{
			e->lastUsed = ++columnarFetchClock;
			*hit = true;
			return e;
		}
	}

	if (victim == NULL)
	{
		/* every slot is live in this command: take the least recently used */
		uint64		oldest = UINT64_MAX;

		for (i = 0; i < COLUMNAR_FETCH_CACHE_ENTRIES; i++)
			if (columnarFetchCache[i].lastUsed < oldest)
			{
				oldest = columnarFetchCache[i].lastUsed;
				victim = &columnarFetchCache[i];
			}
		pgcolumnar_fetch_entry_reset(victim);
	}

	victim->cx = AllocSetContextCreate(TopTransactionContext,
									   "columnar fetch group",
									   ALLOCSET_DEFAULT_SIZES);
	victim->storageId = storageId;
	victim->groupNumber = groupNumber;
	victim->cid = cid;
	victim->lastUsed = ++columnarFetchClock;
	return victim;
}

/*
 * pgcolumnar_fetch_row
 *		Shared worker behind the three fetch entry points below.
 *
 *		Which columns to decode is said two ways, and deliberately not one.
 *		allColumns is an explicit flag; needed is a set of 0-based attribute
 *		numbers consulted only when it is false.
 *
 *		The obvious single-argument form -- a set where NULL means "all" -- cannot
 *		be made safe, because a Bitmapset does not distinguish empty from NULL: an
 *		empty one *is* NULL. A caller that computes its set and finds nothing in it
 *		would then silently ask for every column, which is the exact opposite, and
 *		no assertion can catch it because the two cases are the same value.
 *		A column outside it is not read, not decoded and not indexed, and comes
 *		back null. wantValues == false stops as soon as liveness is settled,
 *		without touching the group's bytes at all.
 */
static bool
pgcolumnar_fetch_row(Relation rel, Snapshot snapshot, uint64 rowNumber,
				   Datum *values, bool *nulls, bool allColumns,
				   Bitmapset *needed, bool wantValues)
{
	uint64		storageId = PgColumnarStorageId(rel);
	TupleDesc	tupdesc = RelationGetDescr(rel);
	int			natts = tupdesc->natts;
	MemoryContext target = CurrentMemoryContext;
	MemoryContext tmp;
	MemoryContext oldContext;
	Snapshot	metaSnapshot;
	List	   *rgList;
	NativeRowGroupMetadata *rg = NULL;
	PgColumnarFetchGroup *entry;
	bool		hit;
	int			validityBytes;
	uint64		rowInGrp;
	ListCell   *nlc;
	int			c;

	/*
	 * pgcolumnar_fetch_row is called once per item pointer by the executor -- per
	 * row on an index or bitmap scan, and per duplicate by _bt_check_unique()
	 * while it holds the index page (see pgcolumnar_metadata.c). None of those
	 * callers checks for interrupts between fetches, and each fetch reads the
	 * row-group list out of the catalog, so a statement that fetches many rows
	 * spends its whole time in here. Without a check the loop is uncancellable
	 * and never notices postmaster death -- a backend spun here at 100% CPU for
	 * three days, outliving its cluster (#212). One check per fetch makes the
	 * statement cancellable; the per-fetch cost itself is a separate fix.
	 */
	CHECK_FOR_INTERRUPTS();

	/*
	 * Reject a native format_version this build does not understand before
	 * decoding any bytes (#240). The scan-open paths check this in
	 * PgColumnarBeginReadWithStorage / PgColumnarBeginAggScan, but the by-row-number
	 * fetch path -- an index scan returning a decoded column, UPDATE re-fetching
	 * the old row, and the vacuum row reader -- reaches neither. Only an actual
	 * decode is guarded (wantValues); a visibility-only probe decodes nothing and
	 * cannot misread. Memoized per command (see the slot above) so a large index
	 * scan pays one catalog check rather than one per row.
	 */
	if (wantValues &&
		!(columnarFetchFmtOk && columnarFetchFmtOkStorageId == storageId))
	{
		PgColumnarCheckNativeFormatVersion(storageId, RelationGetRelationName(rel));
		columnarFetchFmtOkStorageId = storageId;
		columnarFetchFmtOk = true;
	}

	tmp = AllocSetContextCreate(CurrentMemoryContext, "columnar fetch",
								ALLOCSET_SMALL_SIZES);
	oldContext = MemoryContextSwitchTo(tmp);

	metaSnapshot = PgColumnarCatalogSnapshot(snapshot);

	/*
	 * Native (PGCN v1) fetch-by-row-number: find the row group covering the row
	 * and reconstruct each column's value at its position. Index and bitmap scans
	 * and unique enforcement call this. A deleted row (in the group's delete vector or
	 * a not-yet-flushed buffered delete) is not visible.
	 *
	 * The row-group list is read per fetch and deliberately not cached: a group
	 * flushed earlier in this same statement has to become visible here.
	 */
	rgList = PgColumnarReadRowGroupList(storageId, metaSnapshot);
	foreach(nlc, rgList)
	{
		NativeRowGroupMetadata *g = (NativeRowGroupMetadata *) lfirst(nlc);

		if (rowNumber >= g->firstRowNumber &&
			rowNumber < g->firstRowNumber + g->rowCount)
		{
			rg = g;
			break;
		}
	}
	if (rg == NULL)
	{
		MemoryContextSwitchTo(oldContext);
		MemoryContextDelete(tmp);
		return false;
	}
	rowInGrp = rowNumber - rg->firstRowNumber;

	/*
	 * SnapshotAny asks for the row whatever its visibility, so the delete vector
	 * is not consulted for it. That is not a loophole, it is the contract: core
	 * uses SnapshotAny to re-fetch a row it already knows the fate of.
	 *
	 * An AFTER UPDATE ... FOR EACH ROW trigger is the case that needs it (#179).
	 * The update marks the old row deleted and the trigger then asks for that
	 * same row to hand the user OLD -- so honouring the delete mark here answered
	 * "no such row" to a question about a row the caller had just deleted itself,
	 * and the statement died with "failed to fetch tuple for trigger".
	 */
	if (snapshot != NULL && snapshot->snapshot_type == SNAPSHOT_ANY)
	{
		/* no visibility filtering at all */
	}
	else
	{
		List	   *maskList = PgColumnarReadDeleteVectorList(storageId,
													   rg->groupNumber,
													   metaSnapshot);
		ListCell   *mlc;
		bool		deleted = PgColumnarDeleteVectorBufferedDeleted(rel, rowNumber);

		foreach(mlc, maskList)
		{
			DeleteVectorMetadata *rm = (DeleteVectorMetadata *) lfirst(mlc);

			if (rm->bitmap != NULL && (rowInGrp >> 3) < rm->bitmapLen &&
				(rm->bitmap[rowInGrp >> 3] & (1 << (rowInGrp & 7))) != 0)
				deleted = true;
		}
		if (deleted)
		{
			MemoryContextSwitchTo(oldContext);
			MemoryContextDelete(tmp);
			return false;
		}
	}

	/*
	 * Liveness is fully settled here: it depends only on the row group covering
	 * the row and on the delete vector. A caller that asks nothing else is done,
	 * without the group's bytes being read or a single column decoded (#157).
	 */
	if (!wantValues)
	{
		MemoryContextSwitchTo(oldContext);
		MemoryContextDelete(tmp);
		return true;
	}

	/*
	 * The group's bytes and its decoded columns are the expensive part and the
	 * part that repeats across fetches of the same group, so they come from the
	 * statement-scoped cache above. A miss fills the entry; a hit skips the read
	 * and the decode entirely.
	 */
	entry = pgcolumnar_fetch_group_slot(storageId, rg->groupNumber, &hit);

	/*
	 * The geometry the entry was filled with has to match the group just read
	 * out of the catalog. The invariant that it always does is argued above and
	 * is almost certainly true, but it is load-bearing rather than decorative:
	 * validityBytes comes from the cached rowCount and base from the cached
	 * fileOffset, so a group number that ever came back with different geometry
	 * inside one command would be read at wrong offsets and return wrong values
	 * rather than fail. Checking costs four comparisons and turns that into a
	 * re-decode.
	 */
	if (hit &&
		(entry->firstRowNumber != rg->firstRowNumber ||
		 entry->rowCount != rg->rowCount ||
		 entry->fileOffset != rg->fileOffset ||
		 entry->natts != natts))
	{
		pgcolumnar_fetch_entry_reset(entry);
		entry = pgcolumnar_fetch_group_slot(storageId, rg->groupNumber, &hit);
		Assert(!hit);
	}

	if (!hit)
	{
		MemoryContext entryOld = MemoryContextSwitchTo(entry->cx);
		List	   *nchunks;

		entry->firstRowNumber = rg->firstRowNumber;
		entry->rowCount = rg->rowCount;
		entry->fileOffset = rg->fileOffset;
		entry->natts = natts;
		entry->vbits = palloc0(sizeof(char *) * natts);
		entry->ccForCol = palloc0(sizeof(NativeColumnChunkMetadata *) * natts);
		entry->rawBuf = palloc0(sizeof(char *) * natts);
		entry->rankPrefix = palloc0(sizeof(uint32 *) * natts);
		entry->valOffset = palloc0(sizeof(uint32 *) * natts);
		entry->colCx = palloc0(sizeof(MemoryContext) * natts);
		entry->overflow = palloc0(sizeof(bool) * natts);
		MemoryContextSwitchTo(tmp);

		/*
		 * The group's bytes are NOT read here (#433). Each column chunk is an
		 * independently addressable range -- NativeColumnChunkMetadata carries
		 * pageOffset and pageLength -- so a column is read when it is first
		 * touched and a column nobody projects is never read at all.
		 */
		nchunks = PgColumnarReadColumnChunkList(storageId, rg->groupNumber,
											  metaSnapshot);
		foreach(nlc, nchunks)
		{
			NativeColumnChunkMetadata *cc = (NativeColumnChunkMetadata *) lfirst(nlc);

			if (cc->columnIndex >= 0 && cc->columnIndex < natts)
			{
				NativeColumnChunkMetadata *copy;

				MemoryContextSwitchTo(entry->cx);
				copy = (NativeColumnChunkMetadata *) palloc(sizeof(*cc));
				memcpy(copy, cc, sizeof(*cc));

				/*
				 * encodingDescriptor is a pointer into the bytea the catalog
				 * scan produced, which lives in tmp and dies with it at the end
				 * of this call. Copying the struct alone leaves every later hit
				 * reading freed memory, which usually still holds the old bytes
				 * and so usually works: the projections suite caught it as
				 * "unrecognized native encoding descriptor", but freed memory
				 * that happens to decode is the same bug returning wrong values
				 * in silence. The descriptor comes with the entry.
				 */
				if (cc->encodingDescriptor != NULL &&
					cc->encodingDescriptorLen > 0)
				{
					char	   *desc = (char *) palloc(cc->encodingDescriptorLen);

					memcpy(desc, cc->encodingDescriptor,
						   cc->encodingDescriptorLen);
					copy->encodingDescriptor = desc;
				}

				entry->ccForCol[cc->columnIndex] = copy;
				MemoryContextSwitchTo(tmp);
			}
		}
		MemoryContextSwitchTo(entryOld);
	}

	validityBytes = (int) ((entry->rowCount + 7) / 8);

	for (c = 0; c < natts; c++)
	{
		Form_pg_attribute att = TupleDescAttr(tupdesc, c);
		NativeColumnChunkMetadata *cc = entry->ccForCol[c];
		char	   *vbits;
		char	   *rawBuf;
		char	   *cursor;
		uint64		present;
		bool		justDecoded;	/* this fetch decoded it; may not fit */

		/*
		 * A column the caller did not ask for is neither decoded nor indexed,
		 * and reads as null rather than being left untouched: a caller that
		 * projects and then reads outside its projection gets a null instead of
		 * whatever the array happened to hold.
		 */
		if (!allColumns && !bms_is_member(c, needed))
		{
			values[c] = (Datum) 0;
			nulls[c] = true;
			continue;
		}

		if (cc == NULL)
		{
			values[c] = getmissingattr(tupdesc, c + 1, &nulls[c]);
			continue;
		}

		/*
		 * The validity bitmap, read once for this column and then kept (#433).
		 * It is small and it is consulted on every fetch, so an overflowed
		 * column still answers "is this row null" without touching the group.
		 */
		if (entry->vbits[c] == NULL)
		{
			MemoryContext vOld = MemoryContextSwitchTo(entry->cx);

			entry->vbits[c] = palloc(validityBytes > 0 ? validityBytes : 1);
			MemoryContextSwitchTo(vOld);
			if (validityBytes > 0)
				PgColumnarReadLogicalData(rel, cc->pageOffset, entry->vbits[c],
										validityBytes);
		}
		vbits = entry->vbits[c];
		if (((vbits[rowInGrp >> 3] >> (rowInGrp & 7)) & 1) == 0)
		{
			values[c] = (Datum) 0;
			nulls[c] = true;
			continue;
		}

		if (entry->rawBuf[c] != NULL)
		{
			rawBuf = entry->rawBuf[c];
			justDecoded = false;
		}
		else
		{
			/*
			 * A baseline chunk is not encoded, so its stored bytes ARE its
			 * value stream and rawBuf points straight at them. It therefore
			 * needs its own releasable context like any other column: before
			 * #433 it pointed into the shared group buffer, which is what made
			 * it unreleasable and, in turn, what forced the whole-entry drop.
			 *
			 * For an encoded chunk the stored bytes are scratch. They are read
			 * into the per-fetch context and decoded out of it, so the entry
			 * never retains a raw stream it has already decoded.
			 */
			bool		baseline = (cc->encodingDescriptorLen == 1 &&
									(uint8) cc->encodingDescriptor[0] ==
									COLUMNAR_NATIVE_ENCDESC_BASELINE);
			MemoryContext decCx;
			MemoryContext decOld;
			uint32		vlen = (uint32) (cc->pageLength - validityBytes);
			char	   *vstream;

			if (entry->overflow[c])
				decCx = tmp;	/* known not to fit: decode per fetch */
			else
				decCx = AllocSetContextCreate(entry->cx,
											  "columnar fetch column",
											  ALLOCSET_DEFAULT_SIZES);

			/*
			 * The value stream lives with the column when it IS the column's
			 * data, and in scratch when it is only the input to a decode.
			 */
			decOld = MemoryContextSwitchTo(baseline ? decCx : tmp);
			vstream = palloc(vlen > 0 ? vlen : 1);
			MemoryContextSwitchTo(decOld);
			if (vlen > 0)
				PgColumnarReadLogicalData(rel, cc->pageOffset + validityBytes,
										vstream, vlen);

			decOld = MemoryContextSwitchTo(decCx);
			if (baseline)
				rawBuf = vstream;
			else
				rawBuf =
					pgcolumnar_native_decode_chunk(decCx, att,
												 vstream, vlen,
												 cc->encodingDescriptor,
												 cc->encodingDescriptorLen,
												 cc->blockCodec, NULL, NULL,
												 NULL, NULL);
			MemoryContextSwitchTo(decOld);

			/*
			 * Index the column while it is being decoded, so every fetch into
			 * this group afterwards reaches its row directly (issue #143).
			 *
			 * The indexes live in the entry context, not in the column's, so
			 * they outlive a released column. That is deliberate: decoding the
			 * same chunk bytes is deterministic and yields the same layout, so
			 * the offsets stay valid across a re-decode. An overflowed column
			 * therefore pays its decode again but still reaches its row in
			 * constant time, which is what stops #143's quadratic returning
			 * through this path. They are small next to the stream: rankPrefix
			 * is four bytes per 64 rows, valOffset four per value.
			 */
			if (entry->rankPrefix[c] == NULL)
			{
				MemoryContext idxOld = MemoryContextSwitchTo(entry->cx);

				entry->rankPrefix[c] = pgcolumnar_build_rank_prefix(vbits,
																 entry->rowCount);
				if (att->attlen < 0)
				{
					uint64		nblocks = (entry->rowCount +
										   COLUMNAR_RANK_BLOCK_ROWS - 1) /
						COLUMNAR_RANK_BLOCK_ROWS;

					entry->valOffset[c] =
						pgcolumnar_build_val_offsets(att, rawBuf,
												   entry->rankPrefix[c][nblocks]);
				}
				MemoryContextSwitchTo(idxOld);
			}

			if (decCx != tmp)
			{
				entry->rawBuf[c] = rawBuf;
				/*
				 * Baseline columns get a context too, now that their stream is
				 * their own allocation rather than an interior pointer into a
				 * shared group buffer. That makes every resident column
				 * releasable, which is what lets the cap be enforced per column
				 * with no whole-entry fallback (#433).
				 */
				entry->colCx[c] = decCx;
			}
			justDecoded = true;
		}

		/*
		 * The row's value sits at the rank-th position in the present-value
		 * stream. A fixed-length column strides straight to it; a varying-length
		 * one reads its offset out of the table built above. Neither depends on
		 * how far into the group the row is, which is what made a cache hit
		 * proportional to the row's position before.
		 */
		present = pgcolumnar_rank_before(vbits, entry->rankPrefix[c], rowInGrp);

		if (att->attlen > 0)
			cursor = rawBuf + present * (uint64) att->attlen;
		else
			cursor = rawBuf + entry->valOffset[c][present];

		values[c] = PgColumnarDecodeValue(att, &cursor, target);
		nulls[c] = false;

		/*
		 * Release this column if it is the one that took the entry over the cap
		 * (issue #359). Measuring the context is what makes the cap mean decoded
		 * bytes rather than stored bytes; a column of wide text decodes to many
		 * times its size on disk, and sizing from disk would overshoot worst on
		 * exactly the tables this helps most.
		 *
		 * Releasing here rather than dropping the whole entry is what makes
		 * going over the cap cost proportionally: the columns admitted before
		 * this one stay resident and are decoded once, and only the remainder is
		 * decoded per fetch. groupBuffer stays either way, so no fetch re-reads
		 * the group from disk.
		 *
		 * It is safe because nothing handed back points into the column: the
		 * value returned was copied into the caller's context by the
		 * PgColumnarDecodeValue call immediately above, and the position indexes
		 * live in entry->cx rather than in the column's own context.
		 */
		if (justDecoded && entry->colCx[c] != NULL &&
			MemoryContextMemAllocated(entry->cx, true) >
			COLUMNAR_FETCH_CACHE_MAX_BYTES)
		{
			MemoryContextDelete(entry->colCx[c]);
			entry->colCx[c] = NULL;
			entry->rawBuf[c] = NULL;
			entry->overflow[c] = true;
		}
	}

	/*
	 * There is no whole-entry drop here any more (#433).
	 *
	 * There used to be: when the group's *raw* bytes alone exceeded the cap, the
	 * entry was reset at the end of every fetch, because every column would
	 * overflow and the entry would still pin the whole-group buffer, so four such
	 * entries could hold arbitrarily much. The effect was a hit rate of zero by
	 * construction above the cap -- populate, use once, discard -- so each fetched
	 * row re-read and re-decoded the entire group. Measured at 9.65x the buffers
	 * for ten rows against one, on a 42 MB group in perfect key order.
	 *
	 * It also tested the group's raw stored size, so a narrow projection over a
	 * wide group was dropped just the same. Selecting one int column cost the
	 * same buffers as selecting the 8 KB text beside it.
	 *
	 * Nothing needs defending against now. No allocation spans the group: each
	 * column reads its own chunk, and every resident column has a releasable
	 * context, so the per-column cap above is sufficient on its own. What the
	 * entry retains is
	 *
	 *     4 x (cap + retained position indexes + retained validity bitmaps)
	 *
	 * where the validity bitmaps are (rowCount + 7) / 8 per touched column,
	 * ~1.2 KB at the default stripe. The '+ groupBuffer' term that #359's
	 * corrected comment had to carry is gone.
	 *
	 * rankPrefix and valOffset still stay in the entry context by design, so a
	 * released column keeps its position indexes. Releasing valOffset with the
	 * stream was tried under #359 and is worse: it holds the bound (62 MB ->
	 * 28 MB) but costs 47% in time (127.7 s -> 187.5 s), because rebuilding
	 * offsets is a second walk of the value stream on every fetch rather than a
	 * constant factor on the decode. The retained indexes are what makes an
	 * overflowed column cheap on its next fetch.
	 */

	MemoryContextSwitchTo(oldContext);
	MemoryContextDelete(tmp);
	return true;
}

/*
 * PgColumnarReadRowByNumber
 *		Reconstruct every column of the row addressed by a row number. False when
 *		the row is not visible.
 */
bool
PgColumnarReadRowByNumber(Relation rel, Snapshot snapshot, uint64 rowNumber,
						Datum *values, bool *nulls)
{
	return pgcolumnar_fetch_row(rel, snapshot, rowNumber, values, nulls,
							  true, NULL, true);
}

/*
 * PgColumnarReadRowByNumberCols
 *		Decode exactly the columns in `needed`; every other column reads as null.
 *		An empty or NULL set therefore decodes nothing, which is what it says
 *		rather than a silent "everything" -- for every column, call
 *		PgColumnarReadRowByNumber, which takes no set and cannot be misread.
 *
 *		Decoding every column whatever the caller wanted is not merely wasted
 *		work on a wide table. The decoded bytes are measured against the fetch
 *		cache's size cap, so the entry is dropped after every fetch and the group
 *		is decoded again for the next row -- the behaviour the cache exists to
 *		remove (issue #157).
 */
bool
PgColumnarReadRowByNumberCols(Relation rel, Snapshot snapshot, uint64 rowNumber,
							Datum *values, bool *nulls, Bitmapset *needed)
{
	return pgcolumnar_fetch_row(rel, snapshot, rowNumber, values, nulls,
							  false, needed, true);
}

/*
 * PgColumnarRowIsLive
 *		Is the row visible? Decodes nothing.
 *
 *		pgcolumnar_index_delete_tuples asks exactly this, once per candidate index
 *		tuple on a path nbtree drives during deletion, and answered it by
 *		reconstructing every column and freeing the result unread.
 */
bool
PgColumnarRowIsLive(Relation rel, Snapshot snapshot, uint64 rowNumber)
{
	return pgcolumnar_fetch_row(rel, snapshot, rowNumber, NULL, NULL,
							  false, NULL, false);
}

void
PgColumnarRescanRead(PgColumnarReadState *readState)
{
	MemoryContextReset(readState->stripeContext);
	readState->started = false;
	readState->exhausted = false;

	/* native format cursors */
	readState->rowGroupList = NIL;
	readState->rowGroupIndex = 0;
	readState->nativeGroup = NULL;
	readState->nativeBuffer = NULL;
	readState->nativeValidity = NULL;
	readState->nativeValueCursor = NULL;
	readState->nativeSkipVec = NULL;
	readState->nativeVecStart = NULL;
	readState->nativeVecRawLen = NULL;
	readState->nativeVectorCount = 0;
	readState->nativeCurVec = 0;
	readState->nativeDeleteMask = NULL;
	readState->nativeDeleteMaskLen = 0;
}

void
PgColumnarEndRead(PgColumnarReadState *readState)
{
	MemoryContextDelete(readState->readContext);
}

/*
 * PgColumnarReadStats
 *		Report how many chunk groups the scan has read versus skipped by the
 *		min/max skip lists (spec 9). Used by the custom scan's EXPLAIN output.
 */
void
PgColumnarReadStats(PgColumnarReadState *readState, uint64 *groupsRead,
				  uint64 *groupsSkipped, uint64 *groupsTotal)
{
	*groupsRead = readState->groupsRead;
	*groupsSkipped = readState->groupsSkipped;
	*groupsTotal = readState->groupsRead + readState->groupsSkipped;
}

/*
 * PgColumnarReadUsablePredicates
 *		How many skip predicates this read state built, which is how many of its
 *		scan keys can exclude a chunk group. Used by EXPLAIN (#479).
 *
 *		pgcolumnar_make_predicates drops a key it cannot evaluate against the
 *		stored min/max, and a dropped key excludes nothing -- but it is still
 *		counted by "Columnar Pushed-Down Filters", which reports the keys the
 *		scan was given. Reporting only that number is how #477 stayed invisible:
 *		a bigint column against a bare integer literal read as a pushed-down
 *		filter that simply was not selective, when in fact no group could ever
 *		be skipped.
 */
int
PgColumnarReadUsablePredicates(PgColumnarReadState *readState)
{
	return readState->numPredicates;
}

/*
 * PgColumnarVectorsSkipped
 *		How many 1024-value vectors the native scan skipped within read row groups
 *		via per-vector zone maps (native spec 7.1, D5b). Used by EXPLAIN.
 */
uint64
PgColumnarVectorsSkipped(PgColumnarReadState *readState)
{
	return readState->vectorsSkipped;
}

/*
 * PgColumnarVectorsDecoded
 *		How many 1024-value vectors the native scan actually decoded within read
 *		row groups (#452 phase 1b-i). Counted in vector positions, the same unit
 *		as PgColumnarVectorsSkipped, so that the two are comparable: on a group
 *		where decode honours the skip vector, decoded plus skipped is the group's
 *		vector count. Used by EXPLAIN.
 */
uint64
PgColumnarVectorsDecoded(PgColumnarReadState *readState)
{
	return readState->vectorsDecoded;
}

/*
 * PgColumnarVectorDecodes
 *		How many individual (vector, column) decodes the native scan performed.
 *		This is the quantity that measures decode WORK; PgColumnarVectorsDecoded
 *		measures how many row positions were covered. Used by EXPLAIN.
 */
uint64
PgColumnarVectorDecodes(PgColumnarReadState *readState)
{
	return readState->vectorDecodes;
}

/*
 * PgColumnarVectorsRuledOutByValue
 *		How many vectors exact selection ruled out by evaluating the pushed-down
 *		predicates against decoded values, rather than against min/max (#452
 *		phase 1b-ii). A subset of PgColumnarVectorsSkipped. Used by EXPLAIN.
 */
uint64
PgColumnarVectorsRuledOutByValue(PgColumnarReadState *readState)
{
	return readState->vectorsRuledOutByValue;
}
