# #403 item 2: what does locating the surviving chunk groups actually cost?

Status: **measurement in progress**. No issue filed, no code changed.

## Why this document exists

#403 recommends breaking out item 2, a sparse sort-key index over chunk groups.
My own comment on that issue refused to file it, and set a gate:

> "667 today, 66,700 at a hundred times the size" is an extrapolation. Nobody has
> measured what zone-map evaluation actually costs as a fraction of a scan at
> either size. That is a cheap measurement and it should come before an issue, or
> the issue starts with a number nobody checked.

This is that measurement. It decides whether item 2 is worth an issue, and --
more usefully -- whether a sparse index is even the right answer, or whether the
linear cost is dominated by something cheaper to fix.

## What the code actually does (read, not assumed)

`pgcolumnar_native_load_group` (`src/columnar_reader.c:2063`) walks the row-group
list and for each candidate calls `pgcolumnar_native_group_can_match`
(`src/columnar_reader.c:1347`), which for each pushed-down predicate calls
`PgColumnarReadZoneMapForColumn` (`src/columnar_metadata.c:2633`).

That last function is **not** a min/max comparison against an in-memory array.
Per call it does:

- `open_columnar_table("zone_map", AccessShareLock)` -- `pgcolumnar_schema_oid()`,
  `get_relname_relid`, `table_open` with a lock. The `md_flush` reuse cache is
  write-path only (`md_flush.active`), so the read path never hits it.
- `pgcolumnar_index_oid("zone_map_pkey")` -- a second `get_relname_relid`.
- `systable_beginscan` / `getnext` / `endscan` on the catalog index.
- `table_close`.

So the per-group cost is a catalog index probe plus two name lookups and a
relation open, **per predicate column**, not a pair of integer compares. #403's
framing ("66,700 min/max comparisons") therefore *understates* the cost, which is
the opposite of the error I was guarding against when I refused to file it.

Caching is `zoneLookedUp[]`, which is per group, not per scan.

## The claim under test

> Locating the surviving chunk groups is linear in the total number of chunk
> groups, and at scale that cost is a material fraction of a scan.

## Instrument

Primary: **buffers**, from `EXPLAIN (ANALYZE, BUFFERS)` on the columnar scan
node. Catalog index probes read buffers, `pgBufferUsage` is accumulated per node,
and the count is deterministic -- unlike wall clock on this host, which
[[perf-measurement-on-this-host]] records as unusable (12% within-arm scatter, an
A/B that reversed when arm order flipped). The code's own comments at
`columnar_reader.c:1400` already price this path in buffers.

Secondary: backend instructions via `perf stat -p`, read per the hybrid-PMU rule
(take the PMU that held ~the whole window; refuse the run otherwise).

## Design: slope, not a single number

A single "it cost X buffers" says nothing about linearity. So: hold the *matched*
work fixed at exactly one chunk group and vary N, the total number of groups.
The slope of buffers against N is the per-group locate cost; the intercept is
fixed setup plus the one group actually read.

Two costs are both linear in N and must not be conflated:

- **(a) scan-start row-group list load** -- reading the row-group metadata for the
  whole storage, paid whether or not a predicate prunes.
- **(b) per-skipped-group zone-map probe** -- the loop above.

They are separated by **varying the number of predicate columns**: (b) scales
with predicate columns per group, (a) does not. With slopes S1 (one predicate
column) and S2 (two predicate columns, both selecting the same single group):

    b_per_col = S2 - S1
    a         = S1 - b_per_col = 2*S1 - S2

This decomposition is falsifiable, which is the point: if adding a second
predicate column does not move the slope, the model is wrong and the number is
not published.

## Premises to assert before any ratio is believed

Per CONTEXT.md ("assert the premise", and `zonemap_cost` priced pruning for a
year while pruning zero groups):

1. `Columnar Chunk Groups Removed by Filter` == N-1 on **every** arm. If the arm
   does not prune, its slope is not the skip loop.
2. The chunk-group count is read from `pgcolumnar.row_group`, printed from the
   data, never derived from `rows / stripe_row_limit`.
3. The scan node under measurement really is `Custom Scan (PgColumnarScan)` on
   every arm ([[assert-the-execution-path-not-just-the-fixture]]).
4. Row counts returned are identical across arms, so the arms did equal real work.
5. Both predicate columns in the S2 arm must actually be pushed down -- assert
   the pruning is unchanged (still N-1), or S2 differs from S1 for the wrong
   reason.

## Falsification / removal proof

A measurement's removal proof is that the instrument moves when the thing moves.
Planned:

- Bloom filters off/on must not change the pruning arm (zone map already excludes,
  so the bloom is never consulted -- `columnar_reader.c` says so; if the number
  moves, that comment is wrong).
- Drop to zero predicate columns (full scan): buffers must jump by orders of
  magnitude, proving the instrument is reading scan work at all.
- The slope must be positive and reproducible across a reversed N order.

## Decision rule, written before the numbers

Written first on purpose, so the threshold is not chosen to fit the result.

- If locate cost at a realistic large N is **< 2%** of the scan it gates: item 2
  is not worth an issue. Record the number in #403 and close the item.
- If it is **2-20%**: the fix is probably not a sparse index. It is caching the
  relation open and the two name lookups across the scan, or fetching the group's
  zone maps in one ranged scan instead of one probe per group. Cheaper, no new
  on-disk structure. File that instead.
- If it is **> 20%** at a size people will actually run: item 2 earns its issue,
  and the issue opens with this number.

---

# Results

## The mechanism, confirmed against the source

`zone_map_pkey` is `(storage_id, group_number, column_index, vector_index)`
(`pgcolumnar--1.0-alpha2.sql:247`). A per-group probe is therefore a tight
three-key prefix, which is what the reader does -- one index probe per group per
predicate column.

Relation reuse exists in this codebase (`PgColumnarBeginMetadataFlush` /
`open_columnar_table`'s `md_flush` cache) but is called **only** from
`columnar_write_state.c`. The read path has no equivalent, so every probe pays
`pgcolumnar_schema_oid()` + `get_relname_relid` (twice: table and index) +
`table_open` + `table_close`.

## Buffers: the linear cost is entirely the zone-map probe

Fixture: `zc(k, w, v)` bigint, `stripe_row_limit = 10000`, N chunk groups, a
predicate selecting exactly one group. Premises asserted on every arm: group
count from `pgcolumnar.row_group` agrees with EXPLAIN's `Chunk Groups Total`,
`Chunk Groups Removed by Filter` == N-1, node is `Custom Scan (PgColumnarScan)`,
and both pruning arms return the same 10,000 rows.

| arm | slope (buffers per group) | intercept |
| --- | ---: | ---: |
| one predicate column | 6.1 | ~458 |
| two predicate columns | 12.1 | ~463 |

Decomposition, per the plan written before the numbers:

    b_per_col = S2 - S1 = 6.0 buffers per group per predicate column
    a         = 2*S1 - S2 = 0.1 buffers per group   (noise)

The second predicate column **exactly doubled** the slope, which is the
falsification test the design put in front of the number. The row-group list load
(`a`) is not the linear cost; the per-group catalog probe is all of it.

Reproduced identically across two independent runs.

## An artefact that was explained rather than left in the data

`zone_map_pkey`'s `idx_scan` delta exceeded the model by exactly `min(N+1, 33)`.
That is `PGCOLUMNAR_PRUNE_SAMPLE_GROUPS` = 32 (`src/columnar.h:924`): the
*planner* samples up to 32 groups' zone maps to price pruning. It is bounded, so
it is not part of the linear cost, and node-level buffer counts exclude planning
anyway.

## Two instrument bugs found and fixed before the numbers were believed

Recorded because both produced plausible output rather than an error:

- **Summing every `shared hit=` in the plan.** Per-node buffer counts are
  INCLUSIVE of children, so summing the Aggregate and its Custom Scan child
  double-counts. This is what produced a spurious step between N=20 and N=40 in
  the first pass. Fixed to read named nodes, and to count `read` alongside `hit`
  so a miss cannot silently under-report.
- **A window guard that fired on all six arms.** `perf --timeout` always runs the
  whole window, so the elapsed time being compared was perf's, not psql's. A
  guard that fires on every arm is a bug in the guard, not six bad runs. It now
  times psql independently.

Also corrected: the first "full scan" arm used `v >= 0`, which the zone map
answers wholesale -- it reported one vector decoded per group and was not a scan
baseline at all. The denominator arm now uses a qual that cannot be pushed down,
so nothing prunes and every group must be decoded.

## Instructions: the cost in CPU, and how much of the query it is

Same fixture, retired instructions per execution, backend matched by
`application_name`, pinned to the P-cores so a single PMU holds the window, and
the hybrid-PMU rule applied on read (refuse below 95%). 1,000 repetitions per
arm in one session. Premise re-asserted per N: groups removed == N-1.

Least squares over N = 80..640 (N = 20 is excluded from the fit and shown against
it):

| arm | slope, instructions per group | intercept |
| --- | ---: | ---: |
| one predicate column | 30,582 | 10,168,418 |
| two predicate columns | 55,768 | 11,962,214 |

    per zone-map probe   (S2 - S1)  = 25,185 instructions,  6.00 buffers
    per-group, not probe (2*S1 - S2) =  5,397 instructions,  0.09 buffers

Residuals against the fit: +0.07%, +0.17%, -0.27%, +0.06% at N = 80, 160, 320,
640. At N = 20 it is -5.5%, which is why the fit starts at 80.

Residuals are `(measured - fit) / measured`, stated because the other convention,
`(measured - fit) / fit`, puts N = 20 at -5.2% and a reader recomputing it will
otherwise get a different number and not know which of you is wrong.

Two independent instruments agree on the structure. In buffers the probe is
6.00 and everything else is 0.09, i.e. the catalog probe is the entire buffer
cost. In instructions the probe is 25,185 of 30,582, and the remaining 5,397 is
per-group work that touches no buffers: the claim loop, `list_nth`, the context
reset. Labelling that residue "the row-group list load", as the plan did, was
wrong; it is per-group loop overhead.

Sanity check against a known quantity: the intercept is one group of 10,000 rows,
so 10,168,418 / 10,000 = 1,017 instructions per row, beside the ~920 per row
already measured for the grouped-aggregate row path. The instrument is not
reporting an impossible number.

## The answer to the question this document was opened to settle

Share of a pruning query's own execution spent deciding which group to read:

Totals in this table are the MEASURED per-execution figures. The speedup table
further down uses the FITTED totals instead, because it is comparing two lines
rather than reporting an observation, and the two differ by the residuals above
(0.07% to 0.17%). Neither substitutes for the other and no conclusion turns on
which is used.

| chunk groups | rows | locate | total | share |
| ---: | ---: | ---: | ---: | ---: |
| 20 | 200,000 | 611,647 | 10,219,717 | **6.0%** |
| 80 | 800,000 | 2,446,587 | 12,623,288 | **19.4%** |
| 160 | 1,600,000 | 4,893,173 | 15,087,734 | **32.4%** |
| 320 | 3,200,000 | 9,786,347 | 19,901,053 | **49.2%** |
| 640 | 6,400,000 | 19,572,693 | 29,760,395 | **65.8%** |

640 groups was measured rather than projected, deliberately: #403's own bench
table has 667, and my objection to filing the item was that "66,700 at a hundred
times the size" was an extrapolation. It is no longer one.

These are for ONE predicate column. Two columns pay 55,768 per group, and a
smaller `stripe_row_limit` raises N for the same data, so both make it worse.

## Disposition, against the rule written before the numbers

The rule was: under 2% close it; 2-20% the fix is not a sparse index; over 20% the
item earns its issue. At the size the issue itself cites the share is 66%, so
**item 2 earns an issue** and I am filing it.

But the decomposition changes what that issue should say, and this is the part
that would have been got wrong by filing on the extrapolation:

**82% of the per-group cost (25,185 of 30,582) is the catalog probe, not the
min/max comparison.** #403 describes the cost as "66,700 min/max comparisons".
The comparisons are nearly free. What is expensive is that reaching them opens a
relation, takes a lock, and resolves two names, per group, per predicate column.

**What the next table prices is removing the probe ENTIRELY, so it is an upper
bound and not the value of the cheap route.** `S2 - S1` isolates one whole
`PgColumnarReadZoneMapForColumn` call: the schema oid, both `get_relname_relid`
calls, `table_open`, the `systable_beginscan`/`getnext`/`endscan`, and
`table_close`. Route 1 below hoists the open and the two name lookups out of the
loop but leaves the index probe inside it, once per group per predicate column,
so route 1 delivers some fraction of this and route 2 approaches all of it.

Splitting 25,185 into its open-and-lookup half and its index-probe half is what
would price route 1 honestly, and it is a smaller measurement than the ones
already done here. It has not been made, so this table must not be read as the
price of hoisting two name lookups:

| chunk groups | now | probe cost removed | speedup | locate share after |
| ---: | ---: | ---: | ---: | ---: |
| 160 | 15,061,591 | 11,031,937 | **1.37x** | 8% |
| 640 | 29,741,111 | 13,622,495 | **2.18x** | 25% |

So the order is: make the existing zone-map read cheap first, then re-measure. At
640 groups the residue is still 25%, which is where a sparse index earns its
place; below roughly 160 groups it would be attacking 8%. Those two percentages
inherit the upper bound above: they are what is left after the probe is removed
ENTIRELY, so they are the most favourable case for step 2, not a forecast for
route 1.

Two routes for the first step, neither implemented or measured here:

- Hoist the relation open and the two `get_relname_relid` calls out of the
  per-group loop and hold them for the scan. This is the read-path analogue of
  `PgColumnarBeginMetadataFlush`, which already exists and is called only from
  `columnar_write_state.c`.
- Fetch the predicate columns' whole-chunk zone maps for all groups in one scan.
  Note `zone_map_pkey` is `(storage_id, group_number, column_index,
  vector_index)`, so "one column across all groups" is NOT a prefix; this needs
  either an index ordered `(storage_id, column_index, ...)` or a wider scan that
  also reads the per-vector rows.

Item 2's sparse index remains the right end state for sorted data, since it is
the only one of these that is sub-linear in N. It is just not the first move.
