# Issue #405: Position-level late materialization (Abadi), planned and stress-tested

Plan written before code, per house rule. Produced by a multi-agent investigation
(four parallel readers over the decode path, scan interface, counters, and cost
model), a synthesized TDD plan, and an adversarial critique that overturned the
plan's own recommendation. Every load-bearing citation was read against `main`
and the two crux claims were re-verified by hand before this doc was written.

## TL;DR — RETRACTED for the row path; the fold path's gap is REAL (second correction)

**This TL;DR has been corrected twice, and both corrections are kept legible
because each one was caught by the discipline the other skipped.**

1. An earlier revision reported the Step 1 gate CLEARED at 41–58% recoverable.
   That measurement compared two different execution paths and is withdrawn.
   Caught by implementing Step 2 and finding its work-done counter read 0.
2. The first retraction then over-corrected: it concluded "the fold path never
   carries payload, so there is nothing to defer anywhere." **That was an int8
   artifact, not an architecture fact** (review on PR #601): the Step-2 counter
   read 0 because the fixture's payload was int8, and `sum(int8)` is one of the
   shapes the fold classifier rejects. Payload-carrying shapes over int2, int4,
   float4 and float8 DO take the fold, their payload cost is flat in
   selectivity (paid for every non-skipped row before the key check), and the
   measured recoverable share is ~11% of a wide query on incompressible float8
   at 1% selectivity, with a derived ceiling of ~4.6x on highly compressible
   payload.

**What stands: there is no recoverable gap on the ROW path — #452 Phase 1a
already defers there.** On the (default-off) fold path the gap the
pre-retraction plan targeted is real on the shapes below, bounded by the gather
share of payload cost, and the cost-model requirement (kill shot 4's
successor) is re-confirmed: recoverable ≈ gather × (1 − selectivity), so at
high survival there is nothing to win.

### What the invalid gate did wrong

The gate compared `T_qualonly = count(*)` against `T_wide = count(*) + sum(payload)`.
But **`count(*)` batch-folds (a fast path) while any `sum(payload)` falls back to
the row path** (`Columnar Batch Fold: no`, verified). So `T_wide − T_qualonly`
measured the batch-fold-vs-row-path difference, not payload materialization cost.
Apples to oranges.

### What the corrected, like-with-like measurement shows

Same row-path query (`sum(payload)`), only selectivity varies (PG18 non-assert,
4M rows, 8 byval int8 payload):

| selectivity | T (ms) |
| ---: | ---: |
| 1% | 544 |
| 10% | 735 |
| 50% | 1519 |
| 99% | 2448 |

**T scales 4.5x with selectivity.** Payload cost already tracks how many rows
pass — which is exactly what late materialization does. **#452 Phase 1a already
defers payload materialization on the row path**, confirmed. The 1%-selectivity
floor (544 ms) is dominated by qual-column decode and whole-vector payload
decode (comp-vs-rand at 1%: 421 vs 537 ms, so 116 ms is payload decode), neither
of which is cheaply position-deferrable (`decode_delta/dict/fsst` are sequential
streams — the adversary's original point).

### The fold-path census (corrects "it never carries payload")

`pgcolumnar_batch_agg_ok` (`columnar_vector.c`) accepts `count(*)`,
`count(col)`, and `sum`/`avg` over int2, int4, float4 and float8 — all
payload-carrying — and rejects `sum`/`avg` over int8 (whose transition type is
numeric) and numeric, `min`/`max`, and any aggregate list containing one
ineligible member. Verified in code and empirically on two independent lanes
(PG18 assert in the #601 review; PG17 non-assert by the author:
`sum(int4)`/`sum(float8)`/`avg(int4)` report `Batch Fold: yes` under ANALYZE,
`sum(int8)`/`max` report `no`, on the post-#602 line that reports the fold
that RAN).

The earlier claim "every `sum(pN)` shape reports Batch Fold: no" was a true
observation whose scope was the fixture's payload type — int8 — not the fold
path. The Step-2 work-done counter read 0 for the same reason. The #601
review's like-with-like measurement on float8 payload (fold pinned in every
timed run, arms interleaved, median of 7) decomposes the fold's payload cost
at 1% selectivity into ~2,579 ms whole-vector decode (kill shot 1 stands: the
reorder cannot recover it) and ~330 ms gather (~10.3 ns per row·col,
reproducing this doc's 11.7 ns figure on the valid comparison), against a
2,998 ms fold total — flat to 3,147 ms at 99% selectivity.

### Outcome (corrected on PR #601 review)

**Row path: #405 item 1 is implemented by #452 Phase 1a.** Steps 2–4 as
originally scoped (row-path-shaped) stay dropped; the abandoned Step 2 branch
stays abandoned.

**Fold path: the gap is real on the census shapes above and the pre-retraction
plan's Step 2 (the gather reorder) is worth ~11% of a wide float8 query at 1%
selectivity, with a ~4.6x derived ceiling on highly compressible payload.**
Whether that justifies rebuilding Step 2 is a scheduling call recorded on
#405, not made here; two facts bound it: `enable_ungrouped_vector_agg`
defaults to off, so no default configuration reaches the gap, and Step 4's
cost model is mandatory because the recoverable share vanishes at high
selectivity. The byval-only gate stands, so none of this touches q24.

The rest of this document below is the pre-retraction plan, kept for the
verified architecture facts (the plumbing verdict, the two decode
granularities, the #452 1a row-path deferral, the fold-path kill shots that
survive) — its Step 2/4 shapes are the starting point if the scheduling call
above is ever taken.

---

## (superseded) TL;DR — the measured conclusion (Step 1 gate: CLEARS)

**Superseded by the retraction above.** The gate cleared on an invalid
measurement. Retained for the record.

The plan predicted the fold-path residual was "a single L1-resident `fetch_att`
load, not a decode", low single digit percent, likely a no-op. **Measured on PG18
non-assert, 4M rows, 8 byval int8 payload columns, 1% selectivity:**

| quantity | ms | note |
| --- | ---: | --- |
| payload LOAD cost (decode-free `comp` table) | 374 | the `fetch_att` + bookkeeping slice (b) targets |
| payload DECODE cost (`rand` − `comp`) | 122 | whole-vector decode; slice (b) cannot recover this |
| **load : decode** | **3.1 : 1** | **the load DOMINATES decode, the opposite of the prior** |
| recoverable residual (slice b removes fetch_att+stores for the 99% failing rows, keeps cursor advance) | **222–315** | **41–58% of the realistic wide query** |

Per (row,col) the load path is ~11.7 ns (~35 cycles), far more than "a single
register load" — the `fetch_att` + two stores + macro overhead per payload value,
done for every non-skipped row before the key check, is the dominant fold-path
cost on this shape. The threshold the plan set ("low single digit percent") is
cleared by ~10x.

**So Step 1 CLEARS and Step 2 is unblocked** — but scoped by what the measurement
also confirms:

- **byval only.** The fold path rejects varlena (`batch_shape_eligible`,
  `columnar_vector.c:3048`), so this does NOT help q24. The win is for
  byval-wide-aggregate shapes (numeric-aggregate ClickBench queries with many int
  columns and a selective filter). q24's varlena payload is the row path, where
  #452 1a already defers. The adversary's KILL SHOT 2 stands.
- **selectivity-gated.** At 99% selectivity the recoverable residual is ~1%
  (measured), so deferral is a loss there. Step 4's cost model is genuinely
  required, not optional.

The load-vs-decode isolation was the decisive experiment: a constant payload
(14 MB on disk, near-free RLE/FOR decode) vs a random payload (255 MB, full
decode) at the same 1% selectivity. Their gap is decode (122 ms); the constant
table's payload cost is load (374 ms). Load being 3x decode is what refutes the
"cheap register load" prior.

One premise nearly voided the whole measurement and was caught by asserting the
plan node: the first fixture (mixed `sum(int4)`, parallel not pinned) silently
took the ROW path (`Aggregate -> Custom Scan`), not the fold node. A row-path
measurement would have shown late-mat already present (#452 1a) and drawn the
opposite conclusion. The corrected fixture pins serial and asserts
`Columnar Vectorized Aggregates` appears before any timing is trusted.

## 0. What is true today (verified against main)

Two decode granularities exist, and the #405 dichotomy resolves between them:

- **Whole-vector chunk decode** — the expensive per-value work.
  `pgcolumnar_native_load_group` runs a two-pass loop
  (`columnar_reader.c:1917-1990`) calling `pgcolumnar_native_decode_chunk` per
  projected column. It is all-or-nothing per 1024-value vector; the only skip is
  `nativeSkipVec[v]`, a per-vector `bool*`. `pgcolumnar_native_refine_skipvec`
  (`columnar_reader.c:1064`) sets `any = true; break;` on the FIRST surviving row
  (`:1146-1155`) and keeps one bool per vector — it discards which positions
  matched, which is exactly the position list Abadi wants.
- **Per-position value materialization** — cheap. `fetch_att` /
  `PgColumnarDecodeValue` reads one already-decoded value.

Two late-materialization mechanisms already exist:

1. **Row path already does position-level slot deferral (#452 Phase 1a).**
   `pgcolumnar_native_next_row` (`columnar_reader.c:2206-2268`): decode qual
   columns, run `filter()`, read payload columns only for survivors, else
   `pgcolumnar_row_skip_column`. **Verified.** So "a scattered predicate
   materializes every projected column for every row that reaches the filter" is
   FALSE on the row path.
2. **Batch-fold / vectorized-aggregate path does NOT.** `columnar_vector.c:3276-3322`
   `fetch_att`s every needed column for every non-skipped row before the scan-key
   check. This is the only real gap.

## 1. Plumbing verdict

**A position list can be carried from the vector filter to slot materialization
with NO table-AM interface change.** The primary SELECT path is the custom scan,
which bypasses `scan_getnextslot` entirely; the aggregate path is internal
extension state. On the fold path the "position list" is not even a new
structure — the row index `r` and the scan-key pass already live in the same loop
as the payload `fetch_att`, so position-level deferral there is a *reorder within
one loop*. The `#413`/`#363` constraint binds the index-fetch deferred slot, a
different surface, untouched here.

## 2. Why the plan does not survive its own scrutiny (the five kill shots)

An adversarial pass verified the mechanics are real and the "delete-and-reddens"
property holds, then showed green does not imply benefit:

1. **The fold-path counter measures cheap work, not the motivating cost.** By the
   time control reaches the gather loop the vectors are ALREADY decoded
   (`cpacked[col]` is the decoded packed stream, `columnar_vector.c:3186-3200`).
   `fetch_att(ptr, true, len)` with `byval=true` is a single aligned register
   load. Slice (b) removes only those loads for failing rows. The ~3/4 per-value
   cost #405 cites is the *decode*, which ran whole-vector before this loop and
   which the plan explicitly refuses to touch. A true counter drop that does not
   track wall-clock is the `publish-ratios-with-baselines` trap.
2. **The fold path is byval-only, so q24 can never reach it.**
   `pgcolumnar_batch_shape_eligible` (`columnar_vector.c:3011-3053`) rejects any
   non-`attbyval` projected column, with a comment naming ClickBench q21's
   `URL LIKE` and stating the varlena case falls back to the row path. **Verified
   at `:3048`** (`if (!TupleDescAttr(tupdesc, c)->attbyval)`). q24's text payload
   runs on the row path, where #452 1a already defers. Slice (b) contributes
   nothing to q24 — not "needs #426", but structurally inapplicable. Worse, the
   cost model's win region ("wide projection") is self-contradictory: wide payload
   is usually varlena, which forces fallback off the fold path.
3. **The cost-model slice is wired to the wrong node.** The plan targets the
   *scan* custom path's `custom_private`; the fold optimization lives in the
   *aggregate* node (`columnar_vector.c:1113/1796`, executed by
   `PgColumnarBeginAggScan`). The agg node's `custom_private` is a fixed
   positional schema and `list_length == 5` is the grouped-vs-ungrouped
   discriminator (`customscan.c:1675`); stamping a boolean in would misroute the
   node.
4. **The width split is computed in the wrong context.**
   `pgcolumnar_projected_width_fraction` reasons over the scan target list; for an
   ungrouped filtered aggregate the deferrable payload is the aggregated-column
   width off `input_rel`. (`S = rel->rows/rel->tuples` IS available at plan time,
   so selectivity is not the missing input — the width context is.)
5. **Label collision violates the plan's own #493/#522 rule.** Incrementing one
   `Columnar Payload Values Materialized` label on both the fold `fetch_att` (a
   byval load) and `pgcolumnar_row_read_column` (whose non-byval branch is a real
   `PgColumnarDecodeValue`) makes one EXPLAIN line mean cheap load on one plan and
   expensive decode on another.

And an ordering defect: slices (a) and (b) are the before/after halves of one
work-done assertion, not two independently mergeable slices — (a)'s baseline pin
breaks the moment (b) moves the increment site.

## 3. The revised plan — measurement-gated

### Step 1 (the real RED test, and the gate): prove the wall-clock

Before any reorder, add a timing arm on a fold fixture that isolates the
per-discarded-row residual as a fraction of fold runtime *after* decode:

- Fixture: an ungrouped filtered aggregate, `SELECT sum(a), sum(b), ...
  WHERE qual <op> const` with no GROUP BY, all payload columns **byval** (so the
  fold path is actually taken — a varlena column silently routes to the row path
  and the test measures nothing, a false green: sanity-check the plan node).
- Data laid out so every vector's zone map spans the constant (locally dense), so
  `build_skipvec`/`refine_skipvec` prune nothing and true row selectivity is low.
- Assert the residual is above a threshold worth optimizing (predict low single
  digit percent). **If it does not clear the threshold, stop here — steps 2-4 are
  dropped.** Record the number on #405.

The `fetch_att` counter may accompany this arm but must never stand in for it.
The counter reddens on revert honestly; it just does not track benefit.

### Step 2 (only if Step 1 clears): fold-path deferral, one work-done test

Collapse the counter and the reorder into ONE before/after test at a STABLE
increment site (post-key, chosen once). Reorder `columnar_vector.c:3276-3322`:
gather key columns, evaluate scan keys into `pass`, `fetch_att` non-key columns
only when `pass`; advance present-index cursors for deferred columns without
reading, preserving the `vecSkipped`/deleted consume-slot-don't-read contract.
Removal proof: revert the reorder, counter returns to eager, test reddens.

### Step 3: fix the label collision (blocks any merge)

Two distinct counters — `Fold Payload Loads` (byval, fold) vs `Row Values Decoded`
(`PgColumnarDecodeValue`, row) — or a single counter placed only at the real
decode. One EXPLAIN line, one quantity.

### Step 4: cost-model guard, on the right node

Re-target to the agg upper-path (`columnar_vector.c:1113/1796`): append the
enable flag as a NEW TRAILING `custom_private` element AND update the
`list_length` discriminator (`customscan.c:1675`) and the positional parse
(`:1986-1988`) so grouped/ungrouped routing survives; read it in
`PgColumnarBeginAggScan`. Compute the width split in the agg context
(aggregated-column width off `input_rel`), not the scan-path function. Fall back
to eager when stats are missing. RED test: a narrow/high-survival fixture must not
enable deferral and must show no added per-group work (the #289 guard).

### What must NOT be attempted

- No table-AM interface change (verified unnecessary).
- **No decode-level position-selective variant.** `decode_delta/dod/for/gorilla`
  are running-state sequential streams, `decode_dict`/`decode_fsst_shared` have no
  cheap random-position access; "decode the whole vector then keep survivors"
  saves the copy but not the decode, measuring as a near-total loss. This is the
  variant that WOULD save the motivating cost, and it is out of scope precisely
  because it is not cheap.
- No new WAL semantics (read-path only).
- The #289 narrow-scan guard is mandatory: no eager per-group precompute.

## 4. Honest framing and dependencies

- **Item 1 of #405 is largely already implemented** (#452 Phase 1a, row path).
  The genuinely new work is the fold/aggregate path, which is byval-only and
  cheap.
- **This does not advance q24**, and the reason is structural (varlena → row path),
  independent of #426. Delete any implication otherwise.
- **Items 2 (branch predication) and 3 (vector size vs column count)** stay
  recorded on the issue as microbenchmark questions; neither should be touched
  without a microbenchmark, and neither is scheduled here.

## 5. What to tell the issue

Recommend #405 stay open with item 1 re-scoped to "the batch-fold path lacks
position-level late-mat, but it is byval-only and the residual is a decoded-buffer
load, so the win is bounded by a wall-clock measurement not yet taken." The row
path — where the expensive varlena decode lives — already defers. The measurement
in Step 1 decides whether even the fold slice is worth it; the honest prior is no.
