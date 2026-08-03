#!/usr/bin/env bash
# Correctness check for the parallel-partial ungrouped batch fold (#289 phase 5/6).
# Proves: (1) the plan Finalize Aggregate -> Gather -> Partial ColumnarAgg is
# actually chosen with the GUC on and parallelism enabled; (2) count is exact vs a
# serial oracle; (3) avg/sum(float8) match core's own parallel aggregate within
# float-reassociation tolerance (parallel folds are order-nondeterministic, so the
# oracle is core PARALLEL Agg, not the serial fold); (4) all-null, empty, and
# more-workers-than-groups behave. Asserts the parallel path actually ran.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export PGC_SKIP_BUILD=1
pgc_setup "/usr/local/pg18a/bin/pg_config"

PASS=0; FAIL=0
ck() { # ck <label> <got> <want>
	if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
	else FAIL=$((FAIL+1)); echo "FAIL - $1 : got [$2] want [$3]"; fi
}

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

SQL="SELECT count(*), avg(v), sum(v) FROM t WHERE k < 700"

# ---- premise: the parallel plan is actually chosen -------------------------
PLAN="$(q -c "$PAR $UG $PP" -c "EXPLAIN (COSTS OFF) $SQL")"
echo "----- plan (GUC on, parallel) -----"; printf '%s\n' "$PLAN"; echo "-----------------------------------"
ck "premise: Finalize Aggregate present" \
   "$(printf '%s' "$PLAN" | grep -qi 'Finalize Aggregate' && echo y || echo n)" y
ck "premise: Gather present" \
   "$(printf '%s' "$PLAN" | grep -qiE 'Gather' && echo y || echo n)" y
ck "premise: our partial columnar agg node present" \
   "$(printf '%s' "$PLAN" | grep -qi 'Columnar Vectorized Aggregates' && echo y || echo n)" y
ck "premise: parallel-aware (Batch Fold yes under the partial)" \
   "$(printf '%s' "$PLAN" | grep -qi 'Batch Fold: yes' && echo y || echo n)" y

# ---- values: count exact, avg/sum vs core PARALLEL agg within tolerance -----
# serial oracle (exact) for count; core parallel agg for the float oracle
CNT_VEC="$(q -c "$PAR $UG $PP" -c "SELECT count(*) FROM t WHERE k < 700")"
CNT_SER="$(q -c "SET max_parallel_workers_per_gather=0;" -c "SELECT count(*) FROM t WHERE k < 700")"
ck "count(*) parallel-vec == serial oracle" "$CNT_VEC" "$CNT_SER"

# relative-difference gate in SQL: |vec-core|/(|core|+1) < 1e-6
reldiff() { # reldiff <expr> ; prints 'ok' or the diff
	local vec core
	vec="$(q -c "$PAR $UG $PP" -c "SELECT $1 FROM t WHERE k < 700")"
	core="$(q -c "$PAR" -c "SET pgcolumnar.enable_ungrouped_vector_agg=off;" \
	           -c "SELECT $1 FROM t WHERE k < 700")"
	q -c "SELECT CASE WHEN abs(($vec::float8)-($core::float8)) <= 1e-6*(abs($core::float8)+1)
	                  THEN 'ok' ELSE 'DIFF vec=$vec core=$core' END"
}
ck "avg(v) parallel-vec ~= core parallel agg"  "$(reldiff 'avg(v)')" ok
ck "sum(v) parallel-vec ~= core parallel agg"  "$(reldiff 'sum(v)')" ok
ck "avg(w::float8) f4 ~= core parallel agg"    "$(reldiff 'avg(w)::float8')" ok

# ---- edge cases ------------------------------------------------------------
# all-null v: avg -> NULL, count(*) still the row count
AN_AVG="$(q -c "$PAR $UG $PP" -c "SELECT avg(v) FROM t WHERE k < 700 AND v IS NULL")"
ck "all-null avg is NULL (empty string)" "$AN_AVG" ""
AN_CNT="$(q -c "$PAR $UG $PP" -c "SELECT count(*) FROM t WHERE k < 700 AND v IS NULL")"
AN_CNT2="$(q -c "SET max_parallel_workers_per_gather=0;" -c "SELECT count(*) FROM t WHERE k<700 AND v IS NULL")"
ck "all-null count(*) exact" "$AN_CNT" "$AN_CNT2"
# empty: no rows match
E_CNT="$(q -c "$PAR $UG $PP" -c "SELECT count(*) FROM t WHERE k < 0")"
ck "empty count(*) == 0" "$E_CNT" "0"
E_AVG="$(q -c "$PAR $UG $PP" -c "SELECT avg(v) FROM t WHERE k < 0")"
ck "empty avg is NULL" "$E_AVG" ""
# more workers than groups: 8 workers over a tiny 3-group table
q -c "DROP TABLE IF EXISTS tiny;
      CREATE TABLE tiny (v float8) USING pgcolumnar;
      SELECT pgcolumnar.set_options('tiny'::regclass, stripe_row_limit => 1000);
      INSERT INTO tiny SELECT g::float8 FROM generate_series(1,2500) g; ANALYZE tiny;" >/dev/null
TW_VEC="$(q -c "SET max_parallel_workers_per_gather=8; SET parallel_setup_cost=0; SET parallel_tuple_cost=0; SET min_parallel_table_scan_size=0; $UG $PP" -c "SELECT count(*), sum(v) FROM tiny")"
TW_SER="$(q -c "SET max_parallel_workers_per_gather=0;" -c "SELECT count(*), sum(v) FROM tiny")"
ck "more-workers-than-groups count+sum exact (small ints)" "$TW_VEC" "$TW_SER"

echo "===== $PASS passed, $FAIL failed ====="
echo "TEST_PPA_DONE"
