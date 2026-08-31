#!/usr/bin/env python3
# Generate a small, self-contained Apache Iceberg warehouse for the #388 phase 3b
# data-file resolver, plus an oracle for the live data files at the current
# snapshot. One append-only table, db.events.
#
# The warehouse is generated at a STABLE root (argv[2], default /tmp/pgc_ice_wh)
# and its metadata subtree is committed verbatim, so every embedded absolute path
# -- metadata.json's `location`, the manifest-list's manifest_path, the
# manifest's file_path -- shares that one recorded root. The reader rebases that
# recorded root onto wherever the fixture actually sits at read time, which is
# how a relocated Iceberg table is read. Only the metadata/ subtree is committed
# (the resolver lists data files from the manifests; it does not open them), so
# no Parquet data is checked in.
#
# The delete-refusal path is NOT generated here: pyiceberg 0.11.1 cannot write
# merge-on-read delete files (it warns and falls back to copy-on-write), so
# test/iceberg_data_files.sh crafts a content=1 manifest-list for that arm
# instead.
import os, sys, json, shutil
import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import NestedField, LongType, StringType, IntegerType
from pyiceberg.partitioning import PartitionSpec, PartitionField
from pyiceberg.transforms import IdentityTransform

OUT = sys.argv[1]                                   # fixtures/iceberg/warehouse
ROOT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/pgc_ice_wh"

shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT, exist_ok=True)
cat = SqlCatalog("c", uri=f"sqlite:///{ROOT}/cat.db", warehouse=f"file://{ROOT}")
cat.create_namespace("db")

schema = Schema(
    NestedField(1, "id", LongType(), required=False),
    NestedField(2, "region", StringType(), required=False),
    NestedField(3, "amount", IntegerType(), required=False),
)
spec = PartitionSpec(
    PartitionField(source_id=2, field_id=1000, transform=IdentityTransform(), name="region"))
data = pa.table({
    "id": pa.array([1, 2, 3, 4, 5], pa.int64()),
    "region": pa.array(["eu", "eu", "us", "us", "us"], pa.string()),
    "amount": pa.array([10, 20, 30, 40, 50], pa.int32()),
})

# db.events: append only -> current snapshot lists data files, no deletes
events = cat.create_table("db.events", schema=schema, partition_spec=spec)
events.append(data)

# copy just the table's metadata/ dir (metadata.json + avro), not data/
loc = events.metadata.location.replace("file://", "")
dst = os.path.join(OUT, "db", "events", "metadata")
shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(OUT, exist_ok=True)
shutil.copytree(os.path.join(loc, "metadata"), dst)

# oracle: the live data files of db.events at its current snapshot, as pyiceberg
# reports them (an independent writer). Basename + record_count + partition, the
# fields the resolver surfaces. Rebased paths are compared by basename.
io = events.io
oracle = {"recorded_root": ROOT, "data_files": []}
snap = events.current_snapshot()
for m in snap.manifests(io):
    for e in m.fetch_manifest_entry(io, discard_deleted=False):
        df = e.data_file
        oracle["data_files"].append({
            "file_basename": os.path.basename(df.file_path),
            "file_format": str(df.file_format).split(".")[-1],
            "record_count": df.record_count,
            "region": df.partition[0],
            "content": int(df.content),
            "status": int(e.status),
        })
oracle["data_files"].sort(key=lambda r: r["file_basename"])

with open(os.path.join(OUT, "expected_files.json"), "w") as f:
    json.dump(oracle, f, indent=2, sort_keys=True)

print("warehouse root:", ROOT)
print("events current-snapshot manifests:", len(snap.manifests(io)))
print("data files:", [r["file_basename"] for r in oracle["data_files"]])
print(json.dumps(oracle, indent=2, sort_keys=True))
