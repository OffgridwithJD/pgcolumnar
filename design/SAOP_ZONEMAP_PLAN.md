# IN-list / ANY(array) zone-map pushdown (#704)

## Problem

`pgcolumnar_clause_to_scankey` (src/columnar_customscan.c) accepts only
`OpExpr`, so an `IN (...)` / `= ANY(array)` qual (`ScalarArrayOpExpr`) builds
no scan key and the scan reads every row group. Every comparable predicate
shape (equality, range, anchored LIKE, parameterized scalar) already prunes.

## Design

Add a `ScalarArrayOpExpr` branch that derives a conservative `[min, max]`
range over the array elements and emits two range scan keys. The executor
still rechecks exact membership on every surviving row, so the keys only
need to be conservative (never skip a group that could match), not exact.

Acceptance conditions, mirroring the OpExpr path:

1. `saop->useOr` is true (`= ANY`; `ALL` semantics are different and out of
   scope), left arg (RelabelType-stripped) is a `Var` of the scanned rel with
   a valid attno, right arg is a non-null array `Const`.
2. `saop->inputcollid == attcollation` (same collation rule, same reason:
   the stored min/max are ordered under the column collation).
3. `get_op_opfamily_strategy(saop->opno, <column btree opfamily>)` is
   `BTEqualStrategyNumber`. This admits cross-type equality (e.g.
   `int4col = ANY(bigint[])`); the reader already resolves cross-type
   comparison procs per #477/#483.
4. Detoast the array, deconstruct, ignore NULL elements (under `useOr`
   equality a NULL element can never make the qual true). Zero non-null
   elements: no keys.
5. Order elements with the btree ordering proc for `(elemtype, elemtype)`
   from the SAME opfamily (`get_opfamily_proc(..., BTORDER_PROC)`), compared
   under `saop->inputcollid`; missing proc: no keys.
6. Emit `col >= min` (BTGreaterEqual) and `col <= max` (BTLessEqual), with
   `sk_subtype = elemtype`. `PgColumnarBuildScanKeys` already allocates two
   `ScanKeyData` slots per clause (the anchored-LIKE precedent), so the
   allocation is unchanged. Exception: a list with ONE distinct value
   (`= ANY('{7}')`, `= ANY('{7,7}')`) emits a single BTEqual key instead,
   which is exact for that clause and keeps the reader's bloom probe -- so
   `x IN (7)` prunes like `x = 7` even where every group's range contains 7.

Multi-value lists get range keys, not per-element equality keys: predicates
conjoin ANDwise in `pgcolumnar_group_can_match`, so N equality keys would be
wrong (a group must satisfy all keys), and the SkipPredicate list has no OR
structure. The range is the correct conservative projection of the
disjunction onto that AND-only structure. Consequence for multi-value lists:
no bloom-filter probe (that requires an equality key); a gappy IN-list over
a wide range prunes little. That is the same trade the LIKE-prefix pushdown
makes. Note for the #715 exactness-marker design: the single-distinct-value
key IS exact and IS an equality key; only the multi-value range keys are
weaker than their clause.

Parameterized arrays (`col = ANY($1)`): extend `pgcolumnar_stabilize_quals`
(#697) to freeze a stable non-Const array argument of a `ScalarArrayOpExpr`
the same way it freezes scalar OpExpr operands (no Var, no PARAM_EXEC, no
volatile function; guarded evaluation). A correlated PARAM_EXEC array is
deliberately not frozen, same as #697.

## Hazard analysis (outcome)

An adversarial six-dimension hazard workflow ran alongside implementation
(NULL/empty semantics, collation incl. nondeterministic, cross-type and
domains, memory lifetime across Begin/rescan/planner callers, the freeze
extension, planner/executor consistency and sibling paths). Disposition of
its six must-address findings:

- H1 detoast + lifetime: handled. `DatumGetArrayTypeP` before any header
  access; the detoasted copy and the deconstructed element datums are never
  freed, so the reader's by-pointer retention (`compareValue`) stays valid
  across rescans, matching the LIKE precedent.
- H2 batch-fold eligibility admits quals that build no key: REAL,
  pre-existing, reproduced empirically (`count(*) WHERE x <> 5` counts the
  excluded row with `pgcolumnar.enable_ungrouped_vector_agg=on`). Filed as
  #715 with the repro; not fixed here (its own TDD PR).
- H3 conservative keys must never enter the batch fold: guarded three ways.
  A load-bearing comment at the eligibility gate (columnar_vector.c), a
  matching warning in the builder's header comment, and a live test arm
  (vector-agg count over an IN-list with the GUC on must stay exact).
- H4 vector-agg paths rebuild keys per rescan without freeing: pre-existing
  growth, made larger by arrays. Filed as a follow-up issue; not widened
  into this change.
- H5 domain element types: VERIFIED UNREACHABLE, no code. Probed with the
  domain resolution removed: literal `::intdom[]` cast, ArrayExpr cast, and
  a domain-array parameter under a generic plan all arrive with base-type
  OIDs in the array header and all prune. Shipping `getBaseType` there
  would be a guard that fails "can I delete this and stay green"; the
  domain arms stay in the suite as characterization locks. (Also caught in
  review: `deconstruct_array` asserts the header's own OID, so the naive
  resolution would have tripped assert builds.)
- H6 mixed lists (`IN (1, $1)` on a generic plan arrive as an unfolded
  ArrayExpr): handled by construction — the freeze evaluates the whole
  array argument, not bare Params — and pinned by its own test arm.

Nondeterministic-collation ordering was rated already-handled (the
`inputcollid == attcollation` gate plus zone maps written under the column
collation make the range conservative under the same ordering); the ICU
removal-proof fixture is impossible on this build farm (`--without-icu`),
so the argument lives here rather than in a test.

## Test plan (TDD)

New suite `test/native_saop_pushdown.sh`, modeled on
`native_param_pushdown.sh` (same 40000-row / 20-group fixture, same
`Chunk Groups Removed by Filter` instrument, which counts groups actually
removed, i.e. work done, not keys built).

RED first against an unmodified build; each pruning arm's expected value
failed pre-fix (all read 0). The shipped suite's arms:

- `ts IN (39100, 39200)` removes 19 of 20 groups, with the full instrument
  asserted separately: Pushed-Down Filters = 2 (intent), Usable Skip
  Predicates = 2 (accepted), Removed = 19 (work done); count matches the
  literal-OR equivalent.
- NULL element: `ts = ANY(ARRAY[39100, NULL]::int[])` removes 19, count 1.
- Cross-type: `ts = ANY('{...}'::bigint[])` removes 19, count correct.
- Domain-element arrays: characterization locks (base OIDs in the header;
  see the hazard section) -- prune 19, count correct.
- Single-distinct-value refinement: on a column where every group's range
  contains the probe (premise pinned by a range-only arm removing 0 and an
  equality arm removing 20), `= ANY('{25,25}')` removes 20 via the bloom
  probe.
- Wide list spanning the range removes 0 but counts correctly.
- `NOT IN` with a list confined to ONE group: removes 0 and counts exactly
  (a spanning list could not detect a wrongly derived positive range).
- Empty array and all-NULL array: correct result, backend alive.
- Parameterized: generic-plan `PREPARE p(int[])` removes 19; mixed
  `IN (literal, $1)` (an unfolded ArrayExpr on a generic plan) removes 19;
  a correlated PARAM_EXEC array (LATERAL, per-rescan lists landing in
  different groups with different cardinalities) sums exactly.
- Vector-agg guard: with `enable_ungrouped_vector_agg=on`, the plan shows
  `Batch Fold: no` for the IN-list and `Batch Fold: yes` for the equivalent
  exact range quals (the fold is reachable, only the SAOP is refused), and
  the count stays exact.
- Text column IN-list prunes and counts correctly under the column
  collation.

Removal proofs, each run against the built suite: severing the scankey
dispatch reddens every literal pruning arm (and the parameterized ones,
which need keys too); severing only the freeze extension reddens exactly
the two generic-plan parameterized arms; severing only the
single-distinct-value equality branch reddens exactly the `'{25,25}'`
bloom arm.
