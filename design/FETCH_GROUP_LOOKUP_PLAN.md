# O(K·G) index/bitmap fetch row-group lookup (#709)

## Problem

`pgcolumnar_fetch_row` (columnar_reader.c) runs once per fetched TID: per row
of an index or bitmap scan, per duplicate probe of `_bt_check_unique`, and per
UPDATE re-fetch. Each call reads the ENTIRE row-group list out of the catalog
(`PgColumnarReadRowGroupList`: a `systable` index scan over
`pgcolumnar.row_group` plus one palloc'd node per group) and then walks it
linearly. K fetches over G groups cost K catalog index scans and O(K·G)
comparisons; the list read dominates. The code's own comment records the
reason it was left uncached: a group flushed earlier in the same statement
must become visible to a later fetch (read-your-writes through
`PgColumnarCatalogSnapshot`, which advances `curcid`).

## Design

A backend-global row-group-LIST memo beside the existing decoded-group cache
(`columnarFetchCache`, which already memoizes per `(storageId, groupNumber,
cid)`), reusing the delete-vector reader's refresh-on-miss discipline
(`delete_vector_find_row_group`), with these rules:

1. **MVCC snapshots only.** A `SnapshotDirty` probe (`_bt_check_unique`) or
   `SnapshotAny` fetch (trigger OLD-row re-fetch) keeps today's per-fetch
   read. Dirty visibility changes as other transactions commit; the unique
   path relies on seeing current state per probe.
2. **Key = (storageId, CommandId, full snapshot content).** The cached list
   is valid only for a snapshot that judges every catalog tuple identically
   to the one that built it: compare `xmin`, `xmax`, advanced `curcid`,
   `xcnt` + `xip[]`, `subxcnt` + `subxip[]`, `suboverflowed`,
   `takenDuringRecovery`. Content comparison, not pointer identity: pointer
   reuse cannot alias, and two references to one logical snapshot hit. A
   mismatch on anything rebuilds. A handful of slots (LRU, like the group
   cache's 4) covers interleaved cursors.
3. **Refresh on miss.** A rowNumber no cached group covers triggers ONE
   re-read under a fresh `PgColumnarCatalogSnapshot`, then a second lookup
   (the delete-vector two-attempt shape). This is what preserves the
   same-statement-flush contract: a group flushed after the memo was built
   is a miss, and the refresh sees it (same cid, `curcid` advanced). A group
   never covers new row numbers after creation, and within one command the
   own-transaction catalog state visible at `curcid+1` can gain groups but
   not lose them (reclaim/rewrite runs as its own statement, and cross-
   transaction deletions are invisible to the same MVCC snapshot by
   definition), so a HIT cannot be stale.
4. **Last-hit fast path + linear walk, NO binary search.** The adversarial
   pass showed a sorted-array binary search is unfalsifiable here: the
   instrument counts catalog reads, which the memo alone removes, and the
   residual in-memory walk over G entries (fixtures 20-40 groups; 6M rows at
   the default stripe is 40) is microseconds. The proven sibling
   (`delete_vector_find_row_group`) is exactly last-hit + linear + two
   attempts, unsorted. Shipping a comparator with no removal proof fails the
   house rule; the memo keeps the sibling's shape.
5. **Reset with the group cache, PLUS two discards the group cache gets away
   without.** The memo drops where `columnarFetchCache` drops (top-level
   commit/abort, executor end), and additionally:
   - **on subtransaction abort** (the existing subxact callback): a group
     flushed by a live savepoint is visible when the memo is built, and
     `ROLLBACK TO SAVEPOINT` flips its `xmin` verdict with NO change in
     snapshot content, cid, or any reset event the group cache watches.
     Today's per-fetch read re-judges `xmin` every time; a memo HIT would
     serve the aborted group's rows off its durably-written file bytes. The
     decoded-group cache survives this only BECAUSE the per-fetch list read
     answers first — the memo takes over that role, so it must reset.
   - **on row-group retirement** (`PgColumnarRetireGroup`) — and the
     journey of this reset is the record worth keeping. The hazard analysis
     demanded it; probing on PG17 then showed the mid-statement rewrite path
     crossing a `CommandCounterIncrement` (the flush's storage-row update),
     which rebuilds the memo anyway, so the reset failed every PG17 removal
     proof and was REMOVED under the deletion-proof rule, with the suite's
     same-statement rewrite arm left as a sentinel. The sentinel then fired
     on PG18: its rewrite path performs NO such CCI, and the first
     post-rewrite probe hit the stale memo through the old index entry (one
     doubled all-NULL row, 501 not 500) before refresh-on-miss healed the
     slot. The CCI is an accident of one major's flush path, not an
     invariant, so the reset ships — with the PG18 arm as its removal proof
     and PG17's masking CCI documented as exactly that, masking. (A FULLY
     deleted group is refused by `compact_rewrite` — measured: rewrote 0 —
     and is retired only by vacuum-family commands, which cannot run inside
     another statement; that shape stays unreachable.)
6. **The refresh reads under the FETCH's snapshot argument**, i.e. the same
   `PgColumnarCatalogSnapshot(snapshot)` the per-fetch read uses today — NOT
   `GetActiveSnapshot()` as the delete-vector sibling does. One MVCC caller
   (`pgcolumnar_index_delete_tuples`) runs with no active snapshot set, and
   a refresh under a different snapshot than the key's would store a list
   the key's snapshot never judged.

Out of scope, recorded for a follow-up: the per-fetch
`PgColumnarReadDeleteVectorList` read has the same per-fetch-catalog-scan
shape but cannot use refresh-on-miss (a miss is the common "not deleted"
answer), so it needs its own invalidation design.

## Instrument (work-done, not timing; hardened by the adversarial pass)

Every `PgColumnarReadRowGroupList` call is one index scan on
`row_group_pkey`; probed empirically on the unfixed build, K = 3000
index-fetched rows cost 6001 scans — TWO per fetch (one liveness settle via
`PgColumnarRowIsLive`, one deferred decode via
`PgColumnarReadRowByNumberCols`, the #157 slot design) plus setup.
Instrument discipline the pass demanded:

- `pg_stat_get_xact_numscans` is a pending-entry counter: read the BASELINE
  and the AFTER value in the SAME psql session as the measured statement and
  assert the DELTA (the harness's `q()` opens a fresh connection per call,
  which reads 0 and would fake the RED arm green).
- Assert the `pgcolumnar.row_group` TABLE scan delta is 0 in the same
  window: if `row_group_pkey` ever fails to resolve, the read silently
  degrades to a heap scan and the index counter reads a vacuous 0 (#695's
  suite pins its sibling the same way).
- Force the plan and prove it: `enable_seqscan=off`, `enable_bitmapscan=off`,
  `enable_indexonlyscan=off`, `pgcolumnar.enable_custom_scan=off`,
  `pgcolumnar.enable_index_fetch_penalty=off`,
  `max_parallel_workers_per_gather=0`, and an EXPLAIN plan-shape assertion
  (Index Scan) taken BEFORE the baseline capture, because planning itself
  reads the list once (`pgcolumnar_relation_estimate_size`).
- The counted transaction contains exactly: baseline read, ONE SELECT over
  fully-flushed data, after read. Buffered-row fetches are permanent misses
  (each refreshes, same cost as today, no win) and UPDATE arms take
  write-side list reads — both stay OUTSIDE the counted window. Expected
  post-fix contributors: 1 planning scan + 1 memo build (+ nothing else);
  bound <= 20 is auditable slack, pre-fix delta is ~2K.

## Test plan (TDD)

New suite `native_fetch_group_memo.sh`:

- RED arm: K = 3000 LATERAL index fetches; scan delta collapses from ~2K
  (measured 6001) to <= 20, heap-scan delta 0, plan shape pinned.
- Correctness arms:
  - scattered index fetches across many groups: values match generated
    truth;
  - fetch after same-transaction flush in a LATER statement (new cid
    rebuilds);
  - same-statement insert-then-fetch (CTE `INSERT ... RETURNING` joined
    against an index fetch): characterization, same answer as unfixed;
  - **subxact-abort arm** (removal proof for the subxact discard): cursor
    over an index scan; SAVEPOINT; INSERT that flushes a group (stripe limit
    set IN the arm's session — a fixture-session SET does not carry); MOVE
    more (memo rebuilds with the subxact's group visible); ROLLBACK TO
    SAVEPOINT; `MOVE ALL` — its command tag is the row count, and it must
    read exactly the real rows. Rows, never values: a resurrected row
    decodes all-NULL (the group comes from the poisoned memo, the fresh
    column_chunk read sees nothing), so value-counting instruments are
    blind — the arm's first version was, and its removal proof failed;
  - **mid-statement rewrite arm** (removal proof for the retirement reset,
    firing on PG18): `reclaim_coalesce=off`; one statement that
    warm-fetches, runs `compact_rewrite`, then `count(*)`-fetches ids from
    the rewritten group — 500 exact; without the reset PG18 reads 501 (the
    first post-rewrite probe hits the stale memo through the old index
    entry before refresh-on-miss heals it) while PG17's incidental flush
    CCI masks the missing reset;
  - unique-violation with buffered + flushed duplicates (`SnapshotDirty`
    unchanged); UPDATE re-fetch + AFTER UPDATE trigger OLD row
    (`SnapshotAny` unchanged); DELETE then fetch in the next statement
    (delete vectors still read per fetch, uncached).
- Regression: fetch-family suites (`native_fetch_cache`,
  `native_fetch_bigcap`, `index_only`, `unique_conc`, trigger/update
  suites) plus the cross-cutting pair.

Removal proofs: (1) sever the memo lookup (slot never matches, every fetch
rebuilds) — the scan-delta arm goes RED, correctness arms stay green;
(2) sever only the subxact reset — the subxact-abort arm's MOVE ALL tag
reads 3000 high; (3) sever only the retirement reset — the rewrite arm
reads 501 on PG18 (PG17 stays green there, masked by its incidental flush
CCI; the matrix carries the proof).
