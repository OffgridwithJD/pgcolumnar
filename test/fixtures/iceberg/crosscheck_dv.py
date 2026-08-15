#!/usr/bin/env python3
# Independent-engine oracle for the #388 phase 4c deletion-vector fixtures.
#
# The warehouse_del DV fixtures are hand-crafted (pyroaring bitmaps wrapped in
# hand-built Puffin files and hand-encoded Avro manifests), so the expected
# survivors in expected_deletes.json are hand-derived. Unlike the 4b equality
# case, TWO independent implementations can read deletion vectors: pyiceberg
# (0.11.1 applies Puffin DVs in its scan) and DuckDB's iceberg extension. This
# script checks the hand-derived oracle against both.
#
# Both engines require spec-complete metadata that the reduced fixtures omit on
# purpose, so each variant is converted to a spec-complete twin first: the
# manifests and manifest lists are re-encoded with fastavro under full Iceberg
# schemas (field-id annotations, the v3 DV fields 143/144/145), and the
# metadata.json gains the fields the engines validate. The delete semantics
# under test (sequence numbers, DV bytes, the Puffin files) pass through
# unchanged.
#
# Not part of the test suite (needs network once for pip and the DuckDB
# extension); run on the host:
#
#   python3 -m venv V && V/bin/pip install fastavro duckdb pyarrow pyiceberg==0.11.1 pyroaring
#   V/bin/python test/fixtures/iceberg/crosscheck_dv.py
import fastavro, json, uuid, os, shutil, sys

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
        {"name": "referenced_data_file", "field-id": 143, "default": None,
         "type": ["null", "string"]},
        {"name": "content_offset", "field-id": 144, "default": None,
         "type": ["null", "long"]},
        {"name": "content_size_in_bytes", "field-id": 145, "default": None,
         "type": ["null", "long"]},
    ]}}]}

VARIANTS = ["dvapply", "dvnoapply", "dvsupersede", "dvother", "dvwide",
            "dvrun", "dvbitset", "dvtwo"]

# Known engine deviations from the spec, pinned so a fixed engine flips the
# check and gets noticed. On each arm the OTHER engine agrees with the spec
# and with expected_deletes.json:
# - dvnoapply: DuckDB (extension 45163a28) applies a DV whose data sequence
#   number is LOWER than the data file's, ignoring the spec's <= gate ("data
#   file's data sequence number is less than or equal to the deletion
#   vector's"). pyiceberg honors the gate.
# - dvsupersede: pyiceberg 0.11.1 UNIONS position-delete files with the DV;
#   the spec's scope rule applies a position delete file only when "there is
#   no deletion vector that must be applied to the data file" (writers must
#   fold old deletes into the DV, so conforming tables cannot tell the
#   difference; this fixture deliberately breaks the writer obligation to
#   expose reader behavior). DuckDB implements supersede.
DEVIATIONS = {
    ("duckdb", "dvnoapply"): [1, 3, 5],
    ("pyiceberg", "dvsupersede"): [1, 3, 5],
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
                "file_size_in_bytes": df["file_size_in_bytes"],
                "referenced_data_file": df.get("referenced_data_file"),
                "content_offset": df.get("content_offset"),
                "content_size_in_bytes": df.get("content_size_in_bytes"),
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

    import duckdb
    con = duckdb.connect()
    con.execute("INSTALL iceberg; LOAD iceberg;")
    from pyiceberg.table import StaticTable

    expected = json.load(open(os.path.join(FX, "warehouse_del",
                                           "expected_deletes.json")))["dv_surviving"]
    got_duck = {}
    got_pyi = {}
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
        md.setdefault("last-column-id", 3)
        md.setdefault("table-uuid", str(uuid.UUID(int=0)))
        md.setdefault("last-updated-ms", 0)
        md.setdefault("last-partition-id", 1000)
        md.setdefault("last-sequence-number", md["snapshots"][0]["sequence-number"])
        md.setdefault("default-spec-id", 0)
        md.setdefault("partition-specs", [{"spec-id": 0, "fields": []}])
        md.setdefault("sort-orders", [{"order-id": 0, "fields": []}])
        md.setdefault("default-sort-order-id", 0)
        md.setdefault("next-row-id", 100)
        p = f"{DST}/pyc-{tag}.metadata.json"
        json.dump(md, open(p, "w"))
        try:
            rows = con.execute(
                f"SELECT id FROM iceberg_scan('{p}') ORDER BY id").fetchall()
            got_duck[tag] = [int(r[0]) for r in rows]
        except Exception as ex:
            got_duck[tag] = f"ERROR: {str(ex)[:160]}"
        try:
            t = StaticTable.from_metadata(p)
            got_pyi[tag] = sorted(int(r["id"])
                                  for r in t.scan().to_arrow().to_pylist())
        except Exception as ex:
            got_pyi[tag] = f"ERROR: {str(ex)[:160]}"
        wantd = DEVIATIONS.get(("duckdb", tag), expected[tag])
        wantp = DEVIATIONS.get(("pyiceberg", tag), expected[tag])
        okd = "ok" if got_duck[tag] == wantd else "MISMATCH"
        okp = "ok" if got_pyi[tag] == wantp else "MISMATCH"
        if ("duckdb", tag) in DEVIATIONS:
            okd += " (pinned deviation)"
        if ("pyiceberg", tag) in DEVIATIONS:
            okp += " (pinned deviation)"
        print(f"{tag}: expected={expected[tag]}")
        print(f"    duckdb={got_duck[tag]} {okd}")
        print(f"    pyiceberg={got_pyi[tag]} {okp}")

    bad = [t for t in VARIANTS
           if got_duck[t] != DEVIATIONS.get(("duckdb", t), expected[t])
           or got_pyi[t] != DEVIATIONS.get(("pyiceberg", t), expected[t])]
    if bad:
        print(f"CROSSCHECK FAILED: {bad}")
        sys.exit(1)
    print(f"CROSSCHECK PASSED: {len(VARIANTS)} variants; every arm matches at "
          f"least one spec-conforming engine, deviations pinned")


if __name__ == "__main__":
    main()
