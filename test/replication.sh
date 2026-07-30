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
# A second, restore-only cluster. See the "restore in isolation" block: it exists
# to take streaming out of the picture entirely.
RS_DIR="$PGC_WORKDIR/restore"
RS_LOG="$PGC_WORKDIR/restore.log"

# The standby needs a port of its own, and PGC_PORT + 1 is the one choice that
# cannot work. run_all_versions.sh hands each suite a port by walking upward from
# a base, one per suite per major, so PGC_PORT + 1 is the NEXT suite's primary by
# construction. It passes standalone and fails in the matrix, which is exactly
# what it did: green on PG17 alone, red on PG18 inside the matrix.
#
# Draws from below the ephemeral floor, and from a band the matrix's own walk
# does not reach.
#
# The old band was 30000-38999. The ephemeral range on this box starts at 32768,
# so most of that band was inside it, and this is where that cost the most: the
# standby is started LATE, long after the port was chosen, which is the widest
# possible window for an outbound connection to be assigned the same local port.
# The result was
#
#     could not bind IPv4 address "127.0.0.1": Address already in use
#
# with nothing listening before or after -- a standby that never started, checks
# that compared against an empty result, and a failure that moved majors every
# run. portlib.sh carries the full account.
#
# Probing for free is kept, but it is now meaningful: below the floor, a port that
# probes free is still free when the standby binds it, because the kernel does not
# allocate from here.
pick_sb_port() {
	local base p
	base=$(( PGC_AUX_PORT_LO + ($$ % (PGC_AUX_PORT_HI - PGC_AUX_PORT_LO)) ))
	for p in $(seq "$base" $((base + 300))); do
		[ "$p" -ge "$PGC_AUX_PORT_HI" ] && break
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
RS_PORT="$(pick_sb_port)"
while [ "$RS_PORT" = "$SB_PORT" ] || ! pgc_port_free "$RS_PORT"; do
	RS_PORT=$((RS_PORT + 1))
	[ "$RS_PORT" -gt 39000 ] && { echo "FAIL  no free port for the restore"; PGC_FAIL=1; pgc_summary; }
done
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

rs_q() {   # query the RESTORE-ONLY cluster
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$RS_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$1" 2>/dev/null || true
}

rs_stop() {
	pgc_pg "pg_ctl -D '$RS_DIR' stop -m immediate -w" >/dev/null 2>&1 || true
}

rs_start() {
	local i
	pgc_pg "pg_ctl -D '$RS_DIR' -l '$RS_LOG' -t 120 start -w" >/dev/null 2>&1
	for i in $(seq 1 120); do
		[ "$(rs_q 'SELECT 1')" = 1 ] && return 0
		sleep 0.5
	done
	echo "  restore cluster did not accept connections; last 15 lines of its log:"
	pgc_pg "tail -15 '$RS_LOG'" 2>/dev/null | sed 's/^/    /'
	return 1
}

# Stop both extra clusters before the ordinary teardown takes the primary away.
sb_teardown() { sb_stop; rs_stop; pgc_teardown; }
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

# Declared BEFORE the backup on purpose. docs/limitations.md (#267) tells users a
# physical backup preserves projections where pg_dump does not, and the claim is
# about the bytewise copy containing them -- so the projection has to exist at
# backup time or the test exercises streaming replay instead and the assertion
# names a mechanism it never ran.
psql_run "SELECT pgcolumnar.add_projection('r', 'r_pre', ARRAY['id','v'], ARRAY['id']);" >/dev/null 2>&1
proj_sql="SELECT count(*) FROM pgcolumnar.projection
	WHERE storage_id = pgcolumnar.get_storage_id('r') AND projection_id > 0"
pri_proj="$(q "$proj_sql;")"
check "the primary has a projection to preserve, before the backup runs" \
	"$pri_proj" "1"
pri_pre_rows="$(q "SELECT count(*) FROM pgcolumnar.read_projection('r','r_pre');")"
check "and it reads on the primary" "$pri_pre_rows" "20000"

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

# The claim docs/limitations.md makes: a physical backup preserves projections
# where pg_dump does not.
#
# #266 and #267 established the negative half with a test -- projections are keyed
# by storage_id, which a logical restore regenerates, so pg_dump cannot carry them
# and pg_dump_roundtrip.sh pins the loss. The positive half was reasoning: the
# backup is a bytewise copy, so the projection rows and the storage ids they name
# both come across unchanged. r_pre was declared before pg_basebackup ran, so it
# is genuinely in the backup and this asserts the documented mechanism.
check "pg_basebackup carried the projection catalog row, unlike pg_dump (#266)" \
	"$(sb_q "$proj_sql;")" "$pri_proj"

# Existence is not usability. The catalog row can arrive while the projection's
# own storage did not, which would read as preserved and behave as lost -- the
# same existence-versus-function gap the index point-lookup covers in
# pg_dump_roundtrip.sh. Read it on the standby and compare content, not counts.
check "and the projection's storage came across intact and readable" \
	"$(sb_q "SELECT count(*) FROM pgcolumnar.read_projection('r','r_pre');")" \
	"$pri_pre_rows"
check "with the same content the primary reads" \
	"$(sb_q "SELECT md5(string_agg(x, '' ORDER BY x)) FROM pgcolumnar.read_projection('r','r_pre') x;")" \
	"$(q "SELECT md5(string_agg(x, '' ORDER BY x)) FROM pgcolumnar.read_projection('r','r_pre') x;")"

# A distinct property, worth keeping now that it is no longer mislabelled as the
# backup one: a projection created AFTER the backup reaches the standby by WAL
# replay of the DDL and its back-fill -- the sibling of the SMGR-truncate replay
# this suite covers further down.
psql_run "SELECT pgcolumnar.add_projection('r', 'r_post', ARRAY['id','v'], ARRAY['id']);" >/dev/null 2>&1
check "the primary now has a second, post-backup projection" "$(q "$proj_sql;")" "2"

sync_standby
check "streaming replay carried a projection created after the backup" \
	"$(sb_q "$proj_sql;")" "2"
check "and that one reads on the standby too" \
	"$(sb_q "SELECT count(*) FROM pgcolumnar.read_projection('r','r_post');")" \
	"$pri_pre_rows"

# ---------------------------------------------------------------------------
# The same claim, with streaming taken out of the picture
# ---------------------------------------------------------------------------
#
# Everything above runs against a streaming standby, which would hold a
# projection whether it arrived in the backup or by replay afterwards. Declaring
# r_pre before the backup means the backup must contain it, but the assertion
# still cannot see which mechanism delivered it, so on its own it argues rather
# than proves -- the exact failing this PR set out to fix.
#
# So take a second backup and bring it up as a standalone cluster: no -R, no
# standby.signal, no primary_conninfo. It recovers to consistency from its own
# WAL and opens read-write, never connecting to the primary. Anything present in
# it came from the backup bytes, and nothing else. That is the documented claim
# with nothing left to attribute it to.
echo "-- restore in isolation (no streaming)"
pgc_pg "pg_basebackup -h 127.0.0.1 -p $PGC_PORT -U postgres -D '$RS_DIR' -X fetch -c fast" \
	>/dev/null 2>&1
pgc_pg "sed -i 's/^port=.*/port=$RS_PORT/' '$RS_DIR/postgresql.conf'" >/dev/null 2>&1
rs_start
check "the restored cluster accepts connections" "$(rs_q 'SELECT 1')" "1"

# The control that makes the rest mean anything: if this were still following the
# primary, or were the primary, "the projection is there" would prove nothing.
check "the restored cluster is not in recovery (it is not following anyone)" \
	"$(rs_q 'SELECT pg_is_in_recovery()')" "f"
check "and has no upstream configured" \
	"$(rs_q "SELECT count(*) FROM pg_stat_wal_receiver")" "0"
check "and is a different cluster from the primary and the standby" \
	"$([ "$(rs_q 'SHOW data_directory')" != "$(q 'SHOW data_directory')" ] && \
	   [ "$(rs_q 'SHOW data_directory')" != "$(sb_q 'SHOW data_directory')" ] && \
	   echo yes || echo no)" \
	"yes"

# Both of the next two compare the restored cluster against the primary, and a
# comparison of two empty results passes while proving nothing -- so pin the
# primary side to a literal first. Without these, dropping both projections on the
# primary would turn the pair below green rather than red.
rs_pri_count="$(q "$proj_sql;")"
rs_pri_hash="$(q "SELECT md5(string_agg(x, '' ORDER BY x)) FROM pgcolumnar.read_projection('r','r_pre') x;")"
check "the primary still has both projections when the backup is taken" \
	"$rs_pri_count" "2"
check "and a non-empty projection to compare against" \
	"$([ -n "$rs_pri_hash" ] && echo yes || echo no)" "yes"

# Compared against the primary's count now, not a literal: this backup is a
# snapshot of the primary taken at this point, so both r_pre and r_post are in it.
check "a physical backup alone preserves the projections, unlike pg_dump (#266)" \
	"$(rs_q "$proj_sql;")" "$rs_pri_count"
check "and its storage, readable with the same content" \
	"$(rs_q "SELECT md5(string_agg(x, '' ORDER BY x)) FROM pgcolumnar.read_projection('r','r_pre') x;")" \
	"$rs_pri_hash"

# r_post was declared after the FIRST backup but before this one, so it is in
# these bytes too. Its presence is not the point; its absence would mean this
# backup predates it and the check above was reading a stale copy.
check "and the later projection is in this backup as well, so it is not stale" \
	"$(rs_q "SELECT count(*) FROM pgcolumnar.read_projection('r','r_post');")" \
	"$pri_pre_rows"

rs_stop

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
