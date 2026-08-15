# #388 name mapping - reading id-less Iceberg data files

Phases 1-4 read an Iceberg table whose data files carry Parquet field ids. A
data file written outside Iceberg (a migrated Hive/Spark dataset, "imported
data files" in the spec) carries no field ids, and `iceberg_scan` errors on it
today (`22023`, "the Parquet file carries no field ids"). This increment adds
the spec's fallback: bind such a file's columns by name through the table's
`schema.name-mapping.default` property.

## The spec (Column Projection ladder; verified 2026-08-15 against spec.md)

Columns are selected by field id. For "field ids which are not present in a data
file", a reader resolves each in order: (1) identity-partition metadata, (2)
`schema.name-mapping.default`, (3) `initial-default`, (4) `null`. Name mapping
is rung 2, and does exactly one job: supply the id->physical-column binding for
a file that carries no ids. It changes none of the other rungs.

- The mapping is a **table property** (`metadata.json` `properties` map), key
  `schema.name-mapping.default`, value a JSON **string** holding an array of
  `{names: string[], field-id?: int, fields?: [...]}` objects that mirror the
  schema tree (struct children / list `element` / map `key`,`value` via
  `fields`). A `.` in a name is a literal name, never a path separator.
- Matching is by name, case-sensitive; names must be unique across the mapping.
- There is **no spec-defined positional fallback**: an id-less file with no
  mapping resolves every column to null by the letter of the ladder, so
  erroring (today's behavior) is a legitimate, conformant choice. We keep
  erroring when there is no mapping; we only add the binding when there is one.

## Scope

Flat top-level scalar columns, matching the field-id binder's existing scope
(`build_imp_targets_by_field_id` refuses composite/repeated output columns). We
flatten the mapping's **top-level** entries to (name -> id) pairs; nested
`fields` are ignored, since we do not project nested columns anyway. Nested
name mapping is a later increment if nested projection ever lands.

## Architecture (least-invasive seam)

The reader already binds by matching each output column's requested field id to
the file leaf whose `sc->field_id` equals it. Name mapping is modelled as
exactly what the spec calls it -- "map field id to columns without field id" --
by **synthesizing ids for the file's id-less leaves** before that scan runs,
then letting the existing binder work unchanged:

- `PgColumnarReadParquetByFieldId` gains a name->id table
  (`const char *const *nm_names, const int *nm_ids, int nm_count`; all NULL/0
  to disable). Every existing caller (the posdel/eqdel/DV reads by reserved or
  known ids) passes NULL and is unaffected; only the data-file read supplies it.
- In `build_imp_targets_by_field_id`, build a local `eff_id[ncols]` =
  `leaves[j].sc->field_id`, then for each leaf still id-less (`< 0`), look its
  `sc->name` up in the name->id table and overlay the mapped id. `eff_id[]` (not
  the cached `sc->field_id`) drives the "any ids?" check and the per-column id
  scan. Nothing downstream changes; a file that carries ids ignores the table.
- The "no field ids" error fires only when `eff_id` has none AND no mapping
  resolved any, and its message now names `schema.name-mapping.default`.

Iceberg side: a new `ice_name_mapping(root, path, &names, &ids, &n)` reads
`properties -> schema.name-mapping.default` (a jbvString), re-parses it as
jsonb, and flattens each top-level entry to one (name, id) pair per name in its
`names` array. A name appearing twice is corrupt (`XX001`, the spec's
uniqueness rule). Absent property -> n = 0 (today's error path preserved). It is
passed into the data-file read in `pgcolumnar_iceberg_scan`.

## Fixtures (hand-crafted, deterministic, additive: `warehouse_nm`)

Both pyiceberg 0.11.1 and DuckDB's iceberg extension read a name-mapped id-less
table (proven live), so the hand-derived oracle gets two independent checks. But
pyiceberg's own writer is non-deterministic (random uuids/timestamps), so the
committed fixture is hand-crafted like the delete fixtures: a real id-less
pyarrow `data.parquet` (no `PARQUET:field_id` metadata) plus hand-encoded
manifest / manifest-list / metadata.json, the metadata carrying
`"properties": {"schema.name-mapping.default": "[...]"}`. A generator
`gen_name_mapping_fixture.py` writes it; `test/iceberg_name_mapping.sh` reads it.

| arm | shape | expect |
|---|---|---|
| nmapply | id-less data.parquet (id,region,amount), mapping ids 1/2/3 by name | all 5 rows read by name |
| nmrename | mapping name differs from the AS-clause output name (schema field renamed) | still reads: output name -> schema id -> file name |
| nmalias | mapping lists two names for id 1; file uses the second | alias resolves |
| nmsubset | project only (id, amount) from the id-less file | name binding under projection |
| nmnomap | id-less file, NO name-mapping property | refused 22023, message names the property |
| nmdup | mapping lists one name twice under different ids | XX001 |
| nmmissing | mapping lacks a name for a projected column | that column errors (22023, absent id) |

Removal proofs: delete the eff_id overlay -> nmapply reds (back to 22023);
resolve by output name instead of the schema-mapped id -> nmrename reds; take
only the first mapping name -> nmalias reds; drop the uniqueness check -> nmdup
reds. Value arms cross-checked against pyiceberg and DuckDB.
