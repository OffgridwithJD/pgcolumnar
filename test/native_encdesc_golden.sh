#!/usr/bin/env bash
#
# pgColumnar native encoding-descriptor wire layout is stable.
#
# The descriptor is the writer->reader contract for a column chunk's per-vector
# encoding. Its byte layout was hand-packed in columnar_write_state.c and
# hand-parsed in three passes in columnar_reader.c; columnar_encdesc.h now owns it
# (PgColumnarEncdescPut*/ReadEntry), and a StaticAssert ties ENTRY_LEN to the
# field widths. The codec was verified to emit byte-identical descriptors to the
# hand-packed form (captured from both and compared).
#
# This pins the LAYOUT, not the encoder's choice: it decodes the on-disk
# descriptor of a deterministic table and asserts the version byte, the
# vectorCount, the per-entry valueCount and rawLen at their fixed offsets, and a
# self-consistent total length. A codec that reorders a field or changes a width
# reads these back wrong (or the StaticAssert fails the build first), so a layout
# drift fails here rather than surfacing as DATA_CORRUPTED or wrong values in
# production. It does NOT pin which encoding was chosen, so encoder tuning does
# not spuriously break it.
#
# Layout (descriptor version 2):
#   header:  version u8 @0, reserved u8 @1, vectorCount u32 @2   (HEADER_LEN 6)
#   entry:   type u8 @0, valueCount u32 @1, rawLen u32 @5, encLen u32 @9  (ENTRY_LEN 13)
#   trailer: sharedTableLen u32, then that many bytes
#
# Usage:  test/native_encdesc_golden.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null

# 300 rows (< the sample size), so encoding choice is deterministic and the whole
# table is one row group (300 < stripe_row_limit) with one vector per chunk.
q "CREATE TABLE d (a int, b bigint, c text) USING pgcolumnar;
   INSERT INTO d SELECT g, g*1000000::bigint, 'val'||(g%4) FROM generate_series(1,300) g;" >/dev/null
SID="$(q "SELECT pgcolumnar.get_storage_id('d');")"

# a single byte of column COL's descriptor at 0-based offset OFF
b() { q "SELECT get_byte(encoding_descriptor, $2) FROM pgcolumnar.column_chunk
         WHERE storage_id=$SID AND column_index=$1;"; }
# a little-endian uint32 of column COL's descriptor at 0-based offset OFF (inlined:
# each q is a fresh session, so no session-local helper function survives)
le32() { q "SELECT get_byte(d,$2)+get_byte(d,$2+1)*256+get_byte(d,$2+2)*65536
                   +get_byte(d,$2+3)*16777216
            FROM (SELECT encoding_descriptor d FROM pgcolumnar.column_chunk
                  WHERE storage_id=$SID AND column_index=$1) x;"; }
olen() { q "SELECT octet_length(encoding_descriptor) FROM pgcolumnar.column_chunk
            WHERE storage_id=$SID AND column_index=$1;"; }

# version byte is 2 on every column's descriptor
for col in 0 1 2; do
	check "column $col descriptor version byte is 2" "$(b $col 0)" "2"
done

# vectorCount (u32 @2) is 1 (one chunk group, one vector)
check "vectorCount parses as 1 (at offset 2)" "$(le32 0 2)" "1"

# self-consistent length: 6 (header) + vectorCount*13 (entries) + 4 (sharedLen) +
# sharedTableLen. For these columns the FSST shared table is empty (0).
check "descriptor length is header + 1 entry + empty trailer (23)" "$(olen 0)" "23"
check "trailing sharedTableLen is 0 (u32 at offset 6+13=19)" "$(le32 0 19)" "0"

# per-entry valueCount (u32 @ 6+1=7) is the row count on every column
for col in 0 1 2; do
	check "column $col entry valueCount parses as 300 (at offset 7)" \
		"$(le32 $col 7)" "300"
done

# per-entry rawLen (u32 @ 6+5=11) is value_count * attlen for the fixed-width cols:
# int a = 300*4 = 1200, bigint b = 300*8 = 2400. A field-offset drift reads these
# back wrong.
check "int column a rawLen parses as 1200 (300*4, at offset 11)" "$(le32 0 11)" "1200"
check "bigint column b rawLen parses as 2400 (300*8, at offset 11)" "$(le32 1 11)" "2400"

# the whole table still reads back correctly under this descriptor
check "the table reads back all rows" "$(q 'SELECT count(*) FROM d;')" "300"
check "a full-column read is correct" "$(q 'SELECT sum(a) FROM d;')" "45150"

pgc_summary
