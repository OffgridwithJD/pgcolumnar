#!/usr/bin/env bash
#
# pgColumnar physical replication and standby redo (#241).
#
# recovery.sh covers crash redo in place, on the same data directory. This is the
# other half: pg_basebackup to a second cluster, stream a columnar workload, and
# assert the standby's tables match the primary after replay. Nothing before this
# stood up a replica; wal_envelope.sh only greps the C source for the envelope
# around the one direct XLogInsert.
#
# What this suite is really testing, stated precisely, because the issue that
# asked for it got the premise wrong:
#
#   Every WAL record this extension emits is a CORE record type. The data pages
#   go through log_newpage / log_newpage_buffer (RM_XLOG_ID) and the one direct
#   insert is XLogInsert(RM_SMGR_ID, XLOG_SMGR_TRUNCATE). There is no custom
#   resource manager, so redo is core's and a standby does NOT need this module
#   loaded to replay correctly. It needs the module to READ a columnar table,
#   because that requires the table access method handler, which is a different
#   thing from replaying the bytes.
#
# Scenario 3 tests exactly that distinction, and it is the one worth having: it
# is the standing WAL constraint (no new WAL semantics, replay must work on a
# stock binary) turned into an assertion instead of an argument.
#
# Usage:  test/replication.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

SB_DIR="$PGC_WORKDIR/standby"
SB_LOG="$PGC_WORKDIR/standby.log"

# The standby needs a port of its own, and PGC_PORT + 1 is the one choice that
# cannot work. run_all_versions.sh hands each suite a port by walking upward from
# a base, one per suite per major, so PGC_PORT + 1 is the NEXT suite's primary by
# construction. It passes standalone and fails in the matrix, which is exactly
# what it did: green on PG17 alone, red on PG18 inside the matrix.
#
# The matrix walks 40000 upward (portlib.sh), so this draws from below that range
# and still verifies the port is free rather than assuming a range is enough.
pick_sb_port() {
	local base p
	base=$(( 30000 + ($$ % 9000) ))
	for p in $(seq "$base" $((base + 300))); do
		if pgc_port_free "$p"; then
			echo "$p"
			return 0
		fi
	done
	return 1
}
SB_PORT="$(pick_sb_port)"
if [ -z "$SB_PORT" ]; then
	echo "FAIL  no free port for the standby"
	PGC_FAIL=1
	pgc_summary
fi
echo "-- primary port $PGC_PORT, standby port $SB_PORT"

# ---------------------------------------------------------------------------
# Standby lifecycle
# ---------------------------------------------------------------------------

sb_q() {   # query the STANDBY
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$SB_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$1" 2>/dev/null || true
}

sb_stop() {
	pgc_pg "pg_ctl -D '$SB_DIR' stop -m immediate -w" >/dev/null 2>&1 || true
}

# Start the standby and wait until it actually answers, rather than trusting
# pg_ctl -w.
#
# pg_ctl -w gives up after 60s by default and its exit status was being
# discarded, so under the full matrix -- six suites and their clusters on one box
# -- the standby sometimes had not reached a consistent state in time, and the
# suite carried on and reported twelve empty-result failures downstream. One
# unreachable standby should say so once, with its log, not cascade.
sb_start() {
	local i
	pgc_pg "pg_ctl -D '$SB_DIR' -l '$SB_LOG' -t 120 start -w" >/dev/null 2>&1
	for i in $(seq 1 120); do
		[ "$(sb_q 'SELECT 1')" = 1 ] && return 0
		sleep 0.5
	done
	echo "  standby did not accept connections; last 15 lines of its log:"
	pgc_pg "tail -15 '$SB_LOG'" 2>/dev/null | sed 's/^/    /'
	return 1
}

# Stop the standby before the ordinary teardown takes the primary away.
sb_teardown() { sb_stop; pgc_teardown; }
trap sb_teardown EXIT

# Wait until the standby has replayed at least the primary's current LSN.
# Polls rather than sleeping a fixed amount: a fixed sleep is either flaky or
# slow, and on a loaded box it is both.
sync_standby() {
	local target i replayed
	target="$(q "SELECT pg_current_wal_lsn()")"
	for i in $(seq 1 120); do
		replayed="$(sb_q "SELECT pg_last_wal_replay_lsn()")"
		if [ -n "$replayed" ] && [ -n "$target" ] && \
		   [ "$(sb_q "SELECT '$replayed'::pg_lsn >= '$target'::pg_lsn")" = t ]; then
			return 0
		fi
		sleep 0.5
	done
	return 1
}

# Order-independent content hash, computed the same way on either cluster, so a
# row-order difference is not read as data divergence.
hash_primary() { q "SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM $1 t"; }
hash_standby() { sb_q "SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM $1 t"; }

# ---------------------------------------------------------------------------
# Base backup
# ---------------------------------------------------------------------------

psql_run "CREATE TABLE r (id int, v text) USING pgcolumnar;
	INSERT INTO r SELECT g, 'row' || g FROM generate_series(1,20000) g;" >/dev/null 2>&1

echo "-- pg_basebackup"
pgc_pg "pg_basebackup -h 127.0.0.1 -p $PGC_PORT -U postgres -D '$SB_DIR' -R -X stream -c fast" \
	>/dev/null 2>&1
check "pg_basebackup produced a data directory" \
	"$(pgc_pg "test -f '$SB_DIR/PG_VERSION' && echo yes || echo no" 2>/dev/null | tr -d '[:space:]')" \
	"yes"

# The backup copies postgresql.conf, so the standby inherits
# shared_preload_libraries='pgcolumnar'. Only the port has to change.
pgc_pg "sed -i 's/^port=.*/port=$SB_PORT/' '$SB_DIR/postgresql.conf'" >/dev/null 2>&1
sb_start
check "the standby accepts connections" "$(sb_q 'SELECT 1')" "1"

# ---------------------------------------------------------------------------
# The controls. Without these the rest can pass while proving nothing.
# ---------------------------------------------------------------------------

# If this were somehow the primary, every comparison below would trivially agree.
check "the standby is in recovery" "$(sb_q 'SELECT pg_is_in_recovery()')" "t"

check "the standby is a different cluster from the primary" \
	"$([ "$(sb_q 'SHOW data_directory')" != "$(q 'SHOW data_directory')" ] && echo yes || echo no)" \
	"yes"

sync_standby
check "the base backup carried the initial rows" \
	"$(hash_standby r)" "$(hash_primary r)"

# Positive control: with replay paused, a change on the primary must NOT appear.
# This is the check that proves the comparison can fail. Everything after it is
# only meaningful because this one showed a difference is detectable.
sb_q "SELECT pg_wal_replay_pause()" >/dev/null
psql_run "INSERT INTO r SELECT g, 'paused' || g FROM generate_series(90001,90100) g;" >/dev/null 2>&1
sleep 1
check "with replay paused the standby does NOT see the new rows" \
	"$(sb_q "SELECT count(*) FROM r WHERE v LIKE 'paused%'")" "0"
sb_q "SELECT pg_wal_replay_resume()" >/dev/null
sync_standby
check "after resuming, the standby sees them" \
	"$(sb_q "SELECT count(*) FROM r WHERE v LIKE 'paused%'")" "100"

# ---------------------------------------------------------------------------
# Scenario 1: the ordinary write paths
# ---------------------------------------------------------------------------

psql_run "INSERT INTO r SELECT g, 'more' || g FROM generate_series(20001,40000) g;
	DELETE FROM r WHERE id % 7 = 0;
	UPDATE r SET v = v || '-u' WHERE id % 11 = 0;" >/dev/null 2>&1
sync_standby

check "insert, delete and update replay identically" \
	"$(hash_standby r)" "$(hash_primary r)"
check "and the row counts agree" \
	"$(sb_q 'SELECT count(*) FROM r')" "$(q 'SELECT count(*) FROM r')"

# ---------------------------------------------------------------------------
# Scenario 2: compaction, and the SMGR truncate redo the issue asked for
# ---------------------------------------------------------------------------

psql_run "SELECT pgcolumnar.vacuum('r');" >/dev/null 2>&1
sync_standby
check "vacuum replays identically" "$(hash_standby r)" "$(hash_primary r)"

psql_run "SELECT pgcolumnar.compact('r');" >/dev/null 2>&1
sync_standby
check "compact replays identically" "$(hash_standby r)" "$(hash_primary r)"

# ColumnarTruncateMainFork is the one direct XLogInsert in the tree
# (RM_SMGR_ID / XLOG_SMGR_TRUNCATE). wal_envelope.sh asserts the envelope around
# it by reading the source; nothing has ever executed the record, let alone
# replayed it.
#
# Getting it emitted at all is fiddly and the fixture is copied from
# native_truncate.sh rather than invented: end truncation is opt-in (GUC default
# off), and truncBlock comes from the highest LIVE row group, so a DELETE alone
# leaves the metadata in place and reclaims nothing. The trailing rows have to
# form their own row groups (small stripe and chunk limits) and then be freed by
# compact before there is any trailing region to drop.
#
# My first attempt at this used default limits and 60,000 rows, and truncate
# returned 0 every time; pg_waldump confirmed zero SMGR TRUNCATE records in the
# whole run. An assertion about replaying that record would have passed while the
# record was never written, so the primary-side precondition is asserted here
# before anything is claimed about the standby.
# One statement per call, deliberately. psql -c with several statements wraps
# them in one implicit transaction, and both set_options and compact need to be
# committed before the next step reads their effect; batching them was why the
# first version of this scenario silently reclaimed nothing.
psql_run "ALTER DATABASE $PGC_DB SET pgcolumnar.enable_end_truncation = on;" >/dev/null 2>&1
psql_run "DROP TABLE IF EXISTS t;" >/dev/null 2>&1
psql_run "CREATE TABLE t (id int, v text) USING pgcolumnar;" >/dev/null 2>&1
psql_run "SELECT pgcolumnar.set_options('t', stripe_row_limit => 1000, chunk_group_row_limit => 1000);" >/dev/null 2>&1
psql_run "INSERT INTO t SELECT g, md5(g::text) FROM generate_series(1,30000) g;" >/dev/null 2>&1
sync_standby

psql_run "DELETE FROM t WHERE id > 15000;" >/dev/null 2>&1
psql_run "SELECT pgcolumnar.compact('t');" >/dev/null 2>&1
pri_before="$(q "SELECT pg_relation_size('t')")"
trunc="$(q "SELECT pgcolumnar.truncate('t');")"

# Precondition, not decoration: if this is 0 the record was never emitted and
# every standby assertion below would pass vacuously.
check "the primary actually truncated (record was emitted)" \
	"$([ -n "$trunc" ] && [ "$trunc" -gt 0 ] && echo yes || echo "no (returned ${trunc:-empty})")" \
	"yes"

pri_after="$(q "SELECT pg_relation_size('t')")"
sync_standby
sb_after="$(sb_q "SELECT pg_relation_size('t')")"

check "the standby's main fork shrank to match the primary" \
	"$([ -n "$sb_after" ] && [ "$sb_after" = "$pri_after" ] && echo yes || echo "no (primary $pri_before->$pri_after, standby $sb_after)")" \
	"yes"
check "the truncate did not cost rows on the standby" \
	"$(sb_q 'SELECT count(*) FROM t')" "$(q 'SELECT count(*) FROM t')"
check "content still matches after the truncate record" \
	"$(hash_standby t)" "$(hash_primary t)"
check "the standby is still in recovery after the truncate record" \
	"$(sb_q 'SELECT pg_is_in_recovery()')" "t"

# ---------------------------------------------------------------------------
# Scenario 3: a standby WITHOUT the module still replays
#
# This is the claim the standing WAL constraint rests on: every record emitted is
# a core type, so a stock server replays them correctly and only needs the module
# to read the tables. If this ever fails, the extension has grown WAL semantics
# that a plain PostgreSQL cannot replay, which is the thing the project has
# refused to do.
# ---------------------------------------------------------------------------

psql_run "CREATE TABLE r2 (id int, v text) USING pgcolumnar;
	INSERT INTO r2 SELECT g, 'x' || g FROM generate_series(1,5000) g;" >/dev/null 2>&1

sb_stop
pgc_pg "sed -i \"s/^shared_preload_libraries=.*/shared_preload_libraries=''/\" '$SB_DIR/postgresql.conf'" \
	>/dev/null 2>&1
sb_start
check "a standby without pgcolumnar loaded still starts" "$(sb_q 'SELECT 1')" "1"
check "and it is not running the module" \
	"$(sb_q "SELECT count(*) FROM pg_extension WHERE extname='pgcolumnar' AND '' = current_setting('shared_preload_libraries')")" \
	"1"

psql_run "INSERT INTO r2 SELECT g, 'y' || g FROM generate_series(5001,9000) g;" >/dev/null 2>&1
target_lsn="$(q 'SELECT pg_current_wal_lsn()')"
for _i in $(seq 1 120); do
	rep="$(sb_q 'SELECT pg_last_wal_replay_lsn()')"
	[ -n "$rep" ] && [ "$(sb_q "SELECT '$rep'::pg_lsn >= '$target_lsn'::pg_lsn")" = t ] && break
	sleep 0.5
done

check "it replayed columnar WAL past the primary's LSN without the module" \
	"$(sb_q "SELECT pg_last_wal_replay_lsn() >= '$target_lsn'::pg_lsn")" "t"
check "and did not PANIC (still in recovery, still answering)" \
	"$(sb_q 'SELECT pg_is_in_recovery()')" "t"

# The bytes are there; only the access method is missing. Reload the module and
# the same standby can read what it replayed while it could not.
sb_stop
pgc_pg "sed -i \"s/^shared_preload_libraries=.*/shared_preload_libraries='pgcolumnar'/\" '$SB_DIR/postgresql.conf'" \
	>/dev/null 2>&1
sb_start
sync_standby

check "with the module back, the replayed table reads correctly" \
	"$(hash_standby r2)" "$(hash_primary r2)"

# On failure, restate the evidence at the END of the output.
#
# run_all_versions.sh tails the last 20 lines of a failing suite's log, and every
# diagnostic this suite prints -- sb_start's standby log dump, the port line --
# happens near the start, so the matrix showed twenty lines of passing scenario-3
# checks and nothing about what broke. Three separate investigations of an
# intermittent failure here were spent re-running the matrix with an external
# snapshotter purely to recover text the suite had already printed.
if [ "$PGC_FAIL" != 0 ]; then
	echo "-- replication failed; primary port $PGC_PORT, standby port $SB_PORT"
	echo "-- standby log tail:"
	pgc_pg "tail -25 '$SB_LOG'" 2>/dev/null | sed 's/^/     /'
	echo "-- standby data dir present: $(pgc_pg "test -d '$SB_DIR' && echo yes || echo no" 2>/dev/null | tr -d '[:space:]')"
fi

pgc_summary
