#!/usr/bin/env bash
#
# sum(bigint) on the vectorized path must not be SLOWER than off it (#785).
#
# This is the only arm that can see the #785 fix removed, and it lives in its own
# file for that reason.
#
# WHY IT IS NOT IN int8_agg_int128.sh. That suite's 22 value arms cannot detect
# the fix being reverted: reverting it restores the per-row numeric
# accumulation, which is CORRECT and merely slow, so all 22 stay green. The
# defect was speed. But PGC_SKIP_TIMING=1 is set in both ci.yml and
# nightly.yml, so a wall-clock ratio inside that file would be skipped in every
# automated gate while the value arms still reported PASSED -- a suite passing
# with its subject dropped.
#
# Alone in a file listed in is_timing_suite, the driver instead names this suite
# skipped in its "(N ran, M skipped)" line, so a reader can see the guard did not
# run. run_all_versions.sh already records that reasoning for
# planner_choice_quality: "a suite whose subject is dropped has not passed, and
# the driver already knows how to say that."
#
# THE ASSERTION IS A BOUND, NOT A TARGET. "Not slower than the scalar path" is
# exactly the defect #785 describes, and it does not encode how fast this
# machine happens to be. The gap it must detect is wide: the same query was 2.03x
# slower before the fix and 1.65x faster after, so the bound sits in a swing of
# more than 3x rather than in the noise. Reverting the fix reddens it at 3.68x.
#
# Usage:  test/int8_agg_int128_timing.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ON="SET pgcolumnar.enable_ungrouped_vector_agg=on"
vecplan() { q "$ON; EXPLAIN (COSTS OFF) SELECT $1 FROM $2;" | grep -c 'Columnar Vectorized Aggregates'; }

psql_run "CREATE TABLE perf8 (v bigint) USING pgcolumnar;"
psql_run "INSERT INTO perf8 SELECT (g % 1000)::bigint FROM generate_series(1,4000000) g;"
check_num "premise: the fixture loaded every row" "$(q 'SELECT count(*) FROM perf8;')" "4000000"
check_num "premise: the vectorized node really runs, so the ratio compares two paths" \
	"$(vecplan 'sum(v)' perf8)" "1"
check "premise: and the answer is right, so this is not timing a broken path" \
	"$(q "$ON; SELECT sum(v)::text FROM perf8;" | tail -1)" "1998000000"

# min of 5 each, INTERLEAVED: this host is contended and order-dependent, so a
# block design attributes drift to whichever arm ran second.
ms() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -q \
		-c "SET pgcolumnar.enable_ungrouped_vector_agg=$1" -c '\timing on' \
		-c "SELECT sum(v) FROM perf8" 2>/dev/null \
	| grep -o 'Time: [0-9.]*' | tail -1 | cut -d' ' -f2
}
BON=""; BOFF=""
for _ in 1 2 3 4 5; do
	x="$(ms on)"; y="$(ms off)"
	[ -z "$BON" ] && BON="$x"; [ -z "$BOFF" ] && BOFF="$y"
	BON="$(awk -v a="$BON" -v b="$x" 'BEGIN{print (b<a)?b:a}')"
	BOFF="$(awk -v a="$BOFF" -v b="$y" 'BEGIN{print (b<a)?b:a}')"
done
echo "-- sum(bigint): vectorized $BON ms, scalar $BOFF ms"
check_ratio_timing "the vectorized path is not slower than the scalar one" "$BON" "$BOFF" "1.10"

pgc_summary
