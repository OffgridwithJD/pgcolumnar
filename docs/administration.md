# Administration

This guide is for database administrators operating columnar tables. It covers
storage layout, compression, compaction, index-only scans, projections,
monitoring, backup, and security.

## Storage layout

A columnar table is one PostgreSQL relation plus rows in the `pgcolumnar` catalog
tables. pgColumnar puts data in this order:

- A **row group** is the unit of write. Each write transaction appends one or
  more row groups of up to `pgcolumnar.stripe_row_limit` rows.
- In a row group, pgColumnar keeps each column as a chunk and compresses each
  chunk separately. pgColumnar encodes the values of a chunk in **vectors**. A vector
  holds a maximum of `pgcolumnar.chunk_group_row_limit` rows. The vector is the
  unit of the encoding cascade. It is also the unit of minimum and maximum
  skipping.
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

`pgcolumnar.stripe_row_limit` is the setting that governs the cost of a fetch by
index. A fetch decodes the row group that holds the row. A large row group makes
each fetch expensive. Lower this setting for a table that takes many point
lookups. `pgcolumnar.chunk_group_row_limit` does not change this cost. Use
`stripe_row_limit` for this, not `chunk_group_row_limit`.

Measured on 500,000 rows of 1 KiB incompressible data, which is the shape where
the effect is largest:

| `stripe_row_limit` | total size | point lookup | full aggregate scan |
| --- | ---: | ---: | ---: |
| 150000 (default) | 527.0 MB | 244.1 ms | 38.7 ms |
| 50000 | 527.1 MB | 80.0 ms | 37.9 ms |
| 10000 | 527.3 MB | 18.5 ms | 35.4 ms |
| 2000 | 529.4 MB | 5.6 ms | 37.9 ms |

The cost of a smaller row group is small on this data. Size grows by 0.4 percent
at 2000 rows. Scan throughput does not change. There is a floor, so do not go
lower than needed. A selective range query was slower at 2000 rows than at 10000.
A smaller row group makes more metadata to read.

## Compaction and vacuum

There are two distinct operations, and the difference matters:

- **Standard `VACUUM`** (manual or autovacuum) runs the columnar table's vacuum,
  which sets visibility-map bits used by index-only scans and maintains
  statistics. It does not rewrite data or reclaim space from deleted rows.
- **`pgcolumnar.vacuum`** (a function) rewrites the table, combining row groups and
  reclaiming space held by deleted and updated rows.

**`pgcolumnar.vacuum` holds `AccessExclusiveLock` for its whole run.** It rewrites
the relation, so reads and writes on that table stop until it finishes. Treat it as
a maintenance window on a large table, not as a routine command. The online
functions below reclaim space without stopping anything. Use them first.

Run `pgcolumnar.vacuum` after bulk deletes or updates, or after many small load
transactions have produced many small row groups:

```sql
SELECT pgcolumnar.vacuum('events');
```

To store rows sorted on a column so range filters on it skip more row groups,
use `pgcolumnar.vacuum_sorted`. It also rewrites the relation and also holds
`AccessExclusiveLock` for its whole run. `pgcolumnar.recluster` does the same
reordering online:

```sql
SELECT pgcolumnar.vacuum_sorted('events', 'customer_id');
```

A sort is one operation and not a setting. Rows inserted after it go in at the
end, in insertion order. The sorted part of the table therefore shrinks in
proportion as the table grows. Read `pgcolumnar.sort_status` to measure it, and re-sort when
the unsorted part has grown enough to matter to your queries:

```sql
SELECT sorted_rows, appended_rows FROM pgcolumnar.sort_status('events');
```

To compact every columnar table in a schema, use `pgcolumnar.vacuum_full`.

`pgcolumnar.vacuum_sorted` sorts ascending on its columns, which tightens the
minimum and maximum of the leading column. To make several columns tighter at the
same time, use `pgcolumnar.cluster`. It puts the rows in the order of a Z-order
(Morton) curve on the columns that you give. Range filters and point filters on
more than one column then skip more groups:

```sql
SELECT pgcolumnar.cluster('events', 'customer_id', 'ts');
```

**`pgcolumnar.cluster` holds `AccessExclusiveLock` until it completes.** The
PostgreSQL commands `CLUSTER` and `VACUUM FULL` do the same. It rewrites the
relation and replaces the file. Thus reads and writes on the table stop until it
completes. Use it for a first bulk reorganisation, on a table that you can make
unavailable.
`pgcolumnar.recluster` does the same operation online. The text below describes
it. Use it on a table that stays available. The two functions do not change query
results. They change only the order of the physical storage.

Leave autovacuum on. It maintains visibility-map bits and statistics for columnar
tables. Schedule `pgcolumnar.vacuum` separately based on delete and update volume.

### Which maintenance functions stop the table

Every maintenance function is one of two kinds. The kind is set by whether it
rewrites the relation:

| function | lock | table available during it |
| --- | --- | --- |
| `pgcolumnar.vacuum` | `AccessExclusiveLock` | no |
| `pgcolumnar.vacuum_sorted` | `AccessExclusiveLock` | no |
| `pgcolumnar.cluster` | `AccessExclusiveLock` | no |
| `pgcolumnar.compact` | `ShareUpdateExclusiveLock` | yes |
| `pgcolumnar.compact_rewrite` | `ShareUpdateExclusiveLock` | yes |
| `pgcolumnar.recluster` | `ShareUpdateExclusiveLock` | yes |
| `pgcolumnar.truncate` | `ShareUpdateExclusiveLock`, plus a conditional `AccessExclusiveLock` | yes |
| standard `VACUUM` and autovacuum | `ShareUpdateExclusiveLock` | yes |

The three that rewrite need the exclusive lock because they replace the file. The
others work in place and run beside your queries.

Schedule the exclusive three in a maintenance window. Anything that runs
unattended, such as a cron entry, should call the online ones.

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
first. Refer to Configuration. The function does what it can. It takes a short
`AccessExclusiveLock`, but only if the lock is available immediately. If the lock
is not available, the function returns 0 and does not wait. Thus it does not
block a table that is busy. It cannot run inside a transaction block. Run it
after a large delete followed by `pgcolumnar.compact`, when the freed space is at
the end of the file.

## Index-only scans

An index-only scan reads the index and not the table. pgColumnar can use one when
two conditions are true. First, the index contains all the columns of the query.
Second, the rows have the all-visible mark. A columnar visibility-map fork
supplies this:

- `VACUUM` marks a row group all-visible when its inserting transaction is old
  enough and the group has no deletes.
- Any insert, update, or delete clears the bit for the affected group.

Index-only scans are on by default (`pgcolumnar.enable_index_only_scan`). To make a
covering query use an index-only scan, run `VACUUM` on the table after the last
write.
Check with `EXPLAIN (ANALYZE)`: an index-only scan reports `Heap Fetches: 0`.

## Projections

A projection stores a subset of a table's columns a second time, optionally
sorted on a key. The planner reads a projection and not the base table when two
conditions are true. First, the projection contains all the columns of the query.
Second, the projection gives a better result. An example is a range query on a
key. The key is in a random order in the base table, but it is the sort key of
the projection.

Declare a projection:

```sql
SELECT pgcolumnar.add_projection(
    'events', 'events_by_customer',
    columns  => ARRAY['customer_id', 'amount', 'ts'],
    sort_key => ARRAY['customer_id']);
```

When you add the projection, pgColumnar fills it with the rows that exist. New inserts write to
the base table and its projections. Projection scans are on by default
(`pgcolumnar.enable_projection_scan`). Drop a projection with
`pgcolumnar.drop_projection`.

`pg_dump` and `pg_restore` do not carry the projection storage. Its key is an
internal storage id, and a restore makes a new one. They do carry the
declaration, which `pgcolumnar.projection_declaration` holds by relation and
column name. After a logical restore, run `pgcolumnar.rebuild_projections()`. It
builds each declared projection that has no storage and returns the number that
it built. A second run builds nothing. A physical backup (`pg_basebackup`)
preserves the projections themselves, which `test/replication.sh` verifies
against a standby.

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

A columnar table can have a unique index. For such a table,
`pgcolumnar.enable_unique_insert_lock` puts concurrent inserts of the same key in
sequence. It uses an advisory lock with the scope of the transaction. Thus two
inserts of the same key conflict correctly. The setting is on by default. `pgcolumnar.unique_lock_buckets` (default 128) bounds how many advisory
locks a transaction holds per unique index. Leave the lock on unless you have a
specific reason to change it.

## Column cache

There is no cache of decompressed chunk groups. A cache existed in an earlier
build, but its only entry point lost its caller and the code did nothing. It was
removed in #303 rather than left as a setting that changes nothing.

## Backup and restore

A columnar table is an ordinary WAL-logged relation.

- **Physical backup** (`pg_basebackup`, file-system snapshots) and **physical
  replication** include columnar tables and their WAL.
- **Logical backup** (`pg_dump`) writes the table definition, including `USING
  columnar`, and its data with `COPY`. Restore requires the `pgcolumnar` extension
  installed and present in `shared_preload_libraries` on the target server.

Install and preload the extension on any server that restores or replicates a
columnar table, because reading the table requires the access method.

A physical copy moves between hosts of the same byte order. The native format
stores integers in host byte order, which the format specification states. This
is the same rule that PostgreSQL's own heap format follows, so a columnar table is
no more restricted than the rest of the cluster. An independent validation on
2026-08-05 moved a data directory from x86_64 to aarch64 and read it correctly.
Both of those are little-endian. A move to a big-endian host is not supported and
is not tested.

## Security

### Server-side file access

Some `pgcolumnar` functions read or write a file on the server host rather than
operating only on rows. Each gates on the matching server-file role, enforced in C
at the point of use. This is the convention core uses for `COPY ... FROM 'file'`
and `COPY ... TO 'file'`.

| function | direction | required privilege |
| --- | --- | --- |
| `pgcolumnar.import_parquet(rel, path)` | reads a server file | `pg_read_server_files` |
| `pgcolumnar.read_parquet(path)` | reads a server file | `pg_read_server_files` |
| `pgcolumnar.parquet_schema(path)` | reads a server file | `pg_read_server_files` |
| a scan of a `pgcolumnar_parquet` foreign table | reads a server file | `pg_read_server_files` |
| `pgcolumnar.import_arrow(rel, path)` | reads a server file | `pg_read_server_files` |
| `pgcolumnar.file_split_offsets(path, workers)` | reads a server file | `pg_read_server_files` |
| `pgcolumnar.parallel_copy(target, path, workers)` | reads a server file | `pg_read_server_files` |
| `pgcolumnar.export_parquet(rel, path)` | writes a server file | `pg_write_server_files` |
| `pgcolumnar.export_arrow(rel, path)` | writes a server file | `pg_write_server_files` |
| `pgcolumnar.parallel_export_parquet(target, path, workers)` | writes a server file | `pg_write_server_files` |

A superuser holds both roles, so a superuser reaches every function. A read
function needs `pg_read_server_files`. A write function needs
`pg_write_server_files`. A role without the matching role is refused in C at the
point of use.

Two layers keep an unprivileged role out. The `pgcolumnar` schema does not grant
`USAGE` to `PUBLIC`, so a role without schema access cannot reach the functions. A
role that does reach them is then refused by the role check unless it holds the
matching server-file role.

`test/server_file_privilege.sh` holds this table as data. It asserts that a role
without the role is refused, and that a role with the role reaches the file. It
also fails if a function that takes a file path is missing from the list. A new
server-file function therefore cannot slip past the boundary.

Every other `pgcolumnar.*` function runs with ordinary table privileges.

This matches core, where `pg_read_server_files` and `pg_write_server_files` let a
DBA delegate server-file access without a superuser. It is a deliberate change from
the earlier pre-release rule, which required superuser. The read functions that
parse Parquet or Arrow now reach a parser this project wrote from a role short of
superuser. Give an untrusted file the care described below, and see the parser
fuzzing status in that section.

### The file is untrusted input

A Parquet file or an Arrow file from a different source is input without trust.
The parser for these formats is code that this project wrote. The metadata in the
file controls that parser directly. Thus a file that is incorrect or hostile is a
surface for code execution. It is not only a problem of data quality. The read functions now gate on
`pg_read_server_files` rather than superuser. So the exposed condition is a role
with that grant which reads a file a different person made. This is the usual
data-lake condition and not an unusual one. The role has trust, but the file is
external.

The mitigation for that residual risk is fuzzing the parsers, tracked in #214,
which covers the Parquet path at this time. The fuzzing does not cover the Arrow
path yet. Until it does, give the same care to an Arrow file from a source
without trust. Import only the files that you made, or that you got from a source
that you trust.
