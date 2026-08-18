# pgColumnar 1.0-alpha2 release notes

Release date: 2026-08-18
Previous release: 1.0-alpha (2026-08-04)

pgColumnar is a columnar table access method for PostgreSQL. This is the second
alpha. It adds read-only Apache Iceberg support, reads and writes over
S3-compatible object storage, a maintenance daemon, and a broad round of
statistics, planner, performance, and security work. The on-disk native format
(PGCN v1) is unchanged; existing tables are read and written as before.

This release requires one upgrade command. See "Upgrading" at the end.

## Highlights

- **Apache Iceberg, read-only.** Read an Iceberg table at its current snapshot
  three ways: by metadata path, through a REST catalog, or as a foreign table.
  Row-level deletes of all three kinds (position, equality, and format-version-3
  deletion vectors) are applied under their sequence rules, columns resolve by
  schema field id, and the foreign-data wrapper prunes whole data files from a
  query predicate.
- **Object storage.** The Parquet and Iceberg readers, the Parquet export
  functions, and the foreign-data wrapper read from and write to `s3://`,
  `http://`, and `https://` URLs. Remote access goes through a separate module,
  is confined to an operator-set endpoint allow-list, and refuses link-local
  addresses.
- **Maintenance and operations.** A new `pgcolumnar.autovacuum` daemon performs
  online upkeep, `pgcolumnar.maintenance_due` reports what a table needs, and a
  stripe flush can run across background workers.
- **Security and hardening.** Six memory-safety and denial-of-service fixes on
  the read and object-store paths, several from an adversarial audit, each with a
  regression test and a proof that removing the fix reintroduces the failure.

## Apache Iceberg support (read-only)

- **Filesystem tables.** `pgcolumnar.iceberg_scan(metadata_path)` reads a table
  given a column definition list. It resolves each output column to a schema
  field id, so a data file written before a column rename still reads. It applies
  position deletes, equality deletes, and format-version-3 deletion vectors
  (Puffin roaring bitmaps), each under its own sequence and scope rule, and
  verifies deletion-vector checksums, offsets, and cardinality. A data file with
  no field ids is bound by the table's `schema.name-mapping.default`; one with
  neither field ids nor a name mapping is refused rather than guessed. Only
  Parquet data files are read. Recorded paths are rebased onto the table's actual
  location and refused if they resolve outside it. Introspection functions
  `iceberg_current_snapshot`, `iceberg_data_files`, `read_avro_manifest`, and
  `read_manifest_list` are included.
- **REST catalog.** `pgcolumnar.iceberg_rest_scan(catalog_uri, namespace,
  table_name)` resolves a table through a catalog and reads it with the same
  projection and delete rules. The first argument may instead name a foreign
  server of the `pgcolumnar_iceberg_catalog` wrapper, which holds the catalog URI
  in server options and the bearer token or OAuth2 client credentials in a user
  mapping, so one role's secret is private from another and never appears in a
  function argument or the statement log. When the catalog vends short-lived
  storage credentials in its load-table reply, the reader uses them for the data
  files. `iceberg_rest_namespaces` and `iceberg_rest_tables` list a catalog.
- **Foreign-data wrapper.** A foreign table over an Iceberg table
  (`pgcolumnar_iceberg`, option `metadata_path`) receives the query predicate and
  prunes whole data files before opening them: by partition value for identity,
  `bucket[N]`, `truncate[W]`, and the temporal transforms, and by stored
  minimum and maximum for integer and boolean columns. Pruning only removes files
  that cannot match, so results are unchanged, and `EXPLAIN (ANALYZE)` reports
  `Files Pruned`.

## Object storage

- The Parquet read and export functions, the Parquet foreign-data wrapper, and
  the Iceberg reader accept `s3://`, `http://`, and `https://` URLs wherever they
  accept a local path. `s3://` requests are signed with AWS Signature Version 4;
  `https://` verifies the server certificate when the object-store module is
  built with OpenSSL.
- Remote access lives in a separate module, `pgcolumnar_objstore`, loaded on
  first use, so no second TLS stack enters the main server process by default.
- `pgcolumnar.objstore_allowed_endpoints` lists the endpoints remote access may
  reach. It is empty by default, which refuses every remote endpoint, and it is
  superuser-only. Link-local and instance-metadata addresses are refused after
  name resolution.
- Object-store credentials come from the server process environment, never a
  function argument or a log line.

## Maintenance and operations

- `pgcolumnar.autovacuum` is a maintenance daemon for the online upkeep that core
  autovacuum does not perform on a columnar table.
- `pgcolumnar.maintenance_due(rel, compact_due_fraction, recluster_due_fraction)`
  reports whether a table is due for compaction or reclustering.
- `pgcolumnar.parallel_flush` dispatches a stripe flush across background workers.
- `pgcolumnar.fsst_verdict_reuse` caches a column's FSST keep-or-drop verdict, so
  a repeated write does not re-run the substring search.

## Statistics and the planner

- `pgcolumnar.analyze()` now collects `most_common_vals` and `most_common_freqs`,
  places `histogram_bounds` at PostgreSQL's own positions, honours the per-column
  statistics target, and counts `null_frac` over live rows.
- `EXPLAIN (ANALYZE)` reports `Columnar Usable Skip Predicates` beside the skip
  counters.
- The index-fetch cost penalty sizes row groups by a table's effective
  `stripe_row_limit`, and the grouped vector aggregate shares the scan node's
  input-cost estimate, so the planner prices a columnar scan more accurately.
- The Iceberg foreign-data wrapper estimates a scan's row count from the
  manifests rather than a constant, so join planning above a large Iceberg table
  is sound.

## Performance

- A parameterized predicate (`col >= $1` from a prepared statement or PL/pgSQL)
  now drives chunk-group skipping. On a generic plan such a scan previously read
  every chunk group.
- Group and per-vector skipping read only the columns a query's predicates
  reference, rather than every column's zone map. On a wide table a
  one-predicate scan reads far fewer zone-map rows.
- Reads of the `delete_vector` catalog use its index rather than a sequential
  scan, so a scan of a table with deletes is no longer proportional to the
  catalog size.
- The Iceberg foreign-data wrapper decodes only the columns a query references.
- The ungrouped batch fold gathers only the referenced columns per row, and a
  columnar scan whose filter cannot be pushed down skips decoding the filtered
  columns.

## Security

- The native varlena decoder bounds a value's stored length against its buffer, so
  a corrupt chunk or catalog row is refused with a clean error rather than an
  out-of-bounds read or a detoast through a bad pointer.
- The local file read path no longer has a stat-before-open race, and the Iceberg,
  Avro, Parquet, Arrow, and parallel-copy readers refuse a FIFO or other
  non-regular file with a non-blocking open rather than a cancel-resistant hang.
- The Iceberg reader refuses several classes of malformed or hostile table
  metadata, including a null manifest path that had crashed the backend, a null
  or negative position-delete ordinal, a null manifest-list sequence number, and
  a dangling current-schema-id.
- The Thrift and Avro field-skip loops are interruptible, so a crafted Parquet
  footer or Avro manifest can no longer spin the backend uncancellably.
- The object-store client refuses a URL path or host carrying CR or LF, closing an
  HTTP request-line injection.
- The native dictionary decode path no longer reads uninitialized memory, and the
  Parquet dictionary decode path no longer reads out of bounds on a crafted file.

## Correctness fixes

- Concurrent `UPDATE` or `DELETE` of the same columnar row serializes on the row
  identity, so the losing writer gets a retryable serialization failure rather
  than a lost update.
- A predicate on a column declared over a domain, and a `bigint` column compared
  against an unadorned integer literal, now prune chunk groups.
- `CREATE TABLE ... USING pgcolumnar AS SELECT` no longer fails when the source is
  another access method.
- `pgcolumnar.sort_status` works for a non-superuser who owns the table.
- Failed `export_parquet` and `export_arrow` no longer leave a partial file.

## Internal changes

- The extension's exported C symbols are namespaced under `pgcolumnar`, and the
  custom scan node is `PgColumnarScan`. The native encoding-descriptor wire layout
  and the delete-vector visibility logic are each single-sourced, with the on-disk
  format unchanged and verified byte-identical.
- `default_version` is `1.0-alpha2`. Upgrade scripts from both previously shipped
  versions (`1.0-dev`, which the v1.0-alpha tag installed, and `1.0-alpha`) ship
  with the extension, so a single `ALTER EXTENSION pgcolumnar UPDATE` reaches
  `1.0-alpha2` from either.

## Upgrading

Install this build, then run the following in every database that has the
extension:

```sql
ALTER EXTENSION pgcolumnar UPDATE;
```

This is required. The C-symbol rename moves the symbol names each installed
function recorded when it was created; without the catalog update those records
point at symbols the new library does not export, and reading an existing
columnar table fails with `could not find function "columnar_handler"`. No data
is converted and no SQL you write changes. The upgrade replaces catalog entries
only.

See `docs/installation.md` for the commands, including how to list the databases
that need the update.

## Scope and limitations

- Iceberg support is read-only, at a table's current snapshot, and reads Parquet
  data files only.
- Object-storage reads take exact object keys.
- HTTPS and S3 over TLS require the `pgcolumnar_objstore` module built with
  OpenSSL.
- This is an alpha. Interfaces may change before 1.0.

The complete, itemized list of changes is in `CHANGELOG.md`.
