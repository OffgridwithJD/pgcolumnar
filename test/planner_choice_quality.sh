#!/usr/bin/env bash
#
# The planner's chosen plan must not be catastrophically worse than one it
# declined (issues #433, #434).
#
# Every other suite asks whether a plan is CORRECT. None asks whether it is the
# one a reasonable cost model would pick. That gap is how #434 survived: the
# planner prices a columnar index scan at 31,502 and the custom scan at 69,204,
# then chooses the index scan, which is 12.4x slower. Both plans return the right
# answer, so every existing check passes.
#
# WHAT THIS ASSERTS
#
# For each query: run the planner's own choice, then force each alternative, and
# fail when the choice is more than PLAN_BOUND times slower than the best
# alternative. It is a ratio between two plans in the same run on the same box,
# so it does not depend on how fast the machine is.
#
# WHY THE BOUND IS LOOSE
#
# 3x. The point is not to police the cost model, which is allowed to be wrong.
# It is to catch the case where it is wrong by orders of magnitude, which is what
# #434 is. A tight bound here would flake on a shared runner and teach people to
# ignore it.
#
# WHY TIMING RATHER THAN BUFFERS
#
# Buffers would be exact, and they are the right tool when the question is "did
# this read less". Here the question is "is the chosen plan much slower", and
# slower is what the user experiences. The bound is loose enough to survive
# timing noise.
#
# PGC_SKIP_TIMING
#
# The ratios go through check_timing, so a shared runner skips them and still
# runs the premises. The first version of this file only SAID that in this
# comment and used check_ratio throughout, so the flag did nothing and the suite
# went red on every pull request until #434 is fixed. Under the flag the timed
# queries are also not executed at all: running them to discard the result would
# cost the matrix minutes per major to measure something no check reads.
#
# Usage:  test/planner_choice_quality.sh [PG_CONFIG]
# Written fresh for pgColumnar.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

PLAN_BOUND=${PGC_PLAN_BOUND:-3}
ROWS=${PGC_PLANQ_ROWS:-200000}
# The finding is "23x slower", not "slower than two minutes". A long timeout only
# buys a longer wait before the same verdict, on every major, for as long as the
# bug exists.
PLAN_TIMEOUT=${PGC_PLAN_TIMEOUT:-20}
SKIP_TIMING=${PGC_SKIP_TIMING:-0}

# The shape #433 and #434 are about: wide incompressible rows, an index on a
# correlated key. The payload must not compress, or the row group stays under the
# fetch cache cap and the effect disappears. Correlating on both g and the inner
# series is what makes every row and every block differ.
psql_run "CREATE TABLE pq (k bigint, tag text, payload bytea) USING pgcolumnar;
          INSERT INTO pq
          SELECT g, 'tag' || (g % 5),
                 decode((SELECT string_agg(md5(g::text || s::text), '')
                           FROM generate_series(1,64) s), 'hex')
          FROM generate_series(1,$ROWS) g;
          CREATE INDEX pq_k ON pq (k);
          ANALYZE pq;" >/dev/null

check "fixture rows" "$(q 'SELECT count(*) FROM pq')" "$ROWS"
SZ=$(q "SELECT pg_total_relation_size('pq')")
check "premise: the payload did not compress, so the fetch path is exercised" \
	"$([ "$SZ" -gt $(( ROWS * 700 )) ] && echo yes || echo "no ($(( SZ / ROWS )) bytes per row)")" "yes"
check "premise: the index key is correlated, which is the case that misprices" \
	"$(q "SELECT CASE WHEN correlation > 0.9 THEN 'yes' ELSE 'no (' || correlation || ')' END
	        FROM pg_stats WHERE tablename='pq' AND attname='k'")" "yes"

# Time a query under a given setting, and report which scan node ran.
run_plan() {  # run_plan <settings> <sql> -> "<node> <ms>"
	local node ms out
	node=$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq -c "$1" -c "EXPLAIN (COSTS OFF) $2" 2>&1 |
		grep -oE 'Index Only Scan|Index Scan|Bitmap Heap Scan|Custom Scan \([A-Za-z]+\)|Seq Scan' | head -1)
	# No execution under PGC_SKIP_TIMING. The plan name above comes from EXPLAIN,
	# so every premise still holds; only the wall clock is unavailable.
	if [ "$SKIP_TIMING" = 1 ]; then
		printf '%s\t\n' "${node:-unknown}"
		return
	fi
	out=$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq -c "SET statement_timeout='${PLAN_TIMEOUT}s';" -c "$1" -c '\timing on' -c "$2" 2>&1)
	if grep -qiE 'timeout|canceling' <<<"$out"; then
		printf '%s\tTIMEOUT\n' "${node:-unknown}"; return
	fi
	ms=$(grep -oE 'Time: [0-9.]+ ms' <<<"$out" | tail -1 | grep -oE '[0-9.]+')
	# Tab-delimited, because a node name contains spaces: "Custom Scan
	# (PgColumnarScan)" read back through a space-split gives node="Custom" and
	# ms="Scan (PgColumnarScan) 23.380". The first version of this file did that
	# and compared two garbage strings while reporting a pass.
	printf '%s\t%s\n' "${node:-unknown}" "${ms:-}"
}

# The planner's choice against the best alternative it declined.
choice_vs_best() {  # choice_vs_best <label> <sql>
	local label="$1" sql="$2"
	local chosen alt1 alt2 cnode cms best bnode

	IFS=$'\t' read -r cnode cms <<<"$(run_plan "" "$sql")"
	IFS=$'\t' read -r n1 m1 <<<"$(run_plan "SET enable_indexscan=off; SET enable_bitmapscan=off;" "$sql")"
	IFS=$'\t' read -r n2 m2 <<<"$(run_plan "SET pgcolumnar.enable_custom_scan=off; SET enable_seqscan=off;" "$sql")"

	echo "      $label: chose $cnode=${cms:-?}ms; alternatives $n1=${m1:-?}ms $n2=${m2:-?}ms"

	# A plan we could not name is a plan we did not measure. The first version of
	# this file reported "unknown" for an Index Only Scan, because "Index Scan"
	# does not match it, and then compared its time to another unknown.
	check "premise: [$label] the chosen plan was identified" \
		"$([ "$cnode" != unknown ] && echo yes || echo "no (grep matched no scan node)")" "yes"

	# Premise: the alternatives must really be different plans. If forcing changed
	# nothing, there is no choice to judge and the check below would compare a
	# plan with itself.
	check "premise: [$label] forcing produced a different plan" \
		"$([ "$n1" != "$cnode" ] || [ "$n2" != "$cnode" ] && echo yes || echo "no (all $cnode)")" "yes"

	# Everything below this line has a wall clock in it, including the timeout
	# check: "did not finish in N seconds" is a statement about the runner as much
	# as about the plan. check_timing announces the skip and does not count it as a
	# pass, which is the contract the rest of the suite already follows.
	if [ "$SKIP_TIMING" = 1 ]; then
		check_timing "[$label] the chosen plan is within ${PLAN_BOUND}x of the best alternative" "" ""
		return
	fi

	best=""; bnode=""
	# Node and time kept in separate variables rather than re-split from a string.
	for i in 1 2; do
		eval "cand_n=\$n$i; cand_m=\$m$i"
		case "${cand_m:-}" in '' | TIMEOUT | unknown) continue ;; esac
		if [ -z "$best" ] || [ "$(awk -v a="$cand_m" -v b="$best" 'BEGIN{print (a<b)?1:0}')" = 1 ]; then
			best="$cand_m"; bnode="$cand_n"
		fi
	done
	# A plan we could not identify is not an alternative we can judge against.
	check "premise: [$label] at least one alternative produced a timing" \
		"$([ -n "$best" ] && echo yes || echo no)" "yes"
	[ -n "$best" ] || return

	if [ "$cms" = TIMEOUT ]; then
		check "[$label] the chosen plan finished at all" "TIMEOUT after ${PLAN_TIMEOUT}s" "under the bound"
		return
	fi
	check_ratio "[$label] the chosen plan is within ${PLAN_BOUND}x of the best alternative ($bnode)" \
		"$cms" "$best" "$PLAN_BOUND"
}

echo "   planner choice against the best declined alternative, bound ${PLAN_BOUND}x"
choice_vs_best "range scan with aggregate" \
	"SELECT tag, count(*) FROM pq WHERE k > $(( ROWS * 4 / 5 )) GROUP BY tag"
choice_vs_best "wide range, narrow projection" \
	"SELECT count(*) FROM pq WHERE k > $(( ROWS / 2 ))"

pgc_summary
