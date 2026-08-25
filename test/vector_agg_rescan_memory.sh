#!/usr/bin/env bash
#
# pgColumnar #717: the vectorized aggregates must not stack a fresh set of
# pushdown scan keys in query memory on every rescan.
#
# The scalar custom scan builds its scan keys once at Begin and reuses them. The
# vectorized aggregate paths rebuild them at Exec, so a rescan (a LATERAL or
# parameterized aggregate sub-scan) built them again, into es_query_cxt, which
# lives until ExecutorEnd. Since #704 the build of an `IN (...)` key also
# detoasts the array constant and deconstructs it into elems and nulls, so the
# growth is O(rescans x array size) rather than O(rescans).
#
# Measured before the fix on 2000 rescans with a 20000-element IN-list:
# ExecutorState peaked at 362,877,504 bytes. An independent prediction from the
# mechanism alone -- 2000 x (20000 Datums + 20000 bools) -- is about 343 MB, and
# the two agreeing is what identifies the growth as THIS defect rather than
# something else that also consumes memory. After the fix, 1,572,928 bytes.
#
# THE ASSERTION HERE IS A DIFFERENTIAL, NOT A BOUND, and deliberately so.
#
# An absolute byte limit has to be picked against one machine's block sizes and
# one fixture's shape, and it silently stops meaning anything when either moves.
# Worse, it would charge this defect for memory it does not cause: the aggregate
# rescan path grows about 655 bytes per rescan WITH OR WITHOUT an IN-list, at
# slopes that measure identical, so that part is a different leak and is filed
# separately. Subtracting a no-IN-list control removes it exactly, and leaves
# only what adding the IN-list costs.
#
# Measured with the fix reverted: 179,877 bytes per rescan with a
# 20000-element IN-list against 655 without, an excess of 179,222. A prediction
# from the mechanism alone -- one Datum and one bool per element, 20000 x 9 --
# is 180,000, and the two agreeing to 0.07% is what identifies the growth as
# THIS defect rather than something else that also consumes memory. With the fix
# the two slopes are 655 and 655, an excess of zero. The control arm reads
# byte-identical before and after (131,072 -> 2,097,152 either way), which is
# what says the fix changed only the thing it claims to.
# The instrument is pg_log_backend_memory_contexts() called from a second
# session against the running backend, with the MAX taken across samples, so
# the reading does not depend on catching one particular instant.
#
# Usage:  test/vector_agg_rescan_memory.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$1" 2>&1
}
q1() { q "$1" | tail -1; }

NELEM=20000
SMALL=200
LARGE=3200

psql_run "CREATE TABLE vam(k int, v int) USING pgcolumnar;"
psql_run "INSERT INTO vam SELECT g % 5000, g FROM generate_series(1,50000) g;"
psql_run "CREATE TABLE vam_drv(i int);"
psql_run "INSERT INTO vam_drv SELECT g FROM generate_series(1,$LARGE) g;"
psql_run "ANALYZE vam; ANALYZE vam_drv;"

INLIST="$(q1 "SELECT string_agg(g::text, ',') FROM generate_series(1,$NELEM) g;")"
GUC="SET pgcolumnar.enable_ungrouped_vector_agg=on; SET enable_material=off;"

# The correlated `v > d.i` is a PARAM_EXEC, deliberately NOT frozen into a scan
# key, so it stays a residual qual and the node keeps rescanning. The IN-list is
# the Const that gets rebuilt, detoasted and deconstructed on each of those
# rescans, and it is the only difference between the two arms below.
mkq() {	# mkq NROWS [nokeys] -> the query, driven by NROWS rescans
	if [ "${2:-}" = nokeys ]; then
		printf 'SELECT sum(s.c) FROM (SELECT i FROM vam_drv LIMIT %s) d, LATERAL (SELECT count(*) c FROM vam WHERE v > d.i) s' "$1"
	else
		printf 'SELECT sum(s.c) FROM (SELECT i FROM vam_drv LIMIT %s) d, LATERAL (SELECT count(*) c FROM vam WHERE k IN (%s) AND v > d.i) s' "$1" "$INLIST"
	fi
}

check_num "premise: the fixture loaded" "$(q1 'SELECT count(*) FROM vam;')" 50000

# The premise the whole measurement rests on: this query's IN-list really does
# become pushdown scan keys, so there is something per-rescan to rebuild. Read
# under ANALYZE and not plain EXPLAIN, because the ungrouped node does not fill
# its scan-key count in before the EXPLAIN-only return and a plain EXPLAIN
# reports 0 whatever the truth is (#726) -- so a plain-EXPLAIN premise here
# would refuse every arm for a reason that has nothing to do with this defect.
keyed_plan="$(q "$GUC EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY OFF) $(mkq 2)")"
keyed="$(grep 'Columnar Pushed-Down Filters' <<<"$keyed_plan" | grep -oE '[0-9]+' | head -1)"
check_num "premise: the IN-list really becomes pushdown scan keys" \
	"$([ -n "$keyed" ] && [ "$keyed" -gt 0 ] && echo 1 || echo 0)" 1
echo "      (Columnar Pushed-Down Filters = ${keyed:-unset})"

# peak_executor_state NROWS [nokeys] -> max "ExecutorState: N total" while it ran
#
# Asserts the execution path on the way past, because every number below is void
# without it: it must be OUR aggregate node, under a Nested Loop (so it rescans
# at all), with no Materialize (which would rescan a stored tuplestore instead
# of re-executing the node, and re-executing the node is the whole subject).
#
# There is deliberately no "= ANY" check here. This node absorbs its quals, so
# EXPLAIN prints no Filter line for it at all, and an assertion on the rendered
# qual text silently refuses every arm. The scan-key premise above covers it.
peak_executor_state() {	# -> bytes, or empty when the path assertion refuses
	local nrows="$1" variant="${2:-}" query fifo out marker pid="" n=0 mark peak plan
	query="$(mkq "$nrows" "$variant")"

	plan="$(q "$GUC EXPLAIN (COSTS OFF) $query")"
	if ! grep -q 'Columnar Vectorized Aggregates' <<<"$plan" ||
	   ! grep -q 'Nested Loop' <<<"$plan" ||
	     grep -q 'Materialize' <<<"$plan"; then
		echo ""
		return 1
	fi

	fifo="$PGC_WORKDIR/vam.$nrows$variant.fifo"; out="$fifo.out"
	rm -f "$fifo" "$out"; mkfifo "$fifo"
	marker="vam_done_$nrows$variant"
	q "DROP TABLE IF EXISTS $marker;" >/dev/null

	env PATH="$PGC_BINDIR:$PATH" PGAPPNAME="pgc717_$nrows$variant" \
		psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -At \
		< "$fifo" > "$out" 2>&1 &
	exec 9> "$fifo"
	echo "SELECT 1;" >&9
	while [ -z "$pid" ] && [ $n -lt 200 ]; do
		pid="$(q1 "SELECT pid FROM pg_stat_activity WHERE application_name = 'pgc717_$nrows$variant' LIMIT 1;")"
		n=$((n+1)); [ -z "$pid" ] && sleep 0.1
	done
	if [ -z "$pid" ]; then exec 9>&-; echo ""; return 1; fi

	mark=$(wc -l < "$PGC_LOGFILE")
	echo "$GUC $query;" >&9
	echo "CREATE TABLE $marker(x int);" >&9
	n=0
	while [ "$(q1 "SELECT to_regclass('$marker') IS NOT NULL;")" != t ] && [ $n -lt 3000 ]; do
		q "SELECT pg_log_backend_memory_contexts($pid);" >/dev/null
		n=$((n+1)); sleep 0.1
	done
	exec 9>&-; wait 2>/dev/null
	rm -f "$fifo" "$out"
	q "DROP TABLE IF EXISTS $marker;" >/dev/null

	peak="$(tail -n +"$mark" "$PGC_LOGFILE" |
		grep -oE 'ExecutorState: [0-9]+ total' | grep -oE '[0-9]+' |
		sort -n | tail -1)"
	printf '%s' "$peak"
}

with_small="$(peak_executor_state "$SMALL")"
with_large="$(peak_executor_state "$LARGE")"
without_small="$(peak_executor_state "$SMALL" nokeys)"
without_large="$(peak_executor_state "$LARGE" nokeys)"

for v in with_small with_large without_small without_large; do
	check_num "premise: the $v arm produced a reading" \
		"$([ -n "${!v}" ] && [ "${!v}" -gt 0 ] && echo 1 || echo 0)" 1
done

# Bytes of query memory per rescan, as a SLOPE across two rescan counts, so the
# fixed setup cost cancels instead of dominating the small arm.
slope() { awk -v a="$1" -v b="$2" -v n="$(( LARGE - SMALL ))" 'BEGIN { printf "%d", (a - b) / n }'; }
with_slope="$(slope "$with_large" "$with_small")"
without_slope="$(slope "$without_large" "$without_small")"
echo "      per-rescan growth: with a ${NELEM}-element IN-list = ${with_slope} B, without one = ${without_slope} B"
echo "      (peaks: with ${with_small} -> ${with_large}; without ${without_small} -> ${without_large})"

# THE CLAIM, as a DIFFERENTIAL against the no-IN-list control rather than an
# absolute bound.
#
# A bound would have to be picked against one machine's block sizes, and it
# would also be measuring something this defect is not responsible for: the
# aggregate rescan path grows about 0.65 KB per rescan WITH OR WITHOUT the
# IN-list, at identical slopes, so that part is a separate leak (filed
# separately) and not #717. Subtracting the control removes it exactly.
#
# What #717 costs is the difference: before the fix, adding the IN-list added
# about 180,000 bytes per rescan (90,752,384 bytes over 500 rescans at 20000
# elements, against 524,288 flat without it). After it, the two slopes are the
# same to within block quantisation. The 20,000-byte gate sits nine times below
# the defect and far above the noise.
excess="$(awk -v a="$with_slope" -v b="$without_slope" 'BEGIN { d = a - b; print (d < 0 ? 0 : d) }')"
echo "      excess attributable to the IN-list: ${excess} bytes per rescan"
check_num "an IN-list does not add per-rescan query memory (#717)" \
	"$([ "$excess" -lt 20000 ] && echo 1 || echo 0)" 1

pgc_summary
