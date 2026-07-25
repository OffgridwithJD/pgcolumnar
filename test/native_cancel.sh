#!/usr/bin/env bash
#
# pgColumnar scan cancellation (interrupt handling in the read path).
#
# The executor checks for interrupts once per tuple it receives, which is no help
# while a scan is doing work without producing a tuple. The expensive case is
# loading a row group: columnar_native_load_group() reads and decodes every
# column chunk of the group before the row loop can iterate once, and a vector
# holds up to pgcolumnar.chunk_group_row_limit values, which is user-settable and
# unbounded. Without interrupt checks inside that load, statement_timeout,
# pg_cancel_backend() and a standby's recovery conflict all wait for the whole
# decode.
#
# The check here is self-calibrating rather than a fixed millisecond threshold,
# so it means the same thing on fast and slow hardware: time an uninterrupted
# load, then time how long a deliberately short statement_timeout takes to fire
# on the same query. With interrupt checks in the decode path the timeout fires
# early in the load; without them it fires only after the load completes, so the
# two timings converge. Asserting the cancel is comfortably under half the full
# load distinguishes the two without depending on absolute speed.
#
# Usage:  test/native_cancel.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=${PGC_CANCEL_ROWS:-8000000}

# One row group, one vector: the whole table decodes in a single load, which is
# the shape that makes the uninterruptible window long enough to measure.
psql_run "SET pgcolumnar.stripe_row_limit = $ROWS;
          SET pgcolumnar.chunk_group_row_limit = $ROWS;
          CREATE TABLE cancel_t (id bigint, v bigint) USING pgcolumnar;
          INSERT INTO cancel_t SELECT g, g * 7 FROM generate_series(1, $ROWS) g;"

check "one row group" "$(q 'SELECT count(*) FROM pgcolumnar.row_group;')" "1"

# Parallel workers would give the executor its own interrupt points and hide the
# thing under test, so the scan is kept serial.
ms_for() {
	local start end
	start=$(date +%s%N)
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "SET max_parallel_workers_per_gather = 0; $1" \
		>"$PGC_WORKDIR/cancel.out" 2>&1
	end=$(date +%s%N)
	echo $(( (end - start) / 1000000 ))
}

# a full uninterrupted load, twice, so the second is warm like the timed one
ms_for "SELECT * FROM cancel_t LIMIT 1;" >/dev/null
full="$(ms_for "SELECT * FROM cancel_t LIMIT 1;")"

cancel="$(ms_for "SET statement_timeout = '50ms'; SELECT * FROM cancel_t LIMIT 1;")"
err="$(grep -oE 'ERROR:.*' "$PGC_WORKDIR/cancel.out" | head -1)"

echo "-- full load ${full} ms; cancel fired after ${cancel} ms"

check "the short timeout is what fired" \
	"$(case "$err" in *"canceling statement due to statement timeout"*) echo OK ;; *) echo "$err" ;; esac)" \
	"OK"

# Without interrupt checks in the load path the timeout cannot fire until the
# load finishes, so cancel and full converge. With them it fires during the load.
check "cancel arrives well before the load completes" \
	"$( [ "$cancel" -lt $(( full / 2 )) ] && echo yes || echo "no (cancel=${cancel}ms full=${full}ms)")" \
	"yes"

pgc_summary
