# Plan: collect column statistics for ANALYZE

`ANALYZE` on a columnar table reports success and collects nothing.
`columnar_scan_analyze_next_block` and `columnar_scan_analyze_next_tuple` both
return false (`src/columnar_tableam.c:386`), so `pg_statistic` stays empty and
every predicate is estimated with planner defaults. Documented in #130, not fixed.

## What is and is not missing

Worth stating precisely, because the gap is narrower than "the planner is blind".

`columnar_relation_estimate_size` is implemented and returns an accurate live row
count derived from the row group metadata rather than from the metapage
reservation high-water mark. So the planner already has the right `rel->tuples`
and `rel->pages` at planning time, even though `pg_class.reltuples` stays 0.

What is missing is everything about distribution: null fraction, `n_distinct`,
most common values, histograms, and correlation. The consequences, in the order
they hurt:

- **Joins.** A columnar fact table joined to dimension tables is the workload this
  engine exists for, and it is the case where a selectivity guess compounds into a
  wrong join order rather than a slightly slow scan. `WHERE status = 'x'` is
  estimated at 0.5% and `WHERE ts > $1` at a third, regardless of the data.
- **Grouping.** No `n_distinct` means hash aggregate memory is guessed, so the
  planner does not predict the spills it causes.
- **Correlation.** This one is specific to this engine and nothing else will
  supply it. `pgcolumnar.vacuum_sorted` and Z-order clustering exist to create
  physical locality, and the planner currently has no way to know they were used
  or how much skipping to expect.

Single-table analytic queries mostly survive without any of this, because the
custom scan is chosen structurally, ungrouped aggregates go to the metadata path,
and zone maps skip physically whatever the planner believed.

## The trap to design around first

**Corrected after implementation (#159). The prediction below was half wrong, and
the half that was wrong is the interesting half.**

The `scan_analyze_next_block` contract is block-oriented and assumes heap
addressing. The obvious columnar mapping is to treat the block number as a row
group ordinal and return rows from within that group. That is cluster sampling,
not simple random sampling.

What this plan predicted: on a table sorted or Z-ordered on a key, each row group
holds a narrow slice, so whole-group sampling would underestimate `n_distinct`
and skew the most-common-value list, worst on exactly the tables the engine works
hardest to produce.

**That does not happen, and it was checked rather than argued about.** #159
implemented the whole-group variant to find out. Offering every row of a group
for each of the many blocks that group spans hands core far more rows than it
asked for, so its reservoir ends up sampling most of the table and the
distribution statistics come out fine: `n_distinct` 1000 against a true 1001 on
the clustered fixture.

What breaks instead is the row count, because those rows are counted against the
fraction of blocks core visited:

| mapping | reltuples for a 1,000,000-row table |
| --- | --- |
| whole row group per block | 20,500,000 |
| one row slice per block | 986,666 |

A factor of twenty, which is worse for the planner than any distribution skew
would have been. So the mapping still matters and the slice approach is still
right; the reason is the row count, not the distribution, and a test written to
watch `n_distinct` on a clustered table would pass against the wrong
implementation. #159's suite watches `reltuples` and says so.

The general lesson is the one worth keeping: a predicted failure mode is a
hypothesis, and writing the test for the predicted symptom rather than the
measured one produces a check that passes against the bug.

## Approach

**Sampling unit.** Report a block count equal to the row group count, and let core
choose which groups to visit through its existing two-stage sampling. Within a
chosen group, take a bounded random sample of live row numbers rather than the
first N, and reject rows the delete vector marks. The decoded-group cache from
#148 means the group is decoded once for the whole sample.

**Rows returned.** `scan_analyze_next_tuple` hands core a `HeapTuple`, so the
sampled row has to be materialised through the same reconstruction the fetch path
uses. `ColumnarReadRowByNumber` already produces `values`/`nulls` for a row
number, so this is `heap_form_tuple` over that, with a synthetic item pointer from
the row number as the index path already does.

**Correlation.** Worth the most here, and it does **not** fall out of the design,
which is what an earlier revision of this plan claimed.

`acquire_sample_rows` sorts the sample by item pointer, and the sample arrives
through `ExecCopySlotHeapTuple`. A virtual slot's copy is `heap_form_tuple` over
the slot's values, which sets `t_self` invalid and never reads `tts_tid`, so
setting the slot's item pointer is not enough: every sampled tuple carries an
invalid pointer. On a non-assert build the sort then permutes them arbitrarily
and correlation comes out as noise; on an assert build the backend aborts on
`ItemPointerIsValid`.

The access method has to supply its own `copy_heap_tuple` that carries `tts_tid`
into `t_self`, which is what #159 does. Correlation then reads 1.0 on an ascending
column, matching a heap mirror. Recorded because the claim cost a revision to
discover, and because the same one-line cause produced both the missing statistic
and a crash.

**Relation-level stats.** `vac_update_relstats` should record the live row count
and the block count so `pg_class` stops reporting 0 rows, which is separately
confusing when reading `\d+` output even though the planner does not rely on it.

## What this does not attempt

Extended statistics, per-row-group statistics as a planner input, and pushing zone
maps into selectivity estimation. All three are interesting and none is needed to
close #130. Zone maps in particular would be a larger and more speculative piece:
they describe physical layout, and the planner's model wants distribution.

## Testing

Correctness of a statistics implementation is awkward to assert because the
numbers are estimates. Three checks that do discriminate:

1. **Against heap on identical data.** Load the same rows into a heap table and a
   columnar table, `ANALYZE` both, and compare `pg_stats`: `null_frac`,
   `n_distinct` and `most_common_vals` should agree within a stated tolerance.
   This is the differential-oracle pattern the rest of the suite uses, and it is
   what catches a sampling bias rather than a coding error.
2. **The clustering trap specifically.** Build a table sorted on a key so each row
   group holds a narrow slice, `ANALYZE`, and check `n_distinct` is within
   tolerance of the true value. A cluster-sampling implementation fails this and
   passes check 1, which is the whole reason to write it separately.
3. **Plan shape.** A join between a large columnar table and a small one should
   pick the same plan shape as the equivalent heap join. Assert on the plan, not
   the timing.

Every one of these must be shown to fail against the current `return false`
implementation, which for checks 1 and 3 it will trivially, and for check 2 only
once a sampler exists to get it wrong.

## Effort

3 to 5 dev-months for two people, with the sampling design and the clustering
question being most of the risk. The API surface itself is small.
