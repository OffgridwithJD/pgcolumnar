#!/usr/bin/env python3
# Generate an Apache Iceberg warehouse partitioned by bucket[8] of an int column,
# for the Iceberg FDW bucket-pruning suite (#388, phase 5c). Iceberg stores the
# BUCKET (a murmur3-derived int), not the source value, so pruning an equality
# predicate requires computing bucket(const) with the exact Iceberg hash. This
# fixture is the cross-engine oracle: pyiceberg wrote the buckets, so if the C
# murmur3/bucket is wrong the same-oracle read reds.
#
# db.byid: id bigint, val text, amount int; partitioned by bucket[8](id).
# ids 1..8 land in whatever buckets murmur3 says; the suite reads the mapping
# out of the manifest and drives WHERE id = k against it.
#
# Both metadata/ and data/ are committed (the FDW opens data files). Run in a
# host venv with pyiceberg==0.11.1 + pyarrow.
import os
import sys
import shutil
import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import NestedField, LongType, StringType, IntegerType
from pyiceberg.partitioning import PartitionSpec, PartitionField
from pyiceberg.transforms import BucketTransform

OUT = sys.argv[1]
ROOT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/pgc_ice_bucket"

shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT, exist_ok=True)
cat = SqlCatalog("c", uri=f"sqlite:///{ROOT}/cat.db", warehouse=f"file://{ROOT}")
cat.create_namespace("db")

schema = Schema(
    NestedField(1, "id", LongType(), required=False),
    NestedField(2, "val", StringType(), required=False),
    NestedField(3, "amount", IntegerType(), required=False),
)
spec = PartitionSpec(
    PartitionField(source_id=1, field_id=1000, transform=BucketTransform(8), name="id_bucket"))
ids = list(range(1, 9))
data = pa.table({
    "id": pa.array(ids, pa.int64()),
    "val": pa.array([f"v{i}" for i in ids], pa.string()),
    "amount": pa.array([i * 10 for i in ids], pa.int32()),
})

t = cat.create_table("db.byid", schema=schema, partition_spec=spec)
t.append(data)

loc = t.metadata.location.replace("file://", "")
shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(os.path.join(OUT, "db", "byid"))
shutil.copytree(os.path.join(loc, "metadata"),
                os.path.join(OUT, "db", "byid", "metadata"))
shutil.copytree(os.path.join(loc, "data"),
                os.path.join(OUT, "db", "byid", "data"))

bt = BucketTransform(8).transform(LongType())
print("bucket root:", ROOT)
print("id -> bucket[8]:", {i: bt(i) for i in ids})
