# External code audit, July 2026

A fresh-eyes audit of the whole extension by a reviewer who had not worked on it,
carried out on 2026-07-25 against `main` at `a24155b` and tracked forward as the
tree moved. Seven defects were found and fixed, and a larger number of areas were
checked and found sound.

This document exists for the second half. The findings are already in the commit
log; what is not recorded anywhere else is which areas were examined and came back
clean, which techniques found the bugs, and which traps cost time. Re-auditing
what has already been covered is the expensive way to learn that.

Style per project convention: professional, no em-dashes, no unnecessary
adjectives.

## Findings

| PR | Defect | Class |
| --- | --- | --- |
| #128 | `columnar_native_load_group` decodes a whole vector with no interrupt check, so a scan is uncancellable for the length of the load. `statement_timeout`, `pg_cancel_backend` and a standby's recovery conflict all wait for it. | availability |
| #129 | The per-stripe bloom filter saturates above roughly 210,000 values, reaching a 70% false-positive rate at 1M and effectively 100% at 5M, while still costing 256 KB per column per stripe. | wasted work |
| #130 | `ANALYZE` reports success and collects nothing: both scan callbacks return false, so `pg_statistic` stays empty and every predicate is estimated with planner defaults. Documented rather than changed. | undocumented gap |
| #131 | `pgcolumnar.unique_lock_buckets` was `PGC_USERSET` and the bucket is part of the advisory lock tag, so two backends with different values hashed the same key to different locks and did not serialize. A duplicate could commit into a `UNIQUE` index. | correctness |
| #132 | `limitations.md` claimed seven majors while listing five. | documentation |
| #134 | `ColumnarMarkRowDeleted` did two linear list searches per deleted row, both scanned from the head while entries were appended to the tail, giving roughly `rows * row_groups` comparisons for a bulk `DELETE`. | complexity |
| #136 | All 21 `systable_beginscan` calls in `columnar_metadata.c` passed `InvalidOid, false`. Five run once per row group on the read path, so a scan was quadratic in the row-group count. | complexity |
| #137 | A write before `ALTER TABLE ... ADD COLUMN` in the same transaction leaves a stale write buffer, and every value written into the new column afterwards is silently dropped. Survives into a rebuilt projection after `pgcolumnar.vacuum`. | silent data loss |

## What was audited and found sound

Recorded so it is not repeated. Each entry was examined either by reading the
code in full or by differential testing against a heap mirror.

**Encoding and decoding.** `bitunpack` and the `BitReader` bound every read and
range-check every width; `ColumnarDecodeChunk` cross-checks the catalog-supplied
lengths against each encoder's invariants before dispatch. Sixteen boundary cases
round-tripped byte-identically to heap: `int2`/`int4`/`int8` at their extremes,
alternating maximum-delta ramps, perfectly sequential input, constant runs, float
NaN, both infinities and negative zero, decimal-friendly doubles for ALP, numeric
NaN and large exponents, 20 KB text values, multi-byte unicode, `bytea`
containing NUL bytes, arrays and composites, and timestamps at the 4713 BC and
294276 AD bounds.

**Compression.** Every decompressor receives an exact output capacity and its
result length is verified, so a corrupt or truncated stream cannot overrun the
destination.

**Physical storage.** Logical writes are page-aligned, gaps between the current
end of file and the target block are filled with WAL-logged empty pages so a
standby extends identically, and `PageInit` is reached only on the reuse path.

**Planner integration.** The projection covering test derives its column set from
the union of `reltarget` and `baserestrictinfo`, rejects system columns and
whole-row references outright, and initialises its comparison bound to
`PG_INT32_MAX`. A projection that does not cover a referenced column is correctly
declined.

**Visibility map.** Set and clear are both wired, and a rewrite allocates a new
relfilenode, so stale all-visible bits cannot survive compaction.

**Bloom filter probe.** Bounds are correct on both build and probe, and the
cross-type guard (`sk_subtype != atttypid` declines the predicate) means the
constant and the column always hash under the same function.

**Vectorized aggregates.** `sum` over `int8` correctly falls back rather than
accumulating, so overflow behaviour matches core.

**Setting invariance.** Fourteen queries run under nine settings
(`enable_vectorization`, `enable_qual_pushdown`, `enable_bloom_filter`,
`enable_metadata_count`, `enable_custom_scan`, `enable_column_cache`,
`enable_read_stream`, `enable_index_only_scan`, and parallelism) over data
containing NULLs, NaN, both infinities, empty strings, `uuid`, `bytea` and
`numeric`, with deleted rows and an index present. Zero mismatches against the
heap oracle.

**Transactions and DDL.** Savepoint rollback of inserts and of deletes, nested
subtransactions with inner and outer release, update-then-delete in one
transaction, read-your-writes, truncate rollback, add-then-drop column, and
delete-all-then-reinsert all match heap. Only the `ADD COLUMN` sequence in #137
failed.

**Vacuum, compaction and projections.** `pgcolumnar.vacuum` and
`pgcolumnar.vacuum_full` preserve the row set across row renumbering, index scans
agree afterwards, and projections are rebuilt correctly.

**Interoperability.** Fourteen Arrow and Parquet export/import round-trips over
the same edge-case data, all byte-identical.

**Suite baseline.** All 68 suites pass on `main` on PostgreSQL 18.4. The suites
hide nothing; every finding above is in territory they do not cover.

## Techniques that found the defects

**Differential execution against a heap mirror.** Run identical SQL against a
heap table and a columnar table and compare
`md5(string_agg(t::text ORDER BY id))`. This found #137, which no suite covered
because the wrong answer is indistinguishable from the right one for rows written
before a column existed. It is the highest-yield technique in this codebase and
generalises to any state machine: transactions, DDL, vacuum, projections.

**Holding data constant and varying one structural parameter.** Fixing the row
count and varying the row-group count turned #136 from an argument into a
measurement: `count(*)` at 14, 31, 85 and 314 ms as groups doubled, against 10,
11, 11 and 14 ms after. Quadratic behaviour is invisible at suite scale and
obvious in a sweep.

**Self-calibrating timing assertions.** For #128, timing an uninterrupted load
and then timing how long a deliberately short `statement_timeout` takes to fire
on the same query, and asserting the cancel lands under half the full load, means
the same thing on any hardware. A fixed millisecond threshold does not.

**Mutation.** Every test added here was verified to fail with its own guard
removed. Two tests passed with the fix mutated out on the first attempt and had
to be rewritten, which is the argument for doing it at all.

## Traps worth knowing

**`ColumnarCatalogSnapshot` results are not safe for index scans.** It returns an
unregistered copy of the MVCC snapshot with `curcid` advanced past the current
command. A heap scan applies that per tuple and is fine. An index scan under it
does not return, and when the caller is `ColumnarReadRowByNumber` reached from
`_bt_check_unique`, `_bt_doinsert` retries forever, so the symptom is a backend at
100% CPU rather than an error. This is why `ColumnarReadRowGroupList` stays on a
heap scan in #136. Only `unique_conc` scenario 7 catches it.

**`unique_conc.sh` does not use `pgc_setup`.** It starts its own cluster with
`listen_addresses=''` and a private unix socket, and provides its own `ctl_q`,
`SPSQL` and `run_pg`. Code written against `lib.sh` conventions fails there in
ways that look like the condition under test.

**`cmd | grep -q PATTERN && echo OK` cannot pass under `set -o pipefail`** when
`cmd` is still writing: `grep -q` exits at the first match, the upstream takes
SIGPIPE, and the pipeline reports failure even though the match happened. Capture
into a variable first and match with `case`. This produced a check that could
never pass and whose failure was indistinguishable from a real one.

**A backend spinning without an interrupt check cannot be killed by terminating
its client.** Killing psql with `timeout` leaves the backend running, so a later
run in the same cluster contends with it and looks like a fresh hang. Compare
through the suite, in a fresh cluster.

**For anything touching metadata reads or the fetch path, run `unique_conc` and
`audit`.** #136 passed seventeen suites and hung the one that mattered.

## Reproducing

PostgreSQL 18.4 on Ubuntu 26.04 with pyarrow 23.0.1, which matches the versions
the project gates on. The suites handle running as root by way of
`runuser -u postgres`, and build unless `PGC_SKIP_BUILD=1` is set:

```sh
test/<suite>.sh /usr/lib/postgresql/18/bin/pg_config
```

The differential harnesses used here are not committed. They are short scripts
that source `test/lib.sh`, create a heap table and a columnar table with the same
definition, run the same statements against both, and compare an aggregate hash.
Rebuilding one takes minutes and is the recommended starting point for the next
audit.

## Open

#136 is the only finding still unmerged.

Two items were left explicitly unfixed, both recorded where they belong rather
than here: `ANALYZE` collects no statistics (#130 documents it; implementing
sampling is the real fix), and `ColumnarDeleteVectorBufferedDeleted` retains the
nested-scan shape that #134 fixed elsewhere, bounded by insert count rather than
table size.
