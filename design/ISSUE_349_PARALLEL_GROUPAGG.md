# #349: make the grouped vectorized aggregate path parallel-aware

Status: design, 2026-08-03. This is the remaining scope of #349; its other items
are closed (item 2 scan-key pushdown in #354, the costing regression in #350, the
measurement phase in the issue's own comment thread).

## Why

`ColumnarTryGroupAggPath` adds a serial path only:

```c
cpath->path.parallel_aware = false;
cpath->path.parallel_safe = false;
cpath->path.parallel_workers = 0;
```

and `columnar_groupagg_exec_methods` declares no DSM callbacks. So whenever the
grouped vectorized node wins, it **replaces a four-worker parallel plan with a
single-threaded one**. Measured on the 100M TSBS fixture (issue thread):

| shape | groupvec off | groupvec on |
|---|---:|---:|
| G1 (1 metric, 12h window, 48k groups) | 7,139 ms | **3,604 ms** |
| G2 (10 metrics, 12h window) | 10,731 ms | **8,474 ms** |
| G3 (full 100M scan, 4k groups) | **5,953 ms** | 11,478 ms |

G3 regressed 1.92x because the node displaced a genuinely parallel plan. #350
fixed the *selection* (an honest per-row charge now makes G3 pick the parallel
plan) but the node itself is still serial, so on G1/G2 it wins while leaving
parallelism on the table, and `enable_group_vectorization` still cannot default on
with confidence.

Being parallel-aware dissolves the tension: the node would be both vectorized and
parallel, so it wins on merit rather than by pricing, and nothing is displaced.

## Shape

Exactly the #343/#346 ungrouped arm, with one structural difference.

- #343's ungrouped partial node emits **one** tuple per worker (`AGG_PLAIN`
  Finalize).
- The grouped partial node emits **one tuple per group per worker**, and the
  Finalize is `AGG_HASHED` / `AGGSPLIT_FINAL_DESERIAL` keyed on the grouping
  columns.

Plan shape:

```
Finalize HashAggregate  (group keys, AGGSPLIT_FINAL_DESERIAL)
  -> Gather
       -> Partial Custom Scan (ColumnarScan)   parallel_aware = true
```

Each worker claims distinct row groups through the shared `pg_atomic_uint32`
counter (`ColumnarReadSetParallelCounter`, gap 23 — the same atomic the base
parallel scan uses), builds **its own** group hash table over the row groups it
claimed, and emits `(group keys..., partial transition states...)`. The core
Finalize re-aggregates across workers by key.

The per-aggregate transition state is unchanged from #343 — `columnar_agg_emit_partial`
already produces it (int8 for count/sum(int), the identity float for sum(float),
`int8[2]` `{N,sum}` for avg(int), `_float8` `{N,Sx,Sxx}` for avg(float)) — so
combine and overflow parity carry over untouched. `columnar_parallel_agg_ok` already
names exactly the eligible kinds.

## Planner

In the grouped branch of `ColumnarCreateUpperPaths`, alongside the serial path:

Gate on all of: `columnar_enable_parallel_vector_agg`, `gpe->flags &
GROUPING_CAN_PARTIAL_AGG`, `gpe->partial_costs_set`, `output_rel->consider_parallel`,
`input_rel->partial_pathlist != NIL`, every aggregate `columnar_parallel_agg_ok`,
and every group key already accepted by `columnar_classify_group_keys`.

Target: `fetch_upper_rel(root, UPPERREL_PARTIAL_GROUP_AGG, output_rel->relids)->reltarget`.
**Reuse core's target rather than building one.** It holds the grouping expressions
plus the same Aggrefs marked `AGGSPLIT_INITIAL_SERIAL` that the Finalize will
combine, so the partial and final aggregates are structurally related and setrefs
matches them up. Building our own would not match — this is the same reason the
ungrouped arm gives at `columnar_vector.c:1126-1132`, and it is the single most
likely thing to get wrong here.

The `outMap` must therefore be rebuilt against **that** target's expression list,
not `output_rel->reltarget`, and its Aggrefs classified with `allowPartial = true`
(`columnar_classify_aggref` already accepts `AGGSPLIT_INITIAL_SERIAL` under that
flag). Everything else — group-key classification, qual extraction, the
system-column and pseudoconstant rejections — is target-independent and shared.

Rows: `dNumGroups` per worker (each worker may see every group), not
`dNumGroups / workers`.

Then `create_gather_path` directly on the partial path (not `add_partial_path`,
which may `pfree` a dominated path we still hold the only pointer to — same note as
the ungrouped arm), then `create_agg_path(..., AGG_HASHED, AGGSPLIT_FINAL_DESERIAL,
groupClause, groupOperators, &gpe->agg_final_costs, dNumGroups)`.

Version note: the grouping clause list is `root->processed_groupClause` on PG16+
and `parse->groupClause` on PG15. Gate on `PG_VERSION_NUM`.

As in the ungrouped arm, when the parallel arm is added the serial node is **not**,
since keeping a mispriced serial node beside a genuinely parallel plan is what
produced the G3 regression in the first place.

## Execution

`ColumnarGroupAggScanState` gains:

- `pg_atomic_uint32 *parallelCounter` — wired by the DSM/worker callbacks;
- `bool isPartial` — emit transition states rather than finalized values.

`isPartial` is decided at CreateState from the output tuple, the same way the
ungrouped node does it (`columnar_vector.c:1465-1476`): a custom_scan_tlist entry
whose `Aggref->aggsplit != AGGSPLIT_SIMPLE` means partial. That also selects the
exec-methods table carrying the DSM callbacks, so no new custom_private marker is
needed.

`columnar_groupagg_build` wires the counter onto its reader:

```c
if (state->parallelCounter != NULL)
    ColumnarReadSetParallelCounter(rs, state->parallelCounter);
```

`ColumnarExecGroupAggScan` emits `columnar_agg_emit_partial(&e->specs[a], &isnull)`
in place of `columnar_agg_finalize(...)` when `isPartial`.

New DSM callbacks mirror the ungrouped four exactly; they cannot be shared verbatim
because they cast `node` to `ColumnarAggScanState`, and the grouped state is a
different struct. The leader-side flush in `InitializeDSM` matters for the same
reason it did in #343: a worker is a separate backend and cannot see the leader's
unflushed in-transaction writes and deletes.

## Things that will bite

1. **The group-count cap is per worker.** `pgcolumnar.groupagg_max_groups` guards
   one hash table; with N workers there are N tables. That is the correct reading
   (it is a per-backend memory guard) but it should be stated, and the error text
   checked for it still making sense in a worker.
2. **Rescan.** `ReInitializeDSM` resets the counter to zero for all participants;
   the grouped node must also drop its hash table, which `ColumnarReScanGroupAggScan`
   already does for the serial case — verify it holds when partial.
3. **A worker that claims no row groups** must emit zero tuples, not one empty
   group. The ungrouped node emits one all-nulls partial in that case by design;
   the grouped node must emit nothing, which falls out of an empty hash table.
4. **Deterministic collation and hashing** already gate key acceptance; unchanged,
   but the Finalize now hashes the same keys independently, so its equality must
   agree with ours. Reusing core's target and grouping clause is what guarantees
   that.

## Measured outcome, and the one thing this does not fix

20M-row TSBS-shaped fixture (4,000 hosts), PG18 assert, 4 workers. Not the 100M
bench: those fixtures no longer exist on the bench host, so the issue's G1-G3
re-measurement at full scale is still outstanding.

| shape | groupvec off (core) | groupvec on, serial | groupvec on, parallel |
|---|---:|---:|---:|
| G1 (1 metric, 12h window) | 6,144 ms | 4,555 ms | 4,587 ms *(serial chosen)* |
| G2 (10 metrics, 12h window) | 12,410 ms | 9,225 ms | 7,493 ms *(serial chosen)* |
| G3 (full scan, group by host) | 892 ms | 896 ms | **600 ms** *(parallel chosen)* |

G3 takes the new path and wins. G1 and G2 do not take it, and the reason is
specific and worth recording, because it is not "the parallel node is slow" --
forced onto G1 it runs in **1,184 ms against the serial node's 4,555**, a 3.9x win
the planner is declining.

The planner's own numbers on that shape:

```
partialScan=15,042   ppath=16,292   gather=16,292   final=44,324   serial=20,042
dNumGroups=200,000   (actual groups ~8,000)
```

Our partial node under its Gather costs 16,292 against the serial node's 20,042 --
it wins on everything it does. The core `Finalize HashAggregate` on top adds
**28,031**, and that term is priced off `dNumGroups`. For a `date_trunc(...)`
grouping key `estimate_num_groups` cannot estimate distinctness and returns a
count near the input row count: 200,000 estimated against ~8,000 actual here, and
2,000,000 against 48,000 on the larger fixture. The finalize is therefore
overpriced by the same 25-42x, and it alone loses the comparison.

The asymmetry is structural, not a tuning miss. The serial node emits finished
values, so it pays **no finalize at all**, and #350 deliberately priced it per
input row with no per-output-group term (an earlier version charged per group and
autoanalyze's group estimate flipped the plan choice, so the node sometimes did
not run). Any two-phase plan pays a group-count-driven finalize; the serial node
does not. When the group estimate is inflated, the serial node wins by
construction.

That this is the mechanism rather than a guess is confirmed by G3: its grouping
key is a plain column, `estimate_num_groups` is accurate, and there the parallel
arm is chosen and is faster. Accurate estimate -> chosen; inflated estimate ->
declined.

So the serial node is **still offered** rather than suppressed when the parallel
arm is added. Suppressing it (which is what the ungrouped arm does, for a reason
that does not carry over -- see the code comment) makes G1 take the parallel path
and win 4x, but on G2 the parallel arm loses to core's own plan by a hair and,
with the serial node gone, the result is 8,945 ms against 7,493. Offering both
makes enabling the GUC a strict addition to the planner's choices, which is the
only form in which an opt-in accelerator is safe to turn on.

**The follow-up this needs** is the costing asymmetry, not more execution work:
either charge the serial node for the group hash table it builds, or cost the
partial arm's finalize off something less brittle than `estimate_num_groups` on an
expression key. Both change plan choice on shapes beyond this one and deserve
their own measurement, which is why they are not folded in here.

## Gate

Correctness before performance, since this changes results if the combine is wrong:

- `native_groupagg`, `ungrouped_vector_agg`, `parallel_vector_agg`, `differential`,
  `native_agg*` on assert PG18 + PG19, then the full matrix.
- `pg18_san` (ASAN+UBSAN) — DSM and cross-backend state.
- A new differential check: the same grouped query with the parallel arm on and off
  must return identical rows, including for float aggregates where combine order
  differs (compare with a tolerance for float, exact for int/count).
- Re-measure G1/G2/G3 on the bench fixture and post to #349, per the issue's own
  standard that this work is planned against numbers.
