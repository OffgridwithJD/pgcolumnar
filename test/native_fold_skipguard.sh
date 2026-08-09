#!/usr/bin/env bash
#
# pgColumnar: the batch fold must refuse a group whose decode skipped vectors
# (#512).
#
# The fold at columnar_vector.c does NOT honour the skip vector. It reads every
# vector and reaches the right answer by re-checking every value against the scan
# keys, which is correct only while decode produces every vector -- and today it
# does, because pgcolumnar_native_decode_chunk takes no skip mask at all.
#
# The day decode is taught to skip ruled-out vectors (#452 phase 1b) the decoded
# buffer gains holes, and this loop would re-check UNINITIALISED memory: a wrong
# aggregate, silently, and only on data whose zone maps rule something out. The
# row producer is safe there; the fold is not. So the ordering constraint is
# enforced by a guard rather than written in a comment.
#
# This suite proves the guard is REACHABLE, which is the part that is easy to get
# wrong: the fold only runs for a shape that qualifies for it, and the hazard only
# exists where vectors are skipped. Both have to be true at once, and a check that
# never reaches the fold would pass forever while guarding nothing.
#
# Usage:  test/native_fold_skipguard.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=60000
psql_run "CREATE TABLE t (k int, v int) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('t'::regclass, stripe_row_limit => 60000, chunk_group_row_limit => 1024);"
psql_run "INSERT INTO t SELECT g, g FROM generate_series(1, $ROWS) g;"
psql_run "ANALYZE t;"

# Monotonic k, so each 1024-row vector has a tight non-overlapping zone map and a
# narrow range rules almost all of them out.
Q="SELECT count(*), sum(v) FROM t WHERE k BETWEEN 30000 AND 30100"

# The fold needs its GUC and no parallelism; the scalar arm is the same query
# with the GUC off, which is what reports the per-vector counter.
SET_ON="SET max_parallel_workers_per_gather=0; SET pgcolumnar.enable_ungrouped_vector_agg=on;"
SET_OFF="SET max_parallel_workers_per_gather=0; SET pgcolumnar.enable_ungrouped_vector_agg=off;"

run() {  # run <setup> <sql>
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$1" -c "$2" 2>&1
}

# ---- premise one: the reader really does skip vectors for this predicate ----
#
# Read off the SCALAR arm, because the vectorized aggregate node does not print
# "Columnar Vectors Skipped" at all -- a reporting gap of its own. Same table,
# same predicate, same reader, so what it skips there it skips here.
vskip=$(run "$SET_OFF" "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) $Q" \
	| grep "Columnar Vectors Skipped" | grep -oE '[0-9]+' | head -1)
check "premise: the predicate rules vectors out at all" \
	"$([ "${vskip:-0}" -gt 0 ] && echo yes || echo no)" "yes"

# ---- premise two: the query actually reaches the fold -----------------------
#
# Without this the guard below is unreachable and the suite would pass forever
# while protecting nothing. This is the premise a first version of this test
# lacked, and it is why that version could not be trusted.
fold=$(run "$SET_ON" "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) $Q" \
	| grep -oE "Columnar Batch Fold: [a-z]+" | head -1)
check "premise: the query reaches the batch fold" "$fold" "Columnar Batch Fold: yes"

# ---- the guard is silent while decode produces every vector ----------------
#
# Today decode never skips, so the fold must run normally and answer correctly.
# The heap arithmetic is the oracle: 101 rows, sum of 30000..30100.
want_n=101
want_s=$(( (30000 + 30100) * 101 / 2 ))
got=$(run "$SET_ON" "$Q" | tail -1)
check "the fold answers correctly while decode skips nothing" "$got" "$want_n|$want_s"

# And the same answer without the fold, so the fold is not quietly wrong in a way
# that matches a wrong expectation.
got_off=$(run "$SET_OFF" "$Q" | tail -1)
check "and the scalar arm agrees" "$got_off" "$got"

pgc_summary
