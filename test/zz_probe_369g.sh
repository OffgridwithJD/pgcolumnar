#!/usr/bin/env bash
# TEMPORARY PROBE. The decisive run for #369.
#
# At 5M rows, suppressing the serial node did NOT select our parallel arm: the planner
# fell back to core's HashAggregate. So a "forced parallel" timing is only evidence if
# the plan is inspected, not inferred from the suppression. At 20M the classifier did
# report Parallel Custom Scan, and this run proves it with EXPLAIN (ANALYZE) and shows
# Workers Launched and the per-worker row counts, which is what explains WHY our arm is
# slower than our serial node on this shape.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pgsql/bin/pg_config}"

ROWS=${PGC_369_ROWS:-20000000}
psql_run "CREATE TABLE m (time timestamptz, hostname text,
		usage_user float8, usage_system float8, usage_idle float8,
		usage_nice float8, usage_iowait float8, usage_irq float8,
		usage_softirq float8, usage_steal float8, usage_guest float8,
		usage_guest_nice float8) USING pgcolumnar;
	INSERT INTO m SELECT
		'2026-01-01'::timestamptz + (g * interval '2160 microseconds'),
		'host_' || (g % 4000),
		random()*100, random()*100, random()*100, random()*100,
		random()*100, random()*100, random()*100, random()*100,
		random()*100, random()*100
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
	psql_run "$G $2" >/dev/null 2>&1   # warm
	psql_run "$G EXPLAIN (ANALYZE, TIMING ON) $2" 2>&1 |
		grep -iE "Custom Scan|HashAggregate|Gather|Workers|Vectorized|Execution Time" |
		sed 's/^[[:space:]]*/    /' | head -14
}

restart_with ""
ea "G1 as shipped" "$Q1"
ea "G3 as shipped (the arm working correctly, for contrast)" "$Q3"
restart_with "1"
ea "G1, serial node suppressed" "$Q1"
ea "G3, serial node suppressed" "$Q3"
pgc_summary
