# Caching the FSST keep/drop verdict (#472)

## Motivation, re-measured

`pgcolumnar_flush_row_group` decides FSST keep/drop once per column per row
group. The decision cannot use a sample: on a 256 kB training prefix FSST can
look 24% worse while over the whole column it is 23% better, an inversion no
margin would make safe, so `PgColumnarFsstHelpsCompressed` FSST-encodes the
whole corpus and compresses it, only to answer a yes or no.

For a column whose data does not change character, that recomputes the same
answer for every row group of the load.

Measured on current `main` (PG18.4, 2,000,000 rows, `stripe_row_limit` 100000,
so 20 row groups), with the decision instrumented:

| shape | load | decisions | verdict | deciding | share of load |
| --- | ---: | ---: | --- | ---: | ---: |
| `md5(g)` | 5319 ms | 20 | hurts 20/20 | 2482 ms | 47% |
| email-shaped | 2081 ms | 20 | hurts 20/20 | 843 ms | 41% |
| `'label-' \|\| (g%40)` | 533 ms | 20 | build skipped (#155) | 0 ms | 0% |
| low-card then md5 | 3021 ms | 10 built | hurts 10/10 | 1269 ms | 42% |

So 41 to 47 percent of a text load re-derives a constant. This is consistent
with #499's independent profile of the ingest shape (`encode_fsst_shared` 33.9%,
`PgColumnarFsstBuildChunkTable` 14.6%).

The low-cardinality row is the control: #155's `PgColumnarFsstDictWins` already
skips the build there, and that path costs nothing. This work is about the other
one.

## Design

Two fields on `PgColumnarColumnDef`, which is `palloc0`ed per write state, so
`UNKNOWN` is the natural zero:

```c
#define COLUMNAR_FSST_UNKNOWN  0
#define COLUMNAR_FSST_HELPS    1
#define COLUMNAR_FSST_HURTS    2

int8    fsstVerdict;
int     fsstVerdictAge;    /* row groups since the verdict was taken */
```

A write state lives for one statement, so the cache never outlives the load that
built it. Nothing is persisted and no on-disk format changes.

`pgcolumnar.fsst_verdict_reuse`, integer, default 16, minimum 0. After a verdict
is taken it is reused for the next N row groups, then re-taken. **0 means never
reuse**, which is exactly today's behaviour and is what the byte-identical test
arm compares against. It is also the escape hatch.

The two verdicts save different amounts, and the plan should not pretend
otherwise:

- **HURTS reused**: skip the table build AND the decision. The vectors take
  their ordinary encoding, which is what a fresh HURTS verdict would have done.
- **HELPS reused**: still build the table, because it is trained on this row
  group's corpus and stored with the chunk, so reusing the TABLE would change
  stored bytes. Only the whole-corpus decision is skipped. The build is the
  cheaper half (14.6% against 33.9% in #499's profile).

## What must be proven, and how

The saving is real only if the stored bytes do not change. A stale verdict
silently degrades compression, and nothing in the current suites would notice.

Fixtures, chosen by measurement rather than by assumption. Six candidate corpora
were tried and five of them return HURTS; a cache tested only on those would
exercise one branch and a wrongly cached HELPS would sail through:

| fixture | verdict | purpose |
| --- | --- | --- |
| `md5(g)` | hurts, stable | the common case |
| `'the quick brown fox ... ' \|\| g \|\| ' in the morning'` | **helps, stable** | the other branch |
| prose for half the load, then `md5` | helps then hurts | the age bound |

1. **Byte-identical storage, cache on against cache off**, on both stable
   fixtures. `pg_total_relation_size` is too coarse to be the only check, so the
   arm compares the relation's bytes.

2. **The age bound is tested rather than assumed.** For a column that changes
   character mid-load, caching cannot produce byte-identical output: within the
   reuse window the stale verdict is used deliberately. So the assertions are:
   - `fsst_verdict_reuse = 1` must be byte-identical to `0`, which pins the
     mechanism: a bound of one row group re-decides every time.
   - on the changing fixture, a bounded cache must land materially closer to the
     uncached size than an effectively unbounded one. Without this the bound is
     a number nobody checked.

3. **Correctness is asserted separately from size.** Every arm reads its data
   back and compares against a heap mirror. A compression regression is a cost;
   a decode failure is a defect, and the two must not share one check.

4. **The load-time win measured in-suite**, not from a standalone probe.

## Risk

Write-path change. The failure mode is silent: worse compression, correct data.
That is why proof 1 is byte equality rather than a size bound, and why proof 2
exists at all. No format change, no read-path change, no catalog change.
