# PostgreSQL version adoption for pgColumnar

Features in newer PostgreSQL majors that pgColumnar can use, and what has come of
each. Renamed from `PG18_19_OPPORTUNITIES.md` on 2026-08-05: the old name pinned
the file to two majors and was already wrong in the filename, which is the least
fixable place to be wrong (#390, #395).

The support matrix is PostgreSQL 15 through 19, so anything adopted must be
version-gated with `#if PG_VERSION_NUM` and fall back on older majors, in the
style of `src/columnar_compat.h`.

Sources: PostgreSQL 18 and 19 release notes; read_stream.h and read_stream.c;
pgsql-hackers threads on read streams in extensions. Every status note carries the
date it was written. A note without one has not been checked.

## Status, 2026-08-05

| item | state |
| --- | --- |
| 1. Read stream and AIO | **shipped**, `pgcolumnar.enable_read_stream` (gap 29) |
| 2. Virtual generated columns | covered by `test/generated_columns.sh` |
| 3. Temporal constraints | covered by `test/temporal.sh` |
| 4. btree skip scan | open, no measurement |
| 5. REPACK | **investigated and the conclusion was wrong**, see below (#399) |
| 6. Statistics injection | open, no measurement |
| 7. Partial-path startup costs (19) | **measured, changes nothing for us** (#397) |
| 8. Parallel autovacuum (19) | **measured, parameter accepted and ignored** (#398) |

## 19 items this document did not previously mention

Added 2026-08-05 from the 19 release notes.

- **`get_relation_info_hook` is removed and replaced by `build_simple_rel_hook`.**
  We use that hook, so 19 would have broken the build. Already gated, at
  `src/columnar_tableam.c:2443`. Recorded here because nothing else will explain
  why the `#if PG_VERSION_NUM >= 190000` is there.
- **Partial-path startup costs are now considered.** Measured against #369's shapes
  on 18 and 19: plan selection is identical, so this does not move the grouped
  parallel arm. #397 has the numbers. #369 is not version-gated.
- **Parallel autovacuum**, `autovacuum_max_parallel_workers` and the per-table
  `autovacuum_parallel_workers`. Measured: a columnar table **accepts and stores**
  the storage parameter and our vacuum ignores it, while heap launches workers on
  the same fixture. #398.
- **Aggregate processing before joins.** Untested. Interacts with the vectorized
  aggregate and its upper-path hook.
- **New planner hooks**: `planner_setup_hook`, `planner_shutdown_hook`,
  `joinrel_setup_hook`, `join_path_setup_hook`. We install `set_rel_pathlist_hook`
  and `create_upper_paths_hook` today. Untested.
- **Query scans can mark pages all-visible in the visibility map.** We keep our own
  visibility map in `columnar_visibilitymap.c`. Untested.
- **`EXPLAIN (ANALYZE, IO)`.** Methodology rather than a feature, and our benchmark
  arguments keep coming down to what was actually read.
- **C11 is the minimum language version.** We already set a newer standard, so this
  should be free. Worth a preflight rather than an assumption.

## Watching, PostgreSQL 20

**There is no feature list here on purpose.** PostgreSQL 19 is not released: beta 2
shipped 2026-07-16 and release is planned for September 2026. Master is the 20
branch with one commitfest run, freeze around April 2027, and anything committed can
still be reverted. A list would be invention.

One thing is worth watching. 19 changed index access method handlers to a static
`IndexAmRoutines` structure. If a `TableAmRoutine` counterpart follows, it touches
our handler directly.

## 1. Read Stream API + asynchronous I/O — highest value

- **Availability.** The read stream API (`storage/read_stream.h`,
  `read_stream_begin_relation`, `read_stream_next_buffer`) landed in PostgreSQL 17
  and drives sequential scans and ANALYZE. PostgreSQL 18 added the asynchronous
  I/O subsystem (`io_method` = sync | worker | io_uring, `io_combine_limit`,
  `io_max_combine_limit`, `pg_aios`), and the read stream is the interface that
  feeds it. Reported up to 3x on reads from storage.
- **Current state in pgColumnar.** The reader fetches each chunk's value and
  exists stream blocks with individual `ReadBuffer` calls, synchronously, one
  chunk group at a time (`src/columnar_reader.c`). There is no prefetch, so a
  cold scan waits on each block in turn.
- **Opportunity.** Drive the block reads for a stripe/chunk-group scan through a
  read stream. The block numbers a columnar scan needs are known ahead of time
  from the stripe/chunk catalog, which is exactly the case the read stream (and
  `read_stream_next_block` for callers that compute their own block numbers) is
  built for. On PostgreSQL 18 this gets AIO prefetch for free; on 17 it gets
  posix_fadvise-based prefetch; on 13-16 it falls back to the current path.
- **Effort / risk.** Medium. The API shape has moved between 17, 18, and 19, so
  the adoption must be behind a compat shim and validated on each major. Risk is
  confined to the read path and covered by the differential/recovery suites.
- **Why first.** It is the largest cold-scan performance lever available and maps
  directly onto how pgColumnar already plans its block reads.

## 2. Virtual generated columns (PostgreSQL 18, now the default)

- Generated columns can be virtual and are virtual by default; their values are
  computed at read time rather than stored.
- **Relevance.** A columnar table with a virtual generated column must return the
  computed value on read and must not store a chunk for it. Confirm the table AM
  and custom scan handle read-time generation correctly, and add differential
  coverage (columnar vs heap) for stored and virtual generated columns on
  PostgreSQL 18+. Likely handled at the executor level, but it is unverified.
- **Effort.** Small (a correctness check plus a test), version-gated to 18+.
- **Verified (`test/generated_columns.sh`).** Stored and virtual generated
  columns both read correctly on a columnar table across the matrix; the executor
  recomputes the virtual value on read, so values match the heap oracle and the
  generation expression. One finding: pgColumnar currently *materializes an
  all-null chunk* for a virtual generated column at insert rather than skipping
  its storage. The read-time value overrides it, so this is a storage
  inefficiency, not a correctness problem. Skipping the write for
  `attgenerated = 'v'` columns (and returning NULL for them from the reader) is a
  worthwhile future write-path optimization; it needs matching reader/vacuum
  changes and its own coverage, so it is not bundled here.

## 3. Temporal constraints (PostgreSQL 18 `WITHOUT OVERLAPS`, PostgreSQL 19 `FOR PORTION OF`)

- PostgreSQL 18 allows non-overlapping PRIMARY KEY/UNIQUE (`WITHOUT OVERLAPS`) and
  temporal foreign keys (`PERIOD`); PostgreSQL 19 adds `FOR PORTION OF` updates.
- **Relevance.** These run through the index and constraint machinery pgColumnar
  already integrates with. Verify enforcement on a columnar table and add
  coverage; do not assume it works. Effort small, version-gated.

## 4. btree skip scan (PostgreSQL 18)

- The btree AM can skip leading index columns. Indexes built on columnar tables
  benefit automatically; no pgColumnar code change. Worth a benchmark line and a
  test that a multicolumn index on a columnar table plans a skip scan on 18+.

## 5. REPACK, concurrent (PostgreSQL 19) -- CONCLUSION WAS WRONG

**Corrected 2026-08-05 (#399). REPACK does not work on a columnar table.**

This section previously reasoned that because `REPACK` reuses the CLUSTER machinery,
which dispatches through the `relation_copy_for_cluster` table-AM callback, and
because pgColumnar registers that callback, non-concurrent `REPACK` "should work".

The dispatch reasoning was right. The conclusion was not, because the callback is
**registered and is a stub**:

```c
pgcolumnar_relation_copy_for_cluster(...)
{
	COLUMNAR_UNSUPPORTED("CLUSTER / VACUUM FULL");
}
```

So "pgColumnar already implements that callback" was true of the symbol and false of
the behaviour. Measured on 19beta2: `REPACK`, `REPACK ... USING INDEX`,
`REPACK (VERBOSE)`, `CLUSTER` and `VACUUM FULL` all raise, while `REPACK` succeeds on
a heap table on the same build. `REPACK (CONCURRENTLY)` on a table with a primary key
also succeeds on heap and raises on columnar.

The supported route is `pgcolumnar.vacuum()` and `pgcolumnar.vacuum_sorted()`.

**This entry is the reason the file now carries dates and states what was measured
rather than what was inferred.** Inspection of which callback a command dispatches
through cannot tell you whether that callback does anything. Pinned by
`test/native_repack.sh`.


## 6. Optimizer statistics injection (PostgreSQL 18)

- `pg_restore_relation_stats()`, `pg_restore_attribute_stats()`,
  `pg_clear_relation_stats()`, `pg_clear_attribute_stats()` let code set per-
  relation and per-column stats. pgColumnar could seed planner statistics that
  reflect columnar reality (per-column distinct/min/max already in the catalog),
  improving plan choice. Optional, additive, version-gated to 18+.

## Noted, out of scope for pgColumnar

SQL/PGQ property graphs, `ON CONFLICT DO SELECT`, `GROUP BY ALL`, `IGNORE NULLS`,
native JSON `COPY TO`, LZ4 as the default TOAST codec, `pg_plan_advice`. These are
server or SQL-surface features that do not change what a columnar table AM does.
`COPY TO ... (FORMAT json)` (PostgreSQL 19) is unrelated to the Arrow/Parquet
export work in gap 27.

## Suggested order

Revised 2026-08-05, after #397, #398 and #399 reported.

1. **Nothing from 19 is urgent.** The two items measured this week both came back
   negative for us: partial-path startup costs change no plan we care about (#397),
   and parallel autovacuum accepts a parameter we ignore (#398).
2. **#398 is the only one with a user-visible defect attached**, and the fix is to
   reject the storage parameter rather than to honour it.
3. Statistics injection (item 6) and a skip-scan benchmark line (item 4) remain the
   open ones, both untested and neither blocking.

Anything not listed above is a watch item, not planned work. `design/ROADMAP.md` is
the place for planned work, and `docs/roadmap.md` is where a user should be sent.
