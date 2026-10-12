#!/usr/bin/env bash
#
# A ctid range reads only the row groups that hold it (TID range scans).
#
# WRITTEN BEFORE THE CODE. Measured on #1294: `WHERE ctid >= '(600000,0)'` on a
# 10M-row table matched 0 rows and still read all 67 row groups, because the
# access method has no scan_set_tidrange and the range is a per-row filter. A
# rollup that processes "rows added since the last refresh" (#1294) needs to read
# the newest row groups only, and so does anything else that bounds ctid.
#
# THE ORACLE is the same query with TID scans disabled (enable_tidscan = off),
# which is the per-row filter every build applies today: a TID range scan must
# return exactly what that returns, for every shape of range. THE COST is the
# table's own blocks from pg_statio, flushed by the querying session -- an
# instrument that does not depend on which plan node answers.
#
# Usage:  test/tid_range_scan.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

at_least() { [ -z "$1" ] && return; [ "$1" -lt "$2" ] && echo "$1" || echo "$2"; }

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null
q "CREATE TABLE tr (id bigint, v text) USING pgcolumnar;
   SELECT pgcolumnar.set_options('tr', stripe_row_limit => 10000);
   INSERT INTO tr SELECT g, md5(g::text) FROM generate_series(1, 400000) g;" >/dev/null
check_num "premise: the table holds every row" "$(q "SELECT count(*) FROM tr;")" "400000"
groups="$(q "SELECT count(*) FROM pgcolumnar.row_group WHERE storage_id = pgcolumnar.get_storage_id('tr');")"
check_num "premise: the table has many row groups, so skipping can show" "$(at_least "$groups" 30)" "30"

# ctid of the row with a given id, as the AM numbers it
tid_of() { q "SELECT ctid FROM tr WHERE id = $1;"; }
LAST="$(tid_of 390001)"; MID_A="$(tid_of 150001)"; MID_B="$(tid_of 170000)"; END="$(tid_of 400000)"
echo "-- ctids: 390001=$LAST 150001=$MID_A 170000=$MID_B 400000=$END"

hash() { q "SET enable_tidscan = ${2:-on}; SELECT md5(string_agg(id::text || v, ',' ORDER BY id)) || '|' || count(*) FROM tr WHERE $1;" | tail -1; }
for pred in "ctid >= '$LAST'" "ctid >= '$MID_A' AND ctid <= '$MID_B'" "ctid < '$MID_A'" \
            "ctid > '$END'" "ctid >= '(0,0)'"; do
	check "a ctid range returns what the per-row filter returns: ${pred//$LAST/LAST}" \
		"$(hash "$pred" on)" "$(hash "$pred" off)"
done

# max(v || 'x'), not max(v): an unfiltered count/max is answered from zone maps
# (#1293) and read 5 blocks of this table in the first draft, so the "whole
# table" baseline measured metadata, not data.
blocks() {	# blocks PRED -> tr blocks read, in the querying session
	q "SELECT pg_stat_reset();" >/dev/null
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -At \
		-c "SELECT count(*), max(v || 'x') FROM tr WHERE $1" -c "SELECT pg_stat_force_next_flush()" >/dev/null 2>&1
	q "SELECT coalesce(heap_blks_read, 0) + coalesce(heap_blks_hit, 0) FROM pg_statio_user_tables WHERE relname = 'tr';"
}
full="$(blocks "true")"
tail_b="$(blocks "ctid >= '$LAST'")"
echo "-- blocks: whole table $full, last 2.5% by ctid $tail_b"
check_num "premise: reading the whole table reads its blocks" "$(at_least "$full" 100)" "100"
check_num "a ctid range over the last row groups reads under a fifth of the table" \
	"$( [ -n "$tail_b" ] && [ "$tail_b" -ge 1 ] && at_least $((full - 5 * tail_b)) 1 || echo "read ${tail_b:-nothing}")" "1"

# Deleted rows inside the range stay invisible.
q "DELETE FROM tr WHERE id BETWEEN 395000 AND 395999;" >/dev/null
check "and rows deleted inside the range stay deleted" \
	"$(hash "ctid >= '$LAST'" on)" "$(hash "ctid >= '$LAST'" off)"
check_num "premise: the delete removed rows from the range" \
	"$(q "SET enable_tidscan = off; SELECT count(*) FROM tr WHERE ctid >= '$LAST';" | tail -1)" "9000"

pgc_summary
