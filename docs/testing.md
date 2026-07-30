# Testing

The test suite builds and installs the extension, starts a throwaway cluster,
exercises the access method, and checks results. Each script takes a `pg_config`
and is self-contained:

```sh
test/smoke.sh   /path/to/pg_config   # create, insert, scan, drop
test/phase2.sh  /path/to/pg_config   # compression, projection, min/max skip, filter
test/phase3.sh  /path/to/pg_config   # delete, update, MVCC, savepoints, temp tables
test/phase4.sh  /path/to/pg_config   # btree/hash indexes, constraints, conversion
test/phase5.sh  /path/to/pg_config   # custom scan, pushdown, options, vacuum
test/phase6.sh  /path/to/pg_config   # aggregate correctness and the column cache
test/audit.sh   /path/to/pg_config   # regression tests for audited defects
test/concurrency.sh      /path/to/pg_config  # concurrent same-chunk-group deletes
test/unique_conc.sh      /path/to/pg_config  # concurrent same-unique-key inserts
test/differential.sh     /path/to/pg_config  # heap-vs-columnar oracle
test/recovery.sh         /path/to/pg_config  # crash recovery and atomicity
test/fuzz.sh             /path/to/pg_config  # seeded randomized differential
test/hardening.sh        /path/to/pg_config  # corrupt-input robustness (native catalogs)
test/concurrent_diff.sh  /path/to/pg_config  # concurrent DML vs a heap oracle
test/parallel.sh         /path/to/pg_config  # parallel scan plan and results vs a heap oracle
test/sorted_projection.sh /path/to/pg_config # pgcolumnar.vacuum_sorted results and skipping
test/index_only.sh       /path/to/pg_config  # index-only scan and the visibility-map fork
test/projections.sh      /path/to/pg_config  # multiple projections and projection scan
test/arrow_export.sh     /path/to/pg_config  # Arrow IPC export read back with pyarrow
test/parquet_export.sh   /path/to/pg_config  # Parquet export read back with pyarrow and DuckDB
test/arrow_import.sh     /path/to/pg_config  # Arrow IPC import
test/parquet_import.sh   /path/to/pg_config  # Parquet import
test/arrow_nested.sh     /path/to/pg_config  # nested Arrow export
test/parquet_nested.sh   /path/to/pg_config  # nested Parquet export
test/arrow_nested_import.sh   /path/to/pg_config  # nested Arrow import
test/parquet_nested_import.sh /path/to/pg_config  # nested Parquet import
test/native_parquet_schema.sh    /path/to/pg_config  # parquet_schema type inference
test/native_read_parquet.sh      /path/to/pg_config  # read_parquet in place
test/native_parquet_fdw.sh       /path/to/pg_config  # pgcolumnar_parquet foreign tables
test/native_parquet_pushdown.sh  /path/to/pg_config  # FDW row-group predicate skipping
test/native_parquet_projection.sh /path/to/pg_config # FDW column projection pushdown
test/native_parquet_units.sh     /path/to/pg_config  # TIME/TIMESTAMP unit handling
test/native_parquet_flba.sh      /path/to/pg_config  # uuid, decimal, fixed binary reads
test/native_parquet_codecs.sh    /path/to/pg_config  # GZIP, ZSTD, LZ4_RAW page reads
test/native_parquet_hardening.sh /path/to/pg_config  # crafted-file decode guards
test/native_parquet_multifile.sh /path/to/pg_config  # directory and glob reads
test/native_parquet_streaming.sh /path/to/pg_config  # page-at-a-time reads, page guards
test/native_parquet_partition.sh /path/to/pg_config  # Hive partition columns and pruning
test/native_cancel.sh    /path/to/pg_config  # scan cancellation during a group load
test/wal_envelope.sh     /path/to/pg_config  # WAL discipline: core mechanisms only
test/decode_interrupts.sh /path/to/pg_config  # decode path stays interruptible
test/native_fetch_cache.sh /path/to/pg_config # fetch-by-row-number group cache
test/native_fetch_position.sh /path/to/pg_config # reaching a fetched row without walking
test/native_writer.sh    /path/to/pg_config  # native format catalog output
test/native_roundtrip.sh /path/to/pg_config  # native write then read round-trip
test/native_encoding.sh  /path/to/pg_config  # native per-vector encoding cascade
test/native_zonemap.sh   /path/to/pg_config  # native zone maps
test/write_minmax_fastpath.sh /path/to/pg_config # direct zone min/max comparison
test/native_skip.sh      /path/to/pg_config  # native chunk and vector skipping
test/native_agg.sh       /path/to/pg_config  # native aggregate paths
test/native_agg_deletes.sh /path/to/pg_config  # per-row-group fold when rows are deleted
test/native_bloom.sh     /path/to/pg_config  # native per-chunk bloom filters
test/native_vecskip.sh   /path/to/pg_config  # native per-vector skipping
test/native_index.sh     /path/to/pg_config  # native index and index scan
test/native_dml.sh       /path/to/pg_config  # native delete and update
test/native_ios.sh       /path/to/pg_config  # native index-only scan
test/native_projection.sh /path/to/pg_config # native projections
```

## Defects are fixed, not documented

A limitation written into the documentation stops looking like a defect. It reads
as a design choice, people plan around it, and nobody reopens it. So a defect is
resolved one of two ways, and writing it down is neither:

- **Fix it.** Filing an issue is tracking, not resolving; an issue with no change
  behind it is a defect the project has decided to keep.
- **Or measure it and show it is not a defect**, then record the numbers so the
  next person does not re-litigate it. `design/EXTERNAL_AUDIT_2026_07.md` closes
  the `ColumnarDeleteVectorBufferedDeleted` nested scan this way: the shape is
  real, the cost measured linear rather than quadratic, and adding the obvious
  cache made it slower.

`docs/limitations.md` is for what is genuinely out of scope or blocked by an
external constraint: an extension cannot change WAL behaviour, PostgreSQL 13 and
14 lack an API. It is not a parking space. Anything in it that is unfixed only
because nobody has fixed it does not belong there.

When a fix lands, sweep the docs in the same change. `ANALYZE` collecting no
statistics sat in `limitations.md` as a limitation after the implementation had
already merged, which is worse than either state alone.

## Differential oracle

`test/differential.sh`, `recovery`, `fuzz`, `hardening`, and `concurrent_diff`
share `test/lib.sh`, a heap-versus-columnar differential oracle: a query runs
against a heap mirror and the columnar table, and the results are compared as an
order-independent result-set hash, so heap is the correctness oracle.

`test/pbt/run.sh` is a separate, PostgreSQL-independent C property test of the
value-stream codecs (round-trip over randomized and boundary inputs):

```sh
test/pbt/run.sh [seed] [iterations]
```

## Before merging: build every major

```sh
test/build_all_versions.sh
```

No clusters and no suites, only a compile against each installed major, about a
minute for all five. Run it before merging anything that touches a version guard,
a table access method callback signature, or `columnar_compat.h`.

The per-PR gate runs the suites on two majors, which is the right trade for test
time and structurally cannot see a defect on a major it never builds.
`scan_analyze_next_block` changed signature at PG17; a change guarded the
callback at PG18 instead; PG15, PG16, PG18 and PG19 all built, and `main` did not
compile on PG17 at all while a two-major gate reported it green. This check
catches that in a minute. The full matrix remains the thorough answer.

Do not leave a branch broken on a supported major while a fix is pending. Land
the fix.

## The version matrix

To build and run every suite across a set of PostgreSQL majors in one pass, each
in its own fresh build directory, pass their `pg_config` paths to the matrix
helper. With no arguments it uses PostgreSQL 15 through 19:

```sh
test/run_all_versions.sh /usr/local/pg15/bin/pg_config ... /usr/local/pg19/bin/pg_config
```

All suites pass on PostgreSQL 15 through 19. PostgreSQL 19 is validated against
19beta2; revalidation against the final PostgreSQL 19 release is pending that
release.

## Cross-major upgrade

`pg_upgrade` is the path a user takes to a new major, and it is where an access
method with its own catalog is most likely to break: the relation forks carry the
data, the `pgcolumnar.*` tables carry the metadata, and both have to survive the
transfer with the extension present on the new side. `test/pg_upgrade.sh` runs it
and asserts the rows, the content hash, the access method and the per-table
options all come across.

It takes two majors at once and runs the upgrade twice per pair, so it is not part
of the per-PR gate and not on by default. Ask for it:

```sh
PGC_RUN_UPGRADE=1 test/run_all_versions.sh
```

That runs each adjacent pair of the majors being tested, in both transfer modes.
`link` shares the data files with the old cluster and `copy` does not, and they
fail differently, so both are run. A single pair can also be run directly:

```sh
test/pg_upgrade.sh /usr/local/pg17/bin/pg_config /usr/local/pg18/bin/pg_config link
```

Run it before a release. `docs/limitations.md` states that data written by one
build reads back identically on any build of the same format version, across every
supported major, and this is the only thing that tests that claim. It is opt-in
rather than per-PR for cost, not because it is optional: a claim in the
documentation backed by a suite nobody runs is how coverage rots unnoticed.

## make installcheck

The conventional entry point for a PostgreSQL extension:

```sh
make installcheck PG_CONFIG=/path/to/pg_config
```

It runs `sql/pgcolumnar.sql` against `expected/pgcolumnar.out`, then the seven
isolation specs under `test/isolation/specs`. The target server must have
`pgcolumnar` in `shared_preload_libraries`; without it the `CREATE EXTENSION` in
the test fails, which is the correct outcome.

This is a smoke test, not the gate. It compares a columnar table against a heap
mirror across the main paths and confirms the race specs still hold. The gate is
the version matrix above, which asserts properties with explicit controls rather
than comparing output to a recorded file. Expected-output tests are kept
deliberately thin here: their failure mode is to regenerate the expected file,
which converts a defect into a new baseline.

## Coverage

```sh
test/run_coverage.sh /path/to/pg_config
```

Builds instrumented, runs the suites against that build, and writes an HTML
report to `coverage/html`. It runs nightly and uploads the report as an artifact.

There is no threshold and nothing fails on the number, deliberately. A coverage
threshold creates pressure to write tests that execute lines rather than tests
that prove properties. The report answers the question a passing suite cannot:
which code does nothing execute at all. Read it for holes rather than for the
percentage, and expect the percentage to be unremarkable in places that are
correct: a table access method carries defensive branches that should never be
taken, and `columnar_compat.h` carries version shims of which one arm compiles per
major.
## Continuous integration

Three workflows run in GitHub Actions.

**On every pull request and push to `main`** (`.github/workflows/ci.yml`): a build
against PostgreSQL 15, 16, 17 and 18 on both x86_64 and aarch64, treating compiler
warnings as failures, and the suites on 17 and 18. The build preflight is what
catches an API change between majors; the suite run is what catches a behaviour
change.

**Nightly at 06:00 UTC** (`.github/workflows/nightly.yml`): the full packaged
suite matrix across 15 to 18 on x86_64, the current major on aarch64, the ASAN and
UBSAN sanitizer gate against an instrumented PostgreSQL, and the coverage report.
The sanitizer build is cached, since building it takes longer than running the
suites against it.

The aarch64 run executes the suites rather than only building them. Misaligned
reads, the class most often expected to differ by architecture, are already
reported by the sanitizer gate on any host. What a second architecture adds is
what a sanitizer on x86_64 cannot observe: x86_64 orders stores more strictly than
aarch64, so a missing barrier in concurrent code can be invisible on one and a
defect on the other, and the suites that would show it have to run.

**On documentation changes** (`.github/workflows/docs.yml`): builds and publishes
the site at
[jdatcmd.github.io/pgcolumnar](https://jdatcmd.github.io/pgcolumnar/).

PostgreSQL 19 is deliberately absent from CI. It is beta and not packaged in PGDG
stable, so CI cannot install it honestly. The local five-major matrix covers it,
and remains the release gate.

Two suites are not reachable from CI and are run locally: the cross-major upgrade
gate above, and the timing suites, whose wall-clock ratios a shared runner cannot
hold still. Skipping them there is a deliberate trade. A gate that goes red for
reasons unrelated to the change teaches its readers to discount red, which is
worse than not running it.

## Stopping a run

The matrix re-executes itself from a private copy in `/tmp` and runs its suites as
background jobs, so signalling it by pattern does not reach the right process and
leaves the suites running with their clusters and ports held. Use:

```sh
test/run_all_versions.sh --stop
```

That reads the run lock, signals the owner, and lets it stop the suites and then
their clusters through `pg_ctl`. It also clears a lock left by a run that is no
longer alive. Interrupting a run with Ctrl-C does the same cleanup.
