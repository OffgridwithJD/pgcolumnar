# pgColumnar 1.0-alpha5 release notes

Release date: TODO(release)
Previous release: 1.0-alpha4 (2026-09-17)

pgColumnar is a columnar table access method for PostgreSQL. This is the fifth
alpha. Its theme is encoding, as measured. Tables that this release writes are
smaller: on the ClickBench sample, the same data takes 20.6% fewer bytes than
before this release's two encoding changes. Range columns can now skip chunk
groups on overlap and containment queries. Catalog reads cost less in a database
with many columnar tables.

This release changes how column chunks are stored. An alpha4 build cannot read
safely what this release writes. Read "On-disk format" before you upgrade.

This release requires one upgrade command. See "Upgrading" at the end.

## Highlights

- **TODO(release): #1137, the on-disk format version check.** See "On-disk
  format". This is likely the most important item for anyone who upgrades.
- **Smaller tables.** On ClickBench `hits_0.parquet` (1,000,000 rows, 105
  columns), stored chunk bytes fell from 81,869,112 to 64,984,810. Two changes
  produce this. An encoding is kept only when it is smaller after compression.
  A chunk that holds no null stores no validity bitmap.
- **Range columns skip on `&&` and `@>`.** A zone map now records the greatest
  upper bound of a range column. On a table clustered on the range, an overlap
  query read 1 chunk group of 20 instead of all 20.
- **Less catalog work in a large database.** The pgcolumnar catalogs are shared
  by every columnar table in a database. Many lookups used to read a whole
  catalog. They now use its index once the catalog is large enough. A new
  setting, `pgcolumnar.index_min_blocks`, sets that size.
- **Two crashes fixed.** Both involve a partitioned table that names
  `pgcolumnar` as its access method. See "Fixed".
- **Columnar materialized views work in more places.** A columnar materialized
  view can now hold per-table options. Its catalog entry is correct from the
  moment it is created.

## On-disk format: TODO(release): #1137

TODO(release): #1137. Replace this section once #1137 lands. Issue #1137 adds a
format version stamp that this release writes, and a range check on read. Its
purpose is to make an older build refuse a newer table early and loudly on
every read path. State here:

- the new stamp value
- the range of versions this build reads
- what an alpha4 build does with a table this build wrote
- whether existing tables are restamped

What is true without #1137:

- The native data format stays PGCN v1. The metapage version is unchanged.
- Each column chunk carries an encoding descriptor (a small header that records
  how the chunk's values are encoded). Its version moves from 2 to 3. This
  release reads versions 2 and 3, so it reads every table that alpha4 wrote. No
  conversion is needed.
- An alpha4 build cannot read a version 3 chunk safely. A sequential scan fails
  with `unrecognized native encoding descriptor`. An index fetch can fail, or it
  can return NULL for a row that holds a value. Measured on an alpha4 build: 16
  of 40 single-row fetches returned NULL, and the other 24 raised the error.

The NULL case is a wrong answer, not an error. That is why downgrading is not
supported. See the warning in "Upgrading".

## Smaller tables

### An encoding is kept only when it is smaller after compression (#1132)

The writer chooses an encoding, such as bit-packing, by comparing uncompressed
sizes. The block codec (`zstd` or `lz4`) then compresses the result. An
encoding can shrink the bytes and still make the compressed chunk larger,
because it hides patterns the codec would have found.

The writer now compresses both the encoded chunk and the raw chunk and keeps the
smaller. Measured on the ClickBench sample:

| measure | before | after |
| --- | ---: | ---: |
| stored bytes | 81,869,112 | 78,109,810 (-4.59%) |
| `ClientEventTime` column | 3,530,536 | 1,777,051 (-49.7%) |

The price is write CPU: 4.40% more backend instructions on the same load. Query
results are unchanged.

`pgcolumnar.enable_post_codec_encoding_choice` controls this. It is on by
default. Set it to `off` to restore the earlier choice.

### A chunk with no nulls stores no validity bitmap (#1130)

A validity bitmap is one bit per row that records which rows are NULL. The
writer stored it for every chunk, uncompressed, even when no row was NULL. It
now leaves the bitmap out of any chunk that holds no null. The decision depends
on the rows written, not on a `NOT NULL` constraint. A nullable column with no
nulls in a chunk also saves the space.

Measured on the ClickBench sample, which has no nulls:

| measure | before | after |
| --- | ---: | ---: |
| stored bytes | 78,109,810 | 64,984,810 (-16.80%) |
| validity bitmap bytes | 13,125,000 | 0 |
| chunks without a bitmap | 0 of 735 | 735 of 735 |

Both changes apply to data this release writes. Data written before the upgrade
keeps its old layout until it is rewritten. TODO(release): verify.

## Range pruning (#1144)

A query with `&&` (overlap) or `@>` (contains) on a range column now skips
chunk groups that cannot match. Before this release, both operators read every
chunk group.

The zone map (the per-group summary the scan uses to skip data) gains the
greatest upper bound of the range column. The minimum and maximum it already
held cannot answer overlap, because a range type sorts by lower bound first.

Measured on 200,000 rows of `tstzrange` in 20 chunk groups:

| table | groups read, before | groups read, after |
| --- | ---: | ---: |
| clustered on the range column | 20 | 1 |
| rows in random order | 20 | 20 |

Clustering is a precondition, not an option. On a table whose ranges are
scattered, every group holds a bound near the maximum, so nothing is skipped.

Three further points:

- A range with no upper bound is never skipped from above.
- The scan compares under the collation the range type was declared with.
- Data written before the upgrade has no summary. It is read in full, and never
  skipped wrongly, until it is rewritten.

See [docs/limitations.md](docs/limitations.md), section "Which predicates
prune".

## Catalog work in a large database

pgColumnar keeps its metadata in catalogs that every columnar table in a
database shares. Many lookups read a whole catalog to find one table's rows. In
a database with many columnar tables, each lookup paid for every other table.
This release routes those lookups through each catalog's existing index. No
index is added and no catalog changes.

An index probe costs more than reading a catalog of one or two pages. So a
lookup uses the index only when the catalog has at least
`pgcolumnar.index_min_blocks` pages. The default is 3. It was chosen from
measurements at 24 catalog sizes on PostgreSQL 15, 17 and 19.

Measured on PostgreSQL 17 with 400 other columnar tables that have projections,
in catalog buffers read:

| operation | catalog | before | after |
| --- | --- | ---: | ---: |
| one-row `DELETE` | `row_group` | 45 | 19 |
| `INSERT` | `storage` | 19 | 13 |
| `pgcolumnar.vacuum_sorted` | `storage` | 128 | 93 |
| `pgcolumnar.truncate` | `free_space` | 26 | 17 |

Other paths that changed:

- **Planning.** Planning a query read `pgcolumnar.storage` in full for the
  newest table. It now reads the table's own row through its metapage. Measured
  on a 37-page catalog: 37 blocks per planned query before, 4 after.
- **Retiring a row group.** Compaction made 7 sequential catalog scans per
  retired row group, plus 3. It now uses the catalogs' indexes instead, once
  they reach `pgcolumnar.index_min_blocks` pages.
- **`DELETE`.** The session that ran a `DELETE` scanned `delete_vector` in full
  once per row group it touched. It now uses the index.
- **Empty catalogs.** `pgcolumnar.options` and `pgcolumnar.projection` are empty
  until you set an option or add a projection. Planning no longer probes their
  indexes while they are empty or small.

## Covering projections and the planner

A covering projection is a sorted copy of some of a table's columns, which a
query can scan instead of the table. These changes affect which plan the planner
chooses. They do not change query results.

- **Parallel scan of a covering projection.** The planner can now scan a covering
  projection in parallel. Before, a plan had to give up either the projection or
  the parallel workers.
- **A projection scan is priced from its own pages.** The planner used the size
  of the whole relation file. That file holds the base table and every
  projection.
- **A base scan is no longer priced from its projections' pages**, for the same
  reason.
- **A projection is priced from what its sort order can skip.** The cost used to
  assume half the table for every query. It now follows the selectivity of
  conditions on the sort key. A condition that mentions the sort key but cannot
  use it to skip, such as `sk BETWEEN 1 AND 2000 OR kind = 'odd'`, earns no
  discount.

## Retention

`pgcolumnar.expire` now accepts a `date` retention column. Before, it accepted
only `timestamp` and `timestamptz`.

For a `date` column, the cutoff is rounded down to the start of its day. As a
result, `expire` can keep a row up to one day older than the retention window.
It never removes a row that is inside the window.

## Settings

Two settings are added. None is removed, and no default changes.

| setting | type | default | purpose |
| --- | --- | --- | --- |
| `pgcolumnar.enable_post_codec_encoding_choice` | boolean | `on` | Keep an encoding only when it is smaller after block compression. `off` restores the earlier choice. |
| `pgcolumnar.index_min_blocks` | integer | `3` | Page count at or above which a catalog lookup uses the catalog's index. `0` always uses the index. A very large value never does. |

Both can be set per session. See [docs/configuration.md](docs/configuration.md).

## Fixed

- **A partitioned table that names `pgcolumnar` could abort the backend**
  (#1259). From PostgreSQL 17, a partitioned table can carry
  `USING pgcolumnar` as the default for its partitions. It has no storage of its
  own. Functions such as `pgcolumnar.stats` and `pgcolumnar.sort_status` treated
  it as a columnar table. An assert-enabled build aborted. A production build
  returned a wrong answer instead. These functions now treat the partitioned
  parent as not columnar.
- **`pgcolumnar.import_parquet` crashed the server on a partitioned parent**
  (#1263). It now refuses a target without storage. The crash was a
  segmentation fault on production builds too. Importing into a heap table still
  works.
- **`CREATE MATERIALIZED VIEW ... USING pgcolumnar ... WITH DATA` left a wrong
  catalog entry** (#1275). The view's storage row named a relation that no
  longer existed until the first `REFRESH`. It now names the view.
- **`ALTER TABLE ... ALTER COLUMN TYPE` left a wrong catalog entry** (#1211).
  After the rewrite, the table's storage row named the dropped temporary
  relation. The rows stayed readable. The storage row now names the table.
- **`pgcolumnar.analyze()` could skip columns without saying so** (#1276). On a
  table with a covering projection, it could resolve the projection's storage
  instead of the table's. Measured on a five-column table with a one-column
  projection: statistics for 2 columns instead of 5, and a successful return.
- **A columnar materialized view can hold per-table options** (#1265).
  `pgcolumnar.set_options` and `pgcolumnar.reset_options` now accept one, and
  `DROP MATERIALIZED VIEW` removes its options.
- **`pgcolumnar.reset_options` reported success on a non-columnar relation**
  (#1265). It accepted a heap table, a partitioned table and a view, while
  `set_options` refused them. It now refuses the same relations, with SQLSTATE
  `42809`.

## Known issues

- **Setting a codec can make a table larger, on high-entropy text** (#1074).
  This is unchanged from alpha4. Measured on this release, 200,000 rows of
  random 64-character hex text:

  | `pgcolumnar.compression` | relation bytes | against `none` |
  | --- | ---: | ---: |
  | `none` | 7,036,928 | 100% |
  | `lz4` | 7,036,928 | 100% |
  | `zstd` | 7,135,232 | 101.40% |

  If a table stores long high-entropy text, measure both settings. See
  [docs/features.md](docs/features.md).

## Upgrading

### Before you start

- You need:
  - the alpha5 build
  - the same `PG_CONFIG` you installed alpha4 with
  - permission to restart the server
  - the right to run `ALTER EXTENSION` in each database that has the extension
- List the databases you can connect to. You will visit each one:

  ```sql
  SELECT datname FROM pg_database WHERE datallowconn;
  ```

### Steps

1. Run `make install` with the same `PG_CONFIG`.

   **WARNING:** You cannot safely go back to alpha4 after the next step. Once
   the server loads the alpha5 library, the chunks it writes use encoding
   descriptor version 3. An alpha4 build can return NULL for a row that holds a
   value in such a chunk. If you may need to roll back, take a backup first.
   TODO(release): confirm after #1137 lands.

2. Restart the server, so that it loads the new library.
3. Connect to one database from the list.
4. Check whether the extension is installed there:

   ```sql
   SELECT extversion FROM pg_extension WHERE extname = 'pgcolumnar';
   ```

   If the query returns no row, skip to step 7.

5. Run:

   ```sql
   ALTER EXTENSION pgcolumnar UPDATE;
   ```

6. Run the query from step 4 again.

   Expected result: `1.0-alpha5`.

7. Repeat steps 3 to 6 for every other database in the list.

### What the upgrade changes

- It adds the column `max_upper` (type `bytea`) to `pgcolumnar.zone_map`.
  Existing rows get NULL, which means "no summary".
- It replaces `pgcolumnar.set_options`. The new version also accepts a columnar
  materialized view.
- It replaces `pgcolumnar.reset_options`. The new version refuses any relation
  that `set_options` refuses. A script that called it on a heap table, a
  partitioned table or a view used to succeed. It now raises an error.
- It replaces `pgcolumnar."analyze"`. The new version finds a table's storage
  through the table's metapage.
- No table data is converted. TODO(release): confirm after #1137 lands, and
  state whether existing tables keep their current format stamp.
- It does not repair a catalog entry that alpha4 left wrong. See "After the
  upgrade: repair entries alpha4 left wrong".

### After the upgrade: repair entries alpha4 left wrong

Two alpha4 defects, fixed in this release (#1211, #1275), left a table's storage
row naming a relation that no longer exists. The upgrade does not repair rows
that already exist. The table still reads and writes correctly, and `DROP TABLE`
still removes the row. Repair them anyway, so the catalog describes your tables.

This was measured on PostgreSQL 17, on tables created under alpha4. After the
upgrade, the rows stayed wrong through reads, inserts, `pgcolumnar.analyze()`
and `VACUUM`. Each repair below made them correct.

1. In each database, find the rows that name no relation:

   ```sql
   SELECT s.storage_id, s.relation_oid
   FROM pgcolumnar.storage s
   WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = s.relation_oid);
   ```

   If the query returns no row, this database needs nothing.

2. For each columnar materialized view, run:

   ```sql
   REFRESH MATERIALIZED VIEW view_name;
   ```

   **CAUTION:** the next step takes an `ACCESS EXCLUSIVE` lock and rewrites the
   whole table. Run it when the table can be locked for that long.

3. For each columnar table that ran `ALTER TABLE ... ALTER COLUMN ... TYPE`
   under alpha4, rewrite it once. Converting a column to its own type with
   `USING` forces the rewrite and changes no data:

   ```sql
   ALTER TABLE table_name ALTER COLUMN column_name TYPE column_type USING column_name;
   ```

4. Run the query from step 1 again.

   Expected result: no row.

See [docs/installation.md](docs/installation.md) for the full upgrade procedure.

## Scope and limitations

- This is an alpha. Interfaces may change before 1.0.
- Cascading encodings (one encoding applied on top of another) are not in this
  release. Issue #1139 tracks them until a measurement shows a size win.
- `pgcolumnar.vacuum_full` still skips columnar materialized views.
- A GIN or BRIN index builds on a columnar table, but the planner can never use
  it. Both need a bitmap scan, which the columnar access method does not
  provide. See [docs/limitations.md](docs/limitations.md).
- On PGXN this release is `1.0.0-alpha.5`, while `CREATE EXTENSION` reports
  `1.0-alpha5`. PGXN requires a semantic version, which needs three integer
  components. The two names refer to the same release.

The complete, itemized list of changes is in `CHANGELOG.md`.
