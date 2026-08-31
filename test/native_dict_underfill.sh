#!/usr/bin/env bash
# Repro for the DICT decode under-fill: inflate a DICT chunk's value_raw_length
# in the encoding descriptor so the codes decode to fewer bytes than declared,
# leaving the raw buffer tail uninitialized (a varlena length is then read out of
# that garbage). Post-fix the reader must raise a clean error and survive.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE TABLE dt (id int, v text) USING pgcolumnar" >/dev/null
# low-cardinality short text -> DICT-encoded varlena column, one small chunk
q "INSERT INTO dt SELECT g, (ARRAY['aa','bb','cc','dd'])[1+(g%4)] FROM generate_series(1,300) g" >/dev/null

SID="$(q "SELECT pgcolumnar.get_storage_id('dt')")"
# column_index is 0-based; v is attribute 2 -> index 1
ENC="$(q "SELECT get_byte(encoding_descriptor, 6) FROM pgcolumnar.column_chunk WHERE storage_id=$SID AND column_index=1 LIMIT 1")"
echo "-- v-column vector0 encoding type byte (DICT=6): $ENC"
check "the text column is DICT-encoded (precondition)" "$ENC" "6"

# read old rawLen (uint32 LE at descriptor offset 11), inflate by 64, write back
q "UPDATE pgcolumnar.column_chunk c SET encoding_descriptor =
     set_byte(set_byte(set_byte(set_byte(encoding_descriptor,
       11, ( (get_byte(encoding_descriptor,11) + (get_byte(encoding_descriptor,12)<<8) + (get_byte(encoding_descriptor,13)<<16) + (get_byte(encoding_descriptor,14)<<24)) + 64 )       & 255),
       12, (((get_byte(encoding_descriptor,11) + (get_byte(encoding_descriptor,12)<<8) + (get_byte(encoding_descriptor,13)<<16) + (get_byte(encoding_descriptor,14)<<24)) + 64) >> 8) & 255),
       13, (((get_byte(encoding_descriptor,11) + (get_byte(encoding_descriptor,12)<<8) + (get_byte(encoding_descriptor,13)<<16) + (get_byte(encoding_descriptor,14)<<24)) + 64) >>16) & 255),
       14, (((get_byte(encoding_descriptor,11) + (get_byte(encoding_descriptor,12)<<8) + (get_byte(encoding_descriptor,13)<<16) + (get_byte(encoding_descriptor,14)<<24)) + 64) >>24) & 255)
     WHERE c.storage_id=$SID AND c.column_index=1" >/dev/null

env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
    -c "SELECT v FROM dt" >/dev/null 2>"$PGC_WORKDIR/uf.err"
echo "-- select stderr:"; sed 's/^/     /' "$PGC_WORKDIR/uf.err" | head -3
rejected=no
grep -qiE 'does not match|corrupt|invalid|out of' "$PGC_WORKDIR/uf.err" && rejected=yes
crash=no
grep -qiE 'terminated by signal|segmentation|server closed' "$PGC_WORKDIR/uf.err" && crash=yes
grep -qiE 'terminated by signal|segmentation' "$PGC_LOGFILE" 2>/dev/null && crash=yes
echo "-- rejected=$rejected crash=$crash"
check "under-filled DICT chunk is rejected with a clean error" "$rejected" "yes"
check "backend survives the under-filled DICT chunk" "$(q 'SELECT 1')" "1"
pgc_summary
