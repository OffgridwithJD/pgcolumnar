# The vacuity modes: what is refused, what is not, and what nobody attacked

A vacuity defect is a test that reports PASS while asserting nothing. This file is
the inventory: every way a pytest harness can do that which anyone here has
demonstrated, which of them `pgc_vacuity.py` refuses today, and which it does not.

`TESTS.md` documents the tests that exist. This documents the ones that should.

## 1. Where these numbers come from, and what did not run

A five-angle enumeration ran in the audit container against pytest 9.1.1,
pytest-xdist 3.8.0 and psycopg 3.3.5. Each mode had to be demonstrated by an actual
run rather than described.

| stage | started | completed | failed |
| --- | ---: | ---: | ---: |
| enumerate the modes | 5 | 5 | 0 |
| design a refusal per mode | 79 | 74 | 5 |
| **attack each refusal** | **148** | **0** | **148** |
| synthesize the layer | 1 | 0 | 1 |

**The adversarial stage did not run.** It was cut off by a session limit, so the
summary line reading `defeated: 0` counts zero defeats out of **zero completed
attacks**. That number is not evidence that these refusals survive attack, and this
document is the synthesis the failed stage would have produced, written by hand from
the stage outputs that did complete.

So: 79 modes produced by the run, of which **72 are named here** (see 1a), and **73 demonstrated by a run**. 74 refusals designed, every one of them
stating a residual. None of the 74 has been adversarially tested.

## 1a. How to count a mode in this document

**A mode is a backticked kebab-case identifier of three or more words**, such as
`collected-but-nothing-asserted`. That is the counting rule, stated because the
document had none and its numbers therefore could not be checked — which is a
poor property for a document about claims that cannot be checked.

**A mode named in section 2 is refused, even where section 3 also names it.**
Section 3 keeps a back-reference to every mode that moved — "`X` is now closed"
— so a reader who knew a mode as unrefused finds out where it went. Counting
those references as unrefused lists one mode in both states, which is how the
first version of this rule reported 25 refused and 50 unrefused out of 72 named.
Section 3's total is therefore the ids it names MINUS the ids section 2 claims.

Counted that way, and this is a measurement of the file rather than a
recollection of the run:

| | modes |
| --- | ---: |
| named in section 2, refused today | 28 |
| named in section 3, not refused | 44 |
| **named in this document** | **72** |
| produced by the enumeration run | 79 |
| **named nowhere here** | **7** |

**The enumeration produced 79; this document names 72 of them.** The other seven
were counted by the run and never transcribed, so they cannot be cited, checked
or built against. They are not a secret reserve of coverage — they are a gap in
this file.

The run's own split was 23 refused and 56 not, against the 21 and 51 named here.
Those differ by exactly the seven that were never written down. Where the two
disagree, **the named ids are the record** and the run's totals are history:
an id can be read, argued with and turned into a test, and a number cannot.

## 2. What the layer refuses today

28 of the 79, counted by section 1a's rule. Each is enforced by a mechanism, not a convention, and each has a red
test in `test_layer.py` that fails without it.

| mechanism | modes it closes |
| --- | --- |
| a test must make a counted assertion | `collected-but-nothing-asserted`, `return-instead-of-assert`, `assert-hidden-in-an-uncalled-helper` |
| `expect.rows` refuses two empty sides | `empty-equals-empty`, `empty-rows-equal-empty-rows`, `empty-vs-empty-set` |
| `expect.hash` refuses self-comparison, error sentinels, two empties | `oracle-against-itself`, `md5-of-the-empty-oracle` |
| `expect.at_least` refuses a floor of zero | `tautological-bound` |
| `expect.plan_marker` matches a typed key, never a substring | `substring-superstring`, `plan-substring-matches-property-or-prefix` |
| `plan_marker` refuses an absence claim over an empty plan | `absence-assertion-over-empty-plan` |
| `expect.rowcount` refuses psycopg's `-1` | `rowcount-minus-one-is-truthy-and-numeric` |
| a broad `except` is uncollectable, found by AST | `aborted-transaction-swallowed-into-one-fallback` |
| a bare skip fails the run | `skip-family-exit-0`, `all-tests-skipped-exit-zero`, `all-skipped-exits-zero` |
| `xfail_strict = true` | `xfail-xpass-and-the-wrong-exception`, `xfail-and-xpass-are-green` |
| `--pgc-expect-tests` asserts the run's own shape | `zero-collected-exit-5`, `filters-select-nothing`, `partial-selection-exits-zero` |
| the connection fixture is autocommit | `uncommitted-fixture-measures-an-empty-table` |
| `ordered_rows` refuses an unobservable ordering, and the scan refuses an order-killed value feeding it, in three spellings | `set-oracle-on-an-ordered-claim` |
| the reported node-id set is reconciled against the collected one | `crashed-worker-silently-loses-tests` |
| an empty parameter set fails the run, with its own message | `empty-parametrize-is-a-silent-skip` |
| a skip during fixture setup fails the run | `session-fixture-skip-greens-the-whole-suite` |
| a broad `pytest.raises` must pin a SQLSTATE, found by AST | `raises-too-broad` |
| every comparison refuses a value carrying the `QUERY_ERROR` prefix, on either side | `error-swallowed-to-empty` |
| a write whose command tag reports 0 rows fails the test unless the zero is named | `insert-wrote-no-rows` |

Three of those were added after checking this layer against the inventory rather
than reasoning about it, and all three had passed silently before:

- `plan_marker(absent=True)` returned a pass against `[]`. An absence assertion is
  satisfied by nothing being there at all, which is the case most worth catching.
- `expect.num(-1, -1)` passed. `cursor.rowcount` is `-1` when no count is available
  and `1` for an unfetched `SELECT`; both are numbers.
- A broad `except` was forbidden **in a comment**, which enforces nothing.

### 2.1 What the order-killer scan sees, and what it does not

The scan first caught only `expect.ordered_rows(sorted(got), ...)` — the killer
written inside the argument. Two spellings of the same collapse walked past it,
and both read as more careful code than the one that was caught:

    g = sorted(got)          # bound to a name first
    expect.ordered_rows(g, want)

    got.sort()               # killed in place; the call site is unchanged
    expect.ordered_rows(got, want)

All three are refused now. The scan is **one function deep**: a helper that sorts
and returns is invisible to it, as are aliases, attributes and branches. That is a
floor rather than a proof of order-sensitivity, and it is pinned by a test so the
limit cannot quietly turn into a claim of completeness.

It compares line numbers, so a name sorted *after* the claim is not refused. A
guard whose subject is false greens has no business emitting a false red.

## 3. What it does not refuse

55 modes by the run's count, **44 of them named below**, **48 demonstrated by a run**. 51 have a refusal already designed.
Grouped by what a reader needs to decide about them.

### 3.1 The run can lose tests and still exit 0

A run that starts N tests and finishes fewer can still exit 0. Losing a test looks
exactly like never having written it.

**`crashed-worker-silently-loses-tests` is now closed.** The layer reconciles the
collected node-id set against the reported one in the controlling process.

The measurement is narrower than the mode name suggests. On a 6-test corpus under
`-n 2 --max-worker-restart=0`, bare pytest exits 1 and names the crash, so the run
is not green. But 5 node-ids reported against 6 collected, and `test_d` appears
nowhere in the output: it was assigned to the dead worker and never ran. The loss is
what is silent, not the crash. The guard names the missing node-ids and fails the
run on the difference.

Two things that took a measurement to get right. Under xdist the **workers** collect,
not the controller, so the controller's set stayed empty and the guard was present
and blind until it also listened to `pytest_xdist_node_collection_finished`. And the
state has to live on a per-config plugin instance: `pytester.runpytest()` runs the
inner session in-process, so module-level sets leaked between the layer's own tests
and the sessions they drive, and 44 passing tests exited 1.

Still open in this family:

- `xdist-drops-the-deselected-count`, `env-deselect-passes-xdist-divergence-guard`,
  `session-fixture-runs-once-per-worker`, `xdist-split-makes-a-loop-assert-vacuous`
- `process-exits-0-mid-run`, `retry-wrapper-greens-a-lossy-run`,
  `junit-records-a-crash-as-error-failures-zero`

### 3.2 The invocation throws the verdict away

- `exit-5-lost-through-a-pipe` — measured: `pytest -q -k nosuch | tee run.log`
  exits **0** without `pipefail` and **5** with it. The tee-the-log habit discards
  the only vacuity guard pytest ships.
- `ci-step-swallows-the-exit-code`, `n-zero-silently-serial` — measured: `-n 0` runs
  in-process with no workers, no warning, exit 0. So `-n "$PGC_JOBS"` with the
  variable empty turns the parallel gate serial in silence.

These are not fixable inside the plugin. They belong to whatever invokes it, which
is the same reason `test/run_all_versions.sh` carries its own accounting.

### 3.3 Collection can go quiet

**`empty-parametrize-is-a-silent-skip` and
`session-fixture-skip-greens-the-whole-suite` are now closed.** The first has its own
message rather than being folded into the bare-skip refusal, because the cause a
reader needs to see is the corpus, not the marker. The second catches any skip
arriving during setup, since `expect.cannot_run` records a counted assertion instead
of skipping.

Still open in this family:

- `conftest-import-failure`, `collection-error-and-continue-flag`,
  `collection-error-loses-a-module-silently`, `collect-only-and-collect_ignore`,
  `mark-typos-and-bare-marks`

### 3.4 The assertion is shaped so it cannot fail

**`raises-too-broad` is now closed.** A `pytest.raises` over `Error`,
`DatabaseError`, `Exception` or `BaseException` does not collect unless the block
binds the exception and the body pins its SQLSTATE. See section 2.

- `raises-catches-setup` — **narrowed again, and still not closed.** The statement COUNT
  rule refused a block holding more than one top-level statement, and two shapes are ONE
  statement that still performs the setup inside the block:

      with pytest.raises(psycopg.errors.UndefinedObject) as exc:
          _setup_then_run(conn)          # a HELPER CALL: one statement

      with pytest.raises(psycopg.errors.UndefinedObject) as exc:
          for stmt in (setup_sql, sql_under_test):   # a COMPOUND STATEMENT: one
              conn.execute(stmt)                     # statement holding two

  Both were measured against the shipped scan reporting `1 passed`, exit 0, **zero
  offences**, with the setup raising and the statement under test never running. Both are
  refused now, by two rules: no compound statement (all nine kinds Python has, looked up
  by name so a missing `TryStar` or `Match` cannot silently narrow the rule), and no call
  to a function DEFINED IN THE SAME FILE, anywhere in the statement.

  WHAT REMAINS, measured rather than reasoned, which is why this entry stays in section 3
  and the refused count did not move:

      a `for` loop over two statements                     REFUSED
      the same two statements as a list comprehension      allowed
      the same two as a tuple of calls                     allowed
      a helper defined in ANOTHER file                      allowed
      an honest one-statement helper defined in THIS file   REFUSED (a false positive)

  A comprehension and a tuple are EXPRESSIONS rather than compound statements, so a rule
  about statement kinds cannot see them; and `local_defs` is built from one file, so
  moving the helper one file over defeats it. Both are ordinary Python, not contrivances.
  The last row is the rule's cost rather than a gap: an honest single-statement local
  helper is refused, and the author must inline it.

  THE FIX IS NOT A DEEPER COUNT, for the reason this entry always gave: counting
  recursively would also refuse a legitimate single-statement loop. What would close it
  is a claim about which statement raised that does not depend on the SHAPE of the
  statement -- a helper that runs exactly one statement and owns the assertion. Measured,
  the corpus has no SQL-raising `pytest.raises` block at all, so that helper would have
  no call sites today and would be an instrument with nothing exercising it.

  The two arms that used to assert these shapes were NOT refused now assert that they
  are, so the narrowing is a measurement rather than a sentence. Residuals named by
  @jdatcmd on review. See TESTS.md section 20.
- `same-broken-helper-both-sides`, `truthy-error-string`, `assert-not-unset-error`,
  `zero-on-both-arms`, `tuple-assert-always-true`, `approx-of-nothing`

### 3.5 The fixture built the wrong situation

**`insert-wrote-no-rows` is now closed.** `INSERT ... SELECT ... WHERE false` writes
  nothing and raises nothing, and before this nobody read either field. Every write the
  test connection runs is now recorded from the server's own command tag, and a test
  that ran one reporting 0 rows fails unless it named the zero with
  `expect.wrote(cur, 0, ...)` — which is how a DELETE that must match nothing stays
  writable. See section 2 and TESTS.md section 22.

  THE TAG DECIDES, NOT THE COUNT, and that is the whole design. `SELECT 0` and
  `INSERT 0 0` both carry `rowcount == 0`, so a guard keyed on the count would refuse
  every test whose last statement was a SELECT over an empty result. Measured on PG 18
  against a pgcolumnar table: DDL reports `CREATE TABLE`/`SET`/`TRUNCATE TABLE` with
  `rowcount` `-1`, an `INSERT ... WHERE false` reports `INSERT 0 0` with 0, and
  `UPDATE 0` and `DELETE 0` likewise. This guard therefore never parses SQL.
- `mutation-arm-unobservable` — **narrowed, not closed.** The assertion now exists and
  the old spelling of it is unavailable. `expect.differ(a, b, name)` refuses two arms
  that agree and names the value they shared; `expect.num(int(after != before), 1, ...)`
  and its `int(a == b) == 0` twin are refused by an AST scan over the corpus, so the
  class is closed rather than the three instances. It also refuses a failed query on
  either arm, which is the INVERSE of the trap #930 closed: `query_error()` makes each
  failure unique so two failures cannot compare equal, and that uniqueness makes them
  compare UNEQUAL — so an arms-differ assertion passed on a pair of statements that
  both blew up. Measured: two calls give `QUERY_ERROR.1.<detail>` and
  `QUERY_ERROR.2.<detail>`.

  WHAT IS NOT CLOSED is the omission. The layer cannot know which two values in a test
  are arms, so a test that runs an A/B and asserts nothing about the pair is still
  vacuous and nothing refuses it. What has gone is writing the assertion wrongly;
  what remains is not writing it at all. See TESTS.md section 3.

  THE SCAN FOUND A SITE THE MANUAL COUNT MISSED, which is the argument for it. I
  measured the population by grepping for before/after naming and found two. The AST
  scan found three: the third was in `test_docs_cover_the_corpus.py` and spelled
  `int(stated == disk) == 0`, the same assertion with the comparison inverted, which no
  search for `!=` would reach.
**`error-swallowed-to-empty` is now closed.** Every comparison in the layer refuses a
  value carrying the `QUERY_ERROR` prefix, on either side, at any depth — so two
  queries that both failed cannot compare equal, whatever a helper turned them into.
  `query_error()` produces a value unique per occurrence, as `lib.sh`'s
  `QUERY_ERROR.$seq` does, for the paths that compare without the layer. See
  section 2 and TESTS.md section 18.

  THE EARLIER VERSION OF THIS PARAGRAPH SAID "the port has the sentinel constant but
  nothing produces it", AND THAT WAS WRONG IN BOTH HALVES. Two sites did produce
  sentinels by hand (`test_hilbert_locality.py`, one of them from inside SQL), and the
  thing actually missing was not a producer: it was the refusal in four of the five
  comparisons. `expect.text`, `expect.rows`, `expect.row_set` and `expect.ordered_rows`
  each passed with a sentinel on both sides; only `expect.hash` refused. A map that
  names the wrong gap is worse than one that admits it does not know, so the
  measurement is recorded here rather than quietly replaced.
- `guc-set-but-path-never-engaged`, `aggregate-masks-empty-fixture`,
  `db-derived-empty-parametrize`, `null-filter-matches-nothing`,
  `loop-over-zero-rows`, `assert-inside-a-loop-over-zero-rows`

  **`assert-inside-a-loop-over-zero-rows` is NARROWED, and half of it was already
  closed by a mechanism nobody had noticed covered it (#432).** The mode is two shapes:

  *Already refused.* When a loop's body holds the test's ONLY counted assertions, a
  zero-trip loop leaves the count at 0 and `pytest_runtest_call` raises `VacuityError`.
  Measured on a planted test rather than read off the hook --

      only assertion inside a zero-trip loop   VacuityError: made no counted assertion
      the same loop with one row               1 passed

  *Was open.* When the test ALSO asserts outside the loop the count is non-zero, the
  test passes, and the loop's assertions simply never ran. `test_loop_coverage_premise.py`
  now requires a cardinality premise for exactly that shape.

  THE POPULATION, measured over the whole corpus before the arm was written:

  | shape | loops | state |
  | --- | ---: | --- |
  | non-empty by construction (literal, range, local literal) | 20 | cannot be zero-trip |
  | derived, loop holds the only assertions | 0 | already refused |
  | derived, WITH assertions outside the loop | 2 | **at risk**, now guarded |

  Both at-risk loops already carried a premise, so the arm is green on arrival. That is
  the point rather than a weakness: the property was true and nothing held it there.

  **WHY IT NARROWS RATHER THAN CLOSES.** The honest requirement is "a premise bounding
  the cardinality of THIS iterable". What is enforced is "a counted assertion outside
  the loop that takes `len(...)` of something". `test_harness_deps.py`'s loop iterates
  `sorted(found)` while its premise bounds `len(files)` -- `found` is built from `files`
  in a preceding loop -- so a rule demanding the names match would reject correct code.
  The residual is a loop whose premise bounds the wrong collection, which a reviewer
  catches and a sweep does not.

  `loop-over-zero-rows` is untouched: it is the sibling about a loop that produces no
  assertion at all, which the whole-run guard covers only when the test has no others.

### 3.6 psycopg's typed results introduce their own

- `sql-null-to-python-none`, `none-conflates-null-no-row-and-missing-column`
- `dict-row-collapses-duplicate-columns`, `decimal-scale-and-null-aggregate`
- `truthy-cursor-from-execute`, `lossy-row-render`
- `only-first-result-set-fetched`, `multistatement-execute-positions-on-the-first-result`
- `executemany-returning-fetchall-sees-only-the-first-batch`,
  `server-cursor-rowcount-is-not-a-row-count`, `empty-query-string-succeeds`

**MEASURED POPULATIONS, so the next entry is chosen on evidence (#432).** Section 5's
new rule is that an entry must name a mode id, which makes *which* id worth measuring
rather than guessing. Four of 3.6's were counted over the whole corpus by AST scan:

| mode | sites | what they are |
| --- | ---: | --- |
| `truthy-cursor-from-execute` | 7 | **all benign.** Every one is `x = cur.execute(...)`, which is idiomatic psycopg3 — `execute` returns the cursor. **Zero** branch on it (`if`, `while`, `assert`), which is the dangerous form. |
| `empty-query-string-succeeds` | 0 | no `execute()` on an empty or whitespace literal anywhere. |
| `multistatement-execute-positions-on-the-first-result` | 1 | `test_saop_element_pushdown.py`, a three-statement SETUP that fetches nothing. The arm immediately after asserts `count(*) = 40000`, so the INSERT is proven to have run. |
| `server-cursor-rowcount-is-not-a-row-count` | 2 | **both legitimate.** A `DELETE`'s `rowcount` with an `at_least` premise on it, and a field on a stub cursor class. |

**So all four are prospective.** A guard for any of them would be insurance against a
shape the corpus has not yet written, not a closure of one it has — and it should say
so, the way `test_the_empty_plan_refusal_precedes_the_arms_it_protects` does.

That is not an argument against writing them. It is an argument against writing them
and calling the mode closed: the counting rule in 1a treats section 2 as "refused
today", and a refusal with no population has not refused anything yet. The cheapest of
the four is the branching form of the first, because the dangerous spelling is distinct
from the benign one and a planted fixture separates them in two lines.

The enumerating agent's own summary is worth keeping: psycopg **fixes** the half of
issue #418 where an error read as empty, because a failed statement raises and `[]`
can only mean zero rows. That improvement is exactly what will tempt a port to drop
the sentinels that close the other half, empty compared with empty.

### 3.7 The guard itself goes quiet

- `guard-as-teardown-fixture-still-reports-passed` — **narrowed, not closed.** Measured:
  the same `AssertionError` raised from a `pytest_runtest_call` wrapper gives `1 failed`,
  and raised from a fixture teardown gives `1 passed, 1 error` — the test's own outcome
  stays `passed`, so anything counting passes sees a pass. This layer's vacuity guard is
  in the call-phase wrapper, and two arms in `test_runshape.py` now pin that placement
  with a control, so a refactor into a teardown reddens rather than going quiet. What is
  NOT closed is the general shape: a guard anyone adds later in a teardown still cannot
  fail its test, and nothing refuses that. See TESTS.md section 10.
- `session-accounting-guard`, `session-exit-rewrite-masks-a-real-failure`,
  `description-guard-reopens-psycopg-raise`,
  `mitigations-measured-and-the-one-that-does-not-work`

## 4. The false-positive budget

A guard that rejects legitimate tests gets switched off, and then the thing it
replaced is gone too. The layer has four escape hatches, each costing more to type
than the honest form: `allow_empty` takes a reason, `--pgc-expect-tests` takes the
real number, `cannot_run` takes a reason from a closed list, and `absent=True`
requires a plan that arrived.

One false positive has already been hit and fixed. The broad-`except` refusal was
first written as a line regex and immediately rejected this layer's own tests,
because they contain the forbidden shape inside a `pytester.makepyfile` string. It
now parses with `ast`, where a handler inside a string literal is not an
`ExceptHandler` node. **A line regex over source cannot tell code from a string, which
is the same mistake as matching a plan by substring.**

The `raises` scan was written with `ast` for the same reason, and the cost of the
alternative is measured rather than argued. Swept over
`test/pytest/*.py` — 16 files, a superset of the 12 the collection hook reaches,
because a module that is not collected today can be collected tomorrow:

| | count |
| --- | ---: |
| `pytest.raises` call sites the AST finds | 5 |
| offences the scan reports on them | **0** |
| lines a `pytest.raises(` line regex would match | 35 |
| of those, inside a string literal or a comment | 30 |

The 30 are not hypothetical. 22 are in `test_raises_sqlstate.py`, which writes the
forbidden shape inside a `pytester.makepyfile` string in every arm, and 8 are in
`pgc_vacuity.py` itself, where the scan's own comments quote what it refuses.
Replacing `ast.parse` with a line regex is mutation M11 of the removal proof: the
layer then refuses **its own test suite** with 22 invented offences, `pytest.UsageError`,
exit 4, and no tests run at all.

## 5. What to add next, in order

Each entry names the red test to write first.

1. ~~`test_expect_query_error_sentinel_is_unique_per_failure` — closes
   `error-swallowed-to-empty`.~~ **Done, and this entry was wrong about the gap.** It
   said "the constant exists and nothing writes it", and both halves were false:
   `test_hilbert_locality.py` already minted sentinels by hand, one of them from inside
   SQL, and the thing actually missing was not a producer but the REFUSAL in four of the
   five comparisons — `expect.text`, `rows`, `row_set` and `ordered_rows` each passed
   with a sentinel on both sides, and only `expect.hash` refused. 3.2 records that
   measurement rather than quietly replacing it. `query_error()` now mints a value
   unique per occurrence, as `lib.sh`'s `QUERY_ERROR.$seq` does, and
   `test_failed_query_sentinel.py` holds ten arms over it — including the producer's
   uniqueness and the constant's NON-uniqueness, which is the reason the producer
   exists at all.
2. ~~`test_layer_requires_a_write_to_have_written` — closes `insert-wrote-no-rows`.~~
   **Done**, and in two files rather than one, because it is two properties. The
   refusal and the tag-versus-count classification live in
   `test_writes_wrote_rows.py`, which needs no database: a stub cursor carrying the
   two measured fields exercises them exactly. Whether the connection the tests
   actually use is watched at all is a different claim, and no driver-free arm can
   make it — `test_the_connection_the_tests_use_is_watched` in `test_connection.py`
   does, through a real `INSERT ... WHERE false`. Splitting them was not tidiness:
   #917's pytest twin tested a function's body and left its CALL SITE uncovered, so
   deleting the call kept that half green while the shell half went red.
3. ~~`test_layer_requires_ab_arms_to_differ` — closes `mutation-arm-unobservable`.~~
   **Done, and it NARROWS rather than closes** — 3.5 says what remains. The assertion
   exists, refuses a failed arm on either side, and the hand-rolled spelling is refused
   by an AST scan so the class cannot come back. What no mechanism can do is notice a
   test that runs an A/B and asserts nothing about the pair, because nothing tells the
   layer which two values are arms.
4. ~~`test_raises_requires_a_sqlstate` — closes `raises-too-broad`.~~ **Done.**
   It closes `raises-too-broad` and narrows `raises-catches-setup`, which stays
   open in 3.4 with the two shapes it cannot see named there. What would close the
   sibling is the next entry:
5. ~~`test_layer_requires_the_raiser_to_be_the_statement_under_test` — closes
   `raises-catches-setup`.~~ **Done, and it NARROWS rather than closes** — 3.4 lists what
   remains, measured: a comprehension or a tuple instead of a `for`, and a helper defined
   in another file. Both are ordinary Python. The refused count therefore did not move.

6. ~~`test_every_at_risk_loop_carries_a_coverage_premise` — narrows
   `assert-inside-a-loop-over-zero-rows`.~~ **Done, and it NARROWS rather than closes**
   — 3.5 has the measurement and names the residual. Half the mode was already refused
   by `pytest_runtest_call`, which fails a test that counted nothing; the half that was
   open is a loop whose assertions sit alongside others outside it. Population measured
   before building: 20 loops non-empty by construction, 0 in the already-refused shape,
   **2 at risk** and both already compliant.

**Every entry on this list is now struck, and the list is checked (#432).** Section 5
was the one part of this document with no mechanism: 1a, 2 and 3 are all compared
against the ids on disk, and this was prose. Entry 1 stayed wrong long after the work
landed, which is the most expensive place in the document for a stale sentence — its
only reader is someone about to build something.

Two arms in `test_docs_cover_the_corpus.py` hold it now:

- every entry names at least one mode id, so it is tied to the inventory at all.
  Entry 1 named none, which is exactly how it stayed wrong: there was nothing to
  check it against.
- no UN-STRUCK entry names an id section 2 already claims as refused. An entry whose
  id has reached section 2 is done by this document's own accounting, whatever the
  test ended up being called.

**What is not checkable, stated rather than implied.** "Has this work been done" is not
mechanical — entry 1's work landed under four test names, none of them the one the
entry proposed, so asking whether the NAMED test exists would have passed and said
nothing. The id is the only durable anchor.

And with every entry struck, the second arm has nothing to refuse on this document, so
it is the planted fixture beside it that keeps it honest: a two-entry document where
moving the open entry's id into section 2 must be caught. A sweep over an empty
population reports the same clean answer as a correct one.

When the next mode is taken, add it here with its id, un-struck, and the arms will
hold the entry to the inventory from then on.

## 6. What this document cannot tell you

None of the 74 refusal designs has been adversarially tested: the stage that would
have tried to defeat them did not run. Every design states its own residual, and
those residuals are the authors' own, unchallenged.

So treat §2 as measured, §3 as measured, and §5 as a plan that has not yet met an
adversary. The layer is known to refuse 28 demonstrated modes -- the ids named in section 2,
not the run's larger total, for the reason section 1a gives. It is not known to be
undefeatable on any of them.
