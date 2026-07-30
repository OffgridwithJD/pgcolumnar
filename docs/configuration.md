# Configuration reference

pgColumnar has two kinds of settings:

- Server settings under the `pgcolumnar.` prefix, listed below. Most can be set in
  `postgresql.conf`, per session with `SET`, per role, or per database, without
  special privileges. Two are not: `pgcolumnar.enable_end_truncation` requires
  superuser, and `pgcolumnar.unique_lock_buckets` can only be set at server start.
  Each exception is noted in its own row below.
- Per-table storage options, set with `pgcolumnar.set_options`. These
  apply to one table and are used when that table writes new data.

## Server settings

### Storage layout

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.stripe_row_limit` | integer | `150000` | Maximum rows per row group. The row group is the unit of write and the granularity at which whole segments are appended. Range 1000 to INT_MAX. |
| `pgcolumnar.chunk_group_row_limit` | integer | `10000` | Maximum rows per vector. The vector is the unit of encoding and of min/max skipping. Range 100 to INT_MAX. |
| `pgcolumnar.encoding_sample_rows` | integer | `2048` | Rows sampled to choose a vector's value encoding. Candidates are estimated on a windowed sample (evenly spread windows of consecutive values, so both global shape and local runs are visible) and only the best two are applied to the whole vector. `0` applies every candidate to every vector, which is what earlier versions did, and any value below 128 is treated as `0` because a smaller sample cannot rank candidates. Affects write speed and, in principle, compression ratio; never correctness. |

### Compression

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.compression` | enum | `zstd` | Default codec for new chunks. One of `none`, `pglz`, `lz4`, `zstd`. `lz4` and `zstd` are available only when the extension was built with those libraries. |
| `pgcolumnar.compression_level` | integer | `3` | Level for the `zstd` codec. Range 1 to 22. Higher levels compress more and write more slowly. |
| `pgcolumnar.fsst_min_gain_percent` | integer | `5` | Minimum size reduction, in percent, for FSST string encoding to be kept for a column chunk. Range 0 to 99. See below. |

Building FSST codes for every vector is one of the larger costs of a text or
varlena load. At `0`, FSST is kept whenever it produces any reduction after
the block codec, however small, and that reduction does not always repay the
encode. The default of `5` keeps FSST only where it saves at least 5 percent.

On measured workloads this costs about 2 percent stored size on shapes where
FSST barely wins, such as high-entropy text, and reduces their load time by
roughly a third. Where FSST wins by more than the margin, such as low-cardinality text, the
setting changes nothing: the encoding chosen and the bytes written are the same.
Wide values are also unaffected.

Set it to `0` for the previous behaviour of keeping FSST on any reduction. The
setting applies when data is written, so it affects new chunks rather than
existing ones, and it never changes the values a table returns.

### Scan and execution

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.enable_custom_scan` | boolean | `on` | Use the columnar custom scan path for columnar tables. |
| `pgcolumnar.enable_qual_pushdown` | boolean | `on` | Push scan qualifiers down so per-chunk min and max values can skip chunk groups. |
| `pgcolumnar.enable_vectorization` | boolean | `on` | Use the vectorized aggregate path for supported ungrouped aggregates. |
| `pgcolumnar.enable_bloom_filter` | boolean | `on` | Skip chunk groups on equality filters using per-chunk bloom filters. |
| `pgcolumnar.enable_read_stream` | boolean | `on` | Prefetch block reads with the read stream API. Effective on PostgreSQL 17 and later. |

### Index-only scan and projections

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.enable_index_only_scan` | boolean | `on` | Allow index-only scans on columnar tables, served by the columnar visibility-map fork. Set to `off` to force a plain index scan. |
| `pgcolumnar.enable_projection_scan` | boolean | `on` | Let the planner scan a covering projection instead of the base table when one serves the query better. |

### Column cache

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.enable_column_cache` | boolean | `off` | Cache decompressed chunk groups so they can be reused across reads. |
| `pgcolumnar.column_cache_size` | integer (MB) | `200` | Size of the decompressed-chunk cache. Applies when the column cache is enabled. Range 1 to INT_MAX. |

### Maintenance and disk reclaim

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.reclaim_coalesce` | boolean | `on` | During online compaction, split an oversized freed range on reuse and coalesce adjacent freed ranges, so space is reclaimed under fragmentation. Off reverts to whole-range reuse. |
| `pgcolumnar.enable_end_truncation` | boolean | `off` | Allow `pgcolumnar.truncate()` to return trailing reclaimed blocks to the operating system. Off makes `pgcolumnar.truncate()` a no-op. Requires superuser to set. |

### Concurrent unique inserts

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `pgcolumnar.enable_unique_insert_lock` | boolean | `on` | Serialize concurrent inserts of the same unique-index key with a transaction-scoped advisory lock, so overlapping same-key inserts conflict correctly. |
| `pgcolumnar.unique_lock_buckets` | integer | `128` | Advisory-lock buckets per unique index. Bounds how many advisory locks a transaction holds per unique index. Equal keys always share a bucket; unrelated keys may share one, which only over-serializes. Range 1 to 1048576. Settable only at server start: the bucket is part of the lock tag, so backends that disagree on this value would not serialize against each other. |

## Per-table storage options

`pgcolumnar.set_options` sets storage options on one table. New data
written after the change uses the new values; data already written is unchanged
until the table is rewritten (for example by `pgcolumnar.vacuum`).

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

Arguments left at their default (`NULL`) are not changed. A value outside the
valid range for a limit or level is rejected.

### Encode effort

`encode_effort = fast` skips the FSST substring search when writing text and
other variable-length columns. Everything else is unchanged: dictionary,
run-length, the numeric schemes and the block codec all still run, and a table
written either way is read back by the same code, so the setting is a cost
choice and never a compatibility one.

It trades compression ratio for load speed, and how much of each depends
entirely on the data:

| Text shape (1,000,000 rows, one column) | Load speed-up with `fast` | Extra space |
| --- | --- | --- |
| 32-char hashes | 5.7x | 2.7% |
| E-mail addresses | 3.5x | 12.2% |
| 64-char hashes | 3.1x | none |
| 256-char high-entropy | 2.4x | none |
| Short low-entropy text | 1.2x to 2.7x | none |

On five of the seven shapes measured, `fast` produced byte-for-byte identical
storage, so the work it skipped had bought nothing. On the two where the search
does pay, it pays properly. There is no way to know which case a column is
without trying it, which is why this is a per-table choice and why the default
keeps the full search.

`fast` is worth considering for a bulk load you intend to compact later:
`pgcolumnar.vacuum`, `pgcolumnar.compact_rewrite` and `pgcolumnar.recluster`
rewrite the data under whatever effort is set at the time, so a table can be
loaded cheaply and compressed properly afterwards.

The option is per table rather than a session setting on purpose: the same data
written through two sessions with different settings would otherwise be stored
two different ways depending on which session loaded it.

`pgcolumnar.reset_options` returns options to the server defaults:

```sql
SELECT pgcolumnar.reset_options(
    'events',
    chunk_group_row_limit => true,
    compression           => true);
```

Each boolean argument, when true, resets that option on the table.
