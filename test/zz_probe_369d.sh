#!/usr/bin/env bash
# TEMPORARY PROBE. What does the parallel arm cost when the planner is not allowed to
# decline it? Reproducing the wrong CHOICE is only half the case; the other half is
# whether the declined plan is actually better. Requires the throwaway build whose
# add_path for the serial node is behind PGC369_NO_SERIAL.
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
echo "-- fixture: $got rows, $(q "SELECT pg_size_pretty(pg_total_relation_size('m'))")"

G="SET pgcolumnar.enable_group_vectorization=on;
   SET pgcolumnar.enable_parallel_vector_agg=on;
   SET max_parallel_workers_per_gather=4;"

Q1="SELECT date_trunc('minute', time) AS b, avg(usage_user) FROM m
    WHERE time >= '2026-01-01' AND time < '2026-01-01 12:00' GROUP BY b"
Q2="SELECT date_trunc('minute', time) AS b, avg(usage_user), avg(usage_system),
      avg(usage_idle), avg(usage_nice), avg(usage_iowait), avg(usage_irq),
      avg(usage_softirq), avg(usage_steal), avg(usage_guest), avg(usage_guest_nice)
    FROM m WHERE time >= '2026-01-01' AND time < '2026-01-01 12:00' GROUP BY b"

# The suppression is read by the BACKEND, so it has to be in the server's environment.
# Setting it in this shell would do nothing. Restart the cluster with it set.
restart_with() {  # $1 = "" or "1"
	pgc_pg "pg_ctl -D '$PGC_PGDATA' -m fast stop" >/dev/null 2>&1
	if [ -n "$1" ]; then
		pgc_pg "PGC369_NO_SERIAL=1 pg_ctl -D '$PGC_PGDATA' -l '$PGC_LOGFILE' start -w" >/dev/null 2>&1
	else
		pgc_pg "pg_ctl -D '$PGC_PGDATA' -l '$PGC_LOGFILE' start -w" >/dev/null 2>&1
	fi
	sleep 2
}
t() { local s e; s=$(date +%s%N); psql_run "$1" >/dev/null 2>&1; e=$(date +%s%N); echo $(( (e-s)/1000000 )); }
arm() { # -> which node the plan uses
	local p; p=$(psql_run "$G EXPLAIN (COSTS OFF) $1" 2>&1)
	if grep -q "Parallel Custom Scan" <<<"$p"; then echo "PARALLEL arm"
	elif grep -q "Columnar Vectorized Group Keys" <<<"$p"; then echo "serial node"
	else echo "core"; fi
}

for mode in "" "1"; do
	restart_with "$mode"
	label=$([ -n "$mode" ] && echo "serial node SUPPRESSED" || echo "as shipped")
	echo
	echo "=== $label ================================================"
	# assert the premise: the suppression must actually change the plan
	echo "   G1 plan: $(arm "$Q1")   G2 plan: $(arm "$Q2")"
	echo "   G1 time: $(t "$G $Q1") ms"
	echo "   G2 time: $(t "$G $Q2") ms"
done
pgc_summary
