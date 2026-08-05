#!/usr/bin/env bash
# TEMPORARY PROBE. Forced onto the parallel arm, G1 runs 2x SLOWER than the serial node,
# and 8.5x slower than G3's parallel plan over the same 20M rows and the same number of
# columns. Either the workers are not dividing the work, or they are each doing all of
# it. EXPLAIN (ANALYZE) says which.
#
# 5M rows: the question is the ratio and the per-worker row counts, not the absolute time.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pgsql/bin/pg_config}"

ROWS=${PGC_369_ROWS:-5000000}
psql_run "CREATE TABLE m (time timestamptz, hostname text,
		usage_user float8, usage_system float8) USING pgcolumnar;
	INSERT INTO m SELECT
		'2026-01-01'::timestamptz + (g * interval '8640 microseconds'),
		'host_' || (g % 4000), random()*100, random()*100
	FROM generate_series(1,$ROWS) g;
	ANALYZE m;"
got=$(q "SELECT count(*) FROM m")
[ "$got" = "$ROWS" ] || { echo "ABORT: fixture has [$got] rows"; pgc_summary; exit 1; }
echo "-- fixture: $got rows, $(q "SELECT pg_size_pretty(pg_total_relation_size('m'))"), cores=$(nproc)"

G="SET pgcolumnar.enable_group_vectorization=on;
   SET pgcolumnar.enable_parallel_vector_agg=on;
   SET max_parallel_workers_per_gather=4;"
Q1="SELECT date_trunc('minute', time) AS b, avg(usage_user) FROM m
    WHERE time >= '2026-01-01' AND time < '2026-01-01 12:00' GROUP BY b"
Q3="SELECT hostname, avg(usage_user) FROM m GROUP BY hostname"

restart_with() {
	pgc_pg "pg_ctl -D '$PGC_PGDATA' -m fast stop" >/dev/null 2>&1
	if [ -n "$1" ]; then
		pgc_pg "PGC369_NO_SERIAL=1 pg_ctl -D '$PGC_PGDATA' -l '$PGC_LOGFILE' start -w" >/dev/null 2>&1
	else
		pgc_pg "pg_ctl -D '$PGC_PGDATA' -l '$PGC_LOGFILE' start -w" >/dev/null 2>&1
	fi
	sleep 2
}
ea() {  # $1 label, $2 query
	echo
	echo "--- $1 ---"
	psql_run "$G EXPLAIN (ANALYZE, TIMING ON, VERBOSE OFF) $2" 2>&1 |
		grep -iE "Custom Scan|HashAggregate|Gather|Workers|actual time|rows=|Execution Time" |
		sed 's/^[[:space:]]*/    /' | head -14
}

restart_with ""
ea "G1 as shipped (serial node expected)" "$Q1"
ea "G3 as shipped (parallel arm expected)" "$Q3"
restart_with "1"
ea "G1 with the serial node suppressed (parallel arm forced)" "$Q1"
pgc_summary
