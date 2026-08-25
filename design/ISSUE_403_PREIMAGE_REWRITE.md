# #403 item 1: preimage rewriting for monotonic functions

## The opportunity, measured before building anything

Fixture: 500,000 rows, one day per ~10,000 rows, clustered in time, 50 chunk
groups, `stripe_row_limit => 10000`.

| predicate | chunk groups read | removed | rows |
| --- | ---: | ---: | ---: |
| `ts >= '2024-02-01' AND ts < '2024-02-02'` | **2** | 48 | 10000 |
| `date_trunc('day', ts) = '2024-02-01'` | **50** | 0 | 10000 |

Same answer, 25x the groups read. The zone map holds `ts`; the predicate is
about a function of `ts`, so nothing can exclude a group.

Verified before starting, because the issue is old: `grep -riE 'monoton|preimage'
finds three comments and no code. The existing `date_trunc` handling in
`columnar_vector.c` is a group-COUNT estimate for the grouped node, unrelated,
though it shows the funcid-matching pattern.

## What ships

`f(col) OP const` gains derived scan keys on `col`, where `f` is a function we
can invert. Table-driven on funcid, not a hardcoded `date_trunc` branch: the
technique is a function property plus a rewrite, which is the objection #369
raised against a special case.

v1 handles `date_trunc(unit, timestamp) = const`, emitting `col >= lo` and
`col < hi`.

## Three correctness constraints, each of which can produce wrong answers

1. **A non-truncated constant matches NOTHING**, and my first statement of why
   that mattered was WRONG. `date_trunc('day', ts) = '2024-02-01 12:00'` is
   unsatisfiable. I wrote that emitting `[12:00, next day)` "would admit rows
   the original excludes"; it would not. The keys only PRUNE and the executor
   re-applies the clause, and the derived range is never NARROWER than the true
   matching set (here the empty set, which every range contains), so no row can
   be wrongly admitted or wrongly dropped.

   Established by removing the check and watching the suite stay green, not by
   argument. So the round-trip check is **defence in depth**, not a correctness
   requirement today: it stops mattering only while the keys stay conservative
   AND the executor keeps re-checking. Kept because it is two lines and because
   both of those conditions are the kind that change without anyone revisiting
   this.

2. **timestamptz is EXCLUDED in v1.** `date_trunc(text, timestamptz)` truncates
   in the session `TimeZone`, so the preimage depends on a GUC that can change
   after the key is frozen. Plain `timestamp` has no such dependence. The 3-arg
   form takes an explicit zone and could be added later with that argument read.

3. **The keys are CONSERVATIVE (`exact = false`)**, and this too cannot be
   demonstrated today. Marking them exact changes nothing observable, because
   `pgcolumnar_batch_type_ok` admits only int2/4/8 and float4/8, so the fold
   refuses a `timestamp` column on the TYPE gate before exactness is consulted.
   Verified by marking them exact and watching the suite stay green.

   The suite's "does not engage the batch fold" arm therefore passes for a
   different reason than its name suggests, and says so. Conservative is still
   the right marking: it is what makes the claim true independently of a type
   list that could widen, and exactness would then need its own proof over every
   unit and every value.

## Verification

RED first: a suite asserting the `date_trunc` form prunes chunk groups, which
fails today at 0 removed.

- **work**: `Columnar Chunk Groups Removed by Filter` > 0 on the rewritten form,
  paired with the explicit range as the reference.
- **answers**: identical to the explicit range AND to a heap mirror, for a
  truncated constant, a NON-truncated constant (must return zero rows), NULLs,
  and the extremes.
- **the decline arms**: a non-truncated constant, a timestamptz column, and a
  non-constant unit each emit no derived keys and still answer correctly.
- **removal proof**: revert the rewrite and the work arm returns to 0 removed
  while every answer arm stays green -- the pruning is the only thing that moves.
- **two mutations that did NOT redden**, recorded because they corrected the
  design above: removing the round-trip check, and marking the keys exact. Both
  left the suite green, for the reasons now written into constraints 1 and 3.
  Neither is therefore load-bearing today, and both are kept as defence in depth
  with that stated rather than implied.
