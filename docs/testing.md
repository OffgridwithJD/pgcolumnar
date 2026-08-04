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
test/phase6.sh  /path/to/pg_config   # aggregate correctness
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
  the `ColumnarDeleteVectorBufferedDeleted` nested scan this way. The shape is
  real. The measured cost is linear and not quadratic. The obvious cache made it
  slower.

`docs/limitations.md` is for the items that are out of scope, or that an external
constraint blocks. An extension cannot change WAL behaviour. PostgreSQL 13 and
14 lack an API. It is not a parking space. Anything in it that is unfixed only
because nobody has fixed it does not belong there.

When a fix lands, sweep the docs in the same change. `ANALYZE` collecting no
statistics sat in `limitations.md` as a limitation after the implementation had
already merged, which is worse than either state alone.

## Differential oracle

`test/differential.sh`, `recovery`, `fuzz`, `hardening`, and `concurrent_diff`
share `test/lib.sh`. It is a differential oracle that compares heap with
columnar. A query runs against a heap mirror and against the columnar table. The
harness compares the two results as a result-set hash that does not depend on
row order. Heap is therefore the oracle for correctness.

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

The per-PR gate runs the suites on two majors. This is the correct trade for test
time. But the gate cannot see a defect on a major that it never builds. An
example: `scan_analyze_next_block` changed signature at PG17. A change guarded
the callback at PG18 instead. PG15, PG16, PG18 and PG19 all built. `main` did not
compile on PG17 at all, and a two-major gate still reported it green. This check
catches that in a minute. The full matrix remains the thorough answer.

Do not leave a branch broken on a supported major while a fix is pending. Land
the fix.

## The version matrix

The matrix helper builds and runs every suite across a set of PostgreSQL majors
in one pass. Each major gets its own new build directory. Give the helper the
`pg_config` path of each major. With no arguments it uses PostgreSQL 15 through 19:

```sh
test/run_all_versions.sh /usr/local/pg15/bin/pg_config ... /usr/local/pg19/bin/pg_config
```

All suites pass on PostgreSQL 15 through 19. PostgreSQL 19 is validated against
19beta2; revalidation against the final PostgreSQL 19 release is pending that
release.

## Cross-major upgrade

`pg_upgrade` is the path that a user takes to a new major. It is also the point
where an access method with its own catalog is most likely to fail. The relation
forks carry the data. The `pgcolumnar.*` tables carry the metadata. Both must
survive the transfer, and the new side must have the extension. `test/pg_upgrade.sh` runs it
and asserts the rows, the content hash, the access method and the per-table
options all come across.

It needs two majors at the same time and runs the upgrade two times for each
pair. It is therefore not part of the per-PR gate, and it is off by default. Ask for it:

```sh
PGC_RUN_UPGRADE=1 test/run_all_versions.sh
```

That runs each adjacent pair of the majors being tested, in both transfer modes.
`link` shares the data files with the old cluster and `copy` does not, and they
fail differently, so both are run. A single pair can also be run directly:

```sh
test/pg_upgrade.sh /usr/local/pg17/bin/pg_config /usr/local/pg18/bin/pg_config link
```

Run it before a release. `docs/limitations.md` makes a claim: data that one build
writes reads back identically on any build of the same format version, on each
supported major. This suite is the only thing that tests that claim. It is opt-in
rather than per-PR because of its cost, and not because it is optional. A claim
in the documentation with only a suite that nobody runs behind it is how coverage
becomes stale without notice.

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
which code does nothing execute at all. Read it for the gaps and not for the percentage. Expect the percentage to be
low in some places where the code is correct. A table access method carries
defensive branches that should never run. `columnar_compat.h` carries version
shims, and only one arm of each shim compiles for a given major.
## Continuous integration

Three workflows run in GitHub Actions.

**On every pull request and push to `main`** (`.github/workflows/ci.yml`): a
build against PostgreSQL 15, 16, 17 and 18, on x86_64 and on aarch64. There is
also a build against the PostgreSQL 19 beta, from source. Each build treats a
compiler warning as a failure. The suites run on 17 and 18. The build preflight
catches an API change between majors. The suite run catches a change in
behaviour.

**Nightly at 06:00 UTC** (`.github/workflows/nightly.yml`): the full packaged
suite matrix across 15 to 18 on x86_64, and the current major on aarch64. The
nightly run also includes the ASAN and UBSAN sanitizer gate, against an
instrumented PostgreSQL, and the coverage report. The sanitizer build stays in a cache, because it takes longer to build
than to run the suites against it.

The aarch64 run executes the suites rather than only building them. Misaligned
reads, the class most often expected to differ by architecture, are already
reported by the sanitizer gate on any host. A second architecture adds what a sanitizer on
x86_64 cannot see. x86_64 puts stores in a more strict order than aarch64. Thus a
missing barrier in concurrent code can be invisible on one architecture and a
defect on the other. The suites that would show it must run.

**On documentation changes** (`.github/workflows/docs.yml`): builds and publishes
the site at
[commandprompt.github.io/pgcolumnar](https://commandprompt.github.io/pgcolumnar/).

PostgreSQL 19 cannot be installed in CI: PGDG does not package it in stable,
testing or snapshot. It is compiled there anyway, from source, and the build stays
in a cache. To be unable to install a major is not a reason to stop compiling
against it. The newest major is also where header and API tightening lands.

That distinction was not free. A set-returning function used
`tuplestore_begin_heap` without including `utils/tuplestore.h`, which arrives
transitively behind `funcapi.h` through PostgreSQL 18 and does not on 19. It compiled on each major that CI could install. It failed only on
the one that CI could not install. A green CI run therefore sat on a tree that did
not build. The local matrix caught it
before merge; nothing in CI would have.

The suites on 19 remain local. The five-major matrix covers them and stays the
release gate.

Two suites do not run in CI and run locally instead. The first is the cross-major
upgrade gate above. The second is the set of timing suites, because a shared
runner cannot hold their wall-clock ratios steady. Skipping them there is a deliberate trade. A gate that goes red for
reasons unrelated to the change teaches its readers to discount red, which is
worse than not running it.

## Stopping a run

The matrix runs itself again from a private copy in `/tmp`, and it runs its
suites as background jobs. A signal that you send by pattern therefore does not
reach the correct process. It also leaves the suites running, and they keep their
clusters and their ports. Use:

```sh
test/run_all_versions.sh --stop
```

That reads the run lock, signals the owner, and lets it stop the suites and then
their clusters through `pg_ctl`. It also clears a lock left by a run that is no
longer alive. Interrupting a run with Ctrl-C does the same cleanup.

## Documentation style

The user-facing documentation follows the ASD-STE100 writing rules. These are:

- one topic to a sentence
- active voice
- present tense
- articles kept
- no gerund used as a noun
- one term for one thing
- no idiom
 `test/docs_style.sh` checks
the rules that a machine can check. It runs in the matrix, so a document that
drifts goes red.

```sh
test/docs_style.sh
```

It enforces four rules over `docs/*.md` and `README.md`:

- no em dash and no en dash
- no double hyphen used as a dash in prose
- a maximum of 25 words to a sentence
- no phrase from an idiom list

`CHANGELOG.md` is a record of what happened at the time it happened. To rewrite a
landed entry would edit history. The gate therefore checks it for dash characters
only.

**Full ASD-STE100 compliance is not claimed.** Compliance is defined against the
licensed ASD Dictionary. That dictionary holds approximately 900 approved words.
Each word has one approved meaning and one part of speech. That dictionary is not available to this
project, so the approved-vocabulary rule is not enforced and is not claimed. An
unverifiable claim of compliance would be worse than an honest partial one.

`design/` holds internal engineering records and is not checked. Code comments
are not checked either. Both exist to explain why a thing is the way it is, and
that reasoning is worth more than the uniformity would be.
