/*-------------------------------------------------------------------------
 *
 * columnar_row_lock.c
 *		Serialize concurrent writers of the SAME columnar row (issue #5, the
 *		UPDATE facet).
 *
 * A columnar UPDATE is delete-old plus insert-new, and a DELETE marks a bit in
 * the delete vector. Neither takes a lock on the row identity, and
 * pgcolumnar_tuple_lock does not implement row locking, so core never runs
 * EvalPlanQual. Two transactions updating the same row therefore each keep their
 * own new version: the old row is deleted once and both new rows survive, so the
 * row is duplicated and one update is lost. A heap serializes this transparently.
 *
 * This module gives the write paths a row-identity guard, modeled on the
 * concurrent unique-key insert serialization in columnar_unique.c and the
 * chunk-group advisory lock in columnar_metadata.c (issue #4). Before a write
 * marks the old row deleted it:
 *
 *   1. If the row is already marked deleted in THIS command's own buffer, the
 *      same command is modifying it twice (a self-join UPDATE ... FROM). Return
 *      TM_SelfModified so core resolves it exactly as it does for a heap.
 *   2. Take a transaction-scoped advisory lock on the row identity
 *      (storage id, row number). A concurrent writer of the same row waits here
 *      until this transaction commits. A no-wait caller that would block gets
 *      TM_BeingModified.
 *   3. Re-read the row's liveness in the LATEST committed state (not the caller
 *      snapshot, which PgColumnarCatalogSnapshot only copies). If a concurrent
 *      transaction has committed a delete of this row, raise a retryable
 *      serialization_failure. The lock is the authority for waiting out the
 *      competitor; this fresh-snapshot re-read is the authority for whether a
 *      conflict actually happened, so a hash-bucket collision can only add
 *      waiting, never a false failure.
 *
 * The net contract at every isolation level is one retryable serialization
 * failure for the losing writer of a same-row race, matching what a heap gives
 * at REPEATABLE READ and what columnar already gives at SERIALIZABLE. READ
 * COMMITTED becomes stricter than a heap (the loser retries rather than
 * re-applying transparently via EvalPlanQual); see docs/limitations.md.
 *
 * Written fresh for pgColumnar. It reuses no upstream source; it derives from the
 * issue #5 design analysis and the public PostgreSQL API. See PROVENANCE.md.
 *
 *-------------------------------------------------------------------------
 */
#include "columnar.h"

#include "access/tableam.h"
#include "access/xact.h"
#include "miscadmin.h"
#include "storage/lock.h"
#include "utils/snapmgr.h"

#include "columnar_delete_vector.h"

/*
 * GUCs. enable_row_update_lock is USERSET so it can be turned off for a session
 * that wants the old behavior. row_lock_buckets is POSTMASTER because the bucket
 * count is part of the advisory lock tag: two backends racing the same row must
 * compute the same bucket, which they only do when they agree on this value
 * (identical to unique_lock_buckets).
 */
bool		pgcolumnar_enable_row_update_lock = true;
int			pgcolumnar_row_lock_buckets = 1024;

/*
 * row_identity_lock_key
 *		Mix (storage id, row number) into a 64-bit advisory-lock key, with the
 *		same FNV-1a plus splitmix64 finalizer as delete_vector_chunk_lock_key and
 *		the unique-key hash, so the avalanche spreads the bits. A collision only
 *		makes two unrelated rows serialize needlessly; it never affects
 *		correctness, because the exact-row committed re-read below is what decides
 *		a real conflict.
 */
static uint64
row_identity_lock_key(uint64 storageId, uint64 rowNumber)
{
	uint64		h = UINT64CONST(1469598103934665603);	/* FNV-1a offset basis */

	h = (h ^ storageId) * UINT64CONST(1099511628211);
	h = (h ^ rowNumber) * UINT64CONST(1099511628211);

	h ^= h >> 33;
	h *= UINT64CONST(0xff51afd7ed558ccd);
	h ^= h >> 33;
	h *= UINT64CONST(0xc4ceb9fe1a85ec53);
	h ^= h >> 33;

	return h;
}

/*
 * PgColumnarLockRowIdentity
 *		Take the transaction-scoped exclusive advisory lock for one row identity.
 *		Returns true when the lock is held. With wait == false it returns false
 *		instead of blocking when another transaction holds the row. The lock is
 *		held until this transaction ends (the concurrent writer must not run its
 *		committed re-read until our delete is committed and visible to it), which
 *		is why it is a transaction lock, exactly like the delete-vector and
 *		unique-key locks.
 *
 *		The bucket bounds the transaction's distinct held row locks to at most
 *		row_lock_buckets per storage, so a bulk UPDATE cannot exhaust the lock
 *		table; unrelated rows sharing a bucket only over-serialize.
 */
bool
PgColumnarLockRowIdentity(Relation rel, uint64 rowNumber, bool wait)
{
	uint64		storageId = PgColumnarStorageId(rel);
	uint32		numBuckets = (uint32) Max(1, pgcolumnar_row_lock_buckets);
	uint64		key = row_identity_lock_key(storageId, rowNumber);
	uint32		bucket = (uint32) (key % numBuckets);
	LOCKTAG		tag;
	LockAcquireResult res;

	SET_LOCKTAG_ADVISORY(tag, MyDatabaseId,
						 (uint32) storageId, bucket,
						 PGCOLUMNAR_LOCKCLASS_ROW_IDENTITY);

	res = LockAcquire(&tag, ExclusiveLock, false /* transaction lock */ ,
					  !wait /* dontWait */ );
	return res != LOCKACQUIRE_NOT_AVAIL;
}

/*
 * PgColumnarRowCommittedDeleted
 *		Is the row deleted in the LATEST committed state? Used only after the
 *		row-identity lock is held, so any concurrent writer has already committed
 *		or aborted. GetLatestSnapshot (pushed active for the catalog scan, as PG18
 *		asserts) sees a delete a concurrent transaction committed after our own
 *		snapshot, which PgColumnarCatalogSnapshot(caller) would not. The caller
 *		must check the in-memory buffer (PgColumnarDeleteVectorBufferedDeleted)
 *		first, so this only runs when the row is not our own buffered delete; a
 *		row with no covering committed group (concurrently compacted) reads as
 *		deleted, which is the correct conflict verdict.
 */
bool
PgColumnarRowCommittedDeleted(Relation rel, uint64 rowNumber)
{
	bool		live;

	PushActiveSnapshot(GetLatestSnapshot());
	live = PgColumnarRowIsLive(rel, GetActiveSnapshot(), rowNumber);
	PopActiveSnapshot();

	return !live;
}

/*
 * PgColumnarRowWriteConflict
 *		The shared row-identity guard for pgcolumnar_tuple_update and
 *		pgcolumnar_tuple_delete, run BEFORE the write marks the old row deleted.
 *
 *		Returns true when the write must not proceed; then *result holds the
 *		TM_Result to return and tmfd is filled for the self-modified and
 *		being-modified cases. Raises a serialization_failure (does not return) on
 *		a committed concurrent delete. Returns false when the write may proceed.
 *		Does not set *lockmode; the update callback sets it when this returns a
 *		blocking result, since tuple_delete has no lockmode.
 */
bool
PgColumnarRowWriteConflict(Relation rel, ItemPointer otid, CommandId cid,
						   bool wait, TM_FailureData *tmfd, TM_Result *result)
{
	uint64		rowNumber = PgColumnarItemPointerToRowNumber(otid);

	/*
	 * Same command modifying the same row twice (a self-join UPDATE ... FROM):
	 * the old row is already marked deleted in this command's own buffer. Report
	 * it as self-modified so core resolves it as it does for a heap, rather than
	 * writing a second new version. cmax == the current command id makes core
	 * treat it as already handled by this command. This is a deterministic
	 * correctness fix independent of concurrency, so it runs even when the
	 * row-lock GUC is off.
	 */
	if (PgColumnarDeleteVectorBufferedDeleted(rel, rowNumber))
	{
		ItemPointerCopy(otid, &tmfd->ctid);
		tmfd->xmax = GetCurrentTransactionId();
		tmfd->cmax = cid;
		*result = TM_SelfModified;
		return true;
	}

	if (!pgcolumnar_enable_row_update_lock)
		return false;

	/*
	 * Serialize against any concurrent writer of this exact row. With wait the
	 * loser blocks here until the winner commits; a no-wait caller that would
	 * block is told so.
	 */
	if (!PgColumnarLockRowIdentity(rel, rowNumber, wait))
	{
		ItemPointerCopy(otid, &tmfd->ctid);
		tmfd->xmax = InvalidTransactionId;
		tmfd->cmax = InvalidCommandId;
		*result = TM_BeingModified;
		return true;
	}

	/*
	 * The lock is now ours, so any competitor has resolved. If it committed a
	 * delete of this row, our write would duplicate the row and lose an update;
	 * fail with a retryable serialization error instead. The application retries.
	 */
	if (PgColumnarRowCommittedDeleted(rel, rowNumber))
		ereport(ERROR,
				(errcode(ERRCODE_T_R_SERIALIZATION_FAILURE),
				 errmsg("columnar: could not serialize access due to concurrent update or delete of the same row"),
				 errhint("Retry the transaction.")));

	return false;
}
