#!/usr/bin/env bash
# TEMPORARY PROBE. Reproduce #369 with a fixture that can actually express it.
#
# My first two attempts failed for a reason worth stating: the grouping expression
# has to COLLAPSE a high-cardinality column. I used
#   time = start + (g % 250000) * interval '1 second'
# so `time` held 250,000 distinct values and date_trunc('second', time) preserved
# every one. estimate_num_groups came back 251,434 against 250,000 actual, which is
# right, so there was no inflation to trigger the defect.
#
# Here every row gets its own timestamp (20M distinct, 2160us apart, exactly 12
# hours) and date_trunc('minute') collapses them to 720 groups. That gap between the
# column's distinctness and the expression's is the whole mechanism.
#
# Data is random so it does not compress to nothing: the earlier fixture put 20M
# rows in 34 MB, which made every scan term negligible against the finalize term
# and moved the balance point on its own.
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
[ "$got" = "$ROWS" ] || { echo "ABORT: fixture has [$got] rows, expected $ROWS"; pgc_summary; exit 1; }
echo "-- fixture: $got rows, $(q "SELECT pg_size_pretty(pg_total_relation_size('m'))")"
echo "-- ndistinct(time) per ANALYZE: $(q "SELECT n_distinct FROM pg_stats WHERE tablename='m' AND attname='time'")"
echo "-- span: $(q "SELECT max(time)-min(time) FROM m")"

G="SET pgcolumnar.enable_group_vectorization=on;
   SET pgcolumnar.enable_parallel_vector_agg=on;
   SET max_parallel_workers_per_gather=4;"
CORE="SET pgcolumnar.enable_group_vectorization=off;
      SET pgcolumnar.enable_parallel_vector_agg=off;
      SET max_parallel_workers_per_gather=4;"
SER="SET pgcolumnar.enable_group_vectorization=on;
     SET pgcolumnar.enable_parallel_vector_agg=off;
     SET max_parallel_workers_per_gather=0;"

ex() {  # $1 SETs, $2 query -> whole plan
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-q -c "$1" -c "EXPLAIN (COSTS ON) $2" 2>&1
}
t() { local s e; s=$(date +%s%N); psql_run "$1" >/dev/null 2>&1; e=$(date +%s%N); echo $(( (e-s)/1000000 )); }

shape() {  # $1 label, $2 query
	local p top est act
	p=$(ex "$G" "$2")
	# the top node's row estimate is dNumGroups for either arm
	est=$(grep -oE 'rows=[0-9]+' <<<"$p" | head -1 | cut -d= -f2)
	act=$(q "SELECT count(*) FROM ($2) z" | tail -1)
	if grep -q "Parallel Custom Scan" <<<"$p"; then top="PARALLEL arm"
	elif grep -q "Columnar Vectorized Group Keys" <<<"$p"; then top="serial node"
	else top="core"; fi
	echo
	echo "=== $1 ==========================================="
	printf '   dNumGroups=%s  actual=%s  inflation=%s  chosen=%s\n' \
		"${est:-?}" "$act" \
		"$(awk -v e="${est:-0}" -v a="$act" 'BEGIN{printf (a>0? "%.0fx" : "?"), e/a}')" "$top"
	echo "   plan:"; grep -E "Custom Scan|HashAggregate|Gather|Vectorized" <<<"$p" | sed 's/^/     /' | head -6
	echo "   timings:"
	echo "     as chosen        : $(t "$G $2") ms"
	echo "     core only        : $(t "$CORE $2") ms"
	echo "     serial forced    : $(t "$SER $2") ms"
}

# G1: expression key over a 12h window. The shape #369 says is declined.
shape "G1 expression key, 12h window" \
	"SELECT date_trunc('minute', time) AS b, avg(usage_user) FROM m
	 WHERE time >= '2026-01-01' AND time < '2026-01-01 12:00' GROUP BY b"
# G2: same, ten aggregates.
shape "G2 expression key, ten aggregates" \
	"SELECT date_trunc('minute', time) AS b, avg(usage_user), avg(usage_system),
	        avg(usage_idle), avg(usage_nice), avg(usage_iowait), avg(usage_irq),
	        avg(usage_softirq), avg(usage_steal), avg(usage_guest), avg(usage_guest_nice)
	 FROM m WHERE time >= '2026-01-01' AND time < '2026-01-01 12:00' GROUP BY b"
# G3: plain column key. The control: estimate is accurate, arm should be chosen.
shape "G3 plain column key, full scan" \
	"SELECT hostname, avg(usage_user) FROM m GROUP BY hostname"
pgc_summary
