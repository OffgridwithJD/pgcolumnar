# Limitations and compatibility

## Release status

pgColumnar is pre-release. The version marker is `1.0-dev`, recorded in `VERSION`,
and there has been no tagged release.

Until there is, treat a columnar table as reloadable and keep the source the data
was loaded from. The extension is appropriate today for evaluation, for analytical
tables that can be rebuilt from an external source, and for development, testing,
and measurement. It is not yet recommended for a production system of record or
for data that cannot be reloaded.

Hardening tracked before a first alpha is in the issue tracker: fuzzing the
hand-rolled Parquet and Arrow parsers
([issue #214](https://github.com/jdatcmd/pgcolumnar/issues/214)), a stated and
tested boundary for untrusted input files
([issue #216](https://github.com/jdatcmd/pgcolumnar/issues/216)), and a statement
of the blast radius of a single backend crash
([issue #217](https://github.com/jdatcmd/pgcolumnar/issues/217)). The sections
below are the standing functional limitations, separate from that work.

## PostgreSQL versions

pgColumnar builds from one source tree on PostgreSQL 15, 16, 17, 18, and
19. Every test suite runs on all five majors. PostgreSQL 13 and 14 still build
but are out of the tested matrix.

Three behaviors depend on the major:

- `ALTER TABLE ... SET ACCESS METHOD` exists on PostgreSQL 15 and later. On 13 and
  14, `pgcolumnar.alter_table_set_access_method` builds a new table, copies rows,
  and swaps names. This preserves columns, defaults, constraints, and indexes, but
  not the original relation's OID or its dependent objects such as views and
  foreign keys.
- The read stream prefetch path (`pgcolumnar.enable_read_stream`) is effective on
  PostgreSQL 17 and later. On earlier majors the setting has no effect.
- Setting the access method of a *partitioned* table requires PostgreSQL 17. On
  15 and 16, core refuses `ALTER TABLE ... SET ACCESS METHOD` on any partitioned
  table with `cannot change access method of a partitioned table`, so a
  partitioned parent cannot be made columnar there and its later partitions
  cannot inherit the choice. Give each partition the access method individually
  instead. This is core's restriction, not this extension's, and it applies
  whether or not a foreign key is involved.

## Host architecture

The Arrow and Parquet import and export functions run on little-endian hosts
only. The rest of the extension runs on any architecture PostgreSQL supports.

## Workload and access patterns

- Columnar storage is built for append-mostly data. Updates and deletes are
  supported, but they mark rows rather than rewriting data, and the space is
  reclaimed only by `pgcolumnar.vacuum`.
- Point lookups are slower than heap, though far less so than they were. A fetch
  by item pointer locates the row's group and decodes only the columns the
  executor asks for, reusing the decoded group for the rest of the statement, so
  the cost no longer scales with the table's width or with the row's position in
  its group. Heap still wins a single-row fetch outright. Bloom filters speed up
  an equality scan by skipping row groups but do not help a fetch by item pointer.
- Bulk `UPDATE` and `DELETE` reached by index are no longer proportional to rows
  times row group size. They still cost several times what heap costs, because
  each changed row is marked and rewritten rather than updated in place.

## Bulk load and import throughput

Loading a columnar table is slower than loading a heap for most shapes, and the
factor depends on the data rather than on a single number. Measured at 6,000,000
rows on PostgreSQL 17.10, non-assert, against a heap insert of the same rows:

| shape | `encode_effort = full` | `encode_effort = fast` |
| --- | --- | --- |
| one `bigint` column | 0.67x | |
| one low-cardinality text column | 3.83x | 3.01x |
| one high-entropy text column | 6.48x | 1.94x |
| five columns, low-cardinality text | 5.59x | 5.55x |
| five columns, high-entropy text | 8.83x | 4.13x |

A single narrow column can be faster than heap; five columns of long high-entropy
text at full effort are several times slower. A single multiplier would be wrong
in one direction or the other depending on the schema.

`encode_effort` is the knob. The default, `full`, spends the most on encoding for
the best storage ratio; `fast` trades some ratio for load speed and recovers most
of the cost on high-entropy text, where the encoding search is what it skips. Set
it per table with `pgcolumnar.set_options(rel, encode_effort => 'fast')`.
Low-cardinality text is dominated by dictionary encoding rather than by that
search, so `fast` helps it less.

`import_arrow` and `import_parquet` are not slower than an ordinary `INSERT` of
the same rows. There is no import-specific overhead; the cost is the columnar
write path either way.

Work on load throughput is tracked in
[issue #155](https://github.com/jdatcmd/pgcolumnar/issues/155).

## Planner statistics

`ANALYZE` collects column statistics for a columnar table: null fraction,
distinct counts, most-common values, histograms and correlation, the same set it
collects for a heap table. Predicates are estimated from the data.

Correlation is worth calling out because it is the statistic that makes
`pgcolumnar.vacuum_sorted` and Z-order clustering legible to the planner: a table
stored sorted on a key reports a correlation near 1 for that column, and the
planner can then price a range scan over it correctly.

The row count the planner uses does not come from `ANALYZE` at all. It is derived
from row-group metadata, so it is accurate whether or not the table has been
analyzed. `pg_class.reltuples` runs a few percent low after `ANALYZE`, because
blocks that hold no row-group data (the metapage, and space reserved but not yet
written) count as visited while offering no rows; the planner does not use that
figure for columnar tables.

`ANALYZE` samples rows through the fetch path rather than by block, so it costs
somewhat more on a columnar table than on a heap of the same size.

`TABLESAMPLE` is unsupported and says so: it raises an error rather than
returning no rows.

## Vacuum and compaction

- `VACUUM FULL` and `CLUSTER` are not supported on a columnar table; the
  copy-for-cluster path raises an error. Use `pgcolumnar.vacuum` or
  `pgcolumnar.vacuum_full` instead.
- `pgcolumnar.vacuum` always rewrites the whole relation into full row groups. It
  accepts a `stripe_count` argument for interface compatibility but performs the
  full rewrite. Because it renumbers rows, it rebuilds the table's indexes.
- Row numbers are reserved a whole row group at a time, so a row group flushed
  with fewer than `stripe_row_limit` rows leaves a gap in the row-number space. Row
  numbers need only be unique and stable, so the gap is harmless.

## Index-only scans

An index-only scan uses the columnar visibility-map fork, which lazy `VACUUM`
populates. A row group is reported all-visible only once its inserting
transaction precedes the oldest snapshot horizon and it has no deletes, and any
later write clears the bit. Recently loaded data is served by a snapshot-checked
fetch until autovacuum or an explicit `VACUUM` marks it. Turn the feature off with
`pgcolumnar.enable_index_only_scan = off`.

## Projections

Projections are additional sorted copies, so they add write and storage cost
proportional to the number of projections, and they are rebuilt by
`pgcolumnar.vacuum`. The planner uses a projection only when it covers every
referenced column (no system columns or whole-row references) and its leading sort
column is restricted; other queries scan the base. A projection added to a
populated table is back-filled under `ShareLock`, which blocks concurrent writes
for the build, like non-concurrent `CREATE INDEX`. Turn projection scans off with
`pgcolumnar.enable_projection_scan = off`.

## Concurrency

- Concurrent deletes or updates to rows in the same row group serialize on that
  row group's row-mask entry: a second writer waits for the first to commit,
  re-reads the committed mask, and merges its bits, so both sets of delete marks
  survive. Writes to different row groups proceed concurrently.
- Concurrent inserts of the same unique key are serialized so the conflict is
  always caught. Before a freshly inserted row reaches the uniqueness check, the
  access method takes a transaction-scoped advisory lock keyed by the row's unique
  key. Equal keys hash to the same lock, consistent with the index's equality, so
  `numeric` `1.0` and `1.00`, `citext` case differences, and collation-equal text
  serialize correctly. Keys hash into a bounded number of buckets per index
  (`pgcolumnar.unique_lock_buckets`, default 128); unrelated keys sharing a bucket
  are over-serialized, never under-serialized. Unique, immediate, valid indexes
  are covered, including multi-column, partial, and expression indexes. An index
  whose operator class cannot be matched to its key type's default equality, or
  whose key type has no hash support, falls back to a single per-index lock. A
  genuine same-key conflict can surface as a deadlock abort rather than a
  `unique_violation`; both reject the duplicate. Turn the serialization off with
  `pgcolumnar.enable_unique_insert_lock = off`.

## Row locking

`SELECT ... FOR UPDATE`, `FOR SHARE` and `FOR KEY SHARE` are not implemented on a
columnar table and raise `columnar: row locking is not supported yet`.

Two consequences are worth stating here, because the error surfaces somewhere
other than where the feature is used:

- **A foreign key cannot reference a columnar table, and is refused when it is
  created.** The referential-integrity check reads the parent row with
  `FOR KEY SHARE`, which a columnar table cannot serve, so `CREATE TABLE` and
  `ALTER TABLE ADD CONSTRAINT` reject the constraint rather than accepting one
  that could never be satisfied. A columnar table on the child side of a foreign
  key is unaffected and works normally.
- **Converting a table that is already referenced by a foreign key is refused
  for the same reason.** `ALTER TABLE ... SET ACCESS METHOD pgcolumnar`, and
  `pgcolumnar.alter_table_set_access_method`, reach the identical configuration
  from the other side, so they are rejected while any foreign key references the
  table. A partitioned table is refused as well: it has no storage of its own,
  but it chooses the access method every partition created afterwards inherits,
  and each of those would then be refused in turn. Drop the constraint first if
  the table should be columnar. Converting the referencing side, and converting
  a table no foreign key points at, are unaffected.
- `INSERT ... ON CONFLICT DO UPDATE` takes a row lock and raises the same error.
  `ON CONFLICT DO NOTHING` does not, and works.

Unlogged columnar tables are rejected at `CREATE TABLE` for the same reason, and
that is the rule both follow: a configuration this access method cannot honour is
refused where it is chosen, not at every later use of it.

## Indexes

- Stale index entries left by deletes and updates are filtered on fetch and
  reclaimed by `REINDEX`, not removed opportunistically.
- `CREATE INDEX CONCURRENTLY` (the concurrent validate path) and partial
  block-range index builds are not supported.

## Constraints on the import path

`pgcolumnar.import_arrow` and `pgcolumnar.import_parquet` maintain every index on
the target and enforce unique and exclusion constraints, so an import cannot
reach a state an ordinary `INSERT` would refuse. A deferrable constraint is
deferred to commit on the import path as it is for ordinary DML, so an import
that transiently violates uniqueness partway through and is consistent by the end
commits rather than being rejected.

## Vectorized aggregate coverage

The vectorized aggregate path covers the single-relation, ungrouped
`SELECT agg(col) FROM t [WHERE ...]` shape only, and only when every aggregate,
column type, and filter clause is supported: `count` (including `count(*)` and
`count(col)`), `sum` and `avg` over `smallint` and `integer` columns, and `min`
and `max` over any type with a default ordering, with `WHERE` clauses that are
conjunctions of simple `column op const` comparisons. Anything else (`sum` or
`avg` over `bigint`, `numeric`, or floating point; ordered-set and string
aggregates; `DISTINCT`-qualified aggregates; `GROUP BY`; `HAVING`; non-simple
filters; joins; whole-row or system column references) falls back to the scalar
plan and stays correct.

## Skipping and collation

Chunk-group skipping from a pushed-down filter is applied only when the
comparison's collation matches the column's own collation, the collation the
stored minimum and maximum were ordered under. A differently collated comparison
is still applied as a filter but does not drive skipping, so results never depend
on whether the filter was pushed down.

## Replication and backup

- Physical replication and physical backups (`pg_basebackup`, snapshots) include
  columnar tables, which are WAL-logged relations.
- `pg_dump` and `pg_restore` handle columnar tables. The target server must have
  the extension installed and preloaded.
- Logical decoding reads heap-tuple WAL records. Columnar data reaches WAL as
  full-page images, which carry no tuple structure, so changes to columnar
  tables are not emitted through logical decoding and logical replication does
  not carry them. Use physical replication for columnar tables.

  A decoding slot is not silent about a columnar table, which is the part worth
  knowing before relying on one. The metadata catalog is made of ordinary heap
  tables, so a slot delivers inserts and updates to `pgcolumnar.storage`,
  `pgcolumnar.row_group`, `pgcolumnar.column_chunk`, `pgcolumnar.zone_map` and
  `pgcolumnar.delete_vector` as the table is written. A consumer subscribed to
  all tables therefore receives a stream of internal bookkeeping, including
  encoded chunk descriptors as bytea, and none of the table's own rows. Filter
  the `pgcolumnar` schema out of any publication.

  To capture changes from a columnar table today, use a row trigger that writes
  to a heap table and decode that. The recipe is in
  [user-guide.md](user-guide.md#capture-changes-for-replication-or-cdc).

## Import and export type coverage

The import and export functions require superuser and run on little-endian hosts.
They support one-dimensional arrays and composite types built from the scalar
types below, with nulls at every level. Multi-dimensional arrays and types not
listed are rejected.

| Type | Arrow export | Parquet export | Arrow import | Parquet import |
| --- | --- | --- | --- | --- |
| `int2`, `int4`, `int8` | yes | yes | yes | yes |
| `float4`, `float8` | yes | yes | yes | yes |
| `bool` | yes | yes | yes | yes |
| `text`, `varchar` | yes | yes | yes | yes |
| `bytea` | yes | yes | yes | yes |
| `date`, `time`, `timestamp`, `timestamptz` | yes | yes | yes | yes |
| `uuid` | yes | yes | yes | yes |
| `numeric` | yes | yes (`numeric(p,s)`, `p` <= 38) | yes | yes (DECIMAL only) |
| `json`, `jsonb` | yes | yes | yes | no |
| one-dimensional array of the above | yes | yes | yes | yes |
| composite of the above | yes | yes | yes | yes |

`uuid` is imported from a 16-byte fixed-length binary column, and `numeric` from
a DECIMAL column stored as fixed or variable big-endian bytes with precision up
to 38, or from an INT32 or INT64 holding the unscaled integer, which is how
writers store small precisions.

`numeric` needs a declared precision for a Parquet round trip. The exporter
writes DECIMAL only for a column declared `numeric(p,s)` with `p` up to 38; a
`numeric` column with no precision, or one with `p` above 38, is exported as
text, and a text column cannot be imported back into `numeric`. Declare
`numeric(p,s)` with `p` up to 38 when the file has to read back into a `numeric`
column. Arrow export and import carry `numeric` in either form.
`json` and `jsonb` can be exported to Parquet and read back with other tools, but
pgColumnar does not currently import them; they are supported end to end through
Arrow.

## Compression codecs

For the native table format, `lz4` and `zstd` are available only when the
extension was built with the corresponding system libraries. When a codec is not
built in, a request for it falls back to a codec that is present. `pglz` and
`none` are always available.

When reading external Parquet files, the reader decodes uncompressed, Snappy,
GZIP, ZSTD, and LZ4_RAW pages. GZIP requires a build with zlib, and ZSTD and
LZ4_RAW require the same libraries as the native codecs; a page whose codec was
not built in fails with a clean decode error. LZO, BROTLI, and the deprecated
Hadoop-framed LZ4 (codec 5, as distinct from LZ4_RAW) are not read.

## Reading external Parquet

The read-in-place surface (`read_parquet`, `parquet_schema`, and the
`pgcolumnar_parquet` foreign-data wrapper) has these limits:

- Reads are superuser only and run on little-endian hosts, as import and export
  do, since they read a server-side path. A file from a source you did not produce
  is untrusted input to a hand-rolled parser; see Security in the administration
  guide for the trust boundary and that residual risk (fuzzing tracked in #214).
- A `path` that is a directory reads the `*.parquet` files at any depth below
  it, descending into subdirectories. Entries whose name begins with `_` or `.`
  are skipped, directories and files alike, which is the convention Spark and Hive
  write: `_SUCCESS` beside the data and in-progress task output under
  `_temporary`. A path named explicitly is still read whatever it is called. A
  directory reached through a symbolic link is not descended, because a link to an
  ancestor would make the walk endless; a symbolic link to a file is still
  followed. Nesting deeper than 32 levels raises rather than reading part of the
  tree.
- Hive-style partitioning is available on the foreign-data wrapper only, through
  the `partition_columns` table option. The columns are declared, not inferred
  from the tree, and `read_parquet` has no equivalent. A value is taken from the
  directory name after percent-decoding, so a value written as `a%3Db` reads as
  `a=b`, and `__HIVE_DEFAULT_PARTITION__`, the marker Hive and Spark write for a
  null partition value, reads as NULL rather than as that string. A file that does
  not carry a
  directory component for every declared column raises rather than producing rows
  with nulls in the partition columns.
- Only the directory components between the declared path and the file are read
  as partition values, so a component above the path, or a file whose own name
  looks like `col=value`, does not set a column.
- A predicate that reads only partition columns prunes files, unless it contains
  a volatile function. Pruning decides a clause once per file, which matches what
  the executor would decide per row only when the clause is a function of the
  partition values alone; a volatile call is not, so such a clause is left to the
  executor and prunes nothing. Stable and immutable functions still prune.
- `parquet_schema` describes the first file of a directory or glob, assuming the
  set is uniform. The read paths still bind every file against the declared
  columns, so a mismatched file raises rather than returning wrong rows.
- A `TIMESTAMP` column with nanosecond precision is advised as `bigint`, which is
  exact; declaring it `timestamp` reads it with the sub-microsecond digits
  truncated.
- A file is read as it is needed rather than loaded whole: the footer is held for
  the duration of the scan, and pages are read one at a time. Peak memory for the
  raw file data is one page, not one file, so file size is not a limit. What does
  scale with the data is the decoded form of one row group for the columns the
  query reads, since a row group is decoded before its rows are produced. A file
  written with very large row groups therefore costs more memory than the same
  data written with smaller ones.
- The column definition list, or a foreign table's column list, must cover every
  leaf column in the file. A shorter list is an error rather than a projection.

Row-group skipping is narrower than the general statement that a group is skipped
when its statistics exclude the predicate. A scan that skips nothing still returns
correct rows; these are the conditions under which it can skip at all:

- The clause must be `column op constant` with a btree comparison operator.
  A parameterized qual, such as one inside a PL/pgSQL function or a generic plan
  from `PREPARE`, does not drive skipping. This is deliberate: the skip set is
  computed once when the scan starts and reused across rescans.
- The column must be stored as a Parquet INT32, INT64, FLOAT, or DOUBLE. Text,
  bytea, uuid, and boolean columns are filtered but never skipped, whatever their
  statistics. A `numeric` column follows its storage: one written as an INT32 or
  INT64 DECIMAL does skip, one written as a byte-array DECIMAL does not.
- The constant's type must match the column's type exactly. A cross-type
  comparison such as `ts >= DATE '2026-01-01'` against a `timestamp` column, or
  `bigint_col > 5::int`, does not skip.
- The row group's statistics must carry both a minimum and a maximum, and the
  interval must not be inverted. An unsigned Parquet column straddling the sign
  boundary, or one narrowed into a smaller PostgreSQL type, decodes to an
  interval that is not trusted for skipping.

The `Row Groups Skipped` counter in `EXPLAIN ANALYZE` reports what was actually
skipped.
