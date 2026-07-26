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

The `scan_analyze_next_block` / `scan_analyze_next_tuple` contract is
block-oriented and assumes heap addressing. The obvious columnar mapping is to
treat the block number as a row group ordinal and return rows from within that
group. That is cluster sampling, not simple random sampling, and for this engine
it is wrong in a specific and dangerous direction.

A table sorted or Z-ordered on a key holds a narrow slice of that key's range in
each row group. Sampling whole groups therefore underestimates `n_distinct` and
skews the most-common-value list toward whatever happened to be in the groups
chosen. **The better the clustering, the worse the estimate**, which means a naive
implementation produces confidently wrong statistics on exactly the tables the
engine works hardest to optimise. Confidently wrong is worse than absent, because
the planner trusts what it is given.

The fix is to spread the sample across many groups rather than take all of it
from few. That is affordable now in a way it was not a week ago: #152 replaced the
walk to a row's position with a rank lookup, so reaching row *r* of a group no
longer costs O(r), and a scattered sample within a group is no more expensive than
a contiguous one.

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

**Correlation.** Once rows carry their row numbers, core's own correlation
computation works, because row number order is physical order. This falls out of
the design rather than needing special handling, and it is the statistic worth the
most here.

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
