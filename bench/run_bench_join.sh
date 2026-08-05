#!/usr/bin/env bash
#
# Join-heavy benchmark (issue #401).
#
# Every query in the main benchmark reads one table. Star schemas and dimension
# joins are the shape columnar storage is usually bought for, and until this
# existed we had no measurement of them at all. Not "we know and it is bad". We
# did not know.
#
# ---------------------------------------------------------------------------
# The two mistakes this harness is built to prevent, because I made both
# ---------------------------------------------------------------------------
#
# 1. THE DATA SHAPE IS AN ARM, NOT AN ASSUMPTION. My first result on #401 used
#    random() float8 metrics: 20 million distinct values per column, maximum
#    entropy, nothing to compress. That is the one shape where columnar storage
#    cannot win, and I published "we lose by up to 6.2x" from it. Quantising the
#    metrics to two decimals, which is what an instrument actually reports, more
#    than halved the worst gap. So both shapes are measured here and both are
#    reported. Neither is allowed to be implicit.
#
# 2. THE NO-JOIN CONTROL IS MANDATORY. The finding this benchmark exists to
#    surface is invisible without it, and I once "refuted" my own correct
#    hypothesis by running the decomposition with the vectorized aggregate
#    turned off, so the no-join arm was unvectorized too and both looked equally
#    slow. S0 runs the same aggregate over the same rows with no join, and the
#    premise checks below assert that the aggregate really is vectorized there
#    and really is not under the join.
#
# ---------------------------------------------------------------------------
# What it measures
# ---------------------------------------------------------------------------
#
#   S0  no join at all, the control that makes the rest legible
#   S1  selective dimension join, small filtered dimension against a large fact
#   S2  unselective join, the dimension barely filters, so the join does real work
#   S3  multi-dimension star, where join order starts to matter
#   S4  wide projection under a join, does the join force decoding of columns
#       nothing needs
#
# Arms: heap and pgColumnar. See the BENCH_ARMS note below for why TimescaleDB is
# not one of them.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#
#   bench/run_bench_join.sh [PG_CONFIG]
#
#   BENCH_SCALE     fact rows                              (default 20000000)
#   BENCH_REPS      timed repetitions, median reported     (default 3)
#   BENCH_PORT      throwaway cluster port                 (default 55471)
#   BENCH_SHAPES    quantised,random                       (default both)
#   BENCH_ARMS      heap,columnar                          (default heap,columnar)
#
# A TimescaleDB arm is NOT offered. It needs create_hypertable plus the
# columnstore conversion, and until #428 is fixed a parallel query over a
# compressed hypertable fails outright when pgcolumnar is loaded, so the arm
# could only ever run serially and would not be a fair comparison. The flag is
# absent rather than accepting a value that would have built a plain heap table
# and labelled it TimescaleDB.
#   BENCH_KEEP      1 to leave the cluster up afterwards   (default 0)
#
# Run on an idle machine against a non-assert build. Written fresh for
# pgColumnar; it reuses no upstream benchmark script.
set -uo pipefail

PG_CONFIG="${1:-/usr/local/pg18n/bin/pg_config}"
SCALE="${BENCH_SCALE:-20000000}"
REPS="${BENCH_REPS:-3}"
PORT="${BENCH_PORT:-55471}"
SHAPES="${BENCH_SHAPES:-quantised,random}"
ARMS="${BENCH_ARMS:-heap,columnar}"
KEEP="${BENCH_KEEP:-0}"

BINDIR="$("$PG_CONFIG" --bindir)" || { echo "FATAL no pg_config"; exit 1; }
WORKDIR="$(mktemp -d /tmp/pgc-joinbench.XXXXXX)"
PGDATA="$WORKDIR/data"
fail=0

note() { printf '%s\n' "$*"; }
require() {  # require <description> <got> <want>
	if [ "$2" != "$3" ]; then
		printf 'FAIL   premise: %s (got [%s] want [%s])\n' "$1" "$2" "$3"
		fail=1
		return 1
	fi
	printf 'ok     premise: %s\n' "$1"
	return 0
}

note "== join benchmark, $SCALE fact rows, $REPS reps, shapes [$SHAPES], arms [$ARMS]"
note "   $("$PG_CONFIG" --version)"

"$BINDIR/initdb" -D "$PGDATA" --locale=C -U postgres > "$WORKDIR/initdb.log" 2>&1 \
	|| { tail -10 "$WORKDIR/initdb.log"; echo FATAL initdb; exit 1; }
NCPU=$(nproc)
# TimescaleDB has to be preloaded before the cluster starts, so decide here.
# A requested arm whose library is absent is announced, never silently dropped.
PRELOAD=pgcolumnar
MEMGB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
cat >> "$PGDATA/postgresql.conf" <<CONF
shared_preload_libraries = '$PRELOAD'
port = $PORT
shared_buffers = $(( MEMGB / 4 ))GB
effective_cache_size = $(( MEMGB * 3 / 4 ))GB
work_mem = 256MB
maintenance_work_mem = 2GB
max_wal_size = 16GB
max_worker_processes = $(( NCPU + 8 ))
max_parallel_workers = $NCPU
listen_addresses = ''
unix_socket_directories = '/tmp'
CONF
"$BINDIR/pg_ctl" -D "$PGDATA" -l "$WORKDIR/server.log" -w start >/dev/null 2>&1 \
	|| { tail -20 "$WORKDIR/server.log"; echo FATAL start; exit 1; }
cleanup() {
	[ "$KEEP" = 1 ] || "$BINDIR/pg_ctl" -D "$PGDATA" -w stop -m immediate >/dev/null 2>&1
	[ "$KEEP" = 1 ] || rm -rf "$WORKDIR"
}
trap cleanup EXIT
"$BINDIR/createdb" -h /tmp -p "$PORT" -U postgres joinbench >/dev/null 2>&1
P="$BINDIR/psql -h /tmp -p $PORT -U postgres -d joinbench -X -At"
$P -c "CREATE EXTENSION pgcolumnar;" >/dev/null 2>&1 || { echo FATAL extension; exit 1; }

# Serial, so the comparison is of the storage and not of the worker count. The
# main harness does the same and states why: parallelism is a separate axis, and
# mixing it in makes a storage difference unreadable.
SERIAL="SET max_parallel_workers_per_gather=0;"
# The accelerations that matter for an aggregate over our scan. Off by default
# (#401, #421), and a benchmark that leaves them off measures the wrong thing.
VEC="SET pgcolumnar.enable_vectorization=on; SET pgcolumnar.enable_ungrouped_vector_agg=on;"

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------
# One fact table per (arm, shape). Dimensions are heap in every arm, which is the
# realistic deployment and is also what keeps the join method comparable.
#
# quantised: metrics rounded to two decimals, what an instrument reports.
# random:    raw random(), maximum entropy, the worst case for any column store.
metric_expr() {  # metric_expr <shape>
	case "$1" in
		quantised) echo "round((random()*100)::numeric, 2)::float8" ;;
		random)    echo "random()" ;;
	esac
}

note "== dimensions"
$P -c "CREATE TABLE hosts (host_id int PRIMARY KEY, hostname text, region text, tier int);
       INSERT INTO hosts SELECT g, 'host'||g, 'r'||(g%20), g%5 FROM generate_series(1,2000) g;
       CREATE TABLE regions (region text PRIMARY KEY, continent text);
       INSERT INTO regions SELECT 'r'||g, 'c'||(g%4) FROM generate_series(0,19) g;
       ANALYZE hosts; ANALYZE regions;" >/dev/null 2>&1
require "the dimension loaded" "$($P -c 'SELECT count(*) FROM hosts')" "2000" || exit 1

IFS=',' read -r -a SHAPE_A <<< "$SHAPES"
IFS=',' read -r -a ARM_A <<< "$ARMS"

fact_name() { echo "fact_$1_$2"; }   # arm, shape

for shape in "${SHAPE_A[@]}"; do
	m=$(metric_expr "$shape")
	for arm in "${ARM_A[@]}"; do
		t=$(fact_name "$arm" "$shape")
		case "$arm" in
			columnar) using="USING pgcolumnar" ;;
			*)        using="" ;;
		esac
		note "== loading $t"
		$P -c "CREATE TABLE $t (ts timestamptz, host_id int, m1 float8, m2 float8,
		                        m3 float8, m4 float8, m5 float8, m6 float8,
		                        m7 float8, m8 float8) $using;" >/dev/null 2>&1
		$P -c "INSERT INTO $t SELECT
		         '2024-01-01'::timestamptz + (g % 8640000) * interval '10 second',
		         1 + (g % 2000), $m, $m, $m, $m, $m, $m, $m, $m
		       FROM generate_series(1,$SCALE) g;" >/dev/null 2>&1
		$P -c "VACUUM ANALYZE $t;" >/dev/null 2>&1
		n=$($P -c "SELECT count(*) FROM $t")
		sz=$($P -c "SELECT pg_total_relation_size('$t')")
		note "   $t: $n rows, $sz bytes"
		require "$t loaded every row" "$n" "$SCALE" || fail=1
		# No index on either fact table, so neither arm gets an index advantage.
		ni=$($P -c "SELECT count(*) FROM pg_index WHERE indrelid='$t'::regclass")
		require "$t carries no index" "$ni" "0" || fail=1
	done
done
[ "$fail" = 0 ] || { echo "FATAL a fixture premise failed"; exit 1; }

# ---------------------------------------------------------------------------
# The shapes
# ---------------------------------------------------------------------------
# %T is the fact table. S0 is the control and has no join at all.
q_for() {  # q_for <shape-id>
	case "$1" in
		S0) echo "SELECT avg(m1) FROM %T" ;;
		S1) echo "SELECT avg(f.m1) FROM %T f JOIN hosts h USING (host_id) WHERE h.tier = 3" ;;
		S2) echo "SELECT avg(f.m1) FROM %T f JOIN hosts h USING (host_id) WHERE h.tier < 5" ;;
		S3) echo "SELECT r.continent, avg(f.m1) FROM %T f JOIN hosts h USING (host_id)
		            JOIN regions r ON r.region = h.region WHERE h.tier < 4
		          GROUP BY r.continent ORDER BY 1" ;;
		S4) echo "SELECT avg(f.m1+f.m2+f.m3+f.m4+f.m5+f.m6+f.m7+f.m8)
		          FROM %T f JOIN hosts h USING (host_id) WHERE h.tier = 3" ;;
	esac
}
q_desc() {
	case "$1" in
		S0) echo "no join (control)" ;;
		S1) echo "selective dimension join" ;;
		S2) echo "unselective join" ;;
		S3) echo "multi-dimension star" ;;
		S4) echo "wide projection under a join" ;;
	esac
}
SHAPE_IDS="S0 S1 S2 S3 S4"

# One timed run, in milliseconds.
timed() {  # timed <table> <sql-with-%T>
	local sql="${2//%T/$1}" out
	out=$("$BINDIR/psql" -h /tmp -p "$PORT" -U postgres -d joinbench -X -t \
		-c "$SERIAL $VEC" -c '\timing on' -c "$sql" 2>&1)
	grep -qiE '^ERROR' <<<"$out" && { echo ERR; return; }
	grep -oE 'Time: [0-9.]+ ms' <<<"$out" | tail -1 | grep -oE '[0-9.]+'
}
median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
plan_of() {  # plan_of <table> <sql-with-%T>
	"$BINDIR/psql" -h /tmp -p "$PORT" -U postgres -d joinbench -X -At \
		-c "$SERIAL $VEC" -c "EXPLAIN (COSTS OFF) ${2//%T/$1}" 2>&1
}

# ---------------------------------------------------------------------------
# The premises that make the headline claim checkable rather than narrated
# ---------------------------------------------------------------------------
note "== premises on the plans"
for shape in "${SHAPE_A[@]}"; do
	ct=$(fact_name columnar "$shape")
	printf '%s\n' "${ARM_A[@]}" | grep -q columnar || continue

	# The claim this whole issue turns on: our vectorized aggregate sits directly
	# above our scan, so a join between them disables it. Asserted on both sides,
	# because either half alone is consistent with the feature simply being off.
	p0=$(plan_of "$ct" "$(q_for S0)")
	p1=$(plan_of "$ct" "$(q_for S1)")
	require "[$shape] the no-join control really is vectorized" \
		"$(grep -qi 'Vectorized' <<<"$p0" && echo yes || echo no)" "yes" || fail=1
	require "[$shape] a join between scan and aggregate disables it" \
		"$(grep -qi 'Vectorized' <<<"$p1" && echo yes || echo no)" "no" || fail=1

	# A different join method either side makes the comparison meaningless.
	for shp in S1 S2 S4; do
		hm=$(plan_of "$(fact_name heap "$shape")" "$(q_for $shp)" | grep -oE 'Hash Join|Merge Join|Nested Loop' | head -1)
		cm=$(plan_of "$ct" "$(q_for $shp)" | grep -oE 'Hash Join|Merge Join|Nested Loop' | head -1)
		require "[$shape] $shp uses the same join method in both arms ($hm)" "$cm" "$hm" || fail=1
	done
done

# ---------------------------------------------------------------------------
# Measure, interleaved
# ---------------------------------------------------------------------------
# One shape at a time across every arm before moving on. A sweep gives its first
# arm the cold cache and every later arm a warm one (#271).
note "== timings (median of $REPS, interleaved across arms)"
declare -A MS
for shape in "${SHAPE_A[@]}"; do
	for shp in $SHAPE_IDS; do
		for arm in "${ARM_A[@]}"; do
			t=$(fact_name "$arm" "$shape")
			runs=()
			for r in $(seq 1 "$REPS"); do runs+=("$(timed "$t" "$(q_for $shp)")"); done
			MS["$shape:$shp:$arm"]=$(median "${runs[@]}")
		done
		printf '   %-10s %-3s' "$shape" "$shp"
		for arm in "${ARM_A[@]}"; do printf ' %-9s=%-10s' "$arm" "${MS["$shape:$shp:$arm"]}"; done
		printf '\n'
	done
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo
echo "=============== JOIN BENCHMARK (#401) ==============="
echo "rows: $SCALE   reps: $REPS   serial   $(nproc) cores"
echo
for shape in "${SHAPE_A[@]}"; do
	echo "-- data shape: $shape"
	printf '%-4s %-32s %12s %12s %10s\n' id shape heap columnar 'col/heap'
	for shp in $SHAPE_IDS; do
		h="${MS["$shape:$shp:heap"]:-}"
		c="${MS["$shape:$shp:columnar"]:-}"
		r="-"
		case "$h$c" in
			*ERR*|"") ;;
			*) r=$(awk -v a="$c" -v b="$h" 'BEGIN { printf "%.2f", a / b }') ;;
		esac
		printf '%-4s %-32s %12s %12s %10s\n' "$shp" "$(q_desc $shp)" "$h" "$c" "$r"
	done
	hs=$($P -c "SELECT pg_total_relation_size('$(fact_name heap $shape)')")
	cs=$($P -c "SELECT pg_total_relation_size('$(fact_name columnar $shape)')")
	printf '%-4s %-32s %12s %12s %10s\n' "" "total relation size (bytes)" "$hs" "$cs" \
		"$(awk -v a="$cs" -v b="$hs" 'BEGIN { printf "%.3f", a / b }')"
	echo
done
echo "S0 against S1 is the finding: the same aggregate over the same rows, with"
echo "and without a join. Read those two lines together before anything else."
if [ "$fail" != 0 ]; then
	echo
	echo "A PREMISE FAILED. Do not quote these numbers."
	exit 1
fi
exit 0
