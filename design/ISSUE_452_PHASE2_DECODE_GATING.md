# Issue #452 phase 2: gate payload-column decode for unprunable quals

Plan, written before any code, per the house rule. Read `CONTEXT.md` for the
vocabulary (a stripe is a row group; "Chunk Groups" counters count row groups;
a vector is 1024 values). This is a companion to
`design/ISSUE_452_LATE_MATERIALIZATION.md`, which owns phases 1a/1b-i/1b-ii.

## The terminology fork, stated so it cannot become a stale claim

`ISSUE_452_LATE_MATERIALIZATION.md` uses **"Phase 2"** for **Route B** —
per-vector compression blocks, +29-58% storage. That was measured and
**decided against** (owner call, 2026-08-08: Phase 1 delivers 23x more, do not
spend the storage). Route B is not this document and not being built.

The issue's own comments (jdatcmd 2026-08-10, ChronicallyJD 2026-08-11) use
**"phase 2"** for a *different* piece: gating the per-vector **decode** of
projected columns when the qual is not a `SkipPredicate`. That piece needs **no
format change** and is what this plan builds. To avoid two things wearing one
name, this document calls it **decode-gating for unprunable quals**; if a phase
number is wanted it is **1d** (it rides on 1a's callback and 1b-i's masked
decode), not 2.

## What is there today, verified in source at `dde753a`

- The group loader runs **two decode passes** (`columnar_reader.c:1914`): pass 0
  decodes the qual columns, `pgcolumnar_native_refine_skipvec` runs between the
  passes, pass 1 decodes the payload columns and honours `nativeSkipVec`, so a
  masked-out vector costs the payload columns **no decode** (`decode_chunk`
  takes `rs->nativeSkipVec` and reports `vdecoded`, `:1968`).
- `refine_skipvec` **early-returns when `rs->numPredicates == 0`**
  (`columnar_reader.c`, the guard `... || rs->numPredicates == 0 || ...`). It
  refines the mask only from `rs->predicates[]` — reader-side `SkipPredicate`s
  (strategy + constant + compare fn), btree-only.
- A **leading-wildcard `LIKE '%x%'` is never a `SkipPredicate`**, so
  `numPredicates == 0`, no mask is built, `nativeSkipVec` stays NULL, and pass 1
  decodes **every payload vector in full** regardless of how few rows survive.
- 1a already threads the executor qual to the reader as a **per-row callback**:
  `PgColumnarReadNextRowFiltered(..., cstate->qualCols,
  pgcolumnar_scan_row_filter, ss)` (`columnar_customscan.c:2096`). But 1a runs
  that callback in the **row producer**, after both decode passes, so it saves
  per-row *materialization* (cost 3) and never per-vector *decode* (cost 2).
- The fold path was taught to honour the mask and to **poison holes** in skipped
  vectors (1b-i, #512/#542). Any new writer of `nativeSkipVec` inherits that
  contract: a vector marked skipped must be safe for the fold to not read.

## The gap, in one line

For a qual that is not a `SkipPredicate`, nothing evaluates it before pass 1, so
the payload columns are decoded for rows that cannot survive. ChronicallyJD's
measured ceiling: `SELECT *` with `tag LIKE '%HIT%'` (600 of 3,000,000), 21
columns, **81% of the 456 ms is decoding the 20 payload columns for ruled-out
rows**, and it is invariant to selectivity (600 vs 0 survivors: 449 vs 455 ms).
The codec (cost 1, decompression) is only ~3% (jdatcmd, 2026-08-08: q24 codec =
202 ms = 3.36%), which is why this does not need Route B.

## The design: hoist 1a's callback to group-load, per vector

Add a third mask writer, running in `pgcolumnar_native_load_group` **between the
two passes**, active exactly when `refine_skipvec` is not (`numPredicates == 0`
but a qual exists and 1a's late-mat path is on):

1. Pass 0 must have decoded the qual columns. **It does not today for this
   case**: the decode split is `native_is_qual_column`, which is
   *predicate*-based (`rs->predicates[].attidx`) and therefore empty when
   `numPredicates == 0` — a `LIKE`'s column decodes in pass 1 with the payload,
   too late to gate anything. So phase 2 extends `native_is_qual_column` to also
   answer true for the executor `qualCols` **only when `numPredicates == 0`**,
   which leaves 1b-ii's predicate path byte-for-byte unchanged and moves the
   `LIKE`'s column into pass 0 exactly in the case that needs it.
2. For each vector `v` (rows `nativeVecStart[v] .. nativeVecStart[v+1]`),
   materialize the **qual columns only** for those rows into the scan slot and
   call the executor qual (reuse `pgcolumnar_scan_row_filter`, the exact
   predicate 1a already trusts). If **no** row in the vector passes, set
   `nativeSkipVec[v]`.
3. Pass 1 decodes the payload columns against the sharpened mask — the machinery
   is unchanged; it already skips masked vectors and poisons their holes.

Properties that make this safe and correct:

- **Conservative in the safe direction.** A vector is skipped only when *no* row
  passes; a surviving row keeps the whole vector's payload decoded (correct —
  decode granularity is the vector). Missing a skip costs time; never rows.
- **No double-eval hazard beyond 1a's.** 1a already guards the whole late-mat
  path off for a **volatile** qual (`contain_volatile_functions`, Begin). This
  rides on that guard: an unprunable volatile qual takes neither 1a nor this.
- **Fold-path contract honoured for free.** The mask is the same `nativeSkipVec`
  the fold already reads and whose holes it already poisons (1b-i). No new fold
  change — but the acceptance suite must include a fold-shape arm to prove it,
  because "no change needed" is a claim like any other.
- **Baseline (`allDescriptor == false`) columns opt out.** A D2b-baseline chunk
  has no per-vector structure; the loop already disables per-vector skipping for
  it. This writer must respect the same `allDescriptor` gate, or it would mask a
  vector whose payload cannot be skipped anyway.

## The RED test, written first (acceptance check 3 from the parent doc)

Parent doc's check 3: *a qual that cannot be pushed down must still get the
benefit, asserted on work done (vectors decoded), not blocks read* — because I/O
does not move for this and a `BUFFERS` check would pass with the feature deleted.

`test/native_decode_gating.sh` (new suite, registered sorted in `SUITES`):

- Fixture: one wide table (a narrow `tag text` qual column + N wide payload
  columns), enough rows for many vectors per row group, `tag` values arranged so
  a leading-wildcard `LIKE '%needle%'` matches rows in **few** vectors and zero
  in the rest, with the survivors clustered so most vectors are all-rejected.
- **Premises (assert before measuring):** the qual is not pushed down
  (`numPredicates == 0` shape — assert via EXPLAIN that no reader predicate/zone
  pruning applies, `Chunk Groups Removed = 0`); the row count is as expected; the
  survivor count is small and > 0.
- **The measurement:** `SELECT *` under the LIKE. Assert `Columnar Vectors
  Decoded` for the payload columns drops materially versus the same query with
  the feature off, and that decoded + skipped == the group's vectors (the exact
  identity, not merely "fewer" — "fewer" passes on skipping one vector).
- **A zero-survivor arm** (`LIKE '%nomatch%'`): payload decode approaches zero;
  the wide `SELECT *` figure approaches the `count(*)` figure (parent doc's
  acceptance check 2, restated for the unprunable qual).
- **A fold arm:** a `count(*)`/vectorized-aggregate shape over the same fixture,
  asserting the fold still returns the correct aggregate with the new mask writer
  active (poisoned holes are not read).
- **Removal proof:** delete the new mask writer → the decoded-count assertion
  goes RED for the stated reason (all payload vectors decoded again), not for a
  fixture or connectivity reason. Prove the premise can fail
  (`assert-the-fixture-premise`): a wrong needle that matches everything must
  make the "few vectors decoded" check fail.
- **Path assertion, both arms** (`assert-the-execution-path...`): assert the
  scan is the columnar custom scan on the late-mat path (not a fold, not a seq
  scan) for the `SELECT *` arms, or the timing/decode counts measure the wrong
  node.

## What the implementation actually required (recorded, not the plan)

Two things the plan above did not foresee, found by building and measuring, kept
because the correction is the useful part.

**1. `build_skipvec` allocated nothing without a predicate.** It returns early on
`numPredicates == 0`, so neither the mask nor `nativeVecStart` (the per-vector row
spans the evaluator needs) existed for an unprunable qual -- the mask read
`(nil)` and the evaluator did nothing, silently. The guard is now "allocate when
a mask will be CONSULTED": reader predicates OR a phase-2 qual
(`nativeQualFilter` set). The plain scan with neither still allocates nothing, so
that path is unchanged. The predicate-exclusion loop is a no-op at zero
predicates, so the phase-2 case falls through it with an all-false mask.

**2. Reusing 1a's filter double-counted "Rows Removed by Filter".** 1a's callback
increments `InstrCountFiltered1`. The evaluator walks every row, so it counts
every rejection once; the producer then re-tests a surviving vector to find the
rows to emit and counted the same rejections again. Fix: the evaluator is the
group's SOLE counter (it walks every live row through the counting filter), and
the producer filters through a NON-counting variant on this path
(`nativeQualCounted` flags it). Rows in a fully-skipped vector never reach the
producer, so the evaluator adds them to "Rows Filtered Before Materialization"
where it rules the vector out. Net: both counters equal the non-matching row
count, whether a row was ruled out one at a time or a whole vector at once. The
new suite asserts both, because the first version measured only the decode saving
and would not have caught this.

The 1a suite (`native_late_materialization.sh`) was retargeted so its needle
falls in EVERY vector (one per 1024, not one per 2048). That keeps a survivor in
each vector, so phase 2 rules none out and the suite measures 1a in isolation, as
its own premise ("nothing pruned at the vector level") requires. Phase 2's vector
skipping is proven in `native_decode_gating.sh`.

**Cost note.** The evaluator runs whenever the qual is unprunable and the group
has per-vector structure, so on a non-selective unprunable qual (survivors in
most vectors) it pays one extra qual evaluation per row for no decode saving. The
qual runs on the already-decoded qual column, so it is cheap next to the payload
decode it saves in the selective case; gating it on a selectivity or
projection-width estimate is a possible follow-up, not done here.

## What this explicitly does not do

- Not Route B; no per-vector compression; storage headline untouched.
- Nothing for cost 1 (whole-chunk decompression) — that stays ~3% and needs a
  format change nobody has approved.
- Not #426 (making text predicates *prunable* at the reader). This makes the
  unprunable ones *cheap to evaluate late*; #426 and this compound but are
  independent.

## Order of work (vertical slices, one red → green at a time)

1. RED suite above, unregistered, confirmed red on `dde753a` for the right
   reason (payload vectors all decoded). Do not register a red suite.
2. Minimal green: the between-pass mask writer, gated on `numPredicates == 0 &&
   lateMat && allDescriptor`, reusing `pgcolumnar_scan_row_filter`.
3. Register the suite (sorted), run `harness_selftest` + `docs_style` (whole-tree
   suites), then the PG18 arm, then the full matrix once at the end.
