#!/usr/bin/env python3
# Generate an Apache Iceberg warehouse partitioned by day() of a DATE column, for
# the Iceberg FDW temporal-pruning suite (#388, phase 5c). A day() partition of a
# date stores the day as an int (days since the 1970 Unix epoch), one date per
# file; the FDW must convert a PostgreSQL date constant (days since 2000) by the
# +10957 epoch offset before comparing. Column metrics are disabled so day()
# pruning is the sole mechanism (as with the truncate fixture).
#
# db.byday: id bigint, dt date; partitioned by day(dt).
#   2020-01-01 -> id 1 ; 2020-01-02 -> id 2 ; 2020-03-15 -> id 3 (three files).
#
# Run in a host venv with pyiceberg==0.11.1 + pyarrow + pyiceberg-core.
import os
import sys
import shutil
import datetime
import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import NestedField, LongType, DateType
from pyiceberg.partitioning import PartitionSpec, PartitionField
from pyiceberg.transforms import DayTransform

OUT = sys.argv[1]
ROOT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/pgc_ice_day"

shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT, exist_ok=True)
cat = SqlCatalog("c", uri=f"sqlite:///{ROOT}/cat.db", warehouse=f"file://{ROOT}")
cat.create_namespace("db")

schema = Schema(
    NestedField(1, "id", LongType(), required=False),
    NestedField(2, "dt", DateType(), required=False),
)
spec = PartitionSpec(
    PartitionField(source_id=2, field_id=1000, transform=DayTransform(), name="dt_day"))
dates = [datetime.date(2020, 1, 1), datetime.date(2020, 1, 2), datetime.date(2020, 3, 15)]
data = pa.table({
    "id": pa.array([1, 2, 3], pa.int64()),
    "dt": pa.array(dates, pa.date32()),
})

t = cat.create_table("db.byday", schema=schema, partition_spec=spec,
                     properties={"write.metadata.metrics.default": "none"})
t.append(data)

loc = t.metadata.location.replace("file://", "")
shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(os.path.join(OUT, "db", "byday"))
shutil.copytree(os.path.join(loc, "metadata"),
                os.path.join(OUT, "db", "byday", "metadata"))
shutil.copytree(os.path.join(loc, "data"),
                os.path.join(OUT, "db", "byday", "data"))
print("day root:", ROOT, "dates:", [str(d) for d in dates])
