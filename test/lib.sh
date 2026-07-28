#!/usr/bin/env bash
#
# pgColumnar shared test harness.
#
# Sourced by the differential/recovery/fuzz suites. Provides a throwaway
# cluster lifecycle, a heap-vs-columnar differential oracle, and pass/fail
# accounting. Written fresh for pgColumnar; it does not reuse any upstream test
# file or expected-output file.
#
# The differential oracle is the core idea: every table under test has a heap
# mirror loaded with identical data, and a query is run against both. The two
# result sets are compared as order-independent hashes, so heap acts as the
# reference oracle for pgcolumnar. This catches encode/decode and skipping bugs
# generically instead of via hardcoded expected values.
#
# Conventions for suites that source this file:
#   - Call pgc_setup "$@" once (passes through the optional PG_CONFIG arg).
#   - Use q "SQL" for a scalar, psql_run for a statement, psql_file FILE.
#   - Use diff_query LABEL "SQL with %T" to compare a heap/columnar pair.
#   - Finish with pgc_summary (exits non-zero if any check failed).
#
# Client SQL runs as the current (root) user over TCP with trust auth, so
# -f files never have postgres-ownership problems; only initdb and pg_ctl run
# as the postgres OS user.

# Do not set -e here: the suite sets its own shell options. The oracle helpers
# must not abort the run on a single mismatch or a SQL error; they record a
# failure and continue.

PGC_FAIL=0
PGC_CHECKS=0

# ---- cluster identity helpers ----------------------------------------------

# Normalize a directory for comparison. `cd && pwd -P` is POSIX; realpath -m is
# GNU only, and falling back to a raw string compare would compare exactly the
# unresolved paths this check exists to reconcile.
pgc_norm_path() {
	(cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

# The data directory of whatever server answers on PGC_PORT, or empty.
# Retried, because pg_ctl -w can return just before the server is connectable and
# an unanswered probe must never be mistaken for a match.
pgc_cluster_datadir() {
	local _i _d

	for _i in $(seq 1 15); do
		_d="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" \
			-U postgres -d postgres -At -c 'SHOW data_directory' 2>/dev/null)"
		if [ -n "$_d" ]; then
			printf '%s\n' "$_d"
			return 0
		fi
		sleep 1
	done
	return 1
}

. "$(dirname "${BASH_SOURCE[0]}")/portlib.sh"

# True when nothing is accepting connections on the given port.
pgc_port_free() {
	! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# True when the server answering on PGC_PORT is the cluster at PGC_PGDATA. This is
# the guard the start loop applies before trusting a started cluster; naming it
# lets the self-test exercise the decision itself rather than only its inputs. An
# empty (unanswered) probe is deliberately not ours.
pgc_cluster_is_ours() {
	local _d
	_d="$(pgc_cluster_datadir)"
	[ -n "$_d" ] && 		[ "$(pgc_norm_path "$_d")" = "$(pgc_norm_path "$PGC_PGDATA")" ]
}

# ---- setup / teardown ------------------------------------------------------

pgc_setup() {
	PGC_PG_CONFIG="${1:-/usr/local/pg17/bin/pg_config}"
	PGC_BINDIR="$("$PGC_PG_CONFIG" --bindir)"
	# Derived from this process rather than a fixed 54329: two suites run at
	# once on one box otherwise start on the same port, and the loser reports a
	# wall of ERROR: database "regress" already exists with no named check
	# failing -- a red that reads exactly like a real one. There is a retry
	# below for when this still collides; the default should not guarantee it.
	PGC_PORT="${PGC_PORT:-$(pgc_pick_port)}"
	PGC_DB="${PGC_DB:-regress}"
	PGC_LIBDIR="$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
	PGC_SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

	PGC_WORKDIR="$(mktemp -d /tmp/pgcolumnar-test.XXXXXX)"
	PGC_PGDATA="$PGC_WORKDIR/data"
	PGC_LOGFILE="$PGC_WORKDIR/server.log"
	PGC_SQLDIR="$PGC_WORKDIR/sql"
	mkdir -p "$PGC_SQLDIR"
	chmod 777 "$PGC_WORKDIR" "$PGC_SQLDIR"

	echo "== pgColumnar test: $(basename "$0") =="
	echo "PG_CONFIG=$PGC_PG_CONFIG"
	echo "version=$("$PGC_PG_CONFIG" --version)"
	echo "workdir=$PGC_WORKDIR"

	# The matrix runner builds and installs once per version and sets
	# PGC_SKIP_BUILD so parallel suites do not each rebuild (a no-op relink) or
	# race on writing the shared .so during "make install". A suite run on its own
	# still builds and installs.
	if [ -z "${PGC_SKIP_BUILD:-}" ]; then
		echo "-- building"
		make -C "$PGC_SRCDIR" PG_CONFIG="$PGC_PG_CONFIG" >/dev/null
		echo "-- installing"
		make -C "$PGC_SRCDIR" install PG_CONFIG="$PGC_PG_CONFIG" >/dev/null
	fi

	# initdb and pg_ctl cannot run as root; use postgres when we are root.
	if [ "$(id -u)" = "0" ]; then
		PGC_RUNPG=(runuser -u postgres --)
		chown -R postgres "$PGC_WORKDIR"
		chmod 777 "$PGC_WORKDIR" "$PGC_SQLDIR"
	else
		PGC_RUNPG=(env)
	fi

	trap pgc_teardown EXIT

	echo "-- initdb"
	pgc_pg "initdb -D '$PGC_PGDATA' -A trust" >/dev/null 2>&1
	{
		echo "port=$PGC_PORT"
		echo "listen_addresses='127.0.0.1'"
		echo "shared_preload_libraries='pgcolumnar'"
		# Deterministic text output so heap and columnar hashes match.
		echo "extra_float_digits=3"
		echo "timezone='UTC'"
		echo "datestyle='ISO, MDY'"
		echo "bytea_output='hex'"
		# Keep planner honest but let small tables use the custom scan.
		echo "max_parallel_workers_per_gather=0"
		# The unique-insert lock bucket count is fixed at server start (it is part
		# of the advisory lock tag, so backends must agree on it). A large prime
		# keeps unrelated keys out of the same bucket in unique_conc.
		echo "pgcolumnar.unique_lock_buckets=100003"
	} | pgc_pg "cat >> '$PGC_PGDATA/postgresql.conf'"

	# Start, retrying a few times: under rapid cluster churn (the version matrix
	# runs many throwaway clusters back to back) a start can transiently fail to
	# bind or acquire resources before the previous cluster is fully gone.
	#
	# The retry must also not hand this suite someone else's cluster. pg_ctl -w
	# only proves that *something* answers on the port, so if another suite's
	# postmaster already owns it, ours failed to bind while pg_ctl reported
	# success. Every statement would then run against that cluster: its log grows
	# a stray "database already exists" and this suite's own objects are invisible.
	# So the server answering on PGC_PORT must identify itself as ours before the
	# suite proceeds, and if it never does, the suite fails rather than guessing.
	echo "-- start"
	{
		local _a _i _dd _started

		_started=0
		for _a in 1 2 3 4 5 6 7 8; do
			_dd=""
			if pgc_pg "pg_ctl -D '$PGC_PGDATA' -l '$PGC_LOGFILE' start -w" >/dev/null 2>&1; then
				if pgc_cluster_is_ours; then
					_started=1
					break
				fi
				_dd="$(pgc_cluster_datadir)"
			fi
			if [ -n "$_dd" ]; then
				echo "-- port $PGC_PORT serves $_dd, not ours; retrying on a fresh port"
			else
				echo "-- start attempt $_a failed; retrying on a fresh port"
			fi
			# Only ever stops our own data directory, so a squatter is never touched.
			pgc_pg "pg_ctl -D '$PGC_PGDATA' stop -m immediate -w" >/dev/null 2>&1 || true
			# Prefer a port nothing is already listening on, so collisions are
			# avoided rather than merely detected afterwards.
			for _i in 1 2 3 4 5 6 7 8 9 10; do
				PGC_PORT=$(( 2048 + (PGC_PORT + 1 + RANDOM % 40000) % 60000 ))
				if pgc_port_free "$PGC_PORT"; then
					break
				fi
			done
			pgc_pg "sed -i 's/^port=.*/port=$PGC_PORT/' '$PGC_PGDATA/postgresql.conf'"
			sleep 1
		done

		if [ "$_started" != "1" ]; then
			echo "FATAL: no cluster of our own on port $PGC_PORT after $_a attempts" >&2
			echo "       (refusing to run against a cluster this suite does not own)" >&2
			exit 1
		fi
	}
	# The cluster is up, connectable, confirmed ours, and was initdb'd minutes ago
	# into a private mktemp directory. So PGC_DB cannot legitimately already
	# exist, and there is nothing here to retry: create it once, and treat
	# anything else as the problem it is.
	#
	# This used to loop ten times, creating the database and then failing to
	# notice it had. The check asked psql_admin, which does not pass -At, so a
	# one-row answer came back as a bordered table and "tr -dc 0-9" reduced
	# "(1 row)" along with the value to "11" -- never equal to "1". The loop
	# therefore always ran to its limit, and every suite emitted nine
	# ERROR: database "regress" already exists into the server log on every run,
	# passing or failing.
	#
	# That noise is why a genuine failure was twice read as port contention, by
	# two different people on the same day: a red result whose log is a wall of
	# "already exists" looks exactly like a suite that landed on someone else's
	# cluster. Removing the noise is most of the value here; failing loudly on
	# the impossible case is the rest.
	{
		local _exists

		_exists="$(psql_admin_scalar "SELECT count(*) FROM pg_database WHERE datname = '$PGC_DB';")"
		case "$_exists" in
			0)
				if ! psql_admin "CREATE DATABASE $PGC_DB;" >/dev/null 2>&1; then
					echo "FATAL: could not create database $PGC_DB on our own cluster" >&2
					exit 1
				fi
				;;
			1)
				echo "FATAL: database $PGC_DB already exists on a cluster this suite" >&2
				echo "       just created from a fresh initdb in $PGC_PGDATA." >&2
				echo "       That means the server on port $PGC_PORT is not the one we" >&2
				echo "       started, so nothing this suite reports would be about the" >&2
				echo "       build under test." >&2
				exit 1
				;;
			*)
				echo "FATAL: could not determine whether $PGC_DB exists (got '$_exists')" >&2
				exit 1
				;;
		esac
	}
	psql_run "CREATE EXTENSION pgcolumnar;" >/dev/null
}

pgc_teardown() {
	pgc_pg "pg_ctl -D '$PGC_PGDATA' stop -m immediate -w" >/dev/null 2>&1 || true
	rm -rf "$PGC_WORKDIR"
}

# Run a command as the postgres OS user (for initdb/pg_ctl).
pgc_pg() {
	"${PGC_RUNPG[@]}" env PATH="$PGC_BINDIR:$PATH" bash -lc "$1"
}

# ---- SQL helpers (run as root over TCP, trust auth) ------------------------

PGC_PSQL_BASE() {
	echo "psql -h 127.0.0.1 -p $PGC_PORT -U postgres"
}

# Run a statement against the test database, stop on error.
psql_run() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -v ON_ERROR_STOP=1 -q -c "$1"
}

# Run a statement against the maintenance database (for CREATE DATABASE etc.).
psql_admin() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d postgres -v ON_ERROR_STOP=1 -q -c "$1"
}

# Scalar form of psql_admin. Separate because psql_admin is used for statements
# and deliberately keeps psql's ordinary output; -At here means a caller reading
# a single value gets the value and not a bordered table with "(1 row)" under it,
# which is the mistake that made the cluster setup retry ten times.
psql_admin_scalar() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d postgres -At -c "$1" 2>/dev/null
}

# Scalar query: echo a single value (empty on error).
q() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$1" 2>/dev/null || true
}

# Run a SQL file, returning At output.
psql_file() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -f "$1" 2>/dev/null || true
}

# ---- assertions ------------------------------------------------------------

check() {
	local name="$1" got="$2" want="$3"
	PGC_CHECKS=$((PGC_CHECKS + 1))
	if [ "$got" = "$want" ]; then
		echo "PASS  $name"
	else
		echo "FAIL  $name: got [$got] want [$want]"
		PGC_FAIL=1
	fi
}

# Is this query's plan the columnar custom scan?
#
# For a check that reads a counter out of EXPLAIN and asserts on it. Those
# counters exist only on this node, so if the planner stops choosing it the read
# returns nothing and the check fails describing skipping, or bloom, or
# clustering -- anything except the plan change that actually happened.
#
# "Columnar Projected Columns" is the node's own marker: no other node reports
# it, and the vectorized aggregate node reports "Columnar Vectorized Aggregates"
# instead. A positive grep for the marker is deliberately not an absence test --
# a plan that fell back to a sequential scan has no Columnar lines to be absent,
# so an absence test would pass for exactly the case worth catching.
#
# EXPLAIN without ANALYZE is enough: the line comes from the plan rather than the
# run, so the assertion costs a plan and does not execute the query.
pgc_is_columnar_scan() {	# query -> yes|no
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "EXPLAIN (COSTS OFF) $1" 2>/dev/null \
		| grep -q 'Columnar Projected Columns' && echo yes || echo no
}

# Order-independent set hash of an arbitrary query's result. The row is cast to
# text as a whole composite so any column list works. No single quotes are used
# in the wrapper (dollar-quoting + chr(10)) so the inner query may contain its
# own quotes freely.
pgc_set_hash() {
	local query="$1" out res
	out="$PGC_SQLDIR/h.$$.$RANDOM.sql"
	cat > "$out" <<SQL
SELECT coalesce(md5(string_agg(t, chr(10) ORDER BY t)), \$e\$EMPTY\$e\$)
FROM (SELECT _row::text AS t FROM ( $query ) _row) _s;
SQL
	res="$(psql_file "$out")"
	rm -f "$out"
	# A blank result means the query errored or the server is gone; a genuinely
	# empty result set hashes to EMPTY. Return a value unique to this call, so
	# two failing queries can never compare equal and pass the check vacuously.
	# The counter lives in a file because each call runs in its own subshell, and
	# $$/$RANDOM are not reliably distinct between siblings on every bash.
	if [ -z "$res" ]; then
		local seq
		seq=$(( $(cat "$PGC_WORKDIR/.query_error_seq" 2>/dev/null || echo 0) + 1 ))
		echo "$seq" > "$PGC_WORKDIR/.query_error_seq"
		res="QUERY_ERROR.$seq"
	fi
	printf '%s\n' "$res"
}

# diff_query LABEL "QUERY with %T placeholder for the table name"
# Runs QUERY against t_heap and t_col and asserts identical result sets.
diff_query() {
	local label="$1" tmpl="$2"
	local hq hc
	hq="$(pgc_set_hash "${tmpl//%T/t_heap}")"
	hc="$(pgc_set_hash "${tmpl//%T/t_col}")"
	# A blank result means the query errored; surface it as a distinct value.
	[ -z "$hq" ] && hq="HEAP_ERROR"
	[ -z "$hc" ] && hc="COL_ERROR"
	check "$label" "$hc" "$hq"
}

# ---- pair construction -----------------------------------------------------

# make_pair "COLUMN DEFS" ["WITH options for columnar"]
# Creates t_heap (heap) and t_col (columnar) with the same schema.
make_pair() {
	local defs="$1"
	psql_run "DROP TABLE IF EXISTS t_heap; DROP TABLE IF EXISTS t_col;"
	psql_run "CREATE TABLE t_heap ($defs) USING heap;"
	psql_run "CREATE TABLE t_col  ($defs) USING pgcolumnar;"
}

# load_pair "INSERT SELECT body" : insert identical rows into both. The body is
# everything after INSERT INTO <t>, e.g. "SELECT g, g::text FROM generate_series(1,10) g".
# Data is generated once into heap, then copied to columnar, so both hold
# byte-identical logical contents regardless of any volatile generators.
load_pair() {
	local body="$1"
	psql_run "INSERT INTO t_heap $body;"
	psql_run "INSERT INTO t_col SELECT * FROM t_heap;"
}

# Storage id for a columnar relation by name.
storage_id_of() {
	q "SELECT pgcolumnar.get_storage_id('$1');"
}

# Number of row groups physically written for a columnar relation (default
# t_col). The row group is the native write unit and honors stripe_row_limit.
stripe_count() {
	local rel="${1:-t_col}"
	q "SELECT count(*) FROM pgcolumnar.row_group
	   WHERE storage_id = pgcolumnar.get_storage_id('$rel');"
}

# Number of vectors written for a columnar relation (default t_col). The vector
# is the unit of encoding and of min/max skipping and honors chunk_group_row_limit;
# counted as one per-vector zone map for column 0 across all row groups.
chunk_group_count() {
	local rel="${1:-t_col}"
	q "SELECT count(*) FROM pgcolumnar.zone_map
	   WHERE storage_id = pgcolumnar.get_storage_id('$rel')
	     AND vector_index >= 0 AND column_index = 0;"
}

# ---- summary ---------------------------------------------------------------

pgc_summary() {
	echo
	echo "checks run: $PGC_CHECKS"
	if [ "$PGC_FAIL" = "0" ]; then
		echo "$(basename "$0"): PASSED"
	else
		echo "$(basename "$0"): FAILED"
		# A source-shape suite (wal_envelope, decode_interrupts) never calls
		# pgc_setup, so there is no cluster and no log. Without this guard the
		# summary dies on an unset PGC_LOGFILE under `set -u` and the suite
		# reports "unbound variable" instead of which check failed.
		if [ -n "${PGC_LOGFILE:-}" ]; then
			echo "---- server log tail ----"
			pgc_pg "tail -40 '$PGC_LOGFILE'" 2>/dev/null || true
		fi
	fi
	exit $PGC_FAIL
}
