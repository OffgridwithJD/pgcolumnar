#!/usr/bin/env bash
#
# pgColumnar local file opens are race-free (no stat-before-open TOCTOU).
#
# The read path opens local files named by an Iceberg metadata pointer, an Avro
# manifest, a Parquet path, or an Arrow import. A FIFO named there must not block
# the backend in open(2): a blocking open is cancel-resistant (SA_RESTART), an
# availability DoS (#644/#686). The first fix screened with stat() BEFORE the
# open, which avoids the block but races -- a local principal who can write the
# directory can swap the checked regular file for a FIFO between the stat and the
# open, re-introducing the block. All five local openers (ice_slurp_text,
# ice_slurp_bin, av_slurp_file, import_arrow, the Parquet source) now go through
# one helper, PgColumnarOpenLocalRegularFile, that opens O_NONBLOCK and fstats the
# fd it holds: the file it checks is the file it opened.
#
# The TOCTOU itself cannot be tested deterministically -- a static FIFO is refused
# by both the stat and the fstat form, and only a lost race distinguishes them --
# so, like decode_interrupts.sh, the guard is a source-shape assertion: the opener
# must open O_NONBLOCK and fstat (never stat a path before opening it), and the
# racy stat-before-open helper must be gone. A revert to stat-before-open fails
# these. The functional arm confirms each entry point still refuses a FIFO with a
# clean SQLSTATE rather than a hang.
#
# Usage:  test/local_open_race_free.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"
OBJ="$SRC/columnar_objstore.c"

# --- shape arm: the opener is race-free, and the racy helper is gone ----------
# Body of PgColumnarOpenLocalRegularFile: from its definition line to the next
# function at column zero.
opener_body() {
	awk '/^PgColumnarOpenLocalRegularFile\(/{f=1}
	     f && NR>1 && /^[A-Za-z_].*\(/ && !/^PgColumnarOpenLocalRegularFile\(/ {exit}
	     f {print}' "$OBJ"
}

check "the race-free opener exists" \
	"$([ -n "$(opener_body)" ] && echo yes || echo no)" "yes"
check "the opener opens O_NONBLOCK (a FIFO cannot block the open)" \
	"$([ "$(opener_body | grep -c 'O_NONBLOCK')" -ge 1 ] && echo yes || echo no)" "yes"
check "the opener fstats the fd it holds (checks what it opened)" \
	"$([ "$(opener_body | grep -c 'fstat(')" -ge 1 ] && echo yes || echo no)" "yes"
check "the opener never stats a path before opening it (no TOCTOU)" \
	"$(opener_body | grep -Ec 'stat\((const )?path|stat\("|stat\(path')" "0"
check "the racy stat-before-open helper is gone" \
	"$(grep -rc 'PgColumnarRejectNonRegularFile' "$SRC" | awk -F: '{s+=$2} END{print s+0}')" "0"

# The parallel-copy partition coordinator opens the file itself (getline needs a
# FILE*, so it cannot use the transient-fd helper). It must still open O_NONBLOCK
# and fstat, never stat a path before opening it. Body from its definition line to
# the next function at column zero.
PC="$SRC/columnar_parallel_copy.c"
pcopy_part_body() {
	awk '/^pcopy_partition_aligned_offsets\(/{f=1}
	     f && NR>1 && /^[A-Za-z_].*\(/ && !/^pcopy_partition_aligned_offsets\(/ {exit}
	     f {print}' "$PC"
}
check "the partition coordinator opens O_NONBLOCK (a FIFO cannot block its open)" \
	"$([ "$(pcopy_part_body | grep -c 'O_NONBLOCK')" -ge 1 ] && echo yes || echo no)" "yes"
check "the partition coordinator never stats a path before opening it (no TOCTOU)" \
	"$(pcopy_part_body | grep -Ec 'stat\((const )?path|stat\("|stat\(path')" "0"

# --- functional arm: each newly-converted entry point refuses a FIFO ----------
# A static FIFO is refused by both the old and new code, so this does not prove
# the race is closed; it proves the entry point reaches the guard and returns a
# clean error, not a hang. XX001 is DATA_CORRUPTED, what the opener raises.
sqlstate_or_hang() {
	local out rc
	out="$(timeout -s KILL 5 env PATH="$PGC_BINDIR:$PATH" psql \
		-h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -qtA 2>&1 <<SQLEOF
\\set VERBOSITY sqlstate
$1;
SQLEOF
)"
	rc=$?
	if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then echo HANG; return; fi
	printf '%s\n' "$out" | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
}
fifo_release() { exec 9<>"$1" 2>/dev/null; exec 9>&- 2>/dev/null; }

FIFO="$PGC_WORKDIR/lo.fifo"; mkfifo "$FIFO"
check "read_parquet on a FIFO is a clean error, not a hang" \
	"$(sqlstate_or_hang "SELECT * FROM pgcolumnar.read_parquet('$FIFO') AS t(c int)")" \
	"XX001"; fifo_release "$FIFO"
check "read_avro_manifest on a FIFO is a clean error, not a hang" \
	"$(sqlstate_or_hang "SELECT count(*) FROM pgcolumnar.read_avro_manifest('$FIFO')")" \
	"XX001"; fifo_release "$FIFO"
check "backend still up after the FIFO refusals" "$(q 'SELECT 1')" "1"

pgc_summary
