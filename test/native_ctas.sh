#!/usr/bin/env bash
#
# CREATE TABLE AS into a columnar table, with a parallel source plan (issue #387).
#
# PgColumnarInsertNativeStorageRow re-checks for an existing storage row under an
# advisory lock, against GetLatestSnapshot(), so the loser of a cross-transaction
# first-write race sees the winner's committed row instead of failing on
# storage_pkey. GetLatestSnapshot() raises
#
#     ERROR:  cannot update SecondarySnapshot during a parallel operation
#
# under IsInParallelMode(), and CTAS runs the whole executor in parallel mode
# whenever the source plan is parallel. So every CREATE TABLE ... USING pgcolumnar
# AS SELECT over a source large enough to be worth loading failed, on all five
# majors, with the failure arriving exactly when someone bulk loads a real table.
#
# The fix skips the lock and the fresh snapshot when the relation was created by
# this transaction, because then no other session can see it and there is no
# second writer. The condition is creation, not parallel mode: a committed empty
# columnar table can be first-written by two sessions at once, and that race is
# still real and still serialized. Both directions are asserted here.
#
# Every timing-free assertion below is paired with a PLAN assertion, because a
# CTAS that quietly ran serially would pass every value check and prove nothing.
#
# Usage:  test/native_ctas.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=${PGC_CTAS_ROWS:-200000}

# Zeroing the parallel costs makes a modest source go parallel, so this runs in
# seconds instead of needing a table large enough to earn a parallel plan.
FORCE="SET parallel_setup_cost=0; SET parallel_tuple_cost=0;
       SET min_parallel_table_scan_size=0; SET max_parallel_workers_per_gather=2;"

psql_run "CREATE TABLE ctas_src AS
	SELECT g AS id, 'h'||(g%97) AS host, (g%1000)::float8 AS v
	FROM generate_series(1,$ROWS) g;"

# ---- premise: the source plan really is parallel -----------------------------
# Without this the whole suite is satisfied by a serial plan, which is the shape
# that already worked and the reason the defect went unnoticed.
plan="$(psql_run "$FORCE EXPLAIN (COSTS OFF)
	CREATE TABLE ctas_p USING pgcolumnar AS SELECT * FROM ctas_src ORDER BY host;" 2>&1)"
check "premise: the CTAS source plan is parallel" \
	"$(grep -qE 'Gather( Merge)?' <<<"$plan" && echo yes || echo "no ($(head -2 <<<"$plan" | tr '\n' ' '))")" \
	"yes"

# ---- the defect: parallel CTAS into a columnar table -------------------------
out="$(psql_run "$FORCE CREATE TABLE ctas_p USING pgcolumnar AS
	SELECT * FROM ctas_src ORDER BY host;" 2>&1)"
check "parallel CTAS into a columnar table succeeds (#387)" \
	"$(case "$out" in *ERROR*) grep -oE 'ERROR:.*' <<<"$out" | head -1 ;; *) echo ok ;; esac)" \
	"ok"
check "parallel CTAS wrote every row (#387)" \
	"$(q "SELECT count(*) FROM ctas_p")" "$ROWS"

# content, not just the row count: a load that silently dropped or reordered
# columns would satisfy a count
check "parallel CTAS content matches the source (#387)" \
	"$(q "SELECT count(*) FROM ctas_p p JOIN ctas_src s USING (id)
	      WHERE p.host = s.host AND p.v = s.v")" "$ROWS"

# ---- controls: the shapes that already worked must keep working --------------
out="$(psql_run "SET max_parallel_workers_per_gather=0;
	CREATE TABLE ctas_s USING pgcolumnar AS SELECT * FROM ctas_src;" 2>&1)"
check "serial CTAS still succeeds" \
	"$(case "$out" in *ERROR*) grep -oE 'ERROR:.*' <<<"$out" | head -1 ;; *) echo ok ;; esac)" "ok"
check "serial CTAS row count" "$(q "SELECT count(*) FROM ctas_s")" "$ROWS"

out="$(psql_run "$FORCE CREATE TABLE ctas_nd USING pgcolumnar AS
	SELECT * FROM ctas_src WITH NO DATA;
	INSERT INTO ctas_nd SELECT * FROM ctas_src;" 2>&1)"
check "WITH NO DATA then INSERT still succeeds" \
	"$(case "$out" in *ERROR*) grep -oE 'ERROR:.*' <<<"$out" | head -1 ;; *) echo ok ;; esac)" "ok"
check "WITH NO DATA then INSERT row count" "$(q "SELECT count(*) FROM ctas_nd")" "$ROWS"

# one storage row per storage, however many row groups were flushed: the function
# under test is called on every flush and has to stay idempotent
check "the parallel CTAS produced exactly one storage row" \
	"$(q "SELECT count(*) FROM pgcolumnar.storage s
	      JOIN pg_class c ON c.oid = s.relation_oid WHERE c.relname = 'ctas_p'")" "1"

# ---- the direction that must NOT change --------------------------------------
# The advisory lock exists for a cross-transaction first-write race on a table both
# sessions can see. Creation invisibility is what makes the CTAS case safe, so a
# COMMITTED, EMPTY table must still serialize. Two sessions first-write it at once;
# without the lock one of them fails on storage_pkey.
psql_run "CREATE TABLE ctas_race (id int, v text) USING pgcolumnar;"
raceout="$PGC_WORKDIR/race.out"
for i in 1 2; do
	( env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq -c "INSERT INTO ctas_race
			SELECT g, 'w$i-'||g FROM generate_series(1,20000) g;" >>"$raceout" 2>&1 ) &
done
wait
check "concurrent first writes to a committed empty table both succeed" \
	"$(grep -c 'ERROR' "$raceout" || true)" "0"
check "and they produced one storage row, not two" \
	"$(q "SELECT count(*) FROM pgcolumnar.storage s
	      JOIN pg_class c ON c.oid = s.relation_oid WHERE c.relname = 'ctas_race'")" "1"
check "and every row from both writers is present" \
	"$(q "SELECT count(*) FROM ctas_race")" "40000"

pgc_summary
