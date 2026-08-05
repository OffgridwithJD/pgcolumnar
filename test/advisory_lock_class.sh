#!/usr/bin/env bash
#
# pgColumnar's internal advisory locks must not be reachable from SQL (#430).
#
# locktag_field4 says which advisory lock space a tag belongs to, and PostgreSQL's
# own functions own exactly two values. From lockfuncs.c:
#
#     field4: 1 if using an int8 key, 2 if using 2 int4 keys
#
# We used both. The unique-key lock was SET_LOCKTAG_ADVISORY(db, indexOid, bucket, 2),
# which is bit for bit what pg_advisory_lock(indexOid, bucket) takes. So an
# application holding that tag blocked columnar inserts of that key, and columnar
# blocked the application, with nothing to point at but unexplained waiting.
#
# The lock is DISCOVERED from pg_locks rather than recomputed here. Reimplementing
# the bucket hash in the test would assert that two copies of our arithmetic agree,
# which is not the property. Reading the tag the running system actually took, then
# trying to grab that exact tag through the SQL function, is.
#
# It also avoids a trap the first version of this file walked into: lib.sh sets
# pgcolumnar.unique_lock_buckets=100003, so "hold every bucket" needs 100,003
# advisory locks against a max_locks_per_transaction of 64. The holder failed, the
# check passed with nobody holding anything, and the suite reported the same result
# with and without the fix.
#
# Usage:  test/advisory_lock_class.sh [PG_CONFIG]
# Written fresh for pgColumnar.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

PSQL_BG() {  # run SQL in a background session that stays open
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$1" >"$2" 2>&1 &
	echo $!
}

psql_run "CREATE TABLE u (k int, v text) USING pgcolumnar;
          CREATE UNIQUE INDEX u_k ON u (k);
          INSERT INTO u SELECT g, 'v'||g FROM generate_series(1,100) g;" >/dev/null

check "premise: the lock is enabled, or nothing below proves anything" \
	"$(q "SHOW pgcolumnar.enable_unique_insert_lock")" "on"

# ---------------------------------------------------------------------------
# 1. Discover the advisory lock an insert actually takes.
# ---------------------------------------------------------------------------
HOLD1="$PGC_WORKDIR/discover.out"
PID1=$(PSQL_BG "BEGIN; INSERT INTO u VALUES (900001, 'probe'); SELECT pg_sleep(30);" "$HOLD1")

lockrow=""
for _i in $(seq 1 60); do
	lockrow=$(q "SELECT classid || ' ' || objid || ' ' || objsubid
	               FROM pg_locks
	              WHERE locktype = 'advisory' AND granted
	                AND pid <> pg_backend_pid()
	              ORDER BY objsubid DESC LIMIT 1")
	[ -n "$lockrow" ] && break
	sleep 0.2
done
set -- $lockrow
LK_CLASSID="${1:-}"; LK_OBJID="${2:-}"; LK_SUBID="${3:-}"

check "premise: the insert took an advisory lock we can see" \
	"$([ -n "$LK_SUBID" ] && echo yes || echo "no (pg_locks showed nothing)")" "yes"
echo "      the lock it took: classid=$LK_CLASSID objid=$LK_OBJID field4=$LK_SUBID"

# The assertion, read straight off the tag. 1 and 2 are the only values an
# application can produce, so anything else is unreachable from SQL.
check "the lock an insert takes is not in a SQL-reachable class" \
	"$(case "$LK_SUBID" in 1|2) echo "reachable (field4=$LK_SUBID)" ;; "") echo unknown ;; *) echo unreachable ;; esac)" \
	"unreachable"

# Terminate the BACKEND, not just psql. Killing the client leaves the server
# inside pg_sleep() holding its transaction, and every check below then blocks on
# our own lock rather than on the user's, in both arms, which is how the first
# version of this file reported the same result with and without the fix.
q "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
      AND state IN ('idle in transaction', 'active')" >/dev/null
kill "$PID1" 2>/dev/null; wait "$PID1" 2>/dev/null
gone=no
for _i in $(seq 1 60); do
	if [ "$(q "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND pid<>pg_backend_pid()")" = "0" ]; then
		gone=yes; break
	fi
	sleep 0.2
done
check "premise: the discovering session is gone and holds nothing" "$gone" "yes"

# ---------------------------------------------------------------------------
# 2. A user taking that exact tag must not block the insert.
# ---------------------------------------------------------------------------
# pg_advisory_xact_lock(int4,int4) produces field4 = 2. Before the fix our lock
# was also field4 = 2, so this took the same tag and the insert waited forever.
if [ -n "$LK_CLASSID" ] && [ "$LK_CLASSID" -le 2147483647 ] && [ "$LK_OBJID" -le 2147483647 ]; then
	HOLD2="$PGC_WORKDIR/holder.out"
	PID2=$(PSQL_BG "BEGIN;
	                SELECT pg_advisory_xact_lock($LK_CLASSID::int, $LK_OBJID::int);
	                SELECT pg_sleep(30);" "$HOLD2")
	held=no
	for _i in $(seq 1 60); do
		n=$(q "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND granted
		         AND objsubid = 2 AND classid = $LK_CLASSID AND objid = $LK_OBJID")
		[ "${n:-0}" -ge 1 ] && { held=yes; break; }
		sleep 0.2
	done
	check "premise: the other session really holds that exact tag in class 2" "$held" "yes"

	ins=$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -At \
		-c "SET statement_timeout = '10s';" -c "INSERT INTO u VALUES (900001, 'new');" 2>&1)
	case "$ins" in
		*timeout*|*canceling*) verdict="BLOCKED by the user lock" ;;
		*ERROR*)               verdict="ERROR: $(head -1 <<<"$ins")" ;;
		*)                     verdict=ok ;;
	esac
	check "a user advisory lock on that tag does not block a columnar insert" "$verdict" "ok"

	q "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
	    WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
	      AND state IN ('idle in transaction', 'active')" >/dev/null
	kill "$PID2" 2>/dev/null; wait "$PID2" 2>/dev/null
	for _i in $(seq 1 60); do
		[ "$(q "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND pid<>pg_backend_pid()")" = "0" ] && break
		sleep 0.2
	done
else
	echo "SKIP  classid $LK_CLASSID or objid $LK_OBJID exceeds int4, so the SQL form cannot address it"
fi

# ---------------------------------------------------------------------------
# 3. The internal lock still does its job.
# ---------------------------------------------------------------------------
# Removing the collision by removing the lock would satisfy everything above and
# silently give back issue #5.
dup=$(psql_run "INSERT INTO u VALUES (900001, 'dup');" 2>&1)
check "a duplicate key is still rejected" \
	"$(grep -qiE 'duplicate key|unique constraint' <<<"$dup" && echo rejected || echo "NOT rejected: $(head -1 <<<"$dup")")" \
	"rejected"

pgc_summary
