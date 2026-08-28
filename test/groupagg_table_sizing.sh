#!/usr/bin/env bash
#
# pgColumnar: the vectorized grouped aggregate sizes its hash table from the
# group estimate the planner already made, instead of growing it from nothing
# (#403 item 6).
#
# The table is open-addressing, starts at capacity 0, and doubles whenever the
# live count reaches 70% of capacity. A query with 200,000 groups therefore walks
# 1024, 2048, ... , 524288, and every step rehashes every live entry into the new
# array. Measured on 2,000,000 rows before the change: 10 allocations and 366,285
# entries rehashed.
#
# WHAT IS COUNTED, and why it is not the resize count. The first instrument here
# counted resizes, and it flattered the change: sizing removed 7 of 10 resizes
# while removing only about a quarter of the rehashing, because the work is
# dominated by the last two steps and those are the ones a low estimate leaves
# behind. Entries rehashed is the work; the resize count is kept only as a
# diagnostic. A saving must be measured as work removed, not as steps removed.
#
# WHY n_distinct IS DECLARED rather than sampled. ANALYZE's n_distinct estimator
# is a sample, and on this shape two runs of the same fixture gave 91,750 and
# 209,338 for the same 200,000 groups. Asserting against a sampled estimate makes
# the suite fail on the sample rather than on the code. The suite declares
# n_distinct so the estimate is fixed, which tests OUR sizing rather than
# PostgreSQL's estimator.
#
# WHY work_mem IS SET. The up-front allocation is clamped by work_mem, so at the
# 4MB default a 200,000-group table cannot be pre-sized at all and the check
# would pin the clamp rather than the sizing. The clamp gets its own arm below,
# where it is the thing under test.
#
# Usage:  test/groupagg_table_sizing.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

NROWS=2000000
NGROUPS=200000
ENTRY_BYTES=32			# sizeof(PgColumnarGroupEntry) on a 64-bit build

psql_run "CREATE TABLE gts (k int, v int) USING pgcolumnar;"
psql_run "INSERT INTO gts SELECT i % $NGROUPS, i FROM generate_series(1,$NROWS) i;"
psql_run "ALTER TABLE gts ALTER COLUMN k SET (n_distinct = $NGROUPS);"
psql_run "ANALYZE gts;"

ON="SET pgcolumnar.enable_group_vectorization=on;"
BIG="SET work_mem='64MB';"

explain_with() {	# $1 = extra SET, $2 = query
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -Atq \
		-c "$ON $1 EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) $2" 2>&1
}
q1() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -Atq \
		-c "$1" 2>&1 | tail -1
}
field() {	# $1 = plan text, $2 = EXPLAIN label
	sed -n "s/.*$2: \([0-9]*\).*/\1/p" <<<"$1" | head -1
}

PLAN="$(explain_with "$BIG" "SELECT k, sum(v) FROM gts GROUP BY k")"

# ---- premises -------------------------------------------------------------
# The grouped vectorized path is OFF by default, so "the GUC took effect" is the
# premise that can silently fail and leave these numbers describing some other
# node.
check "premise: the vectorized grouped aggregate is the node that ran" \
	"$(grep -q 'Columnar Vectorized Group Keys' <<<"$PLAN" && echo yes \
	   || echo "no -- $(grep -m1 -oE 'HashAggregate|GroupAggregate|Custom Scan' <<<"$PLAN")")" "yes"

check "premise: it built the group count this suite is sized for" \
	"$(q1 "SELECT count(DISTINCT k) FROM gts")" "$NGROUPS"

check "premise: the work-done counter is reported at all" \
	"$(grep -qE 'Columnar Group Table Entries Rehashed: [0-9]+' <<<"$PLAN" && echo yes || echo no)" "yes"

EST="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -Atq \
	-c "$ON $BIG EXPLAIN (COSTS ON) SELECT k, sum(v) FROM gts GROUP BY k" 2>&1 \
	| sed -n 's/.*rows=\([0-9]*\).*width.*/\1/p' | head -1)"
check "premise: the declared n_distinct reached the planner, so the estimate is not a sample" \
	"$(awk -v e="${EST:-0}" -v t="$NGROUPS" \
	   'BEGIN { print (e >= 0.9 * t && e <= 1.1 * t) ? "accurate" : "SAMPLED (" e ")" }')" "accurate"

# ---- the check ------------------------------------------------------------
REHASHED="$(field "$PLAN" 'Columnar Group Table Entries Rehashed')"
RESIZES="$(field "$PLAN" 'Columnar Group Table Resizes')"
INITCAP="$(field "$PLAN" 'Columnar Group Table Initial Capacity')"

# What growing from nothing would have cost, computed from the observed group
# count rather than pinned from a previous build: the ladder rehashes 70% of each
# capacity it leaves behind, which sums to 0.7 * (final - 1024).
LADDER="$(awk -v g="$NGROUPS" 'BEGIN {
	c = 1024; while (c * 0.7 < g) c *= 2;
	printf "%d", 0.7 * (c - 1024);
}')"
echo "-- $NGROUPS groups: $REHASHED entries rehashed over $RESIZES allocations, initial capacity $INITCAP"
echo "-- growing from nothing would rehash about $LADDER"

check "a table sized from the estimate rehashes nothing (#403 item 6)" \
	"$([ "${REHASHED:-1}" -eq 0 ] && echo "no rehashing" \
	   || echo "REHASHED $REHASHED of about $LADDER")" "no rehashing"

check "and it is built in one allocation rather than a ladder (#403 item 6)" \
	"$([ "${RESIZES:-99}" -le 1 ] && echo "one" || echo "$RESIZES allocations from $INITCAP")" "one"

# ---- the clamp arm --------------------------------------------------------
# Sizing from an estimate trades bounded rehashing for unbounded memory unless
# the up-front allocation is clamped. work_mem is the budget the rest of the
# executor sizes against, and this arm is the one that fails if the clamp is
# removed. It does NOT claim the table stays under work_mem afterwards: the
# doubling ladder is unchanged and still grows past it, exactly as before this
# change. The clamp bounds what is allocated SPECULATIVELY.
SMALL_PLAN="$(explain_with "SET work_mem='1MB';" "SELECT k, sum(v) FROM gts GROUP BY k")"
SMALLCAP="$(field "$SMALL_PLAN" 'Columnar Group Table Initial Capacity')"
CAPBOUND=$(( 1024 * 1024 / ENTRY_BYTES ))
echo "-- work_mem 1MB: initial capacity $SMALLCAP, bound $CAPBOUND"

check "premise: the same query wanted more than that up front, or there is nothing to clamp" \
	"$([ "${INITCAP:-0}" -gt "$CAPBOUND" ] && echo "wanted more" \
	   || echo "NOTHING TO CLAMP (wanted $INITCAP, bound $CAPBOUND)")" "wanted more"

check "a small work_mem clamps the up-front allocation (#403 item 6)" \
	"$([ "${SMALLCAP:-0}" -gt 0 ] && [ "${SMALLCAP:-0}" -le "$CAPBOUND" ] && echo "clamped" \
	   || echo "UNCLAMPED ($SMALLCAP entries, bound $CAPBOUND)")" "clamped"

check "and the answer is the same under either budget" \
	"$(q1 "SET work_mem='1MB'; SELECT count(*) FROM (SELECT k, sum(v) FROM gts GROUP BY k) s")" "$NGROUPS"

check "the aggregate itself is still right" \
	"$(q1 "SELECT sum(s) FROM (SELECT k, sum(v) AS s FROM gts GROUP BY k) t")" \
	"$(q1 "SELECT sum(v)::numeric FROM gts")"

pgc_summary
