#!/usr/bin/env bash
#
# pgColumnar chunk-group skipping works for parameterized predicates.
#
# The scan-key builder (pgcolumnar_clause_to_scankey) only accepted a Const
# operand, so a predicate like "col >= $1" -- a PARAM_EXTERN from a prepared
# statement, PL/pgSQL, or the extended protocol -- built no scan key and disabled
# chunk-group skipping entirely. On a generic plan the scan then read every group.
#
# Begin now freezes execution-stable operands (a PARAM_EXTERN, or any subexpression
# with no Var, no PARAM_EXEC, and no volatile function) into Consts before building
# the keys. This is exact: such an operand cannot change within the execution, and
# the executor still re-applies the original qual to every surviving row.
#
# The correctness hazard is a correlated PARAM_EXEC (a nestloop inner scan whose
# qual references the outer row): it changes per rescan, and the keys are built
# once, so freezing it would silently skip groups that in fact match. That param
# is deliberately NOT frozen; the correlated arm below proves results stay correct.
#
# Usage:  test/native_param_pushdown.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null
# 40000 rows / 2000 = 20 monotonic groups; ts >= 39000 lives in the last group.
q "SET pgcolumnar.stripe_row_limit=2000;
   CREATE TABLE t (id int, ts int) USING pgcolumnar;
   INSERT INTO t SELECT g, g FROM generate_series(1,40000) g;
   CREATE TABLE thr (lo int); INSERT INTO thr VALUES (39000),(38000);" >/dev/null

psql_c() { env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -At -c "$1" 2>&1; }

# Groups read by a generic-plan parameterized scan. Under the fix the last group
# is the only one read; without it, all 20 are.
groups_removed() {
	psql_c "SET plan_cache_mode=force_generic_plan;
		DEALLOCATE ALL;
		PREPARE p(int) AS SELECT count(*) FROM t WHERE ts >= \$1;
		EXPLAIN (ANALYZE, TIMING off, SUMMARY off) EXECUTE p(39000);" \
		| sed -n 's/.*Chunk Groups Removed by Filter: \([0-9]*\).*/\1/p' | head -1
}

check "a generic-plan parameterized qual prunes chunk groups (19 of 20 removed)" \
	"$(groups_removed)" "19"

# Correctness: the pruned count equals the literal count (ids 39000..40000).
prep_count() {
	psql_c "SET plan_cache_mode=force_generic_plan;
		DEALLOCATE ALL;
		PREPARE c(int) AS SELECT count(*) FROM t WHERE ts >= \$1;
		EXECUTE c(39000);" | tail -1
}
check "parameterized count matches the literal count" "$(prep_count)" "1001"
check "literal count is the expected value" \
	"$(q 'SELECT count(*) FROM t WHERE ts >= 39000;')" "1001"

# Safety: a correlated PARAM_EXEC (nestloop inner scan) must NOT be frozen, or it
# would mis-prune per outer row. sum over thr(39000, 38000) = 1001 + 2001 = 3002.
check "a correlated PARAM_EXEC is not mis-pruned (results stay correct)" \
	"$(q 'SELECT sum(c) FROM thr, LATERAL (SELECT count(*) c FROM t WHERE t.ts >= thr.lo) s;')" \
	"3002"

check "backend alive" "$(q 'SELECT 1;')" "1"

pgc_summary
