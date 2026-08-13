# Issue #415: pgcolumnar_autovacuum, and the recluster self-gating it requires

Design before code. #415 asked for a background worker that runs the maintenance
autovacuum cannot reach; the measurement and the policy function
(`pgcolumnar.maintenance_due`, merged) settled *what* to run and *when*. This is
the *how*: a daemon on autovacuum's model, and the one fix the daemon cannot be
built without.

## Part A (prerequisite): recluster() must stop rewriting when nothing changed

Measured on #415 axis C: `pgcolumnar.recluster('t','k')` rewrites the whole
relation on **every** call, even when the table is already fully clustered by `k`
(27 groups / ~6.2 s each on a 4M-row table, repeated). A scheduler that calls it
speculatively would rewrite untouched tables on every naptime. This is a
production hazard on its own and a hard blocker for the daemon.

The root cause is that the storage row records the sorted *extent*
(`sorted_from`/`sorted_through`) but **not what key the run is clustered by**, so
recluster cannot tell "already clustered by these columns" from "clustered by
something else". (Same gap surfaced in the maintenance_due work as
`sort_status.sort_key` reading NULL on a clustered table.)

### Fix: record the clustering key and kind

`pgcolumnar.storage` gains two columns:

- `sorted_by name[]` — the clustering columns of the current run.
- `sorted_kind text` — `'zorder'` (recluster/cluster) or `'lexicographic'`
  (vacuum_sorted). The two orderings share the extent mark but are different
  arrangements, so the kind is load-bearing: recluster('k') after a
  vacuum_sorted('k') on the same multi-column key must NOT no-op.

`PgColumnarSetSortedExtent` gains the key columns and kind and writes all four
fields atomically with the extent; a getter returns them. Existing storages
(pre-upgrade rows) have NULL here and are treated as "unknown key" → never
no-op'd, the safe default.

### The no-op condition (recluster)

recluster(rel, cols) returns 0 without rewriting **iff**:
1. the sorted run covers every live group (no unsorted/appended groups outside
   `[sorted_from, sorted_through]`), AND
2. `sorted_kind = 'zorder'`, AND
3. `sorted_by = cols` (exact, ordered).

Any mismatch — appended data present, a different key, or a lexicographic run —
falls through to the full rewrite, so re-clustering by a new key still works
(the contract is preserved, only redundant work is skipped). vacuum_sorted gets
the mirror-image gate for the lexicographic kind.

### Upgrade / binary-swap behavior (durable note, #614 review)

The storage columns are added to the base script (fresh install) and to the
dev->alpha upgrade file as idempotent `ADD COLUMN IF NOT EXISTS`. A binary swap
that installs the new `.so` onto an un-upgraded 7-column storage table degrades
**safely to the pre-#415 behavior** -- but ONLY because both the read
(`PgColumnarGetSortedInfo`) and the write (`PgColumnarSetSortedExtent`) guard on
`tupdesc->natts >= Anum_..._sorted_kind` before touching attnums 8/9. Without
that guard the new .so CRASHES on the old 7-column storage table:
`heap_getattr`/`heap_modify_tuple` index past the descriptor -- an absent attnum
is NOT read as a clean NULL (verified: a faithful old->new binary-swap test
crashed the backend on the first recluster; the guard fixes it, #614 review).
With the guard, an un-upgraded table records nothing and never self-gates
(`sort_key` NULL) -- exactly the pre-#415 behavior. The upgrade file adds the two
columns (idempotent `ADD COLUMN IF NOT EXISTS`) and `CREATE OR REPLACE`s
`sort_status`, so `ALTER EXTENSION ... UPDATE` reaches full behavior; a faithful
old->new test confirmed the columns land at attnums 8/9, the self-gate works, and
pre-existing tables read unchanged.

### Ripple benefit

`sort_status.sort_key` reports `storage.sorted_by` (the actual clustering),
fixing the NULL-on-clustered-table gap; `maintenance_due` then sees a real key
and the daemon can recluster by it.

### TDD

- RED: recluster on an already-clustered, unchanged table rewrites all groups
  (assert `pgcolumnar.recluster(...) > 0` and row groups churn).
- GREEN: it returns 0 and the physical groups are unchanged (relfilenode/blocks).
- After appends: recluster folds only the new data.
- recluster by a NEW key: still a full re-cluster (contract preserved).
- vacuum_sorted then recluster on the same key: NOT a no-op (kind differs).
- Gate: full matrix (18+19) + preflight all majors + **sanitizer** (pg18_san):
  this touches the metadata write path.

## Part B: pgcolumnar_autovacuum

A launcher background worker in autovacuum's shape, registered from `_PG_init`.
pgColumnar is already a `shared_preload_libraries` extension (the custom-scan and
planner hooks require it), so this adds **no new install requirement**; a server
run without preload simply loses the daemon and nothing else.

### Architecture (mirrors core autovacuum)

- **Launcher** (`BgWorkerStart_RecoveryFinished`, connects to no specific DB):
  wakes every `naptime`; if disabled, sleeps again; else enumerates databases
  and registers a short-lived **per-database worker** via
  `RegisterDynamicBackgroundWorker` (the pattern parallel_copy/export already use
  in this tree, portable across PG15-19). Throttles to one worker at a time.
- **Worker**: `BackgroundWorkerInitializeConnectionByOid(dbid, InvalidOid)`;
  enumerates columnar tables (`pg_class.relam = pgcolumnar`); for each, consults
  `pgcolumnar.maintenance_due(rel)` via SPI; runs the recommended **lazy** verb;
  exits.

### The safety invariant (the whole point)

The worker calls **only** the ShareUpdateExclusiveLock verbs — `compact_rewrite`
and the now-self-gating `recluster` — and **never** `vacuum`, `vacuum_sorted`, or
`cluster`. SUEL does not block reads or ordinary writes. So the daemon cannot
block production by construction. A test asserts the worker never acquires
AccessExclusiveLock (lock-contention arm: hold a conflicting lock, confirm the
daemon does not queue ahead of anyone).

### Autovacuum non-blocking semantics (per the user's direction)

SUEL still conflicts with a user's stronger lock (e.g. ALTER TABLE), which would
queue behind a long maintenance op. The daemon adopts autovacuum's yield: the
worker sets `PROC_IS_AUTOVACUUM` on its `MyProc->statusFlags` (compat macro
across majors) for the duration of a maintenance op, so core's lock manager
**auto-cancels** the op the moment a backend queues for a conflicting lock — the
op takes a query-cancel, releases SUEL, the user's statement proceeds, and the
worker catches the cancel (subtransaction + PG_TRY) and moves to the next table.
Autovacuum's own `deadlock_timeout`/cancel path, reused rather than reinvented.

### Recluster and the daemon

The worker reclusters a table only when it has a recorded/declared key (Part A's
`sorted_by`, else `options.sort_by`); with no key it cannot know the columns and
skips recluster (compact_rewrite still runs on deleted fraction). With Part A,
recluster is safe to call speculatively — it self-gates to a no-op when nothing
decayed, so the daemon need not perfectly predict work.

### GUCs (registered in `_PG_init`, `pgcolumnar.*` reserved prefix)

- `pgcolumnar.autovacuum` (bool, **default off**) — master switch. Off by
  default per #415's "strong default of not doing so"; opt-in, and even when on
  it only runs non-blocking verbs.
- `pgcolumnar.autovacuum_naptime` (int seconds, default 60).
- `pgcolumnar.autovacuum_compact_threshold` (float8, default 0.2) →
  maintenance_due's `compact_due_fraction`.
- `pgcolumnar.autovacuum_recluster_threshold` (float8, default 0.05).
- `pgcolumnar.autovacuum_cost_delay`-style throttle: deferred to a follow-up;
  the online verbs + naptime bound the load for the first cut, stated as a
  limitation.

### Failure handling

A worker that errors aborts its own subtransaction and continues to the next
table; a launcher restart uses a bounded `bgw_restart_time`, never a tight loop.
Where it failed is logged with the relation name at `LOG`.

### TDD

- default-off: with the GUC off, no maintenance happens (control).
- enabled + short naptime: a table over the deleted threshold is compacted
  within N naptimes (poll `stats()` for retired/rewritten groups).
- non-blocking: the worker never takes AccessExclusiveLock (lock arm).
- yield: hold SUEL-conflicting demand during a maintenance op, assert the op
  cancels and the user's statement proceeds (autovacuum-cancel arm).
- Gate: full matrix + preflight; the bgworker path is exercised on 18+19.

## Order of work

1. Part A (recluster self-gating) — its own PR; the daemon depends on it.
2. Part B (daemon) — on top, default-off, only the lazy verbs, autovacuum yield.
