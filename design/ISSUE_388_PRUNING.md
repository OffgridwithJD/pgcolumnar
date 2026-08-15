# Issue #388 — Iceberg pruning via a foreign-data wrapper

Status: DESIGN. The last remaining #388 capability. Phases 1-7 (read: filesystem
+ object storage + REST catalog + vended creds) are merged or in review; pruning
was deferred at phase 5 because `iceberg_scan` is a bare SRF that receives no
query predicate. This design gives Iceberg a predicate-bearing scan node — an
**Iceberg foreign-data wrapper** — and prunes in phased increments.

## Why an FDW, and what it reuses

The extension already has a Parquet FDW (`pgcolumnar_parquet`) that captures
quals and prunes: whole partition files by `col=value` directory predicates
("Files Pruned"), and row groups by Parquet-footer min/max. That is the exact
shape Iceberg pruning needs, and most of the Iceberg read path is already
callback-driven and reusable:

- `ice_walk_data_files` (columnar_iceberg.c) walks the current snapshot's
  manifests and invokes an `IceDataFileCb` per live entry — already the seam an
  FDW needs to obtain the file list.
- The manifest decoder already captures each data file's **already-transformed
  partition tuple, typed** (`PgColumnarAvroPartCell part_cells[]`), plus
  `spec_id`/`has_spec_id` — the same data the partition-scoped equality-delete
  code compares with `ice_part_cells_equal`. So **identity-partition values are
  decoded today**; no new manifest decode is needed for 5a.
- The per-file reader `PgColumnarReadParquetByFieldId{,NM}` takes a field-id
  projection, a tuplestore, and a `skipPos` delete set — reusable per surviving
  file.
- The Parquet FDW's qual-capture (`pqfdwGetForeignPlan`) and partition-exclude
  (`pqfdw_partition_quals` / `pqfdw_partition_excludes_file`) are the template,
  adapted to compare typed `part_cells` instead of directory-parsed strings.

What does **not** exist yet: any Iceberg `FdwRoutine`; data-file min/max metrics
decode (`lower_bounds`/`upper_bounds`/`null_value_counts` are `av_skip`-ped
today); and any partition-transform library (no murmur3/bucket/truncate/temporal
— confirmed absent).

## The SRF → FDW refactor (shared by both)

`PgColumnarIcebergScanInto` is SRF-shaped three ways an FDW cannot use as-is: it
hard-writes `rsinfo->returnMode/setResult/setDesc`; it materializes **all** files
eagerly in one pass-2 loop (no streaming/LIMIT stop); and its `TupleDesc` comes
from the SRF column-definition list. Split it into:

1. **Collect + delete-resolve front half** (keep as-is): pass 1 `ice_walk_data_files`
   into `IceScanCtx.data/posdel/eqdel`, then read the delete files. Produces the
   `IceEntry` data list and the per-file delete sets. No output shape assumed.
2. **A driver both callers invoke.** The SRF driver keeps the materialize-all
   loop (unchanged behavior). The FDW driver adds (a) a **qual filter over the
   file list** before reading, and (b) a **one-file-at-a-time streaming**
   producer analogous to the Parquet FDW's `pqfdw_refill`, so a `LIMIT` stops
   early and each file is opened only when reached.

This refactor is behavior-preserving for the SRF (its suite must stay green) and
is the enabling step for every pruning increment.

## Phase 5a — Iceberg FDW + identity-partition pruning (first increment)

Deliver a working `pgcolumnar_iceberg_fdw_handler` + validator:

- A foreign table over an Iceberg table: options `metadata_path` (or, later, a
  REST catalog reference), the column set mapped to field ids the same way
  `iceberg_scan`'s deflist is.
- `GetForeignPlan` captures the scan quals (mirror `pqfdwGetForeignPlan`).
- `BeginForeignScan` runs the collect-half, then **filters the `IceEntry` list
  on identity-partition values**: a clause qualifies for pruning only if every
  `Var` it reads is an identity-partitioned column and it is non-volatile; the
  clause is evaluated against a virtual slot holding the file's `part_cells`
  (exactly `pqfdw_partition_excludes_file`, but from typed cells). A file whose
  partition value excludes a qual is dropped and never opened; `filesPruned++`.
- `IterateForeignScan` streams the surviving files one at a time through
  `PgColumnarReadParquetByFieldIdNM` (with that file's delete `skipPos`).
- `ExplainForeignScan` emits a "Files Pruned" counter (mirror the Parquet FDW).
- **Every non-identity transform is treated as "not prunable" — the file is
  read.** Always sound; never wrong, just not yet optimized.

Reused: the whole delete-application machinery, the decoded `part_cells`, the
file walk, the per-file reader, and the Parquet FDW's qual pattern. Net-new: the
handler/validator/registration, the SRF→streaming refactor, and identity-only
qual→cell comparison.

**Proof:** a partitioned warehouse (identity partition on a column, e.g. region);
a foreign table over it; `EXPLAIN` shows "Files Pruned" &gt; 0 for a predicate on
the partition column, and the returned rows equal `iceberg_scan` of the same
table filtered by the same predicate (same oracle). Removal proof: defeat the
file filter → "Files Pruned" goes to 0 and the plan reads every file (still
correct rows, but the pruning counter reds). A predicate on a **non-partition**
column prunes nothing (reads all files) and still returns correct rows — pinning
that unsound pruning never happens. Assert the pruning with EXPLAIN on BOTH arms
(the "measure the work, not the intent" rule). Gates PG17/18/19 + ASAN, docs.

## Phase 5b — data-file min/max metrics pruning

Decode `lower_bounds`/`upper_bounds`/`null_value_counts` (the `array<map<int,
bytes>>` keyed by field id; bytes are Iceberg single-value binary) in
`av_decode_data_file`, carry them on `IceEntry`, and reuse the **logic** of the
Parquet FDW's `pqfdw_clause_excludes_group` — its min/max strategy switch and its
conservative guards (fixed-width ordered types only, refuse inverted intervals
from type narrowing, refuse NaN-ambiguous float bounds) transfer directly. Prunes
whole data files on non-partition columns (and, if pushed into the reader, row
groups). Net-new: a per-type single-value-binary deserializer. Independent of
transforms. Same proof discipline: EXPLAIN counter both arms, same-oracle rows,
and a conservative-guard removal proof (a NaN/narrowed bound must NOT prune).

## Phase 5c — partition transform library

Order of increasing risk:
1. **truncate[W]** (strings/decimals) and **year/month/day/hour** (temporal):
   order-preserving, so range predicates prune soundly by mapping the qual
   constant through the same transform and widening the boundary by one bucket.
   Small pure functions; cross-checked against pyiceberg/DuckDB partition values.
2. **bucket[N]** (murmur3 x86-32 mod N): the hash destroys order, so **equality
   only** (`col = const` → hash the const, compare to the stored bucket). Highest
   risk: needs an exact-spec murmur3 with adversarial fixtures and a cross-engine
   oracle proving byte-for-byte bucket agreement. Landed last, on its own.

Every transform added is a new "prunable" case; anything not implemented stays
"read the file" (sound).

## Scope note / sequencing

5a is the high-value, low-risk first increment (mostly plumbing over existing
code) and delivers real pruning for the most common partitioning (identity). 5b
adds metrics pruning for non-partition columns. 5c is the transform math, most of
which is order-preserving and low-risk except bucket/murmur3. Each is a separate
PR with its own EXPLAIN-verified proof; none changes read correctness, only which
files are opened.

## Non-goals

- Writes, snapshot selection other than current, time travel.
- Pushing Iceberg residual filters into the Parquet reader beyond row-group
  min/max (the reader already skips row groups; per-row filtering stays in the
  executor recheck, exactly as the Parquet FDW keeps clauses recheckable).
- Anything needing new WAL.
