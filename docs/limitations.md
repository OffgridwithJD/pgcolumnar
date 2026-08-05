# Limitations and compatibility

## Release status

pgColumnar is pre-release. The version marker is `1.0-alpha`, recorded in `VERSION`,
and `v1.0-alpha` is tagged and published as a pre-release.

An alpha is still an alpha: treat a columnar table as reloadable and keep the source
the data was loaded from. The extension is appropriate today for evaluation, for analytical
tables that can be rebuilt from an external source, and for development, testing,
and measurement. It is not yet recommended for a production system of record or
for data that cannot be reloaded.

The hardening that was tracked before a first alpha is complete. The
Parquet and Arrow parsers, which this project wrote, are fuzzed, both by byte mutation and by structural
mutation of the container format
([issue #214](https://github.com/commandprompt/pgcolumnar/issues/214)). The boundary for
untrusted input files is stated and tested
([issue #216](https://github.com/commandprompt/pgcolumnar/issues/216)). The blast radius
of a single backend crash is asserted and documented
([issue #217](https://github.com/commandprompt/pgcolumnar/issues/217)). The build checks the on-disk format version
on read. It does not only stamp the version on write
([issue #240](https://github.com/commandprompt/pgcolumnar/issues/240)). A gate covers
cross-major `pg_upgrade`. Before, only a suite that nobody ran covered it
([issue #257](https://github.com/commandprompt/pgcolumnar/issues/257)).

What that testing does not cover is worth stating alongside it. Every result
recorded in this repository comes from x86_64. The suites have not been run on
aarch64 or on a big-endian platform
([issue #242](https://github.com/commandprompt/pgcolumnar/issues/242)).

Unaligned reads are one class that a reader could expect to differ by
architecture. The tests cover that class on each architecture. The sanitizer gate
builds with the clang address checks and undefined-behaviour checks. These report
a misaligned load on any host. That gate exists because the project found and
fixed such a read one time.

What stays untested on another architecture is what a sanitizer on x86_64 cannot
see. Memory ordering is the main item. x86_64 puts stores in a more strict order
than aarch64. Thus a missing barrier in concurrent code can be invisible on one
architecture and a defect on the other. Another architecture is untested. It is
not known to be broken. Give it that status when you build there.

PostgreSQL 19 coverage is against 19beta2, not a final release.

The sections below are the standing functional limitations, separate from that
work.

## On-disk format stability

The on-disk format is versioned. Each columnar relation records two versions. The first is a native data format
version, which is PGCN v1 at this time. The second is a physical metapage
version. The build checks both on read.

The metapage version guards the physical block layout. The native format version
guards the data encoding. Thus the build also catches a future version that
changes the encoding but keeps the metapage layout.

The build refuses a version that it does not know. It reports `unsupported
columnar format version` for the metapage, or `unsupported columnar native format
version` for the data format. The read then fails. It does not read bytes that a
different layout wrote. The check runs on each decode path. These paths include
the sequential scan, the vectorized aggregate, and the index-scan fetch. Thus the
build refuses a version that it cannot read, whichever path the query uses. Both guards are pinned by
`test/native_format.sh`.

A projection stores its own copy of the data and carries its own format version.
The build checks it against the storage of the projection and not against the
storage of the base table. Each stored object therefore describes itself. A build
that writes a new version stamps each object that it writes. This includes the
base table and the projections together.

In one version, the format keeps the data exactly. Data that one build writes and
reads back is identical byte for byte. `test/native_format.sh` proves this on
each supported PostgreSQL major. `test/pg_upgrade.sh` asserts the same property
across a PostgreSQL major upgrade. It runs as an opt-in gate
(`PGC_RUN_UPGRADE=1 test/run_all_versions.sh`). It covers each adjacent pair of
majors, in the copy transfer mode and in the link transfer mode.

There is no in-place upgrade across an incompatible format version. The format has
not changed during the pre-release, so no migration has been needed. The project has not
committed to an upgrade path or to a compatibility guarantee. Until it does, a
change to an incompatible version needs a reload. This is the same position as
the release-status note above. Keep the source that you loaded a columnar table
from. You can then build the table again if a future version changes the layout.
A physical copy keeps the exact bytes, and a build of the same version can read
it. `pg_basebackup`, a file-system snapshot and replication all make such a copy.
A physical copy does not replace the source across a version change.

The same posture covers the extension's own catalog, not only the on-disk data
format. The install script of a build defines the `pgcolumnar` catalog tables for a fresh
`CREATE EXTENSION`. An `ALTER EXTENSION UPDATE` script ships when a build needs one.
The 1.0-dev to 1.0-alpha script is the first.

**Replacing the shared library is not sufficient on its own.** After installing a new
build, run `ALTER EXTENSION pgcolumnar UPDATE;` in every database that has the extension.
The library and the catalog have to agree, and only that command updates the catalog.

Skipping it can leave the catalog describing the previous build. Each installed function
records the name of a C symbol. 1.0-alpha moved those names, so an un-updated catalog
names symbols the new library does not export. Reading an existing columnar table then
fails with `could not find function "columnar_handler"`. The data is untouched, and the
command above fixes it. See [Upgrade](installation.md#upgrade).

A catalog can also lack a column that a newer build needs, where no upgrade script covers
the gap. For example, `sort_by` was added to `pgcolumnar.options`. A function that
uses that column fails against an `options` table that an older build created.

Across an incompatible build, meaning one where no upgrade script covers the change,
recreate the extension with `DROP EXTENSION` and `CREATE EXTENSION`, and load the data
again. This is not the remedy for the un-updated catalog described above, where
`ALTER EXTENSION pgcolumnar UPDATE` is enough. `DROP EXTENSION` removes your columnar
tables with it. Do not replace the files in place. A
dump that exists still restores into a newer build. `pg_dump` writes an explicit
column list for the configuration tables of the extension, and a new column takes
its default of NULL.

## PostgreSQL versions

pgColumnar builds from one source tree on PostgreSQL 15, 16, 17, 18, and
19. Every test suite runs on all five majors. The project validates 19 against 19beta2 and not against a final release. It will
validate 19 again after the release. It validates 15 through 18 against released
versions. PostgreSQL 13 and 14 still
build but are out of the tested matrix.

Three behaviors depend on the major:

- `ALTER TABLE ... SET ACCESS METHOD` exists on PostgreSQL 15 and later. On 13 and
  14, `pgcolumnar.alter_table_set_access_method` builds a new table, copies rows,
  and exchanges the names. This keeps the columns, the defaults, the constraints
  and the indexes. It does not keep the OID of the original relation. It also
  does not keep the objects that depend on it, such as views and foreign keys.
- The read stream prefetch path (`pgcolumnar.enable_read_stream`) is effective on
  PostgreSQL 17 and later. On earlier majors the setting has no effect.
- To set the access method of a *partitioned* table, you need PostgreSQL 17. On
  15 and 16, core refuses `ALTER TABLE ... SET ACCESS METHOD` on each partitioned
  table. It gives the message `cannot change access method of a partitioned
  table`. You therefore cannot make a partitioned parent columnar on those two
  majors, and its later partitions cannot take the choice from it. Set the access
  method of each partition one at a time instead. This is a restriction of core
  PostgreSQL and not of this extension. It applies with a foreign key and without
  one.

## Host architecture

The Arrow and Parquet import and export functions run on little-endian hosts
only. The rest of the extension runs on any architecture PostgreSQL supports.

## Workload and access patterns

- Columnar storage is for data that you mostly append. Updates and deletes
  operate, but they mark the rows and do not rewrite the data. Only
  `pgcolumnar.vacuum` makes the space available again.
- Point lookups are slower than heap, but much less slow than before. A fetch by
  item pointer finds the group of the row, and it keeps the decoded group for the
  rest of the statement. The cost no longer increases with the position of the row
  in its group. Heap is still faster for a single-row fetch. Bloom filters make an
  equality scan faster, because they skip row groups. They do not help a fetch by
  item pointer.
- **The cost of a fetch does increase with the width of the table.** There are two
  causes and both are easy to meet. An index fetch decodes the columns from the
  first one up to the highest-numbered column that the query reads. It does not
  decode only the columns that it reads. A query that reads one late column
  therefore decodes every column before it. The second cause is the size limit on
  the decoded columns that the statement keeps. The columns that do not fit are
  decoded again on each fetch. A table of many wide text columns meets both
  conditions. One measurement shows the effect. On a table of ten text columns,
  with the same rows and the same plan, a query on the first column took 975 ms.
  A query on the tenth column took 194,798 ms.
- A bulk `UPDATE` or `DELETE` through an index no longer costs the number of rows
  multiplied by the row group size. It still costs several times more than heap.
  The reason is that each changed row is marked and written again, and not
  changed in place.

## Bulk load and import throughput

For most data shapes, a load into a columnar table is slower than a load into a
heap. The factor depends on the data. There is no single number. The measurement
used 6,000,000 rows on PostgreSQL 17.10, non-assert, against a heap insert of the
same rows:

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

`encode_effort` is the control. The default is `full`. It spends the most on the
encoding and gives the best storage ratio. `fast` accepts a lower ratio and gives
a higher load speed. On high-entropy text it recovers most of the cost, because
the encoding search is the work that it omits. Set it for one table with
`pgcolumnar.set_options(rel, encode_effort => 'fast')`. For low-cardinality text,
dictionary encoding is the largest cost and not that search. `fast` therefore
helps less.

`import_arrow` and `import_parquet` are not slower than an ordinary `INSERT` of
the same rows. There is no import-specific overhead; the cost is the columnar
write path either way.

Work on load throughput is tracked in
[issue #155](https://github.com/commandprompt/pgcolumnar/issues/155). One realized lever
is [`pgcolumnar.parallel_copy`](#parallel-bulk-ingest). It loads a text file
across several cores at once.

## Parallel bulk ingest

`pgcolumnar.parallel_copy` loads a text file with several workers at once. It has
these constraints.

- The file must use COPY text format. The function does not accept CSV or binary
  format.
- The target is a single columnar table or a RANGE-partitioned table with
  columnar partitions. The function rejects any other target, such as a heap
  table.
- For a partitioned target the file must be sorted ascending by the partition
  key. The key type must be numeric or a date/time type. The function reports an
  error for a text key and for an unsorted file.
- The caller needs membership in the `pg_read_server_files` role and INSERT on
  the target. The file is read on the server host.
- Set `max_prepared_transactions` above the worker count. The load prepares one
  transaction per worker, and the function errors up front when the setting is
  too low.
- The speedup is bounded by the physical core count. The columnar encode step is
  CPU bound, so workers past the physical cores add little.
- The load commits on its own. It runs in background workers, so it is not part
  of the calling transaction. A `ROLLBACK` in the caller does not undo the loaded
  rows. The atomicity is across the workers, not with the caller.
- The load is atomic through two-phase commit. A coordinator crash during the
  final commit step can leave some ranges committed and some prepared. This is
  the ordinary two-phase-commit in-doubt case. A DBA resolves it from
  `pg_prepared_xacts`.

See the [SQL reference](sql-reference.md#pgcolumnarparallel_copytarget-regclass-filename-text-workers-int-default-null-returns-bigint)
and [Benchmarks](benchmarks.md#parallel-bulk-ingest).

## Planner statistics

`ANALYZE` collects column statistics for a columnar table. These are the null
fraction, the distinct counts, the most-common values, the histograms and the
correlation. This is the same set that it collects for a heap table. The planner
then estimates the predicates from the data.

Correlation has a special importance. It is the statistic that shows
`pgcolumnar.vacuum_sorted` and Z-order clustering to the planner. A table that is
stored in sorted order on a key reports a correlation near 1 for that column. The
planner can then give a correct cost to a range scan on it.

The row count the planner uses does not come from `ANALYZE` at all. It comes from the row-group
metadata. It is therefore correct whether or not `ANALYZE` has run.
`pg_class.reltuples` is a few percent low after `ANALYZE`. Some blocks hold no
row-group data, such as the metapage and the space that is reserved but not
written. These blocks count as visited, but they give no rows. The planner does
not use that figure for columnar tables.

`ANALYZE` costs more on a columnar table than on a heap of the same size. The
sampler offers every row of every block that it visits, so the cost follows the
rows offered and not the rows kept. It reads those rows with a reader that is
restricted to one row group, and not through the fetch-by-row-number path.

`TABLESAMPLE` is unsupported and says so: it raises an error rather than
returning no rows.

## Vacuum and compaction

- `autovacuum_parallel_workers`, the per-table storage parameter PostgreSQL 19 adds
  for parallel autovacuum, is accepted on a columnar table and has no effect.
  pgColumnar implements its own vacuum, which marks the visibility map and retires
  fully-deleted row groups, and does no parallel work. The parameter cannot be
  refused: storage-parameter validation belongs to PostgreSQL and is driven by the
  relation kind rather than by the access method. Setting it is harmless and
  pointless.
- `VACUUM FULL` and `CLUSTER` are not supported on a columnar table; the
  copy-for-cluster path raises an error. Use `pgcolumnar.vacuum` or
  `pgcolumnar.vacuum_full` instead.
- `pgcolumnar.vacuum` always rewrites the whole relation into full row groups. It
  accepts a `stripe_count` argument for compatibility with the interface, but it
  does the full rewrite. It gives the rows new numbers, so it also builds the
  indexes of the table again.
- The writer reserves row numbers one whole row group at a time. A row group that
  it flushes with fewer than `stripe_row_limit` rows therefore leaves a gap in
  the row-number space. A row number must be unique and stable, and nothing more.
  The gap does no damage.
- A declared `sort_by` key (#288) and `pgcolumnar.vacuum_sorted` are **one-shot**.
  Rows that an insert adds after a sort go in at the end, in insertion order. No
  operation sorts them again. Skip quality therefore decreases until the next
  `vacuum_sorted`. `pgcolumnar.sort_status` reports how far that has gone, so the
  decision to re-sort rests on a measurement. The online `pgcolumnar.recluster`
  records only the part of its output it can prove is one contiguous ordered
  run. A table reclustered while another session was inserting therefore reports
  more decay than it has. PostgreSQL `CLUSTER` behaves the same way and is also not
  maintained on insert. An online re-sort for text keys that does not block, and
  automatic maintenance, are not implemented yet. A sort key is also a trade. It
  puts the values of one dimension together, and it spreads the other dimensions
  across each chunk group. A query that filters a *different* dimension can
  therefore skip fewer groups than the natural insertion order permits. Sort by
  the key that your selective queries filter on.

## Index-only scans

An index-only scan uses the columnar visibility-map fork, which lazy `VACUUM`
populates. A row group gets the all-visible mark only when two conditions are true. Its
inserting transaction must come before the oldest snapshot horizon, and the group
must have no deletes. Any later write clears the bit. A fetch that checks the
snapshot serves data that a load wrote recently. This continues until autovacuum
or an explicit `VACUUM` marks the group. Turn the feature off with
`pgcolumnar.enable_index_only_scan = off`.

## Projections

A projection is an additional sorted copy. Each projection therefore adds write
cost and storage cost. `pgcolumnar.vacuum` builds the projections again.

The planner uses a projection only when two conditions are true. The projection
must contain each column that the query refers to, with no system columns and no
whole-row references. The query must also restrict the leading sort column of the
projection. Other queries read the base table.

When you add a projection to a table that holds rows, the build fills it under
`ShareLock`. That lock stops concurrent writes until the build completes, in the
same way as a `CREATE INDEX` that is not concurrent. Turn projection scans off with
`pgcolumnar.enable_projection_scan = off`.

## Concurrency

- Concurrent deletes or updates to rows in the same row group go in sequence, on
  the row-mask entry of that group. A second writer waits for the first writer to
  commit. It then reads the committed mask again and merges its own bits. Thus
  both sets of delete marks survive. Writes to different row groups continue at
  the same time.
- Concurrent inserts of the same unique key go in sequence. The server therefore
  always finds the conflict. Before a new row reaches the uniqueness check, the
  access method takes an advisory lock with the scope of the transaction. The key
  of that lock is the unique key of the row. Equal keys hash to the same lock,
  which agrees with the equality of the index. Thus `numeric` `1.0` and `1.00`,
  `citext` values that differ only in case, and text values that a collation
  makes equal, all go in sequence correctly. Each index has a limited number of buckets, which
  `pgcolumnar.unique_lock_buckets` sets and which defaults to 128. Keys hash into
  those buckets. Two keys that are not related can share a bucket. Such keys go
  in sequence when they do not need to, but they never fail to go in sequence
  when they must. This applies to unique, immediate and valid
  indexes. It includes multi-column indexes, partial indexes and expression
  indexes. Some indexes use a single lock for the whole index
  instead. The first is an index whose operator class does not match
  the default equality of its key type. The second is an index whose key type has
  no hash support. A
  true conflict on the same key can appear as a deadlock abort and not as a
  `unique_violation`. Both results refuse the duplicate. Turn the serialization off with
  `pgcolumnar.enable_unique_insert_lock = off`.

## Row locking

`SELECT ... FOR UPDATE`, `FOR SHARE` and `FOR KEY SHARE` are not implemented on a
columnar table and raise `columnar: row locking is not supported yet`.

Two consequences are worth stating here, because the error surfaces somewhere
other than where the feature is used:

- **A foreign key cannot refer to a columnar table. The server refuses such a
  key when you create it.** The check for referential integrity reads the parent
  row with `FOR KEY SHARE`. A columnar table cannot do that. `CREATE TABLE` and
  `ALTER TABLE ADD CONSTRAINT` therefore refuse the constraint. They do not
  accept a constraint that nothing could satisfy. A columnar table on the child side of a foreign
  key is unaffected and works normally.
- **The server refuses a conversion of a table that a foreign key already refers
  to. The reason is the same.** `ALTER TABLE ... SET ACCESS METHOD pgcolumnar` and
  `pgcolumnar.alter_table_set_access_method` give the same configuration from the
  other side. They are therefore refused while a foreign key refers to the table.
  A partitioned table is also refused. It has no storage of its own. But it sets the access
  method that each later partition takes, and core would then refuse each of those
  partitions. Drop the constraint first if the table must be
  columnar. A conversion of the referencing side is permitted. A conversion of a
  table that no foreign key refers to is also permitted.
- `INSERT ... ON CONFLICT DO UPDATE` takes a row lock and raises the same error.
  `ON CONFLICT DO NOTHING` does not, and works.

`CREATE TABLE` refuses an unlogged columnar table for the same reason. Both cases
follow one rule. This access method refuses a configuration that it cannot
support at the point where you choose it. It does not refuse it at each later
use.

## Indexes

- Stale index entries left by deletes and updates are filtered on fetch and
  reclaimed by `REINDEX`, not removed opportunistically.
- `CREATE INDEX CONCURRENTLY` (the concurrent validate path) and partial
  block-range index builds are not supported.

## Constraints on the import path

`pgcolumnar.import_arrow` and `pgcolumnar.import_parquet` maintain each index on
the target. They also apply the unique constraints and the exclusion constraints.
An import therefore cannot reach a state that an ordinary `INSERT` would refuse.
The import path defers a deferrable constraint to the commit, as ordinary DML
does. An import can therefore break uniqueness for a short time in the middle and
still be correct at the end. Such an import commits, and the server does not
refuse it.

## Vectorized aggregate coverage

The vectorized aggregate path covers one shape only. That shape is
`SELECT agg(col) FROM t [WHERE ...]`, on one relation and with no grouping. The
path also needs each aggregate, each column type and each filter clause to be
supported. The supported set is:

- `count`, which includes `count(*)` and `count(col)`.
- `sum` and `avg` on `smallint` and `integer` columns.
- `min` and `max` on any type that has a default ordering.
- `WHERE` clauses that are conjunctions of simple `column op const` comparisons.

Each other query uses the scalar plan and stays correct. These include `sum` or
`avg` on `bigint`, `numeric` or floating point. They also include these:

- ordered-set aggregates and string aggregates
- aggregates with `DISTINCT`
- `GROUP BY` (unless the opt-in grouped path below is enabled) and `HAVING`
- filters that are not simple
- joins
- a reference to a whole row or to a system column

A separate opt-in path vectorizes `GROUP BY`. It is off by default. Set
`pgcolumnar.enable_group_vectorization` to `on` to enable it. It covers
`SELECT <keys>, agg(col) ... [WHERE ...] GROUP BY <keys>` on one columnar
relation. Each key must be non-volatile, hashable, and computable from that
relation. A collatable key must use a deterministic collation. Each output must
be a supported aggregate or a bare key reference. This path also accepts `sum`
and `avg` on `bigint`, `numeric`, and floating-point columns, which the ungrouped
path rejects. `pgcolumnar.groupagg_max_groups` caps the group count, default
1,000,000. The cap is checked at execution against the real count, so a query
that exceeds it errors rather than switching plans. Raise the cap or turn the
path off.

## Skipping and collation

A pushed-down filter drives chunk-group skipping only when one condition is true.
The collation of the comparison must match the collation of the column. That is
the collation that put the stored minimum and maximum in order. A comparison with
a different collation still operates as a filter, but it does not drive skipping.
The results therefore never depend on the pushdown.

## Replication and backup

- Physical replication and physical backups (`pg_basebackup`, snapshots) include
  columnar tables, which are WAL-logged relations.
- `pg_dump` and `pg_restore` handle columnar tables, and the target server must
  have the extension installed and preloaded. The table data, the indexes and the
  per-table options (`pgcolumnar.set_options`) survive the round trip. The
  projection **storage** does not. Its key is an internal storage id, and a
  restore makes a new one. The projection **declaration** does survive, in
  `pgcolumnar.projection_declaration`, which is keyed by relation and stores
  column names. After a restore, run `pgcolumnar.rebuild_projections()` to build
  the projections again from those declarations. A physical backup (`pg_basebackup`) copies the
  cluster bytewise and preserves them.
- Logical decoding reads the WAL records of heap tuples. Columnar data reaches
  WAL as full-page images, and those carry no tuple structure. Logical decoding
  therefore does not emit a change to a columnar table, and logical replication
  does not carry it. Use physical replication for columnar tables.

  A decoding slot is not silent about a columnar table, which is the part worth
  knowing before relying on one. The metadata catalog uses ordinary heap tables.
  A slot therefore delivers the inserts and the updates to `pgcolumnar.storage`,
  `pgcolumnar.row_group`, `pgcolumnar.column_chunk`, `pgcolumnar.zone_map` and
  `pgcolumnar.delete_vector` while the writer writes the table. A consumer with a
  subscription to all tables therefore gets a stream of internal records. This
  includes the encoded chunk descriptors, as bytea. It includes none of the rows
  of the table. Filter
  the `pgcolumnar` schema out of any publication.

  To capture changes from a columnar table today, use a row trigger that writes
  to a heap table and decode that. The recipe is in
  [user-guide.md](user-guide.md#capture-changes-for-replication-or-cdc).

## Import and export type coverage

The import and export functions require the `pg_read_server_files` or
`pg_write_server_files` role, which superusers hold, and run on little-endian
hosts.
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

The reader imports `uuid` from a fixed-length binary column of 16 bytes. It
imports `numeric` from a DECIMAL column with a precision up to 38. That column
holds big-endian bytes, of fixed or variable length. The reader also imports
`numeric` from an INT32 or an INT64 that holds the unscaled integer. Writers use
that form for a small precision.

`numeric` needs a declared precision for a Parquet round trip. The exporter writes DECIMAL only for a column that you
declare as `numeric(p,s)`, with `p` up to 38. It writes a `numeric` column with
no precision as text, and it does the same for a column with `p` above 38. The
reader cannot import a text column back into `numeric`. Declare
`numeric(p,s)` with `p` up to 38 when the file has to read back into a `numeric`
column. Arrow export and import carry `numeric` in either form.
The exporter can write `json` and `jsonb` to Parquet, and other tools can read
them. pgColumnar cannot import them from Parquet at this time. Arrow supports
both types in each direction.

## Compression codecs

For the native table format, `lz4` and `zstd` are available only when the
extension was built with the corresponding system libraries. When the build does not
include a codec, a request for it uses a codec that the build does include.
`pglz` and `none` are always available.

When reading external Parquet files, the reader decodes uncompressed, Snappy,
GZIP, ZSTD, and LZ4_RAW pages. GZIP needs a build with zlib. ZSTD and LZ4_RAW
need the same libraries as the native codecs. A page whose codec the build did
not include fails with an explicit decode error. LZO, BROTLI, and the deprecated
Hadoop-framed LZ4 (codec 5, as distinct from LZ4_RAW) are not read.

## Reading external Parquet

The read-in-place surface (`read_parquet`, `parquet_schema`, and the
`pgcolumnar_parquet` foreign-data wrapper) has these limits:

- Reads require the `pg_read_server_files` role, which superusers hold, and run on
  little-endian hosts, as import and export do, since they read a server-side path. A file from a different source is input
  without trust, and the parser for it is code that this project wrote. Refer to
  Security in the administration guide for the trust boundary and the risk that
  stays. Issue #214 tracks the fuzzing.
- A `path` that is a directory reads the `*.parquet` files at any depth below
  it, descending into subdirectories. The reader skips each entry whose name starts
  with `_` or `.`, and it does this for directories and for files. Spark and Hive
  write names of that form, such as `_SUCCESS` beside the data and the output of
  a task in progress under `_temporary`. The reader still reads a path that you
  name directly, whatever its name is. The reader does not go into a directory
  that it reaches through a symbolic link. A link to a parent would make the walk
  continue without end. It does follow a symbolic link to a file. Nesting deeper than 32 levels raises rather than reading part of the
  tree.
- Hive-style partitioning is available on the foreign-data wrapper only, through
  the `partition_columns` table option. The columns are declared, not inferred
  from the tree, and `read_parquet` has no equivalent. The reader takes a value from the directory name,
  after it decodes the percent escapes. A value written as `a%3Db` therefore
  reads as `a=b`. Hive and Spark write `__HIVE_DEFAULT_PARTITION__` as the marker
  for a null partition value, and the reader gives NULL for it, not that string.
  A file must carry a directory component for each declared column. If it does
  not, the reader raises an error. It does not give rows with nulls in the
  partition columns.
- The reader takes the partition values only from the directory components
  between the declared path and the file. A component above the path does not set
  a column. A file whose own name has the form `col=value` does not set one
  either.
- A predicate that reads only partition columns prunes files, unless it contains
  a volatile function. Pruning decides a clause one time for each file. That
  matches the decision that the executor would make for each row, but only when
  the clause depends on the partition values alone. A volatile call does not meet
  that condition. The reader therefore leaves such a clause to the
  executor and prunes nothing. Stable and immutable functions still prune.
- `parquet_schema` describes the first file of a directory or glob, assuming the
  set is uniform. The read paths still bind every file against the declared
  columns, so a mismatched file raises rather than returning wrong rows.
- A `TIMESTAMP` column with nanosecond precision is advised as `bigint`, which is
  exact; declaring it `timestamp` reads it with the sub-microsecond digits
  truncated.
- The reader reads a file in parts and does not load the whole file. It holds the
  footer for the length of the scan. It reads the pages one at a time. Peak memory for the
  raw file data is one page, not one file, so file size is not a limit. What does
  increase with the data is the decoded form of one row group, for the columns
  that the query reads. The reader decodes a row group before it produces the rows
  of that group. A file
  written with larger row groups therefore costs more memory than the same data
  written with smaller ones.
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
  interval must not be inverted. Two cases decode to an interval that the reader
  does not trust for skipping. The first is an unsigned Parquet column that
  crosses the sign boundary. The second is a column that the reader makes
  narrower, into a smaller PostgreSQL type.

The `Row Groups Skipped` counter in `EXPLAIN ANALYZE` reports what was actually
skipped.
