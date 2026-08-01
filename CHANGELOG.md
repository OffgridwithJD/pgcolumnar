# Changelog

All notable changes to pgColumnar are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). pgColumnar is
pre-release; the version marker is `1.0-dev`, recorded in `VERSION`. New tables
are written in the native on-disk format, PGCN v1. Everything below is
unreleased. For the forward-looking plan see
[design/ROADMAP.md](design/ROADMAP.md); for full history see the git log.

## [Unreleased]

### Changed

- A row group's bloom filter is read for the columns a query filters on, not for
  every column (#314). A predicate probes one column, so a group that is
  examined needs the filters of the columns carrying predicates and no others.
  `bloom_pkey` is `(storage_id, group_number, column_index)`, so naming the
  column makes the fetch an exact index lookup rather than a range scan whose
  unwanted rows are discarded. Measured on one group of 200,000 rows over 12
  columns with one equality predicate: 715 buffers to 323, against a floor of
  251 with the bloom read deleted outright. With #310 the same probe query falls
  from 9577 buffers to 1547.

- A row group's bloom filters are read only when a predicate reaches them, not
  before every skip decision (#310). A bloom filter is consulted only for an
  equality predicate whose zone map did not already rule the group out, so a
  group the zone map skips needs none of them. The reader loaded them for every
  candidate group, and the cost scaled with the column count and the group size,
  because a filter holds one bitmap per column sized by the group's distinct
  values. Measured on 20 groups of 200,000 rows over 12 columns: 466 buffers per
  skipped group out of 504, with the whole query falling from 9577 buffers to
  1946. Results do not change; the filter was always a pruning step.

### Added

- `pgcolumnar.sort_status(rel)` reports how much of a sorted table is still in
  sorted order (#301). `vacuum_sorted` and `cluster` order a table once; rows
  inserted afterwards append in insertion order, and until now nothing measured
  how large that unsorted tail had become. An ordering rewrite now records the
  row group its run ends at, in a new `pgcolumnar.storage.sorted_through` column,
  and the function reports sorted and appended groups and rows alongside the
  declared `sort_by` key. A boundary rather than a count, so retiring a group
  inside the run does not move the mark onto a later replacement. The mark lives
  on the storage row, so any rewrite resets it with no invalidation step. The
  online `recluster` does not set it and therefore reports more decay than a
  table has (#311).

- Declarative `sort_by` clustering key (#288). `pgcolumnar.set_options(t, sort_by
  => ARRAY['col', ...])` records a physical sort key; `pgcolumnar.vacuum_sorted(t)`
  with no columns re-applies it, like PostgreSQL `CLUSTER` remembering an index.
  The sorted rewrite works on any btree-orderable column, text included (the
  Z-order `cluster()` is numeric-only), so a segment key such as `hostname`
  tightens its zone maps and lets equality/range filters on it skip chunk groups.
  Stored as column names, so it survives `pg_dump`/restore. Not auto-maintained;
  re-run after inserts. Virtual generated columns are rejected as a sort key.

- Column-oriented table access method (`USING pgcolumnar`) with per-column
  compression, chunk-group minimum and maximum skipping, per-chunk bloom filters,
  and a vectorized aggregate path.
- Native on-disk format PGCN v1: row groups, per-column chunks, an adaptive
  per-vector encoding cascade, zone maps for skipping, and per-chunk bloom
  filters. Delete, update, index scan, index-only scan, and projections all work
  on native tables. The earlier 1.0-dev format line has been removed; the
  `v1.0-dev` git tag preserves it.
- Compression codecs `none`, `pglz`, `lz4`, and `zstd`. `lz4` and `zstd` are
  compiled in when their system libraries are present.
- `count(*)` answered from catalog metadata without scanning.
- Parallel scan.
- Read stream prefetch in the scan on PostgreSQL 17 and later
  (`pgcolumnar.enable_read_stream`).
- Full index-only scan through a columnar visibility-map fork, with lazy `VACUUM`
  setting all-visible bits and clear-on-write, on by default
  (`pgcolumnar.enable_index_only_scan`).
- Multiple projections (C-Store model): a `pgcolumnar.projection` catalog, write
  fan-out, planner projection scan, back-fill, and vacuum coordination
  (`pgcolumnar.add_projection`, `pgcolumnar.drop_projection`,
  `pgcolumnar.enable_projection_scan`).
- Sorted storage with `pgcolumnar.vacuum_sorted`.
- Arrow IPC and Parquet export (`pgcolumnar.export_arrow`,
  `pgcolumnar.export_parquet`), self-contained with no libarrow or libparquet
  dependency. Coverage: scalar types (int2/4/8, float4/8, bool, text/varchar,
  bytea, date, time, timestamp, timestamptz, uuid, numeric, json),
  one-dimensional arrays, and composite types, with nulls at every level.
- Arrow IPC and Parquet import (`pgcolumnar.import_arrow`,
  `pgcolumnar.import_parquet`). The Parquet reader parses Thrift metadata,
  decompresses uncompressed, Snappy, GZIP, ZSTD, and LZ4_RAW pages, and decodes
  PLAIN and dictionary encodings from data-page versions 1 and 2. Both readers
  reconstruct one-dimensional arrays and composite types: Arrow from its List and
  Struct buffers, Parquet from the Dremel repetition and definition levels.
- Reading external Parquet in place. `pgcolumnar.read_parquet(path)` returns a
  file's rows without importing, `pgcolumnar.parquet_schema(path)` reports its
  columns and inferred types, and the `pgcolumnar_parquet` foreign-data wrapper
  exposes a file as a foreign table. A `path` may be a single file, a directory
  of `*.parquet` files, or a glob pattern, read as one relation in sorted order.
  The foreign scan skips row groups excluded by the query's predicate (min/max
  statistics) and decodes only the referenced columns; `EXPLAIN ANALYZE` reports
  the row groups and columns read and skipped and the number of files.
- Value encodings are chosen from a strided sample rather than by applying every
  candidate to every vector. Measured on a 6,000,000-row load: 20.9 s to 15.7 s,
  with byte-identical output. `pgcolumnar.encoding_sample_rows` controls the
  sample size and `0` restores the previous exhaustive selection.
- Partition values are percent-decoded, so a directory named `region=a%3Db` reads
  as `a=b`, and `__HIVE_DEFAULT_PARTITION__` reads as NULL rather than as that
  literal string, matching what Hive and Spark write.
- Hive-style partitioning on the `pgcolumnar_parquet` foreign-data wrapper. A
  foreign table declaring `partition_columns` reads `col=value` directory names
  as column values, and a predicate on a partition column drops whole files
  before they are opened, so a pruned file costs no I/O. `EXPLAIN ANALYZE`
  reports `Files Pruned`. The columns are declared rather than inferred, and a
  file missing a declared component raises rather than yielding nulls.
- A directory path now reads `*.parquet` files at any depth below it, where it
  previously read only the files directly inside. Entries whose name begins with
  `_` or `.` are skipped, so a Spark or Hive output directory does not read its
  own `_temporary` staging tree. A directory reached through a
  symbolic link is not descended, since a link to an ancestor would make the walk
  endless; a symbolic link to a file is still followed. Nesting deeper than 32
  levels raises rather than reading part of the tree.
- External Parquet files are read on demand instead of loaded whole. The reader
  holds a file's footer for the scan and pulls one page at a time, so peak memory
  for raw file data is one page rather than one file. A file of 1GB or more could
  not be read at all before this, because the whole-file allocation exceeded
  `MaxAllocSize`; that ceiling is gone. A row group excluded by predicate
  pushdown is now never read from disk, and `pgcolumnar.parquet_schema` reads
  only the footer.
- A Parquet DECIMAL is also read when it is stored as an INT32 or INT64 holding
  the unscaled integer, which is how writers store small precisions;
  `pgcolumnar.parquet_schema` advises `numeric(p,s)` for those columns.
- Parquet read type coverage extended to uuid and numeric (from fixed and
  variable DECIMAL, precision up to 38), fixed-length binary, and millisecond,
  microsecond, and nanosecond time units.
- `pgcolumnar.fsst_min_gain_percent`, a cost margin for the FSST string encoding
  decision. FSST is kept only when it reduces the compressed chunk by at least
  this percentage, default 5. Building FSST codes for every vector is one of the
  larger costs of a text or varlena load, and a sub-margin reduction does not
  repay it.
- The on-disk format version is enforced when data is read, not only stamped when
  it is written. Both the physical metapage version and the native data format
  version are checked, on every path that decodes columnar data, so a file this
  build cannot read is refused rather than misread.
- User and administrator documentation under [docs/](docs/index.md):
  installation, user guide, administration, configuration reference, SQL
  reference, and limitations.
- Benchmark harness (`bench/run_bench.sh`) covering storage size, query latency,
  vectorization, compression, sorted projection, index-only scan, projection
  scan, export, import, nested round-trip, and cross-engine reads of the Parquet
  output with DuckDB and pyarrow.
- Project logo under [logo/](logo/README.md).

### Fixed

- Bounded importer memory. `pgcolumnar.import_arrow` and `pgcolumnar.import_parquet`
  built each row's arrays and composites in one memory context and did not free
  them, using memory proportional to the row count. They now reset a per-row
  scratch context (and, for Parquet, a per-row-group context for decoded leaf
  streams), so peak memory stays bounded on large files.
- Hardened the Parquet reader against crafted files. File-declared page sizes,
  DECIMAL scale, and per-row-group column-chunk counts are range-checked, so a
  malformed footer yields a clean decode error rather than a stack overflow, an
  out-of-bounds read, or a wrong value. Float and double row-group skipping
  accounts for NaN and for inverted min/max intervals, and narrowing a wide
  Parquet value into a smaller PostgreSQL type raises instead of wrapping.
- Concurrent inserts of the same unique-index key now serialize correctly with a
  transaction-scoped advisory lock (`pgcolumnar.enable_unique_insert_lock`).
- Lost delete marks under concurrent same-chunk-group deletes.
- Relation-reference leak in parallel `CREATE INDEX`.

### Removed

- The decompressed-chunk cache, and the `pgcolumnar.enable_column_cache` and
  `pgcolumnar.column_cache_size` settings with it. Its only entry point had lost
  its caller when the earlier on-disk format was removed, so the cache had done
  nothing since. Two settings and four passages of documentation described a
  feature that did not run. A `postgresql.conf` that sets either parameter must
  drop the line. The implementation is in the git history if the performance case
  is made again against the current reader.

### Changed

- FSST string encoding is now kept only when it reduces the compressed chunk by
  at least 5 percent, rather than on any reduction at all. On shapes where FSST
  barely wins, such as high-entropy text, this costs about 2 percent stored size
  and reduces load time by roughly a third. Where FSST wins by more than the
  margin the encoding and the stored bytes are unchanged. Set
  `pgcolumnar.fsst_min_gain_percent` to 0 for the previous behaviour.
- Renamed the per-table option functions to `pgcolumnar.set_options` and
  `pgcolumnar.reset_options`. The previous names were carried over from an
  earlier compatibility goal that no longer applies. No aliases are kept, since
  the project is pre-release.

### Compatibility

- Builds from one source tree on PostgreSQL 15 through 19. Every test suite runs
  on all five majors.
- The Arrow and Parquet import and export functions require superuser and run on
  little-endian hosts.
- Cross-major `pg_upgrade` is covered by an opt-in gate
  (`PGC_RUN_UPGRADE=1 test/run_all_versions.sh`), in both copy and link transfer
  modes.
- All recorded test results come from x86_64. The suites have not been run on
  aarch64 or on a big-endian platform.
