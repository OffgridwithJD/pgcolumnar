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
compression codec and level, encode effort, and the declared `sort_by` key). See
[Configuration reference](configuration.md#per-table-storage-options).

`sort_by name[]` declares a physical sort key, applied by
[`pgcolumnar.vacuum_sorted`](#pgcolumnarvacuum_sortedtablename-regclass-variadic-sort_columns-name)
with no explicit columns. It is not auto-maintained; rows inserted after a sort
append in insertion order, so re-run `vacuum_sorted` to re-establish it, like
PostgreSQL `CLUSTER`. Column names must exist and cannot be virtual generated
columns.

```sql
SELECT pgcolumnar.set_options('events', sort_by => ARRAY['customer_id','ts']);
SELECT pgcolumnar.reset_options('events', sort_by => true);   -- clear it
```

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

Compacts a columnar table and stores its rows sorted ascending (NULLS LAST) on
the given columns. Sorted storage makes the per-chunk minimum and
maximum values tight on the sort columns, and it stops them overlapping.
Equality filters and range filters on those columns therefore skip more chunk
groups. Any column with a btree ordering works, and this includes **text**. The
Z-order `cluster()` takes numeric columns only. Use it for a segment
key (e.g. `customer_id`, `hostname`) whose values are scattered in insertion
order but are often filtered on.

With **no columns**, it applies the `sort_by` key that `set_options` declared for
the table. A bare `CLUSTER` re-applies a remembered index in the same way. It
raises an error if the table declares no key:

```sql
SELECT pgcolumnar.vacuum_sorted('events', 'customer_id');          -- explicit
SELECT pgcolumnar.set_options('events', sort_by => ARRAY['customer_id']);
SELECT pgcolumnar.vacuum_sorted('events');                         -- declared key
```

A sort key is a **trade** and not a free gain. A sort by a segment key puts the
rows of each segment together, so a filter on that key skips most groups. It also
spreads each *other* dimension across every group.

For time-series data, a sort by `(segment_key, time)` keeps time in order *inside*
each segment. A query that filters on time alone, across all segments, then
prunes less than the natural time order permits.

Sort by the key that your selective queries filter on. This is a one-shot
reorder, and no operation maintains it. Read
[`pgcolumnar.sort_status`](#pgcolumnarsort_statusrel-regclass) to measure how
much of the order remains.

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

### pgcolumnar.sort_status(rel regclass)

Reports how much of a table's sorted order is still in place. Returns one row:

| Column | Type | Meaning |
| --- | --- | --- |
| `sort_key` | name[] | The `sort_by` key declared by `set_options`, or NULL. |
| `total_groups` | bigint | Row groups in the table. |
| `sorted_groups` | bigint | Row groups written by the last ordering rewrite. |
| `appended_groups` | bigint | Row groups written after it. |
| `sorted_rows` | bigint | Rows stored in the sorted groups. |
| `appended_rows` | bigint | Rows stored in the appended groups. |

`pgcolumnar.vacuum_sorted` and `pgcolumnar.cluster` order a table once. Rows
inserted afterwards go in at the end, in insertion order. The sorted part
therefore shrinks in proportion as the table grows. This function measures that
proportion, so you can decide when another sort is worth its cost.

```sql
-- what fraction of the table is still in sorted order
SELECT sort_key,
       sorted_rows,
       appended_rows,
       round(100.0 * sorted_rows / nullif(sorted_rows + appended_rows, 0), 1)
         AS percent_sorted
FROM pgcolumnar.sort_status('events');
```

A table that was never sorted reports zero sorted groups. An unsorted
`pgcolumnar.vacuum` returns it to that state, because it rewrites the table
without ordering it.

The row counts are stored rows. Deleted rows stay stored until a maintenance
operation reclaims them, so they are still counted here. Use
[`pgcolumnar.stats`](#pgcolumnarstatsrel-regclass) to read the deleted count per
group.

Three limits apply. The online `pgcolumnar.recluster` records only the part of
its output it can prove is one contiguous ordered run. With no concurrent writer
that is the whole relation. If another session inserts while it runs, it records
less, sometimes much less, and reports the rest as decay. It never reports less
decay than there is. The counts describe where rows are stored, not whether their
values are still in order. An `UPDATE` stores the new row version at the end,
which counts as appended. The record is internal storage metadata and `pg_dump`
does not carry it, so a restored table reports no sorted groups until you sort it
again.

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

Drops a projection and frees its storage. It also removes the declaration, so a
later rebuild does not create the projection again.

```sql
SELECT pgcolumnar.drop_projection('events', 'events_by_customer');
```

### pgcolumnar.rebuild_projections(rel regclass DEFAULT NULL)

Builds each declared projection that has no storage, and returns the number that
it built. Give a relation to limit it to one table. Give no argument to cover
each table in the database.

`pg_dump` carries the projection declarations, in
`pgcolumnar.projection_declaration`, but it cannot carry the projection storage.
Run this after a logical restore. A second run builds nothing, so it is safe to
run at any time.

```sql
SELECT pgcolumnar.rebuild_projections();
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

### pgcolumnar.parallel_copy(target regclass, filename text, workers int DEFAULT NULL) returns bigint

Loads a text file into a columnar table with several background workers at once,
as one atomic operation. Returns the number of rows loaded. The caller needs
membership in the `pg_read_server_files` role, which superusers hold, and INSERT
on the target. The file uses COPY text format. Each worker runs core `COPY` over
a byte range of the file, so parse and write behavior match `COPY FROM` exactly.

The target may be one of two kinds:

- A single columnar table. The workers write the one table together. Any
  record-aligned split of the file is correct, so the file needs no ordering.
- A RANGE-partitioned table whose partitions are columnar. Each worker loads a
  distinct set of partitions. The file must be sorted ascending by the partition
  key. The key column may sit anywhere in the row, and its type must be numeric
  or a date/time type. The function reports an error when the file is not sorted.

The load is atomic. Each worker prepares its transaction rather than committing,
and a coordinator commits them together only if every worker succeeded. A bad
row, a full disk, or a constraint failure in any range rolls the whole load back.
The target keeps its earlier contents. Set `max_prepared_transactions` above the
worker count, because the load prepares one transaction per worker.

When `workers` is omitted the function derives a value from the target. For a
partitioned target it lowers `workers` to the partition count when the count is
smaller.

```sql
-- single columnar table, any row order
CREATE TABLE events (id bigint, ts timestamptz, val double precision) USING pgcolumnar;
SELECT pgcolumnar.parallel_copy('events', '/data/events.txt', 8);   -- returns row count

-- RANGE-partitioned target, file sorted ascending by the partition key
SELECT pgcolumnar.parallel_copy('events_by_day', '/data/events_sorted.txt', 8);
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
