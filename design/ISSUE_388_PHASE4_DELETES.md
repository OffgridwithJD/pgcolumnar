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

**Sequence-number ordering is the correctness crux, and the rule differs by
delete kind** (Iceberg spec, Scan Planning):

- a **position** delete applies when `datafile.sequence_number <=
  delete.sequence_number` -- i.e. `delete.sequence_number >=
  datafile.sequence_number`. The `<=` (not strict `<`) is deliberate: a position
  delete affects data written in the **same commit** or earlier, so a delete and
  the rows it removes may share a sequence number (a single-commit upsert).
- an **equality** delete applies when `datafile.sequence_number <
  delete.sequence_number` -- strictly lower (it targets pre-existing data only).

Get this wrong and the table reads subtly wrong -- deletes bleed onto newer data,
or fail to apply to same-commit or older data. Gate **per kind**, never one
shared operator (position deletes also match `file_path`). Getting this backwards
-- a strict `>` for position deletes -- silently dropped same-commit deletes and
was the blocking bug of the first 4a review; do not repeat it in 4b.

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

A sequence-number arm is essential precisely because the oracle is ours, and it
must sit on the boundary: craft the "apply" delete at a sequence number EQUAL to
the data file's (a position delete must apply -- the case a strict `>` wrongly
excludes) and the "no-apply" delete at a strictly LOWER one (must not apply), so
the `>=` rule is load-bearing, not decorative.

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
  number is `>=` the data file's (position-delete rule; equal = same commit).
  Fixture is hand-crafted (`warehouse_del`, generator `gen_delete_fixture.py`)
  with `apply` (equal seq) / `noapply` (strictly older) / `inherit` / `equality`
  / `wrongpath` / `badseq` variants. Removal proofs: defeating the reader skip
  keeps the deleted rows; reverting the gate to strict `>` reds the equal-seq
  apply; dropping the path match applies a wrong-file delete.
  PG17/18/19 (PG19 needed `TupleDescFinalize` on the manual pos-delete tupdesc)
  + ASAN; the Parquet family and 3a/3b/3c suites are unregressed.
- **4b - equality deletes.** Add equality evaluation on `equality_ids` columns.
  Designed below.
- **4c - v3 deletion vectors (Puffin).** A new container format (Puffin) holding
  a roaring bitmap of deleted positions -- a decoder like the Avro one. Largest.

Held out: pruning/partition transforms (phase 5), object storage + REST (phase
6). Multiple delete files, and delete + data in one snapshot, are covered within
4a/4b.

## 4b design - equality deletes

Spec rules (iceberg.apache.org/spec, Scan Planning + Equality Delete Files;
verified against the spec text 2026-08-14, local copy in the session scratchpad):

- **Sequence gate is STRICT `<`**: an equality delete applies to a data file iff
  `datafile.sequence_number < delete.sequence_number`. At EQUAL sequence numbers
  it does NOT apply -- the deliberate opposite of the position-delete `<=` (no
  same-commit carve-out: this is how "delete old row by key + insert new row" in
  one commit avoids the delete eating the new row). Gate per kind, never shared.
- **Matching**: a data row is deleted if, for ANY row of an applicable equality
  delete file, the values of ALL `equality_ids` columns are equal. Null matches
  null (`IS NULL` semantics, not SQL `=`). Matching is by FIELD ID; column names
  are irrelevant. A delete file may carry extra columns beyond `equality_ids`;
  they are payload and MUST be ignored for matching.
- **`equality_ids`** (data_file field 135, `list<int>`): required when
  `content = 2` (null/empty there is corrupt metadata). Restricted to primitive,
  non-float/double fields (never inside maps/lists).
- **Partition scoping**: a delete file written with an UNPARTITIONED spec is
  global; one written with a partitioned spec applies only to data files with the
  same (spec id, partition tuple). We do not decode typed partitions until phase
  5, so: resolve the delete manifest's `partition_spec_id` against metadata.json
  `partition-specs`; empty `fields` = global (apply); non-empty = refuse `0A000`
  (partition-scoped equality deletes are phase-5 work; applying them globally
  would over-delete); unresolvable spec id = `XX001`. Position deletes never
  consult this (their per-file path match subsumes partition scope).

### Architecture: probe pass reusing skipPos (no reader changes)

Everything an equality delete needs already exists as of 4a; 4b composes it:

1. **Decode `equality_ids`** in `av_decode_data_file` (nullable `array<int>` per
   the Avro block protocol already implemented in `av_skip`), onto
   `PgColumnarAvroManifestEntry`. Thread the enclosing manifest's
   `partition_spec_id` to the walk callback (the entry itself does not carry it).
2. **Collect** content=2 entries in the scan walk (drop the 0A000 at the old
   refusal point; the lister still refuses all deletes). Validate: PARQUET only
   (0A000), non-empty equality_ids (XX001), unpartitioned spec (0A000 above).
3. **Read each equality-delete file once, upfront** (they are global): a manual
   tupdesc built from the file's `equality_ids`, with Postgres types derived from
   the table's CURRENT SCHEMA in metadata.json (`type` per field id): int->int4,
   long->int8, string->text, boolean->bool, date->date; any other type is
   refused 0A000 (never silently unapplied). Types come from the schema, not the
   user's AS clause, so a delete on an unprojected column still applies. Rows are
   kept as Datum arrays (per-file scratch context reset, survivors datumCopy'd
   out -- the 4a `ice_read_pos_deletes` memory pattern).
4. **Per data file D**: filter delete files to `E.seq > D.seq`. If any, run a
   PROBE pass: read ONLY the union of their equality columns from D via
   `PgColumnarReadParquetByFieldId` subset projection (a whole-file read, so the
   tuplestore row index IS the file ordinal -- the same ordinal skipPos uses).
   Test each row against each delete row (AND over that file's ids, null==null
   via each column's type-cache equality operator); matching ordinals join the
   position-delete ordinals in one sorted, deduplicated skipPos for the full
   read. Cost: applicable equality deletes read D's key columns twice (footer
   parse + key decode); acceptable for v1, noted in docs.
5. **Cross-check**: the full read returns `probe_rows - |skip ordinals <
   probe_rows|` rows; a mismatch is XX001 (catches ordinal-accounting drift
   between the two passes).

Known refusals / loud errors, all provable by fixture arm:
- partitioned-spec equality delete: 0A000 (over-deleting is the alternative);
- equality column of an unmapped type (e.g. timestamp): 0A000, before any file
  is opened;
- equality column in the schema but ABSENT from an older data file: the reader's
  existing 22023 (`no Parquet column has field id`); the spec says such a column
  reads as null -- a later increment can add missing-id->null projection; until
  then the error is loud, never wrong;
- content=2 with null/empty equality_ids: XX001;
- delete-file paths go through `ice_open_path` like every opened file (the
  boundary arm reads a real file outside the root and asserts the boundary's
  SQLSTATE, per the 4a lesson).

### 4b fixture arms (generator `gen_delete_fixture.py`, additive only)

Data stays `data.parquet` (ids 1..5, region eu/eu/us/us/us, amount 10..50, seq
5). New: `eqdel-*.parquet` delete files, `data2.parquet` (id 6 region NULL, id 7
region 'eu') for the null arm. Arms, each its own metadata variant:

| arm | delete | seq | expect |
|---|---|---|---|
| eqapply | ids=[1], rows id 2,4 | 6 | survivors 1,3,5 |
| eqboundary | same file | 5 (== data) | ALL rows survive (strict `<`) |
| eqmulti | ids=[1,2], rows (3,eu),(4,us) | 6 | (3,eu) no match: AND, not OR; survivors 1,2,3,5 |
| eqextra | file has id+amount cols, ids=[1], amount values wrong | 6 | extra col ignored; survivors 1,3,4,5 |
| eqnull | ids=[2], row region=NULL, over data+data2 | 6 | id 6 dropped (null==null), id 7 kept |
| eqtwo | two files: ids=[1] row 5; ids=[2] row eu | 6 | union of files; survivors 3,4 |
| eqmixed | posdel (ords 1,3) seq 5 + eq ids=[1] row 5 | 6 | pos+eq union; survivors 1,3 |
| eqnoids | content=2, equality_ids null | 6 | XX001 |
| eqpart | delete manifest spec-id 1 (partitioned) | 6 | 0A000 |
| eqtype | ids=[8] (schema field "created" timestamp) | 6 | 0A000 |
| eqmissing | ids=[9] (schema field "extra" long, absent from parquet) | 6 | 22023 |
| eqescape | delete file path outside the table root | 6 | boundary SQLSTATE |

Removal proofs: flip `<` to `<=` -> eqboundary reds (the arm that distinguishes
the two rules); skip the null-equality branch -> eqnull reds; match on all file
columns instead of equality_ids -> eqextra reds; drop the union across files ->
eqtwo reds; drop the pos+eq merge -> eqmixed reds; derive types from the AS
clause -> the unprojected-column arm reds (eqapply is run projecting a column
subset). The equality metadata variants carry `partition-specs`
(`[{"spec-id":0,"fields":[]}]`, plus a partitioned spec 1 for eqpart); existing
4a variants are untouched (the scoping lookup runs only for content=2).
