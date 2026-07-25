# Issue #133: the orphaned count GUC and the losing aggregate plan

Two separate defects found by the 6M-row benchmark run. They land as two PRs so
each is gated on its own.

## Part 1: remove `pgcolumnar.enable_metadata_count`

State today: declared in `src/columnar.h:159`, defined in
`src/columnar_vector.c:74`, registered in `src/columnar_tableam.c:1193`, read by
nothing. Its consumer left with the 2.2 format in `881fa51`.

Decision: remove it rather than wire it back.

The behaviour the name promises is real but is not a separable code path. An
ungrouped aggregate over a native table is answered from row-group metadata by
the vectorized aggregate path in `columnar_vector.c`, and `count(*)` is one case
of that (`COLUMNAR_AGG_COUNT_STAR` sums `rg->rowCount` at
`src/columnar_vector.c:1008`). Gating only the pure-`count(*)` subset would
invent a boundary that exists nowhere in the code, purely to give the name
something to do, and would leave two knobs whose scopes overlap without matching.

The escape hatch a user would actually want, forcing a real count when the
metadata is under suspicion, already exists under a correctly scoped name:
`pgcolumnar.enable_vectorization = off` falls back to an ordinary `Agg` over the
custom scan.

Changes:

- delete the declaration, definition, and `DefineCustomBoolVariable` call
- `docs/configuration.md:38`: drop the row
- `docs/features.md:48`: the line "`count(*)` with no filter is answered from
  catalog metadata without scanning" states a behaviour that the bullet above it
  already covers more accurately. Fold it into that bullet and name
  `pgcolumnar.enable_vectorization` as the control.

## Part 2: cost the vectorized aggregate path for what it reads

`ColumnarAddVecAggPaths` sets both costs to the cheapest scan path's total cost
(`src/columnar_vector.c:705`). The comment argues this is strictly cheaper than
any `Agg` over a scan, which holds for serial plans and fails for parallel ones:
`Gather` over `Partial Aggregate` divides the same scan cost across workers and
wins. That is the benchmark regression, `count(*)` at 6M rows going from about
0.03 ms on the columnar path to 6.52 ms through a parallel scan, and back to
about 1.75 ms with `max_parallel_workers_per_gather = 0`.

The path does not read the table. It reads one metadata entry per row group, so
its cost should be a function of the row-group count, not of table size in pages.

Model to implement:

    ngroups   = ceil(rel->tuples / columnar_chunk_group_row_limit), floor 1
    startup   = cpu_tuple_cost * 10          /* catalog access to get started */
    total     = startup + ngroups * cpu_tuple_cost * (1 + naggs * 0.5)

At 6M rows and the 10000 default that is about 600 groups, so a total near 6
against thousands for either scan plan. The path stays serial and
`parallel_safe = false`; it does not need workers to win once it is costed
honestly.

Open question to settle while implementing: `rel->tuples` is the planner's
estimate and can be 0 on a never-analyzed relation. Use
`Max(rel->tuples, rel->pages * 100)` or fall back to a fixed small group count so
a stale estimate cannot make the path look free on a table that has none of the
metadata it needs.

## Verification

Part 1 is a removal, so the proof is that the tree builds with no reference left
(`grep -rn columnar_enable_metadata_count src/ docs/` empty) and the suites pass.

Part 2 needs a plan-shape check, because a result-only check passes either way.
Add to `test/native_agg.sh`, with parallelism left at its default:

    EXPLAIN (COSTS OFF) SELECT count(*) FROM <native table>;

must contain `Custom Scan (ColumnarScan)` and must not contain `Gather`. Prove it
by mutation: restore `total_cost = cheapest->total_cost` and confirm the new
check fails while the rest of the suite still passes. The table must be large
enough that a parallel plan is otherwise attractive, so the fixture needs enough
rows and pages for the planner to consider `Gather` at all. Confirm on the real
benchmark table too: `count(*)` at 6M rows back to sub-millisecond with default
settings.

## Gate

PG18 and PG19 per PR, per the standing rule. Part 2 touches planning for every
native aggregate, so the whole suite matters, not just `native_agg`.
