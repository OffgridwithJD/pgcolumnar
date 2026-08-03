/*-------------------------------------------------------------------------
 *
 * columnar_write_state.c
 *		The columnar writer: batch rows into chunk groups and stripes, and
 *		flush a stripe (data pages + catalog rows) when it fills or at
 *		transaction pre-commit (spec 4, 9).
 *
 * Pending writes are held per relation for the life of the transaction. On
 * commit they are flushed at pre-commit; on abort they are discarded with
 * the transaction memory.
 *
 *-------------------------------------------------------------------------
 */
#include "columnar.h"

#include "columnar_compat.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "access/xact.h"
#include "storage/procarray.h"
#include "catalog/pg_type.h"
#include "executor/tuptable.h"
#include "miscadmin.h"
#include "storage/lmgr.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/fmgroids.h"
#include "utils/fmgrprotos.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/typcache.h"

/*
 * How many bytes of a column chunk to run through both candidates when deciding
 * whether FSST still pays once the block compressor has had its turn.
 *
 * Bounded because the buffer is a copy of bytes already resident. Set from
 * measurement rather than taste: on four text shapes at 300,000 rows, deciding
 * over 256 kB (the table's training sample) gets one of them backwards, 1 MB
 * gets all four right but lands 4% off the best size on one, and 4 MB matches
 * the answer a whole-chunk decision gives on every shape. Four shapes is what
 * this was calibrated on, so treat it as a floor that worked rather than a
 * tuned optimum -- if a shape is found where it decides wrong, raise it.
 *
 * It trades write time for that accuracy, because the bytes judged here are
 * FSST-encoded once to judge them and again per vector when the answer is yes.
 * Medians of three at 300,000 rows, against main: 4 MB costs 12% on 's' || g
 * and 63% on the e-mail shape while matching main's size on both; 1 MB costs
 * nothing measurable on either but writes the e-mail shape 4% larger. Both are
 * roughly 4x faster than main on high-entropy text, which is where the encoding
 * was pure waste. Size is the guarantee worth keeping for a storage format, so
 * the larger value is the default; lowering it here is the throughput trade.
 */
#define COLUMNAR_FSST_DECIDE_CAP (4 * 1024 * 1024)

/*
 * Direct comparison kinds for the zone min/max (issue #155).
 *
 * Tracking a chunk's min and max costs two comparisons per value per column, and
 * routing each through fmgr is most of what they cost: removing min/max tracking
 * entirely saved 15% of a five-int-column load, where the comparison itself is a
 * subtraction. These are the types whose stored Datum can be read as a C value
 * and compared without a collation. Anything else keeps the fmgr path.
 *
 * float4 and float8 are deliberately NOT here, and the reason is worth keeping
 * whatever else changes. btree float ordering puts NaN above every other value, which a C
 * comparison gets wrong: every comparison against NaN is false, so NaN would read
 * as equal and never become a chunk's maximum. A zone map with a maximum that is
 * too low makes the reader skip a row group that does hold matching rows, and the
 * query silently returns fewer rows. A path that compares to answer one
 * predicate could take the shortcut, because it does not build stored bounds
 * that a later scan trusts; this one does, so it cannot.
 */
typedef enum ColumnarFastCmp
{
	COLUMNAR_FASTCMP_NONE = 0,
	COLUMNAR_FASTCMP_I16,
	COLUMNAR_FASTCMP_I32,
	COLUMNAR_FASTCMP_I64
} ColumnarFastCmp;

/* per-column, per-write-state facts needed for the min/max skip list */
typedef struct ColumnarColumnDef
{
	bool		orderable;		/* type has a default btree comparison proc */
	FmgrInfo	cmpFn;			/* the comparison proc, when orderable */
	Oid			collation;		/* collation to compare under */
	ColumnarFastCmp fastCmp;	/* direct comparison, when the type allows */

	/*
	 * int2/int4 column: its exact sum fits an int64 accumulator, so the zone map
	 * carries a per-vector and per-chunk sum for the zone-map-only aggregate (D5).
	 * Other summable types (int8, numeric, float) are left with a null zone sum.
	 */
	bool		summableInt;

	/*
	 * Bloom-filter support (I7): hashable and non-collatable, so a value's hash
	 * is collation-independent and a probe of the same type is consistent. Only
	 * such columns accumulate hashes for a per-chunk bloom filter.
	 */
	bool		bloomable;
	FmgrInfo	hashFn;
	Oid			hashCollation;	/* collation to hash under (InvalidOid if none) */
} ColumnarColumnDef;

/* one column's two streams within one chunk group */
typedef struct ColumnChunkBuffer
{
	StringInfoData valueStream;
	StringInfoData existsStream;
	uint64		valueCount;

	/* running min/max of the non-null values seen in this chunk */
	bool		hasMinMax;
	Datum		minValue;		/* held in the stripe context */
	Datum		maxValue;

	/* running exact sum of non-null int2/int4 values (zone map, D5) */
	int64		sum;

	/* accumulated 4-byte value hashes for the per-chunk bloom filter (I7) */
	StringInfoData hashBuf;

	/*
	 * Byte offset into valueStream where each row's value begins, indexed by the
	 * row's position within the chunk group. A null row records the offset it
	 * would have had, so the lookup needs no null accounting.
	 *
	 * NULL until the first buffered fetch of this chunk group builds it, and
	 * maintained on append after that. A load that never fetches never builds it
	 * and pays nothing, which is deliberate: the insert path is what #155 is
	 * about, and this exists only for the fetch path (#212).
	 */
	uint32	   *valOffsets;
	uint64		valOffsetsLen;
	uint64		valOffsetsCap;
} ColumnChunkBuffer;

/* one chunk group: all columns for a horizontal slice of rows */
typedef struct ChunkGroupBuffer
{
	uint64		rowCount;
	ColumnChunkBuffer *columns;		/* array [natts] */
} ChunkGroupBuffer;

struct ColumnarWriteState
{
	Oid			relid;
	SubTransactionId subid;			/* subtransaction that owns the buffer */
	TupleDesc	tupdesc;			/* copy owned by writeContext */
	int			natts;
	int			stripeRowLimit;
	int			chunkGroupRowLimit;
	int			compressionType;	/* columnar.compression at open time */
	int			compressionLevel;	/* columnar.compression_level at open time */
	bool		bloomEnabled;		/* columnar.enable_bloom_filter at open time */
	int			encodeEffort;		/* per-table encode_effort at open time */
	uint64		storageId;
	ColumnarColumnDef *colDefs;		/* array [natts], in writeContext */

	MemoryContext writeContext;		/* lives for the transaction */
	MemoryContext stripeContext;	/* reset after each stripe flush */

	List	   *chunkGroups;		/* list of ChunkGroupBuffer* */
	ChunkGroupBuffer *currentGroup;
	uint64		stripeRowCount;

	/*
	 * Reservation for the stripe currently being buffered (spec 2.2, 6). The
	 * stripe id and the first row number are reserved eagerly, when the first
	 * row of a stripe is buffered, so every row has a stable row number (and
	 * item pointer) at insert time for indexing. haveReservation is false
	 * between stripes; the file offset is reserved separately at flush.
	 */
	bool		haveReservation;
	uint64		stripeId;
	uint64		stripeFirstRowNumber;

	/*
	 * Every stripe id this write state has reserved, appended as it is reserved
	 * (issue #311). The online reclustering path needs to know which row groups
	 * it wrote, and no property of the group tells it: a concurrent inserter's
	 * group takes a number above the retired ones exactly as the rewrite's own
	 * output does, and its row numbers can fall inside the rewrite's range,
	 * because reservations interleave. Recording the reservations is the only
	 * exact answer. One append per stripe, against the flush that follows it.
	 *
	 * A plain array of uint64 rather than a List: a stripe id is 64 bits and
	 * lappend_int would truncate it on a storage that has outlived INT_MAX
	 * stripes.
	 */
	uint64	   *reservedStripeIds;
	int			nReservedStripeIds;
	int			reservedStripeIdsSize;

	/*
	 * Phase 2 (gap 26): additional projections fanned out from this relation's
	 * inserts. projWriters hangs off the base write state so it shares the
	 * (relid, subid) lifecycle -- flush, discard, subxact abort/promote all
	 * follow the base automatically. projInited guards the one-time catalog
	 * lookup that builds the list.
	 */
	bool		projInited;
	List	   *projWriters;	/* list of ColumnarProjWriter * */
};

/* per-backend registry of pending write states, in ColumnarWriteContext */
static MemoryContext ColumnarWriteContext = NULL;
static List *ColumnarWriteStates = NIL;

static void columnar_flush_row_group(ColumnarWriteState *writeState);
static void flush_ws_projections(ColumnarWriteState *writeState);
static ChunkGroupBuffer *columnar_start_chunk_group(ColumnarWriteState *writeState);
static uint64 *grow_uint64_array(uint64 *arr, int oldSize, int newSize);
static void columnar_init_col_defs(ColumnarWriteState *writeState);

/*
 * columnar_cmp_value
 *		Compare two values of a column under its ordering, taking the direct
 *		route when the type allows one and fmgr otherwise. The integer kinds
 *		reproduce their btree comparison exactly, so which route is taken can
 *		never change the answer.
 */
static inline int32
columnar_cmp_value(ColumnarColumnDef *def, Datum a, Datum b)
{
	switch (def->fastCmp)
	{
		case COLUMNAR_FASTCMP_I16:
			{
				int16		x = DatumGetInt16(a);
				int16		y = DatumGetInt16(b);

				return (x < y) ? -1 : (x > y) ? 1 : 0;
			}
		case COLUMNAR_FASTCMP_I32:
			{
				int32		x = DatumGetInt32(a);
				int32		y = DatumGetInt32(b);

				return (x < y) ? -1 : (x > y) ? 1 : 0;
			}
		case COLUMNAR_FASTCMP_I64:
			{
				int64		x = DatumGetInt64(a);
				int64		y = DatumGetInt64(b);

				return (x < y) ? -1 : (x > y) ? 1 : 0;
			}
		case COLUMNAR_FASTCMP_NONE:
			break;
	}

	return DatumGetInt32(FunctionCall2Coll(&def->cmpFn, def->collation, a, b));
}

/*
 * columnar_init_col_defs
 *		Allocate and fill writeState->colDefs: for each column, resolve the btree
 *		comparison proc (for the per-chunk min/max skip list, spec 7.2) and the
 *		hash proc (for the per-chunk bloom filter, I7). Shared by the base writer
 *		and the projection writer so both carry skip metadata.
 */
static void
columnar_init_col_defs(ColumnarWriteState *writeState)
{
	int			c;

	writeState->colDefs = palloc0(sizeof(ColumnarColumnDef) * writeState->natts);

	for (c = 0; c < writeState->natts; c++)
	{
		Form_pg_attribute att = TupleDescAttr(writeState->tupdesc, c);
		TypeCacheEntry *tce;

		if (att->attisdropped)
			continue;

		tce = lookup_type_cache(att->atttypid,
								TYPECACHE_CMP_PROC_FINFO |
								TYPECACHE_HASH_PROC_FINFO);
		if (OidIsValid(tce->cmp_proc_finfo.fn_oid))
		{
			writeState->colDefs[c].orderable = true;
			fmgr_info_copy(&writeState->colDefs[c].cmpFn,
						   &tce->cmp_proc_finfo, ColumnarWriteContext);
			writeState->colDefs[c].collation = att->attcollation;

			/*
			 * Resolve a direct comparison where the type permits one. These
			 * compare byte-for-byte under any collation, so the fast path
			 * cannot disagree with the operator it replaces; the zone map it
			 * feeds is read back through the same ordering.
			 */
			switch (att->atttypid)
			{
				case INT2OID:
					writeState->colDefs[c].fastCmp = COLUMNAR_FASTCMP_I16;
					break;
				case INT4OID:
				case DATEOID:
					writeState->colDefs[c].fastCmp = COLUMNAR_FASTCMP_I32;
					break;
				case INT8OID:
				case TIMESTAMPOID:
				case TIMESTAMPTZOID:
					writeState->colDefs[c].fastCmp = COLUMNAR_FASTCMP_I64;
					break;
				default:
					writeState->colDefs[c].fastCmp = COLUMNAR_FASTCMP_NONE;
					break;
			}
		}

		/* int2/int4: exact sum fits int64, carried in the zone map (D5) */
		writeState->colDefs[c].summableInt =
			(att->atttypid == INT2OID || att->atttypid == INT4OID);

		/*
		 * Bloom filter for hashable columns whose collation is safe (I7, gap
		 * 25): non-collatable types and deterministic collations, so a value
		 * hashes consistently between this build and an equality probe. A
		 * nondeterministic collation is left unbloomed.
		 */
		if (writeState->bloomEnabled &&
			OidIsValid(tce->hash_proc_finfo.fn_oid) &&
			ColumnarCollationIsDeterministic(att->attcollation))
		{
			writeState->colDefs[c].bloomable = true;
			fmgr_info_copy(&writeState->colDefs[c].hashFn,
						   &tce->hash_proc_finfo, ColumnarWriteContext);
			writeState->colDefs[c].hashCollation = att->attcollation;
		}
	}
}

/*
 * ColumnarWriteStateStripeCount
 *		How many stripe reservations this write state has taken so far (#311).
 *
 *		A caller that wants to know which groups IT wrote records this before
 *		its writes and takes the tail afterwards, because ColumnarGetWriteState
 *		can hand back a state that already holds another statement's entries.
 */
int
ColumnarWriteStateStripeCount(ColumnarWriteState *ws)
{
	return ws->nReservedStripeIds;
}

/*
 * ColumnarWriteStateStripeIds
 *		The stripe ids this write state has reserved, in reservation order.
 *		Points at the write state's own array, which stays valid until the
 *		transaction ends.
 */
uint64 *
ColumnarWriteStateStripeIds(ColumnarWriteState *ws, int *n)
{
	*n = ws->nReservedStripeIds;
	return ws->reservedStripeIds;
}

/*
 * grow_uint64_array
 *		Enlarge (or first allocate) an array of uint64 in the current context.
 */
static uint64 *
grow_uint64_array(uint64 *arr, int oldSize, int newSize)
{
	if (arr == NULL)
		return (uint64 *) palloc(sizeof(uint64) * newSize);
	Assert(newSize > oldSize);
	return (uint64 *) repalloc(arr, sizeof(uint64) * newSize);
}

/*
 * ColumnarGetWriteState
 *		Find or create the pending write state for a relation.
 */
ColumnarWriteState *
ColumnarGetWriteState(Relation rel)
{
	Oid			relid = RelationGetRelid(rel);
	SubTransactionId subid = GetCurrentSubTransactionId();
	ListCell   *lc;
	MemoryContext oldContext;
	ColumnarWriteState *writeState;

	/*
	 * A write state is keyed by (relation, subtransaction) so that a buffer
	 * never mixes rows written under different subtransactions. That keeps the
	 * rollback of a subtransaction a simple matter of dropping its buffers
	 * (spec 9).
	 */
	foreach(lc, ColumnarWriteStates)
	{
		writeState = (ColumnarWriteState *) lfirst(lc);
		if (writeState->relid != relid || writeState->subid != subid)
			continue;

		/*
		 * The descriptor is snapshotted when the buffer is opened, so a buffer
		 * that predates an ALTER TABLE ... ADD COLUMN in this same transaction
		 * still has the old column count and silently drops every value written
		 * into the new column: the flushed chunks carry the old shape, and the
		 * reader then serves the column's missing value for those rows. Nothing
		 * else invalidates the buffer, since the write state registers no
		 * relcache callback.
		 *
		 * The buffered rows are correct under the descriptor they were written
		 * with, so flush them under it and open a new buffer for the new shape.
		 */
		if (writeState->natts == RelationGetDescr(rel)->natts)
			return writeState;

		if (writeState->stripeRowCount > 0)
			columnar_flush_row_group(writeState);
		flush_ws_projections(writeState);

		oldContext = MemoryContextSwitchTo(ColumnarWriteContext);
		ColumnarWriteStates = list_delete_ptr(ColumnarWriteStates, writeState);
		MemoryContextSwitchTo(oldContext);
		break;
	}

	if (ColumnarWriteContext == NULL)
		ColumnarWriteContext = AllocSetContextCreate(TopTransactionContext,
													 "columnar write",
													 ALLOCSET_DEFAULT_SIZES);

	oldContext = MemoryContextSwitchTo(ColumnarWriteContext);

	writeState = palloc0(sizeof(ColumnarWriteState));
	writeState->relid = relid;
	writeState->subid = subid;
	/* CopyConstr (not CopyEntry) so attgenerated is preserved: the flush skips
	 * writing a chunk for virtual generated columns (attgenerated 'v'), which
	 * CreateTupleDescCopy would clear. */
	writeState->tupdesc = CreateTupleDescCopyConstr(RelationGetDescr(rel));
	writeState->natts = writeState->tupdesc->natts;
	writeState->stripeRowLimit = columnar_stripe_row_limit;
	writeState->chunkGroupRowLimit = columnar_chunk_group_row_limit;
	writeState->compressionType = columnar_compression;
	writeState->compressionLevel = columnar_compression_level;

	/*
	 * Whether to build bloom filters at all, captured here with the other
	 * write-time settings rather than consulted per row, so one stripe is
	 * written under one decision.
	 */
	writeState->bloomEnabled = columnar_enable_bloom_filter;
	writeState->encodeEffort = COLUMNAR_ENCODE_EFFORT_FULL;
	writeState->storageId = ColumnarStorageId(rel);

	/*
	 * Per-table options (spec 7.4) override the instance-wide GUC defaults for
	 * this relation's writes. They are read at write-state creation, so a value
	 * set with pgcolumnar.set_options takes effect for subsequent
	 * inserts (spec 9).
	 */
	{
		ColumnarOptions opts;

		if (ColumnarReadOptions(relid, &opts))
		{
			if (opts.stripeRowLimitSet)
				writeState->stripeRowLimit = opts.stripeRowLimit;
			if (opts.chunkGroupRowLimitSet)
				writeState->chunkGroupRowLimit = opts.chunkGroupRowLimit;
			if (opts.compressionSet)
				writeState->compressionType = opts.compressionType;
			if (opts.compressionLevelSet)
				writeState->compressionLevel = opts.compressionLevel;
			if (opts.encodeEffortSet)
				writeState->encodeEffort = opts.encodeEffort;
		}
	}

	columnar_init_col_defs(writeState);

	writeState->stripeContext = AllocSetContextCreate(ColumnarWriteContext,
													  "columnar stripe",
													  ALLOCSET_DEFAULT_SIZES);
	writeState->writeContext = ColumnarWriteContext;
	writeState->chunkGroups = NIL;
	writeState->currentGroup = NULL;
	writeState->stripeRowCount = 0;
	writeState->haveReservation = false;
	writeState->stripeId = 0;
	writeState->stripeFirstRowNumber = 0;
	writeState->reservedStripeIds = NULL;
	writeState->nReservedStripeIds = 0;
	writeState->reservedStripeIdsSize = 0;

	ColumnarWriteStates = lappend(ColumnarWriteStates, writeState);

	MemoryContextSwitchTo(oldContext);

	return writeState;
}

/*
 * ColumnarEnsureStorageRow
 *		Create the native storage catalog row for `rel` if it does not exist,
 *		with exactly the metadata a normal flush would record. Used by
 *		pgcolumnar.parallel_copy's coordinator to pre-create and commit the storage
 *		row before launching concurrent loaders, so each loader (with
 *		columnar_bulk_parallel_writer set) sees it committed and skips the
 *		storage-row creation lock. Idempotent -- ColumnarInsertNativeStorageRow
 *		returns if the row already exists.
 */
void
ColumnarEnsureStorageRow(Relation rel)
{
	NativeStorageMetadata s;
	ColumnarOptions opts;
	int			stripeRowLimit = columnar_stripe_row_limit;

	if (ColumnarReadOptions(RelationGetRelid(rel), &opts) && opts.stripeRowLimitSet)
		stripeRowLimit = opts.stripeRowLimit;

	s.storageId = ColumnarStorageId(rel);
	s.relationOid = RelationGetRelid(rel);
	s.formatVersion = COLUMNAR_NATIVE_VERSION_MAJOR;
	s.vectorLength = COLUMNAR_NATIVE_VECTOR_LENGTH;
	s.rowGroupLimit = stripeRowLimit;
	ColumnarInsertNativeStorageRow(&s);
}

/*
 * buffered_note_offset
 *		Record where the next row's value begins, if this column is tracking
 *		offsets at all.
 *
 * Returns immediately when the array does not exist, which is the case for every
 * write that is never fetched from. The array is created only by
 * buffered_build_offsets, on the first buffered fetch of the chunk group.
 */
static void
buffered_note_offset(ColumnChunkBuffer *col, MemoryContext cxt, uint32 off)
{
	if (col->valOffsets == NULL)
		return;

	if (col->valOffsetsLen >= col->valOffsetsCap)
	{
		MemoryContext old = MemoryContextSwitchTo(cxt);

		col->valOffsetsCap *= 2;
		col->valOffsets = repalloc(col->valOffsets,
								   sizeof(uint32) * col->valOffsetsCap);
		MemoryContextSwitchTo(old);
	}
	col->valOffsets[col->valOffsetsLen++] = off;
}

/*
 * buffered_build_offsets
 *		Walk the column's value stream once and record where every row's value
 *		begins, so later fetches can address a row instead of walking to it.
 *
 * This is the O(n) pass that used to run on *every* fetch. Decoded values are
 * thrown away here, so they are built in a scratch context that is deleted at
 * the end rather than left in the stripe context.
 */
static void
buffered_build_offsets(ColumnChunkBuffer *col, Form_pg_attribute att,
					   MemoryContext cxt, uint64 rowCount)
{
	MemoryContext old;
	MemoryContext scratch;
	char	   *cursor = col->valueStream.data;
	uint64		i;

	old = MemoryContextSwitchTo(cxt);
	col->valOffsetsCap = Max(rowCount, 64);
	col->valOffsets = palloc(sizeof(uint32) * col->valOffsetsCap);
	col->valOffsetsLen = 0;
	MemoryContextSwitchTo(old);

	scratch = AllocSetContextCreate(CurrentMemoryContext,
									"columnar buffered offsets",
									ALLOCSET_SMALL_SIZES);

	for (i = 0; i < rowCount; i++)
	{
		/*
		 * Bounded by chunk_group_row_limit, which is user-settable, so this pass
		 * is a cancellation point for the same reason the decoders are. It is
		 * also on the unique-check fetch path, which had no interrupt check at
		 * all before #220 and still has none below columnar_fetch_row.
		 */
		CHECK_FOR_INTERRUPTS();

		col->valOffsets[col->valOffsetsLen++] =
			(uint32) (cursor - col->valueStream.data);

		if (col->existsStream.data[i])
			(void) ColumnarDecodeValue(att, &cursor, scratch);
	}

	MemoryContextDelete(scratch);
}

/*
 * columnar_start_chunk_group
 *		Begin a new chunk group inside the current stripe, allocated in the
 *		stripe memory context.
 */
static ChunkGroupBuffer *
columnar_start_chunk_group(ColumnarWriteState *writeState)
{
	MemoryContext oldContext = MemoryContextSwitchTo(writeState->stripeContext);
	ChunkGroupBuffer *group = palloc0(sizeof(ChunkGroupBuffer));
	int			c;

	group->rowCount = 0;
	group->columns = palloc0(sizeof(ColumnChunkBuffer) * writeState->natts);
	for (c = 0; c < writeState->natts; c++)
	{
		initStringInfo(&group->columns[c].valueStream);
		initStringInfo(&group->columns[c].existsStream);
		initStringInfo(&group->columns[c].hashBuf);
		group->columns[c].valueCount = 0;
	}

	writeState->chunkGroups = lappend(writeState->chunkGroups, group);
	writeState->currentGroup = group;

	MemoryContextSwitchTo(oldContext);
	return group;
}

/*
 * ColumnarWriteRow
 *		Append one row to the current stripe, opening a new chunk group when
 *		the current one is full and flushing the stripe when it reaches the
 *		stripe row limit. Returns the stable 1-based row number assigned to the
 *		row (spec 6), so the caller can set the row's item pointer for indexing.
 */
uint64
ColumnarWriteRow(ColumnarWriteState *writeState, Relation rel,
				 Datum *values, bool *nulls)
{
	ChunkGroupBuffer *group = writeState->currentGroup;
	uint64		rowNumber;
	int			c;

	/*
	 * Reserve this stripe's id and row-number range when its first row is
	 * buffered (spec 2.2, 6). A whole stripe_row_limit worth of row numbers is
	 * reserved up front so the stripe's rows are numbered contiguously from
	 * stripeFirstRowNumber; the writer flushes at stripe_row_limit, so the run
	 * is never overrun. Any unused tail (a stripe flushed early) is a harmless
	 * gap in the row-number space.
	 */
	if (!writeState->haveReservation)
	{
		ColumnarReserveRowNumbers(rel, (uint64) writeState->stripeRowLimit,
								  &writeState->stripeId,
								  &writeState->stripeFirstRowNumber);
		writeState->haveReservation = true;

		/*
		 * Record the reservation (#311). Allocated in writeContext, not
		 * stripeContext, because it must outlive the stripe flush that resets
		 * the latter.
		 */
		{
			MemoryContext old = MemoryContextSwitchTo(writeState->writeContext);

			if (writeState->nReservedStripeIds >= writeState->reservedStripeIdsSize)
			{
				int			newSize = writeState->reservedStripeIdsSize == 0
					? 16 : writeState->reservedStripeIdsSize * 2;

				writeState->reservedStripeIds =
					grow_uint64_array(writeState->reservedStripeIds,
									  writeState->reservedStripeIdsSize, newSize);
				writeState->reservedStripeIdsSize = newSize;
			}
			writeState->reservedStripeIds[writeState->nReservedStripeIds++] =
				writeState->stripeId;
			MemoryContextSwitchTo(old);
		}
	}

	rowNumber = writeState->stripeFirstRowNumber + writeState->stripeRowCount;

	if (group == NULL ||
		group->rowCount >= (uint64) writeState->chunkGroupRowLimit)
		group = columnar_start_chunk_group(writeState);

	for (c = 0; c < writeState->natts; c++)
	{
		ColumnChunkBuffer *col = &group->columns[c];
		Form_pg_attribute att = TupleDescAttr(writeState->tupdesc, c);

		/*
		 * Where this row's value starts, recorded before it is written. Only
		 * costs anything once a buffered fetch has built the array; see
		 * buffered_note_offset.
		 */
		buffered_note_offset(col, writeState->stripeContext,
							 (uint32) col->valueStream.len);

		if (nulls[c])
		{
			appendStringInfoChar(&col->existsStream, 0);
		}
		else
		{
			appendStringInfoChar(&col->existsStream, 1);
			ColumnarEncodeValue(&col->valueStream, att, values[c]);
			col->valueCount++;

			/* accumulate the value's hash for the per-chunk bloom filter (I7) */
			if (writeState->colDefs[c].bloomable)
			{
				uint32		h = DatumGetUInt32(
					FunctionCall1Coll(&writeState->colDefs[c].hashFn,
									  writeState->colDefs[c].hashCollation,
									  values[c]));

				appendBinaryStringInfo(&col->hashBuf, (char *) &h, sizeof(uint32));
			}

			/* maintain the per-chunk exact int sum for the zone map (D5) */
			if (writeState->colDefs[c].summableInt)
				col->sum += (att->atttypid == INT2OID)
					? (int64) DatumGetInt16(values[c])
					: (int64) DatumGetInt32(values[c]);

			/* maintain the per-chunk min/max for orderable types */
			if (writeState->colDefs[c].orderable)
			{
				ColumnarColumnDef *def = &writeState->colDefs[c];
				MemoryContext oldContext =
					MemoryContextSwitchTo(writeState->stripeContext);

				if (!col->hasMinMax)
				{
					col->minValue = datumCopy(values[c], att->attbyval,
											  att->attlen);
					col->maxValue = datumCopy(values[c], att->attbyval,
											  att->attlen);
					col->hasMinMax = true;
				}
				else
				{
					/*
					 * A value above the running maximum cannot also be below the
					 * running minimum, so the second comparison is only needed
					 * when the first does not settle it. Testing the maximum
					 * first makes the ascending case -- which is what a bulk load
					 * of a serial or timestamp column produces -- cost one
					 * comparison per value instead of two.
					 */
					int32		cmpMax = columnar_cmp_value(def, values[c],
														   col->maxValue);

					if (cmpMax > 0)
					{
						if (!att->attbyval)
							pfree(DatumGetPointer(col->maxValue));
						col->maxValue = datumCopy(values[c], att->attbyval,
												  att->attlen);
					}
					else if (columnar_cmp_value(def, values[c],
												col->minValue) < 0)
					{
						if (!att->attbyval)
							pfree(DatumGetPointer(col->minValue));
						col->minValue = datumCopy(values[c], att->attbyval,
												  att->attlen);
					}
				}

				MemoryContextSwitchTo(oldContext);
			}
		}
	}

	group->rowCount++;
	writeState->stripeRowCount++;

	if (writeState->stripeRowCount >= (uint64) writeState->stripeRowLimit)
		columnar_flush_row_group(writeState);

	return rowNumber;
}

/*
 * ColumnarBufferedRowByNumber
 *		Reconstruct a single row that is still held in an unflushed write buffer,
 *		addressed by its row number (spec 6). Returns true and fills values/nulls
 *		(by-reference values copied into the current memory context) when the row
 *		is present in a pending stripe buffer for this relation; false otherwise.
 *
 *		This lets an index fetch see rows written earlier in the same statement
 *		but not yet flushed, which is what makes a unique constraint reject two
 *		duplicate rows inserted by a single statement: the btree uniqueness check
 *		fetches the first row's item pointer while both rows are still buffered.
 *		It reads only process-local memory, so it acquires no locks and is safe
 *		to call while the caller holds an index buffer lock.
 */
bool
ColumnarBufferedRowByNumber(Relation rel, uint64 rowNumber,
							Datum *values, bool *nulls)
{
	Oid			relid = RelationGetRelid(rel);
	MemoryContext target = CurrentMemoryContext;
	ListCell   *lc;

	foreach(lc, ColumnarWriteStates)
	{
		ColumnarWriteState *ws = (ColumnarWriteState *) lfirst(lc);
		uint64		offset;
		uint64		accumulated;
		ListCell   *glc;

		if (ws->relid != relid || !ws->haveReservation)
			continue;
		if (rowNumber < ws->stripeFirstRowNumber ||
			rowNumber >= ws->stripeFirstRowNumber + ws->stripeRowCount)
			continue;

		offset = rowNumber - ws->stripeFirstRowNumber;

		accumulated = 0;
		foreach(glc, ws->chunkGroups)
		{
			ChunkGroupBuffer *group = (ChunkGroupBuffer *) lfirst(glc);
			uint64		posInGroup;
			int			c;

			if (offset >= accumulated + group->rowCount)
			{
				accumulated += group->rowCount;
				continue;
			}

			posInGroup = offset - accumulated;

			for (c = 0; c < ws->natts; c++)
			{
				ColumnChunkBuffer *col = &group->columns[c];
				Form_pg_attribute att = TupleDescAttr(ws->tupdesc, c);
				char	   *existsBytes = col->existsStream.data;
				char	   *cursor;

				/*
				 * Address the row rather than walking to it.
				 *
				 * This loop used to decode and discard every earlier value in
				 * the chunk group, for every column, on every fetch, purely to
				 * advance the cursor. _bt_check_unique() calls this once per
				 * candidate while a statement buffers rows, so the cost was
				 * O(rows x columns) per fetch and quadratic across a statement.
				 * That is what pinned a core for three days in #212.
				 *
				 * The offsets are built once per chunk group on the first fetch
				 * and maintained on append after that, so a load that never
				 * fetches still pays nothing.
				 */
				if (col->valOffsets == NULL ||
					col->valOffsetsLen < group->rowCount)
					buffered_build_offsets(col, att, ws->stripeContext,
										   group->rowCount);

				cursor = col->valueStream.data + col->valOffsets[posInGroup];

				if (existsBytes[posInGroup])
				{
					values[c] = ColumnarDecodeValue(att, &cursor, target);
					nulls[c] = false;
				}
				else
				{
					values[c] = (Datum) 0;
					nulls[c] = true;
				}
			}

			return true;
		}
	}

	return false;
}

/*
 * columnar_flush_row_group
 *		Native-format (PGCN v1) flush. Lay out the accumulated rows as one row
 *		group: each column is a column chunk of [validity bitmap][values], where
 *		the validity bitmap is one bit per row (LSB-first) and the values are the
 *		concatenated present-value streams encoded per-vector via the adaptive
 *		cascade and then optionally block-compressed. Compute per-vector and
 *		whole-chunk zone maps plus a per-chunk bloom filter. Write the bytes to
 *		the relation file and record the native catalog rows (storage, row_group,
 *		column_chunk, zone_map, bloom).
 */
static void
columnar_flush_row_group(ColumnarWriteState *writeState)
{
	MemoryContext flushContext;
	MemoryContext oldContext;
	Relation	rel;
	int			natts = writeState->natts;
	StringInfo	data;
	uint64	   *chunkOffset;
	uint64	   *chunkLength;
	char	  **chunkDescriptor;
	uint32	   *chunkDescriptorLen;
	int		   *chunkBlockCodec;
	uint64		rowCount = writeState->stripeRowCount;
	/*
	 * The row group number is the stripe id reserved from the metapage when this
	 * stripe began buffering (persistent and unique per storage), so incremental
	 * inserts across transactions never collide on (storage_id, group_number).
	 * A per-write-state counter would restart at 0 and clash with existing groups.
	 */
	uint64		groupNumber = writeState->stripeId;
	uint64		fileOffset;
	uint64		dataLength;
	bool		reusedOffset;
	int			validityBytes = (int) ((rowCount + 7) / 8);
	ListCell   *lc;
	int			c;
	bool		pushedSnapshot = false;
	List	   *zoneRows = NIL;		/* NativeZoneMapMetadata * to insert (D5) */
	List	   *bloomRows = NIL;		/* NativeBloomMetadata * to insert (D5b) */

	/*
	 * Nothing buffered: a flush of an empty write state must be a no-op. The
	 * stripe id is only consumed by a group that actually holds rows, so writing
	 * a zero-row group here would reuse a stale stripe id and collide with the
	 * group already written for it (duplicate row_group_pkey). This guards every
	 * caller, including the unconditional pre-commit flush.
	 */
	if (rowCount == 0)
		return;

	if (!ActiveSnapshotSet())
	{
		PushActiveSnapshot(GetTransactionSnapshot());
		pushedSnapshot = true;
	}

	flushContext = AllocSetContextCreate(CurrentMemoryContext,
										 "columnar native flush",
										 ALLOCSET_DEFAULT_SIZES);
	oldContext = MemoryContextSwitchTo(flushContext);

	data = makeStringInfo();
	chunkOffset = palloc0(sizeof(uint64) * natts);
	chunkLength = palloc0(sizeof(uint64) * natts);
	chunkDescriptor = palloc0(sizeof(char *) * natts);
	chunkDescriptorLen = palloc0(sizeof(uint32) * natts);
	chunkBlockCodec = palloc0(sizeof(int) * natts);

	/*
	 * Build the row group column-major: each column chunk is
	 * [validity bitmap][values]. The values region is encoded per 1024-value
	 * vector (one chunk group) with the lightweight adaptive selector (D4), then
	 * an optional block codec runs over the whole encoded region. The chosen
	 * scheme is recorded in the encoding descriptor so the reader reconstructs
	 * the exact raw bytes. A vector whose selector returns NONE is stored raw,
	 * so an incompressible column stays byte-for-byte the D2b baseline plus the
	 * descriptor.
	 */
	for (c = 0; c < natts; c++)
	{
		Form_pg_attribute att = TupleDescAttr(writeState->tupdesc, c);
		uint8	   *validity = (uint8 *) palloc0(validityBytes);
		uint64		rowIdx = 0;
		StringInfo	encoded = makeStringInfo();
		StringInfo	desc = makeStringInfo();
		uint8		descVersion = COLUMNAR_NATIVE_ENCDESC_VERSION;
		uint8		descReserved = 0;
		uint32		vectorCount = (uint32) list_length(writeState->chunkGroups);
		char	   *fsstTable = NULL;	/* chunk-shared FSST table (E3b), or NULL */
		uint32		fsstTableLen = 0;
		char	   *finalData;
		uint32		finalLen;
		int			blockCodec = COLUMNAR_COMPRESSION_NONE;
		ColumnarColumnDef *def = &writeState->colDefs[c];
		int			vec = 0;
		bool		chunkHasMinMax = false;
		Datum		chunkMin = (Datum) 0;
		Datum		chunkMax = (Datum) 0;
		uint64		chunkValueCount = 0;
		int64		chunkSum = 0;

		chunkOffset[c] = data->len;

		/*
		 * Virtual generated columns (attgenerated 'v', PostgreSQL 18+) are computed
		 * on read from their base columns and never stored, so writing an all-null
		 * chunk for them wastes space. Skip the chunk entirely: the reader finds no
		 * column_chunk for this column, treats it as absent, and returns its missing
		 * value (NULL via getmissingattr), while the executor expands the generated
		 * expression regardless. A NULL descriptor marks the column skipped for the
		 * column_chunk insertion pass below. ('v' is never set on PG15-17.)
		 */
		if (att->attgenerated == 'v')
		{
			chunkLength[c] = 0;
			chunkDescriptor[c] = NULL;
			chunkDescriptorLen[c] = 0;
			chunkBlockCodec[c] = COLUMNAR_COMPRESSION_NONE;
			pfree(validity);
			continue;
		}

		foreach(lc, writeState->chunkGroups)
		{
			ChunkGroupBuffer *group = (ChunkGroupBuffer *) lfirst(lc);
			ColumnChunkBuffer *col = &group->columns[c];
			char	   *existsBytes = col->existsStream.data;
			uint64		i;

			for (i = 0; i < group->rowCount; i++, rowIdx++)
				if (existsBytes[i])
					validity[rowIdx >> 3] |= (uint8) (1 << (rowIdx & 7));
		}
		appendBinaryStringInfo(data, (char *) validity, validityBytes);

		/* descriptor header */
		appendBinaryStringInfo(desc, (char *) &descVersion, 1);
		appendBinaryStringInfo(desc, (char *) &descReserved, 1);
		appendBinaryStringInfo(desc, (char *) &vectorCount, sizeof(uint32));

		/*
		 * E3b: build one FSST symbol table for the whole column chunk from a
		 * bounded sample of its value streams, so the costly table build is paid
		 * once here rather than once per vector. It is stored once as a trailing
		 * descriptor region and reused by every FSST vector below. Non-varlena
		 * columns and columns FSST cannot help leave it NULL.
		 */
		if (att->attlen == -1)
		{
			StringInfoData corpus;
			uint32		sampleLen = 0;

			initStringInfo(&corpus);
			foreach(lc, writeState->chunkGroups)
			{
				ChunkGroupBuffer *group = (ChunkGroupBuffer *) lfirst(lc);
				ColumnChunkBuffer *col = &group->columns[c];

				if (col->valueStream.len > 0)
					appendBinaryStringInfo(&corpus, col->valueStream.data,
										   col->valueStream.len);
				if (sampleLen == 0 && corpus.len >= 262144)
					sampleLen = (uint32) corpus.len;	/* matches FSST_SAMPLE_CAP:
														 * train the one per-chunk
														 * table on a broad sample */
				if (corpus.len >= COLUMNAR_FSST_DECIDE_CAP)
					break;
			}
			if (sampleLen == 0)
				sampleLen = (uint32) corpus.len;

			/*
			 * encode_effort = fast skips the FSST substring search entirely:
			 * no symbol table, so no whole-corpus decision below and no
			 * per-vector encode either, since all three are reached only
			 * through a non-NULL fsstTable.
			 *
			 * This is where a text column's write cost lives (issue #155).
			 * Measured on 1,000,000 rows, one text column, the load runs 1.2x
			 * to 5.7x faster without it -- and on five of the seven shapes
			 * measured it produced byte-for-byte identical storage, so that
			 * time bought nothing at all. On the two where FSST does win it
			 * costs 2.7% and 12.2% more space, which is why this is a choice
			 * offered rather than a default changed.
			 */
			/*
			 * Skip the FSST symbol-table build when a cheap distinct probe shows
			 * the dictionary wins outright (#155): the build is the single largest
			 * cost of a text load, and for a low-cardinality column the table is
			 * built and then never used per vector. The probe reads the same corpus
			 * the keep/drop decision uses, and only skips when the dictionary is
			 * viable and wins for every vector, so the stored bytes are identical.
			 */
			if (corpus.len > 0 &&
				writeState->encodeEffort != COLUMNAR_ENCODE_EFFORT_FAST &&
				!ColumnarFsstDictWins(corpus.data, (uint32) corpus.len))
				ColumnarFsstBuildChunkTable(corpus.data, sampleLen, att,
											&fsstTable, &fsstTableLen);

			/*
			 * A table that shrinks every vector can still enlarge the chunk,
			 * because what lands on disk is this stream after the codec below
			 * has run, and FSST codes compress far worse than the text they
			 * replace. Ask before committing to it, and drop the table when the
			 * answer is no: the vectors below then take their ordinary encoding
			 * and skip the FSST attempt altogether, so the check pays for itself
			 * in write time exactly when it saves space.
			 *
			 * This is asked over a much longer run of bytes than the table is
			 * trained on, because the answer moves with volume and the sample
			 * size is not neutral: zstd needs a good deal of FSST output before
			 * it finds the structure in it. Measured on 300,000 e-mail-shaped
			 * rows, the 256 kB training sample says FSST is 24% worse while over
			 * the whole column it is 23% better -- a verdict that is not merely
			 * imprecise but inverted, so no margin on the sample would be safe.
			 */
			if (fsstTable != NULL &&
				!ColumnarFsstHelpsCompressed(corpus.data, (uint32) corpus.len,
											 fsstTable, fsstTableLen,
											 writeState->compressionType,
											 writeState->compressionLevel))
			{
				pfree(fsstTable);
				fsstTable = NULL;
				fsstTableLen = 0;
			}

			pfree(corpus.data);
		}

		/* encode each vector (chunk group) and record its descriptor entry */
		foreach(lc, writeState->chunkGroups)
		{
			ChunkGroupBuffer *group = (ChunkGroupBuffer *) lfirst(lc);
			ColumnChunkBuffer *col = &group->columns[c];
			char	   *encData;
			uint32		encLen;
			int			encType;
			uint8		entryType;
			uint32		entryValueCount;
			uint32		entryRawLen;

			encType = ColumnarEncodeChunk(col->valueStream.data,
										  col->valueStream.len, att,
										  col->valueCount, fsstTable, fsstTableLen,
										  &encData, &encLen);

			if (encLen > 0)
				appendBinaryStringInfo(encoded, encData, encLen);

			entryType = (uint8) encType;
			entryValueCount = (uint32) col->valueCount;
			entryRawLen = (uint32) col->valueStream.len;
			appendBinaryStringInfo(desc, (char *) &entryType, 1);
			appendBinaryStringInfo(desc, (char *) &entryValueCount, sizeof(uint32));
			appendBinaryStringInfo(desc, (char *) &entryRawLen, sizeof(uint32));
			appendBinaryStringInfo(desc, (char *) &encLen, sizeof(uint32));

			/* per-vector zone map (native spec 7.1, D5) */
			{
				NativeZoneMapMetadata *z = palloc0(sizeof(NativeZoneMapMetadata));

				z->storageId = writeState->storageId;
				z->groupNumber = groupNumber;
				z->columnIndex = c;
				z->vectorIndex = vec;
				z->valueCount = col->valueCount;
				z->nullCount = group->rowCount - col->valueCount;

				if (def->summableInt && col->valueCount > 0)
				{
					z->hasSum = true;
					z->sum = DirectFunctionCall1(int8_numeric,
												 Int64GetDatum(col->sum));
				}

				if (col->hasMinMax)
				{
					StringInfoData mn;
					StringInfoData mx;

					initStringInfo(&mn);
					initStringInfo(&mx);
					ColumnarEncodeValue(&mn, att, col->minValue);
					ColumnarEncodeValue(&mx, att, col->maxValue);
					z->hasMinMax = true;
					z->minimum = mn.data;
					z->minimumLen = (uint32) mn.len;
					z->maximum = mx.data;
					z->maximumLen = (uint32) mx.len;

					/* fold into the whole-chunk min/max via the btree cmp proc */
					if (!chunkHasMinMax)
					{
						chunkMin = col->minValue;
						chunkMax = col->maxValue;
						chunkHasMinMax = true;
					}
					else
					{
						if (DatumGetInt32(FunctionCall2Coll(&def->cmpFn,
															def->collation,
															col->minValue,
															chunkMin)) < 0)
							chunkMin = col->minValue;
						if (DatumGetInt32(FunctionCall2Coll(&def->cmpFn,
															def->collation,
															col->maxValue,
															chunkMax)) > 0)
							chunkMax = col->maxValue;
					}
				}

				chunkValueCount += col->valueCount;
				chunkSum += col->sum;
				zoneRows = lappend(zoneRows, z);
			}
			vec++;
		}

		/*
		 * E3b: trailing chunk-shared FSST table region (descriptor version 2).
		 * sharedTableLen is 0 when the chunk has no shared table; FSST vectors
		 * above reference this one table instead of embedding their own.
		 */
		appendBinaryStringInfo(desc, (char *) &fsstTableLen, sizeof(uint32));
		if (fsstTableLen > 0)
			appendBinaryStringInfo(desc, fsstTable, fsstTableLen);

		/* whole-chunk zone map (vector_index -1) */
		{
			NativeZoneMapMetadata *z = palloc0(sizeof(NativeZoneMapMetadata));

			z->storageId = writeState->storageId;
			z->groupNumber = groupNumber;
			z->columnIndex = c;
			z->vectorIndex = -1;
			z->valueCount = chunkValueCount;
			z->nullCount = rowCount - chunkValueCount;

			if (def->summableInt && chunkValueCount > 0)
			{
				z->hasSum = true;
				z->sum = DirectFunctionCall1(int8_numeric,
											 Int64GetDatum(chunkSum));
			}

			if (chunkHasMinMax)
			{
				StringInfoData mn;
				StringInfoData mx;

				initStringInfo(&mn);
				initStringInfo(&mx);
				ColumnarEncodeValue(&mn, att, chunkMin);
				ColumnarEncodeValue(&mx, att, chunkMax);
				z->hasMinMax = true;
				z->minimum = mn.data;
				z->minimumLen = (uint32) mn.len;
				z->maximum = mx.data;
				z->maximumLen = (uint32) mx.len;
			}

			zoneRows = lappend(zoneRows, z);
		}

		/* per-column-chunk bloom over hashable values (native spec 7.2, D5b) */
		if (def->bloomable)
		{
			StringInfoData hashes;
			char	   *bloom;
			uint32		bloomLen;

			initStringInfo(&hashes);
			foreach(lc, writeState->chunkGroups)
			{
				ChunkGroupBuffer *group = (ChunkGroupBuffer *) lfirst(lc);
				ColumnChunkBuffer *col = &group->columns[c];

				if (col->hashBuf.len > 0)
					appendBinaryStringInfo(&hashes, col->hashBuf.data,
										   col->hashBuf.len);
			}
			if (hashes.len > 0 &&
				ColumnarBloomBuild((const uint32 *) hashes.data,
								   hashes.len / sizeof(uint32),
								   &bloom, &bloomLen))
			{
				NativeBloomMetadata *b = palloc0(sizeof(NativeBloomMetadata));

				b->storageId = writeState->storageId;
				b->groupNumber = groupNumber;
				b->columnIndex = c;
				b->filter = bloom;
				b->filterLen = bloomLen;
				bloomRows = lappend(bloomRows, b);
			}
		}

		/* optional block codec over the whole encoded region (spec 6) */
		finalData = encoded->data;
		finalLen = encoded->len;
		if (writeState->compressionType != COLUMNAR_COMPRESSION_NONE &&
			encoded->len > 0)
		{
			char	   *compData;
			uint32		compLen;
			int			usedType;
			int			usedLevel;

			ColumnarCompressValueStream(encoded->data, encoded->len,
										writeState->compressionType,
										writeState->compressionLevel,
										&compData, &compLen,
										&usedType, &usedLevel);
			if (usedType != COLUMNAR_COMPRESSION_NONE)
			{
				finalData = compData;
				finalLen = compLen;
				blockCodec = usedType;
			}
		}

		if (finalLen > 0)
			appendBinaryStringInfo(data, finalData, finalLen);

		chunkLength[c] = data->len - chunkOffset[c];
		chunkDescriptor[c] = desc->data;
		chunkDescriptorLen[c] = (uint32) desc->len;
		chunkBlockCodec[c] = blockCodec;
	}

	dataLength = data->len;

	rel = table_open(writeState->relid, RowExclusiveLock);

	/*
	 * Physical reclaim (Phase F): an online compaction (which holds
	 * ShareUpdateExclusiveLock and is self-serialized, so it is the only writer
	 * that can reuse space at a time) reserves from a previously freed range whose
	 * freeing transaction the oldest-xmin horizon has passed, instead of advancing
	 * the file highwater. Reuse is done here, before the relation extension lock,
	 * so the free_space catalog access is not under that lock. Plain inserts (which
	 * hold only RowExclusiveLock) always append, so they never race a reuse.
	 */
	reusedOffset = false;
	if (dataLength > 0 &&
		CheckRelationLockedByMe(rel, ShareUpdateExclusiveLock, false))
		reusedOffset = ColumnarAllocateFreeSpace(ColumnarStorageId(rel), dataLength,
												 ColumnarOldestXmin(rel), &fileOffset);

	LockRelationForExtension(rel, ExclusiveLock);
	if (!reusedOffset)
		ColumnarReserveOffset(rel, dataLength, &fileOffset);
	if (dataLength > 0)
		ColumnarWriteLogicalData(rel, fileOffset, data->data, dataLength);
	UnlockRelationForExtension(rel, ExclusiveLock);

	{
		NativeStorageMetadata s;

		s.storageId = writeState->storageId;
		s.relationOid = writeState->relid;
		s.formatVersion = COLUMNAR_NATIVE_VERSION_MAJOR;
		s.vectorLength = COLUMNAR_NATIVE_VECTOR_LENGTH;
		s.rowGroupLimit = writeState->stripeRowLimit;
		ColumnarInsertNativeStorageRow(&s);
	}
	{
		NativeRowGroupMetadata rg;

		rg.storageId = writeState->storageId;
		rg.groupNumber = groupNumber;
		rg.fileOffset = fileOffset;
		rg.rowCount = rowCount;
		rg.byteLength = dataLength;
		rg.firstRowNumber = writeState->stripeFirstRowNumber;
		ColumnarInsertRowGroupRow(&rg);
	}
	for (c = 0; c < natts; c++)
	{
		NativeColumnChunkMetadata cc;

		/* skipped virtual generated column (no chunk written) */
		if (chunkDescriptor[c] == NULL)
			continue;

		cc.storageId = writeState->storageId;
		cc.groupNumber = groupNumber;
		cc.columnIndex = c;
		cc.valueCount = rowCount;
		cc.encodingDescriptor = chunkDescriptor[c];
		cc.encodingDescriptorLen = chunkDescriptorLen[c];
		cc.blockCodec = chunkBlockCodec[c];
		cc.pageOffset = fileOffset + chunkOffset[c];
		cc.pageLength = chunkLength[c];
		ColumnarInsertColumnChunkRow(&cc);
	}
	foreach(lc, zoneRows)
		ColumnarInsertZoneMapRow((NativeZoneMapMetadata *) lfirst(lc));
	foreach(lc, bloomRows)
		ColumnarInsertBloomRow((NativeBloomMetadata *) lfirst(lc));

	table_close(rel, RowExclusiveLock);

	MemoryContextSwitchTo(oldContext);
	MemoryContextDelete(flushContext);

	/* reset accumulation; the next row reserves a fresh stripe id (row group) */
	MemoryContextReset(writeState->stripeContext);
	writeState->chunkGroups = NIL;
	writeState->currentGroup = NULL;
	writeState->stripeRowCount = 0;
	writeState->haveReservation = false;

	if (pushedSnapshot)
		PopActiveSnapshot();
}

/* -------------------------------------------------------------------------
 * projection write fan-out (gap 26, phase 2)
 *
 * Each additional projection of a table has its own storage id but shares the
 * table's relation file and row-number space. On insert, the projected columns
 * plus the base row number are buffered; at flush the batch is sorted on the
 * projection's sort key and written as a stripe to the projection's storage,
 * reusing the base stripe encoder (ColumnarWriteRow + columnar_flush_row_group).
 * The base row number is stored as a leading int8 column so the projection can
 * be joined back to the base; deletes/visibility come from the base delete_vector, so
 * only INSERT fans out (see design/gaps/26-IMPL-projections-phase2-plan.md).
 * ------------------------------------------------------------------------- */

/* one buffered projection row: [rownumber, projcol1..projcolK] */
typedef struct ProjRow
{
	Datum	   *values;
	bool	   *nulls;
} ProjRow;

typedef struct ColumnarProjWriter
{
	uint64		projStorageId;
	int			ncols;			/* number of projection columns (K) */
	AttrNumber *colAttnums;		/* table attnums of the K columns (1-based) */
	TupleDesc	projTupdesc;	/* [rownumber int8, projcol1..projcolK] */

	int			nsort;
	int		   *sortBufIdx;		/* index into a row's values[] for each sort col */
	FmgrInfo   *sortCmp;		/* btree cmp proc per sort col */
	Oid		   *sortColl;		/* collation per sort col */

	int			stripeRowLimit;
	int			chunkGroupRowLimit;
	int			compType;
	int			compLevel;

	ProjRow    *rows;			/* buffered rows (capacity stripeRowLimit) */
	int			nrows;
	MemoryContext ctx;			/* persists: struct arrays, projTupdesc */
	MemoryContext rowCtx;		/* reset after each stripe flush: row datums */
	ColumnarWriteState *innerWs;	/* reused stripe encoder for this projection */
} ColumnarProjWriter;
/*
 * ColumnarWriteStateProjStripeIds
 *		The stripe ids this write state's projection fan-out drew (#345).
 *
 *		A projection writes through its own inner write state but reserves from
 *		the BASE relation's stripe counter, because ColumnarWriteRow is called
 *		with the base relation (see flush_proj_writer). Its groups are recorded
 *		under the projection's own storage id, so they never appear in the base
 *		relation's row group list.
 *
 *		That combination is why the caller needs these separately. To
 *		record_online_sorted_extent, an id drawn by its own projection fan-out is
 *		indistinguishable from one taken by another session: both leave a gap in
 *		the base write state's ids. Treating the former as foreign truncated the
 *		ordered run at the first projection flush, so a fully reclustered table
 *		with a projection reported almost all of itself as decayed.
 *
 *		Returns a palloc'd array in the caller's context, or NULL when this write
 *		state has no projection writers.
 */
uint64 *
ColumnarWriteStateProjStripeIds(ColumnarWriteState *ws, int *n)
{
	ListCell   *lc;
	uint64	   *ids = NULL;
	int			total = 0;
	int			k = 0;

	*n = 0;
	if (ws->projWriters == NIL)
		return NULL;

	foreach(lc, ws->projWriters)
	{
		ColumnarProjWriter *w = (ColumnarProjWriter *) lfirst(lc);

		if (w->innerWs != NULL)
			total += w->innerWs->nReservedStripeIds;
	}
	if (total == 0)
		return NULL;

	ids = (uint64 *) palloc(sizeof(uint64) * total);
	foreach(lc, ws->projWriters)
	{
		ColumnarProjWriter *w = (ColumnarProjWriter *) lfirst(lc);
		int			i;

		if (w->innerWs == NULL)
			continue;
		for (i = 0; i < w->innerWs->nReservedStripeIds; i++)
			ids[k++] = w->innerWs->reservedStripeIds[i];
	}
	*n = k;
	return ids;
}


/*
 * columnar_build_write_state
 *		Allocate a standalone stripe encoder for the given tuple descriptor and
 *		storage id, not registered in ColumnarWriteStates. Used for a
 *		projection's inner writer; carries the same per-chunk min/max and bloom
 *		skip metadata as the base writer so a sorted projection gives tight
 *		min/max ranges for the planner (gap 26).
 */
static ColumnarWriteState *
columnar_build_write_state(Oid relid, TupleDesc srcTupdesc, uint64 storageId,
						   int stripeRowLimit, int chunkGroupRowLimit,
						   int compType, int compLevel)
{
	MemoryContext oldContext;
	ColumnarWriteState *ws;

	if (ColumnarWriteContext == NULL)
		ColumnarWriteContext = AllocSetContextCreate(TopTransactionContext,
													 "columnar write",
													 ALLOCSET_DEFAULT_SIZES);
	oldContext = MemoryContextSwitchTo(ColumnarWriteContext);

	ws = palloc0(sizeof(ColumnarWriteState));
	ws->relid = relid;
	ws->subid = GetCurrentSubTransactionId();
	ws->tupdesc = CreateTupleDescCopy(srcTupdesc);
	ws->natts = ws->tupdesc->natts;
	ws->stripeRowLimit = stripeRowLimit;
	ws->chunkGroupRowLimit = chunkGroupRowLimit;
	ws->compressionType = compType;
	ws->compressionLevel = compLevel;

	/*
	 * A projection is written under the same bloom decision as its base
	 * relation. Leaving this unset would zero it, silently dropping bloom
	 * filters from projections while the setting was on.
	 */
	ws->bloomEnabled = columnar_enable_bloom_filter;

	/*
	 * And under the same encode_effort as its base, for the same reason: a
	 * projection written at a different effort from the table it projects would
	 * make the setting mean something different depending on which copy you read.
	 */
	ws->encodeEffort = COLUMNAR_ENCODE_EFFORT_FULL;
	{
		ColumnarOptions opts;

		if (ColumnarReadOptions(relid, &opts) && opts.encodeEffortSet)
			ws->encodeEffort = opts.encodeEffort;
	}
	ws->storageId = storageId;
	columnar_init_col_defs(ws);	/* min/max + bloom skip metadata for projections */
	ws->stripeContext = AllocSetContextCreate(ColumnarWriteContext,
											  "columnar proj stripe",
											  ALLOCSET_DEFAULT_SIZES);
	ws->writeContext = ColumnarWriteContext;
	ws->chunkGroups = NIL;
	ws->currentGroup = NULL;
	ws->stripeRowCount = 0;
	ws->haveReservation = false;

	MemoryContextSwitchTo(oldContext);
	return ws;
}

/* qsort_arg comparator: ascending, NULLS LAST, over the projection sort key */
static int
proj_row_cmp(const void *a, const void *b, void *arg)
{
	const ProjRow *ra = (const ProjRow *) a;
	const ProjRow *rb = (const ProjRow *) b;
	ColumnarProjWriter *w = (ColumnarProjWriter *) arg;
	int			i;

	for (i = 0; i < w->nsort; i++)
	{
		int			idx = w->sortBufIdx[i];
		bool		na = ra->nulls[idx];
		bool		nb = rb->nulls[idx];
		int32		c;

		if (na && nb)
			continue;
		if (na)
			return 1;			/* nulls last */
		if (nb)
			return -1;
		c = DatumGetInt32(FunctionCall2Coll(&w->sortCmp[i], w->sortColl[i],
											ra->values[idx], rb->values[idx]));
		if (c != 0)
			return c;
	}
	return 0;
}

/*
 * flush_proj_writer
 *		Sort the buffered rows on the projection's sort key and write them as one
 *		stripe to the projection's storage, then reset the buffer.
 */
static void
flush_proj_writer(ColumnarProjWriter *w, Relation tableRel)
{
	int			i;

	if (w->nrows == 0)
		return;

	if (w->nsort > 0)
		qsort_arg(w->rows, w->nrows, sizeof(ProjRow), proj_row_cmp, w);

	if (w->innerWs == NULL)
		w->innerWs = columnar_build_write_state(RelationGetRelid(tableRel),
												w->projTupdesc, w->projStorageId,
												w->stripeRowLimit,
												w->chunkGroupRowLimit,
												w->compType, w->compLevel);

	for (i = 0; i < w->nrows; i++)
		ColumnarWriteRow(w->innerWs, tableRel, w->rows[i].values, w->rows[i].nulls);

	if (w->innerWs->stripeRowCount > 0)
		columnar_flush_row_group(w->innerWs);

	MemoryContextReset(w->rowCtx);
	w->nrows = 0;
}

/*
 * build_proj_writer
 *		Construct a ColumnarProjWriter for one projection catalog row.
 */
static ColumnarProjWriter *
build_proj_writer(Relation rel, const ColumnarProjection *proj,
				  int stripeRowLimit, int chunkGroupRowLimit,
				  int compType, int compLevel)
{
	TupleDesc	tableDesc = RelationGetDescr(rel);
	MemoryContext ctx;
	MemoryContext oldContext;
	ColumnarProjWriter *w;
	int			i;

	ctx = AllocSetContextCreate(ColumnarWriteContext, "columnar proj writer",
								ALLOCSET_DEFAULT_SIZES);
	oldContext = MemoryContextSwitchTo(ctx);

	w = palloc0(sizeof(ColumnarProjWriter));
	w->projStorageId = proj->projStorageId;
	w->ncols = proj->columnsLen;
	w->stripeRowLimit = stripeRowLimit;
	w->chunkGroupRowLimit = chunkGroupRowLimit;
	w->compType = compType;
	w->compLevel = compLevel;
	w->ctx = ctx;
	w->rowCtx = AllocSetContextCreate(ctx, "columnar proj rows",
									  ALLOCSET_DEFAULT_SIZES);
	w->rows = palloc0(sizeof(ProjRow) * stripeRowLimit);
	w->nrows = 0;
	w->innerWs = NULL;

	w->colAttnums = palloc(sizeof(AttrNumber) * w->ncols);
	for (i = 0; i < w->ncols; i++)
		w->colAttnums[i] = (AttrNumber) proj->columns[i];

	/* synthetic tuple descriptor: rownumber int8, then the projection columns */
	w->projTupdesc = CreateTemplateTupleDesc(w->ncols + 1);
	TupleDescInitEntry(w->projTupdesc, 1, "rownumber", INT8OID, -1, 0);
	for (i = 0; i < w->ncols; i++)
		TupleDescCopyEntry(w->projTupdesc, i + 2, tableDesc, w->colAttnums[i]);

	/* sort-key comparators; each sort attnum is one of the projection columns */
	w->nsort = proj->sortKeyLen;
	if (w->nsort > 0)
	{
		w->sortBufIdx = palloc(sizeof(int) * w->nsort);
		w->sortCmp = palloc(sizeof(FmgrInfo) * w->nsort);
		w->sortColl = palloc(sizeof(Oid) * w->nsort);
		for (i = 0; i < w->nsort; i++)
		{
			int16		attno = proj->sortKey[i];
			Form_pg_attribute att = TupleDescAttr(tableDesc, attno - 1);
			TypeCacheEntry *tce;
			int			p;

			/* position of this sort column within the projection's columns */
			w->sortBufIdx[i] = -1;
			for (p = 0; p < w->ncols; p++)
				if (w->colAttnums[p] == attno)
				{
					w->sortBufIdx[i] = p + 1;	/* +1 for the leading rownumber */
					break;
				}
			if (w->sortBufIdx[i] < 0)
				elog(ERROR, "columnar: sort column not in projection columns");

			tce = lookup_type_cache(att->atttypid, TYPECACHE_CMP_PROC_FINFO);
			if (!OidIsValid(tce->cmp_proc_finfo.fn_oid))
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("cannot sort projection on column of type %s",
								format_type_be(att->atttypid))));
			fmgr_info_copy(&w->sortCmp[i], &tce->cmp_proc_finfo, ctx);
			w->sortColl[i] = att->attcollation;
		}
	}

	MemoryContextSwitchTo(oldContext);
	return w;
}

/*
 * append_proj_row
 *		Buffer one row (the base row number plus the projection's columns) into a
 *		projection writer, flushing a stripe when the buffer fills. Shared by the
 *		insert fan-out and the add-projection back-fill.
 */
static void
append_proj_row(ColumnarProjWriter *w, Relation rel, TupleDesc tableDesc,
				uint64 rowNumber, Datum *values, bool *nulls)
{
	MemoryContext oldContext = MemoryContextSwitchTo(w->rowCtx);
	ProjRow    *r = &w->rows[w->nrows];
	int			i;

	r->values = palloc(sizeof(Datum) * (w->ncols + 1));
	r->nulls = palloc(sizeof(bool) * (w->ncols + 1));
	r->values[0] = Int64GetDatum((int64) rowNumber);
	r->nulls[0] = false;
	for (i = 0; i < w->ncols; i++)
	{
		AttrNumber	a = w->colAttnums[i];
		Form_pg_attribute att = TupleDescAttr(tableDesc, a - 1);

		if (nulls[a - 1])
		{
			r->nulls[i + 1] = true;
			r->values[i + 1] = (Datum) 0;
		}
		else
		{
			r->nulls[i + 1] = false;
			r->values[i + 1] = datumCopy(values[a - 1], att->attbyval,
										 att->attlen);
		}
	}
	w->nrows++;
	MemoryContextSwitchTo(oldContext);

	if (w->nrows >= w->stripeRowLimit)
		flush_proj_writer(w, rel);
}

/*
 * ColumnarProjectionFanoutRow
 *		Buffer a freshly inserted row into each additional projection of the
 *		relation. rowNumber is the base row number returned by ColumnarWriteRow.
 *		The projection writers hang off the base write state, so they share its
 *		(relid, subid) lifecycle.
 */
void
ColumnarProjectionFanoutRow(Relation rel, ColumnarWriteState *baseWs,
							uint64 rowNumber, Datum *values, bool *nulls)
{
	TupleDesc	tableDesc = RelationGetDescr(rel);
	ListCell   *lc;

	if (!baseWs->projInited)
	{
		List	   *projs = ColumnarListProjections(baseWs->storageId);
		MemoryContext oldContext = MemoryContextSwitchTo(ColumnarWriteContext);
		ListCell   *pc;

		foreach(pc, projs)
		{
			ColumnarProjection *p = (ColumnarProjection *) lfirst(pc);

			if (p->projectionId == 0)
				continue;		/* base projection is the table itself */
			baseWs->projWriters =
				lappend(baseWs->projWriters,
						build_proj_writer(rel, p, baseWs->stripeRowLimit,
										  baseWs->chunkGroupRowLimit,
										  baseWs->compressionType,
										  baseWs->compressionLevel));
		}
		baseWs->projInited = true;
		MemoryContextSwitchTo(oldContext);
	}

	if (baseWs->projWriters == NIL)
		return;

	foreach(lc, baseWs->projWriters)
		append_proj_row((ColumnarProjWriter *) lfirst(lc), rel, tableDesc,
						rowNumber, values, nulls);
}

/*
 * ColumnarBackfillProjection
 *		Populate a newly declared projection from the table's existing live rows
 *		(gap 26): scan the base and buffer-sort-flush each row into the
 *		projection's storage. Called by add_projection so a projection added to a
 *		populated table is complete. The caller must hold a lock that blocks
 *		concurrent writers (ShareLock) so no row is missed.
 */
void
ColumnarBackfillProjection(Relation rel, const ColumnarProjection *proj)
{
	TupleDesc	tableDesc = RelationGetDescr(rel);
	Oid			relid = RelationGetRelid(rel);
	int			stripeRowLimit = columnar_stripe_row_limit;
	int			chunkGroupRowLimit = columnar_chunk_group_row_limit;
	int			compType = columnar_compression;
	int			compLevel = columnar_compression_level;
	ColumnarOptions opts;
	ColumnarProjWriter *w;
	ColumnarReadState *readState;
	Snapshot	snapshot;
	Datum	   *values;
	bool	   *nulls;
	uint64		rowNumber;

	if (ColumnarWriteContext == NULL)
		ColumnarWriteContext = AllocSetContextCreate(TopTransactionContext,
													 "columnar write",
													 ALLOCSET_DEFAULT_SIZES);

	if (ColumnarReadOptions(relid, &opts))
	{
		if (opts.stripeRowLimitSet)
			stripeRowLimit = opts.stripeRowLimit;
		if (opts.chunkGroupRowLimitSet)
			chunkGroupRowLimit = opts.chunkGroupRowLimit;
		if (opts.compressionSet)
			compType = opts.compressionType;
		if (opts.compressionLevelSet)
			compLevel = opts.compressionLevel;
	}

	/* flush any pending base writes so the scan sees this transaction's rows */
	ColumnarFlushWriteStateForRelation(relid);
	ColumnarFlushDeleteVectorForRelation(rel);

	w = build_proj_writer(rel, proj, stripeRowLimit, chunkGroupRowLimit,
						  compType, compLevel);

	snapshot = ActiveSnapshotSet() ? GetActiveSnapshot() : GetTransactionSnapshot();
	values = palloc(sizeof(Datum) * tableDesc->natts);
	nulls = palloc(sizeof(bool) * tableDesc->natts);

	readState = ColumnarBeginRead(rel, snapshot, NULL, NULL, 0, NULL);
	while (ColumnarReadNextRow(readState, values, nulls, &rowNumber))
		append_proj_row(w, rel, tableDesc, rowNumber, values, nulls);
	ColumnarEndRead(readState);

	flush_proj_writer(w, rel);
}

/* Flush all projection writers hanging off a base write state. */
static void
flush_ws_projections(ColumnarWriteState *ws)
{
	ListCell   *lc;
	Relation	rel;
	bool		any = false;

	foreach(lc, ws->projWriters)
		if (((ColumnarProjWriter *) lfirst(lc))->nrows > 0)
			any = true;
	if (!any)
		return;

	rel = table_open(ws->relid, RowExclusiveLock);
	foreach(lc, ws->projWriters)
		flush_proj_writer((ColumnarProjWriter *) lfirst(lc), rel);
	table_close(rel, RowExclusiveLock);
}

/*
 * ColumnarFlushWriteStateForRelation
 *		Flush any pending partial stripe for a single relation. Used at scan
 *		start so data written earlier in this transaction is persisted.
 */
void
ColumnarFlushWriteStateForRelation(Oid relid)
{
	ListCell   *lc;

	foreach(lc, ColumnarWriteStates)
	{
		ColumnarWriteState *writeState = (ColumnarWriteState *) lfirst(lc);

		if (writeState->relid != relid)
			continue;
		if (writeState->stripeRowCount > 0)
			columnar_flush_row_group(writeState);
		flush_ws_projections(writeState);
	}
}

/*
 * ColumnarForgetWriteStateForRelation
 *		Drop the cached write state for a relation without flushing it. Used
 *		after the relation's storage is swapped (columnar.vacuum): the cached
 *		state holds the old storage id, so it must be discarded and a fresh one
 *		created for the new storage. The caller must have flushed first if any
 *		buffered rows still needed persisting.
 */
void
ColumnarForgetWriteStateForRelation(Oid relid)
{
	List	   *kept = NIL;
	ListCell   *lc;
	MemoryContext oldContext;

	if (ColumnarWriteStates == NIL)
		return;

	oldContext = MemoryContextSwitchTo(ColumnarWriteContext);
	foreach(lc, ColumnarWriteStates)
	{
		ColumnarWriteState *writeState = (ColumnarWriteState *) lfirst(lc);

		if (writeState->relid != relid)
			kept = lappend(kept, writeState);
	}
	MemoryContextSwitchTo(oldContext);

	ColumnarWriteStates = kept;
}

/*
 * ColumnarFlushAllPendingWrites
 *		Flush every pending write state. Called at transaction pre-commit.
 */
void
ColumnarFlushAllPendingWrites(void)
{
	ListCell   *lc;

	foreach(lc, ColumnarWriteStates)
	{
		ColumnarWriteState *writeState = (ColumnarWriteState *) lfirst(lc);

		columnar_flush_row_group(writeState);
		flush_ws_projections(writeState);
	}
}

/*
 * ColumnarDiscardAllPendingWrites
 *		Forget all pending write states. The backing memory is freed with the
 *		transaction context, so we only clear our static references.
 */
void
ColumnarDiscardAllPendingWrites(void)
{
	ColumnarWriteStates = NIL;
	ColumnarWriteContext = NULL;
}

/*
 * ColumnarWriteStateDiscardSubXact
 *		Drop buffered (unflushed) writes made in an aborting subtransaction.
 *		Stripes already flushed by that subtransaction are made invisible by
 *		the subtransaction abort itself (their catalog rows), so only the
 *		in-memory buffers need discarding here (spec 9).
 */
void
ColumnarWriteStateDiscardSubXact(SubTransactionId subid)
{
	List	   *kept = NIL;
	ListCell   *lc;
	MemoryContext oldContext;

	if (ColumnarWriteStates == NIL)
		return;

	oldContext = MemoryContextSwitchTo(ColumnarWriteContext);
	foreach(lc, ColumnarWriteStates)
	{
		ColumnarWriteState *writeState = (ColumnarWriteState *) lfirst(lc);

		if (writeState->subid != subid)
			kept = lappend(kept, writeState);
	}
	MemoryContextSwitchTo(oldContext);

	ColumnarWriteStates = kept;
}

/*
 * ColumnarWriteStatePromoteSubXact
 *		On subtransaction commit, reassign its buffered writes to the parent so
 *		they are flushed when the parent (eventually the top transaction)
 *		commits.
 */
void
ColumnarWriteStatePromoteSubXact(SubTransactionId subid, SubTransactionId parent)
{
	ListCell   *lc;

	foreach(lc, ColumnarWriteStates)
	{
		ColumnarWriteState *writeState = (ColumnarWriteState *) lfirst(lc);

		if (writeState->subid == subid)
			writeState->subid = parent;
	}
}
