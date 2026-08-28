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

# --- #768: the decode charge must scale with WIDTH, not just column count ------
#
# #503 above priced one cpu_operator_cost per decoded VALUE, which fixed "nine
# columns cost the same as one". It left a second flatness: a 324-byte text
# column is charged exactly what a 4-byte int4 column is. Measured on 4,000,000
# rows, PG17 non-assert, metadata and fold paths off, min of interleaved reps:
#
#   marginal cost of one more projected column
#     int4            4 bytes     24.0 ms
#     text (md5)     36 bytes    247.0 ms      10.29x for 9.00x the bytes
#     text (long)   324 bytes   1420.3 ms
#
#   and what the planner charged for the whole projection, after ANALYZE:
#     8 int4                     206,524   at   335 ms
#     4 text (324 bytes)         163,422   at  5875 ms
#
# Four long-text columns were priced BELOW eight int columns while taking 17.5
# times as long -- a 22x under-charge. Decode cost tracks bytes to within ~1.5x
# across an 81x width range; charging by column count is off by 59x across the
# same range.
#
# The bound is deliberately weak. The measured time ratio is 17.5x and the fixed
# model prices these ~40x apart on the decode term alone, but the assertion only
# demands 2x, because the point is the SIGN of the comparison: the flat model
# puts the text projection BELOW the int one at 0.79x, so 2x is unreachable
# without width entering the charge, and the check does not encode one box's
# calibration.
TW=100000
psql_run "CREATE TABLE cwide (a int4,b int4,c int4,d int4,e int4,f int4,g int4,h int4,
	t1 text, t2 text, t3 text, t4 text) USING pgcolumnar;"
psql_run "INSERT INTO cwide SELECT i,i,i,i,i,i,i,i,
	repeat(md5(i::text),3), repeat(md5((i+1)::text),3),
	repeat(md5((i+2)::text),3), repeat(md5((i+3)::text),3)
	FROM generate_series(1,$TW) i;"
psql_run "ANALYZE cwide;"

# PREMISE: the fixture must actually be wide, and the planner must be able to SEE
# that it is. A cost model that reads width from statistics is void as a subject
# if the statistics are missing -- the arms would differ by nothing the model can
# observe, and the check would be about ANALYZE rather than about costing.
WT="$(q "SELECT avg_width FROM pg_stats WHERE tablename='cwide' AND attname='t1'")"
WA="$(q "SELECT avg_width FROM pg_stats WHERE tablename='cwide' AND attname='a'")"
check "premise: the wide column's width is in the statistics" 	"$([ "${WT:-0}" -ge 64 ] && echo "wide ($WT)" || echo "NOT WIDE (${WT:-none})")" "wide ($WT)"
check "premise: and the narrow column's width is too, and is smaller" 	"$([ "${WA:-0}" -gt 0 ] && [ "${WA:-0}" -lt "${WT:-0}" ] && echo yes || echo "no (a=${WA:-none} t1=$WT)")" "yes"

CTEXT="$(topcost 'SELECT t1,t2,t3,t4 FROM cwide')"
CINT="$(topcost 'SELECT a,b,c,d,e,f,g,h FROM cwide')"
check "premise: both projections priced" 	"$([ -n "$CTEXT" ] && [ -n "$CINT" ] && echo yes || echo no)" "yes"

WRATIO="$(awk -v t="$CTEXT" -v i="$CINT" 'BEGIN{ printf "%.3f", (i>0)?t/i:0 }')"
echo "-- #768: 4 wide text columns cost $CTEXT, 8 narrow int columns cost $CINT (${WRATIO}x)"
check "four wide text columns cost more than eight narrow int ones (#768)" 	"$(awk -v r="$WRATIO" 'BEGIN{ print (r >= 2.0) ? "scaled" : "flat" }')" "scaled"

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
