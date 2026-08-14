# #388 phase 3c - field-id projection through the Parquet reader

Phase 2 of the #388 plan is "Field IDs through the Parquet reader, with name
mapping as fallback. Useful to us independently of Iceberg." The parsing half
landed in #613 (thrift field 9 -> `PqSchemaCol.field_id`, `-1` sentinel). This is
the **using** half, which #613 deliberately deferred until it had a caller rather
than ship an unused resolution API. The caller now exists: the Iceberg
data-file list (#637) needs each Parquet file's columns resolved to the table
schema by field id, because Iceberg selects columns by id, not by name or
position (a data file written before a rename still carries the old name).

Delivered as its own PR first (this doc), independently of Iceberg, then wired
into an Iceberg scan.

## The semantic difference from today's binding

`build_imp_targets()` binds a tuple descriptor to a Parquet file **positionally**:
a single `lf` counter walks the file's leaves in order, and the final identity
check `lf == pf->ncols` requires the target to expand to *exactly* the file's
leaf count. That is 1:1 by position.

Field-id resolution is **projection**: bind each output column to the file leaf
whose `field_id` matches, read a *subset* of the file's columns, in the output's
order not the file's. The `lf == ncols` identity does not hold (you may read 2 of
5 columns), and the order is driven by the request, not the file. So this is a
separate binding path, not a tweak to the positional loop -- conflating them
would weaken the positional identity check that a whole suite relies on.

## Surface (this PR)

A new overload:

```sql
SELECT * FROM pgcolumnar.read_parquet(path, field_ids => ARRAY[7, 3])
  AS t(a int, b text);
```

`field_ids[i]` is the Parquet field id to bind output column `i` to. The array
length must equal the column-definition-list length. This reads only the two
named leaves, in the given order, regardless of their position in the file.

Scope of this PR, kept tight because it touches the mature reader:
- **Flat top-level scalars only.** Each requested id must resolve to exactly one
  top-level leaf (`max_rep == 0`, not nested). A target that is an array or
  composite in field-id mode is refused (`0A000` feature_not_supported) -- Iceberg
  v1 tables here are flat; nested field-id projection is a later step.
- **Unique ids.** A requested id absent from the file's top-level leaves, or
  matching more than one, is an error (`22023` / `42702` ambiguous) -- never a
  silent wrong column.
- **No id in the file.** If the file carries no field ids at all (every leaf
  `field_id == -1`), field-id mode errors and points at the positional overload.
  Name-mapping fallback (the plan's documented fallback for id-less files) is the
  immediate follow-on PR, not bundled here.

## Implementation

`build_imp_targets_by_field_id(tupdesc, pf, field_ids, n, &leaves, &ntops)`, a
sibling of `build_imp_targets` that reuses the same `ImpTop` / `ImpLeaf` output
structures (so `pq_read_rows` and the projection/skip machinery downstream are
unchanged), but:
1. builds a `field_id -> top-level leaf index` map over the file once, erroring on
   a duplicate id;
2. for each output attribute, looks up its requested id -> leaf index, validates
   the leaf is a non-repeated scalar of a compatible physical type, and binds
   `ImpTop{kind=IMP_SCALAR, firstLeaf=that index, nleaves=1}`;
3. skips the `lf == ncols` identity check (projection reads a subset).

`pq_read_rows` already decodes only the leaves the bound tops reference (the
projection path keys off `tops[t].firstLeaf`), so reading a subset needs no
change there -- confirm with a test that an unread column is never decoded.

`pgcolumnar_read_parquet` gains the optional second argument; when present it
calls the field-id binder instead of the positional one. The single-file helper
`pq_read_file_into` grows a `const int *field_ids, int nfield` pair threaded
through (NULL = positional, unchanged).

## Tests (`test/native_parquet_fieldid.sh`)

Independent writer: pyarrow, ids **out of order and disjoint from position**
(e.g. columns a,b,c with field ids 7,3,12), same technique as #613's schema arm --
a reader fabricating ids from position cannot pass.
- **Projection + reorder.** `field_ids => ARRAY[12,7]` AS `t(c int, a int)` returns
  the id-12 and id-7 columns, in that order, values matching a positional oracle
  read of the full file. RED first (no such overload on main).
- **Removal proof.** Positional binding (drop the field-id path) returns the wrong
  columns -> the value arm reds. And: bind `ARRAY[3]` AS `t(b text)` alone, assert
  only the id-3 column chunk is touched (projection reads a subset).
- **Refusals**, each its SQLSTATE: an absent id, a duplicate id in the file, a
  nested/array target, an id-less file (points at positional). Backend survives
  each.
- Matrix PG17/18/19 + ASAN (a binding/decode change earns the sanitizer).

## Then: the Iceberg scan (follow-on PR, 3c end-to-end)

`pgcolumnar.iceberg_scan(metadata_path) AS t(...)`: resolve the data files
(#637), read the table's current schema from metadata.json (name -> field id),
map each output column's name to its field id, and read each data file through
this field-id path, streaming rows. **Reuse `ice_open_path`** to open each data
file (the 3b review's symlink boundary -- a data-file path is opened here, so a
traversal would be a content leak). Deletes already refused upstream by
`iceberg_data_files`. That PR is where field-id projection becomes the Iceberg
read it was built for.
