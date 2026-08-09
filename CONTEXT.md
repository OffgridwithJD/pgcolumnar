# CONTEXT

Orientation for anyone, human or agent, working in this repository. It is the
vocabulary and the house rules, not the status. Read it before naming a
function, a test, or an EXPLAIN line, so that new code says the same words the
existing code says.

Other documents outrank this one where they overlap, and each owns a different
question:

| document | owns |
| --- | --- |
| `design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md` | what the format and the interface ARE |
| `design/ROADMAP.md` | what is planned |
| `CHANGELOG.md` | what changed, per release |

This file owns the words.

**Where the spec and the shipped defaults disagree, the defaults are what you
will observe.** The spec describes the native format as designed, and in two
known places the code has not moved to meet it. Neither is a defect, and neither
is going to announce itself:

| the spec says | the code ships |
| --- | --- |
| a vector is a fixed 1024 values | a vector holds up to `pgcolumnar.chunk_group_row_limit` rows, default 10000 |
| the row-group limit is 122880 rows, a multiple of the vector length | `pgcolumnar.stripe_row_limit`, default 150000 |

The first is the sharper trap, because 1024 is not merely aspirational: it is
written into the native storage catalog row as `vector_length` and then never
read back by anything. A constant that is recorded and never consulted looks
exactly like a constant that is enforced.

Read the spec for intent and the code for behaviour. Where a fixture depends on
one of these numbers, take it from the setting, not from the spec.

There is also a `HANDOFF.md`, the running continuity record: what has happened,
what is in flight, and what to pick up. **It is deliberately not in the
repository.** It is excluded per clone through `.git/info/exclude`, so a fresh
clone will not have one and nothing here should be written to depend on it. If
you have it, read it; it is the single most useful file on the machine that has
it.

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
- **Vector**: a run of up to `pgcolumnar.chunk_group_row_limit` rows (default
  10000) inside a column chunk. The unit of encoding, of data skipping within a
  row group, and of vectorized execution. The native format fixes this at 1024
  values; the classic path does not, and `Columnar Vectors Skipped` moves with
  the setting.
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
What it does size is the VECTOR, so it moves `Columnar Vectors Skipped` instead.
Rebuilding the same 200,000 rows and running the same predicate:

| `chunk_group_row_limit` | `Columnar Vectors Skipped` |
| ---: | ---: |
| 10000 | 4 |
| 5000 | 8 |
| 1024 | 39 |

Each matches the arithmetic for the row group that is read: 50,000 rows at
10,000 is 5 vectors with 4 below the predicate, at 5,000 it is 10 with 8 below,
at 1,024 it is about 49 with 39 below. The 1,024 run also grows a
`Rows Removed by Filter: 64` line, because 190,000 is not a multiple of 1024, so
the straddling vector is decoded and filtered rather than skipped.

**`projection` names two unrelated things.** A **projection** is the secondary
physical ordering defined above. `pgcolumnar.enable_column_projection` and
EXPLAIN's `Columnar Projected Columns` use the same word for reading only the
columns a query references, which has nothing to do with it. Say **column
projection** for the second and never the bare word.

**Pruning and filtering are different outcomes, and a plan prints both.**
`Chunk Groups Removed by Filter` and `Vectors Skipped` are work never done.
`Rows Removed by Filter` is work done and thrown away. They appear on the same
node, and which one moved tells you whether a predicate actually helped.

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
  `bash test/run_all_versions.sh --list-suites | wc -l`. A text parser over the
  array disagrees with bash on exactly the mistake this invites, and the
  disagreement is silent. No number is quoted here on purpose: this bullet used
  to end "it is 132 today", which was 137 by the time anyone noticed. A count
  that changes weekly, written beside the command that computes it, is a
  liability and not a convenience.
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
- **Prove it by removal, and not only guards.** A test proves nothing until it
  has been seen to fail with the thing under test removed. The one-line form,
  which needs no interpretation and costs ten seconds:

      Can I delete this change and still be green?

  It applies to any change at all, not just a guard: a bug fix, a feature, an
  optimisation, a counter, a call site, a comment claiming a behaviour. This
  bullet used to say "guard", and on 2026-08-09 two changes shipped whose entire
  contribution could be deleted with the suite still green (#532, and the first
  version of #537's own fix; #538 is the change that caught the first of those).
  Neither was a guard, which is exactly why this line did not fire for either.

  Fingerprint the installed `.so` when you do it, because a shared install prefix
  will happily let the "before" run be the fixed binary.
- **A removal proof must fail for the STATED reason.** That a check can fail is
  not evidence that it fails for the reason claimed. Read the failure text.
- **A suite that sources a helper cannot see whether anything calls it.** Feeding
  a function fixtures proves its arithmetic and nothing else, so the caller can
  be deleted with every check still passing. Assert the call site too. A grep
  over source text is the weaker kind of check and is still worth writing;
  premise it on the call site existing, or it approves a file that no longer has
  one.
- **Before believing a check, make it say the other thing.** There are two ways
  to be misled and they are mirror images. A check too TIGHT to fail approves
  anything, and you find out when someone deletes your feature and the suite
  stays green. A check too LOOSE to be believed condemns anything, and you find
  out after chasing a defect that does not exist -- in #537 a grep for one
  message matched a different message that merely began the same way, one about
  the previously installed `.so` (#513), and reported a fault that was not there.
  So: make a passing check fail, and show a failing check passes on code known to
  be good. Both directions, every time.
- **When a rule does not fire, fix its trigger, not your discipline.** Guidance
  here, in a code comment, or in a local note can be correct, specific, and
  silent, because the condition that summons it is narrower than the content it
  guards. The bullet above is the worked example: it said "guard" while its
  content covered any removal, so it stayed quiet for both changes above. When
  something you had already written fails to help, ask whether its CONTENT
  would have covered the case. If yes the trigger is the bug, so widen it and put
  the wider form in the first line where it is actually read. If no, the content
  is. Only the second is about knowledge, and the first is the common one.
  "Consult it more carefully" is not a fix.
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

An ordinary PGXS extension: `make PG_CONFIG=/path/to/pg_config` then
`make install`, and a suite is `bash test/<name>.sh /path/to/pg_config`. Each
suite stands up and tears down its own cluster, so nothing needs a server
running first. `bash test/run_all_versions.sh <pg_config> ...` runs the matrix,
taking one `pg_config` per major as positional arguments and defaulting to
PostgreSQL 15 through 19 when given none.

- **Always pass `PG_CONFIG` to `make clean` as well as to `make`.** Objects left
  from another major link an ABI-incompatible `.so`, and the symptom is an
  `undefined symbol` at load time, which reads like a code defect and is not. It
  cost an hour on 2026-08-07, where five test runs produced no output because the
  cluster never started.
- Build out of the source tree, or clean between majors. A suite installs into
  the prefix its `pg_config` names, so two majors sharing a prefix will overwrite
  each other's `.so`.

Where a development environment is containerised, or PostgreSQL is not on the
host, that is a property of the machine rather than of the project, and belongs
in local notes beside `HANDOFF.md` rather than here.
- Cadence: PG18 and PG19 per pull request, the full PostgreSQL 15 through 19
  matrix per feature. The per-PR pair cannot see a version boundary below 18,
  which is exactly how #218 was missed.
- A red is not a result until the job's own conclusion has been read. Cancelled
  jobs, queued jobs, and genuine failures are not distinguishable on the board.
