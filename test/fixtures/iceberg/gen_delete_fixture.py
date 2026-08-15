#!/usr/bin/env python3
# Generate a hand-crafted Apache Iceberg v2 table that carries POSITION DELETES,
# for #388 phase 4a. No available writer emits merge-on-read deletes (pyiceberg
# 0.11.1 falls back to copy-on-write), so the whole table is constructed: the
# data and position-delete Parquet files are written with pyarrow (real Parquet,
# real field ids), and the manifests, manifest list, and metadata.json are
# hand-encoded Avro / JSON so the data/delete sequence numbers are exact.
#
# Layout, all rooted at a stable recorded path so the committed fixture carries
# no machine-specific path (the reader rebases it at read time):
#
#   db/t/metadata/v1.metadata.json
#   db/t/metadata/manifest-list.avro   -> data manifest (content 0, seq 1)
#                                         delete manifest (content 1, seq 2)
#   db/t/metadata/data-manifest.avro   -> data.parquet   (content 0)
#   db/t/metadata/delete-manifest.avro -> posdel.parquet (content 1)
#   db/t/data/data.parquet             id/region/amount, 5 rows
#   db/t/data/posdel.parquet           (file_path, pos) dropping rows 1 and 3
#
# The oracle is the five data rows minus the two deleted positions.
import sys, os, json, shutil
import pyarrow as pa, pyarrow.parquet as pq

OUT = sys.argv[1]                                   # fixtures/iceberg/warehouse_del
ROOT = "/tmp/pgc_ice_del"                           # stable recorded root
LOC = f"file://{ROOT}/db/t"

shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(os.path.join(OUT, "db", "t", "metadata"))
os.makedirs(os.path.join(OUT, "db", "t", "data"))


# ---- Avro OCF encoding helpers --------------------------------------------
def zz(n):
    u = (n << 1) ^ (n >> 63) if n < 0 else (n << 1)
    out = bytearray()
    while True:
        b = u & 0x7f; u >>= 7
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


# a manifest_entry with a reduced data_file (the fields our decoder projects)
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
    return zz(status) + zz(1) + zz(seq) + zz(content) + s(path.encode()) + \
        s(fmt.encode()) + zz(rows) + zz(size)


def mfile(path, content, seq, snap, files, rows):
    return s(path.encode()) + zz(1000) + zz(0) + zz(content) + zz(seq) + zz(seq) + \
        zz(snap) + zz(files) + zz(0) + zz(0) + zz(rows) + zz(0) + zz(0)


# ---- the data and delete Parquet (real pyarrow) ---------------------------
data = pa.table({
    "id": pa.array([1, 2, 3, 4, 5], pa.int64()),
    "region": pa.array(["eu", "eu", "us", "us", "us"], pa.string()),
    "amount": pa.array([10, 20, 30, 40, 50], pa.int32()),
}, schema=pa.schema([
    pa.field("id", pa.int64(), metadata={b"PARQUET:field_id": b"1"}),
    pa.field("region", pa.string(), metadata={b"PARQUET:field_id": b"2"}),
    pa.field("amount", pa.int32(), metadata={b"PARQUET:field_id": b"3"}),
]))
pq.write_table(data, os.path.join(OUT, "db", "t", "data", "data.parquet"))

DATA_PATH = f"{LOC}/data/data.parquet"
DEL_PATH = f"{LOC}/data/posdel.parquet"
DELETED_POS = [1, 3]                                 # drop rows 1 and 3 (id 2, id 4)
posdel = pa.table({
    "file_path": pa.array([DATA_PATH] * len(DELETED_POS), pa.string()),
    "pos": pa.array(DELETED_POS, pa.int64()),
}, schema=pa.schema([
    pa.field("file_path", pa.string(), nullable=False,
             metadata={b"PARQUET:field_id": b"2147483546"}),
    pa.field("pos", pa.int64(), nullable=False,
             metadata={b"PARQUET:field_id": b"2147483545"}),
]))
pq.write_table(posdel, os.path.join(OUT, "db", "t", "data", "posdel.parquet"))

# ---- the manifests, manifest list, metadata -------------------------------
md = os.path.join(OUT, "db", "t", "metadata")
SNAP = 7766554433221100
DM = f"{LOC}/metadata/data-manifest.avro"
open(os.path.join(md, "data-manifest.avro"), "wb").write(
    ocf(ENTRY_SCHEMA, entry(1, 1, 0, DATA_PATH, "PARQUET", 5, 1000)))

schema = {"schema-id": 0, "type": "struct", "fields": [
    {"id": 1, "name": "id", "required": False, "type": "long"},
    {"id": 2, "name": "region", "required": False, "type": "string"},
    {"id": 3, "name": "amount", "required": False, "type": "int"}]}


def emit_variant(tag, del_content, del_seq):
    """Write a (delete manifest, manifest list, metadata) triple: a delete file
    of the given data_file content (1 position, 2 equality) at data sequence
    number del_seq, over the shared data manifest (content 0, seq 1)."""
    xm_name = f"delete-manifest-{tag}.avro"
    ml_name = f"manifest-list-{tag}.avro"
    open(os.path.join(md, xm_name), "wb").write(
        ocf(ENTRY_SCHEMA, entry(1, del_seq, del_content, DEL_PATH, "PARQUET",
                                len(DELETED_POS), 500)))
    xm = f"{LOC}/metadata/{xm_name}"
    sync = b"\x00" * 16
    meta = zz(2) + s(b"avro.schema") + s(MFILE_SCHEMA) + s(b"avro.codec") + s(b"null") + zz(0)
    ml = b"Obj\x01" + meta + sync
    for rec in (mfile(DM, 0, 1, SNAP, 1, 5),
                mfile(xm, 1, del_seq, SNAP, 1, len(DELETED_POS))):
        ml += zz(1) + zz(len(rec)) + rec + sync
    open(os.path.join(md, ml_name), "wb").write(ml)
    metadata = {
        "format-version": 2, "location": LOC, "current-schema-id": 0,
        "schemas": [schema], "current-snapshot-id": SNAP,
        "snapshots": [{
            "snapshot-id": SNAP, "sequence-number": max(2, del_seq),
            "timestamp-ms": 0,
            "manifest-list": f"{LOC}/metadata/{ml_name}",
            "summary": {"operation": "overwrite"}, "schema-id": 0}],
    }
    open(os.path.join(md, f"{tag}.metadata.json"), "w").write(json.dumps(metadata))


# apply:   a position delete at seq 2 > the data's seq 1 -> the rows are dropped
# noapply: a position delete at seq 1, NOT greater than the data's -> no-op
# equality: an equality (content 2) delete -> refused, not applied
emit_variant("apply", 1, 2)
emit_variant("noapply", 1, 1)
emit_variant("equality", 2, 2)

# oracle: the surviving rows (id, region, amount), deleted positions removed
rows = [(1, "eu", 10), (2, "eu", 20), (3, "us", 30), (4, "us", 40), (5, "us", 50)]
survive = [r for i, r in enumerate(rows) if i not in DELETED_POS]
oracle = {"deleted_positions": DELETED_POS,
          "surviving": [{"id": r[0], "region": r[1], "amount": r[2]} for r in survive],
          "data_seq": 1, "delete_seq": 2}
open(os.path.join(OUT, "expected_deletes.json"), "w").write(json.dumps(oracle, indent=2))
print("surviving rows:", oracle["surviving"])
print("deleted positions:", DELETED_POS)
