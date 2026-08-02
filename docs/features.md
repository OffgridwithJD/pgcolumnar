# Features

This document lists what pgColumnar provides. For how to use each capability see
the [user guide](user-guide.md) and [administration](administration.md); for
settings see the [configuration reference](configuration.md); for constraints see
[limitations](limitations.md).

## Storage and format

- Column-oriented storage in the relation's main fork, so the buffer manager,
  WAL, and page checksums apply. Data is stored in the native format, PGCN v1,
  specified in
  [../design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md](https://github.com/jdatcmd/pgcolumnar/blob/main/design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md).
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
- `pgcolumnar.stats(table)` reports per-row-group row counts, deleted-row counts,
  chunk counts, and byte sizes.

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
  functions require superuser and run on little-endian hosts. See the
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
- The foreign-table scan pushes work down. It skips a row group when the minimum
  and maximum statistics exclude the predicate of the query. It decodes only the
  columns that the query refers to. `EXPLAIN ANALYZE` reports the row groups read and
  skipped, the columns read, and the number of files. Skipping applies to
  `column op constant` clauses over integer and floating-point columns; see
  [limitations.md](limitations.md) for the exact conditions.
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
