#!/usr/bin/env python3
# Generate a real Iceberg table with pyiceberg and extract its manifest-list and
# manifest Avro files as committed fixtures, plus an oracle report (the data-file
# list + per-file partition/metrics as the writer reports them). This is the
# independent oracle for the #388 step-1 Avro manifest decoder.
import os, sys, json, shutil, struct
import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import NestedField, LongType, StringType, IntegerType
from pyiceberg.partitioning import PartitionSpec, PartitionField
from pyiceberg.transforms import IdentityTransform

OUT = sys.argv[1]           # fixtures dir
WH = os.path.join(OUT, "_warehouse")
shutil.rmtree(WH, ignore_errors=True)
os.makedirs(WH, exist_ok=True)

cat = SqlCatalog("c", uri=f"sqlite:///{WH}/cat.db", warehouse=f"file://{WH}")
cat.create_namespace("db")

schema = Schema(
    NestedField(1, "id", LongType(), required=False),
    NestedField(2, "region", StringType(), required=False),
    NestedField(3, "amount", IntegerType(), required=False),
)
spec = PartitionSpec(
    PartitionField(source_id=2, field_id=1000, transform=IdentityTransform(), name="region"))
tbl = cat.create_table("db.events", schema=schema, partition_spec=spec)

# two partitions -> at least two data files, so the manifest has >1 entry with
# distinct partition values
data = pa.table({
    "id": pa.array([1, 2, 3, 4, 5], pa.int64()),
    "region": pa.array(["eu", "eu", "us", "us", "us"], pa.string()),
    "amount": pa.array([10, 20, 30, 40, 50], pa.int32()),
})
tbl.append(data)

snap = tbl.current_snapshot()
io = tbl.io
print("format-version:", tbl.format_version)
print("manifest_list:", snap.manifest_list)

# copy the manifest-list avro
os.makedirs(OUT, exist_ok=True)
ml_src = snap.manifest_list.replace("file://", "")
shutil.copyfile(ml_src, os.path.join(OUT, "manifest-list.avro"))

manifests = snap.manifests(io)
report = {"format_version": tbl.format_version,
          "manifest_list": "manifest-list.avro",
          "manifests": [], "entries": []}
for i, m in enumerate(manifests):
    mp = m.manifest_path.replace("file://", "")
    dst = f"manifest-{i}.avro"
    shutil.copyfile(mp, os.path.join(OUT, dst))
    report["manifests"].append({
        "fixture": dst,
        "added_files_count": m.added_files_count,
        "existing_files_count": m.existing_files_count,
        "deleted_files_count": m.deleted_files_count,
        "partition_spec_id": m.partition_spec_id,
        "content": int(m.content),
    })
    for e in m.fetch_manifest_entry(io, discard_deleted=False):
        df = e.data_file
        report["entries"].append({
            "manifest": dst,
            "status": int(e.status),
            "file_path_basename": os.path.basename(df.file_path),
            "file_format": str(df.file_format).split(".")[-1],
            "content": int(df.content),
            "record_count": df.record_count,
            "file_size_in_bytes": df.file_size_in_bytes,
            "partition": {"region": df.partition[0]},
        })

with open(os.path.join(OUT, "expected.json"), "w") as f:
    json.dump(report, f, indent=2, sort_keys=True)

# the manifest-list oracle: the manifest_file entries the snapshot points at
list_report = {"manifest_files": []}
for m in manifests:
    list_report["manifest_files"].append({
        "manifest_path_basename": os.path.basename(m.manifest_path),
        "manifest_length": m.manifest_length,
        "partition_spec_id": m.partition_spec_id,
        "content": int(m.content),
        "sequence_number": m.sequence_number,
        "min_sequence_number": m.min_sequence_number,
        "added_snapshot_id": m.added_snapshot_id,
        "added_files_count": m.added_files_count,
        "existing_files_count": m.existing_files_count,
        "deleted_files_count": m.deleted_files_count,
        "added_rows_count": m.added_rows_count,
        "existing_rows_count": m.existing_rows_count,
        "deleted_rows_count": m.deleted_rows_count,
    })
with open(os.path.join(OUT, "expected_list.json"), "w") as f:
    json.dump(list_report, f, indent=2, sort_keys=True)

# the table metadata.json (#388 phase 3a): copy the current metadata pointer and
# an oracle for its current snapshot. The committed metadata.json carries the
# real absolute warehouse paths pyiceberg wrote, rewritten to a neutral, stable
# root so the fixture is machine-independent (basenames, and the oracle, are
# unaffected; real relocation/rebasing is phase 3b).
md_src = tbl.metadata_location.replace("file://", "")
md_text = open(md_src).read().replace(f"file://{WH}", "file:///warehouse")
assert WH not in md_text, "warehouse path leaked into the committed metadata.json"
with open(os.path.join(OUT, "table.metadata.json"), "w") as f:
    f.write(md_text)

op = snap.summary.operation.value if snap.summary and snap.summary.operation else None
meta_oracle = {
    "current_snapshot_id": tbl.metadata.current_snapshot_id,
    "snapshot_id": snap.snapshot_id,
    "parent_snapshot_id": snap.parent_snapshot_id,
    "sequence_number": snap.sequence_number,
    "timestamp_ms": snap.timestamp_ms,
    "operation": op,
    "manifest_list_basename": os.path.basename(snap.manifest_list),
    "schema_id": snap.schema_id,
}
with open(os.path.join(OUT, "expected_meta.json"), "w") as f:
    json.dump(meta_oracle, f, indent=2, sort_keys=True)

# report the avro header of the first manifest so we know the codec/schema shape
with open(os.path.join(OUT, "manifest-0.avro"), "rb") as f:
    head = f.read(4)
print("manifest magic:", head)
print("entries:", len(report["entries"]))
print(json.dumps(report, indent=2, sort_keys=True))
