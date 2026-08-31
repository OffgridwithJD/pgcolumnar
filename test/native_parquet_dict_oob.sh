#!/usr/bin/env bash
#
# Regression: a Parquet dictionary index with the high bit set must not read out
# of bounds of the dictionary.
#
# The RLE_DICTIONARY decode path bounds-checked the file-controlled index with a
# SIGNED comparison, `(int) idx[i] >= dictCount`. An index with the high bit set
# (reachable with bit_width 32, which the bit-packer accepts) sign-extends to a
# negative int, slips past the check, and `dict[idx[i]]` then reads ~16 GB past
# the dictionary. On the unfixed build one crafted file (no elevated privilege
# beyond calling read_parquet) crashes the whole cluster with SIGSEGV.
#
# This is the deterministic companion to fuzz_parquet.sh, which asserts the same
# "a malformed file raises an ERROR, never dies" property over random mutants but
# would not land on this exact bit_width/index pair. The committed evil fixture
# was made by fixtures/parquet/gen_dict_oob.py (a required-column, uncompressed,
# single-entry-dictionary file whose data page payload is replaced with
# [bit_width=32][bit-packed index 0x80000000]).
#
# Usage:  test/parquet_dict_oob.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

FX="$(dirname "${BASH_SOURCE[0]}")/fixtures/parquet"
BASE_SRC="$FX/dict_oob_base.parquet"
EVIL_SRC="$FX/dict_oob_evil.parquet"
[ -f "$BASE_SRC" ] && [ -f "$EVIL_SRC" ] \
	|| pgc_skip fixture "dictionary-index OOB fixtures are missing"

# The cluster runs as the postgres OS user; copy the fixtures where it can read.
cp "$BASE_SRC" "$EVIL_SRC" "$PGC_WORKDIR/"
chmod a+r "$PGC_WORKDIR"/*.parquet
BASE="$PGC_WORKDIR/dict_oob_base.parquet"
EVIL="$PGC_WORKDIR/dict_oob_evil.parquet"

# Control: the benign dictionary-encoded file reads its four rows.
check "control: a normal dictionary-encoded file reads its 4 rows" \
	"$(q "SELECT count(*) FROM pgcolumnar.read_parquet('$BASE') AS t(v int)")" "4"

# Attack: the crafted out-of-range index must be rejected, not dereferenced.
env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
	-c "SELECT * FROM pgcolumnar.read_parquet('$EVIL') AS t(v int)" \
	>/dev/null 2>"$PGC_WORKDIR/atk.err"

rejected=no
grep -qiE 'could not decode|corrupt|invalid|out of range' "$PGC_WORKDIR/atk.err" && rejected=yes
check "attack: the out-of-range dictionary index is rejected with an error" "$rejected" "yes"

# The decisive property: the backend is still alive (the OOB read did not happen).
check "attack: the backend survives (no out-of-bounds crash)" "$(q 'SELECT 1')" "1"

crashlines="$(grep -ciE 'terminated by signal|segmentation' "$PGC_LOGFILE" 2>/dev/null | head -1)"
check "attack: the server log records no segfault" "$crashlines" "0"

pgc_summary
