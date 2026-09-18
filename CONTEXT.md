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

**Every new test is written twice: once as a `.sh` suite and once as a pytest
test, in the same change.** Owner's rule, 2026-09-09. Not "ported later" and not
"one or the other" -- a test that exists in only one harness is not finished.

The reason is the reason #432 exists. The bash harness carries 4,429 anchored
assertions and is the gate; the pytest harness returns typed results and refuses
shapes bash passes silently. Writing new tests in only the old one grows the
port debt with every change, and writing them in only the new one puts a property
outside the gate. Writing both keeps the two harnesses honest about each other:
where they disagree, one of them is wrong, and that is worth finding at the time
rather than during a port.

**The two harnesses are parallel in functionality, and independent in
implementation. They must not call, import or reference each other.** Owner's
rule, 2026-09-10. Documentation is the only exception: prose, comments and
docstrings may name the other harness freely.

This follows from the paragraph above. Two harnesses can only disagree if they
are two measurements. A pytest test that drives `test/lib.sh` by subprocess is
not a second measurement of the property -- it is the first measurement wearing a
Python wrapper, so it agrees with the shell by construction and can never report
the shell wrong. The coupling turns the twin from evidence into a mirror, and a
mirror is what the twin rule exists to avoid.

So each harness asserts the property against **the product**, in its own terms,
never against the other harness's implementation. Building a throwaway fixture
that merely resembles the other side -- writing a fake `lib.sh` into a `tmp_path`
-- is not a reference to it; sourcing the real one is. If a property can only be
expressed by driving the other side, that is a signal it belongs to one harness
alone: say which, and say why, rather than reaching across.

**The counting rule, so the inventory can be re-derived.** A **reference** is an
executable line that names a file belonging to the other harness *as it exists in
this tree* -- sourcing it, importing it, running it, or reading its text. Three
things are not references, in the order they get confused:

1. prose. Comments, docstrings and help strings may name the other harness freely.
2. a file the test **builds itself** under a `tmp_path`, even with the same name.
3. a word that merely looks like a filename. `sharedir` is not a `.sh` file.

**Count files, not lines.** A line total moves with any refactor and with the
exact pattern used, and three different patterns gave three different totals when
this was first counted. The file is the stable unit, so each file below is named
with the mechanism that makes it a reference -- which is also what has to change
for it to stop being one.

**The debt this starts with, on 2026-09-10: 3 python files and 7 shell files.**

**Progress, 2026-09-11.** The fourth never arrived: #923 deleted
`test_check_results_are_machine_readable.py` rather than land a fresh violation. And
`test_build_refusal.py` is down from 36 cross-harness calls to 13, of which 7 are the
debt proper, 2 are the permitted cross-reference below, and 2 are one historical-parity
arm. **Counted by mechanism rather than by line, because a line total moves with the
pattern:** the real executable coupling across the whole corpus was six sites in three
files -- `pgc_cluster.py` once, `test_build_refusal.py` three times, and
`test_suite_accounting.py` twice -- and the two `lib.sh` writes in
`test_build_refusal.py` are fake trees under `tmp_path`, rule 2, not references.

Python that reaches into shell:

- `test_build_refusal.py` -- **reduced, not cleared.** It sourced the real
  `test/lib.sh` in three helpers (`_sh`, `_sh_fp`, `_sh_fp_as`) behind 36 calls and
  was the largest item here. Counted with `ast`, not `grep`: the pattern
  `[^_a-z]_sh(` also matches `def _sh(`, which is how the first draft said 39 -- 36
  calls plus the 3 definitions. Reported by @OffgridwithJD. Rule 3 above, caught in
  the very entry that states it.

  **22 of those calls are gone.** Their subject was `test/pgc_fingerprint.py`, the ONE
  implementation since #907, and `pgc_source_fingerprint` and `pgc_source_manifest`
  are thin wrappers that shell out to exactly it -- so the path was
  python -> bash -> lib.sh -> python3 -> the module, and removing the middle two
  changed no subject. Measured before converting anything: byte-identical
  fingerprint, identical manifest line for line, and agreement across LC_ALL=C,
  C.UTF-8 and en_US.UTF-8. Two of them needed a separate process rather than an
  in-process call -- one reads as an unprivileged user because root ignores
  `chmod 000`, one varies the locale -- and both use the module's own CLI, which is
  the entry point lib.sh uses with lib.sh taken out of the path.

  **FOUR calls remain and none of them is debt.** Two are
  `test_the_two_fingerprint_implementations_cover_the_same_inputs`, which reaches
  across on purpose -- see below. Two are a historical-parity arm whose fixture is
  its own.

  The seven that drove `pgc_write_source_stamp`, `pgc_source_stamp_path`,
  `pgc_freshness_report` and `pgc_freshness_verdict` are **gone**, and not one of
  them needed porting: `test/selftest/340` already held every property they
  asserted, with more arms in each case. Measured arm by arm before anything was
  deleted.

  **THE FIRST MEASUREMENT OF 340 WAS WRONG AND NEARLY COST A DUPLICATE.** Enumerating
  its checks with `grep -cE '^check "'` gave 81; the real number is 89, because 340
  has INDENTED `check` calls inside an `if` and a `for`, and the eight it missed are
  exactly the unreadable-source block. On that bad count one python arm looked like a
  genuine gap, and a duplicate of it was written and proven to discriminate before
  the duplication was noticed. The tell was a duplicate check name -- the ledger tool
  reported "one ledger row covers 2" -- and the right response to a name that already
  exists is to ask why, not to rename it. Anchor a check sweep at `^[[:space:]]*`.

- **A sweep over shell source cannot tell code from the prose describing it.**
  Anchoring is only half the decision. Four guards got this wrong in one week, in
  both directions, and every one was silent (#1123).

  ```
  selftest/070 flagged its own subject's comment, which quoted the pattern it greps for
  grep -l pgc_setup counted six comments saying "skipped deliberately" as CALLS
  the same trap as an EXCLUSION dropped those six, and with them 233 records
  a record-pattern matched the word `check` inside run_all_versions.sh's echo strings
  ```

  Over-inclusion reads as a strict guard; under-inclusion reads as a clean tree.
  Neither announces itself.

  **Three decisions, and the third removes the question where it applies:**

  1. **Strip comments.** `grep -vE '^[[:space:]]*#'` into a variable, then read the
     variable. A herestring, not a pipe -- part 080 forbids the pipe (#486).
  2. **Decide whether string literals count, and say which.** A pattern that
     matches inside an `echo` is a different sweep from one that does not, and
     stripping comments does not settle it.
  3. **Prefer a population that cannot contain prose about itself.** Sweeping the
     REGISTERED SUITES rather than `test/*.sh` dropped `run_all_versions.sh` out of
     scope, because the runner is not a suite. That fixed one of the four with no
     pattern work at all.

  **Measured over this tree**, with each grep's own pattern extracted by `shlex`
  from the `$(...)` body rather than by a regex over the line -- which is the part
  that was wrong the first time and produced a number too bad to publish:

  ```
  126 sweeps over shell source
   34 anchored at ^, so a comment line cannot match
   92 unanchored
    2 unanchored AND over a commented file AND the pattern is a bare identifier
  ```

  That last class is the one that bites, and both instances were real. In
  `selftest/320` the pattern was `MAJOR_FAIL=` over a runner carrying 874 comment
  lines: adding one comment saying the old name was `MAJOR_FAIL=`, changing no
  code, took `harness_selftest` to `1080 passed + 1 failed`. In `selftest/080` the
  pattern was the bare word `grep` over a file of 61 comment lines about readers.
  Both now read code only.

  **The wider count is a measurement, not a budget.** "Unanchored" is not
  "exposed": a pattern like `/pbt/run\.sh$` cannot plausibly appear in prose, and
  whether one can is a judgment a guard should not pretend to make. The narrow
  class above is the part worth checking by hand when a sweep is written.

- **The one permitted cross-reference, named as the rule asks.**
  `test_the_two_fingerprint_implementations_cover_the_same_inputs` asserts that the
  shell path and the Python path give the same value, which is to say that neither
  side carries a private copy. That property IS the relationship, so it cannot be
  expressed from one side: the rule's own escape clause -- "say which, and say why"
  -- applies, and this is the saying. It caught four defects in one day (#907), and
  it is what reddens on the FIRST edit if a private implementation comes back rather
  than on the first edit that happens to diverge. Every other reference in this
  inventory is expected to go; this one is expected to stay.
- `test_suite_accounting.py` -- reads `run_all_versions.sh`'s text, sources the
  real `lib.sh` from a suite it writes, and executes the real runner.
- `pgc_cluster.py` -- sources the real `test/lib.sh`.
- `test_mutation_ledger.py` -- runs `run_all_versions.sh --list-suites` for the
  registered suite list. It **arrived after this inventory was written**, with #925,
  and the arm below is what said so: the set-equality assertion reddened on the
  rebase naming a fourth file, which is the whole reason the inventory is a mechanism
  and not this paragraph. Same mechanism as `test_suite_accounting.py`, so it is the
  same item of debt twice and they should move together.

Shell whose subject is python: `selftest/350`, `360` and `380`. **Three, not the
seven this line first named, and the three it dropped were rule 3 all along.**
`lib.sh`, `selftest/030` and `selftest/040` reference NO path under `test/pytest`:
their only matches were the shell functions `pgc_cluster_datadir` and
`pgc_cluster_is_ours`, both defined in `lib.sh` itself -- "a word that merely looks
like a filename", caught for the second time in the entry that states the rule.
`selftest/370` was the fourth and is **deleted**: every property it pinned was a text
pin on `pgc_vacuity.py`, and #927 is the precedent -- a shell arm asserting a text pin
cannot prove a python arm is caught. Its one property that the pytest corpus did not
already assert behaviourally moved to `test_guards_pinned.py`, where python reads its
own module rather than the other harness's.

**And that property is not behaviourally observable today, which is why it moved as a
SOURCE check and says so.** Measured: with `plan_marker`'s empty-plan refusal moved to
the very end of the function, `plan_marker([], absent=True)` still refuses --
`plan_marker` has no early return, so the refusal fires wherever it sits. 370's stated
reason, that "the absent arm returns a pass first", describes a shape the function does
not have. The arm is prospective insurance against a refactor that adds an early return,
and it is labelled as that rather than as a live guard.

**`test_build_refusal.py` is the example worth studying, because it does both.**
It writes a fake `test/lib.sh` into a `tmp_path` and drives that -- rule 2, not a
reference -- and it *also* sources the real one three times. The first draft of
this section read the fake tree, called the file "not debt", and used it as the
illustration of what the rule permits. It is in fact the largest single item in
the list. Reported by @OffgridwithJD, who checked the inventory instead of
believing it. Judge a file by what it executes, not by the fixture it builds.

None of that is fixed by this section. It records which direction those files are
expected to move, and makes the inventory falsifiable rather than a vague sense
that some coupling exists.

**A sequencing note that will stop being true.** As of 2026-09-09 the pytest
harness is PR #897 and is not on `main`, so this rule cannot be satisfied for a
test written today. Until it lands, write the `.sh` suite, write the pytest twin
alongside it in the same change, and say in both headers that the twin is blocked
on #897. Do not let "the harness is not merged yet" become a standing excuse: the
twin is written either way, so the debt is never deferred, only its execution is.

**And pin the SHA you tested the twin against, not the branch name.** A branch
name is not checkable later and moves under you -- the pytest harness branch
moved three times while the first twin was being written, and two of those moves
changed its content. `blocked on #897 at b785795d7ccd` costs the same to type as
`blocked on #897` and is falsifiable: a reader can diff that SHA against the
branch and see whether the claim still holds. Same reason a tag is read from the
API rather than from a local ref.

- Register every suite in `SUITES` in `test/run_all_versions.sh`. That array is
  **one name per line and sorted**; insert in sorted position, never at the end.
  `harness_selftest` fails if the order decays.
- **A script is executable and declares its interpreter on line 1, or it has
  neither.** `harness_selftest` sweeps every `.sh` and `.py` under `test/` and
  `bench/`, at any depth, with nothing excluded, and fails if one has either
  without the other. A file with neither is a fragment meant to be sourced, and
  that is the only self-consistent way to say so. The matrix starts a suite as
  `bash test/<name>.sh`, which never reads the mode, so only the documentation
  and a reader's shell ever see it: 103 scripts were 100644 when this rule was
  written, and 30 documented commands died with `Permission denied` (#852).
- **And a script a document names as a bare command must exist and be
  executable**, whatever its first line says. Both halves: a named path that has
  been deleted or moved gives a reader `No such file or directory`, which is the
  same defect as `Permission denied` in a different coat. That is the one check anchored on prose, and it
  is deliberately over-inclusive: it exists because a file that has lost both its
  shebang and its bit is internally consistent and still broken for the reader,
  so the sweep above cannot see it (#856).
- The population is every directory that holds a documented entry point, which
  today is `test/` and `bench/`. `docs/benchmarks.md` names five `bench/` scripts
  as bare commands; before #856 nothing checked them, which is exactly what
  `test/` was before #852. A new directory that documents a command belongs in
  the sweep the day it is added.
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

  **A cached build artifact can serve either arm the wrong code, and it is the
  same defect at both ends.** A shared install prefix will happily let the
  "before" run be the fixed `.so`. A stale `.pyc` will let every run AFTER the
  restore be the mutant: CPython validates its cache on `(source mtime in whole
  seconds, source size)`, so a same-size edit applied and restored inside one
  second leaves a cache that still validates. Only IMPORTED modules are cached: a
  script run directly is compiled fresh every time, which is why the two
  invocations disagree at all. Measured on 2026-09-13 against
  `compare_to_bash.py`, where `"pgc_skip": 2,` -> `1,` is exactly that shape; the
  source was verified restored by md5 and the runtime kept running the mutation
  for the rest of the session. It produced a confident, reproducible and entirely
  false defect report about another branch, which was caught before it was sent.

  So fingerprint the artifact, and assert the RUNTIME rather than the file:

      find . -name __pycache__ -type d -exec rm -rf {} +   before EVERY arm,
                                                           the control included
      python3 -c 'import mod; print(mod.THE_THING_YOU_CHANGED)'

  The four steps a removal proof owes, in order: the edit landed, the mutant is
  still a valid program, the RUNTIME sees the change, and only then read which
  checks moved. The third is the one that looks redundant next to an md5 and is
  not: md5 is a claim about the file, and the conclusion is drawn from the
  process.

  The tell, when it happens, is two ways of invoking the same code disagreeing --
  the CLI read 9 names and the import read 15 out of one file, which is impossible
  for one function unless the two are not running the same function. The direct
  run is the one to believe, since it was compiled fresh.

  **The same cause also produces the opposite quiet wrong answer, so do not read a
  clean run as proof there is nothing here.** Mutate and restore inside the
  ORIGINAL's second and the clean cache never invalidates either, so the mutation
  appears to do nothing -- and "the mutation changed nothing" is what "this code is
  not load-bearing" looks like, which is the conclusion the whole removal proof
  exists to reach. Reproducing the stale cache took @OffgridwithJD three attempts
  for exactly that reason. One cause, two silent and opposite errors: the proof
  reads as passing when the change is unnecessary, and as failing when it is not.
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
  the previously installed `.so` (#508), and reported a fault that was not there.
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
- **When you fix one instance, look for the rest before you believe you are
  done.** A correction is not complete until you have searched for the same claim
  elsewhere: grep for the phrasing you just removed. The bullets above were
  written with a claim about people in them, corrected in one place, and the same
  claim survived one paragraph below in different words. Then a wrong issue
  citation was corrected in one place and a second wrong one survived four lines
  away, and was caught by this rule rather than by rereading. Both times the
  first correction felt like completion.
- **Never gate on luck.** A premise that requires a random sample to miss, or
  core to be unlucky, will fail eventually and will blame innocent code (#487).
  Restate it as arithmetic, or print it as an observation.
- **Pin known-wrong behaviour as an assertion, never as an echo.** Nobody reads a
  passing suite's output. Pinned as an assertion, the fix turns the suite red and
  forces the expectation to be updated deliberately.
- **Never pipe a captured string into a reader whose exit status is your answer**
  (#486). Under `pipefail` it reports "not found" whenever the writer fails.
  Use `case` for a fixed string, or `grep -q PATTERN <<<"$var"`.

## A CONFLICTING badge on CHANGELOG.md means rebase locally (#1116)

`CHANGELOG.md` carries a **union** merge driver, set in `.gitattributes` by #996.
Two pull requests that each add an entry no longer conflict: git takes both sides,
emits the shared `## [Unreleased]` / `### Fixed` lines once, and the result needs no
hand editing.

**GitHub does not honour it.** Its mergeability calculation and its merge button do
not read `.gitattributes`, so a pull request still shows the red *This branch has
conflicts that must be resolved* badge the moment another changelog entry lands.

This is confusing in the specific way that costs time: **the merge is clean on your
machine and the web UI says it is not.**

### What to do

Rebase locally and push. Do not click *Update branch*, and do not wait for the
button — both give you the conflict the driver exists to remove.

    git fetch origin
    git rebase origin/main
    git push --force-with-lease

Measured, on four branches rebased onto the driver after it landed: zero CHANGELOG
conflicts, one `## [Unreleased]`, every entry present, `docs_style.sh` green. The
same merges showed `CONFLICTING` on GitHub throughout.

### And why rebasing works where merging does not

The advice above is not a preference. Git reads `.gitattributes` from the tree it is
merging **into**, so a branch that predates the driver cannot use it:

    merge main INTO the branch   conflicts: CHANGELOG.md  <derived files>
    rebase the branch ONTO main  conflicts:               <derived files>

Measured on #1107, whose head predates #1108 (`grep -c 'CHANGELOG.md.*merge=union'`
gives 0 on that head and 1 on main). Merging brings main's commits into a tree whose
attributes have no driver; rebasing replays the branch onto main, where the driver is
already in force.

So for any branch opened before the driver landed, *Update branch* cannot work even
in principle — and that is most branches that have been open more than a day.

### What the driver does not excuse

A **release cut** edits `## [Unreleased]` into `## [1.0-alphaN] - date`, which is the
one case union resolves silently and wrongly: a pending entry lands inside the
section that just shipped. `test/docs_style.sh` compares each dated section against
what its own tag shipped, so that is caught rather than trusted. If you are cutting a
release, land the pending changelog entries first or expect that arm to tell you.

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
- **Build output is never committed.** `.gitignore` covers `*.o`, `*.so`, `*.bc`,
  `__pycache__/` and `*.pyc`, and `harness_selftest` fails if a compiled Python
  artifact is tracked or if either Python rule goes missing. A tracked artifact
  does not stay still: `test/__pycache__/ste_check.cpython-312.pyc` outlived the
  source it was compiled from, which had been renamed away, and re-committed
  itself -- two bytes of PEP 552 timestamp -- inside an unrelated
  logical-replication fix (#854).

Where a development environment is containerised, or PostgreSQL is not on the
host, that is a property of the machine rather than of the project, and belongs
in local notes beside `HANDOFF.md` rather than here.
- Cadence: PG18 and PG19 per pull request, the full PostgreSQL 15 through 19
  matrix per feature. The per-PR pair cannot see a version boundary below 18,
  which is exactly how #218 was missed.
- A red is not a result until the job's own conclusion has been read. Cancelled
  jobs, queued jobs, and genuine failures are not distinguishable on the board.
