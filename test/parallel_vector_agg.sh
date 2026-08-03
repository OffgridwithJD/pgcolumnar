#!/usr/bin/env bash
#
# pgColumnar parallel-aware ungrouped vectorized aggregate (#289 phase 5/6).
#
# pgcolumnar.enable_parallel_vector_agg makes the ungrouped batch fold
# parallel-aware: a parallel partial ColumnarAgg under a core Gather + Finalize.
# Each worker claims distinct row groups through the shared gap-23 counter and
# emits per-worker transition state the Finalize combines. This suite proves:
#   (1) the plan Finalize Aggregate -> Gather -> parallel partial ColumnarAgg is
#       ACTUALLY chosen with the GUC on and parallelism enabled (premise);
#   (2) count(*) is exact vs a serial oracle;
#   (3) avg/sum over float4/float8 match core's OWN parallel aggregate within
#       float-reassociation tolerance -- a parallel fold sums in worker/arrival
#       order, so the oracle is core PARALLEL Agg, never the serial fold;
#   (4) all-null, empty, more-workers-than-groups, and a not-batch-foldable
#       filter (a NULL test, which runs on the row path with the shared counter).
#
# Usage:  test/parallel_vector_agg.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# Force parallel plans; both arms then differ only in the aggregate node.
PAR="SET max_parallel_workers_per_gather=4;
     SET parallel_setup_cost=0; SET parallel_tuple_cost=0;
     SET min_parallel_table_scan_size=0; SET min_parallel_index_scan_size=0;"
UG="SET pgcolumnar.enable_ungrouped_vector_agg=on;"
PP="SET pgcolumnar.enable_parallel_vector_agg=on;"

q() { env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
        -d "$PGC_DB" -Atq "$@" 2>&1; }

# ~2M rows, small stripe -> many row groups so several workers each claim some.
q -c "DROP TABLE IF EXISTS t;
      CREATE TABLE t (id int, k int, v float8, w float4) USING pgcolumnar;
      SELECT pgcolumnar.set_options('t'::regclass, stripe_row_limit => 40000);
      INSERT INTO t
      SELECT g, g % 1000,
             CASE WHEN g % 50 = 0 THEN NULL
                  ELSE ((g % 13) - 6)::float8 * (10.0 ^ (g % 4)) END,
             ((g % 7) - 3)::float4
      FROM generate_series(1, 2000000) g;
      ANALYZE t;" >/dev/null

# ---- premise: the parallel plan is actually chosen -------------------------
PLAN="$(q -c "$PAR $UG $PP" -c "EXPLAIN (COSTS OFF) SELECT count(*), avg(v), sum(v) FROM t WHERE k < 700")"
check "premise: Finalize Aggregate present" \
   "$(printf '%s' "$PLAN" | grep -qi 'Finalize Aggregate' && echo y || echo n)" y
check "premise: Gather present" \
   "$(printf '%s' "$PLAN" | grep -qiE 'Gather' && echo y || echo n)" y
check "premise: the partial columnar agg node present" \
   "$(printf '%s' "$PLAN" | grep -qi 'Columnar Vectorized Aggregates' && echo y || echo n)" y
check "premise: the partial runs the batch fold" \
   "$(printf '%s' "$PLAN" | grep -qi 'Batch Fold: yes' && echo y || echo n)" y

# ---- values: count exact, avg/sum vs core PARALLEL agg within tolerance -----
CNT_VEC="$(q -c "$PAR $UG $PP" -c "SELECT count(*) FROM t WHERE k < 700")"
CNT_SER="$(q -c "SET max_parallel_workers_per_gather=0;" -c "SELECT count(*) FROM t WHERE k < 700")"
check "count(*) parallel-vec == serial oracle" "$CNT_VEC" "$CNT_SER"

# relative-difference gate in SQL: |vec-core|/(|core|+1) < 1e-6
reldiff() { # reldiff <expr>
	local vec core
	vec="$(q -c "$PAR $UG $PP" -c "SELECT $1 FROM t WHERE k < 700")"
	core="$(q -c "$PAR" -c "SET pgcolumnar.enable_ungrouped_vector_agg=off;" \
	           -c "SELECT $1 FROM t WHERE k < 700")"
	q -c "SELECT CASE WHEN abs(($vec::float8)-($core::float8)) <= 1e-6*(abs($core::float8)+1)
	                  THEN 'ok' ELSE 'DIFF vec=$vec core=$core' END"
}
check "avg(v) parallel-vec ~= core parallel agg"  "$(reldiff 'avg(v)')" ok
check "sum(v) parallel-vec ~= core parallel agg"  "$(reldiff 'sum(v)')" ok
check "avg(w::float8) f4 ~= core parallel agg"    "$(reldiff 'avg(w)::float8')" ok

# ---- edge cases ------------------------------------------------------------
# a NULL test is not batch-foldable: the partial must still be correct on the
# row path (shape ineligible from the start -> shared counter untouched).
AN_AVG="$(q -c "$PAR $UG $PP" -c "SELECT coalesce(avg(v)::text,'NULLZ') FROM t WHERE k < 700 AND v IS NULL")"
check "not-batch-foldable filter: all-null avg is NULL" "$AN_AVG" "NULLZ"
AN_CNT="$(q -c "$PAR $UG $PP" -c "SELECT count(*) FROM t WHERE k < 700 AND v IS NULL")"
AN_CNT2="$(q -c "SET max_parallel_workers_per_gather=0;" -c "SELECT count(*) FROM t WHERE k<700 AND v IS NULL")"
check "not-batch-foldable filter: count(*) exact" "$AN_CNT" "$AN_CNT2"
# empty
check "empty count(*) == 0"  "$(q -c "$PAR $UG $PP" -c "SELECT count(*) FROM t WHERE k < 0")" "0"
check "empty avg is NULL"    "$(q -c "$PAR $UG $PP" -c "SELECT coalesce(avg(v)::text,'NULLZ') FROM t WHERE k < 0")" "NULLZ"
# more workers than groups: 8 workers over a tiny 3-group table, small ints so exact
q -c "DROP TABLE IF EXISTS tiny;
      CREATE TABLE tiny (v float8) USING pgcolumnar;
      SELECT pgcolumnar.set_options('tiny'::regclass, stripe_row_limit => 1000);
      INSERT INTO tiny SELECT g::float8 FROM generate_series(1,2500) g; ANALYZE tiny;" >/dev/null
TW_VEC="$(q -c "SET max_parallel_workers_per_gather=8; SET parallel_setup_cost=0; SET parallel_tuple_cost=0; SET min_parallel_table_scan_size=0; $UG $PP" -c "SELECT count(*), sum(v) FROM tiny")"
TW_SER="$(q -c "SET max_parallel_workers_per_gather=0;" -c "SELECT count(*), sum(v) FROM tiny")"
check "more-workers-than-groups count+sum exact" "$TW_VEC" "$TW_SER"

check "server still up" "$(q -c 'SELECT 1')" 1
pgc_summary
