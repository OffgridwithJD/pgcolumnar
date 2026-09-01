#!/usr/bin/env python3
# Generate an Apache Iceberg warehouse partitioned by truncate[100] of an int
# column, for the Iceberg FDW truncate-pruning suite (#388, phase 5c). A
# truncate[W] partition is order-preserving, so a range predicate prunes: a
# file's stored truncate value V bounds its rows to [V, V+W). pyiceberg wrote the
# partition values, so a green same-oracle read validates the reader.
#
# db.bytr: id bigint, amount int; partitioned by truncate[100](amount).
#   amounts 10,40 -> V=0 ; 130,160 -> V=100 ; 250 -> V=200 (three files).
#
# Run in a host venv with pyiceberg==0.11.1 + pyarrow + pyiceberg-core.
import os
import sys
import shutil
import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import NestedField, LongType, IntegerType
from pyiceberg.partitioning import PartitionSpec, PartitionField
from pyiceberg.transforms import TruncateTransform

OUT = sys.argv[1]
ROOT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/pgc_ice_trunc"

shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT, exist_ok=True)
cat = SqlCatalog("c", uri=f"sqlite:///{ROOT}/cat.db", warehouse=f"file://{ROOT}")
cat.create_namespace("db")

schema = Schema(
    NestedField(1, "id", LongType(), required=False),
    NestedField(2, "amount", IntegerType(), required=False),
)
spec = PartitionSpec(
    PartitionField(source_id=2, field_id=1000, transform=TruncateTransform(100), name="amount_tr"))
amounts = [10, 40, 130, 160, 250]
data = pa.table({
    "id": pa.array(list(range(1, len(amounts) + 1)), pa.int64()),
    "amount": pa.array(amounts, pa.int32()),
})

# Disable column metrics so the manifest carries no lower/upper bounds. Metrics
# pruning would otherwise subsume truncate pruning (a file's real [min,max] is
# inside its truncate range [V, V+W)), hiding whether truncate pruning works.
t = cat.create_table("db.bytr", schema=schema, partition_spec=spec,
                     properties={"write.metadata.metrics.default": "none"})
t.append(data)

loc = t.metadata.location.replace("file://", "")
shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(os.path.join(OUT, "db", "bytr"))
shutil.copytree(os.path.join(loc, "metadata"),
                os.path.join(OUT, "db", "bytr", "metadata"))
shutil.copytree(os.path.join(loc, "data"),
                os.path.join(OUT, "db", "bytr", "data"))

tr = TruncateTransform(100).transform(IntegerType())
print("trunc root:", ROOT)
print("amount -> truncate[100]:", {a: tr(a) for a in amounts})
