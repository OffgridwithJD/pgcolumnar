# Features

This document lists what pgColumnar provides. For how to use each capability see
the [user guide](user-guide.md) and [administration](administration.md); for
settings see the [configuration reference](configuration.md); for constraints see
[limitations](limitations.md).

## Storage and format

- Column-oriented storage in the relation's main fork, so the buffer manager,
  WAL, and page checksums apply. Data is stored in the native format, PGCN v1,
  specified in
  [../design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md](https://github.com/commandprompt/pgcolumnar/blob/main/design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md).
- The writer selects the value encoding for each vector. It estimates each
  candidate on a strided sample and then applies only the best two. It does not
  apply each candidate to the whole vector. On a load of 6,000,000 rows this
  removes approximately one third of the write time, with no measured cost to the
  ratio. `pgcolumnar.encoding_sample_rows = 0` restores the
  exhaustive behaviour.
- The writer puts the rows into row groups, which are the unit of the write. In a
  row group, it keeps each column as its own chunk and compresses each chunk
  separately. It encodes the values of a chunk in vectors of a fixed size. Zone maps hold each chunk's and each vector's
  minimum and maximum for skipping.

## Encodings and compression

- Value encodings that know the type, applied to each chunk before compression.
  These are run-length (RLE), frame-of-reference
  with bit-packing (FOR), delta, delta-of-delta, and Gorilla XOR for floats.
  There is also a dictionary for columns with a low cardinality, which includes
  text. Each chunk takes the encoding that makes it
  smallest. The block codec then runs on the encoded stream.
- Block compression with four codecs: `none`, `pglz`, `lz4`, and `zstd` with a
  level. The writer compresses each column chunk separately. It stores a chunk
  without compression if the compression makes it no smaller.

## Scan and execution

- Column projection: a scan decodes only the columns the query references.
- Chunk-group skipping: a per-chunk minimum and maximum skip list lets a filtered
  scan skip chunk groups that cannot match a pushed-down `column op const`
  qualifier. A per-chunk bloom filter additionally skips groups on an equality
  probe whose value is provably absent, for hashable columns whose collation is
  deterministic. This covers the types that have no collation,
  such as ids and uuids. It also covers text under an ordinary deterministic
  collation. It does not cover a nondeterministic collation, because two equal
  values there do not have to share a hash. The
  executor always re-applies the full qualifier, so skipping never changes
  results.
- Vectorized aggregate. The zone-map metadata answers an ungrouped `count`,
  `sum`, `avg`, `min` or `max` on a supported column type. If the group has
  deletes, a fold over the decoded values answers it, one column at a time.
  Neither path uses the per-tuple executor path. `count(*)` with no filter is one case of
  this: it is answered from each row group's stored row count and reads no column
  data. Set `pgcolumnar.enable_vectorization` to `off` to force an ordinary
  aggregate over the scan instead. An opt-in path vectorizes `GROUP BY` too. Set
  `pgcolumnar.enable_group_vectorization` to `on` to group and aggregate in one
  pass over the reader. It is off by default.
- Column statistics. `ANALYZE` samples rows from across the row groups. It stores
  the null fraction, the distinct counts, the most-common values, the histograms
  and the correlation. The planner then estimates the predicates from the data. Correlation is what lets the planner
  see the locality `pgcolumnar.vacuum_sorted` and Z-order clustering create.
- A fetch by row number decodes only the columns that the executor asks for. It
  keeps the decoded row group for the rest of the statement. An index-driven read
  of a wide table therefore does not decode the columns that it will not return.
- Parallel scan across a table's row groups.
- Read stream prefetch of block reads on PostgreSQL 17 and later
  (`pgcolumnar.enable_read_stream`).

The vectorized aggregate and skipping change how a result is computed, never the
result. See [limitations](limitations.md) for the exact aggregate and type
coverage.

## Indexes and index-only scans

- `CREATE INDEX` builds btree and hash indexes over a columnar table. Every row is
  assigned a stable row number and synthetic item pointer at insert time, so
  ordinary index scans fetch rows by item pointer.
- Index-only scans: a columnar visibility-map fork records which chunk groups are
  all-visible. Lazy `VACUUM` sets the bit for a group when two conditions
  are true. The inserting transaction of the group must come before the oldest
  snapshot horizon. The group must also have no deletes. Any write clears the bit. WAL
  records both operations. For an all-visible group, a covering index query
  answers from the index tuple. For any other group, it uses the row fetch that
  checks the snapshot. An index-only answer therefore never returns a row that
  the snapshot cannot see. On by default (`pgcolumnar.enable_index_only_scan`).

## Projections

- Multiple projections, which follow the C-Store model.
  `pgcolumnar.add_projection(table, name, columns, sort_key)` declares an extra
  physical copy of a subset of the columns. That copy has its own sort order. It
  shares the row identity of the table. Every insert fans
  out to each projection. A projection stored sorted has tight per-chunk minimum
  and maximum ranges.
- The planner scans a projection instead of the base table when it covers the
  query's columns and its leading sort column is restricted. `EXPLAIN` shows
  `Columnar Projection: <name>`. Deletes and MVCC visibility come from the base,
  and `pgcolumnar.vacuum` keeps projections aligned.
  `pgcolumnar.drop_projection(table, name)` frees one. On by default
  (`pgcolumnar.enable_projection_scan`).

## Transactions, MVCC, and DML

- Reads see the transaction's own inserts and deletes while staying isolated from
  other transactions. Deletes and the old side of updates are marked in a row mask
  without rewriting row groups. Pending work is discarded on transaction and
  savepoint rollback, with correct attribution across `ROLLBACK TO`.
- Unique and primary-key constraints are enforced on insert and at index build
  time. NOT NULL and CHECK constraints are enforced through the insert path.
- Concurrent inserts of the same unique key are serialized so the conflict is
  always caught, controlled by `pgcolumnar.enable_unique_insert_lock`. See
  [limitations](limitations.md) for the exact behavior.

## Schema changes

- `ALTER TABLE ... ADD COLUMN` on a table that holds rows, with no rewrite. A row
  group that the writer wrote before the column existed carries no chunk for that
  column. The reader then gives the missing value of the column. That value is
  NULL, or the constant default that you gave with the column. This matches the
  fast-default behaviour of a heap table.
- `pgcolumnar.alter_table_set_access_method(table, method)` converts a table to or
  from columnar storage. See [limitations](limitations.md) for the PostgreSQL 13
  and 14 behavior.

## Maintenance

- `pgcolumnar.vacuum(table)` rewrites a table's live rows into full row groups,
  combining small row groups, reclaiming deleted-row space, and rebuilding indexes.
  `pgcolumnar.vacuum_full(schema)` does the same across a schema.
- `pgcolumnar.vacuum_sorted(table, col [, col ...])` rewrites a table stored sorted
  on the given columns, ascending with nulls last. A sorted key gives tight per-chunk ranges that
  do not overlap. Range predicates and ordered scans therefore skip more chunk
  groups. The sort key also compresses better under the RLE and delta encodings. It is a one-time reorder, like `CLUSTER`: rows inserted afterward
  append in insert order until the next call.
- `pgcolumnar.cluster(table, col [, col ...])` orders the rows by a Z-order
  (Morton) curve on several numeric columns at once. Point and range filters on
  more than one clustered column then skip more groups. It holds
  `AccessExclusiveLock`, like core `CLUSTER`, so it is an eager bulk operation.

### Online reclaim and clustering

These verbs run against a live table under `ShareUpdateExclusiveLock`, so reads
and writes continue.

- `pgcolumnar.compact(table)` retires row groups that are fully deleted and drops
  their metadata, so scans skip them.
- `pgcolumnar.compact_rewrite(table, min_deleted_fraction, max_groups)` rewrites
  partially deleted row groups to drop their dead rows and reclaim the space.
  `max_groups` bounds how many one call rewrites.
- `pgcolumnar.recluster(table, col [, col ...])` re-establishes the same Z-order
  as `cluster` online. It is a fast no-op when the recorded key is intact.
- `pgcolumnar.truncate(table)` returns the reclaimed end blocks to the operating
  system, taking a brief `AccessExclusiveLock` only when it is free.

### Reporting and the maintenance daemon

- `pgcolumnar.stats(table)` reports per-row-group row counts, deleted-row counts,
  chunk counts, and byte sizes. `pgcolumnar.sort_status(table)` reports how much of
  the declared sort order remains. `pgcolumnar.maintenance_due(table, ...)` reports
  whether a table has crossed the compact and recluster thresholds.
- `pgcolumnar.autovacuum` is a background maintenance daemon. When on, a per-database
  worker runs the online verbs above on a schedule for tables that
  `maintenance_due` reports as due. It runs only the online operations, so it never
  takes an exclusive lock, and it yields to a stronger lock a session requests.

## Parallel bulk ingest

- `pgcolumnar.parallel_copy(target, path [, workers])` loads a COPY text file with
  several background workers at once, as one atomic operation. It returns the row
  count. The columnar encode step is CPU bound, so more workers give a large load
  speedup up to the physical core count.
- Each worker runs core `COPY` over a byte range of the file, so parse and write
  behavior match `COPY FROM` exactly. There is no second parser to keep correct.
- The load is atomic. Each worker prepares its transaction, and a coordinator
  commits them together only when every worker succeeded. Any failure rolls the
  whole load back, and the target keeps its earlier contents.
- The target is a single columnar table or a RANGE-partitioned table with
  columnar partitions. A single table needs no row order. A partitioned target
  needs the file sorted ascending by the partition key, whose type must be
  numeric or a date/time type.
- See the [SQL reference](sql-reference.md#pgcolumnarparallel_copytarget-regclass-filename-text-workers-int-default-null-returns-bigint)
  and [Benchmarks](benchmarks.md#parallel-bulk-ingest).

## Interoperability

- Export to Arrow and Parquet: `pgcolumnar.export_arrow(table, path)` and
  `pgcolumnar.export_parquet(table, path)`, both without a libarrow or libparquet
  dependency.
- Parallel Parquet export: `pgcolumnar.parallel_export_parquet(table, dir, workers)`
  writes a columnar table to a directory of Parquet files with several read-only
  background workers, one file each. It gives a near-linear speedup, returns the
  row count, and `pgcolumnar.read_parquet` reads the directory back.
- Import from Arrow and Parquet: `pgcolumnar.import_arrow(table, path)` and
  `pgcolumnar.import_parquet(table, path)`, into a target table that exists. The
  import maintains each index on the target. It also applies the unique
  constraints and the exclusion constraints. It therefore cannot leave the table
  in a state that ordinary DML would refuse. The Parquet reader parses the Thrift
  metadata. It decompresses uncompressed, Snappy, GZIP, ZSTD and LZ4_RAW pages.
  It decodes the PLAIN encoding and the dictionary encoding, from data-page
  version 1 and version 2.
- Both directions cover scalar types, one-dimensional arrays, and composite types
  (Arrow List and Struct, Parquet LIST and group), with nulls at every level. The
  functions require a server-file role, `pg_read_server_files` to read or
  `pg_write_server_files` to write, which superusers hold. They run on
  little-endian hosts. See the
  [SQL reference](sql-reference.md#import-and-export) and the
  [type-coverage table](limitations.md#import-and-export-type-coverage).

## Reading external Parquet in place

- `pgcolumnar.read_parquet(path) AS t(...)` reads a server-side Parquet file's
  rows without importing them, and `pgcolumnar.parquet_schema(path)` reports its
  leaf columns and the PostgreSQL type each maps to.
- The `pgcolumnar_parquet` foreign-data wrapper exposes a Parquet file as a
  foreign table: `CREATE FOREIGN TABLE ... SERVER ... OPTIONS (path '...')`.
- A `path` that is a directory reads each `*.parquet` file below it, at any
  depth, as one relation. A glob pattern expands in the same way. Both use a
  sorted order that does not change between runs.
- The foreign-table scan streams one row group at a time. It holds one row group
  rather than the whole file, and a `LIMIT` the plan meets early leaves the rest
  undecoded. It pushes work down. It skips a row group when the
  minimum and maximum statistics exclude the predicate of the query. It decodes
  only the columns that the query refers to. `EXPLAIN ANALYZE` reports the row
  groups read, skipped, and decoded, the columns read, and the number of files.
  Skipping applies to `column op constant` clauses over integer and
  floating-point columns; see [limitations.md](limitations.md) for the exact
  conditions.
- Hive-style partitioning. A foreign table that declares `partition_columns`
  reads a `col=value` directory name as a column. A predicate on such a column
  removes complete files before the reader opens them. A file that pruning
  removes therefore costs no I/O.
  `EXPLAIN ANALYZE` reports `Files Pruned`.
- uuid and numeric columns are read from their Parquet representations, and the
  reader handles millisecond, microsecond, and nanosecond time units.
- Files are read on demand rather than loaded whole. The reader reads the footer first. It then
  reads each page when the scan reaches it. Memory use therefore does not increase
  with the size of the file. The available disk limits a file, and memory does
  not. A row group that
  predicate pushdown excludes is never read from disk at all, and
  `parquet_schema` reads only the footer.

## Object storage

- Every path that reads or writes a Parquet or Arrow file also accepts an
  `s3://`, `http://`, or `https://` URL. This covers `read_parquet`,
  `export_parquet`, `import_parquet`, `parquet_schema`, the `pgcolumnar_parquet`
  foreign-data wrapper, and the Iceberg reader. The support lives in a separate
  module, `pgcolumnar_objstore`, loaded on the first remote use.
- `s3://` requests are signed with AWS Signature Version 4. An `https://` request
  verifies the server certificate when the module is built with OpenSSL. An export
  writes a small object in one request, and a large object as a multipart upload
  that is visible only when it completes.
- Credentials come from the server process environment: `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`, and
  `AWS_ENDPOINT_URL`. The foreign-data wrapper can read them from its server and
  user mapping instead.
- `pgcolumnar.objstore_allowed_endpoints` gates every remote scheme. It is empty
  by default, so no host is reachable until an administrator lists it. A
  link-local or instance-metadata address is refused even when it is listed.

## Apache Iceberg

Read-only support for Apache Iceberg tables at their current snapshot.

- `pgcolumnar.iceberg_scan(metadata_path) AS t(...)` reads a table given a column
  definition list. It resolves each output column to a schema field id, so a data
  file written before a column rename still reads. The metadata path may be local
  or an object-storage URL.
- It applies row-level deletes of all three kinds. A position delete drops named
  row ordinals. An equality delete drops rows matching on its `equality_ids`,
  including a partition-scoped delete. A format-version 3 deletion vector applies a
  Puffin roaring bitmap. Each kind follows its own sequence rule.
- A data file written outside Iceberg, with no field ids, is read through the
  table's `schema.name-mapping.default` property. A file with neither field ids nor
  such a mapping is refused rather than guessed.
- `pgcolumnar.iceberg_current_snapshot` and `pgcolumnar.iceberg_data_files`
  introspect a table. `pgcolumnar.read_avro_manifest` and
  `pgcolumnar.read_manifest_list` read the Avro building blocks.

### REST catalog

- `pgcolumnar.iceberg_rest_scan(catalog_uri, namespace, table)` reads a table named
  by a catalog rather than a metadata path. `iceberg_rest_table_location`,
  `iceberg_rest_namespaces`, and `iceberg_rest_tables` resolve and list a catalog.
- A bearer token comes from the `PGCOLUMNAR_ICEBERG_REST_TOKEN` environment
  variable. It can instead come per role from a foreign server and user mapping of
  the `pgcolumnar_iceberg_catalog` wrapper. The mapping holds the token in
  `pg_user_mapping`, where it is not world-readable.
- A user mapping may carry OAuth2 client credentials instead of a static token.
  The catalog then mints a short-lived bearer by the client-credentials grant.
- A catalog can vend short-lived storage credentials in its reply. The reader then
  reads the table files with those credentials, not the server environment.

### Foreign-data wrapper and file pruning

- The `pgcolumnar_iceberg` foreign-data wrapper exposes an Iceberg table as a
  foreign table with a `metadata_path` option. Unlike `iceberg_scan`, it receives
  the query predicate, so it prunes whole data files before it opens them.
- Partition pruning covers identity, `bucket[N]` (murmur3), `truncate[W]`, and the
  temporal transforms `year`, `month`, `day`, and `hour` on date, timestamp, and
  timestamptz columns. Metrics pruning covers integer and boolean columns by their
  stored minimum and maximum.
- Pruning is only an optimization. A predicate the wrapper cannot decide reads the
  file and returns the same rows. `EXPLAIN (ANALYZE)` reports `Files Pruned`.
