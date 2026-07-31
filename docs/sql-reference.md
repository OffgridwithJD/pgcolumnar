# SQL reference

Every function is in the `pgcolumnar` schema. Types are shown as in the function
signature. For server settings, see [Configuration reference](configuration.md).

## Table management

### pgcolumnar.alter_table_set_access_method(t text, method text)

Converts a table to another access method, for example from the default heap to
`pgcolumnar` or back.

On PostgreSQL 15 and later this runs `ALTER TABLE ... SET ACCESS METHOD`, which
rewrites the table in place and preserves its identity and dependents. PostgreSQL 13 and 14 do not have that command. On those two versions, the
function makes a second table with `LIKE ... INCLUDING ALL`. It then copies each
row through the target method and exchanges the names. On those two majors the conversion does not preserve the original table's
OID or objects that depend on it, such as views and foreign keys.

```sql
SELECT pgcolumnar.alter_table_set_access_method('events', 'pgcolumnar');
```

### pgcolumnar.set_options(...) and pgcolumnar.reset_options(...)

Set or reset per-table storage options (row group and vector row limits,
compression codec and level, and encode effort). See
[Configuration reference](configuration.md#per-table-storage-options).

### pgcolumnar.get_storage_id(rel regclass) returns bigint

Returns the internal storage identifier of a columnar table. Used to join the
`pgcolumnar` catalog tables. Most users read [`pgcolumnar.stats`](#pgcolumnarstatsrel-regclass)
instead.

## Maintenance

### pgcolumnar.vacuum(tablename regclass, stripe_count int DEFAULT 0)

Compacts a columnar table by combining small row groups and reclaiming space held
by rows that were deleted or updated. Use it after bulk deletes or updates, or
after many small load transactions have produced many small row groups.

`stripe_count` bounds how many row groups are combined in one call; `0` places no
bound.

```sql
SELECT pgcolumnar.vacuum('events');
```

### pgcolumnar.vacuum_sorted(tablename regclass, VARIADIC sort_columns name[])

Compacts a columnar table and stores its rows sorted ascending on the given
columns. Sorted storage makes per-chunk minimum and maximum values tight and
non-overlapping on the sort columns, so range filters on those columns skip more
chunk groups. Use it for a column whose values are scattered in insertion order
but are often queried by range.

```sql
SELECT pgcolumnar.vacuum_sorted('events', 'customer_id');
```

### pgcolumnar.cluster(tablename regclass, VARIADIC columns name[])

Rewrites a columnar table with its rows ordered by a Z-order (Morton)
space-filling curve on the columns that you give. `vacuum_sorted` sorts in
ascending order. Thus it makes the minimum and maximum of its first column
tighter. Z-order makes each clustered column tighter at the same time. Range
filters and point filters on more than one column then skip more vectors and more
chunk groups. The results do not change. Only the physical order changes.

**Holds `AccessExclusiveLock` for the duration**, like PostgreSQL's own `CLUSTER`
and `VACUUM FULL`, because it rewrites the relation and swaps its file. Reads and
writes on the table block until it completes. Use it for an initial bulk
reorganisation; use [`pgcolumnar.recluster`](administration.md#online-maintenance-and-disk-reclaim)
to reorder a live table without an exclusive lock.

```sql
SELECT pgcolumnar.cluster('events', 'customer_id', 'ts');
```

### pgcolumnar.recluster(tablename regclass, VARIADIC columns name[]) returns bigint

The online counterpart to `cluster`. Re-establishes the same Z-order clustering
over the given columns, but under `ShareUpdateExclusiveLock`, so concurrent reads
and writes continue instead of blocking. Returns the number of row groups
reclustered.

```sql
SELECT pgcolumnar.recluster('events', 'customer_id', 'ts');
```

### pgcolumnar.compact(tablename regclass) returns bigint

Retires row groups that are fully deleted, dropping their metadata so scans skip
them. Holds only `ShareUpdateExclusiveLock`, so it runs against a live table.
Returns the number of groups retired.

```sql
SELECT pgcolumnar.compact('events');
```

### pgcolumnar.compact_rewrite(tablename regclass, min_deleted_fraction float8 DEFAULT 0.2, max_groups int DEFAULT 0) returns bigint

Rewrites partially-deleted row groups, those whose deleted fraction is at least
`min_deleted_fraction`, to drop their dead rows and reclaim the space, under
`ShareUpdateExclusiveLock`. `max_groups` caps how many groups a single call
rewrites; 0 means no cap. Returns the number of groups rewritten.

```sql
SELECT pgcolumnar.compact_rewrite('events', 0.3);
```

### pgcolumnar.truncate(tablename regclass) returns bigint

Gives the reclaimed blocks at the end of the file back to the operating system.
The function does what it can. It takes `AccessExclusiveLock` for the short
physical step, but only if the lock is available. If the table is busy, the
function returns 0 and does not wait. It removes only the space that became free
before the oldest-xmin horizon. Gated by `pgcolumnar.enable_end_truncation`, which is off by
default. Returns the number of blocks truncated.

```sql
SELECT pgcolumnar.truncate('events');
```

### pgcolumnar.vacuum_full(schema name DEFAULT 'public', sleep_time real DEFAULT 0.0, stripe_count int DEFAULT 0)

Runs `pgcolumnar.vacuum` on every columnar table in a schema. `sleep_time` is a
pause in seconds between tables. Each call receives the same `stripe_count`.

```sql
SELECT pgcolumnar.vacuum_full('public');
```

### pgcolumnar.stats(rel regclass)

Returns one row per row group, with these columns:

| Column | Type | Meaning |
| --- | --- | --- |
| `stripeid` | bigint | Row group number within the table. |
| `fileoffset` | bigint | Byte offset of the row group in the relation file. |
| `rowcount` | bigint | Rows written into the row group. |
| `deletedrows` | bigint | Rows in the row group marked deleted. |
| `chunkcount` | integer | Vectors in the row group. |
| `datalength` | bigint | On-disk length of the row group in bytes. |

```sql
-- total live rows, deleted rows, and size
SELECT sum(rowcount) AS rows,
       sum(deletedrows) AS deleted,
       pg_size_pretty(sum(datalength)) AS size
FROM pgcolumnar.stats('events');
```

## Projections

A projection is a named subset of a table's columns stored a second time,
optionally sorted on a key. When a projection covers a query and serves it better
than the base table, the planner scans the projection instead. See
[Administration](administration.md#projections).

### pgcolumnar.add_projection(rel regclass, name text, columns text[], sort_key text[] DEFAULT '{}')

Declares a projection on `rel` named `name`, storing `columns`, sorted on
`sort_key`. When you add the projection, pgColumnar fills it with the rows that exist.

```sql
SELECT pgcolumnar.add_projection(
    'events', 'events_by_customer',
    columns  => ARRAY['customer_id', 'amount', 'ts'],
    sort_key => ARRAY['customer_id']);
```

### pgcolumnar.drop_projection(rel regclass, name text)

Drops a projection and frees its storage.

```sql
SELECT pgcolumnar.drop_projection('events', 'events_by_customer');
```

### pgcolumnar.read_projection(rel regclass, name text) and pgcolumnar.reconstruct_via_projection(rel regclass, name text)

Return a projection's stored rows as text, for verification. They are for
inspection and testing, not for query use.

## Import and export

These functions read and write Arrow IPC stream files and Parquet files. They
require superuser, because they read and write files on the server host. They run
on little-endian hosts only. They support scalar column types, one-dimensional
arrays, and composite types, with nulls at every level. The functions refuse multi-dimensional arrays
and types that they do not support. See
[Limitations and compatibility](limitations.md).

### pgcolumnar.export_arrow(rel regclass, path text) returns bigint

Writes the live rows of `rel` to an Arrow IPC stream file at `path`. Returns the
number of rows written.

### pgcolumnar.export_parquet(rel regclass, path text) returns bigint

Writes the live rows of `rel` to a Parquet file at `path`. Returns the number of
rows written.

### pgcolumnar.import_arrow(rel regclass, path text) returns bigint

Inserts the rows of an Arrow IPC stream file at `path` into the existing table
`rel`. The column types of the table define the types that the function accepts. Returns the number of
rows inserted.

### pgcolumnar.import_parquet(rel regclass, path text) returns bigint

Inserts the rows of a Parquet file at `path` into the existing table `rel`. The
reader handles uncompressed, Snappy, GZIP, ZSTD, and LZ4_RAW pages, PLAIN and
dictionary encodings, and data-page versions 1 and 2. `path` may name a single
file, a directory (every `*.parquet` file below it is imported, at any depth),
  or a glob
pattern. Returns the number of rows inserted.

```sql
-- round-trip a table through Parquet
SELECT pgcolumnar.export_parquet('events', '/tmp/events.parquet');   -- returns row count
CREATE TABLE events_copy (LIKE events) USING pgcolumnar;
SELECT pgcolumnar.import_parquet('events_copy', '/tmp/events.parquet');

-- import an entire directory of Parquet files
SELECT pgcolumnar.import_parquet('events_copy', '/data/events/');
```

## Reading external Parquet

These read a server-side Parquet file in place, without importing it. They
require superuser and operate on little-endian hosts. In each function, `path`
can be one of three things. It can be a single file. It can be a directory, and
then the function reads all the `*.parquet` files below it at any depth as one
relation, in sorted order. It can also be a glob pattern.

### pgcolumnar.read_parquet(path text) returns setof record

Returns the rows of a Parquet file. You must supply a column definition list. It
gives the names of the output columns and their types. The reader connects the
list to the leaf columns of the file by position. It uses the same rules for type
compatibility as the import functions.

The list must contain each leaf column in the file. A list with fewer columns is
an error and not a projection. The read stops and gives a message. The message
contains the number of leaf columns in the file and the number that the target
expands to. The same rule applies to a foreign
table's column definitions. Projection pushdown selects the declared columns
that the reader decodes. This is a separate question from the number of columns
that you must declare. Use
`parquet_schema` to generate the full list.

```sql
SELECT * FROM pgcolumnar.read_parquet('/data/events.parquet')
  AS t(id int, ts timestamp, amount numeric(12,2));

-- read a whole directory
SELECT count(*) FROM pgcolumnar.read_parquet('/data/events/')
  AS t(id int, ts timestamp, amount numeric(12,2));
```

### pgcolumnar.parquet_schema(path text) returns table(column_name text, data_type text, nullable bool)

Reports the leaf columns of a Parquet file and the PostgreSQL type each maps to,
without reading the data. Useful for writing the column definition list for
`read_parquet` or a foreign table. For a directory or glob it describes the first
file.

```sql
SELECT * FROM pgcolumnar.parquet_schema('/data/events.parquet');
```

### The pgcolumnar_parquet foreign-data wrapper

Exposes a Parquet file, directory, or glob as a foreign table. The scan pushes
work down: row groups whose min/max statistics exclude the query's predicate are
skipped, and only referenced columns are decoded. Skipping requires a
`column op constant` clause over an integer or floating-point column with a
constant of the same type; [limitations.md](limitations.md) lists the conditions.
A scan that skips nothing still returns correct rows.

Table options: `path`, and `partition_columns` for a Hive-style layout. The
latter names the columns whose values come from `col=value` directory components
rather than from the files. You declare these columns. pgColumnar does not infer
them, because an incorrect value would change the rows that a query returns, with
no message. A predicate on a partition column removes complete files before the
reader opens them. The plan shows this as
`Files Pruned`.

```sql
CREATE SERVER pq FOREIGN DATA WRAPPER pgcolumnar_parquet;
CREATE FOREIGN TABLE events (id int, ts timestamp, amount numeric(12,2))
  SERVER pq OPTIONS (path '/data/events/');

-- events/dt=2026-01-01/region=eu/part-0.parquet
CREATE FOREIGN TABLE events_p (id int, amount numeric(12,2), dt date, region text)
  SERVER pq OPTIONS (path '/data/events', partition_columns 'dt,region');

SELECT sum(amount) FROM events WHERE ts >= '2026-01-01';

-- EXPLAIN ANALYZE reports Row Groups, Row Groups Skipped, Columns Read,
-- Columns Total, and Files.
EXPLAIN (ANALYZE, COSTS OFF) SELECT id FROM events WHERE ts >= '2026-01-01';
```

## Visibility map inspection

These report the state of the columnar visibility-map fork that serves
index-only scans. They are for diagnostics.

### pgcolumnar.vm_is_visible(rel regclass, blk int)

Tells you if the block (chunk group) has the all-visible mark.

### pgcolumnar.vm_selftest(rel regclass, blk int)

Runs a set and clear self-test against the visibility map for one block.
