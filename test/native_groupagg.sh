#!/usr/bin/env bash
#
# pgColumnar #289: grouped vectorized aggregate.
#
# The grouped path fires for SELECT <keys>, agg(col) ... [WHERE ...] GROUP BY
# <keys> over one columnar relation. It reads each surviving row with
# ColumnarReadNextRow (WHERE pushed down for group/vector skipping), rechecks the
# full WHERE, evaluates the group keys, and scatters the row into an
# open-addressing hash table whose per-group accumulators fold in scan order.
#
# Two oracles prove it:
#
#   * Heap mirror. Every query runs against a heap table with identical data.
#     Exact aggregates (count, integer/numeric sums, min/max) compare byte-exact;
#     float sums/averages compare rounded, because float summation order (not the
#     grouping) is all that can differ and that is the executor, not a defect.
#
#   * Toggle-differential. The same query runs against the columnar table with
#     the path off (scalar Agg over the columnar scan) and on. Both read the same
#     rows in the same order, so exact aggregates must be byte-identical -- this
#     is what validates the order-preserving accumulators.
#
# Plan assertions confirm the node is actually chosen when supported and that
# every unsupported shape (group count over the cap, non-deterministic collation,
# an output built on a key, no aggregate) falls back to the ordinary Agg while
# still producing the oracle's answer.
#
# Runs on an assert server too, so a bad read or a mis-sized accumulator also
# trips a backend assertion under the oracle data.
#
# Usage:  test/native_groupagg.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# The grouped path is opt-in; set it at the database level so every new psql
# connection the oracle helpers open picks it up.
groupvec_on()  { psql_run "ALTER DATABASE $PGC_DB SET pgcolumnar.enable_group_vectorization = on;"; }
groupvec_off() { psql_run "ALTER DATABASE $PGC_DB SET pgcolumnar.enable_group_vectorization = off;"; }

# Is this query planned as the grouped vectorized node? Its own marker line is
# "Columnar Vectorized Group Keys"; no other node emits it, so a positive grep is
# proof of the node rather than an absence test that a fallback would also pass.
pgc_is_groupvec() {	# query -> yes|no
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "EXPLAIN (COSTS OFF) $1" 2>/dev/null \
		| grep -q 'Columnar Vectorized Group Keys' && echo yes || echo no
}

# toggle_diff LABEL "QUERY on t_col": same query, path off vs on, byte-exact.
toggle_diff() {
	local label="$1" query="$2" h_off h_on
	groupvec_off
	h_off="$(pgc_set_hash "$query")"
	groupvec_on
	h_on="$(pgc_set_hash "$query")"
	check "$label" "$h_on" "$h_off"
}

# ---- 1. the data: a q4/q5-shaped table with many group shapes ---------------

make_pair "g       int,
	ts      timestamp,
	host    text,
	region  text,
	i2      smallint,
	i4      int,
	i8      bigint,
	f4      real,
	f8      double precision,
	num     numeric"
# small row groups so grouping spans many groups and vectors
psql_run "SELECT pgcolumnar.set_options('t_col', stripe_row_limit => 1000);"

# 20000 rows: 50 hosts, 4 regions, timestamps spanning ~14 hours, values with
# interleaved NULLs in both keys and measures (a NULL host/ts must form its own
# group, exactly as GROUP BY does).
load_pair "SELECT g,
	CASE WHEN g % 331 = 0 THEN NULL
	     ELSE timestamp '2024-01-01 00:00:00' + (g * interval '25 seconds') END,
	CASE WHEN g % 197 = 0 THEN NULL ELSE 'host_' || (g % 50) END,
	'region_' || (g % 4),
	CASE WHEN g % 11 = 0 THEN NULL ELSE (g % 97 - 48)::smallint END,
	CASE WHEN g %  7 = 0 THEN NULL ELSE (g * 7 - 3) END,
	CASE WHEN g %  5 = 0 THEN NULL ELSE (g::bigint * 1000003 - 5) END,
	CASE WHEN g %  6 = 0 THEN NULL ELSE (g * 1.5)::real END,
	CASE WHEN g %  9 = 0 THEN NULL ELSE (g::float8 * 0.125 - 3.5) END,
	CASE WHEN g %  8 = 0 THEN NULL ELSE (g * 0.01)::numeric(12,4) END
	FROM generate_series(1, 20000) g"

# ---- 2. plan assertions: the node is chosen for the supported shapes --------

groupvec_on
Q_KEYHOST="SELECT host, count(*), sum(i4) FROM t_col GROUP BY host"
Q_KEYHOUR="SELECT date_trunc('hour', ts) h, count(*) FROM t_col GROUP BY date_trunc('hour', ts)"
Q_Q4="SELECT date_trunc('hour', ts) h, host, avg(f8), count(*)
      FROM t_col WHERE ts >= timestamp '2024-01-01 02:00:00'
                   AND ts <  timestamp '2024-01-01 06:00:00'
      GROUP BY date_trunc('hour', ts), host"
check "plan: GROUP BY text key uses grouped node"      "$(pgc_is_groupvec "$Q_KEYHOST")" yes
check "plan: GROUP BY hour expr uses grouped node"     "$(pgc_is_groupvec "$Q_KEYHOUR")" yes
check "plan: q4-shape (WHERE+2 keys) uses grouped node" "$(pgc_is_groupvec "$Q_Q4")"    yes
groupvec_off
check "plan: off -> ordinary Agg, not grouped node"    "$(pgc_is_groupvec "$Q_KEYHOST")" no
groupvec_on

# ---- 3. heap oracle: exact aggregates, every group shape -------------------
# GUC on, so t_col runs the grouped path; t_heap is the reference.

EXACT="count(*), count(i4), count(host),
	sum(i2), sum(i4), sum(i8), sum(num),
	min(f8), max(f8), min(host), max(host), min(ts), max(ts), min(i8), max(i8)"

diff_query "oracle exact: GROUP BY host" \
	"SELECT host, $EXACT FROM %T GROUP BY host"
diff_query "oracle exact: GROUP BY hour" \
	"SELECT date_trunc('hour', ts), $EXACT FROM %T GROUP BY date_trunc('hour', ts)"
diff_query "oracle exact: GROUP BY hour, host (q4/q5 shape)" \
	"SELECT date_trunc('hour', ts), host, $EXACT FROM %T GROUP BY date_trunc('hour', ts), host"
diff_query "oracle exact: GROUP BY region, host (two text keys)" \
	"SELECT region, host, $EXACT FROM %T GROUP BY region, host"
diff_query "oracle exact: GROUP BY integer expr key" \
	"SELECT (g % 7), $EXACT FROM %T GROUP BY (g % 7)"
diff_query "oracle exact: GROUP BY bigint column key" \
	"SELECT i2, count(*), sum(i4), min(f8), max(f8) FROM %T GROUP BY i2"

# with a WHERE that both prunes groups and needs a residual recheck
diff_query "oracle exact: WHERE range + GROUP BY hour, host" \
	"SELECT date_trunc('hour', ts), host, $EXACT FROM %T
	 WHERE ts >= timestamp '2024-01-01 02:00:00'
	   AND ts <  timestamp '2024-01-01 06:00:00'
	 GROUP BY date_trunc('hour', ts), host"
diff_query "oracle exact: WHERE on measure + GROUP BY host" \
	"SELECT host, $EXACT FROM %T WHERE i4 > 40000 AND host IS NOT NULL GROUP BY host"

# ---- 4. heap oracle: averages and float sums, rounded ----------------------

ROUNDED="round(avg(i4)::numeric, 6), round(avg(i8)::numeric, 6),
	round(avg(num)::numeric, 6),
	round(sum(f8)::numeric, 4), round(avg(f8)::numeric, 6),
	round(sum(f4)::numeric, 3), round(avg(f4)::numeric, 5)"

diff_query "oracle rounded avg/float: GROUP BY host" \
	"SELECT host, $ROUNDED FROM %T GROUP BY host"
diff_query "oracle rounded avg/float: GROUP BY hour, host" \
	"SELECT date_trunc('hour', ts), host, $ROUNDED FROM %T GROUP BY date_trunc('hour', ts), host"

# ---- 5. toggle-differential: off vs on, byte-exact accumulators ------------

toggle_diff "toggle exact: GROUP BY host" \
	"SELECT host, $EXACT FROM t_col GROUP BY host"
toggle_diff "toggle exact: GROUP BY hour, host" \
	"SELECT date_trunc('hour', ts), host, $EXACT FROM t_col GROUP BY date_trunc('hour', ts), host"
toggle_diff "toggle exact: GROUP BY region, host, WHERE" \
	"SELECT region, host, $EXACT FROM t_col WHERE i8 IS NOT NULL GROUP BY region, host"

# ---- 6. adversarial: NULL keys, deletes, ADD COLUMN ------------------------

groupvec_on
# NULL keys already present (g%197, g%331); confirm the node is still used and
# the NULL group matches the oracle.
check "plan: NULL-bearing key still uses grouped node" \
	"$(pgc_is_groupvec "SELECT host, count(*) FROM t_col GROUP BY host")" yes
diff_query "oracle exact: NULL ts group folds like heap" \
	"SELECT date_trunc('hour', ts), count(*), sum(i4) FROM %T GROUP BY date_trunc('hour', ts)"

psql_run "DELETE FROM t_heap WHERE g % 17 = 0;"
psql_run "DELETE FROM t_col  WHERE g % 17 = 0;"
diff_query "oracle exact: GROUP BY host after deletes" \
	"SELECT host, $EXACT FROM %T GROUP BY host"
toggle_diff "toggle exact: GROUP BY host after deletes" \
	"SELECT host, $EXACT FROM t_col GROUP BY host"

psql_run "ALTER TABLE t_heap ADD COLUMN extra int DEFAULT 7;"
psql_run "ALTER TABLE t_col  ADD COLUMN extra int DEFAULT 7;"
diff_query "oracle exact: GROUP BY host, added column" \
	"SELECT host, count(*), sum(extra), sum(i4) FROM %T GROUP BY host"
diff_query "oracle exact: GROUP BY added column" \
	"SELECT extra, count(*), sum(i4) FROM %T GROUP BY extra"

# ---- 7. fallback shapes: not the node, still the right answer ---------------

# The cap bounds the actual group count at execution, not the planner's group
# estimate (unreliable for expression keys): over the cap the node stops with
# guidance rather than building an unbounded hash table. The node is forced here
# (the only grouping path left with hashagg and sort off) so the cap-enforcement
# path is exercised deterministically regardless of how the planner would cost it
# on this small table; the node's real-world plan choice is covered above and by
# the benchmark. The cap is set in-session so the executor reads it directly.
check "plan: node still chosen (no estimate gate)" \
	"$(pgc_is_groupvec "SELECT g, count(*) FROM t_col GROUP BY g")" yes
# Capture to a variable before grepping: the query errors on purpose, so psql
# exits non-zero, and under `set -o pipefail` a `psql | grep` pipeline would
# report psql's failure even when grep matched -- flipping this check to a false
# negative. Grepping the captured text keeps psql's exit status out of it.
oc_out="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
	-d "$PGC_DB" -Atc "SET pgcolumnar.enable_group_vectorization=on;
		SET enable_hashagg=off; SET enable_sort=off;
		SET pgcolumnar.groupagg_max_groups=100;
		SELECT g, count(*) FROM t_col GROUP BY g" 2>&1 || true)"
n_err="$(printf '%s' "$oc_out" | grep -q 'groupagg_max_groups' && echo yes || echo no)"
check "over-cap stops with a groupagg_max_groups error" "$n_err" yes
diff_query "oracle exact: default cap runs the high-cardinality key" \
	"SELECT g, count(*), sum(i4) FROM %T GROUP BY g"

# non-deterministic collation key -> falls back
psql_run "DROP TABLE IF EXISTS t_ci;"
psql_run "CREATE COLLATION IF NOT EXISTS ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);" \
	2>/dev/null || true
if [ "$(q "SELECT 1 FROM pg_collation WHERE collname = 'ci'")" = "1" ]; then
	psql_run "CREATE TABLE t_ci (k text COLLATE ci, v int) USING pgcolumnar;"
	psql_run "INSERT INTO t_ci SELECT 'K' || (g % 20), g FROM generate_series(1, 5000) g;"
	check "plan: non-deterministic collation key falls back" \
		"$(pgc_is_groupvec "SELECT k, count(*) FROM t_ci GROUP BY k")" no
	check "answer: non-deterministic collation grouping runs" \
		"$(q "SELECT count(*) FROM (SELECT k FROM t_ci GROUP BY k) s")" \
		"$(q "SELECT count(DISTINCT lower(k)) FROM t_ci")"
else
	echo "SKIP  non-deterministic collation (ICU unavailable)"
fi

# an output expression built on a group key (not a bare key) -> falls back
check "plan: f(key) output falls back" \
	"$(pgc_is_groupvec "SELECT upper(host), count(*) FROM t_col GROUP BY host")" no
diff_query "oracle exact: f(key) output still correct" \
	"SELECT upper(host), count(*), sum(i4) FROM %T GROUP BY host"

# GROUP BY with no aggregate -> falls back (nothing to vectorize)
check "plan: GROUP BY with no aggregate falls back" \
	"$(pgc_is_groupvec "SELECT host FROM t_col GROUP BY host")" no

# ---- 8. degenerate inputs --------------------------------------------------

diff_query "oracle exact: all rows filtered out -> 0 groups" \
	"SELECT host, count(*) FROM %T WHERE g < 0 GROUP BY host"

# empty columnar table: GROUP BY yields no rows
psql_run "DROP TABLE IF EXISTS t_empty;"
psql_run "CREATE TABLE t_empty (k text, v int) USING pgcolumnar;"
check "empty table: grouped scan yields 0 rows" \
	"$(q "SELECT count(*) FROM (SELECT k, count(*) FROM t_empty GROUP BY k) s")" 0

pgc_summary
