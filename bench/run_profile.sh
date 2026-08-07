#!/usr/bin/env bash
#
# pgColumnar profiling harness.
#
# Attaches a sampling profiler to a running backend for each of a few query
# shapes and reports where the time actually goes, so a micro-optimisation is
# aimed at a measured hot path rather than a guessed one.
#
# The shapes are the ones the benchmark harnesses found interesting rather than
# an arbitrary set:
#
#   decode      a text predicate, which cannot be pushed down (#426), so every
#               value is decoded. The purest read-path profile available.
#   filtered    an aggregate over a min/max-skippable range. This is the shape
#               that does not get faster with parallel workers, so its profile
#               is where any explanation has to come from.
#   project     a wide row-returning scan, which never receives a parallel plan.
#   ingest      the columnar write path, which is 3.6x slower than heap on text
#               (#445) and is the largest single number in the benchmark set.
#
# Usage:
#   bench/run_profile.sh [PG_CONFIG]
#
# Environment:
#   PROFILE_SCALE   rows in the fixture (default 20000000)
#   PROFILE_SECS    sample window per shape, seconds (default 8)
#   PROFILE_SHAPES  space-separated subset of: decode filtered project ingest
#   PROFILE_PORT    cluster port (default 55996)
#
# Run as a user that may "runuser -u postgres" (e.g. root), like the other
# harnesses that install: the install target is a root-owned prefix.
#
# Written fresh for pgColumnar.

set -uo pipefail

PG_CONFIG="${1:-/usr/local/pg18n/bin/pg_config}"
BINDIR="$("$PG_CONFIG" --bindir)"
PORT="${PROFILE_PORT:-55996}"
SCALE="${PROFILE_SCALE:-20000000}"
SECS="${PROFILE_SECS:-8}"
SHAPES="${PROFILE_SHAPES:-decode filtered project ingest}"
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d /tmp/pgcolumnar-profile.XXXXXX)"
PGDATA="$WORKDIR/data"

echo "== pgColumnar profile =="
echo "PG_CONFIG=$PG_CONFIG  ($("$PG_CONFIG" --version))"
echo "scale=$SCALE rows  window=${SECS}s  shapes: $SHAPES"

# ---- can we profile at all, and with what event? ---------------------------
#
# This is asserted BEFORE any fixture is built, because the failure is silent in
# the worst way: perf writes a zero-sized perf.data, `perf report` renders an
# empty profile without complaint, and an empty profile looks exactly like a
# finding ("nothing is hot"). Half an hour of fixture loading would be spent
# first.
#
# Two independent things can go wrong, and they need different answers:
#
#   no hardware PMU  -- a virtual machine commonly exposes none. Then
#                       /sys/bus/event_source/devices has no 'cpu' entry and any
#                       PRECISE event (the ':ppp' perf appends by default) cannot
#                       be opened at all. A software event still can.
#   no frame pointers -- PostgreSQL builds with -g -O2 and does NOT pass
#                       -fno-omit-frame-pointer, so frame-pointer unwinding
#                       yields truncated stacks. DWARF unwinding needs
#                       .debug_info, which the same build does keep.
#
# So both are probed and reported rather than assumed, and the event actually
# used is printed with the profile: a profile whose event is unstated cannot be
# compared with another one.
command -v perf >/dev/null || { echo "FATAL: perf is not installed"; exit 1; }

if [ -e /sys/bus/event_source/devices/cpu/type ]; then
	PERF_EVENT="cycles"
	PMU="hardware PMU present"
else
	PERF_EVENT="cpu-clock"
	PMU="no hardware PMU (virtualised); precise events unavailable"
fi

# Prove the chosen event opens, rather than trusting the inference above. Note
# perf's stderr is NOT redirected anywhere in this script: its diagnostics are
# the only explanation an empty profile ever gets.
if ! perf stat -e "$PERF_EVENT" true >/dev/null 2>"$WORKDIR/evprobe.err"; then
	echo "-- $PERF_EVENT unavailable, falling back to cpu-clock"
	cat "$WORKDIR/evprobe.err"
	PERF_EVENT="cpu-clock"
	perf stat -e "$PERF_EVENT" true >/dev/null || {
		echo "FATAL: no usable perf event; profiling would report an empty profile as data"
		exit 1; }
fi

CFLAGS="$("$PG_CONFIG" --cflags)"
case "$CFLAGS" in
	*-fno-omit-frame-pointer*) UNWIND="fp";      UNWIND_WHY="frame pointers present" ;;
	*)                         UNWIND="dwarf,8192"; UNWIND_WHY="no frame pointers; DWARF unwinding" ;;
esac

echo "-- profiler: perf, event=$PERF_EVENT ($PMU)"
echo "-- unwind:   $UNWIND ($UNWIND_WHY)"

# ---- build, install, and start a throwaway cluster -------------------------
echo "-- building"
make -C "$SRCDIR" PG_CONFIG="$PG_CONFIG" clean >/dev/null 2>&1 || true
make -C "$SRCDIR" PG_CONFIG="$PG_CONFIG" >/dev/null || { echo "FATAL: build"; exit 1; }
make -C "$SRCDIR" install PG_CONFIG="$PG_CONFIG" >/dev/null || { echo "FATAL: install"; exit 1; }

if [ "$(id -u)" = "0" ]; then
	RUNPG=(runuser -u postgres --)
	chown -R postgres "$WORKDIR"
	chmod 777 "$WORKDIR"
else
	RUNPG=(env)
fi
run_pg() { "${RUNPG[@]}" env PATH="$BINDIR:$PATH" bash -lc "$1"; }

cleanup() {
	run_pg "pg_ctl -D '$PGDATA' stop -m immediate -w" >/dev/null 2>&1 || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "-- initdb and start"
run_pg "initdb -D '$PGDATA' -A trust --locale=C" >"$WORKDIR/initdb.log" 2>&1 \
	|| { tail -5 "$WORKDIR/initdb.log"; echo "FATAL: initdb"; exit 1; }
{
	echo "port=$PORT"
	echo "shared_preload_libraries='pgcolumnar'"
	echo "shared_buffers=1GB"
	echo "work_mem=64MB"
	echo "max_wal_size=8GB"
	# Serial on purpose. A profile split across workers attributes each frame to
	# whichever process happened to run it, and the leader's profile then omits
	# most of the work. Profile one backend, tune, then re-measure in parallel.
	echo "max_parallel_workers_per_gather=0"
} | run_pg "cat >> '$PGDATA/postgresql.conf'"
run_pg "pg_ctl -D '$PGDATA' -l '$WORKDIR/server.log' -w start" >/dev/null 2>&1 \
	|| { tail -10 "$WORKDIR/server.log"; echo "FATAL: start"; exit 1; }
run_pg "createdb -p $PORT prof" >/dev/null 2>&1

# Every psql goes through run_pg, as the other harnesses do. Under sudo, initdb
# ran as postgres, so postgres is the only superuser role; a psql invoked
# directly connects as root and is refused with `role "root" does not exist`.
#
# SQL is passed by FILE rather than inline. Wrapping a -c argument inside
# run_pg's own quoted string nests three levels of quoting, which is how a query
# silently becomes a different query.
PSQL="psql -p $PORT -d prof -X -q -v ON_ERROR_STOP=1"
sql_file() { printf '%s\n' "$1" > "$WORKDIR/q.sql"; chmod 644 "$WORKDIR/q.sql"; }
q()       { sql_file "$1"; run_pg "$PSQL -At -f '$WORKDIR/q.sql'"; }
sql_run() { sql_file "$1"; run_pg "$PSQL -f '$WORKDIR/q.sql'"; }

echo "-- loading $SCALE rows"
sql_run "CREATE EXTENSION pgcolumnar;
	CREATE TABLE p (id bigint, k int, v numeric(12,2), t text) USING pgcolumnar;
	INSERT INTO p SELECT g, g % 1000, (g % 997)/7.0, md5(g::text)
		FROM generate_series(1, $SCALE) g;
	ANALYZE p;" >/dev/null || { echo "FATAL: fixture"; exit 1; }
echo "   table: $(q "SELECT pg_size_pretty(pg_table_size('p'))")"

# ---- one profiled shape ----------------------------------------------------
#
# Three things here exist because of one bug, and it is worth stating because the
# harness reported it as four clean profiles.
#
# `kill` on the psql client does NOT stop the backend: the server keeps executing
# the DO loop until it next tries to write to a gone client, which a CPU-bound
# loop may not do for a long time. The first shape's backend therefore survived
# into the second shape, whose pid lookup matched on a generic `%LOOP%` and found
# it. All four shapes profiled the FIRST query. Every guard passed -- a backend
# was running, and each profile had ~6000 samples -- because none of them asked
# the only question that mattered: is this backend running the shape I asked for.
#
# So: the loop is time-bounded and expires on its own, the backend is terminated
# server-side rather than the client killed, the lookup matches a marker unique to
# this shape and this run, and the pid is asserted to differ from the last one.
PREV_PID=""

# Two counters, not one. #447 made a skip a status the harness owns, and #455 had
# to fix that again a layer down when a single value collided with something
# else; the lesson recorded from the pair was that one signal cannot be made
# collision-proof. So a defect and an underpowered run are counted separately and
# reported separately, and the exit code distinguishes them:
#
#   0  every requested shape produced a usable profile
#   1  at least one shape FAILED (pid collision, or a shape name that does not exist)
#   2  no shape failed, but at least one produced too few samples to attribute
#
# Without this a run in which every shape collided printed its FAIL lines, then
# "profile complete", and exited 0 -- the summary claiming success while nothing
# had been measured, which is the exact defect the rest of this script exists to
# prevent.
FAILED_SHAPES=""
THIN_SHAPES=""

profile_shape() {	# profile_shape <name> <sql>
	local name="$1" sql="$2" pid="" i st samples marker deadline

	echo
	echo "=============== $name ==============="
	printf '%s\n' "$sql" | sed 's/^/  /'

	# Unique per shape AND per run, so a leftover from an earlier invocation
	# cannot be matched either.
	marker="PROFILEMARK_${name}_$$"

	# Self-limiting: the loop stops a few seconds after the sample window even if
	# every cleanup below fails, so nothing can survive into the next shape.
	deadline=$(( SECS + 5 ))
	cat > "$WORKDIR/loop_$name.sql" <<SQLEOF
DO \$\$
DECLARE deadline timestamptz := clock_timestamp() + interval '$deadline seconds';
BEGIN
	/* $marker */
	WHILE clock_timestamp() < deadline LOOP
		$sql;
	END LOOP;
END \$\$;
SQLEOF
	chmod 644 "$WORKDIR/loop_$name.sql"
	run_pg "$PSQL -f '$WORKDIR/loop_$name.sql'" >/dev/null 2>&1 &
	local qpid=$!

	# Attach only to a backend confirmed ON-CPU *and* running this shape.
	for i in $(seq 1 120); do
		pid="$(q "SELECT pid FROM pg_stat_activity
		            WHERE state = 'active' AND query LIKE '%$marker%'
		              AND pid <> pg_backend_pid() LIMIT 1")"
		if [ -n "$pid" ]; then
			st="$(ps -o stat= -p "$pid" 2>/dev/null)"
			case "$st" in R*) break ;; esac
		fi
		sleep 0.25
	done
	if [ -z "$pid" ]; then
		echo "  FAIL: no backend running $marker appeared; nothing was profiled"
		FAILED_SHAPES="$FAILED_SHAPES $name"
		return
	fi

	# The assertion the earlier version lacked. Two shapes sharing a pid means the
	# previous backend never died and this profile is a copy of the previous one.
	if [ "$pid" = "$PREV_PID" ]; then
		echo "  FAIL: pid $pid already profiled for the previous shape."
		echo "        The earlier backend outlived its window, so this would"
		echo "        re-profile that query under this shape's name."
		FAILED_SHAPES="$FAILED_SHAPES $name"
		return
	fi
	PREV_PID="$pid"
	echo "  backend pid=$pid state=$(ps -o stat= -p "$pid" 2>/dev/null)"

	perf record -e "$PERF_EVENT" -F 999 --call-graph "$UNWIND" \
		-p "$pid" -o "$WORKDIR/$name.data" -- sleep "$SECS"
	chmod 644 "$WORKDIR/$name.data" 2>/dev/null

	# perf report renders an empty profile without complaint, so the sample count
	# is asserted before any percentage is believed.
	samples="$(perf report -i "$WORKDIR/$name.data" --stats 2>/dev/null \
		| awk '/SAMPLE events/ { print $3; exit }')"
	samples="${samples:-0}"
	echo "  samples: $samples"
	if [ "$samples" -lt 200 ]; then
		echo "  THIN: only $samples samples; too few to attribute. Raise PROFILE_SECS"
		echo "        or PROFILE_SCALE rather than reading the percentages below."
		THIN_SHAPES="$THIN_SHAPES $name"
	else
		echo
		echo "  -- self time"
		perf report -i "$WORKDIR/$name.data" --stdio --no-children -g none \
			--percent-limit 1.5 2>/dev/null | grep -vE '^#|^$' | head -12 | sed 's/^/  /'

		echo
		echo "  -- callers"
		perf report -i "$WORKDIR/$name.data" --stdio -g graph,3,caller \
			--percent-limit 4 2>/dev/null | grep -E 'columnar|fsst|decode|encode' \
			| head -8 | sed 's/^/  /'
	fi

	# Terminate the BACKEND, not the client, and wait for it to actually go.
	q "SELECT pg_terminate_backend($pid)" >/dev/null 2>&1
	for i in $(seq 1 40); do
		[ -z "$(q "SELECT 1 FROM pg_stat_activity WHERE pid = $pid")" ] && break
		sleep 0.25
	done
	kill "$qpid" 2>/dev/null
	wait "$qpid" 2>/dev/null
}

for shape in $SHAPES; do
	case "$shape" in
	decode)
		profile_shape decode "PERFORM count(*) FROM p WHERE t LIKE '%abc%'" ;;
	filtered)
		profile_shape filtered "PERFORM sum(v) FROM p WHERE k BETWEEN 100 AND 140" ;;
	project)
		profile_shape project "PERFORM id, k, v FROM p WHERE k BETWEEN 100 AND 140" ;;
	ingest)
		sql_run "CREATE TABLE pw (id bigint, t text) USING pgcolumnar;" >/dev/null 2>&1
		profile_shape ingest "INSERT INTO pw SELECT g, md5(g::text) FROM generate_series(1,200000) g" ;;
	*)
		echo "FAIL: unknown shape '$shape'"
		echo "      valid: decode filtered project ingest"
		FAILED_SHAPES="$FAILED_SHAPES $shape"
		;;
	esac
done

echo
echo "Event and unwind method are printed above and belong with any number taken"
echo "from this run: a percentage is only comparable against another profile that"
echo "sampled the same way."
echo

if [ -n "$FAILED_SHAPES" ]; then
	echo "== profile FAILED =="
	echo "   no usable profile for:$FAILED_SHAPES"
	[ -n "$THIN_SHAPES" ] && echo "   too few samples for:$THIN_SHAPES"
	exit 1
fi
if [ -n "$THIN_SHAPES" ]; then
	echo "== profile INCOMPLETE =="
	echo "   too few samples to attribute:$THIN_SHAPES"
	echo "   Raise PROFILE_SECS or PROFILE_SCALE and re-run those shapes."
	exit 2
fi
echo "== profile complete =="
