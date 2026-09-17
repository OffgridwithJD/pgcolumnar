# Release plan to 1.0

Written 2026-08-29. A proposal, not a decision. It exists so the alpha series has
a stated end and beta 1 has an entry test that can be passed or failed.

## The rule this plan is built on

**An alpha may add features. Beta 1 and everything after it may not.**

That single rule decides the whole schedule. Anything we want in 1.0 that a user
can see must land in an alpha. After beta 1 the only permitted changes are fixes,
performance work that adds no surface, documentation, and tests.

Two consequences worth stating before the schedule.

**A feature we defer past beta 1 is deferred to 2.0, not to beta 2.** There is no
later chance inside this release.

**Work that changes what the writer emits is a feature**, even when no function
signature changes. A new default compression tier and a new encoding selector
both change the bytes on disk, so both belong in an alpha.

## Where we are

| version | tagged | contains |
| --- | --- | --- |
| `v1.0-dev` | yes | the first published marker |
| `v1.0-alpha` | 2026-08-04 | native format, scan, maintenance, Arrow and Parquet |
| `v1.0-alpha2` | 2026-08-18 | object storage, Apache Iceberg, parallel bulk ingest and export |
| `1.0-alpha3` | 2026-09-02 | retention, `parallel_copy` deduplication, `sort_status` reporting `sorted_kind` |

The observed cadence is 14 days, from one tag to the next. The dates below keep
it. They are a cadence, not a commitment, and each is the date the tag is cut
rather than the date work starts.

## What is already done

Read this before proposing anything for an alpha, because the list is longer than
the tracker suggests. Exactly one open issue is a feature.

Storage and scan, maintenance, and projections. Arrow and Parquet in both
directions, and external Parquet with pushdown. Object storage and Apache
Iceberg. Parallel bulk ingest and export. The maintenance daemon and retention.
The PostgreSQL integration points we have taken so far.

`MERGE` also works today and is not documented as working. That is a
documentation gap rather than a feature gap. It is verified rather than assumed:
a `MERGE` with both a matched and an unmatched arm updates and inserts correctly
on a columnar target.

## The alpha series

Each alpha carries one theme so that a slipped item moves a whole release rather
than silently widening one. Effort figures come from `design/ROADMAP.md`, which
sources each to a published paper; they are that document's estimates, not new
ones made here.

### 1.0-alpha3, target 2026-09-01

**Already feature-complete**, and it carries more than an earlier draft of this
document said. That draft named three items. The changelog's `[Unreleased]`
section holds **twelve** entries under Added, because everything since the
`v1.0-alpha2` tag of 2026-08-18 is alpha3 content.

The features:

- retention through `pgcolumnar.expire`;
- `pgcolumnar.parallel_copy` refusing a load it has already taken;
- `pgcolumnar.sort_status` reporting `sorted_kind`;
- chunk-group skipping from a predicate on `date_trunc(unit, ts)`, both the
  range and the equality form, which is #403's preimage item;
- chunk-group skipping from `IN (...)` and `= ANY(array)`;
- the scan reporting to the planner the order a sorted rewrite left behind;
- `pgcolumnar.vacuum_sorted()` self-gating when the relation is already sorted;
- the vectorized aggregate accepting a target list that contains aggregates.

Three further Added entries are test and benchmark work rather than user-visible
features. They are the CDC recipe tested end to end, a suite for the replication
and backup claim, and the cross-engine benchmark arms made reproducible.

The arithmetic is shown, because this section exists to correct a miscount.
Twelve Added entries: nine features, three test work. The eight bullets above
cover the nine. The two `date_trunc` entries, the range form and the equality
form, are one capability in one bullet.

Readiness was checked rather than assumed, on 2026-08-29. `VERSION` and
`pgcolumnar.control` agree at `1.0-alpha3`. The upgrade script from `1.0-alpha2`
ships alongside those from `1.0-dev` and `1.0-alpha`. A `COPT=-Werror` build is
clean with zero warnings. `native_upgrade_converge` is 8 of 8, `docs_style` 9,
and `harness_selftest` 168.

Nothing further should be added. It is 11 days into a 14-day cycle.

### 1.0-alpha4, target 2026-09-15. Theme: skipping and layout

- **Hilbert curve clustering. DONE**, merged as #899 (issue #889). It ships as
  two new verbs, `pgcolumnar.cluster_hilbert` and `pgcolumnar.recluster_hilbert`,
  rather than a key-kind argument: PostgreSQL refuses to extend the existing
  `(regclass, VARIADIC name[])` signature in either direction, and an
  array-plus-kind overload breaks the documented `cluster('t','a','b')` call
  style. Both measured on 18.4.

  **The "better locality" claim above was an assertion when this plan was
  written, and it is now a measurement.** It had to be, because the obvious
  fixture cannot show it: on a dense power-of-two-aligned grid whose groups are
  perfect dyadic sub-cubes, the two curves produce the **identical** row-to-group
  partition, so no query can distinguish them. That case is carried as a control.

  On 200,000 rows over two `int` columns with a deliberately non-dyadic
  `stripe_row_limit`, summing the engine's own chunk-group counter over 60 query
  boxes per size, across **two seeds**:

  | query box | Z-order groups read | Hilbert groups read | Hilbert advantage |
  | --- | --- | --- | --- |
  | 2000 | 233 / 241 | 122 / 118 | 1.91x - 2.04x |
  | 5000 | 339 / 351 | 212 / 209 | 1.60x - 1.68x |
  | 12000 | 592 / 588 | 412 / 402 | 1.44x - 1.46x |
  | 30000 | 1623 / 1624 | 1308 / 1313 | 1.24x |

  **Reading the table: in the two count columns FEWER IS BETTER, and in the last
  column LARGER IS BETTER.** A chunk group that is read is a group the scan had
  to open and decode; one that is skipped costs nothing. `groupsSkipped++` and
  `groupsRead++` are the two arms of the same loop in `src/columnar_reader.c`, so
  the count is work done and not work available.

  **The claim is the decay, not the headline.** The advantage shrinks from about
  2x to about 1.24x as the query box grows, and that is the shape a locality
  effect has: a large box must read most groups whichever curve laid them out. A
  constant offset would have been an artifact, and an earlier single-origin
  version of this measurement produced exactly that.

  **The most selective cell is the least reproducible, so do not quote it alone.**
  Across the two seeds the ratio moved +6.94%, +5.03%, +1.80% and -0.32% as the
  box grows -- so the 2x headline is the least stable number in the table and the
  decay is the most stable. Two seeds is a spread, not a distribution;
  a threshold set from this would need more.

  **What that does not license.** Two `int` columns, uniform, one shape. It is
  not evidence for three or four columns or for mixed types, and the ordinal
  layer caps the benefit for types of unequal width -- `bool` against `int4`
  showed no separation at all. It is a count of chunk groups, which is work and
  not time; no timing claim is made, and the per-row key build has never been
  measured inside PostgreSQL. Recorded on #889 with the instrument's own defects,
  three of which produced wrong numbers before they were found.
- **Per-tier block compression defaults. MEASURED, NO CHANGE** (#890). The
  premise did not reproduce on this engine, so nothing about the default moved
  and this item ships as a measurement rather than as code.

  Two things retired it. There is no storage tier to key a default off: a native
  table's blocks always live in the data directory, and object storage is an
  import/export surface rather than a location for native table storage. And
  across five corpus shapes, against a rule registered before the run, **no shape
  fires NET COST** -- the shape the rule names as the decider comes out
  UNDECIDED, and an undecided measurement does not move a default.

  **This item cost nothing in written bytes and therefore did not need to be
  alpha work at all.** That is worth recording: it was scheduled as alpha because
  the plan assumed it would change the writer, and the assumption was the part
  that needed checking first. `design/ROADMAP.md` carries the table and the
  narrow reading of it.

  Three defects found by the investigation are tracked separately and do NOT
  close with it: #1074, #1075, #1076.

### 1.0-alpha5, target 2026-09-29. Theme: join acceleration

**BOTH ITEMS SHIPPED EARLY, IN ALPHA4. This alpha has no scope as written, and
the owner has to give it some or fold it into alpha6.** Recorded 2026-09-17 while
auditing the documentation for the alpha4 tag. Verified rather than assumed: each
commit below is absent from `v1.0-alpha3` and present in `main`.

    9f7dcd8  perf: prune scattered IN lists by element (#752)
    ae623cb  feat: add serial join runtime range filter (#752)
    cbd0c2e  feat: add serial join runtime Bloom filter (#752)
    60ddc10  feat: turn join runtime filter on by default (#752)

The two items as they were planned:

- **Per-element evaluation of a set predicate** (#752). Already specified, with a
  measured ceiling. On a clustered fact table it reaches 9 to 12 chunk groups of
  27, against 25 today. On an unclustered one the ceiling is provably zero. The
  design, the cost bound, the buffer constraint and the negative control are all
  recorded on the issue. **Shipped in alpha4 as `9f7dcd8`.**
- **Runtime filters from a join's build side**, with clustering on the join key as
  a stated precondition rather than an assumption. The ceiling is zero without it,
  which is measured, so the documentation half of this item is as important as the
  code. **Shipped in alpha4, and on by default.** The precondition is documented in
  `docs/how-to.md` and `docs/features.md`.

This is a scheduling fact rather than a problem. The series compressed on
2026-08-29 to reach beta sooner, and work moving forward is that decision
working. But `docs/roadmap.md` still publishes "join acceleration" as alpha5's
theme, and that is now a promise about work already delivered.

### 1.0-alpha6, target 2026-10-13. Theme: encoding and interoperability

- **Adaptive cascade encoding selection.** The primitives exist; the missing piece
  is a sampling selector that chooses per block. High value at low to medium
  effort, and it changes what the writer emits.
- **Parquet partition inference**, the one remaining item inside Parquet.

Two items rather than three, deliberately. The Arrow C Data Interface export was
cut from this alpha on 2026-08-29. alpha6 is now the last one, and the series
should not lose an item it needs to a slip in October.

## What compressing the series costs

The owner chose on 2026-08-29 to compress and reach beta sooner. That removes the
reserve alpha, and beta 1 moves from 2026-11-10 to 2026-10-27.

The saving is real and so is the price. State the price plainly.

**There is no longer a last chance.** With a reserve, an item that slipped moved
one cycle. Without one, an item that slips past alpha6 is deferred to 2.0,
because beta 1 will not take it. The deferral rule was always there; removing the
reserve is what makes it bite.

**The risk concentrates on the final alpha.** alpha6 carries three items, and it
is now the last one. If the series is going to lose something, it loses it there.

**That concentration was acted on.** The owner cut the Arrow C Data Interface
export from alpha6 on 2026-08-29, moving it to the list below.

It was the least load-bearing of the three. The cascade encoding selector changes
written bytes, so it cannot be added later. Parquet partition inference completes
a format we already ship. Zero-copy Arrow export is a new surface that nothing
else depends on. Cutting it deliberately beat losing it to a slip in October.

The consequence is the freeze rule, stated once more because it now binds a real
item: Arrow C Data Interface export is 2.0 work. It does not return in beta 2.

## Not before beta 1

Named so that proposing one later is a decision rather than a discovery. Each is
either a research direction with no specification, or larger than the remaining
alpha series.

| item | why not |
| --- | --- |
| Morsel-driven parallelism | PostgreSQL's parallel workers are process-based and fixed at plan time; large effort against the grain of the host |
| Data-centric JIT with adaptive execution | large effort, and it competes with core's own JIT |
| FastLanes on-disk format generation | a new format generation, so 2.0 by definition |
| ORC, Delta Lake, Hudi | each is a project the size of the Iceberg work |
| Asynchronous write with background compaction | large, and gated on a measurement that has not been taken |
| Arrow C Data Interface zero-copy export | cut from alpha6 on 2026-08-29 to protect the final cycle; a new surface nothing else depends on |

## Beta 1 entry test

Beta 1 is not a date. It is the first build that passes all of the following, and
the date below is only where the cadence puts it if nothing slips.

**Target 2026-10-27.**

1. **The feature set is declared closed.** Every item in the alpha series above is
   either shipped or explicitly deferred to 2.0, in writing.
2. **The full matrix is green**, PostgreSQL 15 through 19. That includes the
   nightly deep gate and the sanitizer gate. It must be green on the tag itself,
   not on a branch.
3. **The upgrade path is gated from every shipped version.** From `1.0-dev`,
   `1.0-alpha`, `1.0-alpha2`, and every alpha tagged after this document.
   `native_upgrade_converge` must reach the beta catalog from each of them.
4. **The on-disk format is frozen for 1.0.** PGCN v1 and the metapage version are
   final. Any format change after this point is 2.0.
5. **Every open performance issue is dispositioned**, which means measured and
   answered, not necessarily fixed. An issue may close as "measured, and the cost
   is inherent"; it may not remain open and unexplained.
6. **The documentation is current against the code.** The currency audit of
   2026-08-29 is the standard. Every function, GUC and default is cross-checked
   against the source. No figure is published without the conditions that
   reproduce it.

## After beta 1

Fixes, performance work that adds no user-visible surface, documentation, and
tests. Beta releases follow the same 14-day cadence until the entry test for 1.0
is met. That test is the beta test above, plus a period with no new defect of the
kind that would change behaviour.

## What this plan does not claim

It does not claim the dates will hold. It claims three things. The cadence is
observed rather than invented. Every item named is traceable to an issue or to
`design/ROADMAP.md`. And the beta 1 test can be failed, which matters, because a
plan whose entry criteria cannot be failed is a wish.

## Cutting a release

**This section exists because it did not, and alpha4 reached tag day with no
release notes**. Every previous release has a `RELEASE_NOTES_*.md`, so the step
was known and simply never written down. A step that lives only in someone's
memory is a step that gets skipped under time pressure.

Documentation, in this order, before the tag:

1. **Write `RELEASE_NOTES_<version>.md`.** Model it on the previous one. Build the
   highlights from what a USER can see, which means the upgrade script, the GUC
   defaults, and the `feat`/`fix` commits touching `src/`. Do not build them from
   the changelog's headline count: alpha4's `[Unreleased]` ran to 4,229 lines and
   almost all of it was test-harness work.
2. **Check the changelog's categories.** Alpha4's headline feature sat under
   `### Fixed`. Keep a Changelog wants Added for new surface, and a reader looking
   for what is new will not find it under Fixed.
3. **Update the two version claims.** They are different sentences in different
   places and only one of them is gated:

       "<version>, recorded in `VERSION`"        gated by docs_style.sh
       "the latest published pre-release is"     agreement-checked only

   The second drifted a whole cycle across README.md, docs/roadmap.md and
   docs/installation.md while the first stayed green. `docs_style.sh` now checks
   that every document making the claim makes the SAME claim, which catches one
   file drifting. It cannot catch all of them being stale together, because no
   tracked file records the newest tag. That is this step's job.
4. **Re-theme the next alpha if its scope shipped early.** Alpha5's two items both
   landed in alpha4, so the published roadmap promised work already delivered.
5. **Run the gates.** `test/docs_style.sh` and `python3
   test/plain_language_check.py docs/*.md README.md`. Release notes are outside
   `docs_style.sh`'s scope by design, so run the language check on the new file by
   hand.

Then the tag itself:

6. `## [Unreleased]` becomes `## [<version>] - <date>`.
7. Tag, then capture the fixture FROM THE TAG (#901):
   `git show v<version>:pgcolumnar--<version>.sql > test/fixtures/pgcolumnar--<version>.sql`.
   Capturing it from the working tree at the next cycle-open is how the alpha2
   fixture came to differ from what alpha2 actually shipped.
