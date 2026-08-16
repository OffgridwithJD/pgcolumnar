# Changelog

All notable changes to pgColumnar are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). pgColumnar is
pre-release; the version marker is `1.0-alpha`, recorded in `VERSION`. New tables
are written in the native on-disk format, PGCN v1. For the forward-looking plan see
[design/ROADMAP.md](design/ROADMAP.md); for full history see the git log.

The extension's `default_version` is `1.0-alpha`, and an upgrade script ships with
it. Older notes in this file describe `default_version` as pinned at `1.0-dev`,
which was true until that script existed.

## [Unreleased]

### Security

- Fixed an HTTP request-line injection in the object-store client. A URL path or
  host containing CR or LF was written verbatim into the request line, so a
  crafted path could split the request and smuggle a second line to an
  allow-listed endpoint. The request path and host are now rejected if they carry
  CR or LF, as the caller-supplied header lines already were. Regression test:
  objstore_crlf.

- Fixed an uninitialized-memory read in the native DICT decode path. A chunk
  whose descriptor declared a `value_raw_length` larger than its codes decode to
  left the tail of the raw buffer uninitialized, and a varlena column then read a
  length prefix out of that garbage (silent wrong results, or an out-of-bounds
  read). `decode_dict` now requires the decoded length to equal the declared raw
  length, mirroring the FSST path. Regression test: native_dict_underfill.
- Fixed an out-of-bounds read in the Parquet dictionary decode path. A file whose
  RLE_DICTIONARY data page carried an index with the high bit set (reachable at
  bit_width 32) passed a signed bounds check that sign-extended it to a negative
  int, and the dictionary was then read far out of bounds, crashing the backend
  from a single crafted file. The bounds check is now unsigned and the index is
  rejected. The index decode runs only when the page has coded values, so an
  all-null column with an empty dictionary page still reads. Regression tests:
  native_parquet_dict_oob and native_parquet_streaming.

### Added

- Read-only Apache Iceberg support, filesystem-backed, at a table's current
  snapshot (#388). `pgcolumnar.iceberg_scan(metadata_path)` reads a table given
  a column definition list, resolving each output column to a schema field id so
  a data file written before a column rename still reads. It applies **row-level
  deletes of all three kinds**, each under its own sequence rule: a position delete
  drops the row ordinals it names from a data file whose data sequence number is
  at or below the delete's (same commit or earlier), and an equality delete
  drops every data row matching a delete row on the delete's `equality_ids`
  columns when the data file's sequence number is strictly below the delete's
  (never same-commit data). Format-version 3 **deletion vectors** (Puffin
  files holding a portable roaring bitmap of row ordinals) apply under the
  position-delete rule, scoped to their referenced data file, and supersede
  position delete files for that file per the specification; the blob checksum,
  the manifest/footer offsets, and the recorded cardinality are verified, and
  at most one vector may reference a data file. A null delete value matches only a null data value,
  and columns beyond `equality_ids` do not take part in the match. A
  partition-scoped equality delete is applied within its partition: its stored
  partition values are matched against each data file's, so it removes rows only
  from data files in the same partition. Equality
  deletes with no supported handling are refused rather than ignored, so a table
  using them errors instead of returning rows it should have removed:
  delete columns of
  types outside `int`/`long`/`string`/`boolean`/`date`, delete columns
  dropped from the current schema, and a partition value the reader cannot
  compare exactly. Supporting introspection functions:
  `iceberg_current_snapshot` and
  `iceberg_data_files` (which refuses any delete), and the Avro building blocks
  `read_avro_manifest` and `read_manifest_list`. Only Parquet data files are
  read; recorded paths are rebased onto the table's actual location and refused
  if they resolve outside it. The table may live in object storage: a metadata
  path of `s3://`, `http://`, or `https://` reads the metadata, manifests, data
  files, and delete files from the endpoint through the object-store module,
  gated by the same `objstore_allowed_endpoints` allow-list and ambient
  credentials as the Parquet reader. A data file written outside Iceberg, which carries
  no field ids, is read through the table's `schema.name-mapping.default`
  property, which binds its columns by name; a file with no field ids and no
  such property is refused rather than guessed. `read_parquet` also gained a
  `field_ids` form that projects columns by Parquet field id. See
  [Iceberg](docs/sql-reference.md#pgcolumnariceberg_scanmetadata_path-text-returns-setof-record).

- Read-only Apache Iceberg **REST catalog** support (#388). A table is named by a
  catalog (catalog URI, namespace, table) rather than a metadata path.
  `pgcolumnar.iceberg_rest_scan(catalog_uri, namespace, table_name)` reads it at
  its current snapshot, taking a column definition list exactly like
  `iceberg_scan`: the catalog resolves the table to its metadata location, which
  is then read through the same path, so every projection and delete rule
  applies unchanged. `pgcolumnar.iceberg_rest_table_location` returns that
  resolved metadata location on its own, and
  `pgcolumnar.iceberg_rest_namespaces` and `pgcolumnar.iceberg_rest_tables` list
  a catalog. Requests go over HTTP or HTTPS. The catalog endpoint is subject to
  the same `objstore_allowed_endpoints` allow-list and link-local refusal as
  every other remote access, and is carried by the object-store module, so no
  second TLS stack enters the server process. A bearer token, when the catalog
  requires one, is read from the `PGCOLUMNAR_ICEBERG_REST_TOKEN` server
  environment variable, never a function argument, so it does not appear in the
  statement log. The first argument may instead name a foreign server of the new
  validator-only `pgcolumnar_iceberg_catalog` wrapper (#656). The server holds
  `catalog_uri`, and the current role's user mapping holds the bearer `token` in
  `pg_user_mapping`, which is not world-readable, so one role's token is private
  from another. A role with neither a mapping token nor superuser rights is
  refused, and the validator keeps secrets off the world-readable server options.
  A user mapping may instead carry OAuth2 client credentials (`oauth_client_id`,
  `oauth_client_secret`, and optionally `oauth_scope` and `oauth_token_uri`)
  (#656). The catalog then mints a bearer by the client-credentials grant; the
  secret travels in the request body, never a URL or a log line, and a half
  credential is refused before any request. When the catalog vends short-lived
  storage credentials in its
  `loadTable` reply (the flat `config` keys or the `storage-credentials` array,
  longest prefix selected), `iceberg_rest_scan` reads the table's files with
  those credentials rather than the server environment (#656). Vended
  credentials do not bypass the endpoint allow-list. A table that vends none
  reads with the ambient environment as before. See
  [Iceberg REST catalog](docs/sql-reference.md#pgcolumnariceberg_rest_scancatalog_uri-text-namespace-text-table_name-text-returns-setof-record).

- An Apache Iceberg **foreign-data wrapper**, `pgcolumnar_iceberg` (#388). A
  foreign table over an Iceberg table gets the query's predicate, which
  `iceberg_scan` cannot, and prunes: a predicate on an identity-partitioned
  column removes whole data files before they are opened, reading each file's
  partition value from the manifest. A predicate on an integer or boolean column
  removes whole files whose stored minimum and maximum exclude it, so an
  unpartitioned column prunes too. Pruning is only an optimization, so a
  predicate the wrapper cannot decide never changes the rows returned, and every
  projection and delete rule matches `iceberg_scan`. The table option is
  `metadata_path`; `EXPLAIN (ANALYZE)` reports `Files Pruned`. An equality
  predicate on a `bucket[N]`-partitioned column prunes files whose stored bucket
  differs from the constant's, computed with the Iceberg murmur3 hash. A
  predicate on a `truncate[W]`-partitioned integer column prunes files whose
  truncated value range excludes it, and a predicate on a `day()`-partitioned
  date column prunes by day. The `year()`, `month()`, `day()`, and `hour()`
  transforms prune too, on a `timestamp` or `timestamp with time zone` column
  (and `year()`/`month()` on a `date`): each bucket spans a range, so a file
  whose bucket equals the constant's is read and its rows are rechecked, never
  dropped at the boundary, and a timestamptz value is compared as its UTC
  instant. Partition pruning covers identity, `bucket[N]`, `truncate[W]`
  (integer), and the temporal transforms on date, timestamp, and timestamptz;
  metrics pruning covers integer and boolean columns; other column types read in
  full. See
  [Iceberg FDW](docs/sql-reference.md#the-pgcolumnar_iceberg-foreign-data-wrapper).

- The Parquet read and export functions and the foreign-data wrapper read from
  and write to object storage (#393, #394). A path may be an `s3://`,
  `http://`, or `https://` URL wherever it may be a local path. `s3://` requests
  are signed with AWS Signature Version 4; `https://` verifies the server
  certificate and is available when the object-store module is built with
  OpenSSL. Support lives in a separate module, `pgcolumnar_objstore`, loaded on
  the first remote use. Reads take exact object keys only. `export_parquet` and
  `export_arrow` write to `s3://`, as one request for a small object or a
  multipart upload for a large one, and the object becomes visible only when the
  upload completes. See [Object storage](docs/sql-reference.md#object-storage).

- Credentials for object storage come from the server process environment
  (`AWS_ENDPOINT_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_SESSION_TOKEN`, `AWS_REGION` or `AWS_DEFAULT_REGION`) for the function
  API, and from the catalog
  for the foreign-data wrapper: `endpoint` and `region` on the server, and
  `access_key_id`, `secret_access_key`, `session_token`, and
  `credentials_required` only on a user mapping, so a secret is never in a
  world-readable option. Ambient environment credentials are used only for a
  superuser or a mapping a superuser marked `credentials_required 'false'`.

- `pgcolumnar.objstore_allowed_endpoints` lists the endpoints the object-store
  module may connect to (#393). It is empty by default, which refuses every
  remote endpoint, so a role that can read or write server files cannot reach an
  arbitrary host through the extension. Link-local addresses, including the cloud
  instance-metadata address, are refused whether or not they are listed. The
  setting is superuser-only.

- `pgcolumnar.parquet_schema` reports a `field_id` column (#388), the Parquet
  schema field id each leaf column carries, which formats such as Apache Iceberg
  use to select columns by id. It is NULL when the writer emitted none.

- `pgcolumnar.maintenance_due(rel, compact_due_fraction, recluster_due_fraction)`
  reports whether an online maintenance verb is worth running on a table, from its
  statistics alone (#415). It takes no lock and rewrites nothing. It returns the
  deleted and appended fractions, whether `compact_rewrite` or `recluster` has
  crossed its threshold, and a `recommendation`. This is the policy the
  `pgcolumnar.autovacuum` daemon consults, and a monitoring role can call it
  directly. It is `SECURITY DEFINER` and checks that the caller may `SELECT` the
  table, so the owner can run it without superuser rights.

- `pgcolumnar.autovacuum`, a maintenance daemon for the online upkeep that core
  autovacuum cannot reach (#415). pgColumnar's `compact_rewrite` and `recluster`
  live in extension functions, not table access method callbacks, so core
  autovacuum never runs them. A table's dead rows and clustering decay then
  accumulate until someone runs the verbs by hand. This daemon runs them for you.

  It is off by default. When on, a launcher wakes every
  `pgcolumnar.autovacuum_naptime` seconds (default 60) and starts one worker per
  database. Each worker asks `pgcolumnar.maintenance_due()` which tables crossed a
  threshold, then runs the recommended verb over SPI in its own transaction.

  Two properties make it safe unattended. It calls only the
  `ShareUpdateExclusiveLock` verbs, never `vacuum`, `vacuum_sorted`, or `cluster`,
  so it cannot block a reader or a writer. And it yields the way autovacuum does:
  the worker sets `PROC_IS_AUTOVACUUM`, so the lock manager cancels its
  maintenance the moment a backend queues for a stronger lock. New settings:
  `pgcolumnar.autovacuum`, `autovacuum_naptime`, `autovacuum_compact_threshold`
  (0.2), and `autovacuum_recluster_threshold` (0.05). See the administration
  guide for the operator's view.

- `pgcolumnar.parallel_flush` dispatches a stripe flush across background workers
  (#445). Default off. When on, a flush of two or more columns fans the per-column
  encode and compress work out to a worker pool. Any column a worker does not
  finish is completed serially in the backend, so the stored bytes match the
  serial path either way. It helps one large flush of many numeric columns by up
  to 14 percent. A wide text-heavy flush regresses, and so do frequent small
  flushes, because it copies the buffered bytes through shared memory. So it is a
  per-session opt-in for a wide numeric bulk load, not a default.

- `pgcolumnar.fsst_verdict_reuse` caches a column's FSST keep/drop verdict for a
  bounded number of row groups (#472). Default 16; `0` asks every time, which is
  the behaviour before this setting existed.

  Deciding whether an FSST symbol table pays for itself costs a whole-corpus
  encode plus a compression pass, and the answer cannot be sampled: on a training
  prefix FSST can look 24 percent worse while over the whole column it is 23
  percent better. So it was asked once per column per row group, and for a column
  whose data does not change character that re-derived the same answer for the
  whole load. Measured at 2,000,000 rows in 20 row groups: 2482 ms of a 5319 ms
  `md5` load and 843 ms of a 2081 ms email-shaped load, with the verdict identical
  all 20 times.

  A text load is about 2.5 times faster as a result, measured in-suite at 1623 ms
  against 648 ms. Stored bytes are unchanged for a column whose verdict is stable,
  which is asserted rather than assumed: the suite compares the encoding
  descriptor, block codec and page length of every chunk. A column that changes
  character mid-load is noticed within the bound.

  Reuse is per statement. Nothing is persisted and no on-disk structure changes.

- `EXPLAIN (ANALYZE)` now reports `Columnar Usable Skip Predicates` beside
  `Columnar Pushed-Down Filters` (#479). The existing line counts the filters the
  scan was handed and is unchanged; the new one counts how many of those the
  reader can actually skip chunk groups with. A filter whose types have no
  ordering function for the pair is dropped by the reader and excludes nothing,
  and until now the plan reported it as pushed down with no way to see the
  difference. That is how #477 went unseen for a year, and how
  `test/zonemap_cost.sh` validated a cost discount against a fixture that pruned
  zero groups.

  All three nodes that print the original line report the new one: the scalar
  custom scan and both vectorized aggregate nodes. The new line needs `ANALYZE`,
  since it describes what the scan built at execution.

- `pgcolumnar.analyze()` now collects `most_common_vals` and `most_common_freqs`,
  and excludes those values from `histogram_bounds` (#414). Frequencies are exact
  counts over the total row count rather than sample estimates. PostgreSQL 18 and
  later, which is where `pg_restore_attribute_stats` exists; earlier majors raise
  and should use `ANALYZE`.

  The selection rule is PostgreSQL's own. `analyze_mcv_list()` keeps the entire
  list when the whole table was read instead of applying its significance filter,
  because that filter exists to judge sample frequencies. Reading the column makes
  the values eligible on count alone, matching what core would store given the
  same information.

  Excluding most-common values from the histogram is required rather than
  cosmetic: keeping them counts those values twice in selectivity, once from the
  most-common list and again inside the bucket that holds them.

- `test/analyze_differential.sh`, which compares the statistics `pgcolumnar.analyze()`
  writes against the shape PostgreSQL's own `ANALYZE` produces across five column
  types. `pg_restore_attribute_stats` takes `VARIADIC "any"` and responds to a
  mistyped argument with a warning rather than an error, so a statistic can be
  dropped while the call reports success. Values cannot be the comparison, since
  exact and sampled statistics differ by design, so the suite compares the
  operator, collation and presence of each statistic kind, and verifies every
  stored value against an independent count.

### Fixed

- The Iceberg reader no longer crashes on a malformed manifest (#644). A crafted
  manifest that recorded no data-file path made `iceberg_scan` and
  `iceberg_data_files` dereference a null pointer. A manifest whose Avro record
  schema gave a `fields` element as a JSON array made the schema decoder read past
  an object container. Both now raise a clean error. These reproduce only from
  hand-crafted manifests, since no writer emits them, and they are covered by the
  new `iceberg_malformed` suite.

- A failed `export_parquet` or `export_arrow` no longer leaves a partial file at
  the destination (#394). An export writes to a temporary name and renames to the
  final name only when it is complete, so a reader never sees a half-written file.
  Every write is checked, so a full disk during an export is reported rather than
  detected only at close.

- `EXPLAIN (ANALYZE)` on a vectorized aggregate reports whether the batch fold
  actually ran, not whether it was predicted eligible (#602). A query that fell
  back to the row path, such as an aggregate over a column added after some row
  groups, no longer reads `Columnar Batch Fold: yes`. Plain `EXPLAIN`, which has
  no execution to report, still shows the prediction.

- `pgcolumnar.sort_status` works for a non-superuser who owns the table (#608).
  The function reads pgColumnar's internal catalogs, which carry no `GRANT`. As an
  invoker-rights function it therefore failed for any caller who was not a
  superuser. It is now `SECURITY DEFINER` and checks that the caller may `SELECT`
  the table. The owner can read the sort status of their own table, and no caller
  gains access to a table they could not already read.

- `pgcolumnar.analyze()` counts `null_frac` over live rows (#485). It came from
  the zone maps, which record what was written, so a deleted row kept counting
  toward the denominator until the table was rewritten. `VACUUM` did not correct
  it. On 1,000 rows holding 100 nulls, deleting the 301 rows of one value left
  `null_frac` at 0.100000 against a true 0.143062.

  The size of the error is not the whole of it. `null_frac` came from the zone
  maps while the most-common frequencies came from a live count, so one
  `pg_stats` row carried two statistics normalised against different
  populations: a `null_frac` implying 1,200 rows beside a frequency implying
  900, with 900 actually present. `null_frac + sum(most_common_freqs) + rest =
  1` stopped holding, and `eqsel` subtracts both when pricing everything else.

  The null count now comes from the read the function already performs, so this
  costs no extra pass. It does give up the "null_frac is a metadata read"
  property claimed for #414 slice 1, which cost nothing in practice because the
  function always goes on to read the column for `n_distinct`. A metadata-only
  fast path would need a live-row count, which is that same read. Whether
  `pgcolumnar.zone_map`'s counts should account for the delete vector, which
  would also affect pruning, is a wider question and is not addressed.

- A column declared over a domain now prunes chunk groups (#483). The scan key
  was built and then dropped: a domain column carries the domain's type in
  `pg_attribute` while the constant beside it carries the base type, so the
  comparison looked cross-type, and an operator family has no comparison
  function registered for a domain. Measured on identical values in one table
  over 20 row groups, `int` and `bigint` each removed 19 groups and a domain
  over either removed none, while all three reported the filter as pushed down.

  Answers were never wrong, because the executor re-applies the qual. The cost
  was reading the whole table on ordinary SQL. Both sides of the comparison are
  now resolved to their base types, so a domain compared against a value of a
  different domain over the same base type is also recognised. Ordering and
  hashing are unchanged: the comparison and hash functions were already taken
  from the column type's resolved entry, which is what the writer used to build
  the zone maps and bloom filters.

- A `bigint` column compared against an unadorned integer literal now prunes
  chunk groups (#477). The scan key was dropped because the column type's default
  comparison function cannot take an `int4` argument, so predicates of the form
  `bigint_column > 16000` read every chunk group while `bigint_column >
  16000::bigint` pruned normally. The comparison function is now resolved for
  both types from the column's btree operator family, which supplies exactly this
  for the built-in numeric types. Where a family provides no such function the
  key is still skipped, as before.

  `EXPLAIN` did not show the difference. `Columnar Pushed-Down Filters` counts
  scan keys given to the reader rather than predicates able to exclude a group,
  so it reported the filter as pushed down while nothing was skipped.

  The bloom filter probe remains disabled for cross-type equality. The filter
  stores hashes of column-type values, so hashing a differently typed constant
  would probe a slot that was never written and could skip a group holding
  matching rows.

- `pgcolumnar.analyze()` now honours the per-column statistics target set by
  `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS` (#414). It read the global
  `default_statistics_target` for every column, so a column given its own target
  was sized by the global setting instead. A target of zero means the column is
  not to be analysed at all, and is now respected rather than overridden.

  Requesting only zero-target columns no longer raises. The function reported
  that it had collected statistics for no columns, with a hint about missing row
  groups, which pointed at storage for what was a deliberate setting.

- Renamed the custom scan node from `ColumnarScan` to `PgColumnarScan`, and the
  custom path from `ColumnarAgg` to `PgColumnarAgg` (#428). `ColumnarScan` is
  also registered by **Citus columnar** and by **TimescaleDB 2.29**.
  PostgreSQL's registry is one hash table keyed on that name, so two extensions
  cannot both hold it. Neither failure needed a pgColumnar table; our presence
  in `shared_preload_libraries` was enough.

  With **Citus columnar** the server refused to start at all, in either load
  order:

      FATAL:  extensible node type "ColumnarScan" already exists

  With **TimescaleDB** there was no startup error and serial queries returned
  correct results. TimescaleDB checks the registry first and silently skips
  registering when the name is taken, so a parallel worker then resolved
  TimescaleDB's node through pgColumnar's callbacks, and any parallel query over
  a columnstore hypertable failed with
  `could not read blocks 0..0 in file ...`. That is the more dangerous of the
  two, because nothing announces it.

  **This changes `EXPLAIN` output.** Plans that read `Custom Scan (ColumnarScan)`
  now read `Custom Scan (PgColumnarScan)`. Anything parsing plan text for the old
  name must be updated. The `Columnar ...` property lines, such as
  `Columnar Projected Columns`, are a different namespace and are unchanged.
  `ColumnarAgg` never appeared in `EXPLAIN`: it names a `CustomPathMethods`, and
  the planned node carries the scan's methods (`columnar_vector.c:717`), so that
  half of the rename is hygiene rather than a visible change.

### Changed

- `pgcolumnar.recluster` no longer rewrites a table that is already clustered by
  the requested key (#415). The function records the clustering key and kind it
  establishes. A later call with the same key returns 0 and touches nothing when
  the existing sorted run still covers every row group. Before this, it re-sorted
  on every call, so a scheduled recluster rewrote the whole table each time, which
  is why the maintenance daemon could not have run it safely. `pgcolumnar.sort_status`
  now reports this recorded key as `sort_key`, and falls back to the declared
  `sort_by` when there is no recorded key.

- A columnar scan whose filter cannot be pushed down now skips decoding the
  projected columns of a 1024-row vector that holds no matching row (#452). The
  scan decodes the filter columns first, rules out the vectors with no match, and
  decodes the rest only for the vectors that survive. A `SELECT *` under a
  leading-wildcard `LIKE` that matches few rows then approaches the cost of
  `count(*)`. It no longer decodes every column of every row scanned. A count over
  one column gains nothing, because it has no projected column to skip.

- The writer detoasts each value once per row (#445). It was detoasted once for
  the encoder, once for the bloom filter, and once for each of the two zone-map
  comparisons. For a toasted column each of those was a separate decompression. A
  load of a large compressed text column is about 11 percent faster, and the
  stored bytes are unchanged.

- `pgcolumnar.analyze()` places `histogram_bounds` at PostgreSQL's own positions
  (#414). The bounds were evenly spaced quantiles; core places bound i at
  `values[floor(i * (nvals - 1) / (num_hist - 1))]` among the rows left after
  the most-common values are removed, and `percentile_disc` resolves a fraction
  to a different index whenever the two disagree.

  **This changes the emitted array.** The length and both endpoints are the
  same, so the exactness of the minimum and maximum is unaffected, but an
  interior bound can move by one position. Both forms are valid equi-depth
  histograms; core's is the one the planner's selectivity estimators were tuned
  against. Anyone comparing `pg_stats` across this upgrade should expect
  interior bounds to differ and that is intended, not a regression.

- The unsupported-rewrite error names `REPACK` on PostgreSQL 19 (#399). `REPACK`
  replaces `CLUSTER` and `VACUUM FULL` in 19 and dispatches through the same
  copy-for-cluster path, which pgColumnar does not implement, so a 19 user who
  typed `REPACK` was told that `CLUSTER / VACUUM FULL` was unsupported: two
  commands they had not typed, and on 19 the superseded ones. The message now
  names the command and hints at `pgcolumnar.vacuum()`, which does the work. This
  covers `REPACK (CONCURRENTLY)` too: given a table with an identity index, where
  PostgreSQL will run it, heap succeeds and a columnar table is refused.
- `CREATE TABLE ... USING pgcolumnar AS SELECT` no longer fails when the source
  plan is parallel (#387). The storage-row creation path re-checked for an
  existing row against `GetLatestSnapshot()`, which raises "cannot update
  SecondarySnapshot during a parallel operation" inside parallel mode, and CTAS
  runs its whole executor in parallel mode whenever the source plan is parallel.
  That is the default for any source large enough to be worth loading, so bulk
  creating a columnar table from existing data failed on every supported major.
  The lock and the fresh snapshot are now skipped when the relation was created
  by the current transaction, because no other session can see it and the
  first-writer race they defend against cannot happen. A committed table
  first-written by two sessions at once is unaffected and still serializes.

- The extension's exported C symbols are namespaced under `pgcolumnar` (#382).
  Two extensions that both call themselves `columnar` could define the same
  symbol. `columnar_handler` and `columnar_relation_storageid` collided with
  Citus columnar. Four settings variables such as `columnar_stripe_row_limit`
  also shared names with the same settings there. That case binds one library's
  setting to the other's storage.
- `default_version` moves from `1.0-dev` to `1.0-alpha`, so
  `SELECT extversion FROM pg_extension` now agrees with `VERSION`.
- `CREATE INDEX` decodes only the columns the index needs (#413). The index
  build received an `IndexInfo` carrying the key columns and the expression and
  predicate trees, and discarded it, so a one-column index on a wide table read
  every column. Both readers are now projected: the one a serial build opens for
  itself, and the shared scan a parallel build arrives with, which comes through
  the table-access-method scan interface and has nowhere to carry a projection.
  The parallel branch is not a corner case. With every parallel setting left at
  its default, a 1.5 million row table of incompressible text, 459 MB on disk,
  is built in parallel, so that is the branch a table of consequential size
  takes. On 300,000 rows of 20 columns on PostgreSQL 18, a one-column index
  drops from 568 ms to 73 ms with workers allowed, against 563 ms for the same
  index on a heap table.

- Logical replication into a columnar table says what is wrong and how to
  proceed (#435). Applying an UPDATE or a DELETE takes a row lock, which
  columnar storage does not support, so the apply worker raised "columnar: row
  locking is not supported yet". That names something the user was not doing.
  PostgreSQL takes that lock for every applied UPDATE and DELETE and has no
  lock-free path, and it does not advance the replication origin when a
  transaction fails, so the subscription retries the same transaction for as
  long as it runs and no later change is applied. The error now names logical
  replication, says the retry is unbounded, and points at
  `CREATE PUBLICATION ... WITH (publish = 'insert')`, which does work. See
  [Limitations](docs/limitations.md).

- The grouped vectorized aggregate's parallel arm is no longer declined on a
  truncating time key (#369). `estimate_num_groups` cannot see through a
  function, so for `date_trunc('minute', ts)` it falls back to the timestamp
  column's distinct count, which measured 19,996,000 against 720 actual. That
  number is charged twice on the parallel arm, once by the Gather for tuples it
  believes it must ship and again by the Finalize, and not at all on the serial
  node, which is priced per input row. The serial node therefore won by
  construction on the shapes where the parallel arm is fastest. The estimate is
  now bounded by the number of buckets the scanned time range can span, and only
  when the planner had nothing to estimate from. A plain column, an expression
  index and a user's `CREATE STATISTICS ON (expr)` all count as informed and are
  left alone. Measured on 20 million rows: a one-aggregate windowed query goes
  from 2,017 ms to 497 ms and a ten-aggregate one from 4,687 ms to 1,146 ms,
  while a plain-column key keeps a bit-identical estimate and its existing plan.
  Both settings involved are still off by default.
- The ungrouped vectorized aggregate no longer errors on a varlena filter
  column (#423). `SELECT count(*) FROM t WHERE s LIKE '%x%'` raised
  "unsupported byval length: -1" with
  `pgcolumnar.enable_ungrouped_vector_agg` on. The batch fold gathers each
  projected column with pointer arithmetic on `attlen`, which is -1 for a
  varlena, so the offset and the fetch were both wrong. The eligibility check
  walked the scan keys and asked whether each type was comparable, while the
  gather walks the projected set and needs each type passed by value. A text
  column filtered with `LIKE` is projected and is not a scan key, so it arrived
  unchecked. `uuid` and `name` failed the same way for a different reason: both
  are fixed width, 16 and 64 bytes, but passed by reference, and the gather
  hardcodes by-value. Such a shape now falls back to the row path, which is what
  the ALTER TABLE ADD COLUMN case already did. This was ClickBench q21.

### Upgrading

**Run `ALTER EXTENSION pgcolumnar UPDATE;` in every database that has the
extension, after installing this build.**

The rename moves the C symbol names that each installed function recorded when it
was created. Replace the shared library without this step and those records
point at symbols the new library does not export. The extension then stops
working until the catalog is updated. Reading an existing columnar table fails
with `could not find function "columnar_handler"`.

Nothing happens to your data, and no conversion runs. The upgrade replaces
catalog entries only, and keeps each function's identity, so the access method
binding and every dependency survive. The SQL you write does not change.

See [Upgrade](docs/installation.md#upgrade) for the commands, including how to
list the databases that need it.

## [1.0-alpha] - 2026-08-04

First tagged release. Everything below shipped in it.

### Known limitations

- The grouped vectorized aggregate's parallel arm is declined on shapes with an
  expression grouping key, because the core Finalize is priced off a group estimate
  that can be 25x to 42x wrong (#369). Both settings involved are off by default.
- The by-row-number fetch cache is bounded by `4 x (cap + retained position indexes
  + groupBuffer)` rather than `4 x cap`. On a table of many wide varlena columns one
  entry measured 62 MB against a 32 MB cap (#364). Releasing the position indexes
  with the decoded stream holds the bound but costs 47% in time, so this design
  keeps the speed and records the trade.
- The index-fetch penalty is bounded by a multiple of one full scan rather than
  modelled against the consumer, so a plan that stops early inherits more of it than
  it should (#376). The bound keeps the penalty steering correctly on every shape
  measured; the model is post-alpha work.
- Point lookups remain slower than heap, and the cost of a fetch grows with table
  width, because an index fetch decodes the attribute prefix up to the highest
  column the query reads. See `docs/limitations.md`.

### Added

- `pgcolumnar.parallel_copy(target, path [, workers])` loads a COPY text file into
  a columnar table with several background workers at once, and returns the row
  count (#300). Each worker runs core `COPY` over a byte range of the file, so
  parse and write behavior match `COPY FROM`. The load is atomic through two-phase
  commit: every worker prepares its transaction, and a coordinator commits them
  together only when all succeeded, so any failure rolls the whole load back. The
  target is a single columnar table, where any record-aligned split is correct, or
  a RANGE-partitioned table with columnar partitions, where the file must be sorted
  ascending by the partition key and the key type must be numeric or a date/time
  type. The columnar encode step is CPU bound, so the load scales with worker
  count up to the physical core count. It landed in two parts, partition-parallel
  (#323) and single-table (#324). See docs/user-guide.md and docs/benchmarks.md.

- Column projection reads only the columns a query references, and is **on by
  default** (#339, `pgcolumnar.enable_column_projection`). A columnar scan
  previously decoded every column of every row group it touched regardless of the
  query's target list, which discards the main advantage of the storage format on
  wide tables. Measured on a 100M-row 21-column fixture, a single-column
  aggregate improved 6.9x. The gain is smaller on grouped queries, which also read
  their grouping keys: 1.24x, 1.13x and 3.13x on three TSBS-shaped grouped
  aggregates. Turning the setting off restores the previous behavior.

- Vectorized aggregates, all **off by default** and opt-in while they are proven:

  - `pgcolumnar.enable_ungrouped_vector_agg` folds a plain `SELECT agg(col) FROM t`
    over the decoded column buffer instead of one Datum tuple per row (#337).
  - `pgcolumnar.enable_parallel_vector_agg` makes that fold parallel-aware (#343),
    extended to integer sum and average partials (#346), and to grouped
    aggregates (#366). Each worker claims distinct row groups through a shared
    counter and emits per-worker transition state that a core Finalize combines.
  - `pgcolumnar.enable_group_vectorization` answers `GROUP BY` from a vectorized
    grouped node (#321). `pgcolumnar.groupagg_max_groups` caps its hash table and
    errors with guidance rather than growing without bound.

  These remain off by default because plan selection for them is not settled: a
  grouped query with an expression grouping key such as `date_trunc()` can decline
  the parallel path on a group-count estimate that is 25x to 42x wrong (#369).

- `pgcolumnar.enable_index_fetch_penalty`, **on by default** (#355), prices the
  per-row heap fetch of an index or bitmap path on a columnar table. A columnar
  fetch decodes the row group the row lives in, while core prices it as a page or
  two, so an unclustered ordering column made an index scan look cheap and then
  run for minutes decoding the table many times over. The penalty counts the
  distinct row groups the fetches force, interpolating on the square of the
  leading-key correlation. Turning it off restores the previous planner behavior.

### Changed

- The fetch cache holds the columns that fit rather than dropping a whole entry
  when it exceeds its size cap (#359). An entry one byte over the 32 MB cap was
  not retained at all, so every fetch re-read the row group and re-decoded every
  column it touched. On a 100M-row fixture that was 2,833 ms at four aggregated
  columns and 134,147 ms at five, flat on either side of the step. Each column now
  decodes into its own context and the one that crosses the cap is released after
  its value is read, so exceeding the cap costs the overflow fraction rather than
  everything. An earlier fix moved the decode scratch out of the cached entry,
  shrinking entries about 3x (#353). A group whose raw bytes alone exceed the cap
  is still dropped whole.

- The index-fetch penalty is applied before the columnar path is offered to the
  planner, not after (#362). `add_path` frees a path it judges dominated, so a
  columnar path offered while the index paths still carried un-penalized costs was
  discarded, and raising those costs afterwards changed what `EXPLAIN` printed
  with nothing left to switch to. The planner chose an index scan it priced at
  13,954,742 over a columnar path it priced at 589,348, running 224 seconds where
  the columnar path runs 4.7. Two related defects were fixed with it: the parallel
  columnar path was conditional on a sequential scan surviving `add_path`, so it
  did not exist on exactly the selective queries where it was needed, and the
  projection path read the base path's cost after `add_path` may have freed it.

- The grouped vectorized aggregate path is charged for the folding it does (#349),
  `cpu_operator_cost` per input row per aggregate. It previously priced itself
  just above the scan it performs, which made it unpriceable against: every
  competing plan paid a per-row aggregation cost and this one paid none, so it won
  by construction, including against a parallel plan several times faster. That
  cost about 1.9x on a full-scan `GROUP BY` with few groups.

- The vectorized batch fold pushes scan keys, so it no longer forfeits zone-map
  row-group pruning (#349). The fold opened its reader with no predicates, so no
  group skipping occurred: on a clustered fixture with a selective predicate it
  read 200 of 200 row groups where the ordinary path read 2.

- Server-file functions now gate on the `pg_read_server_files` and
  `pg_write_server_files` roles instead of `superuser()` (#330), matching core
  `COPY ... FROM/TO 'file'` so a DBA can delegate server-file access without
  handing over superuser. This is a deliberate loosening. The read functions
  (`import_parquet`, `read_parquet`, `parquet_schema`, the `pgcolumnar_parquet`
  foreign-table scan, `import_arrow`) parse files this project wrote, so they are
  now reachable from a role short of superuser; give an untrusted Parquet or Arrow
  file the care in `docs/administration.md` while the Arrow parser fuzzing (#214)
  is incomplete. The write functions (`export_parquet`, `export_arrow`,
  `parallel_export_parquet`) gate on `pg_write_server_files`. `file_split_offsets`
  and `parallel_copy` already used the read role. `test/server_file_privilege.sh`
  now covers the full set and fails if a new file function lacks a check.

- The C standard flag for PostgreSQL 19 is probed rather than hardcoded (#294).
  This project sets `-std=gnu23` for PostgreSQL 19, whose headers use C23
  constructs. GCC 13 accepts only the older `gnu2x` spelling of the same
  language and rejects `gnu23` outright, so building against PostgreSQL 19 with
  GCC 13 failed on a flag the user never set. The Makefile now asks the compiler
  which spelling it takes. Every source file compiles under GCC 13 with `gnu2x`
  against PostgreSQL 19 headers.

- `pgcolumnar.recluster` records its ordered extent, so `pgcolumnar.sort_status`
  no longer reports a reclustered table as entirely unsorted (#311). It runs
  under a lock that permits concurrent inserts, and the mark is a boundary, so
  it can only be set where no other session's group is numbered below it. The
  rewrite records the stripe ids it reserves and marks the contiguous run from
  its first; a concurrent reservation leaves a gap in that sequence whenever it
  commits, which the visible catalog cannot show. With no concurrent writer the
  whole relation is recorded. With one, the run stops where it was interrupted
  and the rest is reported as decay, never the reverse.

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
  values.

  The scale of that is easy to understand: on a 100 million row TSBS-cpu table a
  single filter is 256 kB, and the whole bloom catalog is 3.5 GB, larger than the
  data it describes. A selective scan copied it per query through 256 kB
  allocations, and profiling put about 55 percent of the query's CPU in
  anonymous-page faults under the group-skip check.

  On that table a clustered hostname query falls from 4610 ms to 106 ms, a factor
  of 43. On a smaller shape, 20 groups of 200,000 rows over 12 columns, the cost
  is 466 buffers per skipped group out of 504, and the query falls from 9577
  buffers to 1946. Results do not change; the filter was always a pruning step.

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
