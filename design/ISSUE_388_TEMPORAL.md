# #388 phase 5d: coarse temporal partition pruning (year/month/hour, day on timestamp)

## Status of temporal transforms before this phase

The Iceberg FDW (`src/columnar_iceberg_fdw.c`) already prunes data files by
`day()` on a **DATE** column (`ice_fdw_day_quals`, `IceDayQual`,
`PgColumnarIcebergDayMap`, filter arm at "temporal day() pruning"). That path is
**exact**: a date maps one-to-one to a day bucket, and the predicate constant is
another date, so the file's single-day cell V is decided against `[V, V]` with
`ice_fdw_metric_excludes`.

Missing: `year()`, `month()`, `hour()`, and `day()` on a **TIMESTAMP** column.
These are *coarse*: one bucket spans a range of source values (a whole year, a
whole month, a whole day of timestamps, a whole hour). The exact `[V, V]`
decision is unsound for them at the boundary bucket, so they need a different
filter rule.

## Iceberg transform math (all from the 1970 Unix epoch, proleptic Gregorian, UTC)

The manifest stores the partition value as the transform's already-computed
signed integer bucket. So the file cell V is directly comparable to the constant
mapped through the same transform. Only the constant needs mapping:

- `year(v)`  = `year_of(v) - 1970`
- `month(v)` = `(year_of(v) - 1970) * 12 + (month_of(v) - 1)`
- `day(v)`   = days from 1970. On a DATE this is the date itself (existing exact
  path). On a TIMESTAMP it is `floor(micros_1970 / microsPerDay)`.
- `hour(v)`  = `floor(micros_1970 / microsPerHour)`; defined on timestamps only.

Source types handled: DATE (year, month; day keeps the exact path), TIMESTAMP,
and TIMESTAMPTZ (all four). A timestamptz value is stored as UTC micros from
2000, which is the epoch Iceberg's transforms count from, so the constant is
mapped with no zone shift. A DATE constant is taken at midnight of the day. The
constant must carry the column's own type. (The TIMESTAMPTZ and DATE-year/month
cases were a follow-up increment after the initial timestamp-only landing.)

PG-to-Iceberg epoch: PG dates are days from 2000-01-01 (`+10957` to reach 1970);
PG timestamps are micros from 2000-01-01 (`+ 10957 * microsPerDay` micros to
reach 1970). Calendar decomposition uses `j2date` (date) and `timestamp2tm`
(timestamp).

## The coarse filter rule (why not `[V, V]`)

For an order-preserving transform T, a file in bucket V holds exactly the source
values s with T(s) = V, i.e. s in `[Vstart, Vend]`. Let `b = T(c)` (the floor
bucket of the predicate constant c). Whether any value in bucket V can satisfy
`s <op> c`:

| predicate | satisfiable in bucket V             | prune (skip) iff |
|-----------|-------------------------------------|------------------|
| s <  c    | V < b, or (V==b and Vstart < c)     | V > b            |
| s <= c    | V <= b                              | V > b            |
| s >  c    | V > b, or (V==b and Vend > c)       | V < b            |
| s >= c    | V >= b                              | V < b            |
| s =  c    | V == b                              | V != b           |

At the boundary bucket `V == b` the file may hold values on both sides of c, so
we **do not** prune (read it, the executor rechecks). This is the "widen by one
bucket" conservatism the pruning design note calls for. It is strictly sound:
never drops a file that could contain a match. The exact date path is a special
case (Vstart==Vend==the date==c's bucket) where `V==b` for `<`/`>` also cannot
match, so day-on-date keeps its tighter `[V, V]` decision and is left unchanged.

## Implementation

- One new qual struct `IceTemporalQual { pos, strategy, bucket }` and one compile
  pass `ice_fdw_temporal_quals`, parameterized by a transform kind, that:
  1. matches `Var <op> Const` (and `Const <op> Var`, commuted) on a partition
     column of the right transform and source type;
  2. extracts the btree strategy (BTLess..BTGreater) via
     `PgColumnarGetOpInterpretation`;
  3. maps the constant to its bucket b with a per-transform pure function
     (`ice_temporal_bucket`: calendar for year/month, floor-div for day/hour).
- A new map helper `PgColumnarIcebergTemporalMap(transform)` in
  `columnar_iceberg.c`, mirroring `PgColumnarIcebergDayMap`, returning the
  partition-cell positions and source attnos for fields whose transform is named.
- One filter arm (`ice_fdw_temporal_excludes`) applying the 5-way table above to
  each temporal qual's file cell V and bucket b.

## Proof discipline (unchanged from 5a-5c)

- Cross-engine oracle: pyiceberg-core writes each fixture, so the manifest bucket
  values are the reference implementation's, read back byte-for-byte.
- Fixtures with `write.metadata.metrics.default=none` so temporal pruning is the
  **sole** mechanism (a metrics fallback would mask a wrong transform).
- EXPLAIN `Files Pruned` counter on the pruning arm; row output cross-checked
  against `iceberg_scan` so a wrong bucket that over-prunes reds a row arm, and a
  wrong bucket that under-prunes reds the Files-Pruned arm.
- Removal proof per direction: the coarse rule replaced by the exact rule
  over-prunes and drops the boundary row; an off-by-one epoch reds the transform's
  Files-Pruned arm.
- Boundary fixture: a predicate whose constant lands exactly on a bucket edge
  (e.g. `ts > '2021-01-01 00:00:00'` on a year() partition) proves the `V==b`
  file is read, not dropped, and still returns its matching row.

## Non-goals

- (none remaining for source types: date, timestamp, and timestamptz all prune).
- Writes, non-current snapshots, time travel (out of #388 read scope).
