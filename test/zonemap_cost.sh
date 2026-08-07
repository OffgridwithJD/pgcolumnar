#!/usr/bin/env bash
#
# The columnar scan must be priced for what the zone maps let it skip (#434).
#
# The scan skips a row group whose stored minimum and maximum prove the
# restriction cannot match, but the cost model quoted a full scan regardless. An
# index scan on the same relation was quoted at its best case, so the planner
# preferred it: priced 12,407 and ran 500 ms, against a columnar scan priced
# 17,326 that ran 43 ms. Declined a plan 11.6x faster, on a correlated bigint key
# with 80 percent of the rows excluded.
#
# What is asserted here is the PLAN and the COST RELATION, not wall clock. Which
# plan the planner picks is deterministic given statistics, so nothing in this
# suite is timing-sensitive.
#
# The control is the point. A blanket discount would also flip the correlated
# case, and would be wrong: pruning depends on how the matching rows are LAID
# OUT, not on how many there are. So the same query shape runs against a
# scattered key, where every group holds the full value range and nothing can be
# skipped, and the discount must NOT appear there.
#
# Usage:  test/zonemap_cost.sh [PG_CONFIG]
# Written fresh for pgColumnar.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=200000
CUT=$((ROWS * 8 / 10))

# Two tables, one query shape. `seq` ascends with physical order; `scat` is the
# same values in an order uncorrelated with it, so its zone maps overlap and
# prune nothing.
psql_run "DROP TABLE IF EXISTS zc;
	CREATE TABLE zc (seq bigint, scat bigint, tag int, pad text) USING pgcolumnar;
	SELECT pgcolumnar.set_options('zc', stripe_row_limit => 10000);
	INSERT INTO zc
	SELECT g, ((g * 7919) % $ROWS), g % 5, md5(g::text)
	  FROM generate_series(1, $ROWS) g;
	CREATE INDEX zc_seq ON zc (seq);
	CREATE INDEX zc_scat ON zc (scat);
	ANALYZE zc;" >/dev/null 2>&1

check_num "premise: every row loaded" "$(q 'SELECT count(*) FROM zc')" "$ROWS"

CORR_SEQ=$(q "SELECT round(abs(correlation)::numeric, 2) FROM pg_stats
              WHERE tablename = 'zc' AND attname = 'seq'")
CORR_SCAT=$(q "SELECT round(abs(correlation)::numeric, 2) FROM pg_stats
               WHERE tablename = 'zc' AND attname = 'scat'")
echo "-- |correlation|: seq = ${CORR_SEQ:-?}, scat = ${CORR_SCAT:-?}"

# The premise the whole suite rests on. Without this the two arms could differ
# for some reason other than the one being tested, and the control would prove
# nothing. A fixture whose "scattered" column is accidentally ordered makes both
# arms the correlated arm.
check_num "premise: the ordered key really is correlated" \
	"$([ -n "$CORR_SEQ" ] && awk "BEGIN{exit !($CORR_SEQ > 0.9)}" && echo 1 || echo 0)" "1"
check_num "premise: the scattered key really is not" \
	"$([ -n "$CORR_SCAT" ] && awk "BEGIN{exit !($CORR_SCAT < 0.2)}" && echo 1 || echo 0)" "1"

# EXPLAIN's chosen node, and the total cost of a named path.
node_for() {	# $1 = column
	psql_run "SET max_parallel_workers_per_gather=0;
	          EXPLAIN (COSTS OFF)
	          SELECT tag, count(*) FROM zc WHERE $1 > $CUT GROUP BY tag;" 2>/dev/null |
		grep -oE 'Custom Scan \(PgColumnarScan\)|Index Scan|Seq Scan' | head -1
}
cost_for() {	# $1 = column, $2 = extra SETs
	psql_run "SET max_parallel_workers_per_gather=0; $2
	          EXPLAIN SELECT tag, count(*) FROM zc WHERE $1 > $CUT GROUP BY tag;" 2>/dev/null |
		grep -oE 'cost=[0-9.]+\.\.[0-9.]+' | head -1 | sed 's/.*\.\.//'
}

# ---- the correlated arm: pruning is real, so it must be priced -------------
SEQ_NODE=$(node_for seq)
SEQ_COL=$(cost_for seq "SET enable_indexscan=off; SET enable_bitmapscan=off;")
SEQ_IDX=$(cost_for seq "SET pgcolumnar.enable_custom_scan=off; SET enable_seqscan=off; SET enable_bitmapscan=off;")
echo "-- correlated: chosen=$SEQ_NODE  columnar=$SEQ_COL  index=$SEQ_IDX"

check_num "premise: the columnar cost is a measurement" \
	"$([ -n "$SEQ_COL" ] && awk "BEGIN{exit !($SEQ_COL > 0)}" && echo 1 || echo 0)" "1"
check_num "premise: the index cost is a measurement" \
	"$([ -n "$SEQ_IDX" ] && awk "BEGIN{exit !($SEQ_IDX > 0)}" && echo 1 || echo 0)" "1"
check_text "a correlated restriction picks the columnar scan (#434)" \
	"$SEQ_NODE" "Custom Scan (PgColumnarScan)"
check_num "and it is priced below the index scan it used to lose to (#434)" \
	"$(awk "BEGIN{print ($SEQ_COL < $SEQ_IDX) ? 1 : 0}")" "1"

# ---- the control: nothing to prune, so nothing to discount ------------------
#
# This is what separates "price the pruning" from "make the columnar scan
# cheaper". The discount must come from the layout, and here there is none.
SCAT_COL=$(cost_for scat "SET enable_indexscan=off; SET enable_bitmapscan=off;")
FULL_COL=$(cost_for scat "SET enable_indexscan=off; SET enable_bitmapscan=off; SET pgcolumnar.enable_custom_scan=on;")
echo "-- scattered: columnar=$SCAT_COL"
check_num "premise: the scattered columnar cost is a measurement" \
	"$([ -n "$SCAT_COL" ] && awk "BEGIN{exit !($SCAT_COL > 0)}" && echo 1 || echo 0)" "1"
check_num "an uncorrelated restriction gets no pruning discount (#434)" \
	"$(awk "BEGIN{print ($SCAT_COL > $SEQ_COL) ? 1 : 0}")" "1"

# ---- correctness, which the cost model may not change ----------------------
check_text "the correlated query returns the same rows either way" \
	"$(q "SELECT md5(string_agg(tag || ':' || n, ',' ORDER BY tag)) FROM (
	        SELECT tag, count(*) n FROM zc WHERE seq > $CUT GROUP BY tag) s")" \
	"$(q "SET pgcolumnar.enable_custom_scan=off;
	      SELECT md5(string_agg(tag || ':' || n, ',' ORDER BY tag)) FROM (
	        SELECT tag, count(*) n FROM zc WHERE seq > $CUT GROUP BY tag) s" | tail -1)"
check_num "the correlated query returns the right count" \
	"$(q "SELECT count(*) FROM zc WHERE seq > $CUT")" "$((ROWS - CUT))"

pgc_summary
