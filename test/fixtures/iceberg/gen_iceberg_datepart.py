#!/usr/bin/env python3
# Generate a small Apache Iceberg warehouse identity-partitioned by a DATE column,
# for the Iceberg FDW pruning suite (#388, phase 5a). A date partition is the
# case that exposed the over-prune bug: the FDW cannot convert a date partition
# cell, so it must NOT prune on it (read the file in full), never drop rows.
#
# db.byday: id bigint, dt date, amount int; partitioned by identity(dt).
#   dt=2020-01-01 -> ids 1,2   dt=2020-02-01 -> ids 3,4
# Both the metadata/ and data/ subtrees are committed (the FDW opens the data
# files), rooted at a stable path the reader rebases at read time.
#
# Run in a host venv with pyiceberg==0.11.1 + pyarrow (pypi is not reachable from
# the build containers). See design/ISSUE_388_PRUNING.md.
import os
import sys
import shutil
import datetime
import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import NestedField, LongType, DateType, IntegerType
from pyiceberg.partitioning import PartitionSpec, PartitionField
from pyiceberg.transforms import IdentityTransform

OUT = sys.argv[1]                                   # fixtures/iceberg/warehouse_datepart
ROOT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/pgc_ice_datepart"

shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT, exist_ok=True)
cat = SqlCatalog("c", uri=f"sqlite:///{ROOT}/cat.db", warehouse=f"file://{ROOT}")
cat.create_namespace("db")

schema = Schema(
    NestedField(1, "id", LongType(), required=False),
    NestedField(2, "dt", DateType(), required=False),
    NestedField(3, "amount", IntegerType(), required=False),
)
spec = PartitionSpec(
    PartitionField(source_id=2, field_id=1000, transform=IdentityTransform(), name="dt"))
data = pa.table({
    "id": pa.array([1, 2, 3, 4], pa.int64()),
    "dt": pa.array([datetime.date(2020, 1, 1), datetime.date(2020, 1, 1),
                    datetime.date(2020, 2, 1), datetime.date(2020, 2, 1)],
                   pa.date32()),
    "amount": pa.array([10, 20, 30, 40], pa.int32()),
})

t = cat.create_table("db.byday", schema=schema, partition_spec=spec)
t.append(data)

# commit both metadata/ and data/ (the FDW opens the data files)
loc = t.metadata.location.replace("file://", "")
shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(os.path.join(OUT, "db", "byday"))
shutil.copytree(os.path.join(loc, "metadata"),
                os.path.join(OUT, "db", "byday", "metadata"))
shutil.copytree(os.path.join(loc, "data"),
                os.path.join(OUT, "db", "byday", "data"))

print("datepart warehouse root:", ROOT)
print("metadata:", os.listdir(os.path.join(OUT, "db", "byday", "metadata")))
