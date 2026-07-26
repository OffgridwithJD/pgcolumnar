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
commit `1be027b`: PostgreSQL 17.10 non-assert (18.4 with io_uring for the read
stream harness), 6,000,000 rows, 8-column table, median of 5, on 8 cores with
24 GB of memory. Raw output is in
[../bench/sample_output_pg17_6m.txt](../bench/sample_output_pg17_6m.txt). They
show the shape of the tradeoff, not a precise score. The dataset is synthetic and
deliberately mixes column shapes that suit different encodings, so a table of
purely random values will look worse and a repetitive one better.

One change landed after these were measured and is not reflected in them: #160
made the zone min/max tracking on the write path 5 to 7% faster, so every
ingestion figure here (loads, imports, the FSST insert) is a floor rather than
what the current tree does. Query latency and storage are unaffected.

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
| count(*) full table | 251.34 | 0.02 | 12567 |
| sum/avg over one int column | 354.96 | 0.53 | 670 |
| filtered agg, min/max-skippable range | 263.62 | 92.35 | 2.85 |
| projection: 3 of 8 cols, 1% filter | 264.94 | 81.58 | 3.25 |
| point lookup by indexed id | 0.01 | 23.75 | 0.00 |

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
| no deletes | 0.02 ms | 0.32 ms | 0.32 ms |
| after deleting 1 row of 6,000,000 | 0.18 ms | 6.87 ms | 8.44 ms |
| after `pgcolumnar.vacuum` | 0.02 ms | 0.31 ms | 0.31 ms |

The fallback is per row group, so a delete costs only the groups it touches: the
39 clean groups still fold from their zone maps and only the dirty one is read,
which is why `sum/avg` costs one group's scan rather than forty. `count(*)` barely
moves at all, because a group's live count is exactly its row count minus its
deleted count and needs no data either way.

This used to be storage-wide, and one deleted row put `count(*)` at 222 ms and
`min/max` at 317 ms instead of the figures above
([issue #149](https://github.com/jdatcmd/pgcolumnar/issues/149), fixed). Vacuuming
still helps, since it returns the dirty group to the clean path.

## Mutation

Rows reached by index, on a 1,000,000-row copy, median of 5 for the updates and a
single run for the delete:

| operation | heap | columnar | columnar / heap |
| --- | --- | --- | --- |
| UPDATE single row by id | 0.02 ms | 0.22 ms | 11 |
| UPDATE 1000 rows, ids in row order | 3.76 ms | 20.78 ms | 5.5 |
| UPDATE 1000 rows, ids scattered | 44.07 ms | 146.07 ms | 3.3 |
| DELETE 1000 rows by id range | 0.5 ms | 22.8 ms | 46 |

Row-ordered access does better than scattered because consecutive fetches stay
inside one row group, which the statement-scoped decoded-group cache serves
without re-decoding.

The delete figure was the weakest number in this document at 1509 ms, when
reaching a row still meant walking to it through every earlier row in its group.
Both halves of [issue #143](https://github.com/jdatcmd/pgcolumnar/issues/143) are
now in: the group is decoded once and cached, and a row's value is reached by rank
rather than by walking. Deleting 1000 rows costs 22.8 ms rather than 1509.

## Feature toggles

Vectorization on versus off (columnar zstd, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| sum/avg over int | 0.51 | 1352.10 | 2651 |
| filtered agg (range) | 87.51 | 86.53 | 0.99 |

Index-only scan on versus off (covering range count, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| covering count, id range (~2%) | 7.24 | 689.21 | 95 |

The "off" column is the fetch-by-row path doing nothing else, which makes it the
clearest single view of what that path costs, and the clearest measure of what
#143 changed: this shape was 200.9 s before the decoded-group cache, 31.8 s after
it, and 0.69 s once the walk to the row went too.

Projection scan on versus off (covering scan on a scattered sort key, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| sortk, val where sortk in ~0.1% range | 201.16 | 646.43 | 3.21 |

Sorted storage (`pgcolumnar.vacuum_sorted`), narrow range scan on a key not
correlated with insert order, median ms:

| state | ms |
| --- | --- |
| before vacuum_sorted | 348.79 |
| after vacuum_sorted | 45.47 |

Compression none versus zstd (columnar table-only): 40 MB versus 5.95 MB, with
scan latency unchanged (0.50 ms against 0.49 ms), because the encoded stream is
already small and the aggregates do not read it.

## Import and export

Export, 6,000,000 rows, 5 columns:

| format | ms | file size | M rows/s |
| --- | --- | --- | --- |
| arrow | 1029.3 | 186 MB | 5.8 |
| parquet | 1113.7 | 186 MB | 5.4 |

Import, 6,000,000 rows, 5 columns:

| format | ms | M rows/s |
| --- | --- | --- |
| arrow | 18533.2 | 0.3 |
| parquet | 18746.0 | 0.3 |

Import is about 18x slower than export, and the reason is not the import code.
Measured separately: `import_arrow` costs 12,150 ms against 12,990 ms for an
`INSERT INTO ... SELECT` of the same rows with no file involved, so there is no
import-specific overhead. Reading the whole Parquet file through `read_parquet`
costs 1,415 ms, 11% of the import. The other 89% is the write path, which is also
4.9x slower than a heap insert of the same rows.

So the target is bulk load in general rather than the interop path: both readers
decode a column-oriented file into per-row values, and the writer copies them back
into per-column buffers. Tracked as
[issue #155](https://github.com/jdatcmd/pgcolumnar/issues/155) with a plan in
`design/IMPORT_THROUGHPUT_PLAN.md`.

Index maintenance is not in this path at all, which is a correctness bug rather
than a cost: see [issue #153](https://github.com/jdatcmd/pgcolumnar/issues/153).

Nested round-trip, 1,000,000 rows, one `int[3]` array column and one composite
column:

| format | export ms | import ms | file size |
| --- | --- | --- | --- |
| arrow | 580.0 | 4914.0 | 38 MB |
| parquet | 533.4 | 4923.5 | 35 MB |

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
fixed, and two further changes landed while this run was being written up. To
measure honestly rather than compare across machines and days, the same harness
was run on this machine on this day at each commit:

| metric | 2f1320f | f7adbdb | 1be027b | |
| --- | --- | --- | --- | --- |
| count(*) | 8.27 ms | 0.02 ms | 0.02 ms | 413x |
| sum/avg over int | 8.04 ms | 0.53 ms | 0.53 ms | 15x |
| covering count, index-only scan off | 200914.88 ms | 31845.77 ms | 689.21 ms | 291x |
| DELETE 1000 rows by id range | not measured | 1509.5 ms | 22.8 ms | 66x |
| count(*) with one row deleted | not measured | 222.28 ms | 0.18 ms | 1235x |
| point lookup by id | 32.96 ms | 26.75 ms | 23.75 ms | 1.4x |
| projection: 3 of 8 cols | 91.68 ms | 80.18 ms | 81.58 ms | 1.12x |
| storage, all three tables | identical | identical | identical | no change |

Four changes account for it:

- **#133** fixed the aggregate path. The planner had been losing to a parallel
  scan on cost, and `count(*)` was reading every column's zone maps and using none
  of them.
- **#148** cached the decoded row group for the length of a statement, so
  fetching many rows from one group decodes it once.
- **#152** replaced the walk to a row's position with a rank lookup, which is what
  takes the index-only-scan-off shape from 31.8 s to 0.69 s and the delete from
  1509 ms to 23 ms. Together with #148 that is issue #143 closed: the path is no
  longer quadratic in the rows touched per group.
- **#151** made the delete fallback per row group instead of per storage, so one
  deleted row no longer costs the whole table its metadata answers.

Nothing measured got slower.

The absolute ingestion and I/O figures in this document are higher than the
previous run recorded (arrow import 18.5 s against 13.6 s, cold scans about 38 s
against about 30 s), and they moved again between the two runs on this same day
(arrow export 923 ms then 1029 ms) without any code touching that path.
Re-running `2f1320f` today reproduces today's figures rather than the recorded
ones, so this is the machine. It is the reason for the warning at the top about
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
