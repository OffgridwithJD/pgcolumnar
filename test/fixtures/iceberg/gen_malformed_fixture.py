#!/usr/bin/env python3
# Hand-crafted MALFORMED Iceberg fixtures for the read-path robustness suite
# (test/iceberg_malformed.sh). Each targets a defect the adversarial re-audit of
# #388 phase-4a (#644) found and proved on the bench: a crafted manifest that the
# reader must refuse cleanly (never crash), and a faithful v1 manifest the reader
# must read (never wrongly refuse). No available writer emits these shapes, so the
# manifests / manifest lists / metadata.json are hand-encoded Avro / JSON and the
# data Parquet is a real pyarrow file. All paths use a stable recorded root so the
# committed fixture carries no machine-specific path; the reader rebases at read
# time and the suite relocates the tree first.
#
# Variants written under OUT:
#   nullpath      v2 manifest whose data_file.file_path is union[null,string]=null
#                 -> was a NULL-deref SIGSEGV in iceberg_scan/iceberg_data_files
#   nullpath_ctl  same, file_path present (control: reads one file / five rows)
#   arrayfield/evil.avro  an Avro OCF whose record schema "fields" element is a
#                 JSON array [[0]] -> was an assert-abort / OOB heap read
#   arrayfield/good.avro  same framing, a well-formed field object (control)
import sys, os, json, shutil
import pyarrow as pa, pyarrow.parquet as pq

OUT = sys.argv[1]                                   # fixtures/iceberg/warehouse_malformed
ROOT = "/tmp/pgc_ice_malformed"                     # stable recorded root
shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(OUT)


# ---- Avro OCF encoding helpers (as in gen_delete_fixture.py) --------------
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


def ocf(schema_json, records):
    sync = b"\x00" * 16
    meta = zz(2) + s(b"avro.schema") + s(schema_json) + s(b"avro.codec") + s(b"null") + zz(0)
    out = b"Obj\x01" + meta + sync
    for rec in records:
        out += zz(1) + zz(len(rec)) + rec + sync
    return out


ICE_FIELDS = [
    {"id": 1, "name": "id", "required": False, "type": "long"},
    {"id": 2, "name": "region", "required": False, "type": "string"},
    {"id": 3, "name": "amount", "required": False, "type": "int"}]
SCHEMA = {"schema-id": 0, "type": "struct", "fields": ICE_FIELDS}
SNAP = 4242


def write_data_parquet(dest):
    data = pa.table({
        "id": pa.array([1, 2, 3, 4, 5], pa.int64()),
        "region": pa.array(["eu", "eu", "us", "us", "us"], pa.string()),
        "amount": pa.array([10, 20, 30, 40, 50], pa.int32()),
    }, schema=pa.schema([
        pa.field("id", pa.int64(), metadata={b"PARQUET:field_id": b"1"}),
        pa.field("region", pa.string(), metadata={b"PARQUET:field_id": b"2"}),
        pa.field("amount", pa.int32(), metadata={b"PARQUET:field_id": b"3"}),
    ]))
    pq.write_table(data, dest, row_group_size=2)


def metadata_json(loc, ml_name, fmt_version, snap_seq):
    m = {"format-version": fmt_version, "location": loc,
         "current-snapshot-id": SNAP,
         "snapshots": [{"snapshot-id": SNAP, "timestamp-ms": 0,
                        "manifest-list": f"{loc}/metadata/{ml_name}",
                        "summary": {"operation": "append"}}]}
    if fmt_version == 1:
        m["schema"] = {"type": "struct", "fields": ICE_FIELDS}
    else:
        m["current-schema-id"] = 0
        m["schemas"] = [SCHEMA]
        m["snapshots"][0]["sequence-number"] = snap_seq
        m["snapshots"][0]["schema-id"] = 0
    return json.dumps(m)


# ================================================== nullpath (v2, #2 crash) ==
# data_file.file_path declared union[null,string]; the null branch (index 0)
# decodes to a NULL path the reader must refuse, not dereference.
ENTRY_NULLPATH = json.dumps({"type": "record", "name": "manifest_entry", "fields": [
    {"name": "status", "type": "int"},
    {"name": "sequence_number", "type": ["null", "long"]},
    {"name": "data_file", "type": {"type": "record", "name": "df", "fields": [
        {"name": "content", "type": "int"},
        {"name": "file_path", "type": ["null", "string"]},
        {"name": "file_format", "type": "string"},
        {"name": "record_count", "type": "long"},
        {"name": "file_size_in_bytes", "type": "long"}]}}]}).encode()

MFILE_V2 = json.dumps({"type": "record", "name": "manifest_file", "fields": [
    {"name": "manifest_path", "type": "string"},
    {"name": "manifest_length", "type": "long"},
    {"name": "partition_spec_id", "type": "int"},
    {"name": "content", "type": "int"},
    {"name": "sequence_number", "type": ["null", "long"]},
    {"name": "min_sequence_number", "type": "long"},
    {"name": "added_snapshot_id", "type": "long"}]}).encode()


def mfile_v2(path, content, seq, snap):
    return s(path.encode()) + zz(1000) + zz(0) + zz(content) + \
        (zz(1) + zz(seq)) + zz(seq) + zz(snap)


def build_nullpath(name, file_path_present):
    root = os.path.join(OUT, name)
    md = os.path.join(root, "db", "t", "metadata")
    dd = os.path.join(root, "db", "t", "data")
    os.makedirs(md); os.makedirs(dd)
    loc = f"file://{ROOT}/{name}/db/t"
    write_data_parquet(os.path.join(dd, "data.parquet"))
    if file_path_present:
        fp = (zz(1) + s(f"{loc}/data/data.parquet".encode()))     # union branch 1
    else:
        fp = zz(0)                                                # union branch 0: null
    ent = zz(1) + (zz(1) + zz(5)) + zz(0) + fp + s(b"PARQUET") + zz(5) + zz(1000)
    open(os.path.join(md, "dm.avro"), "wb").write(ocf(ENTRY_NULLPATH, [ent]))
    open(os.path.join(md, "ml.avro"), "wb").write(
        ocf(MFILE_V2, [mfile_v2(f"{loc}/metadata/dm.avro", 0, 5, SNAP)]))
    open(os.path.join(md, "t.metadata.json"), "w").write(
        metadata_json(loc, "ml.avro", 2, 5))


build_nullpath("nullpath", False)
build_nullpath("nullpath_ctl", True)


# ================================== arrayfield (bare Avro OCF, #7 crash) ==
af = os.path.join(OUT, "arrayfield")
os.makedirs(af)
evil = json.dumps({"type": "record", "name": "manifest_entry",
                   "fields": [[0]]}).encode()          # a field element that is an ARRAY
good = json.dumps({"type": "record", "name": "manifest_entry",
                   "fields": [{"name": "status", "type": "int"}]}).encode()
open(os.path.join(af, "evil.avro"), "wb").write(ocf(evil, []))
open(os.path.join(af, "good.avro"), "wb").write(ocf(good, []))

print("malformed fixtures written under", OUT)
