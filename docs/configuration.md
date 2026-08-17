# Configuration reference

pgColumnar has two kinds of settings:

- Server settings. These settings use the `pgcolumnar.` prefix. The list is
  below. For almost all of them, you do not need a special privilege. You can set
  them in `postgresql.conf`, for one session with `SET`, for one role, or for one
  database. A few need a special privilege or a specific time. Setting
  `pgcolumnar.enable_end_truncation` or `pgcolumnar.objstore_allowed_endpoints`
  needs superuser. You can set `pgcolumnar.unique_lock_buckets` only at server
  start. The row for each of these gives the condition again.
- Per-table storage options. You set these options with
  `pgcolumnar.set_options`. They apply to one table. That table uses them when it
  writes new data.

## Server settings

### Storage layout

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.stripe_row_limit` | integer | `150000` | Maximum rows per row group. The row group is the unit of write and the granularity at which whole segments are appended. Range 1000 to INT_MAX. |
| `pgcolumnar.chunk_group_row_limit` | integer | `10000` | Maximum rows per chunk group. The chunk group is the band a scan skips as a unit when a filter cannot match its minimum and maximum. Within a chunk group each column is encoded in fixed 1024-value vectors. Range 100 to INT_MAX. |
| `pgcolumnar.encoding_sample_rows` | integer | `2048` | The number of rows that the writer samples to select the value encoding of a vector. The writer estimates each candidate on a sample of windows. The windows contain consecutive values and have an equal distance between them. Thus the sample shows the global shape and also the local runs. The writer then applies only the two best candidates to the full vector. A value of `0` applies each candidate to each vector. This is the behaviour of earlier versions. The writer changes a value below 128 to `0`, because a smaller sample cannot put the candidates in order. This setting changes the write speed. It can also change the compression ratio. It does not change correctness. |

### Compression

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.compression` | enum | `zstd` | Default codec for new chunks. One of `none`, `pglz`, `lz4`, `zstd`. `lz4` and `zstd` are available only when the extension was built with those libraries. |
| `pgcolumnar.compression_level` | integer | `3` | Level for the `zstd` codec. Range 1 to 22. Higher levels compress more and write more slowly. |
| `pgcolumnar.fsst_min_gain_percent` | integer | `5` | Minimum size reduction, in percent, for FSST string encoding to be kept for a column chunk. Range 0 to 99. See below. |
| `pgcolumnar.fsst_verdict_reuse` | integer | `16` | How many later row groups may reuse a column's FSST keep-or-drop verdict before it is decided again. Range 0 to INT_MAX. |
| `pgcolumnar.parallel_flush` | boolean | `off` | Opt-in. When on, a stripe flush of two or more columns fans the per-column encode and compress work out to background workers. The stored bytes match the serial path. It helps one large flush of many numeric columns by up to 14 percent. A wide text-heavy flush regresses, because it copies the buffered bytes through shared memory. Frequent small flushes regress too, so it is off by default. Enable it for a wide numeric bulk load in the session that runs it. |

To build the FSST codes for each vector is one of the larger costs of a load of
text data. A value of `0` keeps FSST if it makes any reduction after the block
codec. A small reduction does not always pay for the cost of the encode. The
default of `5` keeps FSST only if it saves 5 percent or more.

Measurements show the effect of the default. For the data shapes where FSST wins
by a small quantity, such as high-entropy text, the stored size increases by
approximately 2 percent. The load time of the same data decreases by
approximately one third. For the data shapes where FSST wins by more than the
margin, such as low-cardinality text, the setting changes nothing. The writer
selects the same encoding and writes the same bytes. Wide values also stay the
same.

To get the behaviour of earlier versions, set the value to `0`. Then FSST stays
if it makes any reduction. The setting applies when the writer writes data. Thus
it changes new chunks, but it does not change the chunks that are already on
disk. It never changes the values that a table returns.

### Scan and execution

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.enable_custom_scan` | boolean | `on` | Use the columnar custom scan path for columnar tables. |
| `pgcolumnar.enable_qual_pushdown` | boolean | `on` | Push scan qualifiers down so per-chunk min and max values can skip chunk groups. |
| `pgcolumnar.enable_vectorization` | boolean | `on` | Use the vectorized aggregate path for supported ungrouped aggregates. |
| `pgcolumnar.enable_group_vectorization` | boolean | `off` | Use the vectorized aggregate path for `GROUP BY` queries on a columnar table. Off by default. |
| `pgcolumnar.groupagg_max_groups` | integer | `1000000` | Cap on the group count the grouped vectorized aggregate builds. Over the cap the query errors. Range 1 to INT_MAX. |
| `pgcolumnar.enable_bloom_filter` | boolean | `on` | Skip chunk groups on equality filters using per-chunk bloom filters. |
| `pgcolumnar.enable_read_stream` | boolean | `on` | Prefetch block reads with the read stream API. Effective on PostgreSQL 17 and later. |
| `pgcolumnar.enable_ungrouped_vector_agg` | boolean | `off` | Answer an ungrouped aggregate (`count`, `sum`, `avg`, `min`, `max` with no `GROUP BY`) with a batch fold over decoded vectors instead of row-at-a-time. Off by default. |
| `pgcolumnar.enable_parallel_vector_agg` | boolean | `off` | Let the ungrouped batch fold run as a parallel partial aggregate under `Gather`, each worker folding its own row groups. Requires `pgcolumnar.enable_ungrouped_vector_agg`. Off by default. |
| `pgcolumnar.enable_column_projection` | boolean | `on` | Read only the columns a query references rather than every column of the row group. |
| `pgcolumnar.enable_index_fetch_penalty` | boolean | `on` | Charge a columnar index scan for the row-group decode its per-row heap fetches force, so the planner does not treat a columnar fetch as if it were a heap page read. Set to `off` to restore the pre-1.0-alpha planner behaviour. |
| `pgcolumnar.enable_late_materialization` | boolean | `on` | Evaluate the scan qualifier before building the columns it does not read, so decode cost scales with rows emitted rather than rows scanned. |
| `pgcolumnar.qual_skipvec_min_payload_cols` | integer | `20` | Minimum projected non-qual columns before per-vector qual gating skips a no-match 1024-row vector's payload decode. Range 0 to 100000. |

### Index-only scan and projections

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.enable_index_only_scan` | boolean | `on` | Allow index-only scans on columnar tables, served by the columnar visibility-map fork. Set to `off` to force a plain index scan. |
| `pgcolumnar.enable_projection_scan` | boolean | `on` | Let the planner scan a covering projection instead of the base table when one serves the query better. |

### Maintenance and disk reclaim

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.reclaim_coalesce` | boolean | `on` | During online compaction, split an oversized freed range on reuse and coalesce adjacent freed ranges, so space is reclaimed under fragmentation. Off reverts to whole-range reuse. |
| `pgcolumnar.enable_end_truncation` | boolean | `off` | Allow `pgcolumnar.truncate()` to return trailing reclaimed blocks to the operating system. Off makes `pgcolumnar.truncate()` a no-op. Requires superuser to set. |
| `pgcolumnar.autovacuum` | boolean | `off` | Run the maintenance daemon. When on, it runs `compact_rewrite` and `recluster` on columnar tables that cross a threshold. It uses only `ShareUpdateExclusiveLock` and yields to any stronger lock. It never blocks a reader or a writer. See the [administration guide](administration.md#the-maintenance-daemon-pgcolumnarautovacuum). Reloadable, not a per-session setting. |
| `pgcolumnar.autovacuum_naptime` | integer | `60` | Seconds between daemon sweeps. Each sweep starts one worker per database. Range 1 to 86400. Reloadable. |
| `pgcolumnar.autovacuum_compact_threshold` | float | `0.2` | Deleted fraction at which the daemon rewrites a table with `compact_rewrite`. Range 0.0 to 1.0. Reloadable. |
| `pgcolumnar.autovacuum_recluster_threshold` | float | `0.05` | Appended fraction at which the daemon reclusters a table that has a recorded clustering key. Range 0.0 to 1.0. Reloadable. |

### Object storage

These govern the object-store module that reads and writes remote Parquet and
Arrow files. See [Object storage](sql-reference.md#object-storage) for the URL
schemes and the credential model.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.objstore_allowed_endpoints` | string | `''` (empty) | The endpoints the module may connect to, comma-separated as `host` or `host:port`. An entry with no port matches any port on that host; add a port to restrict it. Empty refuses every remote endpoint, so a role that can read or write server files cannot reach an arbitrary host through the extension. Link-local addresses, including `169.254.169.254`, are refused whether or not they are listed. Superuser-only, so a role cannot widen its own reach. |
| `pgcolumnar.objstore_s3_addressing` | string | `path` | The S3 request addressing style. `path` sends `s3://bucket/key` to `endpoint/bucket/key`; `virtual` sends it to `bucket.endpoint/key`, which is what AWS now prefers. Under virtual-host addressing the allow-list still authorizes the endpoint, not the per-bucket hostname. |
| `pgcolumnar.objstore_buffered` | boolean | `on` | Coalesce remote Parquet reads to one request per column chunk instead of many small ranged reads. |
| `pgcolumnar.objstore_part_size` | integer | `0` | Multipart part size in bytes for a remote export. `0` uses the module default of 8 MiB. Raise it for a fast link. Range 0 to INT_MAX. |

### Concurrent writes

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.enable_unique_insert_lock` | boolean | `on` | Serialize concurrent inserts of the same unique-index key with a transaction-scoped advisory lock, so overlapping same-key inserts conflict correctly. |
| `pgcolumnar.unique_lock_buckets` | integer | `128` | Advisory-lock buckets per unique index. Bounds how many advisory locks a transaction holds per unique index. Equal keys always share a bucket; unrelated keys may share one, which only over-serializes. Range 1 to 1048576. Settable only at server start: the bucket is part of the lock tag, so backends that disagree on this value would not serialize against each other. |
| `pgcolumnar.enable_row_update_lock` | boolean | `on` | Serialize a concurrent `UPDATE` or `DELETE` of the same row on the row identity, so the losing writer gets a retryable `serialization_failure` instead of duplicating the row and losing an update. Off restores the prior behavior. |
| `pgcolumnar.row_lock_buckets` | integer | `1024` | Advisory-lock buckets per storage for same-row `UPDATE`/`DELETE` serialization. Bounds the row locks a transaction holds, so a bulk update cannot exhaust the lock table. Unrelated rows may share a bucket, which only over-serializes. Range 1 to 1048576. Settable only at server start: the bucket is part of the lock tag. |

### Internal settings

These settings are registered but are not tuning knobs. They are listed here
because they appear in `pg_settings` and a reader who finds one there deserves an
answer.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.bulk_parallel_writer` | boolean | `off` | Internal. Set by `pgcolumnar.parallel_copy` loader workers so they skip the storage-row creation lock when the row already exists committed, which is what lets several atomic writers load one table at once. Marked `GUC_NOT_IN_SAMPLE`; leave it alone. Setting it by hand is safe but pointless: the skip only fires when the storage row is already committed, which is exactly when the lock guards nothing. |
| `pgcolumnar.maintenance_hold_ms` | integer | `0` | Internal, for tests. A maintenance verb holds `ShareUpdateExclusiveLock` this many milliseconds, interruptibly, so a test can observe the daemon yield to a stronger lock. `0` disables it. Range 0 to 600000. Leave it at `0`. |
| `pgcolumnar.sink_fail_after` | integer | `-1` | Internal, for tests. A fault-injection point that fails an export write after this many bytes, by the path a full disk takes. `-1` disables it. Range -1 to INT_MAX. Leave it at `-1`. |

## Per-table storage options

`pgcolumnar.set_options` sets the storage options of one table. The new values
apply to the data that the writer writes after the change. The data that is
already on disk does not change. It changes only when a command rewrites the
table, for example `pgcolumnar.vacuum`.

```sql
SELECT pgcolumnar.set_options(
    'events',
    chunk_group_row_limit => 20000,
    stripe_row_limit      => 300000,
    compression           => 'zstd',
    compression_level     => 6);
```

| Argument | Type | Description |
| --- | --- | --- |
| `table_name` | regclass | The columnar table to change. |
| `chunk_group_row_limit` | integer | Per-table override of `pgcolumnar.chunk_group_row_limit`. |
| `stripe_row_limit` | integer | Per-table override of `pgcolumnar.stripe_row_limit`. |
| `compression` | name | One of `none`, `pglz`, `lz4`, `zstd`. |
| `compression_level` | integer | Level for the `zstd` codec, 1 to 22. |
| `encode_effort` | name | `full` (default) or `fast`. How much work the writer spends choosing an encoding. See below. |
| `sort_by` | name[] | Declared physical sort key (#288), applied by `pgcolumnar.vacuum_sorted(t)` with no columns. Column names, so it survives `pg_dump`/restore. Not auto-maintained; re-run after inserts. Cannot name a virtual generated column. Clear with `reset_options(t, sort_by => true)`. |

The function does not change an argument that keeps its default value of
`NULL`. The function refuses a value that is outside the permitted range of a
limit or a level.

### Encode effort

`encode_effort = fast` does not do the FSST substring search. This applies when
the writer writes text columns and other columns of variable length. All other
parts stay the same. The dictionary, the run-length encoding, the numeric
schemes and the block codec all continue to operate. The same code reads a table
that the writer wrote with either value. Thus this setting controls cost only.
It does not control compatibility.

The setting decreases the compression ratio and increases the load speed. The
quantity of each effect depends fully on the data:

| Text shape (1,000,000 rows, one column) | Load speed-up with `fast` | Extra space |
| --- | --- | --- |
| 32-char hashes | 5.7x | 2.7% |
| E-mail addresses | 3.5x | 12.2% |
| 64-char hashes | 3.1x | none |
| 256-char high-entropy | 2.4x | none |
| Short low-entropy text | 1.2x to 2.7x | none |

The measurements used seven data shapes. For five of them, `fast` wrote storage
that is identical byte for byte. Thus the work that it did not do gave no
benefit. For the other two shapes, the search gives a large benefit. You cannot
know which condition applies to a column until you try it. For this reason the
option applies to one table, and the default keeps the full search.

Use `fast` for a bulk load if you will compact the table later.
`pgcolumnar.vacuum`, `pgcolumnar.compact_rewrite` and `pgcolumnar.recluster`
rewrite the data. They use the effort value that applies at that time. Thus you
can load a table at a low cost, then compress it fully after the load.

The option applies to one table and is not a session setting. This is
deliberate. If it were a session setting, two sessions with different values
would store the same data in two different forms.

`pgcolumnar.reset_options` returns options to the server defaults:

```sql
SELECT pgcolumnar.reset_options(
    'events',
    chunk_group_row_limit => true,
    compression           => true);
```

If a boolean argument is true, the function resets that option on the table.
