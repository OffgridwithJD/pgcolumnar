#!/usr/bin/env python3
# Generate a hand-crafted Apache Iceberg table whose data file carries NO
# Parquet field ids, read through a schema.name-mapping.default table property
# (#388 name mapping). An id-less data file is what an Iceberg "imported data
# file" (a migrated Hive/Spark dataset) looks like; the reader must bind its
# columns by name through the mapping instead of by id.
#
# Deterministic and additive, like gen_delete_fixture.py: the data Parquet is a
# real pyarrow file (written with NO PARQUET:field_id metadata), and the
# manifest, manifest list, and metadata.json are hand-encoded Avro / JSON with a
# stable recorded root, so the committed fixture regenerates byte-identically
# and the reader rebases the paths at read time.
#
# Layout under OUT (test/fixtures/iceberg/warehouse_nm):
#   db/t/data/data.parquet         id-less columns id/region/amount, 5 rows
#   db/t/data/data-alias.parquet   id-less columns rid/region/amount (alias arm)
#   db/t/metadata/data-manifest.avro       -> data.parquet
#   db/t/metadata/data-manifest-alias.avro -> data-alias.parquet
#   db/t/metadata/manifest-list-<tag>.avro
#   db/t/metadata/<tag>.metadata.json      one per arm, carrying the mapping
import sys
import os
import json
import shutil
import pyarrow as pa
import pyarrow.parquet as pq

OUT = sys.argv[1]                                   # fixtures/iceberg/warehouse_nm
ROOT = "/tmp/pgc_ice_nm"                            # stable recorded root
LOC = f"file://{ROOT}/db/t"

shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(os.path.join(OUT, "db", "t", "metadata"))
os.makedirs(os.path.join(OUT, "db", "t", "data"))
md = os.path.join(OUT, "db", "t", "metadata")


# ---- Avro OCF encoding helpers (as in gen_delete_fixture.py) ---------------
def zz(n):
    u = (n << 1) ^ (n >> 63) if n < 0 else (n << 1)
    out = bytearray()
    while True:
        b = u & 0x7f
        u >>= 7
        out.append(b | 0x80 if u else b)
        if not u:
            break
    return bytes(out)


def s(bs):
    return zz(len(bs)) + bs


def ocf(schema_json, record_bytes):
    sync = b"\x00" * 16
    meta = zz(2) + s(b"avro.schema") + s(schema_json) + s(b"avro.codec") + s(b"null") + zz(0)
    return b"Obj\x01" + meta + sync + zz(1) + zz(len(record_bytes)) + record_bytes + sync


ENTRY_SCHEMA = json.dumps({"type": "record", "name": "manifest_entry", "fields": [
    {"name": "status", "type": "int"},
    {"name": "sequence_number", "type": ["null", "long"]},
    {"name": "data_file", "type": {"type": "record", "name": "df", "fields": [
        {"name": "content", "type": "int"},
        {"name": "file_path", "type": "string"},
        {"name": "file_format", "type": "string"},
        {"name": "record_count", "type": "long"},
        {"name": "file_size_in_bytes", "type": "long"}]}}]}).encode()

MFILE_SCHEMA = json.dumps({"type": "record", "name": "manifest_file", "fields": [
    {"name": "manifest_path", "type": "string"},
    {"name": "manifest_length", "type": "long"},
    {"name": "partition_spec_id", "type": "int"},
    {"name": "content", "type": "int"},
    {"name": "sequence_number", "type": "long"},
    {"name": "min_sequence_number", "type": "long"},
    {"name": "added_snapshot_id", "type": "long"},
    {"name": "added_files_count", "type": "int"},
    {"name": "existing_files_count", "type": "int"},
    {"name": "deleted_files_count", "type": "int"},
    {"name": "added_rows_count", "type": "long"},
    {"name": "existing_rows_count", "type": "long"},
    {"name": "deleted_rows_count", "type": "long"}]}).encode()


def entry(status, seq, content, path, fmt, rows, size):
    return zz(status) + (zz(1) + zz(seq)) + zz(content) + s(path.encode()) + \
        s(fmt.encode()) + zz(rows) + zz(size)


def mfile(path, content, seq, snap, files, rows):
    return s(path.encode()) + zz(1000) + zz(0) + zz(content) + zz(seq) + zz(seq) + \
        zz(snap) + zz(files) + zz(0) + zz(0) + zz(rows) + zz(0) + zz(0)


# ---- the id-less data Parquet (real pyarrow, NO field-id metadata) ---------
ROWS = [(1, "eu", 10), (2, "eu", 20), (3, "us", 30), (4, "us", 40), (5, "us", 50)]


def write_idless(name, id_col):
    """An id-less parquet with columns (id_col, region, amount). No field is
    given PARQUET:field_id metadata, so every column reads as field_id = -1."""
    t = pa.table({
        id_col: pa.array([r[0] for r in ROWS], pa.int64()),
        "region": pa.array([r[1] for r in ROWS], pa.string()),
        "amount": pa.array([r[2] for r in ROWS], pa.int32()),
    })
    pq.write_table(t, os.path.join(OUT, "db", "t", "data", name), row_group_size=2)
    return f"{LOC}/data/{name}"


DATA = write_idless("data.parquet", "id")
DATA_ALIAS = write_idless("data-alias.parquet", "rid")

SNAP = 5544332211009988
SEQ = 1
DM = f"{LOC}/metadata/data-manifest.avro"
DMA = f"{LOC}/metadata/data-manifest-alias.avro"
open(os.path.join(md, "data-manifest.avro"), "wb").write(
    ocf(ENTRY_SCHEMA, entry(1, SEQ, 0, DATA, "PARQUET", 5, 1000)))
open(os.path.join(md, "data-manifest-alias.avro"), "wb").write(
    ocf(ENTRY_SCHEMA, entry(1, SEQ, 0, DATA_ALIAS, "PARQUET", 5, 1000)))


def emit(tag, fields, mapping, dm=DM):
    """Write a (manifest-list, metadata.json) pair for one arm. `fields` is the
    schema fields list; `mapping` is the schema.name-mapping.default value (a
    Python object serialized to the JSON *string* the property holds), or None
    to omit the property entirely."""
    ml_name = f"manifest-list-{tag}.avro"
    sync = b"\x00" * 16
    meta = zz(2) + s(b"avro.schema") + s(MFILE_SCHEMA) + s(b"avro.codec") + s(b"null") + zz(0)
    ml = b"Obj\x01" + meta + sync
    rec = mfile(dm, 0, SEQ, SNAP, 1, 5)
    ml += zz(1) + zz(len(rec)) + rec + sync
    open(os.path.join(md, ml_name), "wb").write(ml)
    props = {} if mapping is None else {"schema.name-mapping.default": json.dumps(mapping)}
    metadata = {
        "format-version": 2, "location": LOC, "current-schema-id": 0,
        "schemas": [{"schema-id": 0, "type": "struct", "fields": fields}],
        "partition-specs": [{"spec-id": 0, "fields": []}], "default-spec-id": 0,
        "properties": props, "current-snapshot-id": SNAP,
        "snapshots": [{"snapshot-id": SNAP, "sequence-number": SEQ,
                       "timestamp-ms": 0,
                       "manifest-list": f"{LOC}/metadata/{ml_name}",
                       "summary": {"operation": "append"}, "schema-id": 0}],
    }
    open(os.path.join(md, f"{tag}.metadata.json"), "w").write(json.dumps(metadata))


SCHEMA_STD = [{"id": 1, "name": "id", "required": False, "type": "long"},
              {"id": 2, "name": "region", "required": False, "type": "string"},
              {"id": 3, "name": "amount", "required": False, "type": "int"}]
MAP_STD = [{"field-id": 1, "names": ["id"]},
           {"field-id": 2, "names": ["region"]},
           {"field-id": 3, "names": ["amount"]}]

# nmapply: the id-less file binds by name; all 5 rows read
emit("nmapply", SCHEMA_STD, MAP_STD)

# nmrename: the schema field for id 1 is named "ident" (the table was renamed
# after the file was written), the mapping carries the OLD file name "id", the
# file column is still "id". Reading proves output name -> schema id -> mapping
# name -> file column, not output name -> file column.
emit("nmrename",
     [{"id": 1, "name": "ident", "required": False, "type": "long"},
      {"id": 2, "name": "region", "required": False, "type": "string"},
      {"id": 3, "name": "amount", "required": False, "type": "int"}],
     [{"field-id": 1, "names": ["id"]},
      {"field-id": 2, "names": ["region"]},
      {"field-id": 3, "names": ["amount"]}])

# nmalias: id 1 has two mapping names; the file uses the second ("rid")
emit("nmalias", SCHEMA_STD,
     [{"field-id": 1, "names": ["id", "rid"]},
      {"field-id": 2, "names": ["region"]},
      {"field-id": 3, "names": ["amount"]}],
     dm=DMA)

# nmsubset: project only (id, amount); name binding under projection
emit("nmsubset", SCHEMA_STD, MAP_STD)

# nmnomap: an id-less file with NO name-mapping property -> refused, naming it
emit("nmnomap", SCHEMA_STD, None)

# nmdup: the name "id" appears under two field ids -> corrupt (uniqueness)
emit("nmdup", SCHEMA_STD,
     [{"field-id": 1, "names": ["id"]},
      {"field-id": 2, "names": ["id"]},
      {"field-id": 3, "names": ["amount"]}])

# nmmissing: the mapping has no name for "amount"; projecting amount errors
emit("nmmissing", SCHEMA_STD,
     [{"field-id": 1, "names": ["id"]},
      {"field-id": 2, "names": ["region"]}])

oracle = {"rows": [{"id": r[0], "region": r[1], "amount": r[2]} for r in ROWS]}
open(os.path.join(OUT, "expected.json"), "w").write(json.dumps(oracle, indent=2))
print("name-mapping fixtures written under", OUT)
