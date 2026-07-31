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

## Cross-engine read

DuckDB over the same data (`BENCH_DUCKDB=1`), as a sanity check on order of
magnitude rather than a competitive claim:

| query | DuckDB | pgColumnar |
| --- | --- | --- |
| count(*) | 1 ms | 0.02 ms |
| sum/avg over int | 4 ms | 0.53 ms |

pgColumnar is now ahead on both. This result means less than it appears to.
These are the two shapes that pgColumnar answers from catalog metadata, with no
access to the column data, and DuckDB scans the data. On the shapes that actually scan, the filtered aggregate and
the projection, it remains the other way round.

Reading the Parquet file pgColumnar wrote, 6,000,000 rows, count and sum:

| reader | time |
| --- | --- |
| DuckDB `read_parquet` (stats-accelerated) | 12 ms |
| pyarrow `read_table` (full materialization) | 149 ms |

These confirm the Parquet output is read by other engines without conversion.

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
