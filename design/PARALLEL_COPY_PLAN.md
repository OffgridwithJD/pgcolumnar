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

## API

```sql
pgcolumnar.parallel_copy(
    target        regclass,      -- columnar table, or partitioned parent (staging mode)
    filename      text,          -- server-side path (like COPY FROM file)
    workers       int   DEFAULT NULL,      -- NULL => min(physical cores, 8)
    mode          text  DEFAULT 'atomic',  -- 'atomic' | 'staging'
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
   the file. A small C helper opens `filename`, and for each of the N target
   offsets seeks near `filesize * i / N`, scans forward to the next record
   terminator, and records the exact byte offset. Ranges are `[off[i],
   off[i+1])`, together covering the file with no overlap or gap.
   - **`format text`**: safe. Text format escapes embedded newlines (`\n`), so a
     raw `\n` is always a record boundary.
   - **`format csv`**: a quoted field may contain a literal newline, so a naive
     newline scan can split mid-record. v1 does a quote-state scan (track open
     quotes, honoring `quote`/`escape`) when finding boundaries; if the scan
     cannot prove a boundary (pathological quoting), it **falls back to a single
     COPY** rather than risk a bad split. Correctness first.
2. **Launch N dynamic background workers** (`RegisterDynamicBackgroundWorker`).
   Each attaches the DSM segment, `BackgroundWorkerInitializeConnection`s to the
   coordinator's database/role, and runs COPY over its byte range using
   `BeginCopyFrom` with a range-limited data source (a callback that returns
   bytes only within `[off[i], off[i+1])`). Rows loaded and status are returned
   through a `shm_mq` per worker.
3. **Commit according to `mode`** (below). Then aggregate rows-loaded and return.

Worker count defaults to `min(online physical cores, 8)`; oversubscribing past
physical cores does not help (measured plateau) and wastes memory.

## Atomicity — two admin-selectable modes

The admin picks the contract that fits the workload; both are all-or-nothing, and
neither can leave a torn partial load committed.

### `mode => 'atomic'` (two-phase commit)

Each worker loads into `target` directly, then `PREPARE TRANSACTION 'pgc_pcopy_<coordpid>_<i>'`
instead of committing. When **all** workers report prepared, the coordinator
`COMMIT PREPARED` each; if **any** worker fails or the coordinator is cancelled,
it `ROLLBACK PREPARED` the ones that prepared and aborts the rest. True
COPY-like atomicity **into a populated table** (append), because every row lands
in one logical target and either all commit or none do.

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

### `mode => 'staging'` (partition attach)

`target` must be a **partitioned table**. Each worker creates a fresh columnar
table and loads its range into it (a normal single-relation COPY, its own
committed transaction), then the coordinator `ALTER TABLE target ATTACH
PARTITION` each staging table — a metadata-only operation. Atomic at the attach
step: until attached the rows are invisible in `target`; a failure drops the
unattached staging tables and nothing is visible in `target`.

- No 2PC / `max_prepared_transactions` requirement.
- Fits the natural time-series layout (partition by time or hostname) and the
  "each worker owns one partition" split, so no cross-partition routing contention.
- **Crash safety:** staging tables are ordinary relations; orphans from a
  coordinator crash are droppable by name prefix (`pgcolumnar.parallel_copy_cleanup()`).
- Requires the split to align with the partition key, or a documented staging→
  attach where partitions are added rather than merged into existing ones.

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
  forced error mid-range) and assert: `atomic` leaves `target` byte-identical to
  its pre-load state (no partial rows); `staging` leaves no attached partition and
  no orphan visible. Assert no prepared-transaction or staging-table leak after
  a clean failure.
- **`workers=1` equals a plain COPY** exactly (degenerate path).
- Assert build + **sanitizer** (bgworker + shm_mq + DSM lifetime is exactly the
  memory-safety surface ASan/UBSan catches) + full 18/19 matrix.

## Phased implementation

1. **File range splitter** — C helper computing N line-aligned offsets (text +
   csv quote-aware), unit-tested against handmade files. Self-contained, no
   worker machinery. *(smallest first slice)*
2. **Coordinator + one worker, `mode='atomic'`, `workers=1`** — end-to-end path
   with the real COPY-over-range data source and 2PC of a single worker; proves
   BeginCopyFrom-over-range and the shm_mq result channel.
3. **N workers, `mode='atomic'`** — DSM fan-out, prepare/commit-all or
   rollback-all, `max_prepared_transactions` guard, failure injection test.
4. **`mode='staging'`** — staging tables + ATTACH PARTITION, cleanup helper.
5. **CSV quote-aware split + full adversarial oracle + sanitizer + 18/19 gate.**
6. **Bench:** parallel-8 100M headline vs single COPY; confirm ~7× and the
   overhead the coordinator adds over the raw prototype.

Each phase compiles, is gated, and is a reviewable commit.

## Open questions for review

- **Mechanism:** native dynamic bgworkers (chosen here — no external dependency,
  integrated cancellation/errors) vs a `dblink`-based orchestrator (simpler, but a
  contrib dependency and self-connections). This plan assumes bgworkers.
- **`staging` combine:** ATTACH PARTITION (chosen — metadata-only, requires a
  partitioned target) vs a columnar-native stripe splice into a non-partitioned
  target (faster for the unpartitioned case but needs storage-format surgery and
  its own crash-safety proof — deferred).
- Default `workers` cap (physical cores vs a fixed 8).
