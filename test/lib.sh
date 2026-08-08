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

# The status pgc_summary uses for "ran no checks".
#
# NOT 2. #448 used 2 and that was wrong: 2 is a status suites already produce for
# unrelated reasons. bash exits 2 on a parse error in the suite file (verified),
# and the suites that run under `set -euo pipefail` -- smoke, phase2 through
# phase6, audit -- abort with whatever status the failing command returned, so a
# dead postmaster or a typo became "ran no checks" and every runner reported the
# major green. That is precisely the lie #447 was opened to remove, relocated one
# layer down.
#
# 66 is not produced by bash (1, 2, 126, 127, 128+n), by psql (1, 2, 3), or by
# make. It cannot be made collision-proof -- `set -e` propagates any status an
# aborting command returns -- so the runners ALSO require the SKIPPED line in the
# log before believing it. Two independent signals, because one was not enough.
PGC_EXIT_SKIPPED=66

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
	# One definition of the server major, for the suites that must branch on it.
	# A behavior that exists only from some major is core's, not this extension's,
	# and a check written against the newer one fails on the older ones for a
	# reason that is not a defect. Branch on this rather than deriving it again.
	PGC_MAJOR="$("$PGC_PG_CONFIG" --version | sed -E 's/^[^0-9]*([0-9]+).*/\1/')"
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
	#
	# Both steps are status-checked. lib.sh sets `set -uo pipefail` but not -e, so
	# an unchecked make that fails to compile does not stop the suite: it carries
	# on and runs every check against the PREVIOUSLY INSTALLED .so, then prints a
	# full PASS/FAIL report for code that does not exist. That is indistinguishable
	# from a real result, and it was caught only because someone fingerprinted the
	# installed .so and saw the same hash either side of a source change that could
	# not have produced it.
	if [ -z "${PGC_SKIP_BUILD:-}" ]; then
		echo "-- building"
		if ! make -C "$PGC_SRCDIR" PG_CONFIG="$PGC_PG_CONFIG" >/dev/null; then
			echo "FATAL: the build failed, so there is nothing new to test" >&2
			echo "       (refusing to report checks against the previously installed .so)" >&2
			exit 1
		fi
		echo "-- installing"
		if ! make -C "$PGC_SRCDIR" install PG_CONFIG="$PGC_PG_CONFIG" >/dev/null; then
			echo "FATAL: the install failed, so the .so under test is not the one just built" >&2
			echo "       (refusing to report checks against the previously installed .so)" >&2
			exit 1
		fi
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
		# Per-suite extra GUCs, set before the cluster starts (some, like
		# max_prepared_transactions, are PGC_POSTMASTER and cannot be changed
		# later). parallel_copy.sh uses this for 2PC capacity + worker slots.
		[ -n "${PGC_EXTRA_CONF:-}" ] && printf '%s\n' "$PGC_EXTRA_CONF"
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
				# Stays inside the main band. A retry that lands in the
				# ephemeral range can be stolen between this probe and the bind
				# below, which is the failure the retry exists to escape; one
				# that lands in the auxiliary band collides with the extra
				# clusters replication stands up. See portlib.sh.
				PGC_PORT=$(( PGC_PORT_LO + (PGC_PORT + 1 + RANDOM % 5000) % (PGC_PORT_HI - PGC_PORT_LO) ))
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

# ---- assertions that refuse to compare a measurement nobody took ------------
#
# check "$label" "$a" "$b" with both sides empty compares "" with "" and prints
# PASS (#418). Every way a measurement goes missing produces exactly that: a
# tool that is not installed, a grep that matched no line, a psql against a
# cluster that is down, a substitution that expanded to nothing. The suite then
# reports success for a number nobody has.
#
# This is not hypothetical and it is not rare. column_projection.sh piped its
# buffer count through bc, bc was absent on one machine, and both sides came
# back empty. It failed there only because one side happened to be non-empty.
# Two green checks were produced the same day that measured nothing at all.
#
# So: a measurement must look like a number before it is compared, and the
# failure says which side was not one. "got [] want []" is the message that cost
# the time.

# Integer or decimal, optional leading sign. Deliberately strict: an empty
# string, a psql error message, and "no" are all not numbers.
pgc_is_number() {	# $1 -> 0 when $1 is a number
	local v="${1#-}"
	v="${v#+}"
	case "$v" in
		'' | . | *[!0-9.]* | *.*.*) return 1 ;;
	esac
	return 0
}

# check_text LABEL GOT WANT -- check, with both sides required to be non-empty.
#
# check_num covers a measurement that is a NUMBER. Plenty of oracles are not: an
# md5 over an ordered result, a plan node name, a returned string. check_num
# rejects those outright -- it refuses two identical md5 hashes, because an md5
# is not a number -- so a suite comparing one has nothing to reach for and falls
# back to plain check, where "" equals "" and prints PASS (#418).
#
# That is the same defect, on the larger half: 35 places in this tree compare an
# md5(string_agg(...)) oracle, and every one of them is a down cluster or an
# errored query away from comparing nothing with nothing.
#
# Deliberately weaker than check_num: it asserts presence, not shape. A caller
# that knows the shape should say so, and native_index_projection.sh's agree()
# additionally requires 32 hex characters before it trusts either side.
check_text() {
	local name="$1" got="$2" want="$3"
	if [ -z "$got" ] || [ -z "$want" ]; then
		PGC_CHECKS=$((PGC_CHECKS + 1))
		PGC_FAIL=1
		echo "FAIL  $name: a side is empty, so nothing was compared:" \
			"got [$got] want [$want]"
		return 1
	fi
	check "$name" "$got" "$want"
}

# check_num LABEL GOT WANT -- check, with both sides required to be numbers.
check_num() {
	local name="$1" got="$2" want="$3"
	if ! pgc_is_number "$got" || ! pgc_is_number "$want"; then
		PGC_CHECKS=$((PGC_CHECKS + 1))
		PGC_FAIL=1
		echo "FAIL  $name: not a measurement, so nothing was compared:" \
			"got [$got] want [$want]"
		return 1
	fi
	check "$name" "$got" "$want"
}

# check_ratio LABEL A B MAX -- assert A divided by B is at most MAX.
#
# awk rather than bc, on purpose. bc is not part of a base install and its
# absence is what produced the empty measurement in the first place; awk is
# required by POSIX and is present wherever these suites can run at all.
#
# Zero on EITHER side is refused, not only the denominator.
#
# The first version of this checked only the denominator while this comment
# claimed both. The same commit changed column_projection.sh's bufs() to sum with
# awk, which returns 0 where it used to return the empty string, and that
# converted a failure mode this helper rejects into one it accepted: a projected
# read touching no buffers gives a ratio of 0.00, inside any bound, and passes.
# #418 moved rather than closed, inside the very check that started it.
#
# A zero numerator is "the thing we measured cost nothing", which is nearly
# always "the thing we measured did not happen". A call site that genuinely needs
# to permit zero should say so under its own name rather than get it by default.
check_ratio() {	# $1 label, $2 a, $3 b, $4 max
	local name="$1" a="$2" b="$3" max="$4" ratio

	if ! pgc_is_number "$a" || ! pgc_is_number "$b" || ! pgc_is_number "$max"; then
		PGC_CHECKS=$((PGC_CHECKS + 1))
		PGC_FAIL=1
		echo "FAIL  $name: not a measurement, so no ratio was formed:" \
			"a=[$a] b=[$b] max=[$max]"
		return 1
	fi
	if [ "$(awk -v x="$a" -v y="$b" 'BEGIN { print (x + 0 == 0 || y + 0 == 0) ? "yes" : "no" }')" = yes ]; then
		PGC_CHECKS=$((PGC_CHECKS + 1))
		PGC_FAIL=1
		echo "FAIL  $name: a side of the ratio is zero, so nothing was measured:" \
			"a=[$a] b=[$b]"
		return 1
	fi
	ratio="$(awk -v a="$a" -v b="$b" 'BEGIN { printf "%.2f", a / b }')"
	PGC_CHECKS=$((PGC_CHECKS + 1))
	if [ "$(awk -v r="$ratio" -v m="$max" 'BEGIN { print (r <= m) ? "yes" : "no" }')" = yes ]; then
		echo "PASS  $name (${ratio}x, bound ${max}x, from a=$a b=$b)"
	else
		echo "FAIL  $name: ${ratio}x exceeds the ${max}x bound (a=$a b=$b)"
		PGC_FAIL=1
	fi
}

# pgc_require_tools TOOL... -- one clear line at the top, rather than an empty
# string three checks later. A suite that needs a tool it does not have has not
# been skipped; it has been silently narrowed.
pgc_require_tools() {
	local t missing=""
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
	done
	if [ -n "$missing" ]; then
		echo "FAIL  the tools this suite measures with are missing:$missing"
		PGC_CHECKS=$((PGC_CHECKS + 1))
		PGC_FAIL=1
		return 1
	fi
	return 0
}

# A check whose subject is a wall-clock ratio.
#
# PGC_SKIP_TIMING exists because a shared runner cannot hold a ratio still, and
# a gate that reds for reasons unrelated to the change teaches its readers to
# discount red. Until now it was applied a whole suite at a time, which is too
# blunt: native_cancel and native_fetch_cache each hold one ratio and several
# correctness checks, so dropping the suite dropped the correctness with it
# (#254). native_fetch_cache was not dropped at all, and flaked CI instead:
#
#     FAIL  fetching from one big group is not far dearer than from ten small
#           ones: got [no (one=397ms ten=91ms)]
#
# So the ratio is skipped and the rest of the suite runs. A skip is announced
# rather than silent, and it is not counted as a pass, because a count that
# includes checks nobody ran is the thing this project keeps having to unlearn.
check_timing() {
	local name="$1" got="$2" want="$3"

	if [ "${PGC_SKIP_TIMING:-0}" = 1 ]; then
		echo "SKIP  $name (PGC_SKIP_TIMING: wall-clock ratio)"
		return 0
	fi
	check "$name" "$got" "$want"
}

# A ratio check whose subject is a wall-clock ratio.
#
# check_timing does this for a scalar; a ratio needs its own entry point because
# check_ratio takes a bound as well as two sides.
#
# It exists so that a suite never has to read PGC_SKIP_TIMING to decide whether
# to ASSERT. planner_choice_quality did read it, branched on it, and then called
# check_timing with two empty strings for got and want -- the "" vs "" compare
# check_text and check_num were added to forbid (#418). That was safe only while
# the suite's copy of the condition agreed with this file's, which is exactly the
# coupling this helper removes. Deciding whether to MEASURE is still the suite's
# business; deciding whether to assert is this file's.
check_ratio_timing() {  # check_ratio_timing <name> <a> <b> <bound>
	if [ "${PGC_SKIP_TIMING:-0}" = 1 ]; then
		echo "SKIP  $1 (PGC_SKIP_TIMING: wall-clock ratio)"
		return 0
	fi
	check_ratio "$@"
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

# A dependency this suite needs is not installed.
#
# This FAILS, and that is the point. A skip is a red that nobody has to look at,
# which is how fifteen suites came to report PASSED while asserting nothing, and
# how temporal.sh has been green on PG18 without btree_gist. A box that cannot run
# a suite is not a box that passed it.
#
# The opt-out is explicit and per-capability, so a developer without pyarrow can
# still work, and so the waiver is visible in the command rather than implied by
# silence:
#
#     PGC_ALLOW_MISSING_PYARROW=1 test/native_parquet_units.sh
#     PGC_ALLOW_MISSING=1         test/run_all_versions.sh
#
# Missing DEPENDENCY and not-applicable-to-this-MAJOR are different things and are
# deliberately not the same code path. PostgreSQL 15 has no WITHOUT OVERLAPS to
# test and no amount of installing will give it one, so those gates call
# pgc_summary directly and report SKIPPED. Nothing is broken there. Here it is.
pgc_skip() {  # pgc_skip <capability> <message>
	local cap allow_one
	cap="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
	allow_one="PGC_ALLOW_MISSING_$cap"
	if [ "${PGC_ALLOW_MISSING:-0}" = 1 ] || [ "${!allow_one:-0}" = 1 ]; then
		echo "SKIP  $2 (waived by $allow_one or PGC_ALLOW_MISSING)"
		pgc_summary
	fi
	PGC_CHECKS=$((PGC_CHECKS + 1))
	PGC_FAIL=1
	echo "FAIL  $2"
	echo "      A missing dependency is an environment defect, not a pass. Install"
	echo "      it, or set $allow_one=1 to run knowingly without this coverage."
	pgc_summary
}

# Three states, not two (#447).
#
# The verdict used to be a function of PGC_FAIL alone, and PGC_CHECKS was printed
# and never read. So a suite that asserted NOTHING printed PASSED and exited 0,
# indistinguishable from one that ran four hundred checks. Fifteen suites do that
# whenever pyarrow is absent, which is how an entire Parquet and Arrow surface,
# including both fuzzers, can leave a run with every line still saying PASSED.
#
# A suite that ran no checks did not pass. It is also not a failure: PostgreSQL 15
# genuinely has no WITHOUT OVERLAPS to test, and a developer box without an
# optional dependency is a supported configuration rather than a defect. Making
# those red is the "a red everyone knows to ignore is a red nobody reads" failure
# this tree keeps arguing against.
#
# So skipped is its own exit code. 0 passed, 1 failed, 2 ran nothing. The drivers
# count 2 separately and report how many suites actually ran, which is what #422
# did one level up for how many VERSIONS actually ran.
pgc_summary() {
	echo
	echo "checks run: $PGC_CHECKS"
	if [ "$PGC_FAIL" != "0" ]; then
		echo "$(basename "$0"): FAILED"
		# A source-shape suite (wal_envelope, decode_interrupts) never calls
		# pgc_setup, so there is no cluster and no log. Without this guard the
		# summary dies on an unset PGC_LOGFILE under `set -u` and the suite
		# reports "unbound variable" instead of which check failed.
		if [ -n "${PGC_LOGFILE:-}" ]; then
			echo "---- server log tail ----"
			pgc_pg "tail -40 '$PGC_LOGFILE'" 2>/dev/null || true
		fi
		exit 1
	fi
	if [ "$PGC_CHECKS" = "0" ]; then
		echo "$(basename "$0"): SKIPPED (ran no checks)"
		exit $PGC_EXIT_SKIPPED
	fi
	echo "$(basename "$0"): PASSED"
	exit 0
}
