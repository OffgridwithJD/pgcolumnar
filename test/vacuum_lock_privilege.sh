#!/usr/bin/env bash
#
# pgColumnar: vacuum, vacuum_sorted and cluster check ownership BEFORE taking the
# AccessExclusiveLock (#568), so an unprivileged caller cannot queue in the lock
# FIFO and block readers of a table it does not own.
#
# A plain "a non-owner is refused" test is NOT a removal proof here: on unfixed
# main the non-owner IS refused, just after table_open has already taken (or
# queued for) the exclusive lock. The observable that separates the two orderings
# is contention. This suite holds an AccessExclusiveLock on the table in another
# session and then calls the function as a non-owner with a short lock_timeout:
#
#   fix (privilege first): refused with "must be owner" immediately, no lock wait.
#   main (lock first):     the caller queues behind the held lock and hits the
#                          lock_timeout -- proof it requested the exclusive lock
#                          before its ownership was ever checked.
#
# So the deny arms assert the refusal is an OWNERSHIP error and not a lock
# timeout. On main they see a lock timeout and go red; that red is the proof.
#
# Usage:  test/vacuum_lock_privilege.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

psql_run "CREATE TABLE victim (id int, v int) USING pgcolumnar;"
psql_run "INSERT INTO victim SELECT g, g FROM generate_series(1,2000) g;"
psql_run "REVOKE ALL ON victim FROM PUBLIC;"
psql_run "DROP ROLE IF EXISTS t_unpriv;"
psql_run "CREATE ROLE t_unpriv NOSUPERUSER LOGIN;"
psql_run "GRANT USAGE ON SCHEMA pgcolumnar TO t_unpriv;"

as_super() { env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -Atq -v ON_ERROR_STOP=0 "$@" 2>&1; }

# Classify an unprivileged call made WHILE an exclusive lock is held on victim.
# Returns: owner (refused by ownership, before the lock) | locktimeout (queued
# for the lock, so ownership was checked too late) | other | success.
outcome_under_contention() {	# sql -> owner|locktimeout|other|success
	local out
	out="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U t_unpriv \
		-d "$PGC_DB" -Atq -v ON_ERROR_STOP=0 \
		-c "SET lock_timeout='4s';" -c "$1" 2>&1)"
	case "$out" in
		*"must be owner"*|*"permission denied for"*) echo owner ;;
		*"lock timeout"*|*"canceling statement due to lock"*) echo locktimeout ;;
		*ERROR*) echo "other:${out:0:50}" ;;
		*) echo success ;;
	esac
}

# ---- premises ---------------------------------------------------------------
check_num "premise: the caller can open a session" \
	"$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U t_unpriv -d "$PGC_DB" -Atq -c 'SELECT 1;' 2>&1)" 1
check "premise: the caller is not the owner of victim" \
	"$(q "SELECT pg_get_userbyid(relowner)='t_unpriv' FROM pg_class WHERE oid='victim'::regclass;")" "f"
check "premise: victim is a columnar table" \
	"$(q "SELECT a.amname FROM pg_class c JOIN pg_am a ON a.oid=c.relam WHERE c.oid='victim'::regclass;")" "pgcolumnar"

# ---- hold an AccessExclusiveLock on victim in a background session ----------
# The holder keeps a transaction open with the lock for the window below, then
# rolls back. Its own lock conflicts with the exclusive lock vacuum/cluster take,
# so an unfixed caller queues behind it.
holder_log="$PGC_WORKDIR/holder.log"
as_super -c "BEGIN;" -c "LOCK TABLE victim IN ACCESS EXCLUSIVE MODE;" -c "SELECT pg_sleep(30);" -c "ROLLBACK;" > "$holder_log" 2>&1 &
holder_pid=$!
# Wait until the lock is actually granted before probing, so the test is not racing
for _ in $(seq 1 40); do
	held="$(q "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid=l.relation WHERE c.relname='victim' AND l.mode='AccessExclusiveLock' AND l.granted;")"
	[ "${held:-0}" -ge 1 ] && break
	sleep 0.25
done
check "premise: an AccessExclusiveLock on victim is held before the probes" "${held:-0}" "1"

# ---- the deny arms: refused by ownership, not by a lock wait ----------------
check "vacuum refuses a non-owner before taking the exclusive lock" \
	"$(outcome_under_contention "SELECT pgcolumnar.vacuum('victim'::regclass);")" "owner"
check "vacuum_sorted refuses a non-owner before taking the exclusive lock" \
	"$(outcome_under_contention "SELECT pgcolumnar.vacuum_sorted('victim'::regclass, 'id');")" "owner"
check "cluster refuses a non-owner before taking the exclusive lock" \
	"$(outcome_under_contention "SELECT pgcolumnar.cluster('victim'::regclass, 'id');")" "owner"

# The caller must never have entered the lock queue: no ungranted request from it.
check "the refused caller left no lock request queued on victim" \
	"$(q "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid=l.relation JOIN pg_stat_activity a ON a.pid=l.pid WHERE c.relname='victim' AND a.usename='t_unpriv' AND NOT l.granted;")" "0"

# release the holder
as_super -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep(30)%' AND pid <> pg_backend_pid();" >/dev/null 2>&1
wait "$holder_pid" 2>/dev/null || true

# ---- allow arm: the owner is not broken (uncontended) -----------------------
check "the owner can still vacuum the table" \
	"$(as_super -c "SELECT pgcolumnar.vacuum('victim'::regclass);" | grep -c 'ERROR')" "0"

pgc_summary
