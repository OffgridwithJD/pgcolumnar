# Roadmap

What is done, what is planned, and where the detail lives.

This page is the entry point. The working record is
[design/ROADMAP.md](https://github.com/commandprompt/pgcolumnar/blob/main/design/ROADMAP.md),
which carries the full list with per-item history. Issues are the authority on anything
being worked now.

## Status

pgColumnar is [pre-release](limitations.md#release-status). The version marker is
`1.0-alpha3`, recorded in `VERSION`. That version is in development and not tagged; the
latest published pre-release is `v1.0-alpha2`. A table `USING pgcolumnar` is stored in the
native on-disk format, PGCN v1.

## Done

The large pieces that have shipped:

- **Storage and scan.** Native PGCN v1 format, zone maps and bloom filters for skipping,
  column projection, vectorized execution, delete vectors.
- **Interoperability.** Arrow and Parquet, import and export, flat and nested, with no
  libarrow or libparquet dependency. External Parquet read in place, with an FDW surface,
  projection and predicate pushdown, multi-file reads and partition pruning.
- **Maintenance.** Vacuum, compaction, clustering and reclustering, projections. Retention
  through `pgcolumnar.expire`, and an optional background daemon for the online verbs.
- **Object storage.** Reads and writes over S3-compatible endpoints for the Parquet
  functions and both foreign-data wrappers, behind an endpoint allow-list that is empty by
  default.
- **Apache Iceberg.** Read a table at its current snapshot, applying row-level deletes of
  every kind, with an FDW surface and a REST catalog client.
- **Parallel bulk work.** `pgcolumnar.parallel_copy` loads one file with several background
  workers as one atomic operation, and `pgcolumnar.parallel_export_parquet` exports in
  parallel.
- **PostgreSQL integration.** Read stream and asynchronous IO, virtual generated columns,
  temporal constraints, statistics collection for the planner.

## Planned

Nothing here is committed to a release. Each links to the issue that owns it.

| area | item | issue |
| --- | --- | --- |
| Planner | Join and aggregate acceleration, including runtime filters pushed into the scan | [#752](https://github.com/commandprompt/pgcolumnar/issues/752) |

Everything this table listed before has shipped: object storage reads and writes, Apache
Iceberg, the grouped parallel aggregate arm, and the join-heavy benchmark. See Done above.

## Under investigation

Recorded so the work is visible, without implying it will be built:

- Techniques from published columnar systems, ranked against what we already implement.
  See [#403](https://github.com/commandprompt/pgcolumnar/issues/403). Its companion
  reading, [#405](https://github.com/commandprompt/pgcolumnar/issues/405), is closed, and
  so is the PostgreSQL 19 and 20 survey,
  [#390](https://github.com/commandprompt/pgcolumnar/issues/390).

## What this page is not

It is not a commitment, and it is not a schedule. An item here means the work is
recorded and reasoned about. It does not mean anyone is working on it.
