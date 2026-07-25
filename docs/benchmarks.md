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

The numbers below are one full run, measured 2026-07-25 at commit `2f1320f`:
PostgreSQL 17.10 non-assert, 6,000,000 rows, 8-column table, median of 5. Raw
output is in [../bench/sample_output_pg17_6m.txt](../bench/sample_output_pg17_6m.txt).
They show the shape of the tradeoff, not a precise score. The dataset is synthetic
and deliberately mixes column shapes that suit different encodings, so a table of
purely random values will look worse and a repetitive one better.

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
| count(*) full table | 210.07 | 6.52 | 32.2 |
| sum/avg over one int column | 281.55 | 6.50 | 43.3 |
| filtered agg, min/max-skippable range | 217.54 | 81.74 | 2.7 |
| projection: 3 of 8 cols, 1% filter | 214.04 | 74.78 | 2.9 |
| point lookup by indexed id | 0.01 | 26.77 | 0.00 |

The point lookup is the trade the design makes and does not hide: a single-row
fetch decodes the vector containing the row. Columnar suits scans and aggregates;
heap suits point lookups and write-heavy OLTP.

`count(*)` is answered from row-group metadata rather than by decoding column
data. It is nonetheless slower here than it should be, and slower than this
document previously recorded: see [Known issues](#known-issues-in-these-numbers).

## Feature toggles

Vectorization on versus off (columnar zstd, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| sum/avg over int | 6.35 | 1117.15 | 175.9 |
| filtered agg (range) | 76.99 | 77.89 | 1.01 |

The filtered aggregate is unmoved because that query is dominated by the filter,
not by the aggregate.

Index-only scan on versus off (covering range count, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| covering count, id range (~2%) | 6.11 | 154877.94 | very large |

Read that as "the difference between a viable and an unviable plan" rather than a
25000x speedup of the same work: with the feature off, the alternative is a
per-row fetch, not a slower index scan.

Projection scan on versus off (covering scan on a scattered sort key, median ms):

| query | on | off | speedup |
| --- | --- | --- | --- |
| sortk, val where sortk in ~0.1% range | 169.43 | 531.94 | 3.1 |

Sorted storage (`pgcolumnar.vacuum_sorted`), narrow range scan on a key not
correlated with insert order, median ms:

| state | ms |
| --- | --- |
| before vacuum_sorted | 311.09 |
| after vacuum_sorted | 44.77 |

Compression none versus zstd (columnar table-only): 40 MB versus 5.95 MB, 6.8x,
with scan latency essentially unchanged because the encoded stream is already
small.

## Import and export

Export, 6,000,000 rows, 5 columns:

| format | ms | file size | M rows/s |
| --- | --- | --- | --- |
| arrow | 763.2 | 186 MB | 7.9 |
| parquet | 824.7 | 186 MB | 7.3 |

Import, 6,000,000 rows, 5 columns:

| format | ms | M rows/s |
| --- | --- | --- |
| arrow | 13638.3 | 0.4 |
| parquet | 13569.0 | 0.4 |

Import is about 18x slower than export and is the clearest optimisation target in
the interop path: export writes a prepared buffer, while import goes through the
full insert path including encoding selection and index maintenance.

## String ingestion (FSST)

3,000,000 rows of URL-like strings:

| | |
| --- | --- |
| heap INSERT | 1.54 s |
| columnar INSERT | 9.94 s |
| heap size | 419 MB |
| columnar size | 101 MB |
| vectors using FSST | 20 of 20 |
| round trip | exact match |

FSST is chosen for every vector of the URL column and gives 4.1x on size, paid for
with 6.5x on ingestion time. That ratio is why encoding selection is worth
optimising, and why choosing candidates from a sample rather than applying all of
them (`pgcolumnar.encoding_sample_rows`) measured 1.33x faster loads with
byte-identical output.

## Read stream and asynchronous IO

Cold-scan latency on the PostgreSQL 18 io_uring build, median of 3, caches dropped
between runs:

| io_method | read stream on | off | gain |
| --- | --- | --- | --- |
| `sync` | 30.89 s | 30.94 s | 1.00x |
| `worker` | 29.70 s | 30.51 s | 1.03x |
| `io_uring` | 29.20 s | 30.18 s | 1.03x |

Across methods with the read stream on: `worker` 1.04x and `io_uring` 1.06x
against `sync`.

These are small, and the honest reading is that this workload is not I/O-bound in
the way prefetching helps most: the columnar layout already reads few, large,
sequential regions. The feature costs nothing and helps slightly. It is not a
headline.

## Cross-engine read

DuckDB over the same data (`BENCH_DUCKDB=1`), as a sanity check on order of
magnitude rather than a competitive claim:

| query | DuckDB | pgColumnar |
| --- | --- | --- |
| count(*) | 1 ms | 6.52 ms |
| sum/avg over int | 3 ms | 6.50 ms |

Same order of magnitude, DuckDB ahead. It is a purpose-built analytical engine
with no PostgreSQL executor or MVCC visibility work in the path.

## Known issues in these numbers

`count(*)` is **slower than this document previously recorded at the same scale**:
0.03 ms then, 6.52 ms now. Two causes, tracked as issue #133:

- `pgcolumnar.enable_metadata_count` is registered as a GUC but never read. The
  dedicated catalog-level shortcut went with the format 2.2 removal in Phase H2
  and the knob stayed behind, so the setting documents behaviour it no longer
  controls.
- With parallelism at its default the planner prefers a parallel scan over the
  columnar aggregate path. Setting `max_parallel_workers_per_gather = 0` gives
  about 1.75 ms instead of 6.52 ms.

Results are correct either way; the cost is performance and a misleading setting.
The projection query is also somewhat slower than previously recorded (74.78 ms
against 48.00 ms) and may be the same effect.

Everything else moved the other way over the same period: table-only size fell
from 81 MB to 40 MB uncompressed and 48 MB to 5.95 MB with zstd, and the sum/avg
aggregate fell from 142.34 ms to 6.50 ms.

## Reading the results

Columnar wins on analytic shapes: aggregates, filtered aggregates that minimum,
maximum and bloom skipping can prune, wide-table projections, and index-only
covering scans. The size reduction comes mostly from the encoding layer before
zstd. Vectorization adds a large further speedup on aggregates, and storing a
table sorted on its range key improves skipping. Heap wins on a single-row index
fetch. Columnar is the wrong choice for write-heavy OLTP and the right choice for
scan-heavy and aggregate-heavy analytics over wide, append-mostly tables.
