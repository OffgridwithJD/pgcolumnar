# Issue #445: a default-on gate for parallel_flush

Plan, written before code, per the house rule. This finishes #445's serial-load
story: `pgcolumnar.parallel_flush` landed as a proven, opt-in control (#589/#591/
#592). It is off by default because it only pays on one shape and regresses
several others. This work asked whether a gate could let it default ON while
auto-declining the shapes it hurts.

## VERDICT (2026-08-12): NO. Keep it opt-in.

Measured, designed, and adversarially refuted (a workflow of 7 agents plus a
hand-check). **No metric computable at dispatch time -- natts, buffered bytes, or
bytes per value -- separates the win from the losses**, because the deciding
variable is per-column encode CPU and its BALANCE across columns, which the
buffered `.len` fields do not carry. Verified by hand: 20 int2 columns and 5 int8
columns buffer the same bytes but do **6.4x different work** (3680 ms vs 578 ms to
load 500k rows), so buffered bytes is not a work proxy; a random and a constant
column are byte-identical to the metric and opposite in cost. Moving a threshold
cannot fix a metric that lacks the deciding term.

(The specific win/regress ratios the sweep reported are wall-clock noisy -- the
peer's ClickBench ran concurrently on the box -- and should not be quoted. The
structural refutation above is noise-independent and is what the verdict rests
on.)

**Disposition shipped**: default stays `false`; a dispatch observability line
records the metric (helps opt-in users, and makes the refutation checkable);
`test/parallel_flush_optin.sh` pins the default-off + byte-identity + the metric
collision, so the refuted gate cannot be re-added silently. The only path to
default-on is a re-SHAPE of the dispatch around a per-column encode-cost estimate
with per-column partitioning -- a separate design, not a re-calibration of a
bytes/natts threshold. The original plan follows, kept as the record of what was
tried.

## What is already measured (do not re-derive; verify)

From the #592 review and the crossover data on that PR:

- **Wins**: one large flush of many CHEAP (numeric, fixed-width) columns. 41-col
  int / 500k rows: ON 916 ms vs OFF 1058 ms, ~14% faster. Byte-identical.
- **Regresses, badly**: frequent small flushes. 50 flushes of a 5-col 50k load:
  OFF 47 ms vs ON 170 ms, 3.6x slower. Worker spawn + shmem round-trip per flush
  dominates when the flush is small.
- **Regresses**: a wide TEXT-heavy flush, ~+16% (peer). The parallel path copies
  the buffered column bytes through shared memory; varlena buffers are large, so
  the copy overhead exceeds the parallel encode/compress benefit.

So the decision boundary is not just "big vs small". It is whether the
parallelisable per-column encode/compress work exceeds the fixed cost (worker
spawn) plus the shmem-copy cost (proportional to buffered bytes). Numeric-wide is
the only measured win; text and small are losses.

## The question this work must answer FIRST (prove, not assume)

**Can a metric computable at dispatch time reliably separate the win from the
losses?** The dispatch point already gates on `pgcolumnar_parallel_flush && natts
>= 2 && tupdescIsRel && !rel_new_in_current_xact`. The gate adds a size/shape
term. Candidate metrics, to be chosen by measurement not taste:

- total buffered bytes across the stripe's columns (the shmem-copy cost proxy);
- buffered bytes per column, or the varlena/fixed-width split;
- natts, rows-in-stripe, or their product.

If no metric cleanly separates the cases on real shapes, the honest outcome is
**keep it opt-in** and close #445's default-on question as not worth the
misprediction risk. That verdict is a valid result of this work.

## Order of work (TDD, one slice)

1. **Measure the crossover** on a private lane (NOT the peer's pg18 bench lane):
   sweep column count, stripe size, and column type, `parallel_flush` on vs off,
   to find where parallel starts winning and which metric predicts it.
2. **Design the gate** from the measured boundary: the metric, the threshold, and
   how to compute it at the dispatch point without a new pass over the data.
3. **RED test** (`test/parallel_flush_gate.sh`): a wide-numeric stripe must
   dispatch to workers, a small stripe and a text-heavy stripe must stay serial,
   all byte-identical, asserted on an observable (an EXPLAIN/log signal that the
   flush went parallel), with a removal proof.
4. **Implement** the gate, flip the default to on-behind-the-gate, and verify: the
   full suite matrix does not regress (the #592 timeout must not return), the
   wide-numeric win survives, small/text stay serial.

## Adversarial bar

Before implementing, a shape that the proposed gate MISPREDICTS -- goes parallel
and regresses, or stays serial and misses a clear win -- must be searched for and
not found (or the threshold moved until it is not). The gate is only as good as
the worst shape it misjudges.
