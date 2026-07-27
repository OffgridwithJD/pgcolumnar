/*-------------------------------------------------------------------------
 *
 * columnar_tableam.c
 *		Table access method handler for pgColumnar and extension glue:
 *		GUCs, the pre-commit flush hook, and drop-time metadata cleanup.
 *
 * Implements the subset of TableAmRoutine built through phase 3: create, bulk
 * insert, sequential scan, delete and update via the delete vector, fetch by tid,
 * size estimation, and non-transactional truncate. Index, vacuum, and sample
 * callbacks are stubbed for later phases.
 *
 *-------------------------------------------------------------------------
 */
#include "columnar.h"

#include "access/multixact.h"
#include "access/relation.h"
#include "access/relscan.h"
#include "access/xact.h"
#include "catalog/index.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_class.h"
#include "catalog/storage.h"
#include "commands/defrem.h"
#include "commands/vacuum.h"
#include "executor/executor.h"
#include "executor/tuptable.h"
#include "miscadmin.h"
#include "nodes/pathnodes.h"
#include "optimizer/pathnode.h"
#include "optimizer/plancat.h"
#include "port/atomics.h"
#include "storage/bufmgr.h"
#if PG_VERSION_NUM >= 170000
/* the read-stream ANALYZE rework landed in PG17, and so did this header */
#include "storage/read_stream.h"
#endif
#include "storage/lmgr.h"
#include "storage/smgr.h"
#include "storage/spin.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

PG_MODULE_MAGIC;

/* GUC-backed instance defaults (spec 8.3) */
int			columnar_stripe_row_limit = 150000;
int			columnar_chunk_group_row_limit = 10000;
int			columnar_encoding_sample_rows = 2048;

int			columnar_compression = COLUMNAR_COMPRESSION_ZSTD;
int			columnar_compression_level = 3;
bool		columnar_enable_qual_pushdown = true;
bool		columnar_enable_bloom_filter = true;

/* value set for columnar.compression (spec 5, 8.3) */
static const struct config_enum_entry columnar_compression_options[] = {
	{"none", COLUMNAR_COMPRESSION_NONE, false},
	{"pglz", COLUMNAR_COMPRESSION_PGLZ, false},
	{"lz4", COLUMNAR_COMPRESSION_LZ4, false},
	{"zstd", COLUMNAR_COMPRESSION_ZSTD, false},
	{NULL, 0, false}
};

/* forward declaration of the AM routine so hooks can compare against it */
static const TableAmRoutine columnar_am_methods;

static object_access_hook_type prev_object_access_hook = NULL;
static ExecutorEnd_hook_type prev_executor_end_hook = NULL;
#if PG_VERSION_NUM >= 190000
static build_simple_rel_hook_type prev_build_simple_rel_hook = NULL;
#else
static get_relation_info_hook_type prev_get_relation_info_hook = NULL;
#endif

/* cached OID of the "columnar" table access method (index-only-scan hook) */
static Oid	columnar_am_oid_cache = InvalidOid;

/* our scan descriptor wraps the base scan and the reader state */
/*
 * ANALYZE sampling state (issue #154).
 *
 * The scan_analyze_next_block contract is block-oriented: core's block sampler
 * picks physical blocks, hands one to the AM at a time, and the AM offers the
 * rows on it. A columnar block holds encoded column bytes rather than rows, so
 * the rows "on" it have to be defined rather than read off it.
 *
 * Defining a block as a whole row group would be cluster sampling. A table sorted
 * or Z-ordered on a key holds a narrow slice of that key per group, so whole-group
 * sampling underestimates n_distinct and skews the MCV list -- and does so worst
 * on the tables pgcolumnar.vacuum_sorted and Z-ordering work hardest to produce.
 * Confidently wrong statistics are worse than none.
 *
 * Instead a block maps to the *slice* of its row group that the block's position
 * within that group represents: a group of R rows spanning K blocks is cut into K
 * equal row slices, and block j of the group offers slice j. That keeps the heap
 * analogue exact -- a sampled block offers its own rows and no others, so core's
 * liverows-per-block scaling stays honest -- while spreading the sample across the
 * whole of every group core touches, which is what defeats the clustering trap.
 * A row is offered by exactly one block, so no row can be sampled twice.
 */
typedef struct ColumnarAnalyzeState
{
	List	   *rowGroups;		/* NativeRowGroupMetadata *, in row order */
	Snapshot	metaSnapshot;
	MemoryContext cx;

	/* the slice the current block maps to; sliceRows == 0 means "no rows here" */
	uint64		sliceFirstRow;
	uint64		sliceRows;
	uint64		sliceNext;		/* next offset within the slice */
	uint64		sliceGroup;		/* the row group the slice belongs to */

	Datum	   *values;
	bool	   *nulls;

	/*
	 * A forward reader over the group the current slice belongs to.
	 *
	 * The rows a slice offers are a contiguous run of row numbers, slices within
	 * a group are visited in ascending order, and groups likewise, so one
	 * forward scan per group serves every slice in it. Fetching each row by
	 * number instead -- which this did first -- re-reads the row group list from
	 * the catalog and re-locates the row on every call, and ANALYZE offers every
	 * row of every block core samples: 250,000 fetches on a 250,000-row table,
	 * which ran for over 200 seconds and did not improve when the statistics
	 * target was lowered, because the work is per row offered rather than per row
	 * kept.
	 */
	ColumnarReadState *rs;		/* NULL until the first slice with rows */
	uint64		rsGroup;		/* group number rs is restricted to */
	bool		rsHavePending;	/* pendingRow/values hold an unconsumed row */
	uint64		pendingRow;
	Datum	   *pendingValues;
	bool	   *pendingNulls;
} ColumnarAnalyzeState;

typedef struct ColumnarScanDescData
{
	TableScanDescData rs_base;
	ColumnarReadState *readState;

	/*
	 * The context the scan descriptor itself was allocated in. The read state
	 * is built on the first getnextslot, where the current context is usually a
	 * per-tuple one that is reset before the scan ends, so it is allocated here
	 * instead and outlives the row that triggered it.
	 */
	MemoryContext scanContext;
	ColumnarAnalyzeState *analyzeState;
} ColumnarScanDescData;
typedef struct ColumnarScanDescData *ColumnarScanDesc;

PG_FUNCTION_INFO_V1(columnar_handler);

/* -------------------------------------------------------------------------
 * slot / scan callbacks
 * ------------------------------------------------------------------------- */

/*
 * Slot operations for a columnar relation (issue #154).
 *
 * These are TTSOpsVirtual with one callback replaced. A virtual slot's
 * copy_heap_tuple is heap_form_tuple over the slot's values, which leaves the
 * new tuple's t_self invalid and never looks at tts_tid -- the slot's item
 * pointer is simply dropped on the way out.
 *
 * That is fatal for ANALYZE rather than merely lossy. acquire_sample_rows
 * collects the sample with ExecCopySlotHeapTuple and then sorts it by item
 * pointer, and ItemPointerGetBlockNumber asserts the pointer is valid, so an
 * assert-enabled backend dies on the sort:
 *
 *     TRAP: failed Assert("ItemPointerIsValid(pointer)"), itemptr.h:105
 *
 * On a non-assert build the same invalid pointers are read as garbage and the
 * sample is sorted into an arbitrary order, which is the silent form of it: the
 * correlation statistic is then computed over rows in no particular order and
 * comes out as noise.
 *
 * Carrying tts_tid into t_self fixes both, and costs nothing on the scan path
 * because copy_heap_tuple is not on it -- a scan stores values into the slot and
 * the executor reads them from there.
 *
 * The slot is no longer "virtual" by TTS_IS_VIRTUAL, which is a pointer identity
 * test against TTSOpsVirtual. That is safe here: nothing in core requires it,
 * the paths that check it fall back to the general case, and the one that would
 * error -- tts_virtual_getsomeattrs -- is unreachable because
 * ExecStoreVirtualTuple sets tts_nvalid to the full attribute count, so
 * slot_getsomeattrs never calls it. The full suite is run on an assert-enabled
 * build to keep that reasoning honest.
 */
static TupleTableSlotOps ColumnarSlotOps;

/*
 * A slot that can defer its decode (issue #157).
 *
 * An index fetch used to reconstruct every column of the row before returning,
 * because a virtual slot holds values and nothing else. On a wide table that is
 * ruinous: the decoded row group exceeds the fetch cache's size cap, the entry is
 * dropped after every fetch, and each row re-reads and re-decodes the whole
 * group. Measured at 41 columns, 2,000 index fetches reading one column took
 * about seventeen minutes.
 *
 * The executor never tells the access method which columns it will read, so there
 * is no projection to pass down. But it does ask, through slot_getsomeattrs, and
 * it asks for the smallest prefix it needs. So the slot carries the row's address
 * instead of its values, and decodes when asked.
 *
 * Only the index fetch defers. Everything else stores values eagerly with
 * ExecStoreVirtualTuple, which sets tts_nvalid to the full count, so getsomeattrs
 * is never reached for those and their behaviour is unchanged.
 */
typedef struct ColumnarSlot
{
	/*
	 * VirtualTupleTableSlot, not TupleTableSlot, and it must come first. Every
	 * callback inherited from TTSOpsVirtual casts the slot to its own type and
	 * uses the `data` pointer that follows the base: tts_virtual_materialize
	 * writes it and tts_virtual_clear pfrees it. Deriving from TupleTableSlot
	 * puts our own first field exactly where `data` belongs, so materialising a
	 * slot would scribble on it and clearing one would free it.
	 */
	VirtualTupleTableSlot vslot;

	/* set when the slot holds a row's address rather than its values */
	bool		deferred;
	Relation	rel;
	Snapshot	snapshot;
	uint64		rowNumber;
} ColumnarSlot;

/*
 * The fields above must sit past everything the inherited callbacks touch. If
 * VirtualTupleTableSlot ever grows, this fails to compile rather than silently
 * aliasing.
 */
StaticAssertDecl(offsetof(ColumnarSlot, deferred) >= sizeof(VirtualTupleTableSlot),
				 "ColumnarSlot fields must not overlap VirtualTupleTableSlot");

/*
 * columnar_slot_decode_upto
 *		Materialise attributes 0 .. natts-1 of a deferred slot.
 *
 *		Decodes a prefix because that is what slot_getsomeattrs asks for, and the
 *		executor asks for the largest attribute number it needs. A query reading
 *		column 2 of 41 decodes two columns, not forty-one.
 */
static void
columnar_slot_decode_upto(TupleTableSlot *slot, int natts)
{
	ColumnarSlot *cslot = (ColumnarSlot *) slot;
	Bitmapset  *needed = NULL;
	int			i;

	Assert(cslot->deferred);

	for (i = 0; i < natts; i++)
		needed = bms_add_member(needed, i);

	/*
	 * Visibility was settled when the slot was filled, so this cannot fail for a
	 * row that was live then. It can still miss a row held only in an unflushed
	 * write buffer, which is where the buffered reader comes in; that path
	 * reconstructs the whole row, which is correct if not lazy, and it is bounded
	 * by what one transaction has buffered.
	 */
	if (!ColumnarReadRowByNumberCols(cslot->rel, cslot->snapshot,
									 cslot->rowNumber, slot->tts_values,
									 slot->tts_isnull, needed))
		(void) ColumnarBufferedRowByNumber(cslot->rel, cslot->rowNumber,
										   slot->tts_values, slot->tts_isnull);

	bms_free(needed);

	/*
	 * Attributes past the prefix hold nothing meaningful yet. tts_nvalid is what
	 * tells the executor how far it may read, so leaving them is correct, but a
	 * later call asking for more has to decode again from the start rather than
	 * assume the earlier ones are still there -- which they are, so it does not.
	 */
	slot->tts_nvalid = natts;
}

static void
columnar_slot_getsomeattrs(TupleTableSlot *slot, int natts)
{
	ColumnarSlot *cslot = (ColumnarSlot *) slot;

	if (!cslot->deferred)
	{
		/*
		 * A slot filled eagerly has tts_nvalid at the full count already, so
		 * nothing should reach here. Erroring matches the virtual slot this
		 * otherwise behaves as, rather than silently returning junk.
		 */
		elog(ERROR, "getsomeattrs on a columnar slot that was filled eagerly");
	}

	columnar_slot_decode_upto(slot, natts);
}

/*
 * Anything that wants the row whole -- materialising, copying, forming a tuple
 * -- has to finish the decode first.
 */
static void
columnar_slot_force_full(TupleTableSlot *slot)
{
	ColumnarSlot *cslot;

	/*
	 * Callers hand us slots that are not ours. copyslot in particular takes a
	 * source of any type -- the executor copies an ordinary virtual slot into a
	 * columnar one on every INSERT -- and casting that to ColumnarSlot reads
	 * past the end of it, so the deferred flag is whatever happened to be in
	 * the next word and the relation pointer behind it is garbage. That is a
	 * segfault on the plainest INSERT there is, which is how it was found.
	 */
	if (slot->tts_ops != &ColumnarSlotOps)
		return;

	cslot = (ColumnarSlot *) slot;
	if (cslot->deferred && slot->tts_nvalid < slot->tts_tupleDescriptor->natts)
		columnar_slot_decode_upto(slot, slot->tts_tupleDescriptor->natts);
}

/*
 * The added fields have to start out cleared: a slot that is never used for a
 * deferred fetch still has them read, and MakeTupleTableSlot does not know they
 * are there.
 */
static void
columnar_slot_init(TupleTableSlot *slot)
{
	ColumnarSlot *cslot = (ColumnarSlot *) slot;

	TTSOpsVirtual.init(slot);
	cslot->deferred = false;
	cslot->rel = NULL;
	cslot->snapshot = NULL;
	cslot->rowNumber = 0;
}

static void
columnar_slot_clear(TupleTableSlot *slot)
{
	ColumnarSlot *cslot = (ColumnarSlot *) slot;

	Assert(slot->tts_ops == &ColumnarSlotOps);
	cslot->deferred = false;
	cslot->rel = NULL;
	cslot->snapshot = NULL;
	cslot->rowNumber = 0;
	TTSOpsVirtual.clear(slot);
}

static void
columnar_slot_materialize(TupleTableSlot *slot)
{
	columnar_slot_force_full(slot);
	TTSOpsVirtual.materialize(slot);
}

static void
columnar_slot_copyslot(TupleTableSlot *dstslot, TupleTableSlot *srcslot)
{
	columnar_slot_force_full(srcslot);
	TTSOpsVirtual.copyslot(dstslot, srcslot);
}

static MinimalTuple
columnar_slot_copy_minimal_tuple(COLUMNAR_COPY_MINIMAL_TUPLE_ARGS)
{
	columnar_slot_force_full(slot);
	return TTSOpsVirtual.copy_minimal_tuple
		COLUMNAR_COPY_MINIMAL_TUPLE_FWD(slot);
}

/*
 * ColumnarSlotStoreDeferred
 *		Point the slot at a row without decoding it. The caller has already
 *		established that the row is visible.
 */
static void
ColumnarSlotStoreDeferred(TupleTableSlot *slot, Relation rel,
						  Snapshot snapshot, uint64 rowNumber)
{
	ColumnarSlot *cslot = (ColumnarSlot *) slot;

	ExecClearTuple(slot);
	cslot->deferred = true;
	cslot->rel = rel;
	cslot->snapshot = snapshot;
	cslot->rowNumber = rowNumber;

	slot->tts_flags &= ~TTS_FLAG_EMPTY;
	slot->tts_nvalid = 0;
}

static HeapTuple
columnar_slot_copy_heap_tuple(TupleTableSlot *slot)
{
	HeapTuple	tuple;

	Assert(!TTS_EMPTY(slot));

	columnar_slot_force_full(slot);

	tuple = heap_form_tuple(slot->tts_tupleDescriptor,
							slot->tts_values, slot->tts_isnull);
	tuple->t_self = slot->tts_tid;
	tuple->t_tableOid = slot->tts_tableOid;

	return tuple;
}

static const TupleTableSlotOps *
columnar_slot_callbacks(Relation relation)
{
	return &ColumnarSlotOps;
}

static TableScanDesc
columnar_scan_begin(Relation rel, Snapshot snapshot, int nkeys,
					ScanKey key, ParallelTableScanDesc pscan, uint32 flags)
{
	ColumnarScanDesc scan;

	RelationIncrementReferenceCount(rel);

	/*
	 * Persist any data and delete marks written earlier in this transaction so
	 * they reach the catalog before this scan reads it. The reader consults the
	 * catalog with a command-id-advanced snapshot (ColumnarCatalogSnapshot), so
	 * these become visible to this same scan: same-transaction read-your-writes
	 * (spec 9).
	 */
	ColumnarFlushWriteStateForRelation(RelationGetRelid(rel));
	ColumnarFlushDeleteVectorForRelation(rel);

	scan = (ColumnarScanDesc) palloc0(sizeof(ColumnarScanDescData));
	scan->rs_base.rs_rd = rel;
	scan->rs_base.rs_snapshot = snapshot;
	scan->rs_base.rs_nkeys = nkeys;
	scan->rs_base.rs_flags = flags;
	scan->rs_base.rs_parallel = pscan;

	/*
	 * The read state is built on the first getnextslot, not here, because the
	 * shape to decode against arrives with the slot and is not always the
	 * relation's current one.
	 *
	 * ALTER TABLE ... ALTER COLUMN TYPE is where they differ (#178). Phase 2 of
	 * ATRewriteTable has already updated pg_attribute when phase 3 scans the old
	 * relation, so RelationGetDescr(rel) describes the new types while the bytes
	 * on disk are still the old ones. Core hands the scan a slot built from
	 * tab->oldDesc for exactly that reason; decoding against the relation
	 * instead read 4-byte values as 8-byte ones and worse.
	 *
	 * For every other scan the slot's descriptor is the relation's, so this
	 * costs a branch and changes nothing.
	 *
	 * Phase 2 projects all columns for a plain sequential scan (there is no
	 * per-scan projection channel in the table AM without the custom scan of
	 * a later phase), so we pass a NULL projection set. Any ScanKeys the
	 * executor supplies are forwarded for chunk-group skipping.
	 */
	scan->rs_base.rs_key = key;
	scan->readState = NULL;
	scan->scanContext = CurrentMemoryContext;

	return (TableScanDesc) scan;
}

/*
 * columnar_scan_read_state
 *		The scan's reader, built on first use against the descriptor the caller
 *		is asking for.
 *
 * Deferring it is what lets a rewrite decode against tab->oldDesc (#178). It
 * also means no caller may assume scan->readState is already set: the parallel
 * index build reads it straight off the scan without ever going through
 * getnextslot, and dereferenced NULL the first time this was written that way.
 * Everything that wants the reader comes through here.
 *
 * The read state is allocated in the context the scan descriptor itself lives
 * in. The current context on first use is usually a per-tuple one that is reset
 * before the scan ends, and ColumnarEndRead then frees an already-freed pointer.
 */
static ColumnarReadState *
columnar_scan_read_state(ColumnarScanDesc scan, TupleDesc tupdesc)
{
	if (scan->readState == NULL)
	{
		MemoryContext oldContext = MemoryContextSwitchTo(scan->scanContext);

		scan->readState =
			ColumnarBeginReadWithStorage(scan->rs_base.rs_rd,
										 scan->rs_base.rs_snapshot,
										 ColumnarStorageId(scan->rs_base.rs_rd),
										 tupdesc,
										 scan->rs_base.rs_parallel, NULL,
										 scan->rs_base.rs_nkeys,
										 scan->rs_base.rs_key);
		MemoryContextSwitchTo(oldContext);
	}

	return scan->readState;
}

static void
columnar_scan_end(TableScanDesc sscan)
{
	ColumnarScanDesc scan = (ColumnarScanDesc) sscan;

	if (scan->readState != NULL)
		ColumnarEndRead(scan->readState);

	if (scan->analyzeState != NULL)
	{
		if (scan->analyzeState->rs != NULL)
			ColumnarEndRead(scan->analyzeState->rs);
		MemoryContextDelete(scan->analyzeState->cx);
	}

	/* release a snapshot restored+registered for a parallel worker */
	if (scan->rs_base.rs_flags & SO_TEMP_SNAPSHOT)
		UnregisterSnapshot(scan->rs_base.rs_snapshot);

	RelationDecrementReferenceCount(scan->rs_base.rs_rd);
	pfree(scan);
}

static void
columnar_scan_rescan(TableScanDesc sscan, ScanKey key, bool set_params,
					 bool allow_strat, bool allow_sync, bool allow_pagemode)
{
	ColumnarScanDesc scan = (ColumnarScanDesc) sscan;

	if (scan->readState != NULL)
		ColumnarRescanRead(scan->readState);
}

static bool
columnar_scan_getnextslot(TableScanDesc sscan, ScanDirection direction,
						  TupleTableSlot *slot)
{
	ColumnarScanDesc scan = (ColumnarScanDesc) sscan;
	uint64		rowNumber;

	ExecClearTuple(slot);

	if (!ColumnarReadNextRow(columnar_scan_read_state(scan,
													 slot->tts_tupleDescriptor),
							 slot->tts_values, slot->tts_isnull, &rowNumber))
		return false;

	ExecStoreVirtualTuple(slot);
	ColumnarRowNumberToItemPointer(rowNumber, &slot->tts_tid);
	slot->tts_tableOid = RelationGetRelid(scan->rs_base.rs_rd);

	return true;
}

/* -------------------------------------------------------------------------
 * parallel scan: single-worker claim (see columnar_reader.c)
 * ------------------------------------------------------------------------- */

static Size
columnar_parallelscan_estimate(Relation rel)
{
	return sizeof(ParallelBlockTableScanDescData);
}

static Size
columnar_parallelscan_initialize(Relation rel, ParallelTableScanDesc pscan)
{
	ParallelBlockTableScanDesc bpscan = (ParallelBlockTableScanDesc) pscan;

	memset(bpscan, 0, sizeof(ParallelBlockTableScanDescData));
	COLUMNAR_PARALLELSCAN_SET_REL(bpscan, rel);
	bpscan->phs_nblocks = 0;
	SpinLockInit(&bpscan->phs_mutex);
	bpscan->phs_startblock = InvalidBlockNumber;
	pg_atomic_init_u64(&bpscan->phs_nallocated, 0);

	return sizeof(ParallelBlockTableScanDescData);
}

static void
columnar_parallelscan_reinitialize(Relation rel, ParallelTableScanDesc pscan)
{
	ParallelBlockTableScanDesc bpscan = (ParallelBlockTableScanDesc) pscan;

	pg_atomic_write_u64(&bpscan->phs_nallocated, 0);
}

/* -------------------------------------------------------------------------
 * insert callbacks
 * ------------------------------------------------------------------------- */

static void
columnar_tuple_insert(Relation rel, TupleTableSlot *slot, CommandId cid,
					  COLUMNAR_TABLE_OPTIONS options,
					  struct BulkInsertStateData *bistate)
{
	ColumnarWriteState *writeState = ColumnarGetWriteState(rel);
	uint64		rowNumber;

	slot_getallattrs(slot);

	/*
	 * Serialize concurrent inserters of the same unique key (issue #5) before
	 * the executor runs its btree uniqueness check on this row, so the check
	 * runs only after any conflicting transaction has committed and flushed.
	 */
	ColumnarLockUniqueKeys(rel, slot);

	rowNumber = ColumnarWriteRow(writeState, rel, slot->tts_values,
								 slot->tts_isnull);

	/* fan the row out to every additional projection of this table (gap 26) */
	ColumnarProjectionFanoutRow(rel, writeState, rowNumber, slot->tts_values,
								slot->tts_isnull);

	/*
	 * A new row makes its block not all-visible; clear any VM bit so an
	 * index-only scan never skips the fetch for a block that just changed
	 * (gap 28). A no-op unless a prior vacuum had marked the block visible.
	 */
	ColumnarVMClearForRow(rel, rowNumber);

	/*
	 * Publish the row's synthetic item pointer (spec 6) so the executor can
	 * insert correct (index value, TID) entries into any indexes on this
	 * relation and enforce unique constraints (spec 9).
	 */
	ColumnarRowNumberToItemPointer(rowNumber, &slot->tts_tid);
	slot->tts_tableOid = RelationGetRelid(rel);
}

static void
columnar_multi_insert(Relation rel, TupleTableSlot **slots, int nslots,
					  CommandId cid, COLUMNAR_TABLE_OPTIONS options,
					  struct BulkInsertStateData *bistate)
{
	ColumnarWriteState *writeState = ColumnarGetWriteState(rel);
	int			i;

	for (i = 0; i < nslots; i++)
	{
		uint64		rowNumber;

		slot_getallattrs(slots[i]);
		ColumnarLockUniqueKeys(rel, slots[i]);	/* issue #5 */
		rowNumber = ColumnarWriteRow(writeState, rel, slots[i]->tts_values,
									 slots[i]->tts_isnull);
		ColumnarProjectionFanoutRow(rel, writeState, rowNumber,
									slots[i]->tts_values, slots[i]->tts_isnull);
		ColumnarVMClearForRow(rel, rowNumber);	/* gap 28: block changed */
		ColumnarRowNumberToItemPointer(rowNumber, &slots[i]->tts_tid);
		slots[i]->tts_tableOid = RelationGetRelid(rel);
	}
}

static void
columnar_finish_bulk_insert(Relation rel, COLUMNAR_TABLE_OPTIONS options)
{
	/*
	 * End of a bulk-load path (COPY, CREATE TABLE AS, ALTER TABLE rewrite).
	 * Flush now, under this operation's subtransaction, so the buffer never
	 * spans a later statement or savepoint boundary (spec 9).
	 */
	ColumnarFlushWriteStateForRelation(RelationGetRelid(rel));
	ColumnarFlushDeleteVectorForRelation(rel);
}

/* -------------------------------------------------------------------------
 * DDL callbacks
 * ------------------------------------------------------------------------- */

static void
columnar_relation_set_new_filelocator(Relation rel,
									  const RelFileLocator *newrlocator,
									  char persistence,
									  TransactionId *freezeXid,
									  MultiXactId *minmulti)
{
	SMgrRelation srel;
	uint64		storageId;

	*freezeXid = InvalidTransactionId;
	*minmulti = InvalidMultiXactId;

	if (persistence == RELPERSISTENCE_UNLOGGED)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("unlogged columnar tables are not supported")));

	srel = ColumnarRelationCreateStorage(*newrlocator, persistence);
	storageId = ColumnarNextStorageId();
	ColumnarWriteNewMetapage(newrlocator, srel, persistence, storageId);
}

static void
columnar_relation_nontransactional_truncate(Relation rel)
{
	uint64		storageId = ColumnarStorageId(rel);

	ColumnarDeleteMetadata(storageId);
	RelationTruncate(rel, 2);
	ColumnarResetMetapage(rel);
}

/* -------------------------------------------------------------------------
 * miscellaneous callbacks
 * ------------------------------------------------------------------------- */

static uint64
columnar_relation_size(Relation rel, ForkNumber forkNumber)
{
	SMgrRelation srel = RelationGetSmgr(rel);

	/*
	 * Compute size from smgr directly. We must not call
	 * RelationGetNumberOfBlocksInFork here: for a table AM it dispatches back
	 * into this very callback.
	 */
	if (forkNumber != MAIN_FORKNUM && !smgrexists(srel, forkNumber))
		return 0;

	return (uint64) smgrnblocks(srel, forkNumber) * BLCKSZ;
}

static bool
columnar_relation_needs_toast_table(Relation rel)
{
	/* the writer detoasts and stores values inline in the value stream */
	return false;
}

static void
columnar_relation_estimate_size(Relation rel, int32 *attr_widths,
								BlockNumber *pages, double *tuples,
								double *allvisfrac)
{
	BlockNumber nblocks = RelationGetNumberOfBlocks(rel);
	uint64		storageId = ColumnarStorageId(rel);
	Snapshot	snapshot;
	List	   *rowGroupList;
	ListCell   *lc;
	double		liveRows = 0;

	/*
	 * Estimate the row count from row-group metadata, not from the metapage
	 * reservation high-water mark: row numbers are reserved a whole row group at
	 * a time, so the reservation overcounts. An accurate estimate keeps the
	 * planner from mis-costing scans (spec 6, 9).
	 */
	snapshot = ActiveSnapshotSet() ? GetActiveSnapshot() : GetTransactionSnapshot();
	rowGroupList = ColumnarReadRowGroupList(storageId, ColumnarCatalogSnapshot(snapshot));

	foreach(lc, rowGroupList)
		liveRows += (double) ((NativeRowGroupMetadata *) lfirst(lc))->rowCount;

	*pages = Max(nblocks, 1);
	*tuples = Max(liveRows, 0);
	*allvisfrac = 0.0;
}

/*
 * columnar_analyze_state
 *		The sampling state for this scan, built on first use. The row group list
 *		is read once: ANALYZE holds ShareUpdateExclusiveLock, so no group is added
 *		or retired under us, and re-reading it per block would put a catalog scan
 *		in the middle of the sample loop.
 */
static ColumnarAnalyzeState *
columnar_analyze_state(ColumnarScanDesc scan)
{
	ColumnarAnalyzeState *st = scan->analyzeState;
	Relation	rel = scan->rs_base.rs_rd;
	MemoryContext oldContext;

	if (st != NULL)
		return st;

	st = palloc0(sizeof(ColumnarAnalyzeState));
	st->cx = AllocSetContextCreate(CurrentMemoryContext, "columnar analyze",
								   ALLOCSET_DEFAULT_SIZES);
	oldContext = MemoryContextSwitchTo(st->cx);
	st->metaSnapshot = ColumnarCatalogSnapshot(scan->rs_base.rs_snapshot);
	st->rowGroups = ColumnarReadRowGroupList(ColumnarStorageId(rel),
											 st->metaSnapshot);
	st->values = palloc(sizeof(Datum) * RelationGetDescr(rel)->natts);
	st->nulls = palloc(sizeof(bool) * RelationGetDescr(rel)->natts);
	st->pendingValues = palloc(sizeof(Datum) * RelationGetDescr(rel)->natts);
	st->pendingNulls = palloc(sizeof(bool) * RelationGetDescr(rel)->natts);
	MemoryContextSwitchTo(oldContext);

	scan->analyzeState = st;
	return st;
}

/*
 * columnar_analyze_set_slice
 *		Point the sampler at the rows a physical block stands for.
 *
 *		The block's logical byte offset locates the row group it falls in; its
 *		position within that group's byte range gives the slice ordinal, and the
 *		group's rows are cut into as many equal slices as it spans blocks. A block
 *		that lands outside every group -- the metapage, or space reserved but not
 *		yet written -- yields an empty slice, which is the columnar equivalent of
 *		sampling an empty heap page and is reported the same way: the block counts
 *		as visited and offers nothing.
 */
static void
columnar_analyze_set_slice(ColumnarAnalyzeState *st, BlockNumber blockno)
{
	uint64		logicalOffset;
	ListCell   *lc;

	st->sliceFirstRow = 0;
	st->sliceRows = 0;
	st->sliceNext = 0;

	/* blocks 0 and 1 are the metapage and its reserve; no logical data there */
	if ((uint64) blockno * COLUMNAR_BYTES_PER_PAGE < COLUMNAR_FIRST_LOGICAL_OFFSET)
		return;

	logicalOffset = (uint64) blockno * COLUMNAR_BYTES_PER_PAGE -
		COLUMNAR_FIRST_LOGICAL_OFFSET;

	foreach(lc, st->rowGroups)
	{
		NativeRowGroupMetadata *rg = (NativeRowGroupMetadata *) lfirst(lc);
		uint64		span;
		uint64		nblocks;
		uint64		slice;
		uint64		firstOff;
		uint64		endOff;

		if (rg->rowCount == 0)
			continue;
		if (logicalOffset < rg->fileOffset)
			continue;

		/*
		 * A group's footprint is its data length rounded up to a page, so the
		 * blocks it owns are exactly those its rounded span covers. Using the
		 * unrounded length would leave the last block of every group unmatched
		 * and its slice of rows unreachable.
		 */
		span = COLUMNAR_PAGE_ROUND_UP(rg->byteLength);
		if (logicalOffset >= rg->fileOffset + span)
			continue;

		nblocks = span / COLUMNAR_BYTES_PER_PAGE;
		if (nblocks == 0)
			nblocks = 1;
		slice = (logicalOffset - rg->fileOffset) / COLUMNAR_BYTES_PER_PAGE;
		if (slice >= nblocks)
			slice = nblocks - 1;

		/*
		 * Cut the group's rows into nblocks slices. Computing both edges from the
		 * same expression makes the slices exactly partition the group however the
		 * division rounds, so every row belongs to one block and none to two.
		 */
		firstOff = (rg->rowCount * slice) / nblocks;
		endOff = (rg->rowCount * (slice + 1)) / nblocks;

		st->sliceFirstRow = rg->firstRowNumber + firstOff;
		st->sliceRows = endOff - firstOff;
		st->sliceNext = 0;
		st->sliceGroup = rg->groupNumber;
		return;
	}
}

/*
 * The block comes from a read stream from PG17 and as a plain BlockNumber
 * before that. columnar_compat.h supplies the parameter list and splits at the
 * same major; these two must agree, and when they did not, PG17 took the
 * pre-17 branch and failed to compile on a `blockno` its signature does not
 * have.
 */
#if PG_VERSION_NUM >= 170000
static bool
columnar_scan_analyze_next_block(COLUMNAR_ANALYZE_NEXT_BLOCK_ARGS)
{
	ColumnarScanDesc cscan = (ColumnarScanDesc) scan;
	ColumnarAnalyzeState *st = columnar_analyze_state(cscan);
	Buffer		buf = read_stream_next_buffer(stream, NULL);

	if (!BufferIsValid(buf))
		return false;

	/*
	 * The stream chose the block; the buffer's contents are of no use here,
	 * because a columnar block holds encoded column bytes and the rows it stands
	 * for are read through the fetch path instead. Release the pin at once rather
	 * than holding it across the tuple loop as heap does.
	 */
	columnar_analyze_set_slice(st, BufferGetBlockNumber(buf));
	ReleaseBuffer(buf);
	return true;
}
#else
static bool
columnar_scan_analyze_next_block(COLUMNAR_ANALYZE_NEXT_BLOCK_ARGS)
{
	ColumnarScanDesc cscan = (ColumnarScanDesc) scan;

	columnar_analyze_set_slice(columnar_analyze_state(cscan), blockno);
	return true;
}
#endif

static bool
columnar_scan_analyze_next_tuple(COLUMNAR_ANALYZE_NEXT_TUPLE_ARGS)
{
	ColumnarScanDesc cscan = (ColumnarScanDesc) scan;
	ColumnarAnalyzeState *st = columnar_analyze_state(cscan);
	Relation	rel = scan->rs_rd;
	TupleDesc	tupdesc = RelationGetDescr(rel);
	uint64		sliceEnd = st->sliceFirstRow + st->sliceRows;
	int			i;

	if (st->sliceRows == 0)
		return false;

	/* a slice in a new group needs a reader positioned on that group */
	if (st->rs == NULL || st->rsGroup != st->sliceGroup)
	{
		MemoryContext oldContext = MemoryContextSwitchTo(st->cx);

		if (st->rs != NULL)
			ColumnarEndRead(st->rs);
		st->rs = ColumnarBeginRead(rel, scan->rs_snapshot, NULL, NULL, 0, NULL);
		ColumnarReadRestrictToGroups(st->rs, &st->sliceGroup, 1);
		st->rsGroup = st->sliceGroup;
		st->rsHavePending = false;
		MemoryContextSwitchTo(oldContext);
	}

	for (;;)
	{
		uint64		rowNumber;

		CHECK_FOR_INTERRUPTS();

		if (st->rsHavePending)
		{
			rowNumber = st->pendingRow;
			st->rsHavePending = false;
			memcpy(st->values, st->pendingValues,
				   sizeof(Datum) * tupdesc->natts);
			memcpy(st->nulls, st->pendingNulls, sizeof(bool) * tupdesc->natts);
		}
		else if (!ColumnarReadNextRow(st->rs, st->values, st->nulls, &rowNumber))
		{
			/*
			 * The group is exhausted. Any rows of this slice not returned were
			 * removed by the delete vector, which the reader applies for us.
			 */
			*deadrows += (double) (sliceEnd - st->sliceFirstRow - st->sliceNext);
			st->sliceNext = st->sliceRows;
			return false;
		}

		/* rows before the slice belong to a block core has already visited */
		if (rowNumber < st->sliceFirstRow)
			continue;

		if (rowNumber >= sliceEnd)
		{
			/*
			 * Past the slice. Hold the row for the next one rather than losing
			 * it: the reader only goes forward, and re-reading the group per
			 * slice is what this design exists to avoid.
			 */
			memcpy(st->pendingValues, st->values, sizeof(Datum) * tupdesc->natts);
			memcpy(st->pendingNulls, st->nulls, sizeof(bool) * tupdesc->natts);
			st->pendingRow = rowNumber;
			st->rsHavePending = true;
			*deadrows += (double) (sliceEnd - st->sliceFirstRow - st->sliceNext);
			st->sliceNext = st->sliceRows;
			return false;
		}

		/*
		 * Rows the reader skipped between the last one and this are deleted; the
		 * live-row estimate core computes needs them counted, not merely left
		 * out of the sample.
		 */
		*deadrows += (double) (rowNumber - st->sliceFirstRow - st->sliceNext);
		st->sliceNext = rowNumber - st->sliceFirstRow + 1;

		ExecClearTuple(slot);
		for (i = 0; i < tupdesc->natts; i++)
		{
			slot->tts_values[i] = st->values[i];
			slot->tts_isnull[i] = st->nulls[i];
		}
		ExecStoreVirtualTuple(slot);

		/*
		 * Give the row its synthetic address. ANALYZE sorts the collected sample
		 * by item pointer before computing statistics, and the row-number mapping
		 * is monotonic, so this is what makes the sorted order the physical order
		 * -- which in turn is what makes the correlation statistic mean anything.
		 */
		ColumnarRowNumberToItemPointer(rowNumber, &slot->tts_tid);

		*liverows += 1;
		return true;
	}
}

/* VACUUM: nothing to do in phase 1 (delete vector / compaction arrive later) */
static void
columnar_relation_vacuum(Relation rel, COLUMNAR_VACUUM_PARAMS params,
						 BufferAccessStrategy bstrategy)
{
	/*
	 * Lazy vacuum (gap 28 phase 3): mark all-visible chunk groups in the VM
	 * fork so index-only scans can skip the columnar fetch. This only reads
	 * committed state and writes the VM fork -- no data rewrite -- so it runs
	 * fine under the ShareUpdateExclusiveLock a plain VACUUM/autovacuum holds,
	 * concurrent with readers and writers. The space-reclaiming rewrite stays in
	 * columnar.vacuum (AccessExclusiveLock, the VACUUM-FULL analog).
	 */
	ColumnarVMSetVisibleForRelation(rel);

	/*
	 * Online compaction (Phase F3a): retire row groups that are fully deleted
	 * as-of the oldest-xmin horizon, dropping their metadata so scans skip them.
	 * This is also read-mostly on data (it only deletes catalog rows for groups
	 * every snapshot agrees are dead) and is safe under ShareUpdateExclusiveLock,
	 * so a plain VACUUM / autovacuum reclaims fully-deleted groups online without
	 * the AccessExclusiveLock rewrite.
	 */
	ColumnarRetireFullyDeletedGroups(rel);
}

/* -------------------------------------------------------------------------
 * not-yet-supported callbacks (later phases)
 * ------------------------------------------------------------------------- */

#define COLUMNAR_UNSUPPORTED(feature) \
	ereport(ERROR, \
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED), \
			 errmsg("columnar: %s is not supported yet", \
					feature)))

/* our index-fetch descriptor is just the base plus nothing extra */
typedef struct ColumnarIndexFetchData
{
	IndexFetchTableData xs_base;
} ColumnarIndexFetchData;

static struct IndexFetchTableData *
columnar_index_fetch_begin(COLUMNAR_INDEX_FETCH_BEGIN_ARGS)
{
	ColumnarIndexFetchData *scan = palloc0(sizeof(ColumnarIndexFetchData));

	scan->xs_base.rel = rel;
	return &scan->xs_base;
}

static void
columnar_index_fetch_reset(struct IndexFetchTableData *scan)
{
}

static void
columnar_index_fetch_end(struct IndexFetchTableData *scan)
{
	pfree(scan);
}

/*
 * columnar_index_fetch_tuple
 *		Fetch the columnar row addressed by an index item pointer (spec 6) into
 *		the slot. Returns false when the row is marked deleted in the delete vector
 *		or does not exist, so an index scan never returns a deleted row and a
 *		unique check does not treat a deleted row as a live duplicate (spec 9).
 *
 *		The row is looked up first in the flushed stripes, then in any unflushed
 *		write buffer for the relation. The latter lets a unique constraint catch
 *		two duplicate rows inserted within a single statement, where the first
 *		row's item pointer is fetched while both rows are still buffered. This
 *		function acquires no relation extension or metapage locks, so it is safe
 *		to call while the caller holds an index buffer lock (the uniqueness
 *		check path).
 */
static bool
columnar_index_fetch_tuple(struct IndexFetchTableData *scan, ItemPointer tid,
						   Snapshot snapshot, TupleTableSlot *slot,
						   bool *call_again, bool *all_dead)
{
	Relation	rel = scan->rel;
	uint64		rowNumber = ColumnarItemPointerToRowNumber(tid);

	/* columnar rows are 1:1 with item pointers: no chain, never dead here */
	*call_again = false;
	if (all_dead != NULL)
		*all_dead = false;

	ExecClearTuple(slot);

	/*
	 * Settle visibility without decoding anything, then hand the slot the row's
	 * address rather than its values (issue #157). The columns are decoded when
	 * the executor asks for them, and it asks for the smallest prefix it needs.
	 *
	 * A row that is not in the flushed stripes may still be in this
	 * transaction's write buffer, and that reader reconstructs whole rows, so it
	 * is stored eagerly.
	 */
	if (ColumnarRowIsLive(rel, snapshot, rowNumber))
		ColumnarSlotStoreDeferred(slot, rel, snapshot, rowNumber);
	else if (ColumnarBufferedRowByNumber(rel, rowNumber,
										 slot->tts_values, slot->tts_isnull))
		ExecStoreVirtualTuple(slot);
	else
		return false;

	ColumnarRowNumberToItemPointer(rowNumber, &slot->tts_tid);
	slot->tts_tableOid = RelationGetRelid(rel);

	return true;
}

/*
 * columnar_tuple_fetch_row_version
 *		Fetch the row addressed by tid into slot (spec 6). Used by UPDATE, which
 *		re-fetches the old row by its item pointer. Returns false when the row
 *		does not exist or is marked deleted.
 */
static bool
columnar_tuple_fetch_row_version(Relation rel, ItemPointer tid,
								 Snapshot snapshot, TupleTableSlot *slot)
{
	uint64		rowNumber = ColumnarItemPointerToRowNumber(tid);

	ExecClearTuple(slot);

	if (!ColumnarReadRowByNumber(rel, snapshot, rowNumber,
								 slot->tts_values, slot->tts_isnull))
		return false;

	ExecStoreVirtualTuple(slot);
	ColumnarRowNumberToItemPointer(rowNumber, &slot->tts_tid);
	slot->tts_tableOid = RelationGetRelid(rel);

	return true;
}

static bool
columnar_tuple_tid_valid(TableScanDesc scan, ItemPointer tid)
{
	return true;
}

static void
columnar_tuple_get_latest_tid(TableScanDesc scan, ItemPointer tid)
{
	COLUMNAR_UNSUPPORTED("get latest tid");
}

static bool
columnar_tuple_satisfies_snapshot(Relation rel, TupleTableSlot *slot,
								  Snapshot snapshot)
{
	/* stripes are visible per their metadata snapshot; slots are visible */
	return true;
}

/*
 * columnar_index_delete_tuples
 *		Opportunistic index tuple deletion. An index entry is deletable exactly
 *		when its row is no longer visible, i.e. ColumnarReadRowByNumber cannot
 *		return it (deleted via the delete vector). Reporting deletability by actual
 *		liveness is required for correctness: nbtree's deletion pass (including
 *		bottom-up deletion of duplicate keys, which a same-key UPDATE produces)
 *		marks candidate items and calls this callback as the authority; leaving a
 *		genuinely dead item marked non-deletable would make nbtree assert
 *		(ndeletable > 0 || nupdatable > 0). Entries left in place are still
 *		filtered on fetch, so either way is correct. The snapshot conflict horizon
 *		is reported as invalid (no conflict), matching the delete vector's own MVCC on
 *		the catalog.
 */
#if PG_VERSION_NUM < 140000
/*
 * PG13 spelling of the same policy: the callback is
 * compute_xid_horizon_for_tuples, which reports the snapshot conflict horizon
 * for a batch of index tuples the caller would like to remove. We never remove
 * index entries opportunistically, so an invalid (no-conflict) horizon is the
 * correct and always-safe answer.
 */
static TransactionId
columnar_compute_xid_horizon_for_tuples(Relation rel, ItemPointerData *tids,
										int nitems)
{
	return InvalidTransactionId;
}
#else
static TransactionId
columnar_index_delete_tuples(Relation rel, TM_IndexDeleteOp *delstate)
{
	Snapshot	snapshot = ActiveSnapshotSet() ? GetActiveSnapshot()
		: GetTransactionSnapshot();
	int			i;

	for (i = 0; i < delstate->ndeltids; i++)
	{
		uint64		rowNumber =
			ColumnarItemPointerToRowNumber(&delstate->deltids[i].tid);

		/*
		 * Only liveness matters here, and ColumnarRowIsLive decodes nothing to
		 * answer it. This used to reconstruct every column of the row and then
		 * free the result unread, once per candidate index tuple, on a path
		 * nbtree drives during deletion (issue #157).
		 */
		delstate->status[delstate->deltids[i].id].knowndeletable =
			!ColumnarRowIsLive(rel, snapshot, rowNumber);
	}

	return InvalidTransactionId;
}
#endif

static void
columnar_tuple_insert_speculative(Relation rel, TupleTableSlot *slot,
								  CommandId cid, COLUMNAR_TABLE_OPTIONS options,
								  struct BulkInsertStateData *bistate,
								  uint32 specToken)
{
	COLUMNAR_UNSUPPORTED("speculative insert");
}

static void
columnar_tuple_complete_speculative(Relation rel, TupleTableSlot *slot,
									uint32 specToken, bool succeeded)
{
	COLUMNAR_UNSUPPORTED("speculative insert");
}

/*
 * columnar_tuple_delete
 *		Mark the row addressed by tid as deleted in the delete vector (spec 9). The
 *		stripe is not rewritten. The tid is the synthetic item pointer the scan
 *		produced, which maps back to the row number.
 */
static TM_Result
columnar_tuple_delete(COLUMNAR_TUPLE_DELETE_ARGS)
{
	uint64		rowNumber = ColumnarItemPointerToRowNumber(tid);

	ColumnarMarkRowDeleted(rel, rowNumber);
	return TM_Ok;
}

/*
 * columnar_tuple_update
 *		Update is delete-plus-insert (spec 9): mark the old row deleted in the
 *		delete vector and append the new tuple as a fresh row with a new row number.
 *		The new row's item pointer is published on the slot and index
 *		maintenance is requested, so the new row gets fresh index entries. The
 *		old row's index entries remain but are filtered on fetch because the old
 *		row is now marked deleted (spec 6, 9).
 */
static TM_Result
columnar_tuple_update(COLUMNAR_TUPLE_UPDATE_ARGS)
{
	uint64		oldRowNumber = ColumnarItemPointerToRowNumber(otid);
	ColumnarWriteState *writeState;
	uint64		rowNumber;

	ColumnarMarkRowDeleted(rel, oldRowNumber);

	writeState = ColumnarGetWriteState(rel);
	slot_getallattrs(slot);

	/* the new row version is a fresh insert: serialize its unique keys too */
	ColumnarLockUniqueKeys(rel, slot);		/* issue #5 */

	rowNumber = ColumnarWriteRow(writeState, rel, slot->tts_values,
								 slot->tts_isnull);

	ColumnarRowNumberToItemPointer(rowNumber, &slot->tts_tid);
	slot->tts_tableOid = RelationGetRelid(rel);

	*lockmode = LockTupleExclusive;
	*update_indexes = COLUMNAR_TU_ALL;
	return TM_Ok;
}

static TM_Result
columnar_tuple_lock(Relation rel, ItemPointer tid, Snapshot snapshot,
					TupleTableSlot *slot, CommandId cid, LockTupleMode mode,
					LockWaitPolicy wait_policy, uint8 flags,
					TM_FailureData *tmfd)
{
	COLUMNAR_UNSUPPORTED("row locking");
	return TM_Ok;
}

static void
columnar_relation_copy_data(Relation rel, const RelFileLocator *newrlocator)
{
	COLUMNAR_UNSUPPORTED("relation copy (ALTER TABLE SET TABLESPACE)");
}

static void
columnar_relation_copy_for_cluster(COLUMNAR_COPY_FOR_CLUSTER_ARGS)
{
	COLUMNAR_UNSUPPORTED("CLUSTER / VACUUM FULL");
}

/*
 * columnar_index_build_range_scan
 *		Scan every live row of the columnar table and hand it to the index
 *		build callback, so CREATE INDEX (btree or hash) works over a columnar
 *		table (spec 9). Deleted rows (delete vector) are skipped by the reader, so
 *		they are not indexed. Each row's synthetic item pointer (spec 6) is the
 *		TID recorded in the index.
 *
 *		Only a full-table build is supported: a partial block range would have
 *		no meaning for synthetic item pointers, and concurrent validation uses a
 *		separate callback. Pending writes are flushed first so buffered rows are
 *		included in the build.
 */
static double
columnar_index_build_range_scan(Relation table_rel, Relation index_rel,
								struct IndexInfo *index_info, bool allow_sync,
								bool anyvisible, bool progress,
								BlockNumber start_blockno, BlockNumber numblocks,
								IndexBuildCallback callback, void *callback_state,
								TableScanDesc scan)
{
	ColumnarReadState *readState;
	bool		ownReadState;
	EState	   *estate;
	ExprContext *econtext;
	ExprState  *predicate;
	TupleTableSlot *slot;
	Datum		indexValues[INDEX_MAX_KEYS];
	bool		indexNulls[INDEX_MAX_KEYS];
	double		reltuples = 0;
	uint64		rowNumber;

	if (start_blockno != 0 || numblocks != InvalidBlockNumber)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("columnar: partial-range index build is not supported")));

	/* persist buffered rows and delete marks so the build sees them (spec 9) */
	ColumnarFlushWriteStateForRelation(RelationGetRelid(table_rel));
	ColumnarFlushDeleteVectorForRelation(table_rel);

	estate = CreateExecutorState();
	econtext = GetPerTupleExprContext(estate);
	slot = table_slot_create(table_rel, NULL);
	econtext->ecxt_scantuple = slot;

	/* a partial index only indexes rows satisfying its predicate */
	predicate = ExecPrepareQual(index_info->ii_Predicate, estate);

	/*
	 * Obtain the reader. A parallel index build passes the TableScanDesc it
	 * opened with table_beginscan_parallel; that scan already holds a reader
	 * bound to the shared parallel scan, whose single-participant claim (see
	 * columnar_read_start) makes exactly one participant read the whole table.
	 * We must read through that reader, not a private one: a private full-table
	 * reader in every participant would index every row once per participant,
	 * producing duplicate (key, TID) entries. When no scan is supplied (a serial
	 * build), open a private reader under an MVCC snapshot: the active snapshot
	 * when one is set (planning/DDL always has one), otherwise the transaction
	 * snapshot. The reader advances the command id internally for
	 * read-your-writes.
	 */
	if (scan != NULL)
	{
		/*
		 * An index build always wants the relation's current shape: it is
		 * indexing what the table is now, not what an in-flight rewrite is
		 * converting away from.
		 */
		readState = columnar_scan_read_state((ColumnarScanDesc) scan,
											 RelationGetDescr(table_rel));
		ownReadState = false;
	}
	else
	{
		Snapshot	snapshot;

		if (ActiveSnapshotSet())
			snapshot = GetActiveSnapshot();
		else
			snapshot = GetTransactionSnapshot();

		readState = ColumnarBeginRead(table_rel, snapshot, NULL, NULL, 0, NULL);
		ownReadState = true;
	}

	while (true)
	{
		CHECK_FOR_INTERRUPTS();

		ExecClearTuple(slot);
		if (!ColumnarReadNextRow(readState, slot->tts_values, slot->tts_isnull,
								 &rowNumber))
			break;
		ExecStoreVirtualTuple(slot);

		reltuples += 1;

		MemoryContextReset(econtext->ecxt_per_tuple_memory);

		if (predicate != NULL && !ExecQual(predicate, econtext))
			continue;

		FormIndexDatum(index_info, slot, estate, indexValues, indexNulls);

		ColumnarRowNumberToItemPointer(rowNumber, &slot->tts_tid);

		callback(index_rel, &slot->tts_tid, indexValues, indexNulls, true,
				 callback_state);
	}

	if (ownReadState)
		ColumnarEndRead(readState);
	ExecDropSingleTupleTableSlot(slot);
	FreeExecutorState(estate);

	/*
	 * The table AM contract makes index_build_range_scan the owner of a scan the
	 * caller supplied: it must end it, exactly as heapam_index_build_range_scan
	 * calls table_endscan on the passed scan whether or not it created the scan
	 * itself. columnar_scan_begin took a relation reference (and, for a worker,
	 * a registered snapshot) and created the reader used above; table_endscan
	 * runs columnar_scan_end, which ends that reader and releases the reference.
	 * Omitting this leaked one relation reference per build participant, which
	 * surfaced at commit as "resource was not closed: relation".
	 */
	if (scan != NULL)
		table_endscan(scan);

	return reltuples;
}

static void
columnar_index_validate_scan(Relation table_rel, Relation index_rel,
							 struct IndexInfo *index_info, Snapshot snapshot,
							 struct ValidateIndexState *state)
{
	COLUMNAR_UNSUPPORTED("concurrent index validate");
}

static bool
columnar_scan_sample_next_block(TableScanDesc scan,
								struct SampleScanState *scanstate)
{
	COLUMNAR_UNSUPPORTED("TABLESAMPLE");
	return false;
}

static bool
columnar_scan_sample_next_tuple(TableScanDesc scan,
								struct SampleScanState *scanstate,
								TupleTableSlot *slot)
{
	COLUMNAR_UNSUPPORTED("TABLESAMPLE");
	return false;
}

/* -------------------------------------------------------------------------
 * the routine
 * ------------------------------------------------------------------------- */

static const TableAmRoutine columnar_am_methods = {
	.type = T_TableAmRoutine,

	.slot_callbacks = columnar_slot_callbacks,

	.scan_begin = columnar_scan_begin,
	.scan_end = columnar_scan_end,
	.scan_rescan = columnar_scan_rescan,
	.scan_getnextslot = columnar_scan_getnextslot,

	.parallelscan_estimate = columnar_parallelscan_estimate,
	.parallelscan_initialize = columnar_parallelscan_initialize,
	.parallelscan_reinitialize = columnar_parallelscan_reinitialize,

	.index_fetch_begin = columnar_index_fetch_begin,
	.index_fetch_reset = columnar_index_fetch_reset,
	.index_fetch_end = columnar_index_fetch_end,
	.index_fetch_tuple = columnar_index_fetch_tuple,

	.tuple_fetch_row_version = columnar_tuple_fetch_row_version,
	.tuple_tid_valid = columnar_tuple_tid_valid,
	.tuple_get_latest_tid = columnar_tuple_get_latest_tid,
	.tuple_satisfies_snapshot = columnar_tuple_satisfies_snapshot,
#if PG_VERSION_NUM < 140000
	.COLUMNAR_AM_INDEX_DELETE_FIELD = columnar_compute_xid_horizon_for_tuples,
#else
	.COLUMNAR_AM_INDEX_DELETE_FIELD = columnar_index_delete_tuples,
#endif

	.tuple_insert = columnar_tuple_insert,
	.tuple_insert_speculative = columnar_tuple_insert_speculative,
	.tuple_complete_speculative = columnar_tuple_complete_speculative,
	.multi_insert = columnar_multi_insert,
	.tuple_delete = columnar_tuple_delete,
	.tuple_update = columnar_tuple_update,
	.tuple_lock = columnar_tuple_lock,
	.finish_bulk_insert = columnar_finish_bulk_insert,

	.COLUMNAR_AM_SET_NEW_FILE_FIELD = columnar_relation_set_new_filelocator,
	.relation_nontransactional_truncate = columnar_relation_nontransactional_truncate,
	.relation_copy_data = columnar_relation_copy_data,
	.relation_copy_for_cluster = columnar_relation_copy_for_cluster,
	.relation_vacuum = columnar_relation_vacuum,
	.scan_analyze_next_block = columnar_scan_analyze_next_block,
	.scan_analyze_next_tuple = columnar_scan_analyze_next_tuple,
	.index_build_range_scan = columnar_index_build_range_scan,
	.index_validate_scan = columnar_index_validate_scan,

	.relation_size = columnar_relation_size,
	.relation_needs_toast_table = columnar_relation_needs_toast_table,

	.relation_estimate_size = columnar_relation_estimate_size,

	.scan_sample_next_block = columnar_scan_sample_next_block,
	.scan_sample_next_tuple = columnar_scan_sample_next_tuple,
};

Datum
columnar_handler(PG_FUNCTION_ARGS)
{
	PG_RETURN_POINTER(&columnar_am_methods);
}

/* -------------------------------------------------------------------------
 * transaction callback: flush pending writes at pre-commit
 * ------------------------------------------------------------------------- */

static void
columnar_xact_callback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_PRE_COMMIT:
		case XACT_EVENT_PARALLEL_PRE_COMMIT:
		case XACT_EVENT_PREPARE:
			ColumnarFlushAllPendingWrites();
			ColumnarFlushAllDeleteVectors();
			break;
		case XACT_EVENT_COMMIT:
		case XACT_EVENT_ABORT:
		case XACT_EVENT_PARALLEL_COMMIT:
		case XACT_EVENT_PARALLEL_ABORT:
			ColumnarDiscardAllPendingWrites();
			ColumnarDiscardAllDeleteVectors();
			ColumnarDiscardFetchCache();
			break;
		default:
			break;
	}
}

/* -------------------------------------------------------------------------
 * subtransaction callback: discard or promote pending work of a savepoint
 * ------------------------------------------------------------------------- */

static void
columnar_subxact_callback(SubXactEvent event, SubTransactionId mySubid,
						  SubTransactionId parentSubid, void *arg)
{
	switch (event)
	{
		case SUBXACT_EVENT_ABORT_SUB:
			ColumnarWriteStateDiscardSubXact(mySubid);
			ColumnarDeleteVectorDiscardSubXact(mySubid);
			break;
		case SUBXACT_EVENT_COMMIT_SUB:
			ColumnarWriteStatePromoteSubXact(mySubid, parentSubid);
			ColumnarDeleteVectorPromoteSubXact(mySubid, parentSubid);
			break;
		default:
			break;
	}
}

/* -------------------------------------------------------------------------
 * executor end hook: flush pending writes at statement end
 *
 * INSERT/UPDATE/DELETE do not call finish_bulk_insert, so flush here at the
 * end of each executed statement. Flushing while the writing statement's
 * subtransaction is still current is what makes savepoint rollback correct:
 * a buffer written before a savepoint is persisted (and attributed) under the
 * outer subtransaction, so it survives a later ROLLBACK TO, while a buffer
 * written after the savepoint is attributed to the inner subtransaction and
 * is correctly discarded on its rollback (spec 9).
 * ------------------------------------------------------------------------- */

static void
columnar_executor_end(QueryDesc *queryDesc)
{
	if (prev_executor_end_hook)
		prev_executor_end_hook(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);

	ColumnarFlushAllPendingWrites();
	ColumnarFlushAllDeleteVectors();

	/*
	 * The fetch cache is scoped to a statement, so release it here rather than
	 * waiting for transaction end. Without this a statement that filled every
	 * slot pins them for the rest of the transaction, and a session sitting idle
	 * in transaction after one UPDATE holds them indefinitely.
	 */
	ColumnarDiscardFetchCache();
}

/* -------------------------------------------------------------------------
 * object access hook: clean up metadata when a columnar table is dropped
 * ------------------------------------------------------------------------- */

static void
columnar_object_access(ObjectAccessType access, Oid classId, Oid objectId,
					   int subId, void *arg)
{
	if (prev_object_access_hook)
		prev_object_access_hook(access, classId, objectId, subId, arg);

	if (access == OAT_DROP && classId == RelationRelationId && subId == 0)
	{
		Relation	rel;

		if (get_rel_relkind(objectId) != RELKIND_RELATION)
			return;

		/* DROP already holds AccessExclusiveLock on the relation */
		rel = relation_open(objectId, NoLock);

		if (rel->rd_tableam == &columnar_am_methods)
		{
			uint64		storageId = ColumnarStorageId(rel);

			ColumnarDeleteMetadata(storageId);
			ColumnarDeleteOptions(objectId);
		}

		relation_close(rel, NoLock);
	}
}

/* -------------------------------------------------------------------------
 * planner hook: forbid index-only scans on columnar tables
 *
 * A columnar table has no visibility map, so an index-only scan cannot decide
 * visibility from the map and is not supported (spec 9). An ordinary index scan
 * is fine because it fetches each row through index_fetch_tuple, which applies
 * the delete vector. We forbid index-only scans by clearing each candidate index's
 * per-column "can return" flags for a columnar table, before the planner builds
 * any path; the planner then builds a plain index scan instead of an index-only
 * scan for the same index.
 *
 * The clearing must happen after get_relation_info() has populated the base
 * relation's indexlist. Through PG18 that is get_relation_info_hook; PG19
 * removed it and added build_simple_rel_hook, which fires at the same point
 * (right after get_relation_info in build_simple_rel) for exactly this kind of
 * editorializing on the index list. Both routes yield an identical plan.
 * ------------------------------------------------------------------------- */

static bool
columnar_relation_is_columnar(Oid relid)
{
	if (columnar_am_oid_cache == InvalidOid)
		columnar_am_oid_cache = get_am_oid("pgcolumnar", true);

	return OidIsValid(columnar_am_oid_cache) &&
		get_rel_relam(relid) == columnar_am_oid_cache;
}

/* GUC: when on, allow the planner to build index-only-scan paths for columnar
 * tables, served by the VM fork (gap 28). Default on: the phase-5 MVCC,
 * concurrency, and crash-recovery suites prove the all-visible protocol (the
 * horizon accounts for open snapshots and every write clears the bit, both
 * WAL-logged), and a not-all-visible block always falls back to the
 * snapshot-checked fetch, so results are correct regardless. */
bool		columnar_enable_index_only_scan = true;

/* clear the "can return" flags of every index on a columnar relation */
static void
columnar_forbid_index_only_scan(Oid relid, RelOptInfo *rel)
{
	ListCell   *lc;

	/* when index-only scans are enabled, leave the index canreturn flags intact
	 * so the planner may choose an IOS; the VM fork (set by lazy vacuum) drives
	 * whether the executor skips the fetch, and a not-all-visible block still
	 * falls back to columnar_index_fetch_tuple, so results are always correct. */
	if (columnar_enable_index_only_scan)
		return;

	if (!OidIsValid(relid) || !columnar_relation_is_columnar(relid))
		return;

	foreach(lc, rel->indexlist)
	{
		IndexOptInfo *index = (IndexOptInfo *) lfirst(lc);
		int			i;

		if (index->canreturn == NULL)
			continue;

		for (i = 0; i < index->ncolumns; i++)
			index->canreturn[i] = false;
	}
}

#if PG_VERSION_NUM >= 190000
static void
columnar_build_simple_rel(PlannerInfo *root, RelOptInfo *rel,
						  RangeTblEntry *rte)
{
	if (prev_build_simple_rel_hook)
		prev_build_simple_rel_hook(root, rel, rte);

	if (rte->rtekind == RTE_RELATION)
		columnar_forbid_index_only_scan(rte->relid, rel);
}
#else
static void
columnar_get_relation_info(PlannerInfo *root, Oid relationObjectId,
						   bool inhparent, RelOptInfo *rel)
{
	if (prev_get_relation_info_hook)
		prev_get_relation_info_hook(root, relationObjectId, inhparent, rel);

	columnar_forbid_index_only_scan(relationObjectId, rel);
}
#endif

/* -------------------------------------------------------------------------
 * module init
 * ------------------------------------------------------------------------- */

void
_PG_init(void)
{
	/*
	 * Virtual slot behaviour, except that a copied heap tuple keeps the slot's
	 * item pointer. See the comment on columnar_slot_copy_heap_tuple.
	 */
	ColumnarSlotOps = TTSOpsVirtual;
	ColumnarSlotOps.base_slot_size = sizeof(ColumnarSlot);
	ColumnarSlotOps.copy_heap_tuple = columnar_slot_copy_heap_tuple;
	ColumnarSlotOps.init = columnar_slot_init;
	ColumnarSlotOps.getsomeattrs = columnar_slot_getsomeattrs;
	ColumnarSlotOps.clear = columnar_slot_clear;
	ColumnarSlotOps.materialize = columnar_slot_materialize;
	ColumnarSlotOps.copyslot = columnar_slot_copyslot;
	ColumnarSlotOps.copy_minimal_tuple = columnar_slot_copy_minimal_tuple;

	DefineCustomIntVariable("pgcolumnar.stripe_row_limit",
							"Maximum number of rows per stripe.",
							NULL,
							&columnar_stripe_row_limit,
							150000,
							1000, INT_MAX,
							PGC_USERSET,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("pgcolumnar.chunk_group_row_limit",
							"Maximum number of rows per chunk group.",
							NULL,
							&columnar_chunk_group_row_limit,
							10000,
							100, INT_MAX,
							PGC_USERSET,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("pgcolumnar.encoding_sample_rows",
							"Rows sampled to choose a chunk's value encoding.",
							"Candidate encodings are estimated on a windowed sample "
							"of this many values, and only the best two are applied "
							"to the whole vector. 0 applies every candidate to the "
							"whole vector, which is what earlier versions did. A "
							"value below 128 is treated as 0, because a sample that "
							"small cannot rank candidates: every candidate's fixed "
							"header would exceed the sample itself.",
							&columnar_encoding_sample_rows,
							2048,
							0, INT_MAX,
							PGC_USERSET,
							0,
							NULL, NULL, NULL);

	DefineCustomEnumVariable("pgcolumnar.compression",
							 "Default compression codec for new chunks.",
							 NULL,
							 &columnar_compression,
							 COLUMNAR_COMPRESSION_ZSTD,
							 columnar_compression_options,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("pgcolumnar.compression_level",
							"Compression level for the zstd codec.",
							NULL,
							&columnar_compression_level,
							3,
							1, 22,
							PGC_USERSET,
							0,
							NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.enable_qual_pushdown",
							 "Push scan qualifiers down for chunk-group skipping.",
							 NULL,
							 &columnar_enable_qual_pushdown,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.enable_custom_scan",
							 "Use the columnar custom scan path for columnar tables.",
							 NULL,
							 &columnar_enable_custom_scan,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.enable_vectorization",
							 "Use the vectorized aggregate fast path.",
							 NULL,
							 &columnar_enable_vectorization,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.enable_bloom_filter",
							 "Skip chunk groups on equality using per-chunk bloom filters.",
							 NULL,
							 &columnar_enable_bloom_filter,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.enable_column_cache",
							 "Cache decompressed chunk groups to reuse across reads.",
							 NULL,
							 &columnar_enable_column_cache,
							 false,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.reclaim_coalesce",
							 "Split oversized freed ranges on reuse and coalesce "
							 "adjacent freed ranges, so compaction reclaims space "
							 "under fragmentation. Off reverts to whole-range reuse.",
							 NULL,
							 &columnar_reclaim_coalesce,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.enable_end_truncation",
							 "Allow pgcolumnar.truncate() to physically return "
							 "trailing reclaimed blocks to the OS. Off (the default) "
							 "makes truncate() a no-op.",
							 NULL,
							 &columnar_enable_end_truncation,
							 false,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.enable_read_stream",
							 "Prefetch block reads with the read stream API (PostgreSQL 17+).",
							 NULL,
							 &columnar_enable_read_stream,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.enable_index_only_scan",
							 "Allow index-only scans on columnar tables, served by the "
							 "visibility-map fork (gap 28). On by default; set off to force "
							 "a plain index scan.",
							 NULL,
							 &columnar_enable_index_only_scan,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.enable_projection_scan",
							 "Let the planner scan a covering projection instead of the "
							 "base table when one serves the query better (gap 26).",
							 NULL,
							 &columnar_enable_projection_scan,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("pgcolumnar.column_cache_size",
							"Size of the decompressed-chunk cache, in megabytes.",
							NULL,
							&columnar_column_cache_size,
							200,
							1, INT_MAX,
							PGC_USERSET,
							GUC_UNIT_MB,
							NULL, NULL, NULL);

	DefineCustomBoolVariable("pgcolumnar.enable_unique_insert_lock",
							 "Serialize concurrent inserts of the same unique key.",
							 "Takes a transaction-scoped advisory lock per unique "
							 "index key so overlapping same-key inserts conflict "
							 "correctly (issue #5). Turning it off restores the "
							 "prior racy behavior.",
							 &columnar_enable_unique_lock,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("pgcolumnar.unique_lock_buckets",
							"Advisory-lock buckets per unique index for same-key "
							"insert serialization.",
							"Bounds the transaction's held advisory locks to at "
							"most this many per unique index. Equal keys always "
							"share a bucket; unrelated keys may share one, which "
							"only over-serializes. Fixed at server start because "
							"the bucket is part of the advisory lock tag: two "
							"backends inserting the same key must compute the "
							"same bucket, which they only do when they agree on "
							"this value.",
							&columnar_unique_lock_buckets,
							128,
							1, 1048576,
							PGC_POSTMASTER,
							0,
							NULL, NULL, NULL);

	MarkGUCPrefixReserved("pgcolumnar");

	RegisterXactCallback(columnar_xact_callback, NULL);
	RegisterSubXactCallback(columnar_subxact_callback, NULL);

	prev_object_access_hook = object_access_hook;
	object_access_hook = columnar_object_access;

	prev_executor_end_hook = ExecutorEnd_hook;
	ExecutorEnd_hook = columnar_executor_end;

	/*
	 * Forbid index-only scans on columnar tables. PG19 replaced
	 * get_relation_info_hook with build_simple_rel_hook; both fire right after
	 * get_relation_info has built the base relation's index list.
	 */
#if PG_VERSION_NUM >= 190000
	prev_build_simple_rel_hook = build_simple_rel_hook;
	build_simple_rel_hook = columnar_build_simple_rel;
#else
	prev_get_relation_info_hook = get_relation_info_hook;
	get_relation_info_hook = columnar_get_relation_info;
#endif

	/* register the custom scan provider and install the pathlist hook */
	ColumnarCustomScanInit();

	/* install the vectorized-aggregate upper-path hook (spec 9) */
	ColumnarVectorInit();

	/* set up the optional decompressed-chunk cache (spec 8.3) */
	ColumnarCacheInit();

	/* register the unique-index cache invalidation callback (issue #5) */
	ColumnarUniqueInit();
}
