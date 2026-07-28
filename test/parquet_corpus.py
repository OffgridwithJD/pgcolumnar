#!/usr/bin/env python3
#
# Seed corpus for the Parquet decode fuzzer (test/fuzz_parquet.sh, issue #214).
#
# Every file here is VALID. The fuzzer mutates copies of them; a seed that is
# already malformed teaches the mutator nothing, because the reader rejects it
# at the first check and never reaches the code under test.
#
# The corpus aims at breadth of decoder state rather than volume: each physical
# type, each encoding the writer will choose, each supported codec, nesting, and
# the multi-file and partitioned layouts. A mutation is only as interesting as
# the path the surrounding bytes reach.
#
# Usage:  python3 test/parquet_corpus.py OUTDIR
# Writes OUTDIR/<name>.parquet and prints one "<name> <path>" line per file.
#
import os
import sys

import pyarrow as pa
import pyarrow.parquet as pq


def w(outdir, name, table, **kw):
    """Write one seed and report it. Codec failures are skipped, not fatal:
    the reader's codec support and this pyarrow's may differ, and a codec we
    cannot write is one we do not need a seed for."""
    path = os.path.join(outdir, name + ".parquet")
    try:
        pq.write_table(table, path, **kw)
    except Exception as e:              # noqa: BLE001 - report and continue
        print("SKIP %s (%s)" % (name, type(e).__name__), file=sys.stderr)
        return
    print("%s %s" % (name, path))


def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)

    n = 200

    # --- one file per physical/logical type, so a mutation lands in a decoder
    # that is actually reached rather than in a type the file never uses.
    w(outdir, "int32", pa.table({"a": pa.array(range(n), pa.int32())}))
    w(outdir, "int64", pa.table({"a": pa.array(range(n), pa.int64())}))
    w(outdir, "int16", pa.table({"a": pa.array(range(n), pa.int16())}))
    w(outdir, "float", pa.table({"a": pa.array([i * 0.5 for i in range(n)], pa.float32())}))
    w(outdir, "double", pa.table({"a": pa.array([i * 0.25 for i in range(n)], pa.float64())}))
    w(outdir, "bool", pa.table({"a": pa.array([i % 2 == 0 for i in range(n)], pa.bool_())}))
    w(outdir, "string", pa.table({"a": pa.array(["v%d" % i for i in range(n)])}))
    w(outdir, "binary", pa.table({"a": pa.array([b"\x00\x01%d" % i for i in range(n)], pa.binary())}))
    w(outdir, "date32", pa.table({"a": pa.array([18000 + i for i in range(n)], pa.date32())}))
    w(outdir, "ts_us", pa.table({"a": pa.array([1600000000000000 + i for i in range(n)],
                                               pa.timestamp("us"))}))
    w(outdir, "ts_tz", pa.table({"a": pa.array([1600000000000000 + i for i in range(n)],
                                               pa.timestamp("us", tz="UTC"))}))
    w(outdir, "time64", pa.table({"a": pa.array([i * 1000 for i in range(n)], pa.time64("us"))}))
    w(outdir, "decimal", pa.table({"a": pa.array([i for i in range(n)], pa.decimal128(18, 4))}))

    # FLBA has its own width handling in the reader and its own bounds.
    w(outdir, "flba", pa.table({"a": pa.array([b"%04d" % i for i in range(n)],
                                              pa.binary(4))}))

    # --- null shapes: the definition-level decoder is a separate path.
    w(outdir, "nulls_some", pa.table({"a": pa.array(
        [None if i % 3 == 0 else i for i in range(n)], pa.int32())}))
    w(outdir, "nulls_all", pa.table({"a": pa.array([None] * n, pa.int32())}))

    # --- low cardinality forces dictionary encoding; high entropy forces plain.
    w(outdir, "dict_text", pa.table({"a": pa.array(["k%d" % (i % 4) for i in range(n)])}))
    w(outdir, "plain_text", pa.table({"a": pa.array(
        ["%064x" % (i * 2654435761) for i in range(n)])}), use_dictionary=False)

    # --- nesting: struct and list drive repetition levels and the schema walk,
    # which is where the second #210 recursion lived.
    w(outdir, "struct", pa.table({"a": pa.array(
        [{"x": i, "y": "s%d" % i} for i in range(n)],
        pa.struct([("x", pa.int32()), ("y", pa.string())]))}))
    w(outdir, "list", pa.table({"a": pa.array(
        [[i, i + 1] for i in range(n)], pa.list_(pa.int32()))}))
    w(outdir, "list_nested", pa.table({"a": pa.array(
        [[[i], [i + 1]] for i in range(n)], pa.list_(pa.list_(pa.int32())))}))
    w(outdir, "struct_deep", pa.table({"a": pa.array(
        [{"b": {"c": {"d": i}}} for i in range(n)],
        pa.struct([("b", pa.struct([("c", pa.struct([("d", pa.int32())]))]))]))}))

    # --- codecs: each has its own page-decompression path and its own way to
    # disagree with the declared uncompressed size.
    wide = pa.table({"a": pa.array(range(n), pa.int32()),
                     "b": pa.array(["p%d" % (i % 17) for i in range(n)])})
    for codec in ("snappy", "gzip", "zstd", "lz4", "brotli", "none"):
        w(outdir, "codec_" + codec, wide, compression=codec)

    # --- multi-row-group and multi-page, so offsets and counts have to agree
    # across more than one of each.
    big = pa.table({"a": pa.array(range(20000), pa.int32()),
                    "b": pa.array(["r%d" % (i % 91) for i in range(20000)])})
    w(outdir, "rowgroups", big, row_group_size=1000)
    w(outdir, "pages", big, data_page_size=1024, row_group_size=20000)

    # --- v2 data pages take a different header union member entirely.
    w(outdir, "pagev2", wide, data_page_version="2.0")

    # --- wide schema: the leaf-count bound and the column-chunk list length are
    # indexed against each other.
    w(outdir, "wide64", pa.table(
        {("c%d" % c): pa.array(range(50), pa.int32()) for c in range(64)}))

    # --- an empty file still has a footer and a schema to walk.
    w(outdir, "empty", pa.table({"a": pa.array([], pa.int32())}))


if __name__ == "__main__":
    main()
