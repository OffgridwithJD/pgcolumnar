# Administration

This guide is for database administrators operating columnar tables. It covers
storage layout, compression, compaction, index-only scans, projections,
monitoring, backup, and security.

## Storage layout

A columnar table is one PostgreSQL relation plus rows in the `pgcolumnar` catalog
tables. Data is organized as follows:

- A **row group** is the unit of write. Each write transaction appends one or
  more row groups of up to `pgcolumnar.stripe_row_limit` rows.
- Within a row group, each column is stored and compressed separately as a
  chunk. A chunk's values are encoded in **vectors** of up to
  `pgcolumnar.chunk_group_row_limit` rows, the unit of the encoding cascade and
  of minimum and maximum skipping.
- Each chunk records its minimum and maximum and an optional bloom filter, and a
  per-vector zone map records the finer minimum and maximum ranges.

Deletes and updates do not rewrite data. They mark rows in a row mask. Space is
reclaimed by compaction (see below).

Inspect the layout with [`pgcolumnar.stats`](sql-reference.md#pgcolumnarstatsrel-regclass).

## Compression

The default codec is `zstd` at level 3. Set the default for new data with
`pgcolumnar.compression` and `pgcolumnar.compression_level`, or per table with
[`pgcolumnar.set_options`](configuration.md#per-table-storage-options).

| Codec | Notes |
| --- | --- |
| `none` | No compression. Lowest write cost, largest size. |
| `pglz` | Built in, always available. |
| `lz4` | Available when built with `liblz4`. Fast decompression. |
| `zstd` | Available when built with `libzstd`. Higher compression at a given speed than `pglz`; the level trades size against write cost. |

A codec change applies to data written after the change. To apply it to existing
data, rewrite the table with [`pgcolumnar.vacuum`](sql-reference.md#pgcolumnarvacuumtablename-regclass-stripe_count-int-default-0).

## Row-group sizing

`pgcolumnar.chunk_group_row_limit` (default 10000) sets how many rows share one
minimum and maximum in a vector. Smaller vectors skip more precisely on selective
range filters but hold less data per vector. `pgcolumnar.stripe_row_limit` (default
150000) sets the write unit. The defaults suit most workloads. Change them for a
table with `pgcolumnar.set_options` when a specific access pattern
calls for it, and measure the result.

## Compaction and vacuum

There are two distinct operations, and the difference matters:

- **Standard `VACUUM`** (manual or autovacuum) runs the columnar table's vacuum,
  which sets visibility-map bits used by index-only scans and maintains
  statistics. It does not rewrite data or reclaim space from deleted rows.
- **`pgcolumnar.vacuum`** (a function) rewrites the table, combining row groups and
  reclaiming space held by deleted and updated rows.

Run `pgcolumnar.vacuum` after bulk deletes or updates, or after many small load
transactions have produced many small row groups:

```sql
SELECT pgcolumnar.vacuum('events');
```

To store rows sorted on a column so range filters on it skip more row groups,
use `pgcolumnar.vacuum_sorted`:

```sql
SELECT pgcolumnar.vacuum_sorted('events', 'customer_id');
```

To compact every columnar table in a schema, use `pgcolumnar.vacuum_full`.

`pgcolumnar.vacuum_sorted` sorts ascending on its columns, which tightens the
minimum and maximum of the leading column. To tighten several columns at once,
use `pgcolumnar.cluster`, which orders rows by a Z-order (Morton) curve over the
columns given, so multi-column range and point filters skip more:

```sql
SELECT pgcolumnar.cluster('events', 'customer_id', 'ts');
```

**`pgcolumnar.cluster` holds `AccessExclusiveLock` for its whole run**, like
PostgreSQL's own `CLUSTER` and `VACUUM FULL`: it rewrites the relation and swaps
the file, so reads and writes on the table block until it finishes. Use it for an
initial bulk reorganisation, on a table you can take offline.
`pgcolumnar.recluster` is the online form of the same idea and is described
below; prefer it on a live table. Neither changes query results. Both only
reorder physical storage.

Leave autovacuum on. It maintains visibility-map bits and statistics for columnar
tables. Schedule `pgcolumnar.vacuum` separately based on delete and update volume.

### Online maintenance and disk reclaim

The online maintenance functions run under ShareUpdateExclusiveLock, so reads and
writes continue during them:

- `pgcolumnar.compact('events')` retires row groups that are fully deleted.
- `pgcolumnar.compact_rewrite('events', 0.2)` rewrites row groups whose deleted
  fraction is at least the given threshold.
- `pgcolumnar.recluster('events', 'customer_id')` reorders live rows on a column
  without an exclusive lock.

These reclaim space for reuse within the file but do not shrink the file on disk.
To return trailing reclaimed blocks to the operating system, use
`pgcolumnar.truncate`:

```sql
SELECT pgcolumnar.truncate('events');
```

`pgcolumnar.truncate` is opt-in. Set `pgcolumnar.enable_end_truncation` to `on`
first (see Configuration). It is best-effort: it takes a brief AccessExclusiveLock
only when it is immediately available and returns 0 without waiting otherwise, so
it does not block a busy table. It cannot run inside a transaction block. Run it
after a large delete followed by `pgcolumnar.compact`, when the freed space is at
the end of the file.

## Index-only scans

An index-only scan answers a query from the index without reading the table, when
the index covers the query and the rows are marked all-visible. pgColumnar serves
this through a columnar visibility-map fork:

- `VACUUM` marks a row group all-visible when its inserting transaction is old
  enough and the group has no deletes.
- Any insert, update, or delete clears the bit for the affected group.

Index-only scans are on by default (`pgcolumnar.enable_index_only_scan`). To make a
covering query use one, ensure the table has been vacuumed since its last write.
Check with `EXPLAIN (ANALYZE)`: an index-only scan reports `Heap Fetches: 0`.

## Projections

A projection stores a subset of a table's columns a second time, optionally
sorted on a key. The planner scans a projection instead of the base table when it
covers the query and serves it better, for example a range query on a key that is
scattered in the base table but is the projection's sort key.

Declare a projection:

```sql
SELECT pgcolumnar.add_projection(
    'events', 'events_by_customer',
    columns  => ARRAY['customer_id', 'amount', 'ts'],
    sort_key => ARRAY['customer_id']);
```

Existing rows are back-filled when the projection is added. New inserts write to
the base table and its projections. Projection scans are on by default
(`pgcolumnar.enable_projection_scan`). Drop a projection with
`pgcolumnar.drop_projection`.

Projections are not carried by `pg_dump` / `pg_restore` -- they are keyed by
internal storage ids that a restore regenerates -- so re-declare them with
`pgcolumnar.add_projection` after a logical restore. A physical backup
(`pg_basebackup`) preserves them.

A projection adds write cost and storage, because inserts write it too. Add one
for a query pattern that a covering, sorted column subset serves, and measure the
result. Confirm the plan uses it with `EXPLAIN`, which names the chosen projection.

## Monitoring

`pgcolumnar.stats(rel)` reports per-row-group row counts, deleted-row counts, chunk
counts, and byte sizes. Use it to see fragmentation and decide when to compact:

```sql
SELECT count(*)                         AS row_groups,
       sum(rowcount)                    AS rows,
       sum(deletedrows)                 AS deleted,
       round(100.0 * sum(deletedrows)
             / nullif(sum(rowcount), 0), 1) AS pct_deleted,
       pg_size_pretty(sum(datalength))  AS size
FROM pgcolumnar.stats('events');
```

A high deleted-row percentage or a large number of small row groups indicates that
`pgcolumnar.vacuum` would help.

## Concurrent unique inserts

When a columnar table has a unique index, `pgcolumnar.enable_unique_insert_lock`
(on by default) serializes concurrent inserts of the same key with a
transaction-scoped advisory lock, so overlapping same-key inserts conflict
correctly. `pgcolumnar.unique_lock_buckets` (default 128) bounds how many advisory
locks a transaction holds per unique index. Leave the lock on unless you have a
specific reason to change it.

## Column cache

`pgcolumnar.enable_column_cache` (off by default) caches decompressed chunk groups
so they can be reused across reads, sized by `pgcolumnar.column_cache_size` (default
200 MB). Enable it for repeated scans over the same recently read data, and size
the cache to the working set.

## Backup and restore

A columnar table is an ordinary WAL-logged relation.

- **Physical backup** (`pg_basebackup`, file-system snapshots) and **physical
  replication** include columnar tables and their WAL.
- **Logical backup** (`pg_dump`) writes the table definition, including `USING
  columnar`, and its data with `COPY`. Restore requires the `pgcolumnar` extension
  installed and present in `shared_preload_libraries` on the target server.

Install and preload the extension on any server that restores or replicates a
columnar table, because reading the table requires the access method.

## Security

### Server-side file access

Some `pgcolumnar` functions read or write a file on the server host rather than
operating only on rows. Every one of them requires superuser, enforced in C at
the point of use:

| function | direction | required privilege |
| --- | --- | --- |
| `pgcolumnar.import_parquet(rel, path)` | reads a server file | superuser |
| `pgcolumnar.read_parquet(path)` | reads a server file | superuser |
| `pgcolumnar.parquet_schema(path)` | reads a server file | superuser |
| a scan of a `pgcolumnar_parquet` foreign table | reads a server file | superuser |
| `pgcolumnar.import_arrow(rel, path)` | reads a server file | superuser |
| `pgcolumnar.export_parquet(rel, path)` | writes a server file | superuser |
| `pgcolumnar.export_arrow(rel, path)` | writes a server file | superuser |

Two layers keep a non-superuser out. The functions carry the default grant to
`PUBLIC`, but the `pgcolumnar` schema does not grant `USAGE` to `PUBLIC`, so a
role that was never given schema access cannot reach them at all; and even with
schema access, the superuser check refuses the call. `test/server_file_privilege.sh`
asserts every entry point above refuses a non-superuser, and holds that list as
data so a new file-reading function is added to one place.

Every other `pgcolumnar.*` function runs with ordinary table privileges.

This is stricter than core's convention: `COPY FROM 'file'` needs membership in
`pg_read_server_files`, not superuser, so a DBA can delegate file reading without
handing over the cluster. pgColumnar keeps superuser for the pre-release: loosening
to `pg_read_server_files` and `pg_write_server_files` later is backward compatible,
while tightening later would break working setups. The looser roles are worth
reconsidering once the parsers are fully fuzzed (see below), because they widen
the set of roles that can reach a hand-rolled parser.

### The file is untrusted input

A Parquet or Arrow file from a source you did not produce is untrusted input to a
hand-rolled parser. The metadata in a crafted file drives that parser directly, so
a malformed or hostile file is a code-execution surface, not just a data-quality
problem. The superuser boundary means the exposed case is a superuser reading a
file they did not produce, which is the ordinary data-lake case rather than an
exotic one: the file is external even though the role is trusted.

The mitigation for that residual risk is fuzzing the parsers, tracked in #214,
which so far covers the Parquet path. Until the Arrow path is fuzzed as well,
treat an Arrow file from an untrusted source with the same caution, and prefer
importing only files you generated or obtained from a source you trust.
