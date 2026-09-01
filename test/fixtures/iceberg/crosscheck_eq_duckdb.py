#!/usr/bin/env python3
# Independent-engine oracle for the #388 phase 4b equality-delete fixtures.
#
# The warehouse_del fixtures are hand-crafted (no available writer emits
# merge-on-read deletes), so the expected survivors in expected_deletes.json
# are hand-derived. This script checks them against a fully independent
# implementation: DuckDB's iceberg extension. pyiceberg 0.11.1 cannot serve
# as the oracle; it refuses to READ equality deletes (apache/iceberg#6568).
#
# DuckDB requires spec-complete metadata that the reduced fixtures omit on
# purpose (field-id annotations inside the Avro schemas, last-column-id and
# friends in metadata.json), so the script first converts each variant into a
# spec-complete twin: it re-encodes the manifests and manifest lists with
# fastavro under full Iceberg schemas, carrying over every value, and fills the
# metadata.json fields DuckDB validates. The delete semantics under test
# (sequence numbers, equality_ids, the Parquet files) pass through unchanged.
#
# Not part of the test suite: it needs network access once (pip packages and
# the DuckDB iceberg extension), so it runs on the host, not in the container.
#
#   python3 -m venv V && V/bin/pip install fastavro duckdb pyarrow
#   V/bin/python test/fixtures/iceberg/crosscheck_eq_duckdb.py
#
# Verified 2026-08-14 (DuckDB iceberg extension, pyarrow 25.0.1): all seven
# value variants match expected_deletes.json's eq_surviving, including the
# strict-< boundary (eqboundary keeps all rows) and null matching (eqnull
# drops only the null-region row).
import fastavro, json, uuid, os, shutil, sys

import duckdb

FX = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(FX, "warehouse_del", "db")
ROOT = "/tmp/pgc_ice_del"        # the fixtures' recorded root
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
        {"name": "file_size_in_bytes", "type": "long", "field-id": 104},
        {"name": "equality_ids", "field-id": 135, "default": None,
         "type": ["null", {"type": "array", "items": "int", "element-id": 136}]},
    ]}}]}

VARIANTS = ["eqapply", "eqboundary", "eqmulti", "eqextra", "eqnull", "eqtwo", "eqmixed"]


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
                "file_size_in_bytes": df["file_size_in_bytes"],
                "equality_ids": df.get("equality_ids"),
            }})
    is_del = any(x["data_file"]["content"] for x in outrecs)
    with open(out, "wb") as fh:
        fastavro.writer(fh, ME_SCHEMA, outrecs,
                        metadata={"schema": json.dumps({"type": "struct", "fields": []}),
                                  "partition-spec": "[]", "partition-spec-id": "0",
                                  "format-version": "2",
                                  "content": "deletes" if is_del else "data"})


def main():
    shutil.rmtree(ROOT, ignore_errors=True)
    shutil.copytree(SRC, f"{ROOT}/db")

    con = duckdb.connect()
    con.execute("INSTALL iceberg; LOAD iceberg;")

    expected = json.load(open(os.path.join(FX, "warehouse_del",
                                           "expected_deletes.json")))["eq_surviving"]
    got = {}
    for tag in VARIANTS:
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
        md.setdefault("last-column-id", 9)
        md.setdefault("table-uuid", str(uuid.UUID(int=0)))
        md.setdefault("last-updated-ms", 0)
        md.setdefault("last-partition-id", 1000)
        md.setdefault("last-sequence-number", md["snapshots"][0]["sequence-number"])
        md.setdefault("default-spec-id", 0)
        md.setdefault("partition-specs", [{"spec-id": 0, "fields": []}])
        md.setdefault("sort-orders", [{"order-id": 0, "fields": []}])
        md.setdefault("default-sort-order-id", 0)
        p = f"{DST}/pyc-{tag}.metadata.json"
        json.dump(md, open(p, "w"))
        rows = con.execute(
            f"SELECT id FROM iceberg_scan('{p}') ORDER BY id").fetchall()
        got[tag] = [int(r[0]) for r in rows]
        marker = "ok" if got[tag] == expected[tag] else "MISMATCH"
        print(f"{tag}: duckdb={got[tag]} expected={expected[tag]} {marker}")

    if got != expected:
        print("CROSSCHECK FAILED")
        sys.exit(1)
    print(f"CROSSCHECK PASSED: {len(VARIANTS)} variants match an independent engine")


if __name__ == "__main__":
    main()
