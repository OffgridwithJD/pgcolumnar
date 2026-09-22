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
# It also avoids a trap the first version of this file walked into: "hold every
# bucket" needs one advisory lock per bucket against a max_locks_per_transaction
# of 64, so the holder failed, the check passed with nobody holding anything, and
# the suite reported the same result with and without the fix. That was found
# when lib.sh globally set unique_lock_buckets=100003; the global is gone (#799)
# and the shipped default is 128, but 128 still exceeds 64, so discovering the
# tag rather than enumerating buckets remains the right shape.
#
# Usage:  test/advisory_lock_class.sh [PG_CONFIG]
# Written fresh for pgColumnar.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

PSQL_BG() {  # run SQL in a background session that stays open
	# STATEMENTS ARE FED ON STDIN, not through -c. With -c psql sends the whole
	# string as ONE simple-query message, so pg_stat_activity carries the entire
	# text from the first instant and cannot say which statement is running. The
	# set of locks an insert takes is complete only once the insert has RETURNED,
	# and "the session has reached its pg_sleep" is the signal that says so. On
	# stdin each statement is its own round trip, so the view moves with it.
	printf '%s\n' "$1" | env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 \
		-p "$PGC_PORT" -U postgres -d "$PGC_DB" -At >"$2" 2>&1 &
	echo $!
}

wait_for_sleeper() {  # -> yes once a background session has reached its pg_sleep
	for _i in $(seq 1 100); do
		if [ "$(q "SELECT count(*) FROM pg_stat_activity
		            WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'
		              AND state = 'active' AND query LIKE 'SELECT pg_sleep%'")" != "0" ]; then
			echo yes; return
		fi
		sleep 0.2
	done
	echo "no (no session reached pg_sleep within 20s)"
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

# EVERY advisory lock the session holds, and only once the insert has RETURNED.
# An insert takes more than one -- PGCOLUMNAR_LOCKCLASS_STORAGE_ROW (102) as
# well as PGCOLUMNAR_LOCKCLASS_UNIQUE_KEY (103) -- so `ORDER BY objsubid DESC
# LIMIT 1` names the unique-key lock only while the unique-key lock is the
# highest-numbered one. That stops being true in exactly the case this suite
# exists to catch: put the unique-key class back to 2 and the maximum becomes
# 102, the STORAGE_ROW lock, which is still unreachable -- so the suite reported
# the property holding while the lock under test sat in the SQL space (#1154).
sleeper="$(wait_for_sleeper)"
LOCKS="$(q "SELECT classid || ' ' || objid || ' ' || objsubid
	              FROM pg_locks
	             WHERE locktype = 'advisory' AND granted
	               AND pid <> pg_backend_pid()
	             ORDER BY objsubid DESC")"
NLOCKS="$(printf '%s\n' "$LOCKS" | grep -c '[0-9]')"

check "premise: the insert took an advisory lock we can see" \
	"$([ "$NLOCKS" -ge 1 ] && echo yes || echo "no (pg_locks showed nothing; sleeper=$sleeper)")" "yes"
echo "      the locks it took: $(printf '%s' "$LOCKS" | tr '\n' ';')"

# The assertion, read straight off the tags and over the WHOLE set: NO lock an
# insert takes may be in a SQL-reachable class. 1 and 2 are the only values an
# application can produce (lockfuncs.c), so anything else is unreachable. The
# failing value names the offending tags, so a red says which lock moved.
sql_reachable=""
while read -r _c _o _f; do
	[ -z "${_f:-}" ] && continue
	case "$_f" in 1|2) sql_reachable="$sql_reachable ($_c,$_o,field4=$_f)" ;; esac
done <<<"$LOCKS"
check "the lock an insert takes is not in a SQL-reachable class" \
	"$(if [ "$NLOCKS" -eq 0 ]; then echo unknown
	   elif [ -n "$sql_reachable" ]; then echo "reachable:$sql_reachable"
	   else echo unreachable; fi)" \
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
#
# EVERY addressable tag is held, not the highest-numbered one, for the reason in
# section 1: the discovery FEEDS this arm, so contending for the wrong tag
# disables this check as well -- two arms moving together with the defect, both
# still looking like evidence (#1154).
ADDR=""
NADDR=0
while read -r _c _o _f; do
	[ -z "${_f:-}" ] && continue
	if [ "$_c" -ge -2147483648 ] && [ "$_c" -le 2147483647 ] &&
	   [ "$_o" -ge -2147483648 ] && [ "$_o" -le 2147483647 ]; then
		ADDR="$ADDR$_c $_o
"
		NADDR=$((NADDR + 1))
	fi
done <<<"$LOCKS"

if [ "$NADDR" -gt 0 ]; then
	grab="BEGIN;"
	cond=""
	while read -r _c _o; do
		[ -z "${_o:-}" ] && continue
		grab="$grab
SELECT pg_advisory_xact_lock($_c::int, $_o::int);"
		cond="$cond OR (classid = $_c AND objid = $_o)"
	done <<<"$ADDR"
	grab="$grab
SELECT pg_sleep(30);"
	cond="${cond# OR }"

	HOLD2="$PGC_WORKDIR/holder.out"
	PID2=$(PSQL_BG "$grab" "$HOLD2")
	sleeper2="$(wait_for_sleeper)"
	held=$(q "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND granted
	            AND objsubid = 2 AND ($cond)")
	check "premise: the other session really holds that exact tag in class 2" \
		"$([ "${held:-0}" -ge "$NADDR" ] && echo yes || echo "no (holds ${held:-0} of $NADDR; sleeper=$sleeper2)")" \
		"yes"

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
	check_skip "the SQL form of the advisory lock" "SKIP  none of $(printf '%s' "$LOCKS" | tr '\n' ';') fits in two int4s, so the SQL form cannot address it" "classid or objid exceeds int4"
fi

# ---------------------------------------------------------------------------
# 3. The internal lock still does its job.
# ---------------------------------------------------------------------------
# Removing the collision by removing the lock would satisfy everything above and
# silently give back issue #5.
#
# IT PLANTS ITS OWN KEY. This arm used to re-insert 900001 and rely on the
# contention arm above having inserted it successfully -- so under a mutation
# that BLOCKS that insert, the key was never there and "a duplicate key is still
# rejected" went red for a reason that has nothing to do with duplicate keys.
# Measured: the #1154 mutation reddened three arms, of which the third was this
# cascade. An arm that depends on an earlier arm having passed reports on the
# earlier arm.
psql_run "INSERT INTO u VALUES (900002, 'first');" >/dev/null 2>&1
dup=$(psql_run "INSERT INTO u VALUES (900002, 'dup');" 2>&1)
check "a duplicate key is still rejected" \
	"$(grep -qiE 'duplicate key|unique constraint' <<<"$dup" && echo rejected || echo "NOT rejected: $(head -1 <<<"$dup")")" \
	"rejected"

pgc_summary
