#!/usr/bin/env bash
#
# Index-fetch I/O is one ReadLogicalData per column (validity, then the value
# stream). The scan path already coalesces adjacent chunk ranges into one read.
# Adjacent columns are laid out back to back, so a wide fetch of a small group
# is many pins of the same pages rather than one walk.
#
# Public seam: EXPLAIN (ANALYZE, BUFFERS) pin count (shared hit+read) after a
# warmup, with the index path forced. The property is the COUNT, not wall
# clock, so it is not subject to PGC_SKIP_TIMING.
#
# Independent of test/pytest/test_native_fetch_coalesce.py: same public seam,
# own fixture, own observations.
#
# Usage:  test/native_fetch_coalesce.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/lib/postgresql/18/bin/pg_config}"

NCOLS=16
ROWS=2000
STRIPE=1000

cols=""
ins=""
sel_wide=""
i=0
while [ "$i" -lt "$NCOLS" ]; do
	cols="${cols}, c$(printf '%02d' "$i") int"
	ins="${ins}, g * ($i + 1)"
	if [ -n "$sel_wide" ]; then
		sel_wide="${sel_wide}, c$(printf '%02d' "$i")"
	else
		sel_wide="c$(printf '%02d' "$i")"
	fi
	i=$((i + 1))
done

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null
q "CREATE TABLE nfc (id int${cols}) USING pgcolumnar;" >/dev/null
q "SELECT pgcolumnar.set_options('nfc', stripe_row_limit => ${STRIPE},
                                 chunk_group_row_limit => 1000,
                                 compression => 'none');" >/dev/null
q "INSERT INTO nfc SELECT g${ins} FROM generate_series(1, ${ROWS}) g;
   CREATE INDEX nfc_id ON nfc (id);
   ANALYZE nfc;" >/dev/null

FORCE="SET max_parallel_workers_per_gather=0; SET enable_seqscan=off;
       SET enable_bitmapscan=off; SET pgcolumnar.enable_custom_scan=off;
       SET pgcolumnar.enable_index_fetch_penalty=off;"

plan_scan() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-Atq -c "${FORCE}
		         EXPLAIN (COSTS OFF) $1" 2>&1 \
		| grep -m1 -oE 'Index Scan|Index Only Scan|Bitmap Heap Scan|Custom Scan|Seq Scan'
}

bufs() {
	local sql="$1"
	psql_run "${FORCE} EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, FORMAT TEXT) ${sql}" \
		>/dev/null 2>&1
	psql_run "${FORCE} EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, FORMAT TEXT) ${sql}" \
		2>/dev/null |
		awk '
			/Planning:/ { p=1 }
			!p && /Buffers:/ {
				for (i = 1; i <= NF; i++) {
					if ($i ~ /^(shared|read|hit)/) {
						gsub(/[^0-9]/, "", $i)
						if ($i != "") t += $i
					}
				}
			}
			END { print t + 0 }'
}

fetch_val() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-Atq -c "$1" 2>&1 | grep -v '^SET$' | tail -1
}

check "premise: a point lookup uses the index" \
	"$(plan_scan "SELECT ${sel_wide} FROM nfc WHERE id = 1")" "Index Scan"

NARROW="$(bufs "SELECT c00 FROM nfc WHERE id = 1;")"
WIDE="$(bufs "SELECT ${sel_wide} FROM nfc WHERE id = 1;")"
echo "-- exec buffers: one column = ${NARROW}, ${NCOLS} columns = ${WIDE}"

check_num "premise: fetching one projected column touched a measurable number of buffers" \
	"$([ "${NARROW:-0}" -gt 0 ] && echo 1 || echo 0)" "1"
check_num "premise: fetching every projected column touched a measurable number of buffers" \
	"$([ "${WIDE:-0}" -gt 0 ] && echo 1 || echo 0)" "1"

# Planning buffers are ignored: they grow with the target list and are not
# fetch I/O. The Index Scan line is. Extra columns today add two pins each
# (validity, then values). Coalescing walks the same pages once, so the wide
# count may not exceed the one-column count by more than one pin per extra
# column.
EXTRA_COLS=$((NCOLS - 1))
check_num "a wide index fetch does not pin once per column" \
	"$([ "${WIDE:-0}" -le $((NARROW + EXTRA_COLS)) ] && echo 1 || echo 0)" "1"

expect_wide=""
i=0
while [ "$i" -lt "$NCOLS" ]; do
	v=$((1 * (i + 1)))
	if [ -n "$expect_wide" ]; then
		expect_wide="${expect_wide}|${v}"
	else
		expect_wide="${v}"
	fi
	i=$((i + 1))
done
check "premise: the wide fetch returns the projected values" \
	"$(fetch_val "${FORCE} SELECT ${sel_wide} FROM nfc WHERE id = 1;")" "$expect_wide"

pgc_summary
