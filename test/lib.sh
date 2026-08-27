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

# pgc_so_line
#		One line naming the shared library the suites are about to exercise.
#
# Printed on every run, not only when something looks wrong, because the failure
# it catches is invisible in a PASS/FAIL list: a suite reporting checks against a
# binary nobody just built. Three separate instances in one session -- a compile
# error the harness did not check (#508), a PGC_SKIP_BUILD run that skipped the
# INSTALL and exercised a guard-removed leftover, and objects from another major
# linked into a third -- all produced plausible results and all were one md5sum
# from being obvious.
#
# It also makes a red-on-change proof self-evidencing: two arms that report the
# same hash have proved nothing, whatever their check counts say.
pgc_so_line() {
	local so
	so="$("$PGC_PG_CONFIG" --pkglibdir)/pgcolumnar.so"
	if [ -r "$so" ]; then
		echo "-- .so: $(md5sum "$so" | cut -c1-12) $so"
	else
		echo "-- .so: NOT PRESENT at $so"
	fi
}

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

	# initdb and pg_ctl cannot run as root; use postgres when we are root.
	#
	# Settled BEFORE the build, and before the trap below, because pgc_teardown
	# reaches pg_ctl through pgc_pg, which expands PGC_RUNPG. Installing the trap
	# while that array is still unset would turn any early failure into an
	# unbound-variable error under `set -u` instead of a cleanup.
	if [ "$(id -u)" = "0" ]; then
		PGC_RUNPG=(runuser -u postgres --)
		chown -R postgres "$PGC_WORKDIR"
		chmod 777 "$PGC_WORKDIR" "$PGC_SQLDIR"
	else
		PGC_RUNPG=(env)
	fi

	# Armed here rather than after the build: the build below can exit, and
	# between mktemp above and this line there is nothing to remove the workdir.
	# Stopping a cluster that was never started is a no-op, so arming it early
	# costs nothing and covers every failure path after the directory exists.
	trap pgc_teardown EXIT

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
		# Objects from another major link but do not load (#536).
		_pgc_stamp="$PGC_SRCDIR/.pgc_built_for_major"
		_pgc_had="$(cat "$_pgc_stamp" 2>/dev/null | tr -dc '0-9')"
		_pgc_objs=no
		[ -n "$(find "$PGC_SRCDIR/src" -maxdepth 1 -name '*.o' -print -quit 2>/dev/null)" ] && _pgc_objs=yes
		if [ "$(pgc_build_needs_clean "$_pgc_had" "$PGC_MAJOR" "$_pgc_objs")" = yes ]; then
			pgc_build_stale_message "$_pgc_had" "$PGC_MAJOR"
			make -C "$PGC_SRCDIR" clean PG_CONFIG="$PGC_PG_CONFIG" >/dev/null 2>&1 || true
		fi
		echo "-- building"
		if ! make -C "$PGC_SRCDIR" PG_CONFIG="$PGC_PG_CONFIG" >/dev/null; then
			echo "FATAL: the build failed, so there is nothing new to test" >&2
			echo "       (refusing to report checks against the previously installed .so)" >&2
			exit 1
		fi
		# Stamped only after a build that succeeded. printf '%s\n', NOT '%s\\n':
		# the doubled backslash writes the four bytes 1 9 \ n, which only worked
		# because the reader strips non-digits. Caught in review, not by a test.
		pgc_write_build_stamp "$_pgc_stamp" "$PGC_MAJOR"
		echo "-- installing"
		if ! make -C "$PGC_SRCDIR" install PG_CONFIG="$PGC_PG_CONFIG" >/dev/null; then
			echo "FATAL: the install failed, so the .so under test is not the one just built" >&2
			echo "       (refusing to report checks against the previously installed .so)" >&2
			exit 1
		fi
	else
		# Named because the variable is not what it says. It reads as "skip the
		# build" and means "skip the build AND the install, and test whatever is
		# already installed" -- correct for the matrix, which installs once per
		# major before setting it, and a trap for a person who has just edited
		# source and run make by hand.
		echo "-- PGC_SKIP_BUILD=1: not building AND NOT INSTALLING;"
		echo "   whatever is already installed is what these checks measure"
	fi

	pgc_so_line

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
		local _a _i _dd _started _nforeign

		_started=0
		_nforeign=0
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
				_nforeign=$(( _nforeign + 1 ))
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
			# The reason FIRST, then the verdict. pg_ctl -l has been writing it
			# to this file since attempt one, and pgc_teardown removes the
			# workdir on exit, so a verdict without it is the last thing anyone
			# sees before the evidence is deleted (#537).
			pgc_start_log_report "${PGC_LOGFILE:-}"
			pgc_start_failure_message "$_a" "$PGC_PORT" "$_nforeign" >&2
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

# ---- reporting a failure that happened before any check ran (#537) ----------

# The events in a server log that mean "this was not a failed assertion", for the
# SUMMARY path.
#
# There are deliberately TWO patterns, not one, and an earlier version of this
# comment claimed they were one shared definition while the code had already
# diverged -- the exact defect #537 is about, committed in the fix for it. They
# are named functions so the divergence is visible and greppable rather than two
# literals in two places: pgc_fatal_pattern here, pgc_start_fatal_pattern below.
# Their reasons for differing are given at each.
#
# "could not load library" is the addition. Bare "FATAL:" deliberately is NOT in
# here, and the reason is measured rather than reasoned, because the first reason
# written here was wrong and did not survive being checked.
#
# What is true: a crash restart produces routine FATALs in TWO classes, and
# neither is a cause of anything. A PASSING run of native_backend_crash.sh leaves
# two lines of the first class; forcing a crash and then attempting twelve
# connections during the recovery window produces both:
#
#     5  FATAL:  the database system is not yet accepting connections
#     3  FATAL:  the database system is in recovery mode
#
# The second class is the one that matters for this decision, because its count
# scales with how many connections arrive during recovery rather than with
# anything about the failure. So the wallpaper bare FATAL would print is not
# bounded at the two lines the crash suite happens to show; a busier run prints
# as many as it raced. Matching them would put a consequence under "first fatal
# events" as though it were a cause, which is the exact defect #537 exists to
# fix. PANIC stays in the pattern because a PANIC is a cause.
#
# What is NOT true, and was the original justification here: that a cluster
# stopped with -m immediate logs a routine FATAL per live backend. Measured twice,
# independently, on two majors and two machines -- four backends held open on
# pg_sleep, then pg_ctl stop -m immediate:
#
#     PG18: 0 FATAL lines        PG17: 0 FATAL lines, before and after
#
# An immediate stop SIGQUITs them and they log nothing. Do not restore that
# reasoning. It is recorded here BECAUSE it is the intuitive answer and will
# otherwise be re-derived by whoever reads this next; it was written into this
# file once already as though it were a finding.
#
# The START path can afford a bare FATAL grep, and does one, because a cluster
# that never started has produced no routine FATALs to confuse it.
pgc_fatal_pattern() {
	printf '%s\n' 'AddressSanitizer|UndefinedBehaviorSanitizer|runtime error:|terminated by signal|PANIC:|could not load library'
}

# The same question for the START path, which can afford a bare FATAL where the
# summary path cannot. A cluster that never started has produced no routine
# FATALs -- the two routine classes both come from crash RECOVERY, which requires
# having started -- so here every FATAL is a candidate cause.
pgc_start_fatal_pattern() {
	printf '%s\n' 'FATAL:|PANIC:'
}

# What the server log says about a cluster that would not start.
#
# Takes the log path so it can be tested against a fixture without standing a
# cluster up. Prints the first FATAL lines with their line numbers, then a tail,
# and says so explicitly when it found neither -- silence here reads as "there
# was nothing to say", which was the whole complaint in #537.
pgc_start_log_report() {
	local _log="$1" _fatal _tail

	if [ -z "$_log" ] || [ ! -s "$_log" ]; then
		echo "---- server log: absent or empty at ${_log:-<unset>} ----" >&2
		return 0
	fi

	_fatal="$(grep -nE "$(pgc_start_fatal_pattern)" "$_log" 2>/dev/null | head -5 || true)"
	if [ -n "$_fatal" ]; then
		echo "---- why the cluster would not start ----" >&2
		printf '%s\n' "$_fatal" >&2
	else
		echo "---- no FATAL in the server log; its tail follows ----" >&2
	fi
	_tail="$(tail -20 "$_log" 2>/dev/null || true)"
	if [ -n "$_tail" ]; then
		echo "---- server log tail ($_log) ----" >&2
		printf '%s\n' "$_tail" >&2
	fi
	return 0
}

# The verdict, which must not assert a cause the code has not established.
#
# The third argument is HOW MANY attempts actually found another cluster's data
# directory on the port. A count rather than a flag, because a flag was sticky:
# set on any attempt and never cleared, so one squatter on attempt 1 followed by
# seven genuine start failures printed the squatter verdict for all eight. That
# is #537's own defect narrowed rather than removed, and it is reachable, since
# escaping a port collision is what the retry loop exists for.
#
# Three cases, and the mixed one is why this is not a branch on zero.
pgc_start_failure_message() {
	local _attempts="$1" _port="$2" _nforeign="$3"

	printf '%s\n' "FATAL: no cluster of our own on port $_port after $_attempts attempts"
	if [ "$_nforeign" = "0" ]; then
		printf '%s\n' "       (nothing was squatting: our own postmaster failed to start, and the"
		printf '%s\n' "        reason is in the server log reported above)"
	elif [ "$_nforeign" = "$_attempts" ]; then
		printf '%s\n' "       (a cluster this suite does not own held the port on every attempt;"
		printf '%s\n' "        refusing to use it)"
	else
		printf '%s\n' "       ($_nforeign of $_attempts attempts found a cluster this suite does not"
		printf '%s\n' "        own; the other $(( _attempts - _nforeign )) failed to start, and that"
		printf '%s\n' "        reason is in the server log reported above)"
	fi
}


# ---- an in-tree build must not reuse another major's objects (#536) ---------
#
# lib.sh builds in $PGC_SRCDIR with no clean and no record of which major the
# objects belong to. One suite against pg18a then pg19a in the same tree links
# the first run's objects into the second .so, which fails to load with
# "undefined symbol: get_relation_info_hook": every cluster start dies and the
# suite reports eight retries with no cause.
#
# The MATRIX is not exposed -- run_all_versions.sh cleans each per-major copy
# right after its cp -a. Measured, after #536 was filed claiming otherwise.
#
# Objects present with NO stamp are unknown provenance and must be cleaned: that
# is what a hand-run `make PG_CONFIG=...` leaves, which is how anyone debugging
# builds and how every gate script here builds.
pgc_build_needs_clean() {
	local have="${1:-}" want="${2:-}" objects="${3:-}"

	case "$want" in '' | *[!0-9]*) echo yes; return ;; esac
	[ "$objects" = yes ] || { echo no; return; }
	[ -z "$have" ] && { echo yes; return; }
	case "$have" in *[!0-9]*) echo yes; return ;; esac
	[ "$have" = "$want" ] && echo no || echo yes
}

# The stamp writer, as a function so a check can exercise THE WRITER rather
# than a copy of it. It was written inline as printf '%s\\n' -- a doubled
# backslash inside single quotes -- which emits the four bytes `1 9 \ n`. That
# passed unnoticed because the reader does tr -dc '0-9' and strips the junk; a
# direct comparison against the major failed. Found in review, not by a check.
pgc_write_build_stamp() {
	printf '%s\n' "${2:-}" > "${1:-/dev/null}" 2>/dev/null || true
}

# An absent stamp is not "built for PG?" -- that asserts a provenance the code
# never recorded, which is the defect #537 was filed about.
pgc_build_stale_message() {
	if [ -z "${1:-}" ]; then
		printf -- '-- the tree holds objects with no recorded major and this run wants PG%s; cleaning first (#536)\n' "${2:-?}"
	else
		printf -- '-- the tree was last built for PG%s and this run wants PG%s; cleaning first (#536)\n' "$1" "${2:-?}"
	fi
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
# Runs everywhere, including CI. For a ratio whose arms move together under
# load -- measured back to back in the same run, compared by minimum. If the
# ratio needs an idle machine to mean anything, use
# check_ratio_needs_quiet_machine instead and read why there.
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
# A wall-clock ratio that is only meaningful on an unloaded machine.
#
# THIS HELPER REMOVES THE CHECK FROM EVERY AUTOMATED GATE. Both .github/workflows/
# ci.yml and .github/workflows/nightly.yml set PGC_SKIP_TIMING, so a check written
# with it runs only when someone runs the suite by hand. That is correct for a
# ratio a shared runner can distort, and it is the whole cost of using it.
#
# USE IT when the ratio compares against an absolute or cross-run baseline, where
# a loaded machine can move one side and not the other.
#
# DO NOT USE IT when the two arms are measured back to back in the same run and
# compared by minimum. Both readings then move together under load, which is what
# makes that shape safe on shared hardware -- use check_ratio, which runs
# everywhere. test/cancel_decode.sh carries the worked argument for its own ratio
# and test/int8_agg_int128.sh is a second instance.
#
# The name says what the helper DOES rather than what it measures. It was
# check_ratio_timing, which read as "the helper for ratios of timings" -- so an
# author holding the safe shape picked it by matching units and lost the check in
# CI silently. Three suites had each derived the exemption for themselves in their
# own headers (bloom_sizing a size, native_fetch_bigcap buffers, cancel_decode a
# same-run ratio) and nothing said it here, where it is decided (#787).
check_ratio_needs_quiet_machine() {  # <name> <a> <b> <bound>
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

# pgc_seq_hash QUERY -> md5 over the rendered rows IN THE ORDER THE QUERY
# RETURNED THEM, or EMPTY for a genuinely empty result set.
#
# The sibling pgc_set_hash sorts the rendered rows before hashing them
# (string_agg(... ORDER BY t)). That is what makes it a SET comparison, and it is
# right for the ~150 diff_query sites that do not name an order. It is wrong for
# the ones that do: an ORDER BY the oracle cannot fail on is not an assertion.
# Measured on the oracle itself -- five rows forward and the same five reversed
# both hash to 2603e60e802d02d5370794d279cb522a, while a genuinely different row
# set does hash differently, so the set oracle is order-blind rather than broken.
#
# row_number() OVER () numbers the rows as they arrive from the subquery and
# string_agg then orders on that number, so what is hashed is the query's own
# output order. The sentinels are pgc_set_hash's, unchanged: a genuinely empty
# result hashes to EMPTY, and a query that errored returns a unique
# QUERY_ERROR.$seq so two failing queries can never compare equal and pass
# vacuously (#418).
pgc_seq_hash() {
	local query="$1" out res
	out="$PGC_SQLDIR/q.$$.$RANDOM.sql"
	cat > "$out" <<SQL
SELECT coalesce(md5(string_agg(t, chr(10) ORDER BY n)), \$e\$EMPTY\$e\$)
FROM (SELECT row_number() OVER () AS n, _row::text AS t
      FROM ( $query ) _row) _s;
SQL
	res="$(psql_file "$out")"
	rm -f "$out"
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

# diff_query_ordered LABEL "QUERY with %T placeholder for the table name"
# As diff_query, but the row ORDER is part of the assertion. Use this for any
# query that names an ORDER BY, and diff_query for everything else. Keeping the
# two apart is deliberate: most comparisons here want set semantics, and only a
# query that asks for an order can be wrong about one. test/selftest enforces the
# split so a new ordered site cannot quietly land on the order-blind oracle.
diff_query_ordered() {
	local label="$1" tmpl="$2"
	local hq hc
	hq="$(pgc_seq_hash "${tmpl//%T/t_heap}")"
	hc="$(pgc_seq_hash "${tmpl//%T/t_col}")"
	# A blank result means the query errored; surface it as a distinct value.
	[ -z "$hq" ] && hq="HEAP_ERROR"
	[ -z "$hc" ] && hc="COL_ERROR"
	check "$label" "$hc" "$hq"
}
# pgc_check_ordered_oracle
# The premise behind every diff_query_ordered call: the ordered oracle must be
# able to fail on row order, and the set oracle must deliberately not be. Run it
# once in any suite that uses diff_query_ordered. Without it those assertions
# could pass by construction, which is the failure this whole split is about --
# an assertion that cannot fail for the reason it names is not an assertion.
# Static checks cannot see this; it runs against the cluster under test.
pgc_check_ordered_oracle() {
	local fwd rev sfwd srev again
	fwd="$(pgc_seq_hash 'SELECT g FROM generate_series(1,5) g ORDER BY g')"
	rev="$(pgc_seq_hash 'SELECT g FROM generate_series(1,5) g ORDER BY g DESC')"
	again="$(pgc_seq_hash 'SELECT g FROM generate_series(1,5) g ORDER BY g')"
	sfwd="$(pgc_set_hash 'SELECT g FROM generate_series(1,5) g ORDER BY g')"
	srev="$(pgc_set_hash 'SELECT g FROM generate_series(1,5) g ORDER BY g DESC')"
	check "premise: the ordered oracle is order-sensitive" \
		"$([ "$fwd" != "$rev" ] && echo yes || echo no)" "yes"
	check "premise: the ordered oracle agrees with itself" \
		"$([ "$fwd" = "$again" ] && echo yes || echo no)" "yes"
	check "control: the set oracle is order-blind by design" \
		"$([ "$sfwd" = "$srev" ] && echo yes || echo no)" "yes"
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
			# The tail is the right thing to show when one statement failed and
			# the wrong thing after a crash. A crashing backend takes the
			# postmaster through "terminating any other active server processes"
			# and recovery for every subsequent check, so the cause sits at the
			# TOP of the log and the last 40 lines are its aftermath.
			#
			# Measured under the pg18_san build, with a deliberate heap overrun:
			# 67 AddressSanitizer reports in an 8,777-line log, the first at line
			# 12. The tail showed lines 8738-8777 and pgc_teardown then removed
			# the file, so a suite reported 123 failures with no way to find out
			# why -- the diagnosis existed, for a quarter of a second, 8,765 lines
			# above the only window anyone was shown.
			#
			# grep the whole file for the events that mean "this was not a failed
			# assertion", and print the first few with line numbers.
			_pgc_fatal="$(pgc_pg "grep -nE '$(pgc_fatal_pattern)' '$PGC_LOGFILE' | head -5" 2>/dev/null || true)"
			if [ -n "$_pgc_fatal" ]; then
				echo "---- first fatal events in the server log ----"
				printf '%s\n' "$_pgc_fatal"
				echo "(the tail below is what followed; the cause is above)"
			fi
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
