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

The numbers below come from one full run of all three harnesses on 2026-07-27, at
commit `7a9c9f7`. The conditions were PostgreSQL 17.10 non-assert, 6,000,000
rows, an 8-column table, the median of 5 repetitions, 8 cores and 24 GB of
memory. The read stream harness used 18.4 with io_uring. Raw output is in
[../bench/sample_output_all_2026_07_27.txt](https://github.com/jdatcmd/pgcolumnar/blob/main/bench/sample_output_all_2026_07_27.txt).
The Cross-engine comparison and the parallel sections are a separate, larger run.
It ran on the bench host, at up to 100,000,000 rows, dated 2026-08-02. Each of
those sections states its own method.
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
| count(*) full table | 254.28 | 0.02 | 12714 |
| sum/avg over one int column | 379.89 | 0.56 | 678 |
| filtered agg, min/max-skippable range | 268.96 | 90.70 | 2.97 |
| projection: 3 of 8 cols, 1% filter | 232.83 | 85.83 | 2.71 |
| point lookup by indexed id | 0.01 | 1251.88 | 0.00 |

`count(*)` and the ungrouped aggregates are answered from row-group metadata
without decoding column data, which is why they are microseconds rather than
milliseconds.

**The point lookup number is a regression and not a property of the design.**
The investigation is
[issue #171](https://github.com/jdatcmd/pgcolumnar/issues/171). The previous run recorded 23.75 ms for the same query on the
same machine. Two facts are known. First, the cause is not the
lazy-decoding slot. An A/B test across that merge, on a table without statistics,
gives 16.42 ms before and 13.73 ms after. Second, the difference between that
test and this harness is that the harness runs `ANALYZE` on the table first. So the planner is choosing differently once
statistics exist, and choosing worse. Treat the row as a bug report rather than a
measurement of the fetch path.

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
| UPDATE single row by id | 0.02 ms | 0.22 ms | 11 |
| UPDATE 1000 rows, ids in row order | 3.81 ms | 14.28 ms | 3.8 |
| UPDATE 1000 rows, ids scattered | 43.15 ms | 147.89 ms | 3.4 |
| DELETE 1000 rows by id range | 0.5 ms | 14.7 ms | 29 |

Row-ordered access does better than scattered because consecutive fetches stay
inside one row group, which the statement-scoped decoded-group cache serves
without re-decoding.

The delete figure was the weakest number in this document, at 1509 ms. At that
time, to reach a row, the code went through each earlier row in the group. Both
halves of [issue #143](https://github.com/jdatcmd/pgcolumnar/issues/143) are now
complete. The code decodes the group one time and keeps it in a cache. It then
reaches the value of a row by rank, and not by a walk. Deleting 1000 rows costs 22.8 ms rather than 1509.

## Feature toggles

Vectorization on versus off (columnar zstd, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| sum/avg over int | 0.51 | 1392.60 | 2731 |
| filtered agg (range) | 92.12 | 90.32 | 0.98 |

Index-only scan on versus off (covering range count, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| covering count, id range (~2%) | 7.53 | 698.95 | 93 |

The "off" column is the fetch-by-row path with no other work. It therefore
isolates the cost of that path and the effect of #143. This shape was 200.9 s
before the decoded-group cache. It was 31.8 s after the cache. It is 0.69 s now
that the walk to the row is also gone.

Projection scan on versus off (covering scan on a scattered sort key, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| sortk, val where sortk in ~0.1% range | 191.41 | 635.35 | 3.32 |

Sorted storage (`pgcolumnar.vacuum_sorted`), narrow range scan on a key not
correlated with insert order, median ms:

| state | ms |
| --- | --- |
| before vacuum_sorted | 364.13 |
| after vacuum_sorted | 47.72 |

Compression `none` against `zstd`, for the columnar table only: 40 MB against
5.95 MB. The scan latency does not change, at 0.52 ms against 0.52 ms. The
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
| arrow | 1008.6 | 186 MB | 5.9 |
| parquet | 1100.2 | 186 MB | 5.5 |

Import, 6,000,000 rows, 5 columns:

| format | ms | M rows/s |
| --- | --- | --- |
| arrow | 17721.5 | 0.3 |
| parquet | 17762.5 | 0.3 |

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
| 8 | 10.2 | 7.11x |

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

Method: the bench host, 16 vCPU and 62 GB, PostgreSQL 18.4 non-assert, on
2026-08-02 at the current `main` plus the export feature. Each engine has the box
to itself. Latency is client-observed, one cold run after a restart with the
cache dropped, then the median of three warm runs, interleaved per query. Each
engine uses the configuration its own users would choose:

- pgColumnar: columnar scan, storage in load order, which is time ascending.
- TimescaleDB: compressed columnstore, segmented by `hostname`, ordered by `time` descending.
- heap: sequential scan with the secondary indexes a heap user would build.
- Citus: single node, columnar storage, sharded.

The query engines run serial (`max_parallel_workers_per_gather = 0`). That
isolates the storage and scan path. It is not pgColumnar at its ceiling. The
parallel scan below adds about four times on these same shapes.

### Cross-engine storage

Total relation size, including indexes, for the 100,000,000 rows:

| engine | size | smaller than heap |
| --- | --- | --- |
| heap | 22 GB | 1.0x |
| TimescaleDB columnstore | 7.8 GB | 2.8x |
| pgColumnar (zstd) | 6.4 GB | 3.4x |

pgColumnar is the smallest of the four. The encoding layer does most of this, and
zstd compounds it, as the [Storage](#storage) section shows in detail.

### Cross-engine query latency

Warm latency, median of three, in milliseconds:

| query | shape | pgColumnar | TimescaleDB | heap | Citus |
| --- | --- | --- | --- | --- | --- |
| q1 | one host, 1 hour | 994 | 4 | 11045 | 315 |
| q2 | one host, 12 hours | 10532 | 5 | 11244 | 1935 |
| q3 | one host, 12 hours, 5 aggregates | 10462 | 6 | 11341 | 3630 |
| q4 | all hosts, 12 hours, group by host | 18856 | 5098 | 17290 | 6694 |
| q5 | all hosts, 12 hours, 10 aggregates | 22671 | 10437 | 21247 | 15407 |
| q6 | full scan, one value filter | 81966 | 1771 | 14699 | 8810 |
| q7 | last point per host | 785 | 299 | 47 | timeout |
| q8 | top 20 by max | 37397 | 7572 | 23970 | 12943 |

Read this by query shape, not by a single winner. Three patterns hold.

**TimescaleDB wins the host-filtered queries by a wide margin.** q1 to q3 filter
on one `hostname`. The columnstore segments by `hostname`, so it reads one segment
and skips the rest. pgColumnar stores in time order, so its zone maps do not skip
on `hostname` and it scans the range. This is a layout choice, not a ceiling. A
separate run stored the same table clustered on the filter key. q1 to q3 then fell
from about ten seconds to about one hundred milliseconds, because the zone maps
skipped. The cost is the all-host queries, which the clustered layout slows.

**The full-scan aggregate is pgColumnar's weak shape today.** q6 reads every row
and filters on a value column. pgColumnar serial is slower than heap on it. The
decompression and aggregation path is not yet vectorized for this case. That work
is [issue #289](https://github.com/jdatcmd/pgcolumnar/issues/289). The parallel
scan below already brings q6 close to heap, and the vectorization will take it
further.

**Citus and pgColumnar are within a small factor on the heavy grouped queries**
(q4, q5, q8). Citus times out on last point (q7) at the 120-second limit.

The last-point query (q7) is not a scan number for pgColumnar or heap. Both tables
have a `(hostname, time)` index. The query reads one row per host, so the planner
walks the index rather than a full sort. TimescaleDB answers it from segment
order.

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
