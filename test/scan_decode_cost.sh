#!/usr/bin/env bash
#
# pgColumnar: a columnar scan's cost scales with the number of decoded columns (#503).
#
# The custom scan inherits the heap seqscan cost, whose CPU term (cpu_tuple_cost)
# is per row and paid once whatever the projection width. So decoding nine columns
# was priced the same as decoding one, the planner could not see the decode CPU a
# parallel plan would divide, and it declined the partial path even where the
# parallel scan is measured 2.56x faster (the row-scan case in #503, distinct from
# the aggregate parallel_safe=false of #565).
#
# The fix prices one cpu_operator_cost per decoded value, ncols per row. This suite
# pins the plan-side of it -- a wide projection now costs measurably more than a
# narrow one -- without a timing measurement, which lives on the bench. It also
# pins #171: raising the full-scan cost must keep the point-lookup on its index.
#
# Usage:  test/scan_decode_cost.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

N=2000000
psql_run "CREATE TABLE cw (k int, v1 bigint, v2 bigint, v3 bigint, v4 bigint, v5 bigint, v6 bigint, v7 bigint, v8 bigint) USING pgcolumnar;"
psql_run "INSERT INTO cw SELECT (g % 1000000), g,g,g,g,g,g,g,g FROM generate_series(1,$N) g;"
psql_run "ANALYZE cw;"

# total_cost of a query's top node
topcost() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -Atq \
		-c "EXPLAIN (COSTS ON) $1" 2>&1 | grep -oiE 'cost=[0-9.]+\.\.[0-9.]+' | head -1 \
		| sed -E 's/.*\.\.([0-9.]+)/\1/'
}

NARROW="$(topcost 'SELECT k FROM cw')"
WIDE="$(topcost 'SELECT k,v1,v2,v3,v4,v5,v6,v7,v8 FROM cw')"

# premise: both are the columnar scan, and non-empty measurements
check "premise: the narrow scan has a cost" "$([ -n "$NARROW" ] && echo yes || echo no)" "yes"
check "premise: the wide scan has a cost"   "$([ -n "$WIDE" ] && echo yes || echo no)" "yes"

# The load-bearing assertion: decoding 9 columns must cost meaningfully more than
# decoding 1. Before the fix these are ~equal (flat in column count). The fix adds
# cpu_operator_cost per value per column, so 8 extra columns over 2M rows is a
# large, deterministic gap. Assert the wide scan is at least 1.5x the narrow one,
# which the flat pricing (a ~1.4% width difference) cannot reach.
RATIO="$(awk -v w="$WIDE" -v n="$NARROW" 'BEGIN{ printf "%.3f", (n>0)?w/n:0 }')"
check "a wide projection costs materially more than a narrow one (decode is priced)" \
	"$(awk -v r="$RATIO" 'BEGIN{ print (r >= 1.5) ? "scaled" : "flat" }')" "scaled"

# #171 guard: a point lookup on an indexed column must still choose the index,
# not a full columnar scan. Raising the scan cost is the safe direction, but pin
# it so a too-large term cannot push the planner off the index either.
psql_run "CREATE TABLE pt (id int, v bigint) USING pgcolumnar;"
psql_run "INSERT INTO pt SELECT g, g FROM generate_series(1,$N) g;"
psql_run "CREATE INDEX pt_id ON pt (id);"
psql_run "ANALYZE pt;"
PLAN="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -Atq \
	-c 'EXPLAIN (COSTS OFF) SELECT v FROM pt WHERE id = 12345' 2>&1)"
check "#171: a point lookup still uses the index, not a full scan" \
	"$(grep -qi 'Index' <<<"$PLAN" && echo index || echo "$PLAN")" "index"

pgc_summary
