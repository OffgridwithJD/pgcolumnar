#!/usr/bin/env bash
#
# pgColumnar bounds a varlena value's stored length against its buffer.
#
# A varying-length value in a native chunk (and in a zone map's min/max) carries
# its own length prefix, which the decoder trusted: PgColumnarDecodeValue,
# pgcolumnar_skip_value, and pgcolumnar_build_val_offsets read
# PgColumnarVarSizeAnyUnaligned and memcpy that many bytes with no check that the
# value fits its buffer. A corrupt chunk or catalog row (bit rot, a hand-written
# stripe) can then declare a value that runs past the buffer -- an out-of-bounds
# read -- and a header carrying the external-TOAST tag is later detoasted through
# a pointer to nothing. This is the trusted-storage boundary core PostgreSQL does
# not defend for a heap page either, but the reader aspires to (see corruption.sh
# / hardening.sh), and a clean error beats a crash.
#
# Every decode site now passes the value stream's end and reads through
# PgColumnarVarSizeAnyUnalignedBounded, which refuses a length (or an external
# tag) that would read past it. The zone map's min/max is a catalog bytea, so it
# is corruptible with a plain UPDATE (unlike the relation-file value stream),
# which makes this reachable and testable: point a min at a 5-byte value whose
# 4-byte header claims ~1 GB, then a predicate that consults it.
#
# RED (unbounded) is a ~1 GB memcpy from a 5-byte buffer -- a SIGSEGV that takes
# the backend (and the cluster) down. GREEN is a clean DATA_CORRUPTED (XX001) and
# a surviving backend. The other decode sites (the sequential scan, the per-row
# fetch, the vector aggregate) share the one bounded reader, so they are bounded
# by the same fix; the min/max path is the one a catalog UPDATE can reach.
#
# Reproducing the removal proof (two traps that both come back falsely GREEN):
#   - Do a fresh (make clean) build, NOT PGC_SKIP_BUILD=1. The bounded reader is a
#     header inline; PGXS does not track header deps, so a skip build tests the
#     old .so and the gutted guard never takes effect (gate-environment stale-.so).
#   - Poison column_index=1 (txt), not 0. Column 0 is the int id and has no varlena
#     min/max, so corrupting its zone map does not reach the varlena decoder.
# With a clean build and column 1 poisoned, the ungutted bound gives XX001; the
# gutted one turns the ~1 GB claim into a memcpy that SIGSEGVs the backend.
#
# Usage:  test/native_varlena_bound.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null
q "CREATE TABLE t (id int, txt text) USING pgcolumnar;
   INSERT INTO t SELECT g, 'v'||g FROM generate_series(1,2000) g;" >/dev/null
SID="$(q "SELECT pgcolumnar.get_storage_id('t');")"

check "the txt column has a whole-chunk zone map to corrupt" \
	"$(q "SELECT count(*) FROM pgcolumnar.zone_map WHERE storage_id=$SID AND column_index=1 AND vector_index=-1;")" \
	"1"

# 0xfcffffff is a 4-byte varlena header claiming (0x3fffffff) ~1 GB; the value is
# only 5 bytes. errors() runs the query; SQLSTATE / survival are asserted below.
errcode() { # SQL -> the 5-char SQLSTATE it raises, or NOERR
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-qtA -v VERBOSITY=sqlstate -c "$1" 2>&1 \
		| sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
}
alive() { [ "$(q 'SELECT 1;')" = "1" ] && echo yes || echo no; }

# --- corrupt the MINIMUM ------------------------------------------------------
q "UPDATE pgcolumnar.zone_map SET minimum = E'\\\\xfcffffff00'::bytea
   WHERE storage_id=$SID AND column_index=1 AND vector_index=-1;" >/dev/null
check "a min with an over-long varlena length is refused, not an OOB read (XX001)" \
	"$(errcode "SELECT count(*) FROM t WHERE txt > 'a';")" "XX001"
check "backend survived the corrupt minimum" "$(alive)" "yes"

# --- restore, then corrupt the MAXIMUM ---------------------------------------
q "UPDATE pgcolumnar.zone_map SET maximum = E'\\\\xfcffffff00'::bytea
   WHERE storage_id=$SID AND column_index=1 AND vector_index=-1;" >/dev/null
check "a max with an over-long varlena length is refused, not an OOB read (XX001)" \
	"$(errcode "SELECT count(*) FROM t WHERE txt < 'zzz';")" "XX001"
check "backend survived the corrupt maximum" "$(alive)" "yes"

# --- an external-TOAST tag in the raw value stream is refused -----------------
# 0x01 is the 1-byte external-TOAST tag; native storage never holds one, and
# detoasting it would deref a bogus pointer. VARSIZE alone would accept it.
q "UPDATE pgcolumnar.zone_map SET minimum = E'\\\\x0102030405060708090a0b0c0d0e0f1011'::bytea
   WHERE storage_id=$SID AND column_index=1 AND vector_index=-1;" >/dev/null
check "an external-TOAST-tagged min value is refused (XX001)" \
	"$(errcode "SELECT count(*) FROM t WHERE txt > 'a';")" "XX001"
check "backend survived the external-tagged minimum" "$(alive)" "yes"

pgc_summary
