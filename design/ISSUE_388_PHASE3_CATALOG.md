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

SQLSTATEs: malformed JSON `22P02` (jsonb_in); not table metadata (no
`format-version`, or not an object) `22023`; a `current-snapshot-id` naming no
snapshot in the file's own `snapshots[]` `XX001` (data_corrupted); a snapshot id
past the int64 range `22003` (numeric out of range, surfaced by `numeric_int8`);
caller without `pg_read_server_files` `42501`. The snapshot scan carries a
`CHECK_FOR_INTERRUPTS` (the input is capped at `ICE_MAX_METADATA` = 64 MB, so it
is bounded, but the scan is over untrusted input).

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

## 3b - current snapshot -> live data-file list (DONE, this PR)

`pgcolumnar.iceberg_data_files(metadata_path text)` returning
`(file_path, file_format, record_count, partition)`. Chains 3a into the two Avro
decoders: current snapshot -> `manifest_list` -> `manifest_file[]` -> each
manifest -> `manifest_entry[]` -> the live data files. The 3a resolver was
refactored into a shared `ice_current_snapshot()`; both entry points use it.

Two designs settled here:
1. **Absolute-path rebasing, keyed off `location`.** metadata.json, the manifest
   list, and the manifests all store absolute paths. The recorded root is
   metadata.json's `location`; the actual root is derived from where the
   metadata.json sits (Iceberg's layout puts it at `<location>/metadata/<file>`,
   so the location is the parent of the `metadata/` dir). Each recorded path has
   its `location` prefix stripped and is re-rooted onto the actual root; a
   recorded path **not under** `location` is refused (`22023`), never read, so a
   tampered table cannot make the backend open an arbitrary server file.

   The boundary is not a byte-prefix match -- that was a real bug ChronicallyJD
   reproduced on the first 3b revision (`<location>/../../etc/passwd` shares the
   prefix and escapes when re-rooted; `<location>EVIL/x` shares the bytes as a
   sibling). `ice_rebase` therefore (a) requires the recorded path under
   `location` on a **path boundary** (next byte `/` or end), rejecting the
   sibling, and (b) re-roots, then **`canonicalize_path`s the result and
   re-checks containment** under the canonicalized actual root, collapsing any
   `..` and rejecting a traversal escape. The suite copies the committed
   warehouse to a different directory (recorded root != actual root), and asserts
   rebased paths under the actual root, no leaked recorded root, and three
   refusal payloads -- foreign absolute, `..` traversal, sibling prefix -- each
   `22023`. The traversal target is a real server file (`/etc/hostname`), so the
   removal proof (drop the canonicalization) reads it and returns `XX001` (bad
   Avro magic) instead of `22023`: the boundary is load-bearing.
2. **Loud delete refusal (`0A000`).** Refuses if any `manifest_file.content != 0`
   (a delete manifest, caught at the manifest-list level without opening it) or
   any `manifest_entry.content != 0` / `status == 2`. pyiceberg 0.11.1 **cannot**
   write merge-on-read deletes (it warns and falls back to copy-on-write), so the
   deny arm uses a **crafted** manifest-list OCF with `content = 1` -- the same
   crafted-deny technique as the avro suite's bomb/bad-magic arms. Removal proof:
   deleting the `content != 0` gate turns the refusal into a file-not-found
   (`58P01`) instead of `0A000`.

The suite (`test/iceberg_data_files.sh`) asserts the data files against
pyiceberg's own `snap.manifests(io)` oracle (`expected_files.json`), generated
by `gen_iceberg_warehouse.py` at a fixed recorded root; only the metadata/
subtree is committed (the resolver lists data files from manifests, it does not
open them, so no Parquet data is checked in).

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
