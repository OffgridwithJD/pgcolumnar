#!/usr/bin/env python3
# Independent-engine oracle for the #388 name-mapping fixtures (warehouse_nm).
#
# The fixtures are hand-crafted (an id-less pyarrow data file plus hand-encoded
# manifests and a metadata.json carrying schema.name-mapping.default). Both
# pyiceberg 0.11.1 and DuckDB's iceberg extension read a name-mapped id-less
# table, so the hand-derived oracle (all five rows) is checked against both.
#
# The engines need spec-complete metadata that the reduced fixtures omit on
# purpose, so each value arm is converted to a spec-complete twin first: the
# manifest and manifest list are re-encoded with fastavro under full Iceberg
# schemas (field-id annotations), and the metadata.json gains the fields the
# engines validate. The name mapping property and the id-less data file pass
# through unchanged.
#
# Run on the host (needs network once for pip and the DuckDB extension):
#   python3 -m venv V && V/bin/pip install fastavro duckdb pyarrow pyiceberg==0.11.1
#   V/bin/python test/fixtures/iceberg/crosscheck_nm.py
import fastavro
import json
import uuid
import os
import shutil
import sys

FX = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(FX, "warehouse_nm", "db")
ROOT = "/tmp/pgc_ice_nm"
DST = f"{ROOT}/db/t/metadata"

MF_SCHEMA = {"type": "record", "name": "manifest_file", "fields": [
    {"name": "manifest_path", "type": "string", "field-id": 500},
    {"name": "manifest_length", "type": "long", "field-id": 501},
    {"name": "partition_spec_id", "type": "int", "field-id": 502},
    {"name": "content", "type": "int", "field-id": 517},
    {"name": "sequence_number", "type": "long", "field-id": 515},
    {"name": "min_sequence_number", "type": "long", "field-id": 516},
    {"name": "added_snapshot_id", "type": "long", "field-id": 503},
    {"name": "added_files_count", "type": "int", "field-id": 504},
    {"name": "existing_files_count", "type": "int", "field-id": 505},
    {"name": "deleted_files_count", "type": "int", "field-id": 506},
    {"name": "added_rows_count", "type": "long", "field-id": 512},
    {"name": "existing_rows_count", "type": "long", "field-id": 513},
    {"name": "deleted_rows_count", "type": "long", "field-id": 514}]}

ME_SCHEMA = {"type": "record", "name": "manifest_entry", "fields": [
    {"name": "status", "type": "int", "field-id": 0},
    {"name": "sequence_number", "type": ["null", "long"], "field-id": 3, "default": None},
    {"name": "file_sequence_number", "type": ["null", "long"], "field-id": 4, "default": None},
    {"name": "data_file", "field-id": 2, "type": {"type": "record", "name": "r2", "fields": [
        {"name": "content", "type": "int", "field-id": 134},
        {"name": "file_path", "type": "string", "field-id": 100},
        {"name": "file_format", "type": "string", "field-id": 101},
        {"name": "partition", "field-id": 102,
         "type": {"type": "record", "name": "r102", "fields": []}},
        {"name": "record_count", "type": "long", "field-id": 103},
        {"name": "file_size_in_bytes", "type": "long", "field-id": 104}]}}]}

# arm -> (does it read? the AS-clause output names in order)
VALUE_ARMS = {
    "nmapply": ["id", "region", "amount"],
    "nmrename": ["ident", "region", "amount"],
    "nmalias": ["id", "region", "amount"],
    "nmsubset": ["id", "amount"],
}


def conv_manifest(src, out):
    recs = list(fastavro.reader(open(src, "rb")))
    outrecs = []
    for r in recs:
        df = r["data_file"]
        outrecs.append({
            "status": r["status"],
            "sequence_number": r.get("sequence_number"),
            "file_sequence_number": r.get("sequence_number"),
            "data_file": {
                "content": df["content"], "file_path": df["file_path"],
                "file_format": df["file_format"], "partition": {},
                "record_count": df["record_count"],
                "file_size_in_bytes": df["file_size_in_bytes"]}})
    with open(out, "wb") as fh:
        fastavro.writer(fh, ME_SCHEMA, outrecs,
                        metadata={"schema": json.dumps({"type": "struct", "fields": []}),
                                  "partition-spec": "[]", "partition-spec-id": "0",
                                  "format-version": "2", "content": "data"})


def main():
    shutil.rmtree(ROOT, ignore_errors=True)
    shutil.copytree(SRC, f"{ROOT}/db")

    import duckdb
    con = duckdb.connect()
    con.execute("INSTALL iceberg; LOAD iceberg;")
    from pyiceberg.table import StaticTable

    ok = True
    for tag, names in VALUE_ARMS.items():
        ml = list(fastavro.reader(open(f"{DST}/manifest-list-{tag}.avro", "rb")))
        outml = []
        for m in ml:
            base = os.path.basename(m["manifest_path"])
            conv = f"{DST}/pyc-{tag}-{base}"
            conv_manifest(f"{DST}/{base}", conv)
            m2 = dict(m)
            m2["manifest_path"] = f"file://{conv}"
            m2["manifest_length"] = os.path.getsize(conv)
            outml.append(m2)
        mlout = f"{DST}/pyc-{tag}-list.avro"
        with open(mlout, "wb") as fh:
            fastavro.writer(fh, MF_SCHEMA, outml, metadata={"format-version": "2"})
        md = json.load(open(f"{DST}/{tag}.metadata.json"))
        md["snapshots"][0]["manifest-list"] = f"file://{mlout}"
        md.setdefault("last-column-id", 3)
        md.setdefault("table-uuid", str(uuid.UUID(int=0)))
        md.setdefault("last-updated-ms", 0)
        md.setdefault("last-partition-id", 999)
        md.setdefault("last-sequence-number", 1)
        md.setdefault("sort-orders", [{"order-id": 0, "fields": []}])
        md.setdefault("default-sort-order-id", 0)
        p = f"{DST}/pyc-{tag}.metadata.json"
        json.dump(md, open(p, "w"))

        want = 5
        try:
            n = len(con.execute(f"SELECT * FROM iceberg_scan('{p}')").fetchall())
            dmark = "ok" if n == want else f"MISMATCH({n})"
        except Exception as ex:
            dmark = f"ERROR: {str(ex)[:120]}"
        try:
            t = StaticTable.from_metadata(p)
            m = len(t.scan().to_arrow().to_pylist())
            pmark = "ok" if m == want else f"MISMATCH({m})"
        except Exception as ex:
            pmark = f"ERROR: {str(ex)[:120]}"
        print(f"{tag}: duckdb={dmark} pyiceberg={pmark}")
        if dmark != "ok" or pmark != "ok":
            ok = False

    if not ok:
        print("CROSSCHECK FAILED")
        sys.exit(1)
    print(f"CROSSCHECK PASSED: {len(VALUE_ARMS)} value arms read by name in both engines")


if __name__ == "__main__":
    main()
