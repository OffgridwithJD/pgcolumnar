# User guide

This guide covers creating columnar tables, loading data, and querying them. It
assumes the extension is installed and loaded (see [Installation](installation.md)).

## Create a columnar table

Add `USING pgcolumnar` to `CREATE TABLE`:

```sql
CREATE TABLE events (
    id          bigint,
    customer_id int,
    amount      numeric,
    kind        text,
    ts          timestamptz
) USING pgcolumnar;
```

The table behaves like any PostgreSQL table for SQL purposes. It supports
transactions, constraints, indexes, `COPY`, and `pg_dump`.

## Convert an existing table

On PostgreSQL 15 and later:

```sql
ALTER TABLE events SET ACCESS METHOD pgcolumnar;
```

On any supported major, including 13 and 14, the extension provides a helper:

```sql
SELECT pgcolumnar.alter_table_set_access_method('events', 'pgcolumnar');
```

On PostgreSQL 13 and 14 the helper rebuilds the table and does not preserve its
OID or dependent objects such as views and foreign keys. See the
[SQL reference](sql-reference.md#pgcolumnaralter_table_set_access_methodt-text-method-text).

To convert back to the default heap, use `heap` as the method.

## Load data

Columnar storage is built for append-mostly data. Rows are buffered and written
in row groups of up to `pgcolumnar.stripe_row_limit` rows. Each transaction writes
its own row groups, so a load's shape affects the result:

- Prefer `COPY` or multi-row `INSERT` over many single-row `INSERT` statements. A
  `COPY` of N rows writes about N divided by `stripe_row_limit` row groups.
- Many small transactions produce many small row groups. If a table was loaded that
  way, run [`pgcolumnar.vacuum`](sql-reference.md#pgcolumnarvacuumtablename-regclass-stripe_count-int-default-0)
  to combine row groups.

```sql
COPY events FROM '/data/events.csv' WITH (FORMAT csv, HEADER);

INSERT INTO events
SELECT g, g % 1000, (random() * 100)::numeric(10,2), 'sale',
       now() - (g || ' seconds')::interval
FROM generate_series(1, 1000000) g;
```

## Query

Queries need no special syntax. The planner adds columnar scan and aggregate
paths for columnar tables. Reads that touch a subset of columns and scan many
rows benefit most.

```sql
-- reads only amount and ts, skips chunk groups outside the time range
SELECT date_trunc('day', ts) AS day, sum(amount)
FROM events
WHERE ts >= '2026-01-01' AND ts < '2026-02-01'
GROUP BY 1
ORDER BY 1;
```

### How the scan is chosen

Read the plan with `EXPLAIN`:

```sql
EXPLAIN (ANALYZE, VERBOSE) SELECT sum(amount) FROM events WHERE customer_id = 42;
```

A columnar scan shows as a custom scan node. The scan uses the following, each
controlled by a setting in the [Configuration reference](configuration.md):

- Chunk-group skipping: per-chunk minimum and maximum values drop groups of rows
  that cannot satisfy a filter.
- Bloom filters: per-chunk filters drop groups for equality filters.
- Vectorized aggregate: an ungrouped count, sum, avg, min, or max over a
  supported type is answered from the zone-map metadata.
- `count(*)` answered from catalog metadata when there is no filter.

### Point lookups and indexes

Create indexes on columnar tables as usual:

```sql
CREATE INDEX ON events (id);
SELECT * FROM events WHERE id = 12345;
```

An index supports point lookups and range scans. When a query's columns are all
in the index and the table's rows are marked all-visible, pgColumnar can answer
from the index alone with an index-only scan, served by its visibility-map fork.
Visibility bits are set by `VACUUM`. See
[Administration](administration.md#index-only-scans).

## Arrays and composite types

Columnar tables store one-dimensional arrays and composite types. These are also
covered by the Arrow and Parquet import and export functions.

```sql
CREATE TYPE addr AS (city text, zip text);

CREATE TABLE people (
    id    int,
    tags  text[],
    home  addr
) USING pgcolumnar;

INSERT INTO people VALUES (1, ARRAY['a','b'], ROW('Portland','97201')::addr);
```

## Read Parquet files in place

You can query a server-side Parquet file without importing it, either as a
set-returning function or as a foreign table. Both require superuser.

```sql
-- inspect the file's columns and their inferred types
SELECT * FROM pgcolumnar.parquet_schema('/data/events.parquet');

-- read the rows directly
SELECT count(*), max(ts)
FROM pgcolumnar.read_parquet('/data/events.parquet')
  AS t(id int, ts timestamp, amount numeric(12,2));
```

For repeated queries, a foreign table is more convenient, and its scans skip row
groups and columns the query does not need:

```sql
CREATE SERVER pq FOREIGN DATA WRAPPER pgcolumnar_parquet;
CREATE FOREIGN TABLE events_parquet (id int, ts timestamp, amount numeric(12,2))
  SERVER pq OPTIONS (path '/data/events/');   -- a directory of *.parquet files

SELECT sum(amount) FROM events_parquet WHERE ts >= '2026-01-01';
```

A `path` may name one file, a directory (all `*.parquet` files below it, at any
depth), or a
glob pattern. `EXPLAIN (ANALYZE)` shows how much the scan skipped:

```sql
EXPLAIN (ANALYZE, COSTS OFF) SELECT id FROM events WHERE ts >= '2026-01-01';
--   Foreign Scan on events
--     Row Groups: 12
--     Row Groups Skipped: 9
--     Columns Read: 2
--     Columns Total: 3
--     Files: 4
```

## Capture changes for replication or CDC

Logical decoding does not carry changes to a columnar table. Columnar data
reaches WAL as full-page images, which carry no tuple structure for a decoder to
read, so a replication slot never sees the rows. See
[limitations](limitations.md#replication-and-backup).

A slot is not quiet about the table, though. The metadata catalog is made of
ordinary heap tables, so a slot subscribed to everything delivers the internal
bookkeeping and none of the data:

```
table pgcolumnar.row_group:    INSERT: storage_id[bigint]:10000000000 group_number[bigint]:1 ...
table pgcolumnar.column_chunk: INSERT: ... encoding_descriptor[bytea]:'\x020001...'
table pgcolumnar.zone_map:     INSERT: ... minimum[bytea]:'\x0100000000000000' ...
table pgcolumnar.delete_vector: UPDATE: ... bitmap[bytea]:'\x03' deleted_count[integer]:2
```

Exclude the `pgcolumnar` schema from any publication.

To capture the changes themselves, write them to a heap table with a row trigger
and decode that table. Row triggers fire on columnar tables and see the same
rows a heap table would.

```sql
CREATE TABLE events (id bigint primary key, kind text, amount int)
    USING pgcolumnar;

CREATE TABLE events_cdc (
    seq    bigserial primary key,
    op     text,
    id     bigint,
    kind   text,
    amount int
);

CREATE FUNCTION events_capture() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO events_cdc (op, id, kind, amount)
            VALUES ('DELETE', OLD.id, OLD.kind, OLD.amount);
    ELSE
        INSERT INTO events_cdc (op, id, kind, amount)
            VALUES (TG_OP, NEW.id, NEW.kind, NEW.amount);
    END IF;
    RETURN NULL;
END
$$;

CREATE TRIGGER events_cdc_t AFTER INSERT OR UPDATE OR DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION events_capture();
```

The capture table is a heap table, so a slot carries it:

```
table public.events_cdc: INSERT: seq[bigint]:1 op[text]:'INSERT' id[bigint]:1 kind[text]:'sale'   amount[integer]:100
table public.events_cdc: INSERT: seq[bigint]:3 op[text]:'UPDATE' id[bigint]:1 kind[text]:'sale'   amount[integer]:150
table public.events_cdc: INSERT: seq[bigint]:4 op[text]:'DELETE' id[bigint]:2 kind[text]:'refund' amount[integer]:50
```

Four properties of this arrangement are worth knowing.

An `UPDATE` arrives as one `UPDATE`. A columnar update is a delete of the old row
and an insert of a new one internally, but the trigger fires once per row event,
so the capture table records what the statement did rather than how the storage
did it.

The capture is transactional. The trigger runs in the same transaction as the
statement, so a rolled back transaction leaves no captured rows, and the captured
rows commit with the data.

It costs a heap row per changed row, in write time and in space. Bulk loads are
the case to think about before enabling it: a load of ten million rows writes ten
million heap rows as well.

The capture table needs pruning. Nothing deletes from it. Delete rows once the
consumer has confirmed them, and remember that the deletes are themselves
decoded unless the consumer filters them.

## Next steps

- Operate tables in production: [Administration](administration.md).
- Improve range scans on a scattered key or serve a query from a column subset:
  [projections](administration.md#projections) and
  [`pgcolumnar.vacuum_sorted`](sql-reference.md#pgcolumnarvacuum_sortedtablename-regclass-variadic-sort_columns-name).
- Move data in and out of the Arrow and Parquet ecosystem:
  [import and export](sql-reference.md#import-and-export).
