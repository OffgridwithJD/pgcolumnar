# #388 phase 4 - deletes

Phase 4 of the #388 plan: apply row-level deletes instead of refusing tables
that carry them. Phases 1-3 (Avro decode, field-id projection, filesystem
catalog + current-snapshot scan) are merged; `iceberg_scan` today refuses any
snapshot with delete files (`0A000`). This phase reads them correctly.

"A reader that ignores deletes silently returns rows the table says are gone" --
the plan's worst failure mode. So correctness, not breadth, is the bar: every
increment either applies its delete kind correctly or keeps refusing the kinds it
does not yet handle. We never silently drop a delete.

## The Iceberg v2 delete model (from the spec)

Two merge-on-read delete kinds, both tracked in **delete manifests**
(`manifest_file.content = 1`), each entry's `data_file.content` distinguishing:

- **Position deletes** (`content = 1`). A Parquet file with two columns:
  `file_path` (string, field id 2147483546) and `pos` (long, field id
  2147483545). Each row names a (data file, row ordinal) to drop. A position
  delete may also be "path-scoped" (applies to one data file) or global.
- **Equality deletes** (`content = 2`). A Parquet file carrying the columns named
  by the manifest entry's `equality_ids`. Any data row equal to a delete row on
  those columns is dropped.

**Sequence-number ordering is the correctness crux.** A delete file applies only
to data files with a **lower** data sequence number (deletes affect data written
before them). Get this wrong and the table reads subtly wrong -- deletes bleed
onto newer data, or fail to apply to older data. Every delete application is
gated on `delete.sequence_number > datafile.sequence_number` (position deletes
also match `file_path`).

## Fixture tooling (the gating constraint)

pyiceberg 0.11.1 -- the only available writer, and the current release -- CANNOT
write merge-on-read deletes (it warns and falls back to copy-on-write). No Spark
in the containers. So delete fixtures are **constructed**, not written by an
independent engine:

1. pyiceberg writes the data (a normal append) -- the data files are real.
2. A generator hand-crafts the delete Parquet (via pyarrow) and the delete
   manifest (Avro OCF, the same crafting the delete-refusal arm already uses),
   wires them into a new manifest-list + metadata.json snapshot, and sets the
   sequence numbers.
3. The oracle is computed: appended rows **minus** the positions/values the
   generator deleted. The independence we keep is pyarrow-for-data and an
   explicit hand-computed expected set; document that the delete wiring is ours
   (no independent delete writer exists), and cross-check the crafted manifest by
   decoding it back through `read_manifest_list` / `read_avro_manifest`.

A sequence-number arm is essential precisely because the oracle is ours: craft a
delete whose sequence number is NOT greater than the data file's and assert the
row survives (the delete must NOT apply), so the ordering rule is load-bearing,
not decorative.

## Architecture

The scan must, per data file, know each row's **ordinal position** to apply
position deletes, and must evaluate **equality** on the delete columns. Open
question for the reader (investigate before coding): does `pq_read_rows` expose a
per-row ordinal, and can a custom sink filter rows? Likely shape:

- The walk (`ice_walk_data_files`) stops refusing deletes and instead **collects**
  the delete entries (path, content, sequence_number, equality_ids) alongside the
  data entries, so the scan sees both.
- For each data file D (sequence S_d): gather applicable position-delete files
  (matching D's path, sequence > S_d) -> a sorted set of positions; and
  applicable equality-delete files (sequence > S_d) -> their rows.
- Read D through a **position-aware sink**: track the row ordinal, skip a row
  whose ordinal is in the position set or whose equality-column tuple matches an
  equality-delete row.

This needs the reader to either expose row ordinals to a sink, or accept a
skip-set. Reuse `ice_open_path` to open each delete file (a delete-file path is
opened here too -- same content-leak surface as data files).

## Sub-increments (each its own PR, each provable)

- **4a - position deletes. DONE.** `pq_read_rows` gained a sorted `skipPos` set
  (dropping rows by file ordinal, computed as sum-of-prior-row-group-rows + r);
  `PgColumnarReadParquetByFieldId` threads it. The walk grew a `collect_deletes`
  mode: the lister still refuses deletes, the scan collects position-delete
  entries (still refusing equality) and resolves each entry's data sequence
  number (inheriting the manifest's when null). `iceberg_scan` reads the
  position-delete Parquet files (by their reserved field ids 2147483546/545),
  and for each data file drops the ordinals its deletes name whose sequence
  number is greater than the data file's. Fixture is hand-crafted
  (`warehouse_del`, generator `gen_delete_fixture.py`) with `apply` / `noapply`
  (too-old) / `equality` variants. Removal proofs: defeating the reader skip
  keeps the deleted rows; defeating the sequence gate applies a too-old delete.
  PG17/18/19 (PG19 needed `TupleDescFinalize` on the manual pos-delete tupdesc)
  + ASAN; the Parquet family and 3a/3b/3c suites are unregressed.
- **4b - equality deletes.** Add equality evaluation on `equality_ids` columns.
- **4c - v3 deletion vectors (Puffin).** A new container format (Puffin) holding
  a roaring bitmap of deleted positions -- a decoder like the Avro one. Largest.

Held out: pruning/partition transforms (phase 5), object storage + REST (phase
6). Multiple delete files, and delete + data in one snapshot, are covered within
4a/4b.
