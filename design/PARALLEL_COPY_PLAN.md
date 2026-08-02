# Parallel bulk ingest — `pgcolumnar.parallel_copy` (#300)

Independent MIT design. References only the public PostgreSQL API (background
workers, DSM/shm_mq, the COPY `BeginCopyFrom`/`NextCopyFrom` interface in
`commands/copy.h`, two-phase commit SQL) and public techniques. No core,
TimescaleDB, Citus, or DuckDB source consulted.

## Motivation (measured)

Post-#155, a 100M-row TSBS-cpu bulk load splits (bench, 10–16M rows, pg18n) as
**text parse ~21% / encode+columnar-write ~53% / base row-pipeline+WAL ~27%**.
The dominant cost is the columnar encode, which is CPU-bound and embarrassingly
parallel. A prototype confirms it: the same 16M-row load run as N concurrent
`COPY`s into N separate columnar tables scales **near-linearly to the physical
core count** and then plateaus:

| N | wall | speedup |
|--:|-----:|--------:|
| 1 | 85.2s | 1.00× |
| 4 | 22.1s | 3.85× |
| 8 | 11.5s | **7.39×** |
| 16 | 11.6s | 7.37× (8 physical cores; HT gives nothing on CPU-bound encode) |

A real 100M parallel-8 load: **74.9s** (2,736 MB — full footprint, nothing
skipped), vs single-COPY columnar 383s and single-COPY heap 173s on the same
cluster. The 7.4× is pure orchestration: today's `COPY` on more cores, no new
parser and no format change. `parallel_copy` packages that so a user gets it from
one command instead of hand-rolling partitions + concurrent shells.

Honest scope: heap parallelizes too, so both-parallel keeps heap ahead (columnar
still pays the encode nobody else does); the win is the practical single-bulk-load
comparison, and parallelism is the only lever that scales the *dominant* cost.

## Architecture finding (2026-08-01, measured) — parallelism needs distinct storage

Building the atomic (2PC) coordinator surfaced a hard constraint, proven on the
bench (16 cores, pg18n, 20M-row TSBS slice, warm):

| load | time | vs single |
|--|--:|--:|
| single COPY | 127.3 s | 1.00× |
| 2 concurrent → **same** table | 255.3 s | **2.01× (serialized)** |
| 2 concurrent → **separate** tables | 132.8 s | 1.04× (parallel) |

pgColumnar serializes concurrent writers **to one table** on a transaction-scoped,
per-storage-id advisory `ExclusiveLock` (`columnar_metadata.c:1489`,
`ColumnarInsertNativeStorageRow`, "held to transaction end" to make the
first-writer storage-row race safe). Two consequences:

1. **Same-table parallel load gets no speedup** (2.01× above) — the measured 7.4×
   only ever came from N COPYs into N *separate* tables (distinct storage ids →
   distinct lock keys).
2. **Atomic 2PC into one table deadlocks**: a loader that `PREPARE`s **retains**
   that advisory lock; the other loaders block on it; the coordinator only
   `COMMIT PREPARED`s after all loaders finish → nobody progresses. Reproduced: the
   assert gate hung on the first 2-worker test; `pg_locks` showed the prepared
   xact holding the advisory lock and the peer loader waiting on it.

**So loading into a single columnar table cannot be both parallel and atomic** with
today's engine. Real parallelism requires each worker to write **distinct storage**.

### The pivot (validated) — two deliverables

- **v1 — partition-parallel.** Target is a **partitioned** table; each worker loads
  a **distinct partition** (distinct storage id → no shared lock → parallel *and*
  2PC-atomic, no deadlock). Validated on the bench: 4 concurrent transactions each
  `COPY`ing 5M rows into a distinct table, each `PREPARE TRANSACTION`, then
  `COMMIT PREPARED` all — **prepare phase 33.3 s vs 32.0 s single (1.04×), rows
  invisible until the commit-all (atomic), 0 prepared-xacts leaked.** The 2PC
  coordinator/loader machinery already built works unchanged; the only new piece is
  a **partition-aligned splitter** so no two workers touch the same partition.

  **Measured (bench, 20M-row TSBS slice, warm, interleaved 3 rounds):** single COPY
  ~126.8 s vs `parallel_copy(8)` into an 8-partition target ~25.6 s = **≈ 5.0×**;
  byte-identical result (same count and `sum(usage_user)`), 0 prepared-xacts leaked.
  Scaling N=1/2/4/8: 137 / 73 / 42 / 27 s (near-linear; N=1 is slightly *slower*
  than plain COPY because the key-parse split + 2PC overhead only pays off at N>1).
  The ~5× vs the raw 7.4× prototype (N COPYs into N separate tables, no split/2PC)
  is the coordinator+splitter overhead, as expected.

  **Full-file headline (bench, 100M-row / 17 GB TSBS, 16 partitions):** single COPY
  **640.6 s** vs `parallel_copy(16)` **118.6 s** = **5.40×**; both 100,000,000 rows
  with identical `sum(usage_user)`, 0 prepared-xacts leaked. The whole file loads
  atomically and in parallel with byte-identical results.
- **enhancement — columnar-core bulk.** A bulk-load path in the engine that lets
  concurrent writers share **one** table without holding the per-storage lock for
  the whole transaction (e.g. coordinator pre-creates+commits the storage row;
  writers skip the creation lock when the row already exists committed). Lifts the
  single-table restriction. Deferred behind v1 because it changes correctness-
  sensitive core code.

Together these cover both partitioned targets (v1) and arbitrary single tables
(enhancement). The rest of this document is being revised to the partition-parallel
design; the "atomic into one table" mechanism below is **retired** by this finding.

## API

```sql
pgcolumnar.parallel_copy(
    target        regclass,      -- columnar table (partitioned parent: staging, deferred)
    filename      text,          -- server-side path (like COPY FROM file)
    workers       int   DEFAULT NULL,      -- NULL => derived from max_parallel_workers
    mode          text  DEFAULT 'atomic',  -- 'atomic' (v1); 'staging' deferred, see below
    format        text  DEFAULT 'text',    -- 'text' | 'csv'
    delimiter     text  DEFAULT NULL,
    null_string   text  DEFAULT NULL,
    header        bool  DEFAULT false,
    encoding      text  DEFAULT NULL,
    freeze        bool  DEFAULT false
) RETURNS bigint    -- rows loaded
```

Superuser or `pg_execute_server_program`/`pg_read_server_files` as COPY requires.
All COPY-option semantics (NULL, quote, escape, encoding, per-column input
functions) are delegated to core COPY inside each worker, so they are **identical
to a plain `COPY`** — this is the whole point: no looser parser to get wrong.

## Mechanism

The coordinator (the calling backend) runs a fixed pipeline:

1. **Split the input into `workers` line-aligned byte ranges** without rewriting
   the file. A small C helper opens `filename` (rejecting anything that is not a
   regular file, as core COPY does), then makes a **single forward O(filesize)
   pass** — reading in fixed chunks with `CHECK_FOR_INTERRUPTS`, emitting each
   interior boundary at the first newline at or beyond `filesize * i / N`. (A
   per-boundary seek-and-scan was the first cut; it was `O(filesize * workers)` on
   a newline-poor file and not cancellable — the single pass removes both.) Ranges
   are `[off[i], off[i+1])`, together covering the file with no overlap or gap; the
   range count is bounded so a huge `workers` cannot allocate unbounded memory.
   - **`format text`** (v1): safe. Text format escapes embedded newlines (`\n`), so
     a raw `\n` is always a record boundary.
   - **`format csv`** (later phase): a quoted field may contain a literal newline,
     so a naive newline scan can split mid-record. The plan is a quote-state scan
     (track open quotes, honoring `quote`/`escape`); if it cannot prove a boundary
     (pathological quoting), it **falls back to a single COPY** rather than risk a
     bad split. Until then the helper takes no format argument and its contract is
     text-only, stated in both the C and SQL comments.
2. **Launch N dynamic background workers** (`RegisterDynamicBackgroundWorker`).
   Each attaches the DSM segment, `BackgroundWorkerInitializeConnection`s to the
   coordinator's database/role, and runs COPY over its byte range using
   `BeginCopyFrom` with a range-limited data source (a callback that returns
   bytes only within `[off[i], off[i+1])`). Rows loaded and status are returned
   through a shared per-worker slot (a status word + row count + error text).
3. **Commit according to `mode`** (below). Then aggregate rows-loaded and return.

Worker count, when the caller passes none, is **derived from the admin's existing
parallelism budget** (`max_parallel_workers`), not raw physical cores. Two reasons
(both from review): PostgreSQL exposes no portable physical-core count, and
defaulting to `min(cores, 8)` on a stock server asks for the entire
background-worker pool (`max_worker_processes`, default 8), starving autovacuum and
everything else that needs a slot. The default is `max(1, max_parallel_workers / 2)`
and the cap is exposed as a GUC, so there is one knob rather than two that can
disagree. Oversubscribing past physical cores does not help (measured plateau) and
wastes memory.

## Atomicity — two admin-selectable modes

The admin picks the contract that fits the workload; both are all-or-nothing, and
neither can leave a torn partial load committed.

> **Architecture correction (verified 2026-08-01).** `COMMIT PREPARED` /
> `ROLLBACK PREPARED` cannot run inside a transaction block, and a SQL function is
> always in one — confirmed empirically (`EXECUTE of transaction commands is not
> implemented`, and the utility path calls `PreventInTransactionBlock`). So the
> coordinator that *finishes* the 2PC **cannot be the `parallel_copy()` SQL
> function**. Atomic mode therefore runs the coordinator as its own background
> worker: `parallel_copy()` launches one **coordinator bgworker**, which owns its
> transaction loop, spawns the N loader bgworkers, prepares them, issues the
> COMMIT/ROLLBACK PREPARED for all, writes the total back through the DSM, and
> exits; the function just waits and returns that total. (The phase-2 plumbing —
> DSM, loaders, bounded COPY, error propagation — is unchanged and reused; only
> *who* runs it moves from the function to the coordinator bgworker.) Staging mode
> below has no such constraint: `ATTACH PARTITION` is ordinary DDL the function can
> run itself, so staging stays function-driven.

### `mode => 'atomic'` (two-phase commit, via a coordinator bgworker)

Each loader worker loads into `target` directly, then `PREPARE TRANSACTION 'pgc_pcopy_<coordpid>_<i>'`
instead of committing. When **all** loaders report prepared, the coordinator
bgworker `COMMIT PREPARED`s each; if **any** loader fails or the launch is
cancelled, it `ROLLBACK PREPARED`s the ones that prepared and aborts the rest.
True COPY-like atomicity **into a populated table** (append), because every row
lands in one logical target and either all commit or none do.

- Requires `max_prepared_transactions >= workers` (checked up front with a clear
  error naming the setting).
- **Crash safety:** prepared transactions are WAL-durable and recovered by normal
  PostgreSQL crash recovery. A coordinator crash *after* prepare but *before* the
  commit decision leaves prepared transactions that a DBA resolves (or a
  `pgcolumnar.parallel_copy_cleanup()` helper rolls back by gid prefix). This is
  the standard 2PC orphan story, documented, not hidden.
- Concurrent writers into one columnar relation: append-only bulk load acquires
  the same row-group reservation path the single-writer COPY uses; the reservation
  is already serialized by the storage layer, so workers interleave group
  reservations rather than corrupt them. (Verified by the prototype's clean
  concurrent loads; re-verified under assert + the differential oracle here.)

### `mode => 'staging'` (partition attach) — **deferred, not a v1 option**

> **Review finding (2026-08-01), verified as a design defect.** The original idea:
> `target` is partitioned, each worker loads its range into a fresh columnar table,
> the coordinator `ALTER TABLE target ATTACH PARTITION`s each. It does not fit
> together, for three reasons, and staging is therefore **removed from v1**:
>
> 1. **Byte ranges are not key ranges.** The splitter hands worker *i* a *byte*
>    range of the file; a partition needs a *key* range. On unsorted input every
>    staging table spans the whole key space, so each `ATTACH` either fails with
>    "partition constraint is violated by some row" or, if a bound is wide enough to
>    admit them, is useless. Nothing in this design makes the byte split align with
>    the partition key, and the splitter cannot.
> 2. **ATTACH is not metadata-only here.** Attaching a freshly loaded table runs a
>    validation scan unless a matching `CHECK` constraint already proves the bound —
>    for a columnar staging table that is a full decode of everything just written.
>    If the target has a default partition (the normal defensive time-series
>    layout), each ATTACH additionally takes `AccessExclusiveLock` on it and
>    re-validates. That is an exclusive-level lock this project's rules require to be
>    justified against a weaker correct one — and here it is not the metadata-only
>    operation the plan claimed.
> 3. **Atomicity was overstated.** The design never made the N ATTACHes one
>    transaction; if they are not, a coordinator crash after *k* of *N* leaves *k*
>    partitions permanently visible — the torn partial load the doc says cannot
>    happen.
>
> The byte-range vs key-range mismatch is the deciding one and must be answered
> before staging is a v1 option at all (a sort-aware or key-partitioning splitter,
> or a columnar-native stripe splice, is a separate design). v1 ships **atomic mode
> only**; staging is future work with its own plan and crash-safety proof.

WAL: neither mode skips WAL in v1 (the measured profile showed WAL is not the
pole — encode is — so unlogged staging is deferred; it is also blocked today by
"unlogged columnar tables are not supported").

## Correctness & tests (`test/parallel_copy.sh`)

Correctness is the hard part the issue flags, so the oracle is exhaustive:

- **Heap oracle, byte-identical result set.** For each mode and `workers` in
  {1,2,3,8}, `parallel_copy` into a columnar table vs a plain `COPY` of the same
  file into a heap table must produce identical rows (order-independent hash).
  Run over adversarial fixtures: NULLs, quoted/escaped fields, embedded delimiters,
  embedded newlines (CSV), multi-byte encodings, every column type in the TSBS
  schema, empty file, single-row file, file not ending in a newline, a file whose
  size is not divisible by `workers`, and `workers` greater than the row count.
- **Atomicity under failure.** Inject a worker failure (a poisoned row / a
  forced error mid-range) and assert `atomic` leaves `target` byte-identical to
  its pre-load state (no partial rows), with no prepared-transaction leak after a
  clean failure. (Staging's failure story is deferred with staging itself.)
- **`workers=1` equals a plain COPY** exactly (degenerate path).
- Assert build + **sanitizer** (bgworker + shm_mq + DSM lifetime is exactly the
  memory-safety surface ASan/UBSan catches) + full 18/19 matrix.

## Phased implementation

1. **File range splitter** — C helper computing N line-aligned offsets for COPY
   **text** format (one forward O(filesize) pass, interruptible, regular-file
   guard, bounded worker count), unit-tested against handmade files including a
   file with lines longer than the scan chunk and an assertion that the split is
   real. Self-contained, no worker machinery. *(smallest first slice — landed)*
2. **Coordinator + N loader workers, per-range-commit, `workers>=1`** — DSM
   fan-out, the real COPY-over-range data source, and the shm status channel.
   Proves BeginCopyFrom-over-range end to end. *(landed; not yet atomic)*
3. **`mode='atomic'` via a coordinator bgworker** — the loaders `PREPARE
   TRANSACTION`; a dedicated coordinator background worker (its own top-level
   session, so it *can* run `COMMIT PREPARED`) commits-all or rolls-back-all, with
   the `max_prepared_transactions` guard and a failure-injection test. This is the
   architecture correction below; it makes atomic mode actually atomic.
4. **CSV quote-aware split + full adversarial oracle + sanitizer + 18/19 gate.**
5. **Bench:** parallel-8 100M headline vs single COPY; confirm ~7× and the
   overhead the coordinator adds over the raw prototype.

*(Staging/ATTACH mode is removed from this plan — see the staging section above —
and becomes separate future work once the byte-range vs key-range mismatch has a
design.)*

Each phase compiles, is gated, and is a reviewable commit.

## Open questions — resolved in review (2026-08-01)

- **Mechanism:** native dynamic bgworkers, **and the coordinator role moves into a
  bgworker** (not the calling SQL function), because only a top-level session can
  `COMMIT PREPARED`. Decided on that constraint, not dependency taste. dblink could
  also finish the 2PC but adds a contrib dependency and self-connections.
- **`staging` combine:** neither ATTACH nor a stripe splice, *yet* — the question
  assumed ATTACH is metadata-only (it is not) and that byte ranges partition by
  key (they do not). Staging is deferred until the byte-vs-key mismatch is
  designed; it is not a v1 option regardless of the combine.
- **Default `workers`:** not raw physical cores (no portable count; `min(cores,8)`
  grabs the whole `max_worker_processes` pool). Derived from `max_parallel_workers`
  (`max(1, budget/2)`) with the cap exposed as a single GUC.
