# Roadmap

What is done, what is planned, and where the detail lives.

This page is the entry point. The working record is
[design/ROADMAP.md](https://github.com/commandprompt/pgcolumnar/blob/main/design/ROADMAP.md),
which carries the full list with per-item history. Issues are the authority on anything
being worked now.

## Status

pgColumnar is [pre-release](limitations.md#release-status). The version marker is
`1.0-alpha`. A table `USING pgcolumnar` is stored in the native on-disk format, PGCN v1.

## Done

The large pieces that have shipped:

- **Storage and scan.** Native PGCN v1 format, zone maps and bloom filters for skipping,
  column projection, vectorized execution, delete vectors.
- **Interoperability.** Arrow and Parquet, import and export, flat and nested, with no
  libarrow or libparquet dependency. External Parquet read in place, with an FDW surface,
  projection and predicate pushdown, multi-file reads and partition pruning.
- **Maintenance.** Vacuum, compaction, clustering and reclustering, projections.
- **PostgreSQL integration.** Read stream and asynchronous IO, virtual generated columns,
  temporal constraints, statistics collection for the planner.

## Planned

Nothing here is committed to a release. Each links to the issue that owns it.

| area | item | issue |
| --- | --- | --- |
| Storage | Object storage reads for external Parquet | [#393](https://github.com/commandprompt/pgcolumnar/issues/393) |
| Storage | Object storage writes for the export functions | [#394](https://github.com/commandprompt/pgcolumnar/issues/394) |
| Formats | Apache Iceberg support | [#388](https://github.com/commandprompt/pgcolumnar/issues/388) |
| Planner | Grouped parallel aggregate arm, cost model | [#369](https://github.com/commandprompt/pgcolumnar/issues/369) |
| Benchmarks | Join-heavy analytical measurement | [#401](https://github.com/commandprompt/pgcolumnar/issues/401) |

Object storage is a prerequisite for Iceberg rather than a parallel feature. Parquet and
Iceberg data normally live on S3, GCS or ADLS, and today we read local files only.

## Under investigation

Recorded so the work is visible, without implying it will be built:

- Techniques from published columnar systems, ranked against what we already implement.
  See [#403](https://github.com/commandprompt/pgcolumnar/issues/403) and
  [#405](https://github.com/commandprompt/pgcolumnar/issues/405).
- PostgreSQL 19 features we can adopt, and what the 20 branch may bring.
  See [#390](https://github.com/commandprompt/pgcolumnar/issues/390).

## What this page is not

It is not a commitment, and it is not a schedule. An item here means the work is
recorded and reasoned about. It does not mean anyone is working on it.
