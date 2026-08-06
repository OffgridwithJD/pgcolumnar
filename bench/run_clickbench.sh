#!/usr/bin/env bash
#
# ClickBench on pgColumnar (issue #421). An optional run: nothing here is in the
# matrix, and nothing downloads unless you ask for it.
#
# ClickBench is a single 105-column web-analytics table of about 100 million
# rows and 43 queries, most of them GROUP BY with a filter. It is the workload
# this project should be good at, which is exactly why it is worth measuring
# rather than assuming.
#
# ---------------------------------------------------------------------------
# What this script does NOT contain, on purpose
# ---------------------------------------------------------------------------
#
# The ClickBench schema and its 43 queries are not copied into this repository,
# and there are two separate reasons. Either one is sufficient.
#
# ClickBench is licensed CC BY-NC-SA 4.0. It is NOT Apache-2.0; that is
# ClickHouse the database, in a different repository, and an earlier revision of
# this comment had it wrong. NonCommercial and ShareAlike are restrictions the
# MIT license this project ships under does not carry, so an in-tree copy would
# put material into an MIT distribution that downstream users cannot use on MIT
# terms. PROVENANCE.md opens by saying the project is built clean-room so that it
# "can be released under the MIT License".
#
# And PROVENANCE.md says "Do not copy its test files or its expected output", and
# a benchmark definition from another project is that.
#
# So it is fetched from upstream at run time, into the data directory, and never
# into the tree. Feeding it to psql unmodified is use rather than copying, which
# PROVENANCE.md already draws a line around: "Running a program is not copying
# it." Our comparison oracle is the heap arm of this same run, not anybody
# else's expected output.
#
# The numbers this produces are comparable to published ClickBench results only
# to the extent the protocol below matches theirs. Where it deviates, it says so
# in the output. Read "Deviations" below before quoting a number anywhere.
#
# ---------------------------------------------------------------------------
# The three arms, and why there are three
# ---------------------------------------------------------------------------
#
#   heap             PostgreSQL as shipped, the baseline.
#   columnar         pgColumnar with its defaults, which is what a user gets.
#   columnar_tuned   pgColumnar with its aggregate accelerations turned on.
#
# The third arm exists because of a fact worth stating plainly: the grouped
# vectorized aggregate is OFF by default (pgcolumnar.enable_group_vectorization),
# and so is the ungrouped one. About 35 of the 43 queries are GROUP BY. A
# default-configuration run therefore measures this engine with its main
# analytical accelerator disabled. Reporting only that number would understate
# the engine, and reporting only the tuned number would misrepresent what a user
# gets. So both run, and both are published.
#
# ---------------------------------------------------------------------------
# Deviations from the published ClickBench protocol
# ---------------------------------------------------------------------------
#
#  - The arms are INTERLEAVED per query rather than swept per arm. A sweep gives
#    its first arm the cold cache and every later arm a warm one, which is how
#    #271 produced a biased table that an impossible result eventually exposed.
#  - No COPY FREEZE. The upstream loader uses it; it is a heap optimisation, and
#    using it on one arm only would make the load times incomparable.
#  - The cold run drops the page cache but does not restart the server between
#    every query. Upstream calls that a "lukewarm cold run" and requires the tag,
#    so the output carries it.
#  - A row SAMPLE is the default, because a 100 million row load takes hours.
#    PGC_CB_ROWS=all is the real thing.
#
# ---------------------------------------------------------------------------
# Why the sample is a stride and never a prefix
# ---------------------------------------------------------------------------
#
# hits.tsv is ordered. Measured on the real file:
#
#     head -1000000        EventDate distinct 1     CounterID distinct 7
#     every 100th row      EventDate distinct 17    CounterID distinct 4220
#
# So the first million rows are a single day and seven counters. A prefix does
# not scale the benchmark down, it replaces it: every GROUP BY collapses to a
# handful of groups, every date range hits one day, and the storage clusters
# perfectly on the columns the queries filter. That flatters columnar enormously
# and the resulting table would be worthless.
#
# The sample is therefore every Nth row, which preserves the distributions. It
# costs a full decompression of the 16 GB file, once, cached afterwards. The
# representativeness premise below fails the run if the loaded sample is degenerate,
# so this cannot silently regress back to a prefix.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#
#   bench/run_clickbench.sh [PG_CONFIG]
#
#   PGC_CB_ROWS     row prefix, or "all" for the full table   (default 10000000)
#   PGC_CB_DATA     where hits.tsv.gz and the fetched SQL live (default /srv/clickbench)
#   PGC_CB_TRIES    runs per query per arm                     (default 3)
#   PGC_CB_ARMS     comma list from heap,columnar,columnar_tuned,citus,duckdb
#                   (default heap,columnar,columnar_tuned)
#   PGC_CB_PORT     port for the throwaway cluster             (default 58900)
#   PGC_CB_PGDATA   data directory for it                      (default $PGC_CB_DATA/pgdata)
#   PGC_CB_KEEP     1 to leave the cluster running afterwards  (default 0)
#   PGC_CB_MAXGROUPS  pgcolumnar.groupagg_max_groups for the tuned arm
#
# Written fresh for pgColumnar. It reuses no upstream benchmark script.
set -uo pipefail

PG_CONFIG="${1:-/usr/local/pg18n/bin/pg_config}"
CB_DATA="${PGC_CB_DATA:-/srv/clickbench}"
CB_ROWS="${PGC_CB_ROWS:-10000000}"
CB_TRIES="${PGC_CB_TRIES:-3}"
CB_ARMS="${PGC_CB_ARMS:-heap,columnar,columnar_tuned}"
CB_PORT="${PGC_CB_PORT:-58900}"
CB_PGDATA="${PGC_CB_PGDATA:-$CB_DATA/pgdata}"
CB_KEEP="${PGC_CB_KEEP:-0}"
CB_MAXGROUPS="${PGC_CB_MAXGROUPS:-200000000}"

CB_URL_BASE="https://raw.githubusercontent.com/ClickHouse/ClickBench/main/postgresql"
CB_TSV_URL="https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz"

# Ratio of two timings, or "-" when either side is missing.
#
# Testing the CONCATENATION "$a$b" only catches BOTH sides missing. One empty
# side concatenates to a non-empty string and divides, giving 0.00 or inf. 0.00
# is the dangerous one: it reads as a 100 percent win in a table meant to be
# quoted without the run log beside it. Same class as #418.
ratio() {  # ratio <numerator> <denominator> -> "n.nn" or "-"
	case "$1" in '' | *ERR*) echo '-'; return ;; esac
	case "$2" in '' | *ERR*) echo '-'; return ;; esac
	if [ "$(awk -v x="$2" 'BEGIN { print (x + 0 == 0) ? 1 : 0 }')" = 1 ]; then
		echo '-'; return
	fi
	awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", a / b }'
}
# Proved before any number is printed.
[ "$(ratio '' 800)" = '-' ] && [ "$(ratio 1500 '')" = '-' ] && [ "$(ratio 1500 0)" = '-' ] \
	&& [ "$(ratio ERR 800)" = '-' ] && [ "$(ratio 800 1600)" = '0.50' ] \
	|| { echo "FATAL the ratio guard does not reject what it claims to"; exit 1; }

fail=0
note() { printf '%s\n' "$*"; }
die()  { printf 'FATAL  %s\n' "$*" >&2; exit 1; }

# A premise that does not hold makes every number below it meaningless, so it is
# fatal rather than a warning. Half this file is these.
require() {  # require <description> <condition-result> <expected>
	if [ "$2" != "$3" ]; then
		printf 'FAIL   premise: %s (got [%s] want [%s])\n' "$1" "$2" "$3" >&2
		fail=1
		return 1
	fi
	printf 'ok     premise: %s\n' "$1"
	return 0
}

BINDIR="$("$PG_CONFIG" --bindir)" || die "no pg_config at $PG_CONFIG"
PSQL="$BINDIR/psql -h /tmp -p $CB_PORT -U postgres -d clickbench -X -q"

# ---------------------------------------------------------------------------
# 0. Preconditions, once, loudly
# ---------------------------------------------------------------------------
note "== preconditions"
for t in curl awk zcat "$BINDIR/psql" "$BINDIR/initdb" "$BINDIR/pg_ctl"; do
	command -v "$t" >/dev/null 2>&1 || [ -x "$t" ] || die "missing tool: $t"
done
mkdir -p "$CB_DATA" || die "cannot write $CB_DATA"
note "   pg_config: $PG_CONFIG ($("$PG_CONFIG" --version))"
note "   data dir:  $CB_DATA"
note "   rows:      $CB_ROWS    tries: $CB_TRIES    arms: $CB_ARMS"

# ---------------------------------------------------------------------------
# 1. The definition, fetched rather than vendored
# ---------------------------------------------------------------------------
note "== fetching the ClickBench definition (not stored in this repository)"
for f in create.sql queries.sql; do
	if [ ! -s "$CB_DATA/$f" ]; then
		curl -sSL --retry 3 --max-time 120 -o "$CB_DATA/$f" "$CB_URL_BASE/$f" \
			|| die "could not fetch $f"
		note "   fetched $f"
	else
		note "   have $f already"
	fi
done
NQUERIES=$(grep -c 'SELECT' "$CB_DATA/queries.sql")
require "the query file holds 43 queries" "$NQUERIES" "43" || exit 1
# The column count is asserted against the CREATED TABLE further down, not
# against a regular expression over somebody else's DDL. A first version of this
# pattern-matched the type names, missed five spellings, and reported 100.
CB_EXPECT_COLS=105

# ---------------------------------------------------------------------------
# 2. The data
# ---------------------------------------------------------------------------
GZ="$CB_DATA/hits.tsv.gz"
if [ ! -s "$GZ" ]; then
	note "== downloading hits.tsv.gz (16.3 GB); this is the slow part"
	curl -sSL --retry 5 --retry-delay 10 -C - -o "$GZ" "$CB_TSV_URL" || die "download failed"
fi
note "   hits.tsv.gz: $(stat -c%s "$GZ") bytes"

CB_FULL_ROWS=99997497	# upstream's documented row count, used only to size the stride
case "$CB_ROWS" in
	all|full|0)
		TSV="$CB_DATA/hits.tsv"; STRIDE=1 ;;
	*)
		STRIDE=$(( CB_FULL_ROWS / CB_ROWS ))
		[ "$STRIDE" -ge 1 ] || STRIDE=1
		TSV="$CB_DATA/hits.every$STRIDE.tsv" ;;
esac
if [ ! -s "$TSV" ]; then
	note "== materialising $TSV (every ${STRIDE}th row)"
	# Once, and reused by every arm. Decompressing per arm would put minutes of
	# gunzip inside a load time that is supposed to measure the database.
	if [ "$STRIDE" -gt 1 ]; then
		zcat "$GZ" | awk -v k="$STRIDE" 'NR % k == 0' > "$TSV" || die "sampling failed"
	else
		zcat "$GZ" > "$TSV" || die "decompression failed"
	fi
fi
TSV_BYTES=$(stat -c%s "$TSV")
TSV_ROWS=$(wc -l < "$TSV")
note "   $TSV: $TSV_ROWS rows, $TSV_BYTES bytes (stride $STRIDE)"
require "the extracted TSV is not empty" "$([ "$TSV_ROWS" -gt 0 ] && echo yes || echo no)" "yes" || exit 1

# ---------------------------------------------------------------------------
# 3. A throwaway cluster, sized to this box
# ---------------------------------------------------------------------------
note "== cluster"
MEMKB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
# citus_columnar must be preloaded before the cluster starts. Both extensions
# registering a custom scan named ColumnarScan used to make this combination
# refuse to start outright (#428); #429 renamed ours, so the arm is possible.
CB_PRELOAD=pgcolumnar
case ",$CB_ARMS," in *,citus,*) CB_PRELOAD="citus_columnar,pgcolumnar" ;; esac
NCPU=$(nproc)
SHARED_MB=$(( MEMKB / 1024 / 4 ))
CACHE_MB=$(( MEMKB / 1024 * 3 / 4 ))
if [ -d "$CB_PGDATA" ]; then
	"$BINDIR/pg_ctl" -D "$CB_PGDATA" -w stop >/dev/null 2>&1
	rm -rf "$CB_PGDATA"
fi
"$BINDIR/initdb" -D "$CB_PGDATA" --locale=C -U postgres > "$CB_DATA/initdb.log" 2>&1 \
	|| { tail -20 "$CB_DATA/initdb.log"; die "initdb failed"; }
# Settings follow the shape the upstream PostgreSQL entry uses, scaled to this
# machine. They are applied to every arm equally, so they cannot favour one.
cat >> "$CB_PGDATA/postgresql.conf" <<CONF
shared_preload_libraries = '$CB_PRELOAD'
port = $CB_PORT
shared_buffers = ${SHARED_MB}MB
effective_cache_size = ${CACHE_MB}MB
work_mem = 64MB
maintenance_work_mem = 1GB
max_wal_size = 32GB
max_worker_processes = $(( NCPU + 15 ))
max_parallel_workers = $NCPU
max_parallel_workers_per_gather = $(( NCPU / 2 ))
max_parallel_maintenance_workers = $(( NCPU / 2 ))
listen_addresses = ''
unix_socket_directories = '/tmp'
CONF
"$BINDIR/pg_ctl" -D "$CB_PGDATA" -l "$CB_PGDATA/server.log" -w start >/dev/null 2>&1 \
	|| { tail -30 "$CB_PGDATA/server.log"; die "cluster did not start"; }
cleanup() {
	if [ "$CB_KEEP" != 1 ]; then
		"$BINDIR/pg_ctl" -D "$CB_PGDATA" -w stop >/dev/null 2>&1
	fi
}
trap cleanup EXIT
"$BINDIR/createdb" -h /tmp -p "$CB_PORT" -U postgres clickbench >/dev/null 2>&1
$PSQL -c "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null 2>&1 \
	|| die "could not create the extension"
case ",$CB_ARMS," in *,citus,*)
	$PSQL -c "CREATE EXTENSION IF NOT EXISTS citus_columnar;" >/dev/null 2>&1 \
		|| die "the citus arm was asked for and citus_columnar will not install"
	require "citus columnar registers its access method" \
		"$($PSQL -At -c "SELECT count(*) FROM pg_am WHERE amname='columnar' AND amtype='t'")" "1" ;;
esac
EXTVER=$($PSQL -At -c "SELECT extversion FROM pg_extension WHERE extname='pgcolumnar'")
require "the extension is installed" "$([ -n "$EXTVER" ] && echo yes || echo no)" "yes" || exit 1
note "   pgcolumnar $EXTVER on port $CB_PORT"

# ---------------------------------------------------------------------------
# 4. One table per arm, from the same fetched DDL
# ---------------------------------------------------------------------------
# The DDL is rewritten only in its table name and its USING clause. Rewriting
# the column list would be writing our own schema, and then the workload is no
# longer ClickBench.
ddl_for() {  # ddl_for <table> <using clause or empty>
	sed -e "s/^CREATE TABLE hits\b/CREATE TABLE $1/" "$CB_DATA/create.sql" |
		sed -e "\$s/;\s*\$/ $2;/"
}
arm_table() {  # arm -> table name
	case "$1" in
		heap)  echo hits_heap ;;
		citus) echo hits_citus ;;
		*)     echo hits_col ;;
	esac
}
arm_settings() {  # arm -> SET statements applied per session
	case "$1" in
		columnar_tuned)
			echo "SET pgcolumnar.enable_group_vectorization = on;
			      SET pgcolumnar.enable_ungrouped_vector_agg = on;
			      SET pgcolumnar.enable_parallel_vector_agg = on;
			      SET pgcolumnar.groupagg_max_groups = $CB_MAXGROUPS;" ;;
		*) echo "" ;;
	esac
}

IFS=',' read -r -a ARMS <<< "$CB_ARMS"
declare -A LOAD_S SIZE_B ROWS

note "== load"
for arm in "${ARMS[@]}"; do
	# duckdb is not a table in this cluster; it is loaded separately below.
	[ "$arm" = duckdb ] && continue
	tbl=$(arm_table "$arm")
	# columnar and columnar_tuned share one table: they differ only in session
	# settings, and loading it twice would double the load time for nothing.
	if [ -n "${ROWS[$tbl]:-}" ]; then
		LOAD_S[$arm]=${LOAD_S[shared_$tbl]}; SIZE_B[$arm]=${SIZE_B[shared_$tbl]}
		ROWS[$arm]=${ROWS[$tbl]}
		note "   $arm reuses $tbl"
		continue
	fi
	case "$arm" in
		heap)   using="" ;;
		citus)  using="USING columnar" ;;
		*)      using="USING pgcolumnar" ;;
	esac
	$PSQL -c "DROP TABLE IF EXISTS $tbl;" >/dev/null 2>&1
	ddl_for "$tbl" "$using" | $PSQL -v ON_ERROR_STOP=1 >/dev/null 2>"$CB_DATA/ddl.$arm.err"
	if [ -s "$CB_DATA/ddl.$arm.err" ]; then
		head -5 "$CB_DATA/ddl.$arm.err"; die "$arm DDL failed"
	fi
	t0=$(date +%s.%N)
	$PSQL -v ON_ERROR_STOP=1 -c "\\copy $tbl FROM '$TSV'" > "$CB_DATA/load.$arm.log" 2>&1 \
		|| { tail -5 "$CB_DATA/load.$arm.log"; die "$arm load failed"; }
	$PSQL -c "VACUUM ANALYZE $tbl;" >/dev/null 2>&1
	t1=$(date +%s.%N)
	LOAD_S[$arm]=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
	ROWS[$arm]=$($PSQL -At -c "SELECT count(*) FROM $tbl")
	SIZE_B[$arm]=$($PSQL -At -c "SELECT pg_total_relation_size('$tbl')")
	ROWS[$tbl]=${ROWS[$arm]}
	LOAD_S[shared_$tbl]=${LOAD_S[$arm]}; SIZE_B[shared_$tbl]=${SIZE_B[$arm]}
	note "   $arm: ${LOAD_S[$arm]}s, ${ROWS[$arm]} rows, ${SIZE_B[$arm]} bytes"
done

# ---------------------------------------------------------------------------
# The DuckDB arm, which is not a table in this cluster
# ---------------------------------------------------------------------------
# A PERSISTENT database file, never :memory:. In memory DuckDB is not being asked
# the same question as an engine that has to durably store what it loaded, and
# the comparison would not be fair.
#
# The ClickBench PostgreSQL DDL parses in DuckDB unmodified, so the arm runs the
# same 105 columns and the same 43 queries from the same TSV.
#
# NULLSTR matters: DuckDB reads an empty CSV field as NULL, ClickBench's TSV uses
# empty strings for empty text, and every column is NOT NULL. Without it the load
# fails on hits.Title and leaves an EMPTY table, and the queries then all "run"
# while measuring nothing.
DUCK_DB="$CB_DATA/clickbench.duckdb"
if printf '%s\n' "${ARMS[@]}" | grep -qx duckdb; then
	command -v duckdb >/dev/null 2>&1 || die "the duckdb arm was asked for and duckdb is not on PATH"
	note "== loading duckdb (persistent file, not in memory)"
	rm -f "$DUCK_DB" "$DUCK_DB.wal"
	duckdb "$DUCK_DB" ".read $CB_DATA/create.sql" >/dev/null 2>&1
	t0=$(date +%s.%N)
	duckdb "$DUCK_DB" "COPY hits FROM '$TSV' (DELIMITER '\t', HEADER false, QUOTE '', ESCAPE '', NULLSTR '\\N');" \
		> "$CB_DATA/load.duckdb.log" 2>&1 || { tail -3 "$CB_DATA/load.duckdb.log"; die "duckdb load failed"; }
	t1=$(date +%s.%N)
	LOAD_S[duckdb]=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
	ROWS[duckdb]=$(duckdb "$DUCK_DB" -noheader -list 'SELECT count(*) FROM hits' 2>/dev/null)
	SIZE_B[duckdb]=$(stat -c%s "$DUCK_DB")
	note "   duckdb: ${LOAD_S[duckdb]}s, ${ROWS[duckdb]} rows, ${SIZE_B[duckdb]} bytes"
fi

# Every arm must hold the same rows as the file. A load that silently dropped
# rows makes every query below faster and wrong.
for arm in "${ARMS[@]}"; do
	require "$arm loaded every row of the file" "${ROWS[$arm]}" "$TSV_ROWS" || fail=1
done

# The schema is the one upstream publishes, asked of the database rather than of
# a regular expression over their file.
for arm in "${ARMS[@]}"; do
	[ "$arm" = duckdb ] && continue
	tbl=$(arm_table "$arm")
	n=$($PSQL -At -c "SELECT count(*) FROM pg_attribute WHERE attrelid='$tbl'::regclass AND attnum > 0 AND NOT attisdropped")
	require "$tbl has $CB_EXPECT_COLS columns" "$n" "$CB_EXPECT_COLS" || fail=1
done

# The sample must look like the table, not like the first day of it.
#
# This is the assertion with teeth in this file. hits.tsv is ordered, so a
# prefix has one EventDate and seven CounterIDs where the whole file has 17 and
# 4,220. Every number in a run built on a prefix is wrong in the direction that
# flatters us, and nothing else here would notice: the loads succeed, the row
# counts match, the queries return, and they return fast.
#
# The bounds are set from the measured whole-file values with a wide margin, so
# they catch a degenerate sample without tracking data drift.
smpl_tbl=$(arm_table "${ARMS[0]}")
NDATES=$($PSQL -At -c "SELECT count(DISTINCT EventDate) FROM $smpl_tbl")
NCOUNTERS=$($PSQL -At -c "SELECT count(DISTINCT CounterID) FROM $smpl_tbl")
note "   sample spread: $NDATES distinct EventDate, $NCOUNTERS distinct CounterID"
require "the sample spans the month, not one day" \
	"$([ "${NDATES:-0}" -ge 10 ] && echo yes || echo no)" "yes" || fail=1
require "the sample spans many counters, not a handful" \
	"$([ "${NCOUNTERS:-0}" -ge 500 ] && echo yes || echo no)" "yes" || fail=1

[ "$fail" = 0 ] || die "a load premise failed; the timings below would be meaningless"

# The columnar arm must actually be reading through the columnar scan. If the
# planner falls back, this measures PostgreSQL reading columnar storage badly
# and reports it as a columnar result.
if printf '%s\n' "${ARMS[@]}" | grep -qx columnar; then
	plan=$($PSQL -At -c "EXPLAIN (COSTS OFF) SELECT count(*) FROM hits_col WHERE CounterID = 62" 2>&1)
	require "the columnar arm plans a columnar scan" \
		"$(grep -qi 'columnar' <<<"$plan" && echo yes || echo no)" "yes" || fail=1
fi

# And the tuned arm must actually be vectorizing. EXPLAIN prints the same node
# name, Custom Scan (ColumnarScan), whether or not the aggregate is vectorized,
# so the node name cannot tell them apart. The property line can.
if printf '%s\n' "${ARMS[@]}" | grep -qx columnar_tuned; then
	vplan=$($PSQL -At -c "$(arm_settings columnar_tuned)
		EXPLAIN (COSTS OFF) SELECT CounterID, count(*) FROM hits_col GROUP BY CounterID" 2>&1)
	require "the tuned arm plans a vectorized aggregate" \
		"$(grep -qi 'Vectorized' <<<"$vplan" && echo yes || echo no)" "yes" || fail=1
	# And the untuned arm must NOT, or the two arms are the same measurement.
	uplan=$($PSQL -At -c "EXPLAIN (COSTS OFF) SELECT CounterID, count(*) FROM hits_col GROUP BY CounterID" 2>&1)
	require "the default arm does not, so the two arms differ" \
		"$(grep -qi 'Vectorized' <<<"$uplan" && echo no || echo yes)" "yes" || fail=1

	# The two markers are NOT the same thing, and the check above cannot tell them
	# apart. "Columnar Vectorized Aggregates" is printed for the ungrouped fold as
	# well, so a bare grep for "Vectorized" is satisfied by the ungrouped
	# acceleration alone, and the GROUPED one may never engage.
	#
	# That matters because the tuned arm sets three GUCs at once. Anyone reading
	# the table below will attribute a difference to the grouped aggregate, and on
	# this dataset the planner declines it on most shapes: measured on the same
	# table, it is declined at 5,727, 18,344 and 49,511 groups, and chosen only at
	# 4,906,030 (#369). So the arm is labelled by what it SETS and the grouped
	# marker is reported separately, rather than being implied.
	gk=$(grep -ci 'Vectorized Group Keys' <<<"$vplan")
	note "   grouped-aggregate marker on the probe shape: $([ "$gk" -gt 0 ] && echo present || echo ABSENT)"
	note "   so the tuned arm means 'these three GUCs set', not 'the grouped node ran'"
fi

# ---------------------------------------------------------------------------
# 5. The queries, interleaved
# ---------------------------------------------------------------------------
# One query at a time, all arms, before moving on. A sweep would give arm 1 the
# cold cache and every later arm a warm one (#271).
note "== queries ($NQUERIES x ${#ARMS[@]} arms x $CB_TRIES tries, interleaved)"

drop_caches() {
	sync
	if [ -w /proc/sys/vm/drop_caches ]; then
		echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
	elif command -v sudo >/dev/null 2>&1; then
		sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
	fi
}

# Run one query once and return its milliseconds, or ERR.
run_one() {  # run_one <arm> <sql>
	local arm="$1" sql="$2" tbl out ms t0 t1

	if [ "$arm" = duckdb ]; then
		# duckdb's CLI has no \timing, so time the process. That includes
		# process start, which is tens of milliseconds and is stated rather
		# than hidden; it matters only for the very fastest queries.
		t0=$(date +%s.%N)
		out=$(duckdb "$DUCK_DB" -noheader -list "$sql" 2>&1)
		t1=$(date +%s.%N)
		if grep -qiE '^(Error|Parser Error|Binder Error|Catalog Error)' <<<"$out"; then
			printf 'ERR\n'
			printf '%s\n' "$out" | head -1 >> "$CB_DATA/query_errors.log"
			return
		fi
		awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f\n", (b - a) * 1000 }'
		return
	fi

	tbl=$(arm_table "$arm")
	out=$(env PGOPTIONS="" "$BINDIR/psql" -h /tmp -p "$CB_PORT" -U postgres -d clickbench -X -t \
		-c "$(arm_settings "$arm")" -c '\timing on' \
		-c "${sql//FROM hits/FROM $tbl}" 2>&1)
	if grep -qiE '^(ERROR|psql: error|FATAL)' <<<"$out"; then
		printf 'ERR\n'
		printf '%s\n' "$out" | grep -iE '^ERROR' | head -1 >> "$CB_DATA/query_errors.log"
		return
	fi
	ms=$(grep -oE 'Time: [0-9.]+ ms' <<<"$out" | tail -1 | grep -oE '[0-9.]+')
	printf '%s\n' "${ms:-ERR}"
}

# Did the GROUPED vectorized node actually run for this query on this arm? A
# difference in the table means nothing about that node unless it engaged, and on
# this dataset it usually does not (#369).
grouped_engaged() {  # grouped_engaged <arm> <sql>
	local arm="$1" tbl
	tbl=$(arm_table "$arm")
	env "$BINDIR/psql" -h /tmp -p "$CB_PORT" -U postgres -d clickbench -X -At \
		-c "$(arm_settings "$arm")" \
		-c "EXPLAIN (COSTS OFF) ${2//FROM hits/FROM $tbl}" 2>&1 |
		grep -qi 'Vectorized Group Keys' && echo yes || echo no
}

declare -A COLD HOT ERRS
: > "$CB_DATA/query_errors.log"
: > "$CB_DATA/raw_timings.tsv"

qn=0
while IFS= read -r sql; do
	[ -n "$sql" ] || continue
	qn=$((qn + 1))
	drop_caches
	for arm in "${ARMS[@]}"; do
		times=""
		for try in $(seq 1 "$CB_TRIES"); do
			t=$(run_one "$arm" "$sql")
			times="$times $t"
			printf 'q%s\t%s\t%s\t%s\n' "$qn" "$arm" "$try" "$t" >> "$CB_DATA/raw_timings.tsv"
		done
		set -- $times
		COLD["$qn:$arm"]="$1"
		# Hot is the best of the runs after the first, which is what ClickBench
		# reports. Not a median: their site takes the minimum of runs 2 and 3.
		shift
		best=""
		for t in "$@"; do
			case "$t" in ERR) continue ;; esac
			if [ -z "$best" ] || [ "$(awk -v a="$t" -v b="$best" 'BEGIN { print (a < b) ? 1 : 0 }')" = 1 ]; then
				best="$t"
			fi
		done
		HOT["$qn:$arm"]="${best:-ERR}"
		case "${COLD["$qn:$arm"]}${HOT["$qn:$arm"]}" in
			*ERR*) ERRS["$arm"]=$(( ${ERRS["$arm"]:-0} + 1 )) ;;
		esac
	done
	printf '   q%-3s' "$qn"
	for arm in "${ARMS[@]}"; do printf ' %-14s' "$arm=${HOT["$qn:$arm"]}"; done
	printf '\n'
done < "$CB_DATA/queries.sql"

require "every query in the file ran" "$qn" "$NQUERIES" || fail=1

# ---------------------------------------------------------------------------
# 6. Report
# ---------------------------------------------------------------------------
echo
echo "================= CLICKBENCH, pgColumnar $EXTVER ================="
echo "tag: lukewarm-cold-run (page cache dropped, server not restarted per query)"
printf '%s\n' "${ARMS[@]}" | grep -qx duckdb && \
	echo "duckdb: PERSISTENT database file, not :memory:, so it stores what it loaded like the others"
printf '%s\n' "${ARMS[@]}" | grep -qx citus && \
	echo "citus:  citus_columnar USING columnar, co-loaded with pgcolumnar (possible since #429)"
echo "rows: $TSV_ROWS    tries: $CB_TRIES    host: $(nproc) cores, $(( MEMKB / 1024 / 1024 )) GB"
echo
printf '%-16s %12s %16s %10s\n' arm 'load (s)' 'size (bytes)' 'errors'
for arm in "${ARMS[@]}"; do
	printf '%-16s %12s %16s %10s\n' "$arm" "${LOAD_S[$arm]}" "${SIZE_B[$arm]}" "${ERRS[$arm]:-0}"
done
echo
echo "-- hot times, milliseconds. 'x' is columnar over heap; above 1.00 means we lose."
printf '%-6s' query
for arm in "${ARMS[@]}"; do printf ' %14s' "$arm"; done
printf ' %10s %10s\n' 'col/heap' 'tuned/heap'
wins=0; losses=0
for q in $(seq 1 "$qn"); do
	printf 'q%-5s' "$q"
	for arm in "${ARMS[@]}"; do printf ' %14s' "${HOT["$q:$arm"]}"; done
	r1="-"; r2="-"
	h="${HOT["$q:heap"]:-}"
	c="${HOT["$q:columnar"]:-}"
	tu="${HOT["$q:columnar_tuned"]:-}"
	r1=$(ratio "$c" "$h")
	if [ "$r1" != "-" ]; then
		if [ "$(awk -v r="$r1" 'BEGIN { print (r < 1) ? 1 : 0 }')" = 1 ]; then
			wins=$((wins + 1)); else losses=$((losses + 1)); fi
	fi
	r2=$(ratio "$tu" "$h")
	printf ' %10s %10s\n' "$r1" "$r2"
done
echo
echo "columnar beats heap on $wins queries and loses on $losses, at defaults."
if [ -s "$CB_DATA/query_errors.log" ]; then
	echo
	echo "-- queries that errored, which are reported and NOT dropped:"
	sort "$CB_DATA/query_errors.log" | uniq -c | sed 's/^/   /'
fi
echo
echo "raw timings: $CB_DATA/raw_timings.tsv"
echo "=================================================================="
if [ "$fail" != 0 ]; then
	echo "A PREMISE FAILED. Do not quote these numbers."
	exit 1
fi
exit 0
