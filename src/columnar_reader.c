/*-------------------------------------------------------------------------
 *
 * columnar_reader.c
 *		The columnar reader: a sequential scan that reads all columns of all
 *		stripes and reconstructs rows (spec 4, 6). Also holds the value-stream
 *		codec shared with the writer.
 *
 * Phase 1 stores value streams uncompressed. Each chunk carries an exists
 * (null bitmap) stream of one byte per row; present rows draw their value
 * from the value stream in order.
 *
 *-------------------------------------------------------------------------
 */
#include "columnar.h"

#include "fmgr.h"
#include "access/detoast.h"
#include "access/htup_details.h"
#include "access/relscan.h"
#include "access/tupmacs.h"
#include "access/xact.h"
#include "miscadmin.h"
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

struct ColumnarReadState
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
	 * chunks from the native catalog. The current row group's bytes are read
	 * whole into nativeBuffer (in groupContext); nativeValidity[c] points at each
	 * column chunk's validity bitmap and nativeValueCursor[c] advances through its
	 * uncompressed values.
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

static void columnar_build_predicates(ColumnarReadState *readState,
									  int nkeys, ScanKey keys);
static int64 columnar_next_group_index(ColumnarReadState *readState);

/* qsort comparator for the row group restriction set */
static int
columnar_uint64_cmp(const void *a, const void *b)
{
	uint64		x = *(const uint64 *) a;
	uint64		y = *(const uint64 *) b;

	return (x < y) ? -1 : (x > y) ? 1 : 0;
}

/*
 * columnar_group_is_restricted_in
 *		Is this group number in the read state's restriction set? Binary search
 *		over the sorted array set by ColumnarReadRestrictToGroups. Only called
 *		when restrictGroups is non-NULL.
 */
static bool
columnar_group_is_restricted_in(ColumnarReadState *rs, uint64 groupNumber)
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
 * ColumnarEncodeValue
 *		Append a non-null value to a column's value stream. Fixed-length
 *		values are stored as their raw bytes; varlena values are detoasted
 *		and stored with a full 4-byte header so the reader can size them.
 */
void
ColumnarEncodeValue(StringInfo buf, Form_pg_attribute att, Datum value)
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
 * ColumnarDecodeValue
 *		Read one value from a column's value stream, advancing *cursor.
 *		By-reference values are copied into targetContext so they outlive the
 *		stripe buffer's next reset.
 */
Datum
ColumnarDecodeValue(Form_pg_attribute att, char **cursor,
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
		Size		len = VARSIZE_ANY(p);
		char	   *copy = MemoryContextAlloc(targetContext, len);

		memcpy(copy, p, len);
		result = PointerGetDatum(copy);
		*cursor = p + len;
	}

	return result;
}

/* -------------------------------------------------------------------------
 * sequential scan
 * ------------------------------------------------------------------------- */

ColumnarReadState *
ColumnarBeginRead(Relation rel, Snapshot snapshot,
				  ParallelTableScanDesc parallelScan,
				  Bitmapset *projectedColumns, int nkeys, ScanKey keys)
{
	return ColumnarBeginReadWithStorage(rel, snapshot, ColumnarStorageId(rel),
										RelationGetDescr(rel), parallelScan,
										projectedColumns, nkeys, keys);
}

ColumnarReadState *
ColumnarBeginReadWithStorage(Relation rel, Snapshot snapshot,
							 uint64 storageId, TupleDesc tupdesc,
							 ParallelTableScanDesc parallelScan,
							 Bitmapset *projectedColumns, int nkeys, ScanKey keys)
{
	ColumnarReadState *readState;
	MemoryContext readContext;
	MemoryContext oldContext;

	readContext = AllocSetContextCreate(CurrentMemoryContext,
										"columnar read",
										ALLOCSET_DEFAULT_SIZES);
	oldContext = MemoryContextSwitchTo(readContext);

	readState = palloc0(sizeof(ColumnarReadState));
	readState->rel = rel;
	readState->snapshot = snapshot;
	readState->metaSnapshot = ColumnarCatalogSnapshot(snapshot);
	readState->tupdesc = tupdesc;
	readState->natts = readState->tupdesc->natts;
	readState->storageId = storageId;

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

	if (columnar_enable_qual_pushdown)
		columnar_build_predicates(readState, nkeys, keys);

	MemoryContextSwitchTo(oldContext);
	return readState;
}


/*
 * columnar_build_predicates
 *		Translate the scan's ScanKeys into skip predicates for chunk-group
 *		filtering (spec 9). Only simple, same-type btree comparison keys on an
 *		orderable column are used; anything else is ignored, so skipping stays
 *		conservative. Runs in readContext.
 */
static void
columnar_build_predicates(ColumnarReadState *readState, int nkeys, ScanKey keys)
{
	int			i;
	int			n = 0;

	if (nkeys <= 0 || keys == NULL)
		return;

	readState->predicates = palloc0(sizeof(SkipPredicate) * nkeys);

	for (i = 0; i < nkeys; i++)
	{
		ScanKey		key = &keys[i];
		int			attidx;
		Form_pg_attribute att;
		TypeCacheEntry *tce;

		/* only plain "column op const" comparison keys are usable */
		if (key->sk_flags & (SK_ISNULL | SK_ROW_HEADER | SK_ROW_MEMBER |
							 SK_ROW_END | SK_SEARCHNULL | SK_SEARCHNOTNULL |
							 SK_ORDER_BY))
			continue;
		if (key->sk_attno < 1 || key->sk_attno > readState->natts)
			continue;
		if (key->sk_strategy < BTLessStrategyNumber ||
			key->sk_strategy > BTGreaterStrategyNumber)
			continue;

		attidx = key->sk_attno - 1;
		att = TupleDescAttr(readState->tupdesc, attidx);

		/* avoid cross-type comparisons that our column cmp proc cannot do */
		if (OidIsValid(key->sk_subtype) && key->sk_subtype != att->atttypid)
			continue;

		tce = lookup_type_cache(att->atttypid,
								TYPECACHE_CMP_PROC_FINFO |
								TYPECACHE_HASH_PROC_FINFO);
		if (!OidIsValid(tce->cmp_proc_finfo.fn_oid))
			continue;

		readState->predicates[n].attidx = attidx;
		readState->predicates[n].strategy = key->sk_strategy;
		readState->predicates[n].compareValue = key->sk_argument;
		fmgr_info_copy(&readState->predicates[n].cmpFn, &tce->cmp_proc_finfo,
					   readState->readContext);
		readState->predicates[n].collation = att->attcollation;

		/*
		 * For an equality predicate on a hashable column with a safe collation,
		 * enable the bloom-filter probe (I7, gap 25), matching how the filter was
		 * built. The scan key already matches the column collation (a
		 * differently collated predicate is not pushed; see ColumnarBuildScanKeys),
		 * so hashing the constant under the column collation is consistent.
		 */
		readState->predicates[n].hasHash = false;
		if (key->sk_strategy == BTEqualStrategyNumber &&
			OidIsValid(tce->hash_proc_finfo.fn_oid) &&
			ColumnarCollationIsDeterministic(att->attcollation))
		{
			readState->predicates[n].hasHash = true;
			fmgr_info_copy(&readState->predicates[n].hashFn,
						   &tce->hash_proc_finfo, readState->readContext);
			readState->predicates[n].hashCollation = att->attcollation;
		}
		n++;
	}

	readState->numPredicates = n;
}

/*
 * columnar_group_can_match
 *		Decide whether a chunk group could contain a row satisfying every
 *		pushed-down predicate, using the stored per-chunk min/max (spec 9). A
 *		return of false means the group can be skipped. Missing min/max, or a
 *		non-orderable column, is treated conservatively as "may match".
 */

/*
 * columnar_setup_group
 *		Position on a chunk group: decompress each projected column's value
 *		stream into the group context and point the column cursors at the
 *		decompressed bytes and the (uncompressed) exists bytes. Non-projected
 *		columns are left un-decoded (column projection, spec 9).
 */

/*
 * columnar_position_group
 *		Advance from the current groupIndex to the next chunk group that could
 *		match the pushed-down predicates, skipping groups whose min/max rule
 *		them out (spec 9). Returns true when positioned on a readable group,
 *		false when the stripe has no more matching groups.
 */

/*
 * columnar_load_stripe
 *		Read a stripe's metadata and data into memory and position at its
 *		first chunk group.
 */

/*
 * columnar_read_start
 *		Lazily load the stripe list on the first fetch. For a parallel scan a
 *		single worker claims the whole scan and the others see it exhausted,
 *		which is a correct (if not parallel-accelerated) behaviour.
 */
static void
columnar_read_start(ColumnarReadState *readState)
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
			ColumnarReadRowGroupList(readState->storageId,
									 readState->metaSnapshot);
		readState->rowGroupIndex = 0;
		MemoryContextSwitchTo(oldContext);
	}
}

/*
 * columnar_native_decode_chunk
 *		Reconstruct a native column chunk's raw present-value stream (D4) from its
 *		encoding descriptor. The on-disk values region is the per-1024-value-vector
 *		encoded streams concatenated, optionally block-compressed as a whole. This
 *		reverses the block codec, then decodes each vector with ColumnarDecodeChunk
 *		into one raw buffer byte-identical to what the writer buffered, so the
 *		per-row producer walks it exactly as it walks the D2b baseline. Allocated
 *		in the group context. The descriptor lengths are cross-checked so a corrupt
 *		chunk cannot drive a decoder past its buffers.
 */
static char *
columnar_native_decode_chunk(MemoryContext cx, Form_pg_attribute att,
							 char *values, uint32 valuesLen,
							 const char *desc, uint32 descLen, int blockCodec,
							 uint32 **outVecRawLen, int *outVecCount)
{
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

	/* reverse the block codec to recover the concatenated encoded region */
	if (blockCodec != COLUMNAR_COMPRESSION_NONE)
		encRegion = ColumnarDecompressValueStream(values, valuesLen, blockCodec,
												  (uint32) encTotal,
												  cx);
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
			char	   *rawVec = ColumnarDecodeChunk(encCursor, encLen, encType,
													 att, valueCount, rawLen,
													 sharedTable, sharedTableLen,
													 cx);

			memcpy(rawCursor, rawVec, rawLen);
			rawCursor += rawLen;
		}
		encCursor += encLen;
	}

	if (outVecRawLen != NULL)
		*outVecRawLen = vecRawLen;
	if (outVecCount != NULL)
		*outVecCount = (int) vectorCount;

	return rawBuf;
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
	minv = ColumnarDecodeValue(att, &cur, cx);
	cur = (char *) z->maximum;
	maxv = ColumnarDecodeValue(att, &cur, cx);

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
		case BTEqualStrategyNumber: /* col = const : skip if const<min or const>max */
			c1 = DatumGetInt32(FunctionCall2Coll(&pred->cmpFn, pred->collation,
												 pred->compareValue, minv));
			c2 = DatumGetInt32(FunctionCall2Coll(&pred->cmpFn, pred->collation,
												 pred->compareValue, maxv));
			return (c1 < 0 || c2 > 0);
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
 * columnar_native_group_can_match
 *		Decide whether a native row group could hold a row satisfying every
 *		pushed-down predicate, using its whole-chunk zone maps (native spec 7.1,
 *		Phase D5b). Returns false when the group can be skipped. Mirrors the 2.2
 *		columnar_group_can_match, reading min/max from pgcolumnar.zone_map instead
 *		of the 2.2 chunk catalog. A missing or non-orderable zone map is treated
 *		conservatively as "may match". Runs in rs->skipContext (caller-reset).
 */
static bool
columnar_native_group_can_match(ColumnarReadState *rs, uint64 groupNumber)
{
	List	   *zones;
	List	   *blooms;
	NativeZoneMapMetadata **byCol;
	NativeBloomMetadata **byColBloom;
	ListCell   *lc;
	int			p;

	if (rs->numPredicates == 0)
		return true;

	zones = ColumnarReadZoneMapList(rs->storageId, groupNumber, rs->metaSnapshot);
	byCol = palloc0(sizeof(NativeZoneMapMetadata *) * rs->natts);
	foreach(lc, zones)
	{
		NativeZoneMapMetadata *z = (NativeZoneMapMetadata *) lfirst(lc);

		if (z->columnIndex >= 0 && z->columnIndex < rs->natts)
			byCol[z->columnIndex] = z;
	}

	blooms = ColumnarReadBloomList(rs->storageId, groupNumber, rs->metaSnapshot);
	byColBloom = palloc0(sizeof(NativeBloomMetadata *) * rs->natts);
	foreach(lc, blooms)
	{
		NativeBloomMetadata *b = (NativeBloomMetadata *) lfirst(lc);

		if (b->columnIndex >= 0 && b->columnIndex < rs->natts)
			byColBloom[b->columnIndex] = b;
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
			columnar_enable_bloom_filter && pred->hasHash)
		{
			NativeBloomMetadata *b = byColBloom[pred->attidx];

			if (b != NULL && b->filter != NULL)
			{
				uint32		h = DatumGetUInt32(
					FunctionCall1Coll(&pred->hashFn, pred->hashCollation,
									  pred->compareValue));

				if (!ColumnarBloomProbe(b->filter, b->filterLen, h))
					return false;
			}
		}
	}

	return true;
}

/*
 * columnar_native_build_skipvec
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
columnar_native_build_skipvec(ColumnarReadState *rs, uint64 groupNumber, int vecCount)
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

	if (rs->numPredicates == 0 || vecCount <= 0)
		return;

	zones = ColumnarReadZoneMapVectors(rs->storageId, groupNumber, rs->metaSnapshot);
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

	rs->nativeSkipVec = any ? skip : NULL;
}

/*
 * columnar_native_load_group
 *		Load the next native row group (PGCN v1, Phase D3): read its bytes whole
 *		into the group context and set each column's validity-bitmap pointer and
 *		values cursor. Row groups the zone maps prove cannot match are skipped
 *		(Phase D5b). Returns false when no more row groups remain.
 */
static bool
columnar_native_load_group(ColumnarReadState *rs)
{
	MemoryContext oldContext;
	NativeRowGroupMetadata *rg;
	List	   *chunks;
	ListCell   *lc;
	int			validityBytes;
	int			maxVecCount;
	bool		allDescriptor;

	/*
	 * Claim the next row group and advance past any the zone maps rule out
	 * (native spec 7.1). Under a parallel custom scan each worker claims distinct
	 * groups from the shared counter (columnar_next_group_index), so a group is
	 * read by exactly one backend; serially it walks rowGroupIndex. Without the
	 * counter every worker read every group and a parallel scan returned each row
	 * once per participating backend (D6e).
	 */
	rg = NULL;
	for (;;)
	{
		int64		gi = columnar_next_group_index(rs);
		bool		match = true;

		if (gi < 0)
			return false;

		rg = (NativeRowGroupMetadata *) list_nth(rs->rowGroupList, (int) gi);
		if (rs->restrictGroups != NULL &&
			!columnar_group_is_restricted_in(rs, rg->groupNumber))
			match = false;
		else if (rs->numPredicates > 0)
		{
			MemoryContext old = MemoryContextSwitchTo(rs->skipContext);

			MemoryContextReset(rs->skipContext);
			match = columnar_native_group_can_match(rs, rg->groupNumber);
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
	rs->nativeBuffer = palloc(rg->byteLength > 0 ? rg->byteLength : 1);
	if (rg->byteLength > 0)
		ColumnarReadLogicalData(rs->rel, rg->fileOffset, rs->nativeBuffer,
								rg->byteLength);

	chunks = ColumnarReadColumnChunkList(rs->storageId, rg->groupNumber,
										 rs->metaSnapshot);
	rs->nativeValidity = palloc0(sizeof(char *) * rs->natts);
	rs->nativeValueCursor = palloc0(sizeof(char *) * rs->natts);
	rs->nativeVecRawLen = (uint32 **) palloc0(sizeof(uint32 *) * rs->natts);
	validityBytes = (int) ((rg->rowCount + 7) / 8);
	maxVecCount = 0;
	allDescriptor = (chunks != NIL);

	foreach(lc, chunks)
	{
		NativeColumnChunkMetadata *cc = (NativeColumnChunkMetadata *) lfirst(lc);
		char	   *base;

		/* decoding a column chunk is the expensive part of loading a group */
		CHECK_FOR_INTERRUPTS();

		if (cc->columnIndex < 0 || cc->columnIndex >= rs->natts)
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

			/* D4: reconstruct the raw present-value stream from the descriptor */
			rs->nativeValueCursor[cc->columnIndex] =
				columnar_native_decode_chunk(rs->groupContext, att, base + validityBytes,
											 (uint32) (cc->pageLength - validityBytes),
											 cc->encodingDescriptor,
											 cc->encodingDescriptorLen,
											 cc->blockCodec, &vraw, &vcount);
			rs->nativeVecRawLen[cc->columnIndex] = vraw;
			if (vcount > maxVecCount)
				maxVecCount = vcount;
		}
	}

	/*
	 * Per-vector skipping (native spec 7.1, D5b): build the skip vector from the
	 * per-vector zone maps. Only when every column carries a descriptor (so the
	 * vector boundaries line up); a legacy baseline chunk disables it.
	 */
	if (allDescriptor)
		columnar_native_build_skipvec(rs, rg->groupNumber, maxVecCount);
	else
	{
		rs->nativeSkipVec = NULL;
		rs->nativeVecStart = NULL;
		rs->nativeVectorCount = maxVecCount;
		rs->nativeCurVec = 0;
	}

	/*
	 * Native delete visibility (D6b): combine this group's row-mask rows (keyed
	 * by group number, one bit per row-in-group) into a single delete mask that
	 * columnar_native_next_row consults to skip deleted rows.
	 */
	rs->nativeDeleteMask = NULL;
	rs->nativeDeleteMaskLen = 0;
	{
		List	   *maskList = ColumnarReadDeleteVectorList(rs->storageId,
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

	rs->groupRowCount = rg->rowCount;
	rs->rowInGroup = 0;

	MemoryContextSwitchTo(oldContext);
	return true;
}

/*
 * columnar_native_skip_current_vector
 *		Per-vector skipping (native spec 7.1, D5b): when rowInGroup sits at the
 *		start of a vector the zone maps rule out, step each column's value cursor
 *		past that vector's decoded bytes and jump rowInGroup to the next vector,
 *		neither decoding nor emitting its rows. Returns true when it advanced (the
 *		caller re-checks bounds), false when the current row must be emitted.
 */
static bool
columnar_native_skip_current_vector(ColumnarReadState *rs)
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
	rs->vectorsSkipped++;
	return true;
}

/*
 * columnar_native_next_row
 *		Native-format sequential row production (Phase D3). Decodes one row from
 *		the current row group, reconstructing each column from its validity bit
 *		and, when present, the next value on its cursor. Vectors the zone maps rule
 *		out are stepped over without decoding (Phase D5b).
 */
static bool
columnar_native_next_row(ColumnarReadState *rs, Datum *values, bool *nulls,
						 uint64 *rowNumber)
{
	MemoryContext oldContext;
	int			c;

	if (rs->exhausted)
		return false;

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
			if (!columnar_native_load_group(rs))
			{
				rs->exhausted = true;
				return false;
			}
		}

		if (rs->nativeSkipVec != NULL &&
			columnar_native_skip_current_vector(rs))
			continue;			/* stepped past a ruled-out vector; re-check */

		/*
		 * Read the row, advancing each present column's value cursor. This happens
		 * even for a deleted row so the cursors stay aligned for the next row; a
		 * deleted row is simply not emitted (D6b).
		 */
		MemoryContextReset(rs->rowContext);
		oldContext = MemoryContextSwitchTo(rs->rowContext);

		for (c = 0; c < rs->natts; c++)
		{
			Form_pg_attribute att = TupleDescAttr(rs->tupdesc, c);
			char	   *vbits = rs->nativeValidity[c];

			/* column absent from this group (added by a later ADD COLUMN) */
			if (vbits == NULL)
			{
				values[c] = rs->missingValues[c];
				nulls[c] = rs->missingIsnull[c];
				continue;
			}

			if ((vbits[rs->rowInGroup >> 3] >> (rs->rowInGroup & 7)) & 1)
			{
				values[c] = ColumnarDecodeValue(att, &rs->nativeValueCursor[c],
												rs->rowContext);
				nulls[c] = false;
			}
			else
			{
				values[c] = (Datum) 0;
				nulls[c] = true;
			}
		}

		MemoryContextSwitchTo(oldContext);

		deleted = (rs->nativeDeleteMask != NULL &&
				   (rs->rowInGroup >> 3) < rs->nativeDeleteMaskLen &&
				   (rs->nativeDeleteMask[rs->rowInGroup >> 3] &
					(1 << (rs->rowInGroup & 7))) != 0);

		*rowNumber = rs->nativeGroup->firstRowNumber + rs->rowInGroup;
		rs->rowInGroup++;

		if (deleted)
			continue;			/* row deleted: cursors advanced, do not emit */

		return true;
	}
}

bool
ColumnarReadNextRow(ColumnarReadState *readState, Datum *values, bool *nulls,
					uint64 *rowNumber)
{
	columnar_read_start(readState);
	return columnar_native_next_row(readState, values, nulls, rowNumber);
}

/*
 * columnar_next_group_index
 *		The next native row group to scan, or -1 when none remain. The native
 *		counterpart of columnar_next_stripe_index: a parallel custom scan claims
 *		it from the shared atomic so each worker reads distinct row groups (gap
 *		23, D6e); a serial scan walks rowGroupIndex.
 */
static int64
columnar_next_group_index(ColumnarReadState *readState)
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
ColumnarReadSetParallelCounter(ColumnarReadState *readState,
							   pg_atomic_uint32 *counter)
{
	readState->parallelCounter = counter;
}

/*
 * ColumnarReadRestrictToGroups
 *		Restrict this scan to the given row group numbers (issue #149). Groups
 *		outside the set are skipped in the claim loop, so their bytes are never
 *		read and their column chunks never decoded. The array is copied into the
 *		read state's own context and sorted there, so the caller may free its own.
 *
 *		Must be called before the first ColumnarReadNextRow. Passing ngroups == 0
 *		makes the scan return no rows, which is the honest reading of "restrict to
 *		nothing" and is what the aggregate path relies on when every group is
 *		clean.
 */
void
ColumnarReadRestrictToGroups(ColumnarReadState *readState,
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
			  columnar_uint64_cmp);
	}
	MemoryContextSwitchTo(oldContext);
}

/* -------------------------------------------------------------------------
 * Liveness cache (gap 26, phase 4): a projection scan must test each row's base
 * row number for deletion/visibility. The cache reads the base row-group list
 * and delete vectors once (at the scan's snapshot) into memory, then answers each
 * test with a binary search over row groups plus a bitmap probe. Consistent
 * with the scan's fixed snapshot, the same way ColumnarBeginRead reads those
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

struct ColumnarLivenessCache
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

ColumnarLivenessCache *
ColumnarBuildLivenessCache(Relation rel, Snapshot snapshot)
{
	uint64		storageId = ColumnarStorageId(rel);
	Snapshot	metaSnapshot = ColumnarCatalogSnapshot(snapshot);
	MemoryContext ctx = AllocSetContextCreate(CurrentMemoryContext,
											  "columnar liveness cache",
											  ALLOCSET_DEFAULT_SIZES);
	MemoryContext oldContext = MemoryContextSwitchTo(ctx);
	List	   *rgList = ColumnarReadRowGroupList(storageId, metaSnapshot);
	ColumnarLivenessCache *cache = palloc0(sizeof(ColumnarLivenessCache));
	ListCell   *lc;
	int			i = 0;

	/*
	 * Each native row group is one liveness entry with a single whole-group
	 * delete mask (the delete vector is keyed by group number, chunk id 0). Modeling
	 * it as chunkGroupCount 1 with chunkRowCount == rowCount makes the shared
	 * ColumnarLivenessCacheIsLive map every row to chunk 0.
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

		rml = ColumnarReadDeleteVectorList(storageId, rg->groupNumber, metaSnapshot);
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
ColumnarLivenessCacheIsLive(ColumnarLivenessCache *cache, uint64 rowNumber)
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
ColumnarFreeLivenessCache(ColumnarLivenessCache *cache)
{
	if (cache != NULL)
		MemoryContextDelete(cache->ctx);
}

/*
 * ColumnarReadRowByNumber
 *		Fetch a single row addressed by its row number (spec 6). Used by the
 *		table AM's fetch-by-tid callback (UPDATE re-fetches the old row). Reads
 *		only the one chunk group that holds the row and decodes each column up
 *		to the row's position. Returns false when no stripe covers the row or
 *		the row is marked deleted in the delete vector (spec 7.5).
 */

/* -------------------------------------------------------------------------
 * Statement-scoped decoded row-group cache (issue #143).
 *
 * ColumnarReadRowByNumber() read and decoded a whole row group to return one
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
 * frees them without a hook; ColumnarDiscardFetchCache() clears the descriptors
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
 */
#define COLUMNAR_FETCH_CACHE_MAX_BYTES	(32 * 1024 * 1024)

typedef struct ColumnarFetchGroup
{
	MemoryContext cx;			/* holds every pointer below; NULL when free */
	uint64		storageId;
	uint64		groupNumber;
	CommandId	cid;			/* the command that filled this entry */
	uint64		firstRowNumber;
	uint64		rowCount;
	uint64		fileOffset;
	int			natts;
	char	   *groupBuffer;	/* the group's raw bytes */
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
	uint64		lastUsed;
}			ColumnarFetchGroup;

static ColumnarFetchGroup columnarFetchCache[COLUMNAR_FETCH_CACHE_ENTRIES];
static uint64 columnarFetchClock = 0;

/* rows covered by one rankPrefix entry */
#define COLUMNAR_RANK_BLOCK_ROWS 64
#define COLUMNAR_RANK_BLOCK_BYTES (COLUMNAR_RANK_BLOCK_ROWS / 8)

/*
 * columnar_build_rank_prefix
 *		Cumulative count of set validity bits at each 64-row boundary, so the
 *		number of present values before an arbitrary row can be had without
 *		walking to it. Entry b counts the bits below row b * 64; the array has one
 *		more entry than there are blocks, so the last holds the column's total
 *		present count. Bits at or past rowCount are ignored: the writer leaves the
 *		tail of the final byte undefined, and counting it would claim values the
 *		chunk does not hold.
 */
static uint32 *
columnar_build_rank_prefix(const char *vbits, uint64 rowCount)
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
 * columnar_rank_before
 *		How many values are present in this column before row `row` of the group.
 *		The block prefix plus at most eight byte lookups, in place of a loop over
 *		every earlier row.
 */
static inline uint64
columnar_rank_before(const char *vbits, const uint32 *prefix, uint64 row)
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
 * columnar_build_val_offsets
 *		Byte offset of every present value in a decoded varying-length stream.
 *		One pass over the values, paid once per column per cached group, in place
 *		of a partial pass on every fetch. Fixed-length columns never call this:
 *		their k-th value is at k * attlen and needs no table.
 */
static uint32 *
columnar_build_val_offsets(Form_pg_attribute att, char *rawBuf, uint32 nvalues)
{
	uint32	   *offsets = (uint32 *) palloc(sizeof(uint32) * (nvalues + 1));
	char	   *cursor = rawBuf;
	uint32		k;

	for (k = 0; k < nvalues; k++)
	{
		offsets[k] = (uint32) (cursor - rawBuf);
		cursor += VARSIZE_ANY(cursor);

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
columnar_fetch_entry_reset(ColumnarFetchGroup *e)
{
	if (e->cx != NULL)
		MemoryContextDelete(e->cx);
	memset(e, 0, sizeof(*e));
}

/*
 * ColumnarDiscardFetchCache
 *		Forget every cached group. The contexts hang off TopTransactionContext
 *		and are already gone by the time this runs at transaction end, so this
 *		only clears the descriptors that pointed at them.
 */
void
ColumnarDiscardFetchCache(void)
{
	memset(columnarFetchCache, 0, sizeof(columnarFetchCache));
	columnarFetchClock = 0;
}

/*
 * Find the entry for this group in this command, or prepare an empty one.
 * Returns NULL when nothing should be cached, in which case the caller decodes
 * into its own scratch context exactly as before.
 */
static ColumnarFetchGroup *
columnar_fetch_group_slot(uint64 storageId, uint64 groupNumber, bool *hit)
{
	CommandId	cid = GetCurrentCommandId(false);
	ColumnarFetchGroup *victim = NULL;
	int			i;

	*hit = false;

	for (i = 0; i < COLUMNAR_FETCH_CACHE_ENTRIES; i++)
	{
		ColumnarFetchGroup *e = &columnarFetchCache[i];

		if (e->cx == NULL)
		{
			if (victim == NULL)
				victim = e;
			continue;
		}
		/* an entry from an earlier command can never be used again */
		if (e->cid != cid)
		{
			columnar_fetch_entry_reset(e);
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
		columnar_fetch_entry_reset(victim);
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
 * columnar_fetch_row
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
columnar_fetch_row(Relation rel, Snapshot snapshot, uint64 rowNumber,
				   Datum *values, bool *nulls, bool allColumns,
				   Bitmapset *needed, bool wantValues)
{
	uint64		storageId = ColumnarStorageId(rel);
	TupleDesc	tupdesc = RelationGetDescr(rel);
	int			natts = tupdesc->natts;
	MemoryContext target = CurrentMemoryContext;
	MemoryContext tmp;
	MemoryContext oldContext;
	Snapshot	metaSnapshot;
	List	   *rgList;
	NativeRowGroupMetadata *rg = NULL;
	ColumnarFetchGroup *entry;
	bool		hit;
	int			validityBytes;
	uint64		rowInGrp;
	ListCell   *nlc;
	int			c;

	/*
	 * columnar_fetch_row is called once per item pointer by the executor -- per
	 * row on an index or bitmap scan, and per duplicate by _bt_check_unique()
	 * while it holds the index page (see columnar_metadata.c). None of those
	 * callers checks for interrupts between fetches, and each fetch reads the
	 * row-group list out of the catalog, so a statement that fetches many rows
	 * spends its whole time in here. Without a check the loop is uncancellable
	 * and never notices postmaster death -- a backend spun here at 100% CPU for
	 * three days, outliving its cluster (#212). One check per fetch makes the
	 * statement cancellable; the per-fetch cost itself is a separate fix.
	 */
	CHECK_FOR_INTERRUPTS();

	tmp = AllocSetContextCreate(CurrentMemoryContext, "columnar fetch",
								ALLOCSET_SMALL_SIZES);
	oldContext = MemoryContextSwitchTo(tmp);

	metaSnapshot = ColumnarCatalogSnapshot(snapshot);

	/*
	 * Native (PGCN v1) fetch-by-row-number: find the row group covering the row
	 * and reconstruct each column's value at its position. Index and bitmap scans
	 * and unique enforcement call this. A deleted row (in the group's delete vector or
	 * a not-yet-flushed buffered delete) is not visible.
	 *
	 * The row-group list is read per fetch and deliberately not cached: a group
	 * flushed earlier in this same statement has to become visible here.
	 */
	rgList = ColumnarReadRowGroupList(storageId, metaSnapshot);
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
		List	   *maskList = ColumnarReadDeleteVectorList(storageId,
													   rg->groupNumber,
													   metaSnapshot);
		ListCell   *mlc;
		bool		deleted = ColumnarDeleteVectorBufferedDeleted(rel, rowNumber);

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
	entry = columnar_fetch_group_slot(storageId, rg->groupNumber, &hit);

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
		columnar_fetch_entry_reset(entry);
		entry = columnar_fetch_group_slot(storageId, rg->groupNumber, &hit);
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
		entry->groupBuffer = palloc(rg->byteLength > 0 ? rg->byteLength : 1);
		entry->ccForCol = palloc0(sizeof(NativeColumnChunkMetadata *) * natts);
		entry->rawBuf = palloc0(sizeof(char *) * natts);
		entry->rankPrefix = palloc0(sizeof(uint32 *) * natts);
		entry->valOffset = palloc0(sizeof(uint32 *) * natts);
		MemoryContextSwitchTo(tmp);

		if (rg->byteLength > 0)
			ColumnarReadLogicalData(rel, rg->fileOffset, entry->groupBuffer,
									rg->byteLength);

		nchunks = ColumnarReadColumnChunkList(storageId, rg->groupNumber,
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
		char	   *base;
		char	   *vbits;
		char	   *rawBuf;
		char	   *cursor;
		uint64		present;

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

		base = entry->groupBuffer + (cc->pageOffset - entry->fileOffset);
		vbits = base;
		if (((vbits[rowInGrp >> 3] >> (rowInGrp & 7)) & 1) == 0)
		{
			values[c] = (Datum) 0;
			nulls[c] = true;
			continue;
		}

		if (entry->rawBuf[c] == NULL)
		{
			MemoryContext decOld = MemoryContextSwitchTo(entry->cx);

			if (cc->encodingDescriptorLen == 1 &&
				(uint8) cc->encodingDescriptor[0] == COLUMNAR_NATIVE_ENCDESC_BASELINE)
				entry->rawBuf[c] = base + validityBytes;
			else
				entry->rawBuf[c] =
					columnar_native_decode_chunk(entry->cx, att,
												 base + validityBytes,
												 (uint32) (cc->pageLength - validityBytes),
												 cc->encodingDescriptor,
												 cc->encodingDescriptorLen,
												 cc->blockCodec, NULL, NULL);

			/*
			 * Index the column while it is being decoded, so every fetch into
			 * this group afterwards reaches its row directly (issue #143). Both
			 * indexes live in the entry context and so are measured by the cap
			 * below and dropped with the rest of the entry.
			 */
			entry->rankPrefix[c] = columnar_build_rank_prefix(vbits,
															 entry->rowCount);
			if (att->attlen < 0)
			{
				uint64		nblocks = (entry->rowCount +
									   COLUMNAR_RANK_BLOCK_ROWS - 1) /
					COLUMNAR_RANK_BLOCK_ROWS;

				entry->valOffset[c] =
					columnar_build_val_offsets(att, entry->rawBuf[c],
											   entry->rankPrefix[c][nblocks]);
			}
			MemoryContextSwitchTo(decOld);
		}
		rawBuf = entry->rawBuf[c];

		/*
		 * The row's value sits at the rank-th position in the present-value
		 * stream. A fixed-length column strides straight to it; a varying-length
		 * one reads its offset out of the table built above. Neither depends on
		 * how far into the group the row is, which is what made a cache hit
		 * proportional to the row's position before.
		 */
		present = columnar_rank_before(vbits, entry->rankPrefix[c], rowInGrp);

		if (att->attlen > 0)
			cursor = rawBuf + present * (uint64) att->attlen;
		else
			cursor = rawBuf + entry->valOffset[c][present];

		values[c] = ColumnarDecodeValue(att, &cursor, target);
		nulls[c] = false;
	}

	/*
	 * Hold the entry only while it is worth holding. Measuring the context is
	 * what makes the cap mean decoded bytes rather than stored bytes; a group
	 * over the cap is used for this fetch and then dropped, so an outsized group
	 * costs what it always did rather than pinning memory.
	 *
	 * Dropping it here is safe because nothing handed back points into it: the
	 * value that is returned is decoded into the caller's context by the
	 * ColumnarDecodeValue call above. Only the decoded stream and its two
	 * position indexes live in entry->cx.
	 */
	if (MemoryContextMemAllocated(entry->cx, true) > COLUMNAR_FETCH_CACHE_MAX_BYTES)
		columnar_fetch_entry_reset(entry);

	MemoryContextSwitchTo(oldContext);
	MemoryContextDelete(tmp);
	return true;
}

/*
 * ColumnarReadRowByNumber
 *		Reconstruct every column of the row addressed by a row number. False when
 *		the row is not visible.
 */
bool
ColumnarReadRowByNumber(Relation rel, Snapshot snapshot, uint64 rowNumber,
						Datum *values, bool *nulls)
{
	return columnar_fetch_row(rel, snapshot, rowNumber, values, nulls,
							  true, NULL, true);
}

/*
 * ColumnarReadRowByNumberCols
 *		Decode exactly the columns in `needed`; every other column reads as null.
 *		An empty or NULL set therefore decodes nothing, which is what it says
 *		rather than a silent "everything" -- for every column, call
 *		ColumnarReadRowByNumber, which takes no set and cannot be misread.
 *
 *		Decoding every column whatever the caller wanted is not merely wasted
 *		work on a wide table. The decoded bytes are measured against the fetch
 *		cache's size cap, so the entry is dropped after every fetch and the group
 *		is decoded again for the next row -- the behaviour the cache exists to
 *		remove (issue #157).
 */
bool
ColumnarReadRowByNumberCols(Relation rel, Snapshot snapshot, uint64 rowNumber,
							Datum *values, bool *nulls, Bitmapset *needed)
{
	return columnar_fetch_row(rel, snapshot, rowNumber, values, nulls,
							  false, needed, true);
}

/*
 * ColumnarRowIsLive
 *		Is the row visible? Decodes nothing.
 *
 *		columnar_index_delete_tuples asks exactly this, once per candidate index
 *		tuple on a path nbtree drives during deletion, and answered it by
 *		reconstructing every column and freeing the result unread.
 */
bool
ColumnarRowIsLive(Relation rel, Snapshot snapshot, uint64 rowNumber)
{
	return columnar_fetch_row(rel, snapshot, rowNumber, NULL, NULL,
							  false, NULL, false);
}

void
ColumnarRescanRead(ColumnarReadState *readState)
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
ColumnarEndRead(ColumnarReadState *readState)
{
	MemoryContextDelete(readState->readContext);
}

/*
 * ColumnarReadStats
 *		Report how many chunk groups the scan has read versus skipped by the
 *		min/max skip lists (spec 9). Used by the custom scan's EXPLAIN output.
 */
void
ColumnarReadStats(ColumnarReadState *readState, uint64 *groupsRead,
				  uint64 *groupsSkipped, uint64 *groupsTotal)
{
	*groupsRead = readState->groupsRead;
	*groupsSkipped = readState->groupsSkipped;
	*groupsTotal = readState->groupsRead + readState->groupsSkipped;
}

/*
 * ColumnarVectorsSkipped
 *		How many 1024-value vectors the native scan skipped within read row groups
 *		via per-vector zone maps (native spec 7.1, D5b). Used by EXPLAIN.
 */
uint64
ColumnarVectorsSkipped(ColumnarReadState *readState)
{
	return readState->vectorsSkipped;
}
