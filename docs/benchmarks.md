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

Environment variables: `BENCH_SCALE` (rows, default 6000000), `BENCH_REPS`
(timed repetitions, median reported, default 5), `BENCH_PORT`, and `BENCH_DUCKDB`
(set to 1 to add a DuckDB comparison when `duckdb` is on `PATH`).

The numbers below are one full run of all three harnesses, measured 2026-07-26 at
commit `f7adbdb`: PostgreSQL 17.10 non-assert (18.4 with io_uring for the read
stream harness), 6,000,000 rows, 8-column table, median of 5, on 8 cores with
24 GB of memory. Raw output is in
[../bench/sample_output_pg17_6m.txt](../bench/sample_output_pg17_6m.txt). They
show the shape of the tradeoff, not a precise score. The dataset is synthetic and
deliberately mixes column shapes that suit different encodings, so a table of
purely random values will look worse and a repetitive one better.

**Compare ratios across runs, not absolute milliseconds.** Re-measuring the
previous run's commit on this machine on the same day (see
[What changed](#what-changed-since-the-previous-run)) reproduced its query
latencies but came out about 20% slower on ingestion and I/O shapes than when
those numbers were first recorded. Absolute figures move with the machine; the
same-day comparison is the one to trust.

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
| count(*) full table | 251.95 | 0.02 | 12597 |
| sum/avg over one int column | 346.99 | 0.53 | 655 |
| filtered agg, min/max-skippable range | 270.17 | 90.96 | 2.97 |
| projection: 3 of 8 cols, 1% filter | 260.56 | 80.18 | 3.25 |
| point lookup by indexed id | 0.01 | 26.75 | 0.00 |

`count(*)` and the ungrouped aggregates are answered from row-group metadata
without decoding column data, which is why they are microseconds rather than
milliseconds.

The point lookup is the trade the design makes and does not hide: a single-row
fetch decodes the row group the row lives in, so one row costs a whole group's
decode. Columnar suits scans and aggregates; heap suits point lookups and
write-heavy OLTP.

## Aggregates fall back once anything is deleted

The metadata answers above hold only while the storage has no delete vector. A
zone map covers every row in its group including deleted ones, so once a row is
deleted the metadata answer would be wrong and the executor falls back to a scan:

| state | count(*) | sum/avg | min/max |
| --- | --- | --- | --- |
| no deletes | 0.02 ms | 0.29 ms | 0.30 ms |
| after deleting 1 row of 6,000,000 | 222.28 ms | 233.89 ms | 317.22 ms |
| after `pgcolumnar.vacuum` | 0.02 ms | 0.30 ms | 0.30 ms |

The fallback is table-wide rather than per row group, so one deleted row takes all
40 groups off the fast path, including the 39 with no deletes
([issue #149](https://github.com/jdatcmd/pgcolumnar/issues/149)). Vacuuming
restores it. Plan for this on tables that take deletes or updates.

## Mutation

Rows reached by index, on a 1,000,000-row copy, median of 5 for the updates and a
single run for the delete:

| operation | heap | columnar | columnar / heap |
| --- | --- | --- | --- |
| UPDATE single row by id | 0.02 ms | 0.20 ms | 10 |
| UPDATE 1000 rows, ids in row order | 3.68 ms | 22.34 ms | 6.1 |
| UPDATE 1000 rows, ids scattered | 42.38 ms | 161.08 ms | 3.8 |
| DELETE 1000 rows by id range | 0.5 ms | 1509.5 ms | 3019 |

Row-ordered access does better than scattered because consecutive fetches stay
inside one row group, which the statement-scoped decoded-group cache serves
without re-decoding. The delete figure is the weakest number in this document.

Touching N rows in one row group is still quadratic in N: a cache hit skips the
read and the decode but still walks to the row's position, and that walk is linear
in the offset. See [issue #143](https://github.com/jdatcmd/pgcolumnar/issues/143).

## Feature toggles

Vectorization on versus off (columnar zstd, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| sum/avg over int | 0.51 | 795.94 | 1561 |
| filtered agg (range) | 73.19 | 71.86 | 0.98 |

Index-only scan on versus off (covering range count, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| covering count, id range (~2%) | 7.31 | 31845.77 | 4356 |

The "off" column is the fetch-by-row path doing nothing else, which makes it the
clearest single view of what that path costs.

Projection scan on versus off (covering scan on a scattered sort key, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| sortk, val where sortk in ~0.1% range | 184.20 | 619.66 | 3.36 |

Sorted storage (`pgcolumnar.vacuum_sorted`), narrow range scan on a key not
correlated with insert order, median ms:

| state | ms |
| --- | --- |
| before vacuum_sorted | 355.04 |
| after vacuum_sorted | 45.81 |

Compression none versus zstd (columnar table-only): 40 MB versus 5.95 MB, with
scan latency unchanged (0.50 ms against 0.50 ms), because the encoded stream is
already small and the aggregates do not read it.

## Import and export

Export, 6,000,000 rows, 5 columns:

| format | ms | file size | M rows/s |
| --- | --- | --- | --- |
| arrow | 923.0 | 186 MB | 6.5 |
| parquet | 1009.8 | 186 MB | 5.9 |

Import, 6,000,000 rows, 5 columns:

| format | ms | M rows/s |
| --- | --- | --- |
| arrow | 16783.5 | 0.4 |
| parquet | 17171.9 | 0.3 |

Import is about 18x slower than export and is the clearest optimisation target in
the interop path: export writes a prepared buffer, while import goes through the
full insert path including encoding selection and index maintenance.

Nested round-trip, 1,000,000 rows, one `int[3]` array column and one composite
column:

| format | export ms | import ms | file size |
| --- | --- | --- | --- |
| arrow | 528.5 | 4589.8 | 38 MB |
| parquet | 502.8 | 4709.5 | 35 MB |

Both reconstructed tables matched the source exactly (zero differing rows).

## String ingestion (FSST)

3,000,000 rows of URL-like strings:

| | |
| --- | --- |
| heap INSERT | 1.92 s |
| columnar INSERT | 12.37 s |
| heap size | 419 MB |
| columnar size | 101 MB |
| vectors using FSST | 20 of 20 |
| round trip | exact match |

FSST is chosen for every vector of the URL column and gives 4.2x on size, paid for
with 6.4x on ingestion time. That ratio is why encoding selection is worth
optimising, and why choosing candidates from a sample rather than applying all of
them (`pgcolumnar.encoding_sample_rows`) measured 1.33x faster loads with
byte-identical output.

## Read stream and asynchronous IO

Cold-scan latency on the PostgreSQL 18 io_uring build, 60,000,000 rows, median of
3, caches dropped between runs:

| io_method | read stream on | off | gain |
| --- | --- | --- | --- |
| `sync` | 38.12 s | 38.05 s | 1.00x |
| `worker` | 37.49 s | 38.24 s | 1.02x |
| `io_uring` | 38.03 s | 38.91 s | 1.02x |

Across methods with the read stream on: `worker` 1.02x against `sync`, `io_uring`
1.00x.

These are small, and the honest reading is unchanged from the previous run: this
workload is not I/O-bound in the way prefetching helps most, because the columnar
layout already reads few, large, sequential regions. The feature costs nothing and
helps slightly. It is not a headline.

## Cross-engine read

DuckDB over the same data (`BENCH_DUCKDB=1`), as a sanity check on order of
magnitude rather than a competitive claim:

| query | DuckDB | pgColumnar |
| --- | --- | --- |
| count(*) | 1 ms | 0.02 ms |
| sum/avg over int | 4 ms | 0.53 ms |

pgColumnar is now ahead on both, which says less than it appears to: these are the
two shapes it answers from catalog metadata without touching column data, and
DuckDB is scanning. On the shapes that actually scan, the filtered aggregate and
the projection, it remains the other way round.

Reading the Parquet file pgColumnar wrote, 6,000,000 rows, count and sum:

| reader | time |
| --- | --- |
| DuckDB `read_parquet` (stats-accelerated) | 8 ms |
| pyarrow `read_table` (full materialization) | 128 ms |

These confirm the Parquet output is read by other engines without conversion.

## What changed since the previous run

The previous version of this document recorded a run at commit `2f1320f` and
flagged `count(*)` as slower than it should be, tracked as issue #133. That is
fixed. To measure the difference honestly rather than compare across machines and
days, the same harness was run on this machine on this day at both commits:

| metric | 2f1320f | f7adbdb | |
| --- | --- | --- | --- |
| count(*) | 8.27 ms | 0.02 ms | 413x |
| sum/avg over int | 8.04 ms | 0.53 ms | 15x |
| covering count, index-only scan off | 200914.88 ms | 31845.77 ms | 6.3x |
| sum/avg, vectorization off | 1381.37 ms | 795.94 ms | 1.7x |
| point lookup by id | 32.96 ms | 26.75 ms | 1.2x |
| projection: 3 of 8 cols | 91.68 ms | 80.18 ms | 1.14x |
| filtered agg | 99.62 ms | 90.96 ms | 1.10x |
| storage, all three tables | identical | identical | no change |
| arrow export / import | 929.9 / 16950.9 ms | 923.0 / 16783.5 ms | no change |

Two changes account for most of it. Issue #133 fixed the aggregate path: the
planner had been losing to a parallel scan on cost, and `count(*)` was reading
every column's zone maps and using none of them. Issue #143 step one added the
statement-scoped decoded-group cache, which is what the index-only-scan-off row
measures, since that shape does nothing but fetch rows by number.

Nothing measured got slower.

The absolute ingestion and I/O figures in this document are higher than the
previous run recorded (arrow import 16.8 s against 13.6 s, FSST columnar insert
12.4 s against 9.9 s, cold scans about 38 s against about 30 s). Re-running
`2f1320f` today reproduces today's figures, not the recorded ones, so this is the
machine and not the code. It is the reason for the warning at the top about
comparing ratios rather than milliseconds.

## Reading the results

Columnar wins on analytic shapes: aggregates answered from metadata, filtered
aggregates that minimum, maximum and bloom skipping can prune, wide-table
projections, and index-only covering scans. The size reduction comes mostly from
the encoding layer before zstd. Vectorization adds a large further speedup on
aggregates, and storing a table sorted on its range key improves skipping.

Heap wins on single-row fetches and on deletes, both by wide margins, and the
aggregate advantage disappears on a table with deletes until it is vacuumed.
Columnar is the wrong choice for write-heavy OLTP and the right choice for
scan-heavy and aggregate-heavy analytics over wide, append-mostly tables.
