# CONTEXT

Orientation for anyone, human or agent, working in this repository. It is the
vocabulary and the house rules, not the status. Read it before naming a
function, a test, or an EXPLAIN line, so that new code says the same words the
existing code says.

Three documents outrank this one where they overlap, and each owns a different
question:

| document | owns |
| --- | --- |
| `design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md` | what the format and the interface ARE |
| `HANDOFF.md` | what has happened, what is in flight, what to pick up |
| `design/ROADMAP.md` | what is planned |

This file owns the words.

## What this is

pgColumnar is a columnar storage table access method for PostgreSQL, written as
a clean-room MIT-licensed implementation. It reads and writes its own native
format, PGCN v1. The extension, the schema, and the access method are all named
`pgcolumnar`; a table is created `USING pgcolumnar` after
`CREATE EXTENSION pgcolumnar`. The clean-room record is `PROVENANCE.md`.

It is an extension, and that is a hard constraint rather than a description.
**Only core WAL mechanisms and existing record types are available.** A design
that needs new WAL semantics is rejected, not deferred.

## The storage vocabulary

Section 2 of the spec is authoritative. The short form:

- **Storage id**: 64-bit identifier tying a relation to its columnar storage and
  its catalog rows. Most metadata is keyed by it.
- **Row group**: a horizontal partition holding up to a configured number of rows
  across all columns. A relation is a sequence of row groups. It is the write
  unit and the parallel-scan unit.
- **Column chunk**: one column's data within one row group.
- **Vector**: a fixed run of 1024 values inside a column chunk. The unit of
  decode, of data skipping, and of vectorized execution.
- **Page**: the on-disk container of one column chunk's encoded vectors. A
  contiguous byte range in the relation's main fork, which is why the buffer
  manager, WAL, and page checksums apply.
- **Zone map**: the Small Materialized Aggregate for a vector or a column chunk.
  Minimum, maximum, null count, value count.
- **Delete vector**: the per-row-group bitmap that makes a delete a metadata
  write rather than a rewrite. Reads merge it (merge-on-read).
- **Projection**: a secondary physical ordering of a subset of columns, with its
  own storage, that the planner may scan instead of the base relation.
- **Row number**: a 1-based logical position of a row within a relation, stable
  for the life of the row, mapped to a synthetic item pointer for the executor
  and for indexes.

## Words that do not line up, and will mislead you

These are measured, not remembered. Each one has cost somebody time.

**A stripe is a row group.** The spec says row group. The GUC, the per-table
option, and the older code say `stripe`: `pgcolumnar.stripe_row_limit`, default
150000, is "maximum number of rows per stripe" and it is what sets the row-group
size. The spec's intended `row_group_limit` (target 122880, a multiple of the
1024 vector length) is the newer name for the same thing. Both appear in the
tree. Prefer "row group" in new prose; do not rename the option casually,
because it is user-facing and it is in dumps.

**`chunk_group_row_limit` is a different setting and does not control the group
counters.** It is "maximum number of rows per chunk group", default 10000, from
the 1.0-dev lineage. Setting it does not change how many groups a scan reports.

**EXPLAIN's "Chunk Groups" counters count ROW GROUPS.** This is the one most
likely to produce a wrong conclusion, so it is worth stating plainly.
`Columnar Chunk Groups Total`, `Read`, and `Removed by Filter` are incremented
per `NativeRowGroupMetadata` as the scan walks `rowGroupIndex`
(`src/columnar_reader.c`, around the `groupsRead++` and `groupsSkipped++`
lines). Measured: 200,000 rows at the default `stripe_row_limit` report 2 groups
whatever `chunk_group_row_limit` is set to, and report 20 at
`stripe_row_limit => 10000`. If you want a fixture with many groups to prune,
set `stripe_row_limit`.

**"Pushed-Down Filters" and "Usable Skip Predicates" are not the same number.**
`Columnar Pushed-Down Filters` counts the scan keys the scan was HANDED.
`Columnar Usable Skip Predicates` counts the ones the reader built a predicate
from and can actually exclude a row group with. A filter can be pushed down and
still exclude nothing, which is what #477 was and what #479 made visible. Read
them together with `Chunk Groups Removed by Filter`. The second needs `ANALYZE`,
because it describes the run rather than the plan.

## Naming in the code

- **`PgColumnar*`**, CamelCase, for anything with external linkage. Example:
  `PgColumnarBeginRead`, `PgColumnarReadStats`.
- **`pgcolumnar_*`**, lower snake case, for file-static functions, for global
  variables backing GUCs, and for the GUCs and SQL functions themselves. Example:
  `pgcolumnar_make_predicates`, `pgcolumnar_enable_qual_pushdown`.
- Source lives in `src/columnar_<area>.c`. The areas worth knowing first:
  `columnar_tableam.c` (the AM callbacks and every GUC definition),
  `columnar_reader.c` (scan, skipping, predicates), `columnar_write_state.c`
  (the write path and encoding selection), `columnar_customscan.c` (the scalar
  custom scan, its costing and its EXPLAIN), `columnar_vector.c` (the two
  vectorized aggregate nodes), `columnar_metadata.c` (the catalog).
- Everything user-facing is in the `pgcolumnar` schema: `pgcolumnar.analyze()`,
  `pgcolumnar.cluster()`, `pgcolumnar.set_options()`, `pgcolumnar.vacuum()`,
  `pgcolumnar.read_parquet()`, and so on. Prefer standard SQL where standard SQL
  exists; a function is for what SQL cannot say.

## Tests

A **suite** is `test/<name>.sh`. It stands up its own cluster, runs **checks**,
and ends with `pgc_summary`.

- Register every suite in `SUITES` in `test/run_all_versions.sh`. That array is
  **one name per line and sorted**; insert in sorted position, never at the end.
  `harness_selftest` fails if the order decays.
- Count suites by asking the runner, never by parsing the source:
  `bash test/run_all_versions.sh --list-suites | wc -l`. It is 132 today. A text
  parser over the array disagrees with bash on exactly the mistake this invites,
  and the disagreement is silent.
- Assertions: `check` (string equality), `check_num`, `check_text` (for hashes
  and other things `check_num` must refuse), `check_ratio`, `check_timing`.
  `check "" ""` passes, which is why the helpers refuse empty sides.
- **A skip is exit 66** (`PGC_EXIT_SKIPPED`). Use `pgc_skip` only for a missing
  DEPENDENCY, which fails by default so that somebody installs the thing. For an
  old major that lacks a core feature, `echo "SKIP ..."` then `pgc_summary` with
  zero checks, and assert the major is a number first.

## How a test is expected to argue here

This is the part that distinguishes this repository, and it exists because every
expensive mistake in its history was a check that looked like it passed rather
than a wrong algorithm.

- **Assert the premise.** Before comparing two numbers, assert the fact that
  makes the comparison mean something: that the fixture has the rows, that the
  planner chose the node under test, that pruning actually happened. A suite that
  asserts a derived relation without asserting the physical fact underneath it
  can stay green for its whole life while measuring nothing. `zonemap_cost`
  priced pruning correctly for a year while pruning zero groups.
- **Prove the guard by removal.** A test proves nothing until it has been seen to
  fail with that specific guard removed. Fingerprint the installed `.so` when you
  do it, because a shared install prefix will happily let the "before" run be the
  fixed binary.
- **A removal proof must fail for the STATED reason.** That a check can fail is
  not evidence that it fails for the reason claimed. Read the failure text.
- **Never gate on luck.** A premise that requires a random sample to miss, or
  core to be unlucky, will fail eventually and will blame innocent code (#487).
  Restate it as arithmetic, or print it as an observation.
- **Pin known-wrong behaviour as an assertion, never as an echo.** Nobody reads a
  passing suite's output. Pinned as an assertion, the fix turns the suite red and
  forces the expectation to be updated deliberately.
- **Never pipe a captured string into a reader whose exit status is your answer**
  (#486). Under `pipefail` it reports "not found" whenever the writer fails.
  Use `case` for a fixed string, or `grep -q PATTERN <<<"$var"`.

## Building and running

There is no PostgreSQL on the host. Build and test inside the container, against
the read-only source mount, and never write build artifacts into the mount. The
loop, the majors available, and the traps are in the `pgcolumnar-dev-loop`
notes and in `HANDOFF.md`.

- Always pass `PG_CONFIG` to `make clean` as well as to `make`. Stale objects
  from another major link an ABI-incompatible `.so`, and the symptom is an
  `undefined symbol` at load time, which reads like a code defect and is not.
- Cadence: PG18 and PG19 per pull request, the full PostgreSQL 15 through 19
  matrix per feature. The per-PR pair cannot see a version boundary below 18,
  which is exactly how #218 was missed.
- A red is not a result until the job's own conclusion has been read. Cancelled
  jobs, queued jobs, and genuine failures are not distinguishable on the board.
