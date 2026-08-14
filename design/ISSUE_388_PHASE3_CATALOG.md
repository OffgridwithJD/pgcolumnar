# #388 phase 3 - filesystem catalog, current snapshot

Phase 3 of the #388 plan (the phase order lives in the issue): "Filesystem
catalog, read current snapshot, no deletes. Refuses loudly if the snapshot has
any delete files." Phases 1 (Avro decoder: `manifest_entry` #633 + `manifest_file`
#635) and the parse-half of 2 (Parquet field ids #613) are merged.

This phase is decomposed into three reviewable PRs, each provable on its own.
Each has a live consumer, so nothing here is an unused API that fails the
delete-and-stay-green test - the reason #613 deferred field-id *resolution* to
its Iceberg caller.

## 3a - resolve the metadata pointer (this PR)

`pgcolumnar.iceberg_current_snapshot(metadata_path text)` returns the current
snapshot recorded in an Iceberg table `metadata.json`. Pure JSON, filesystem
only, no Avro, no network, no path questions yet. This is the plan's "resolving
the metadata pointer without a network".

Output (one row, or zero rows when the table has no current snapshot):

| column | source in metadata.json |
|---|---|
| `snapshot_id` bigint | the snapshot whose `snapshot-id` == `current-snapshot-id` |
| `parent_snapshot_id` bigint | that snapshot's `parent-snapshot-id` (NULL if absent) |
| `sequence_number` bigint | `sequence-number` |
| `timestamp_ms` bigint | `timestamp-ms` |
| `operation` text | `summary.operation` (append/overwrite/delete/replace) |
| `manifest_list` text | `manifest-list` (the path as recorded, absolute) |
| `schema_id` int | `schema-id` (NULL if absent) |

Behaviour:
- Reads a local file; caller needs `pg_read_server_files` (superusers hold it).
  Same privilege gate as `read_avro_manifest` / `read_manifest_list`.
- Parses with the server jsonb API (text -> jsonb datum, then key lookups), the
  same approach `columnar_avro.c` already uses to read the embedded `avro.schema`.
  No new JSON parser.
- `current-snapshot-id` absent or `-1` -> zero rows (a table with no current
  snapshot is legal, not an error).
- `current-snapshot-id` names a snapshot not present in `snapshots[]` -> error
  (corrupt metadata), a distinct SQLSTATE from a parse failure.
- A file that is not a JSON object, or has no `format-version` -> error.
- `manifest_list` is reported verbatim (absolute path as the writer wrote it).
  Rebasing relocated paths is 3b's concern, deliberately not here.

New source file `src/columnar_iceberg.c` (this begins the catalog component,
kept separate from the Avro decoder). SQL declaration in
`pgcolumnar--1.0-alpha.sql`. Docs in `docs/sql-reference.md`.

### Tests (3a)
`test/iceberg_catalog.sh`, oracle from the committed `metadata.json` fixture
(extracted independently with python's stdlib `json`, not from our own reader):
assert `snapshot_id`, `sequence_number`, `operation`, and `manifest_list`
basename against the oracle. RED first (no such function on main). Removal
proof: mutate the `current-snapshot-id` lookup to return the first snapshot
unconditionally and confirm the arm reds when the current snapshot is not
snapshots[0]. A malformed-JSON arm asserts a clean SQLSTATE, backend survives.
No-current-snapshot arm (edit a copy to drop `current-snapshot-id`) returns
zero rows. PG17/18/19 + ASAN (it reads a file into palloc'd buffers).

### Fixture (3a)
Extend `gen_iceberg_fixture.py` to copy the current `*.metadata.json` into
`test/fixtures/iceberg/table.metadata.json` and write an oracle
`expected_meta.json` (current-snapshot-id, sequence-number, operation,
manifest-list basename, schema-id) using pyiceberg's own view of the table.
Regenerate from the same real pyiceberg v2 warehouse as steps 1-2 (host venv;
no pip in the containers, so the output is committed).

## 3b - current snapshot -> live data-file list (next PR)

Chain 3a into the two Avro decoders: current snapshot -> `manifest_list` ->
`manifest_file[]` -> each manifest -> `manifest_entry[]` -> the live data files.
`pgcolumnar.iceberg_data_files(metadata_path text)` returning
`(file_path, file_format, record_count, partition)`.

Two designs this PR must settle and test:
1. **Absolute-path rebasing.** metadata.json, the manifest list, and the
   manifests all store absolute paths (`file:///.../warehouse/...`). A committed
   fixture, or any relocated table, will not sit at the recorded `location`.
   Derive the table root from where `metadata.json` was found, strip the recorded
   `location` prefix, and re-root each path onto the actual root; refuse a path
   that does not start with the recorded `location` rather than reading an
   arbitrary absolute path off the host. Test by copying the warehouse to a
   second directory and confirming it still resolves.
2. **Loud delete refusal.** Refuse (a specific SQLSTATE, not a silent skip) if
   any `manifest_file.content != 0` (a delete manifest) or any
   `manifest_entry.content != 0` / `status == 2` (position/equality deletes, or a
   deleted entry). A reader that drops deletes looks finished and is wrong. The
   deny arm needs a fixture that actually carries a delete so the call reaches the
   refusing code (assert SQLSTATE), either a real pyiceberg delete table or a
   crafted manifest with `content=1`.

## 3c - scan the data files, projecting by field id (later PR)

Where #613's deferred field-id *resolution* gets its live caller. Open each data
file from 3b through the existing Parquet reader, but resolve the Iceberg
schema's columns to Parquet leaves by **field id** (thrift field 9, already
parsed into `PqSchemaCol.field_id`), with name mapping as the documented
fallback for files written without ids.

Map of what 3c must change (from the reader survey, all in
`src/columnar_parquet_reader.c`; there is no separate FDW file):
- Binding today is **positional**: `build_imp_targets()` (~:2454-2613) is the
  single bind point, walking tupdesc attributes in order and consuming Parquet
  leaves via a monotonically incrementing `lf`; it never reads `sc->name` or
  `sc->field_id` (those `NameStr` uses are error text only). Field-id resolution
  replaces "consume next leaf" with "find the leaf whose `sc->field_id` == the
  attribute's declared id".
- `PqSchemaCol` (:130-145) already carries `field_id` (-1 sentinel) and `name`.
  `PqLeafInfo` (:148-153) is the per-leaf array; `ImpTop` (~:2425-2441) is the
  per-target bind result that would gain a resolved leaf index.
- Projection set `pqfdw_compute_needed()` (:4321-4339) and pushdown mapping
  `pqfdw_top_for_attno()` (:4071-4081) / `pqfdw_compute_skip()` (:4229-4312) key
  off attribute number into positionally-built tops - unchanged in shape once the
  bind resolves by id, since they map attno->top not name->leaf.
- FDW options are validated in `pgcolumnar_parquet_fdw_validator()` (:4768-4858);
  the `else` arm rejects unknown names, so any new resolution option
  (e.g. `resolution = field_id`) must be registered there. Only *partition*
  columns match by name today (`pqfdw_partition_mask()` :3674,
  `pqfdw_partition_values()` :3854).
- Tests: `native_parquet_schema.sh` already writes `PARQUET:field_id` fixtures
  via pyarrow and is the natural home or sibling for a field-id projection suite;
  `native_parquet_projection.sh` is the FDW projection model to extend.

Scope held out of phase 3 entirely (later phases): deletes (phase 4), pruning
and partition transforms (phase 5), object storage and REST catalog (phase 6).
