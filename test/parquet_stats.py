#!/usr/bin/env python3
"""Print a Parquet file's footer statistics, using no Parquet library.

This reads the bytes we wrote rather than asking a third-party reader whether it
is willing to surface them. Two reasons, both learned from #850:

  * A reader may decline to expose statistics for reasons of its own. Arrow
    discards min_value/max_value when FileMetaData.column_orders is absent, so a
    file carrying correct statistics and no column_orders reads as a file with
    no statistics at all. Only the bytes distinguish those two states.
  * A suite whose instrument is an optional import reports SKIP when the import
    is missing, and a skip is not coverage.

Output is one line per record, space-separated key=value, for grep and awk:

  FILE created_by=<s> row_groups=<n> leaves=<n> column_orders=<n> order_ids=<csv>
  CHUNK rg=<i> leaf=<j> path=<a.b> ptype=<n> num_values=<n> has_min=<0|1>
        has_max=<0|1> minlen=<n> maxlen=<n> min=<v> max=<v> minhex=<h> maxhex=<h>
        null_count=<n|-> nan_count=<n|-> has_dep_min=<0|1> has_dep_max=<0|1>

A value that is absent prints as `-`, never as an empty field: an empty capture
must fail check_num rather than silently compare equal to another empty one.

Any parse error exits non-zero with a message on stderr, so a truncated read can
never present as "no statistics found".

Usage:  parquet_stats.py FILE
Written fresh for pgColumnar.
"""
import struct
import sys

# parquet.thrift Type
PTYPE_NAME = {0: "BOOLEAN", 1: "INT32", 2: "INT64", 3: "INT96",
              4: "FLOAT", 5: "DOUBLE", 6: "BYTE_ARRAY", 7: "FLBA"}


class R:
    """A cursor over `raw` with Thrift-compact primitives.

    The same shape as test/craft_parquet_counts.py's reader; kept separate
    because that one is a file-mutating tool and this one must not import
    pyarrow.
    """

    def __init__(self, raw, pos):
        self.raw, self.pos = raw, pos

    def u8(self):
        if self.pos >= len(self.raw):
            die("ran off the end of the footer at %d" % self.pos)
        b = self.raw[self.pos]
        self.pos += 1
        return b

    def varint(self):
        sh = out = 0
        while True:
            b = self.u8()
            out |= (b & 0x7F) << sh
            if not b & 0x80:
                return out
            sh += 7

    def zigzag(self):
        u = self.varint()
        return (u >> 1) ^ -(u & 1)

    def binary(self):
        n = self.varint()
        s = self.raw[self.pos:self.pos + n]
        if len(s) != n:
            die("binary field of %d bytes runs past the footer" % n)
        self.pos += n
        return s

    def list_hdr(self):
        b = self.u8()
        sz, et = (b >> 4) & 0x0F, b & 0x0F
        if sz == 0x0F:
            sz = self.varint()
        return sz, et

    def field(self, last):
        """Read a field header. Returns (type, fid, new_last); type 0 = STOP."""
        b = self.u8()
        if b == 0:
            return 0, 0, last
        t = b & 0x0F
        d = b >> 4
        fid = last + d if d else self.zigzag()
        return t, fid, fid

    def skip(self, t):
        if t in (1, 2):                     # BOOL_TRUE / BOOL_FALSE: no payload
            return
        if t == 3:                          # BYTE
            self.pos += 1
        elif t in (4, 5, 6):                # I16 / I32 / I64
            self.zigzag()
        elif t == 7:                        # DOUBLE
            self.pos += 8
        elif t == 8:                        # BINARY
            self.binary()
        elif t in (9, 10):                  # LIST / SET
            n, et = self.list_hdr()
            for _ in range(n):
                self.skip(et)
        elif t == 11:                       # MAP
            n = self.varint()
            if n:
                kt = self.u8()
                for _ in range(n):
                    self.skip(kt >> 4)
                    self.skip(kt & 0x0F)
        elif t == 12:                       # STRUCT
            self.skip_struct()
        else:
            die("unexpected thrift type %d at %d" % (t, self.pos))

    def skip_struct(self):
        last = 0
        while True:
            t, _fid, last = self.field(last)
            if t == 0:
                return
            self.skip(t)


def die(msg):
    sys.stderr.write("parquet_stats: %s\n" % msg)
    raise SystemExit(2)


def decode_plain(blob, ptype):
    """A statistics value is PLAIN-encoded, and for BYTE_ARRAY carries no length
    prefix. Only the fixed-width ordered types are decoded to a number; anything
    else prints as hex, which is all the caller needs to assert absence."""
    try:
        if ptype == 1 and len(blob) == 4:
            return str(struct.unpack("<i", blob)[0])
        if ptype == 2 and len(blob) == 8:
            return str(struct.unpack("<q", blob)[0])
        if ptype == 4 and len(blob) == 4:
            return repr(struct.unpack("<f", blob)[0])
        if ptype == 5 and len(blob) == 8:
            return repr(struct.unpack("<d", blob)[0])
    except struct.error:
        return "UNDECODABLE"
    return "-"


def parse_statistics(r):
    st = {"has_min": 0, "has_max": 0, "min": None, "max": None,
          "null_count": None, "nan_count": None,
          "has_dep_min": 0, "has_dep_max": 0}
    last = 0
    while True:
        t, fid, last = r.field(last)
        if t == 0:
            return st
        if fid == 1 and t == 8:
            r.binary()
            st["has_dep_max"] = 1
        elif fid == 2 and t == 8:
            r.binary()
            st["has_dep_min"] = 1
        elif fid == 3 and t in (4, 5, 6):
            st["null_count"] = r.zigzag()
        elif fid == 5 and t == 8:
            st["max"] = r.binary()
            st["has_max"] = 1
        elif fid == 6 and t == 8:
            st["min"] = r.binary()
            st["has_min"] = 1
        elif fid == 9 and t in (4, 5, 6):
            st["nan_count"] = r.zigzag()
        else:
            r.skip(t)


def parse_column_meta(r):
    """ColumnMetaData: 1 type, 3 path_in_schema, 5 num_values, 12 statistics."""
    cm = {"ptype": None, "path": None, "num_values": None, "stats": None}
    last = 0
    while True:
        t, fid, last = r.field(last)
        if t == 0:
            return cm
        if fid == 1 and t in (4, 5, 6):
            cm["ptype"] = r.zigzag()
        elif fid == 3 and t == 9:
            n, et = r.list_hdr()
            parts = []
            for _ in range(n):
                if et == 8:
                    parts.append(r.binary().decode("utf-8", "replace"))
                else:
                    r.skip(et)
            cm["path"] = ".".join(parts)
        elif fid == 5 and t in (4, 5, 6):
            cm["num_values"] = r.zigzag()
        elif fid == 12 and t == 12:
            cm["stats"] = parse_statistics(r)
        else:
            r.skip(t)


def parse_column_chunk(r):
    """ColumnChunk: 3 meta_data."""
    meta = None
    last = 0
    while True:
        t, fid, last = r.field(last)
        if t == 0:
            return meta
        if fid == 3 and t == 12:
            meta = parse_column_meta(r)
        else:
            r.skip(t)


def parse_row_group(r):
    """RowGroup: 1 columns, 3 num_rows."""
    cols, num_rows = [], None
    last = 0
    while True:
        t, fid, last = r.field(last)
        if t == 0:
            return cols, num_rows
        if fid == 1 and t == 9:
            n, et = r.list_hdr()
            if et != 12:
                die("RowGroup.columns is not a list of structs")
            for _ in range(n):
                cols.append(parse_column_chunk(r))
        elif fid == 3 and t in (4, 5, 6):
            num_rows = r.zigzag()
        else:
            r.skip(t)


def parse_column_orders(r):
    """list<ColumnOrder>; each is a union struct whose set field id names the
    order (1 = TYPE_ORDER). The ids are what the caller asserts on."""
    ids = []
    n, et = r.list_hdr()
    if et != 12:
        die("column_orders is not a list of structs")
    for _ in range(n):
        last = 0
        seen = 0
        while True:
            t, fid, last = r.field(last)
            if t == 0:
                break
            seen = fid
            r.skip(t)
        ids.append(seen)
    return ids


def main():
    if len(sys.argv) != 2:
        die("usage: parquet_stats.py FILE")
    with open(sys.argv[1], "rb") as fh:
        raw = fh.read()
    if len(raw) < 12 or raw[:4] != b"PAR1" or raw[-4:] != b"PAR1":
        die("not a Parquet file (magic missing)")
    flen = struct.unpack("<I", raw[-8:-4])[0]
    start = len(raw) - 8 - flen
    if start < 4:
        die("footer length %d does not fit the file" % flen)

    r = R(raw, start)
    created_by, rgs, order_ids = "-", [], None
    last = 0
    while True:
        t, fid, last = r.field(last)
        if t == 0:
            break
        if fid == 4 and t == 9:
            n, et = r.list_hdr()
            if et != 12:
                die("row_groups is not a list of structs")
            for _ in range(n):
                rgs.append(parse_row_group(r))
        elif fid == 6 and t == 8:
            created_by = r.binary().decode("utf-8", "replace")
        elif fid == 7 and t == 9:
            order_ids = parse_column_orders(r)
        else:
            r.skip(t)

    if not rgs:
        die("footer carries no row groups")

    nleaves = len(rgs[0][0])
    print("FILE created_by=%s row_groups=%d leaves=%d column_orders=%d order_ids=%s"
          % (created_by, len(rgs), nleaves,
             0 if order_ids is None else len(order_ids),
             "-" if not order_ids else ",".join(str(i) for i in sorted(set(order_ids)))))

    for rg, (cols, _nrows) in enumerate(rgs):
        for leaf, cm in enumerate(cols):
            if cm is None:
                die("row group %d column %d has no meta_data" % (rg, leaf))
            st = cm["stats"] or {"has_min": 0, "has_max": 0, "min": None,
                                 "max": None, "null_count": None,
                                 "nan_count": None, "has_dep_min": 0,
                                 "has_dep_max": 0}
            pt = cm["ptype"]
            mn, mx = st["min"], st["max"]
            print("CHUNK rg=%d leaf=%d path=%s ptype=%s ptname=%s num_values=%s "
                  "has_min=%d has_max=%d minlen=%s maxlen=%s min=%s max=%s "
                  "minhex=%s maxhex=%s null_count=%s nan_count=%s "
                  "has_dep_min=%d has_dep_max=%d"
                  % (rg, leaf, cm["path"] if cm["path"] else "-",
                     "-" if pt is None else pt,
                     PTYPE_NAME.get(pt, "?"),
                     "-" if cm["num_values"] is None else cm["num_values"],
                     st["has_min"], st["has_max"],
                     "-" if mn is None else len(mn),
                     "-" if mx is None else len(mx),
                     "-" if mn is None else decode_plain(mn, pt),
                     "-" if mx is None else decode_plain(mx, pt),
                     "-" if mn is None else mn.hex(),
                     "-" if mx is None else mx.hex(),
                     "-" if st["null_count"] is None else st["null_count"],
                     "-" if st["nan_count"] is None else st["nan_count"],
                     st["has_dep_min"], st["has_dep_max"]))


if __name__ == "__main__":
    main()
