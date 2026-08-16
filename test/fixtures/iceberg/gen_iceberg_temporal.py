#!/usr/bin/env python3
# Generate Apache Iceberg warehouses for the FDW coarse temporal-pruning suite
# (#388, phase 5d): year(), month(), hour(), and day() on a TIMESTAMP column.
# Unlike day() on a DATE (exact, one date per bucket), these transforms are
# coarse: one bucket spans a range of source values, so the reference bucket
# integers below are what the filter compares a mapped predicate constant to.
#
# Iceberg stores each partition value as the transform's integer bucket, from the
# 1970 epoch, UTC: year = years-since-1970, month = months-since-1970,
# day = days-since-1970, hour = hours-since-1970. Column metrics are disabled so
# the temporal transform is the sole pruning mechanism (as for day/truncate).
#
#   db.byyear   : id bigint, ts timestamp; year(ts).  2020,2021,2023  -> one/file
#   db.bymonth  : id bigint, ts timestamp; month(ts). 2021-01,-02,-06
#   db.bydayts  : id bigint, ts timestamp; day(ts).   2021-03-01,-02,-05
#   db.byhour   : id bigint, ts timestamp; hour(ts).  2021-03-01 00,01,05 h
#
# Run in a host venv with pyiceberg==0.11.1 + pyarrow + pyiceberg-core.
import os
import sys
import shutil
import datetime
import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import NestedField, LongType, TimestampType
from pyiceberg.partitioning import PartitionSpec, PartitionField
from pyiceberg.transforms import (YearTransform, MonthTransform, DayTransform,
                                  HourTransform)

OUT = sys.argv[1]
ROOT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/pgc_ice_temporal"

shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT, exist_ok=True)
cat = SqlCatalog("c", uri=f"sqlite:///{ROOT}/cat.db", warehouse=f"file://{ROOT}")
cat.create_namespace("db")


def dt(y, mo, d, h=0):
    return datetime.datetime(y, mo, d, h, 0, 0)


def make(name, transform, rows):
    schema = Schema(
        NestedField(1, "id", LongType(), required=False),
        NestedField(2, "ts", TimestampType(), required=False),
    )
    spec = PartitionSpec(
        PartitionField(source_id=2, field_id=1000, transform=transform,
                       name="ts_part"))
    data = pa.table({
        "id": pa.array([r[0] for r in rows], pa.int64()),
        "ts": pa.array([r[1] for r in rows], pa.timestamp("us")),
    })
    t = cat.create_table(f"db.{name}", schema=schema, partition_spec=spec,
                         properties={"write.metadata.metrics.default": "none"})
    t.append(data)
    loc = t.metadata.location.replace("file://", "")
    dstroot = os.path.join(OUT, "db", name)
    shutil.rmtree(dstroot, ignore_errors=True)
    os.makedirs(dstroot)
    shutil.copytree(os.path.join(loc, "metadata"),
                    os.path.join(dstroot, "metadata"))
    shutil.copytree(os.path.join(loc, "data"), os.path.join(dstroot, "data"))
    # report the stored partition bucket integers, from the manifest scan
    parts = []
    for task in t.scan().plan_files():
        parts.append(task.file.partition[0])
    print(f"{name}: buckets={sorted(parts)} rows={[r[0] for r in rows]}")


make("byyear", YearTransform(),
     [(1, dt(2020, 6, 1)), (2, dt(2021, 6, 1)), (3, dt(2023, 6, 1))])
make("bymonth", MonthTransform(),
     [(1, dt(2021, 1, 15)), (2, dt(2021, 2, 15)), (3, dt(2021, 6, 15))])
make("bydayts", DayTransform(),
     [(1, dt(2021, 3, 1)), (2, dt(2021, 3, 2)), (3, dt(2021, 3, 5))])
make("byhour", HourTransform(),
     [(1, dt(2021, 3, 1, 0)), (2, dt(2021, 3, 1, 1)), (3, dt(2021, 3, 1, 5))])
print("temporal root:", ROOT)
