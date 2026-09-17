# pgColumnar 1.0-alpha4 release notes

Release date: 2026-09-17
Previous release: 1.0-alpha3 (2026-09-02)

pgColumnar is a columnar table access method for PostgreSQL. This is the fourth
alpha. Its theme is layout and skipping. A table can now be laid out on the
Hilbert curve, which keeps neighbouring keys closer together than Z-order does. A
star-schema join now skips fact-table groups and rejects non-matching rows, and it
does so without being asked. The on-disk native format, PGCN v1, is unchanged.
Existing tables are read and written as before.

This release requires one upgrade command. See "Upgrading" at the end. The upgrade
is the smallest of any release so far: it adds two functions and changes nothing
else.

## Highlights

- **Hilbert clustering**. `pgcolumnar.cluster_hilbert` and
  `pgcolumnar.recluster_hilbert` lay a table out on the Hilbert curve. The curve
  has no jumps at a bit boundary, so a range filter reads fewer chunk groups.
  Measured on 200,000 rows over two columns, Hilbert read 1.24x to 2.04x fewer
  groups than Z-order.
- **Star-schema joins skip and reject by default**. A serial inner Hash Join now
  uses the build-side keys to skip fact-table chunk groups and to reject
  non-matching rows. `pgcolumnar.enable_join_runtime_filter` is on.
- **An index-driven read of a wide table does less I/O**. Adjacent column reads in
  one row group are coalesced into a single read.
- **A parallel index build now uses its workers**. Every participant claims
  distinct row groups. Before this release one backend read the whole table while
  the launched workers sat idle.
- **The planner stops preferring a fetching index scan that does far more work**.
  A correlated range over tens of thousands of rows now takes the columnar scan.

## Hilbert clustering

`pgcolumnar.cluster_hilbert(table, VARIADIC columns)` rewrites a table in Hilbert
order. It holds `AccessExclusiveLock`, as `CLUSTER` and `VACUUM FULL` do.
`pgcolumnar.recluster_hilbert(table, VARIADIC columns)` does the same work online
under `ShareUpdateExclusiveLock`, so reads and writes continue.

The curve is sticky. Plain `pgcolumnar.recluster` maintains a Hilbert table rather
than converting it back. Naming the Hilbert verb is how a Z-ordered table is
switched to the curve.

Choose the curve by the predicate. Z-order is fine for point lookups. Hilbert wins
on range filters over several columns, and the gap narrows as the query box grows.
Measure your own corpus when the two look close. See
[docs/best-practices.md](docs/best-practices.md) for the guidance and
`pgcolumnar.sort_status` for how much of a table is currently in order.

There are two verbs rather than a parameter on the existing two because PostgreSQL
cannot extend `cluster(regclass, VARIADIC name[])` in either direction. A defaulted
parameter cannot precede a `VARIADIC` one.

## Join acceleration

A serial inner Hash Join over a columnar fact table now builds a filter from the
join keys it has already hashed. The filter does two things. A key range skips
whole fact-table chunk groups. A Bloom filter rejects rows that cannot match.

Three measured cases decided the default:

| fact table | result |
| --- | --- |
| clustered on the join key | 19 of 20 chunk groups removed, 1 read |
| scattered | 0 groups removed, Bloom rejects over 15,000 of 19,800 non-matches |
| build side too large | the Bloom disables itself |

The third case is why this is on for everyone. A filter that helps nothing turns
itself off. Group skip still needs the fact table clustered on the join key. Set
`pgcolumnar.enable_join_runtime_filter` to `off` to compare.

An ungrouped vectorized aggregate also keeps running over a unique-key inner Hash
Join. A unique dimension acts as a filter of the fact table, so the fold does not
have to stop. Duplicate-key dimensions and LEFT joins stay on the core plan.

## Reads and the planner

- **Coalesced column reads**. An index-driven fetch of several columns in one row
  group issues one read for adjacent chunks instead of one per column.
- **Parallel index build**. The table access method's parallel scan claims row
  groups per participant from the shared counter, the way the custom scan already
  did. A parallel `CREATE INDEX` now spreads across its workers.
- **Parallel scan cost**. The planner no longer divides a parallel scan's I/O by
  the worker count. PostgreSQL divides CPU across workers and leaves the disk work
  whole, and the columnar cost now matches.
- **Clustered index fetch cost**. The fetch penalty now charges a per-row term,
  capped at half a chunk group. Without it a correlated range of 50,000 rows stayed
  on a fetching index scan while doing far more work than a scan.

## Correctness fixes

- **A truncated column chunk is refused rather than read**. A chunk whose recorded
  length exceeded 4 GB was cast to 32 bits on the index-fetch path. A fetch could
  therefore read the wrong bytes and report them as data. Both cast sites now
  raise `XX001`.
- **A coalesced fetch cannot read past its buffer**. The validity bitmap copy is
  now bounded by the chunk length before it runs.
- **Projections survive DDL**. A rewrite re-records its projections. `ALTER TABLE
  ... RENAME COLUMN` carries the new name into the projection. `ALTER TABLE ...
  DROP COLUMN` is refused when a projection depends on the column. An in-place
  `TRUNCATE` clears each projection's storage as well as the base.
- **The block codec frees its buffer**. Both paths abandoned it.
- **Object storage refuses URL userinfo** on `s3://` and `gs://`, as `http(s)://`
  has since #706.

## Known issues

- **Setting a codec can make a table larger, on high-entropy text** (#1074). The
  writer keeps FSST only when it beats the alternative by
  `fsst_min_gain_percent`, and it measures both sides after the block codec has
  run. Storing the FSST codes uncompressed is never compared. Measured on 200,000
  rows of random hex text, `zstd` wrote 1.777% more than `compression = none`.
  `lz4` was unaffected. If a table stores long high-entropy text and size matters,
  measure both settings.
- **The block codec compresses a region it then discards** (#1075). On
  incompressible data this costs about 25% more write CPU. It does not affect what
  is stored or read.

## Upgrading

Install this build, then run the following in every database that has the
extension:

```sql
ALTER EXTENSION pgcolumnar UPDATE;
```

This is required. The upgrade creates `pgcolumnar.cluster_hilbert` and
`pgcolumnar.recluster_hilbert`. It changes nothing else. No table data is
converted, no existing function is replaced, no catalog column is added, and no
SQL you write changes.

See [docs/installation.md](docs/installation.md) for the commands, including how
to list the databases that need the update.

## Scope and limitations

- This is an alpha. Interfaces may change before 1.0.
- Hilbert clustering orders whole row groups on rewrite. A table that is written
  to after the rewrite drifts out of order until the next one.
- The join runtime filter applies to a serial inner Hash Join on a direct columnar
  scan. It does not wrap LEFT, SEMI, ANTI, CROSS, parallel, or projection scans.
- On PGXN this release is `1.0.0-alpha.4`, while `CREATE EXTENSION` reports
  `1.0-alpha4`. PGXN requires a semantic version, which needs three integer
  components. The extension's own version has two. The two names refer to the same
  release.

The complete, itemized list of changes is in `CHANGELOG.md`.
