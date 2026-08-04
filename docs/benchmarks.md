# Benchmarks

`bench/` holds three harnesses. Each builds and installs the extension into a
throwaway cluster, loads a dataset, and reports timings:

```sh
BENCH_DUCKDB=1 bench/run_bench.sh /path/to/pg17_nc/bin/pg_config   # main suite
bench/run_bench_fsst.sh          /path/to/pg17_nc/bin/pg_config    # string ingestion
bench/run_bench_readstream.sh    /path/to/pg18_uring/bin/pg_config # read stream and AIO
```

Run them one at a time, on an idle machine, against a **non-assert** PostgreSQL
build. Assertions distort timing, and a concurrent build or test run makes every
figure meaningless.

These environment variables control the harnesses:

- `BENCH_SCALE`, the number of rows. The default is 6000000.
- `BENCH_REPS`, the number of timed repetitions. The harness reports the median.
  The default is 5.
- `BENCH_PORT`.
- `BENCH_DUCKDB`. Set it to 1 to add a DuckDB comparison, if `duckdb` is on
  `PATH`.

The numbers below come from one full run of `bench/run_bench.sh` on 2026-08-04, at
commit `eb5c7ef`. The conditions were PostgreSQL 18.4 non-assert, 6,000,000 rows,
an 8-column table, the median of 5 repetitions, 8 cores and 12 GB of memory.

The previous record of this section was 2026-07-27 at commit `7a9c9f7`, on
PostgreSQL 17.10 and a machine with 24 GB. The harness itself did not change
between the two runs. The major version and the machine did, so read the ratios
and not the absolute values. The old raw output is in
[../bench/sample_output_all_2026_07_27.txt](https://github.com/jdatcmd/pgcolumnar/blob/main/bench/sample_output_all_2026_07_27.txt).

The read stream section is not re-measured. It needs a PostgreSQL 18 build with
`--with-liburing`, and no such build exists on this machine. Its numbers are from
the earlier run and say so.
The Cross-engine comparison and the parallel sections are a separate, larger run.
It ran on the bench host, at up to 100,000,000 rows, dated 2026-08-04, at the same
commit `eb5c7ef`. Each of those sections states its own method.
They show the shape of the trade and not a precise score. The dataset is
synthetic. It mixes column shapes that suit different encodings, and it does this
deliberately. A table of fully random values will therefore look worse, and a
repetitive table will look better.

**Compare the ratios between runs. Do not compare absolute milliseconds.** This
machine measured the commit of the previous run again, on the same day. Refer to
[What changed](#what-changed-since-the-previous-run). The query latencies were
the same. But the ingestion shapes and the I/O shapes were approximately 20
percent slower than the first record of those numbers. Absolute figures change
with the machine. Trust the comparison that one day gives.

## Storage

Total relation size, including indexes:

| table | size |
| --- | --- |
| heap | 707 MB |
| columnar (zstd) | 135 MB |
| columnar (none) | 40 MB |

Table-only size, excluding indexes:

| table | size | note |
| --- | --- | --- |
| heap | 579 MB | |
| columnar (none) | 40 MB | encodings, no block codec |
| columnar (zstd) | 5.95 MB | encodings plus zstd |

The `columnar (none)` line has no block compression, so 40 MB against heap's
579 MB is the encoding layer alone: 14.5x. zstd on the already-encoded stream
brings the table to 5.95 MB, 97x smaller than heap. Most of the win is the
encodings; the codec compounds it. Including indexes the gap is narrower, because
the benchmark builds the same btree on both and that index dominates the columnar
total.

## Query latency

Heap versus columnar (zstd), median milliseconds:

| query | heap | columnar | heap / columnar |
| --- | --- | --- | --- |
| count(*) full table | 172.13 | 0.02 | 8607 |
| sum/avg over one int column | 258.99 | 0.41 | 632 |
| filtered agg, min/max-skippable range | 205.78 | 11.19 | 18.4 |
| projection: 3 of 8 cols, 1% filter | 229.85 | 10.85 | 21.2 |
| point lookup by indexed id | 0.01 | 15.64 | 0.00 |

`count(*)` and the ungrouped aggregates are answered from row-group metadata
without decoding column data, which is why they are microseconds rather than
milliseconds.

The point lookup was a regression when the previous version of this page was
written, at 1251.88 ms, and it was reported as
[issue #171](https://github.com/jdatcmd/pgcolumnar/issues/171). That issue is
closed. The planner chose a full columnar scan for a point lookup once statistics
existed. It now keeps the index, and the same query takes 15.64 ms.

The filtered aggregate and the projection query also changed by about 8 times.
Column projection is the cause. A columnar scan reads only the columns that a
query references (issue #339).

One point stays true in each case. A single-row fetch must find and decode the
row inside its row group. Columnar storage therefore suits scans and aggregates.
Heap storage suits point lookups and write-heavy OLTP.

## Aggregates fall back once anything is deleted

The metadata answers above hold only while the storage has no delete vector. A zone map covers each row in its group, and this includes the deleted rows. After
a delete, the metadata answer would therefore be incorrect, and the executor uses
a scan instead:

| state | count(*) | sum/avg | min/max |
| --- | --- | --- | --- |
| no deletes | 0.02 ms | 0.32 ms | 0.32 ms |
| after deleting 1 row of 6,000,000 | 0.18 ms | 6.87 ms | 8.44 ms |
| after `pgcolumnar.vacuum` | 0.02 ms | 0.31 ms | 0.31 ms |

The change applies to one row group at a time. A delete therefore costs only the
groups that it touches. The 39 clean groups still fold from their zone maps, and
the executor reads only the group with the delete. This is why `sum/avg` costs
the scan of one group and not of forty. `count(*)` changes very little. The live
count of a group is its row count less its deleted count, and neither figure
needs the data.

This behaviour used to apply to the whole storage. One deleted row then put
`count(*)` at 222 ms and `min/max` at 317 ms, instead of the figures above
([issue #149](https://github.com/jdatcmd/pgcolumnar/issues/149), fixed). Vacuuming
still helps, since it returns the dirty group to the clean path.

## Mutation

Rows reached by index, on a 1,000,000-row copy, median of 5 for the updates and a
single run for the delete:

| operation | heap | columnar | columnar / heap |
| --- | --- | --- | --- |
| UPDATE single row by id | 0.01 ms | 71.73 ms | 7173 |
| UPDATE 1000 rows, ids in row order | 2.38 ms | 84.47 ms | 35 |
| UPDATE 1000 rows, ids scattered | 28.51 ms | 78.98 ms | 2.8 |
| DELETE 1000 rows by id range | 0.3 ms | 73.6 ms | 245 |

The columnar cost is close to the same for one row and for 1000. A write to a
columnar table marks the old row and appends a new one, and the row group is the
unit of that work. The count of rows that are reached therefore matters much less
than it does for heap. This is why the ratio against heap falls as the number of
rows rises: heap pays per row, and columnar pays per row group.

Read the ratio for the scattered case and not the ratio for one row. A single-row
update is the shape that columnar storage is worst at, and the table says so.

**A note on the previous record of this table.** It reported 0.22 ms for the
single-row update. That figure could not be reproduced on the current machine
with the current build or with the build it was taken at. The two builds were compared directly, on
one machine and one major version, with an equivalent single-row update. Commit
`7a9c9f7` gives 162 ms. Commit `eb5c7ef` gives 19 ms. The mutation path is faster than it was, and the earlier 0.22 ms is not a
baseline that this run failed to meet.

The delete figure was the weakest number in this document, at 1509 ms. At that
time, to reach a row, the code went through each earlier row in the group. Both
halves of [issue #143](https://github.com/jdatcmd/pgcolumnar/issues/143) are now
complete. The code decodes the group one time and keeps it in a cache. It then
reaches the value of a row by rank, and not by a walk. Deleting 1000 rows costs 22.8 ms rather than 1509.

## Feature toggles

Vectorization on versus off (columnar zstd, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| sum/avg over int | 0.45 | 270.29 | 601 |
| filtered agg (range) | 8.59 | 8.41 | 0.98 |

The "off" column is much faster than in the previous record, at 270 ms against
1392 ms. Column projection (issue #339) is the reason. The path that does not
vectorize now also reads fewer columns.

Index-only scan on versus off (covering range count, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| covering count, id range (~2%) | 4.97 | 526.69 | 106 |

The "off" column is the fetch-by-row path with no other work. It therefore
isolates the cost of that path and the effect of #143. This shape was 200.9 s
before the decoded-group cache. It was 31.8 s after the cache. It is 0.69 s now
that the walk to the row is also gone.

Projection scan on versus off (covering scan on a scattered sort key, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| sortk, val where sortk in ~0.1% range | 132.47 | 209.48 | 1.58 |

Sorted storage (`pgcolumnar.vacuum_sorted`), narrow range scan on a key not
correlated with insert order, median ms:

| state | ms |
| --- | --- |
| before vacuum_sorted | 255.16 |
| after vacuum_sorted | 1.61 |

Compression `none` against `zstd`, for the columnar table only: 40 MB against
5.95 MB. The scan latency does not change, at 0.41 ms against 0.40 ms. The
encoded stream is already small, and the aggregates do not read it.

## Parallel bulk ingest

`pgcolumnar.parallel_copy` loads a text file with several background workers at
once. The columnar encode step is CPU bound, so the load speeds up with the worker
count, up to the physical core count. The bench host has 8 physical cores and 16
hardware threads.

Method: PostgreSQL 18.4, non-assert, on the bench with 16 vCPU and 62 GB. The
source file is a 20,000,000-row TSBS cpu slice of 21 columns, sorted by time. Each
figure is the median of three interleaved rounds, with the file warm in the page
cache. The baseline is one server-side `COPY`.

Single columnar table, 20,000,000 rows:

| workers | seconds | speedup |
| --- | --- | --- |
| 1 (COPY) | 129.8 | 1.00x |
| 2 | 67.4 | 1.93x |
| 4 | 36.1 | 3.60x |
| 8 | 20.6 | 6.29x |
| 16 | 18.9 | 6.87x |

One worker matches a plain `COPY` at 130.4 s, so the coordinator and the two-phase
commit add little. The result is the same data every time. All runs load
20,000,000 rows with an identical `sum(usage_user)`. On-disk size varies by 0.03%
across worker counts, because the byte split moves a few stripe boundaries.

A 100,000,000-row load shows the same effect at scale. One `COPY` takes 644.1 s;
`parallel_copy` with 16 workers takes 92.8 s, a 6.94x speedup. Both produce 2.67 GB
on disk, within 0.004%. The row counts match. The float `sum` matches to nine
figures and differs in the last, because parallel summation adds in a different
order.

RANGE-partitioned table, 20,000,000 rows, 24 hourly partitions:

| workers | seconds | speedup |
| --- | --- | --- |
| 1 (COPY) | 134.0 | 1.00x |
| 8 | 29.1 | 4.61x |
| 16 | 25.4 | 5.27x |

The partitioned path routes each row to its partition and gives each worker a
distinct partition set. That routing costs a little more than the single-table
split, so the speedup is lower. It still cuts a two-minute load to under 30
seconds.

## Import and export

Export, 6,000,000 rows, 5 columns:

| format | ms | file size | M rows/s |
| --- | --- | --- | --- |
| arrow | 704.0 | 186 MB | 8.5 |
| parquet | 763.0 | 186 MB | 7.9 |

Import, 6,000,000 rows, 5 columns:

| format | ms | M rows/s |
| --- | --- | --- |
| arrow | 4037.3 | 1.5 |
| parquet | 4468.1 | 1.3 |

Import is about 18x slower than export, and the reason is not the import code.
A separate measurement shows this. `import_arrow` costs 12,150 ms. An
`INSERT INTO ... SELECT` of the same rows, with no file, costs 12,990 ms. There
is therefore no overhead that belongs to the import. Reading the whole Parquet file through `read_parquet`
costs 1,415 ms, 11% of the import. The other 89% is the write path, which is also
4.9x slower than a heap insert of the same rows.

So the target is bulk load in general rather than the interop path. Tracked as
[issue #155](https://github.com/jdatcmd/pgcolumnar/issues/155) with a plan in
`design/IMPORT_THROUGHPUT_PLAN.md`.

The plan gives the cost to the transposition between rows and columns. Both
readers decode a column-oriented file into per-row values, and the writer then
copies those values back into per-column buffers. The measurements do not support
that as the main term. A single integer column already writes faster than heap. On a text column, the
FSST substring search is the largest part of the write path. To omit that search
makes a load of 1,000,000 rows 1.2x to 5.7x faster. On five of the seven text
shapes measured, it also produced storage that is identical byte for byte. `encode_effort = fast`
(see [Configuration reference](configuration.md#encode-effort)) exposes that
trade per table.

Index maintenance is not in this path at all, which is a correctness bug rather
than a cost: see [issue #153](https://github.com/jdatcmd/pgcolumnar/issues/153).

Nested round-trip, 1,000,000 rows, one `int[3]` array column and one composite
column:

| format | export ms | import ms | file size |
| --- | --- | --- | --- |
| arrow | 622.8 | 4904.1 | 38 MB |
| parquet | 533.7 | 4860.1 | 35 MB |

Both reconstructed tables matched the source exactly (zero differing rows).

### Parallel export

`pgcolumnar.parallel_export_parquet(table, dir, workers)` writes a columnar table
to a directory of Parquet files with several background workers at once. Each
worker takes a disjoint set of row groups and writes its own file. There is no
coordinator and no shared write state, so export scales close to linearly with
the worker count.

Method: the bench host, 16 vCPU and 62 GB, PostgreSQL 18.4 non-assert, a
50,000,000-row columnar table of 21 columns, source warm, median of three.

| workers | seconds | speedup |
| --- | --- | --- |
| serial `export_parquet` | 72.1 | 1.00x |
| 1 | 71.9 | 1.00x |
| 2 | 36.6 | 1.97x |
| 4 | 19.4 | 3.72x |
| 8 | 10.2 | 7.07x |

One worker matches the serial writer, so the dispatcher adds nothing. Eight
workers cut a 72-second export to about 10 seconds. Every worker imports the one
snapshot the dispatcher exported, so the files together are a single consistent
image of the table at call time.

## String ingestion (FSST)

3,000,000 rows of URL-like strings:

| | |
| --- | --- |
| heap INSERT | 2.00 s |
| columnar INSERT | 12.86 s |
| heap size | 419 MB |
| columnar size | 101 MB |
| vectors using FSST | 20 of 20 |
| round trip | exact match |

FSST is chosen for every vector of the URL column and gives 4.2x on size, paid for
with 6.4x on ingestion time. That ratio is the reason to optimise the selection of the encoding. It is also
the reason to choose the candidates from a sample, and not to apply each of them.
`pgcolumnar.encoding_sample_rows` controls this. It measured loads that are 1.33x
faster, with output that is identical byte for byte.

## Read stream and asynchronous IO

Cold-scan latency on the PostgreSQL 18 io_uring build, 60,000,000 rows, median of
3, caches dropped between runs:

| io_method | read stream on | off | gain |
| --- | --- | --- | --- |
| `sync` | 40.25 s | 40.24 s | 1.00x |
| `worker` | 39.44 s | 40.13 s | 1.02x |
| `io_uring` | 40.10 s | 39.85 s | 0.99x |

Across methods with the read stream on: `worker` 1.02x against `sync`, `io_uring`
1.00x.

These effects are small, and the correct reading does not change from the
previous run. This workload is not I/O-bound in the way that gives prefetching
the most benefit. The columnar layout already reads a small number of large,
sequential regions. The feature costs nothing and
helps slightly. It is not a headline.

## Cross-engine comparison

The sections above measure pgColumnar against heap on the 6,000,000-row synthetic
suite. This section is a separate, larger run. It compares pgColumnar with heap,
TimescaleDB, and Citus on the TSBS `cpu` workload, at 100,000,000 rows across 21
columns. The data is loaded byte for byte the same way into each engine.

The bench host has 16 vCPU and 62 GB. Each engine uses the configuration its own
users would choose:

- pgColumnar: columnar scan, storage in load order, which is time ascending.
- TimescaleDB: compressed columnstore, segmented by `hostname`, ordered by `time` descending.
- heap: sequential scan with the secondary indexes a heap user would build.
- Citus: single node, columnar storage.

The full method follows the storage table.

### Cross-engine storage

Total relation size, including indexes, for the 100,000,000 rows:

| engine | size | smaller than heap |
| --- | --- | --- |
| heap | 22 GB | 1.0x |
| pgColumnar (zstd) | 6,590 MB | 3.4x |
| TimescaleDB columnstore | 7,975 MB | 2.8x |
| Citus columnar | 8,147 MB | 2.8x |

pgColumnar is the smallest of the four.

### Cross-engine query latency

Method, stated so that it can be repeated. Read it before the numbers.

**The data.** All four engines hold the same 100,000,000 rows. The rows come from
one generated TSBS file. Each engine loaded that same file. The row count was
verified in each engine before the measurement.

**The indexes.** Every engine carries a `(hostname, time DESC)` btree. TimescaleDB
also carries the `(time DESC)` index that `create_hypertable` makes. Citus columnar
accepts a btree, so the four are comparable on this point. This is stated for a
reason. An index difference is invisible in a table of times. An engine without an
index that the others have looks worse, and the cause is not the storage format.

**The settings.** `work_mem` is 256MB in every engine. This is a tuned value. The
PostgreSQL default is 4MB. The value is stated because it changes which engine the
table favors. A plan that sorts spills to disk at a low `work_mem`. The same plan
does not spill at a high one. A plan that spills is much slower and much less
stable. Both servers use the same tuned configuration.

**The spill.** The temporary blocks that each query reads and writes are recorded
next to each time. A measurement of a plan that spills has a large spread between
runs. One earlier measurement of this kind moved by 1.43 times with every setting
held constant. That made a difference of 1.73 times impossible to interpret
afterwards (issue #358). Any arm that spills was measured again.

**The parallelism.** Every query was measured twice. The first run sets
`max_parallel_workers_per_gather` to 0. The second sets it to 4. The serial number
shows what the storage format does. The parallel number shows what a user gets.
These are different. After the planner change in issue #362, the difference between
them can be a different plan and not only a different speed.

**The protocol.** The engines are interleaved for each query. No engine is always
the one that is measured first on a cold cache. Each engine gets a cold execution
after a restart of its server and a drop of the operating system cache. Five warm
executions follow. The tables give the median of the five warm runs. The cold
numbers are given separately.

**The servers.** pgColumnar, TimescaleDB and heap share one server. Citus needs a
different `shared_preload_libraries`, so it runs in a second server. The second
server is on the same host and uses the same tuned settings. A cold run restarts
the server that holds the engine which is measured.

**TimescaleDB and parallel workers.** TimescaleDB cannot run the parallel arm on
this host. A query that gets a parallel plan fails:

```
ERROR:  could not read blocks 0..0 in file "base/16384/3708169": read only 0 of 8192 bytes
CONTEXT:  parallel worker
```

The earlier version of this page reported the same fault. This run confirms it and
adds detail. The failure is per query and not per engine. q1, q2 and q3 are served
by an index, take no parallel plan, and give the same result at both settings. q4
and q5 take a parallel plan and fail.

The table records those cells as a failure. It does not record the time that the
failed statement reported. A statement that fails still prints a time, and
that time is small. An error therefore looks like a very fast query if nothing
checks for it.

Measured on 2026-08-04 against `main` at commit `eb5c7ef`, on the 100,000,000-row
fixture. The numbers are the median of five warm runs.

Serial, `max_parallel_workers_per_gather = 0`:

| query | shape | pgColumnar | TimescaleDB | heap | Citus |
| --- | --- | ---: | ---: | ---: | ---: |
| q1 | one host, 1 hour | 400 | 4 | 4 | 279 |
| q2 | one host, 12 hours | 2,253 | 5 | 12 | 1,896 |
| q3 | one host, 12 hours, 5 aggregates | 4,141 | 7 | 14 | 3,386 |
| q4 | all hosts, 12 hours, group by host | 8,517 | 5,465 | 9,810 | 7,398 |
| q5 | all hosts, 12 hours, 10 aggregates | 16,950 | 10,512 | 28,437 | 15,639 |
| q6 | full scan, one value filter | 11,199 | 1,734 | 14,692 | 8,123 |
| q7 | last point per host | 133,759 | 295 | 46 | 124,740 |
| q8 | top 20 by max | 15,639 | 7,583 | 19,857 | 14,440 |

Parallel, `max_parallel_workers_per_gather = 4`:

| query | pgColumnar | TimescaleDB | heap | Citus |
| --- | ---: | ---: | ---: | ---: |
| q1 | 73 | 4 | 4 | 275 |
| q2 | 494 | 5 | 12 | 1,954 |
| q3 | 861 | 6 | 13 | 3,344 |
| q4 | 8,128 | fails | 9,936 | 7,580 |
| q5 | **11,908** | fails | 26,963 | 17,454 |
| q6 | **2,324** | fails | 3,374 | 8,394 |
| q7 | 44,058 | 302 | 47 | 127,796 |
| q8 | 15,958 | fails | 20,420 | 14,635 |

**Spill.** Most cells use no temporary disk at `work_mem = 256MB`. Five do, and they
are all in the two heaviest shapes:

| cell | temp blocks read / written | node |
| --- | ---: | --- |
| q7, pgColumnar, serial | 1,022,514 / 1,022,568 | Sort |
| q7, Citus, serial | 1,022,514 / 1,022,568 | Sort |
| q7, Citus, parallel | 1,022,514 / 1,022,568 | Sort |
| q7, pgColumnar, parallel | 1,533,774 / 1,533,849 | Gather Merge |
| q5, pgColumnar, parallel | 721,569 / 721,584 | GroupAggregate |

A plan that spills can be unstable between runs, which is why each cell is the median
of five. On this host the spilling cells were **not** the unstable ones. Their spread
between the fastest and slowest of the five runs is 1.03 to 1.04 times. The widest
spread in either table is q5 on heap in serial, at **1.18 times**, and that cell does
not spill at all. Every other cell is inside 1.05 times.

Do not read that as "spill does not matter". It matters at a small `work_mem`, where
the same shape has been measured swinging 1.43 times with every setting held constant.
It says that at this setting, on this host, the sort had enough memory for the spill to
be sequential and cheap.

**Parallel workers are what pgColumnar gains most from.** The scan divides cleanly
across workers. q1, q2 and q3 improve by about five times. q5 and q6 move from behind
heap to ahead of it. The serial table is a measure of the storage format. The
parallel table is closer to what an installation gets.

**TimescaleDB leads on every query that filters one host.** Its columnstore segments
by `hostname`, so it reads one segment and not the table. pgColumnar stores rows in
load order, so its zone maps do not skip on `hostname`. A pgColumnar table that is
clustered on the filter key closes that gap, at the cost of the queries that read all
hosts.

**pgColumnar leads the wide aggregate shapes with workers.** q5 reads ten metrics for
all hosts, and q6 scans the table with one filter. pgColumnar is first on both, and
q6 is 2,324 ms against Citus at 8,394 ms.

**q7 measures a planner defect and not the storage format.** The planner declines an
index scan that this query wants. The cost model charges the index path for the rows
the path returns, and not for the rows the query reads. A `DISTINCT ON` reads one row
per host. This is [issue #376](https://github.com/jdatcmd/pgcolumnar/issues/376).

The row above is what this host gives, and this host loads TimescaleDB. That matters,
because TimescaleDB supplies a skip scan, and a skip scan is the consumer that reads
one row per host. The same query gives **769 ms** with
`pgcolumnar.enable_index_fetch_penalty = off`, against 44,058 ms with the default.

An installation without such an extension does not meet this. PostgreSQL has no node that reads part
of an index path and then prices itself again. Such an installation takes the other
plan, and the penalty is correct for it. Which extensions are loaded is part of what a
user gets, which is why the row is given rather than removed.

Citus is slow on this shape for its own reasons, at 124,740 ms serial.

#### Queries

```sql
-- q1, q2: one host, 1 hour and 12 hours
SELECT date_trunc('minute',time) m, max(usage_user) FROM cpu
WHERE hostname='host_1' AND time >= '2024-01-01' AND time < '2024-01-01' + interval '1 hour'
GROUP BY 1 ORDER BY 1;

-- q3: as q2 with five aggregates
SELECT date_trunc('minute',time) m, max(usage_user), max(usage_system),
       max(usage_idle), max(usage_nice), max(usage_iowait) FROM cpu
WHERE hostname='host_1' AND time >= '2024-01-01' AND time < '2024-01-01' + interval '12 hours'
GROUP BY 1 ORDER BY 1;

-- q4, q5: all hosts over 12 hours, one metric and ten
SELECT date_trunc('hour',time) h, hostname, avg(usage_user) FROM cpu
WHERE time >= '2024-01-01' AND time < '2024-01-01' + interval '12 hours'
GROUP BY 1,2;

-- q6: full scan, one value filter
SELECT count(*), avg(usage_system) FROM cpu WHERE usage_user > 90.0;

-- q7: last point per host
SELECT DISTINCT ON (hostname) hostname, time, usage_user FROM cpu
ORDER BY hostname, time DESC;

-- q8: top 20 by max
SELECT hostname, max(usage_user) mx FROM cpu GROUP BY 1 ORDER BY mx DESC LIMIT 20;
```

### Parallel scan

The serial table above holds one axis fixed. pgColumnar's columnar scan
parallelizes across workers. The same query shapes, on a 50,000,000-row columnar
table with no index, serial against four workers, warm median milliseconds:

| query | serial | 4 workers | speedup |
| --- | --- | --- | --- |
| q1 | 987 | 255 | 3.9x |
| q2 | 9580 | 1977 | 4.8x |
| q3 | 9570 | 1965 | 4.9x |
| q4 | 15825 | 3387 | 4.7x |
| q5 | 19155 | 4352 | 4.4x |
| q6 | 40724 | 8290 | 4.9x |
| q7 | 91112 | 26301 | 3.5x |
| q8 | 15482 | 3332 | 4.6x |

Four workers give close to four times on every shape. This table has no index. So
q7 full-scans and sorts, and its serial figure is far above the indexed q7 in the
table above. The point here is the speedup within a column, not a comparison with
that run.

### Reading Parquet from other engines

The Parquet that pgColumnar writes is read by other engines without conversion.
Over a 6,000,000-row file, count and sum:

| reader | time |
| --- | --- |
| DuckDB `read_parquet`, stats-accelerated | 12 ms |
| pyarrow `read_table`, full materialization | 149 ms |

DuckDB over the same rows in its own store answers `count(*)` in 1 ms and
`sum/avg` in 4 ms. pgColumnar answers both from catalog metadata, in 0.02 ms and
0.53 ms, because it does not read the column data for those two shapes. On the
shapes that scan, DuckDB leads. Treat this as an order-of-magnitude check, not a
competitive claim.

## What changed since the previous run

Measured on the same machine, same harness, at three commits. The middle column
is the run this document previously recorded.

| metric | 2f1320f | 1be027b | 7a9c9f7 |
| --- | --- | --- | --- |
| count(*) | 8.27 ms | 0.02 ms | 0.02 ms |
| sum/avg over int | 8.04 ms | 0.53 ms | 0.56 ms |
| covering count, index-only scan off | 200,914 ms | 689 ms | 699 ms |
| DELETE 1000 rows by id range | not measured | 22.8 ms | **14.7 ms** |
| UPDATE 1000 rows, ids in row order | not measured | 20.78 ms | **14.28 ms** |
| count(*) with one row deleted | 222.28 ms | 0.18 ms | 0.18 ms |
| point lookup by indexed id | 32.96 ms | 23.75 ms | **1251.88 ms** |
| storage, all three tables | identical | identical | identical |

The mutation figures improved again, from the direct zone min/max comparison
(#160) and the needed-columns fetch (#164).

Two things do not appear in this table because they are not in the harness, and
both are larger than anything in it:

- **A wide table now permits index-driven access.** 2,000 index fetches that read
  one column of a 41-column table went from 1,001,374 ms to 614 ms. The lazily
  decoding slot (#169) made this change. An 11-column table went from 284,148 ms
  to 159 ms. This is the large step that #157 described, and it is gone.
- **`ANALYZE` now collects statistics** (#159). These include correlation, which
  lets the planner see the locality that `vacuum_sorted` and Z-ordering make.
  This document does not measure its cost. That measurement is part of #171.

The point lookup is the one number that moved the wrong way, and it moved a long
way. See the note above it.

## Reading the results

Columnar wins on analytic shapes: aggregates answered from metadata, filtered
aggregates that minimum, maximum and bloom skipping can prune, wide-table
projections, and index-only covering scans. The size reduction comes mostly from
the encoding layer before zstd. Vectorization adds a large further speedup on
aggregates, and storing a table sorted on its range key improves skipping.

Heap is better for single-row fetches and for deletes, and by a large margin in
both. On a table with deletes, the aggregate advantage is not present until a
vacuum runs.
Columnar is the wrong choice for write-heavy OLTP and the right choice for
scan-heavy and aggregate-heavy analytics over wide, append-mostly tables.
