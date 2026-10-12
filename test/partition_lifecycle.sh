#!/usr/bin/env bash
#
# pgcolumnar.partition_create_ahead: columnar partitions created ahead, without an
# exclusive lock on the parent (#1297).
#
# WRITTEN BEFORE THE FUNCTION EXISTS (the owner's TDD rule). The specification it
# pins, from #1297's design note 1, measured on PG 15..19:
#
#   * CREATE TABLE ... PARTITION OF takes ACCESS EXCLUSIVE on the parent, while a
#     standalone CREATE followed by ATTACH takes SHARE UPDATE EXCLUSIVE. So the
#     function must never hold more than SHARE UPDATE EXCLUSIVE on the parent.
#   * before PG 17 the parent cannot carry USING pgcolumnar, so the function sets
#     the access method on every partition itself.
#   * a DEFAULT partition rules out DETACH CONCURRENTLY for the drop half, so a
#     parent with one is refused rather than half-managed.
#
#   partition_create_ahead(parent regclass, width interval, ahead int) -> int
#
#   Makes sure the parent's partitions reach now() + ahead * width, each `width`
#   wide and contiguous with the last existing upper bound -- or, with no
#   partitions yet, starting at now() truncated to the width's unit -- and returns
#   how many it created. A second call creates nothing: the daemon calls it every
#   pass.
#
# Usage:  test/partition_lifecycle.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

at_least() { [ -z "$1" ] && return; [ "$1" -lt "$2" ] && echo "$1" || echo "$2"; }

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null
check_num "premise: the function exists" \
	"$(q "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	      WHERE n.nspname = 'pgcolumnar' AND p.proname = 'partition_create_ahead';")" "1"

kids() { q "SELECT count(*) FROM pg_inherits WHERE inhparent = '$1'::regclass;"; }
ams()  { q "SELECT coalesce(string_agg(DISTINCT a.amname, ','), 'none') FROM pg_inherits i
            JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_am a ON a.oid = c.relam
            WHERE i.inhparent = '$1'::regclass;"; }
# the partition bounds, as "from|to" lines in order
bounds() {
	q "SELECT (regexp_match(pg_get_expr(c.relpartbound, c.oid),
	           'FROM \\(''([^'']+)''\\) TO \\(''([^'']+)''\\)'))[1]
	          || '|' ||
	          (regexp_match(pg_get_expr(c.relpartbound, c.oid),
	           'FROM \\(''([^'']+)''\\) TO \\(''([^'']+)''\\)'))[2]
	   FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
	   WHERE i.inhparent = '$1'::regclass ORDER BY 1;"
}

# ---- from nothing -----------------------------------------------------------
q "CREATE TABLE tl (ts timestamptz NOT NULL, v int) PARTITION BY RANGE (ts);" >/dev/null
made="$(q "SELECT pgcolumnar.partition_create_ahead('tl', '1 day', 3);")"
check_num "from no partitions it creates enough to reach now plus the lead" \
	"$made" "$(q "SELECT 4;")"
check_num "premise: the parent now has the partitions it reported" "$(kids tl)" "$made"
check "every partition it creates is columnar" "$(ams tl)" "pgcolumnar"
check "they are contiguous, each one width wide" \
	"$(bounds tl | awk -F'|' 'NR>1 && $1!=prev {gap++} {prev=$2} END {print gap+0}')|$(q "SELECT count(DISTINCT upper - lower) FROM (SELECT (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \\(''([^'']+)''\\)'))[1]::timestamptz AS upper, (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'FROM \\(''([^'']+)''\\)'))[1]::timestamptz AS lower FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = 'tl'::regclass) b;")" \
	"0|1"
check "and they cover now() plus the lead" \
	"$(q "SELECT bool_or(now() + interval '3 days' < (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \\(''([^'']+)''\\)'))[1]::timestamptz
	             AND now() + interval '3 days' >= (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'FROM \\(''([^'']+)''\\)'))[1]::timestamptz)
	      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = 'tl'::regclass;")" "t"

# ---- idempotent, and it continues from the last bound ----------------------
check_num "a second call creates nothing" \
	"$(q "SELECT pgcolumnar.partition_create_ahead('tl', '1 day', 3);")" "0"
check_num "asking further ahead creates only the difference" \
	"$(q "SELECT pgcolumnar.partition_create_ahead('tl', '1 day', 5);")" "2"

# ---- rows go in, columnar ------------------------------------------------------
q "INSERT INTO tl SELECT now() + g * interval '1 hour', g FROM generate_series(0, 100) g;" >/dev/null
check_num "premise: rows within the covered range go in" "$(q "SELECT count(*) FROM tl;")" "101"
check "and land in columnar partitions" \
	"$(q "SELECT string_agg(DISTINCT a.amname, ',') FROM tl t JOIN pg_class c ON c.oid = t.tableoid
	      JOIN pg_am a ON a.oid = c.relam;")" "pgcolumnar"

# ---- the parent lock ----------------------------------------------------------
q "CREATE TABLE tk (ts timestamptz NOT NULL, v int) PARTITION BY RANGE (ts);" >/dev/null
# The call and the lock reading share one transaction, and the arm requires the
# call to have RETURNED: in the red run before the function existed, the failed
# call aborted the transaction, the pg_locks query returned nothing, and an arm
# reading "no AccessExclusiveLock" passed on a function that did not exist.
out="$(q "BEGIN; SELECT 'made=' || pgcolumnar.partition_create_ahead('tk', '1 hour', 6);
	SELECT 'locks=' || coalesce(string_agg(DISTINCT mode, ',' ORDER BY mode), 'none') FROM pg_locks
	 WHERE relation = 'tk'::regclass AND pid = pg_backend_pid(); ROLLBACK;")"
tk_made="$(printf '%s\n' "$out" | sed -n 's/^made=//p')"
lock="$(printf '%s\n' "$out" | sed -n 's/^locks=//p')"
echo "-- created $tk_made; locks held on the parent: ${lock:-<unread>}"
check_num "premise: the call inside the transaction created partitions" "$(at_least "$tk_made" 1)" "1"
check "it never takes AccessExclusiveLock on the parent" \
	"$(case "$lock" in '') echo unread;; *AccessExclusiveLock*) echo "held: $lock";; *) echo none;; esac)" "none"

# ---- the session's time zone ----------------------------------------------------
# The bounds are read back as text and continued from. For a `timestamp` key (no
# zone) the text carries no offset, so reading it in one zone and writing the next
# bound in another leaves a gap or an overlap. Each arm continues from a partition
# made by hand, in a session whose zone is not UTC, and requires every partition's
# lower bound to be exactly the previous one's upper bound.
contiguous() {	# contiguous PARENT -> "ok", or the first break
	bounds "$1" | awk -F'|' 'NR>1 && $1!=prev {print "break: " prev " then " $1; bad=1; exit} {prev=$2} END {if (!bad) print "ok"}'
}
for key in timestamp timestamptz; do
	t="tz_$key"
	q "CREATE TABLE $t (ts $key NOT NULL, v int) PARTITION BY RANGE (ts);" >/dev/null
	q "SET TimeZone = 'America/New_York';
	   CREATE TABLE ${t}_seed PARTITION OF $t FOR VALUES
	   FROM (date_trunc('day', now() - interval '2 days')::$key) TO (date_trunc('day', now() - interval '1 day')::$key)
	   USING pgcolumnar;" >/dev/null
	tz_made="$(q "SET TimeZone = 'America/New_York'; SELECT pgcolumnar.partition_create_ahead('$t', '1 day', 2);" | tail -1)"
	check_num "premise: a $key parent continued from a hand-made partition, in a session west of UTC" \
		"$(at_least "$tz_made" 3)" "3"
	check "a $key parent's partitions are contiguous across a non-UTC session" \
		"$(q "SET TimeZone = 'America/New_York'; SELECT 1;" >/dev/null; contiguous "$t")" "ok"
	check_num "and a row at every boundary has exactly one partition to go to ($key)" \
		"$(q "SET TimeZone = 'America/New_York';
		      INSERT INTO $t SELECT (date_trunc('day', now() - interval '1 day') + g * interval '1 day')::$key, g
		      FROM generate_series(0, 2) g; SELECT count(*) FROM $t;" | tail -1)" "3"
done

# A `timestamp` key holds local wall-clock time, so "now" for it is the session's
# localtimestamp. East of UTC that is ahead of UTC's: a function that reasoned in
# UTC would stop nine hours short in Tokyo.
q "CREATE TABLE tz_tokyo (ts timestamp NOT NULL, v int) PARTITION BY RANGE (ts);" >/dev/null
tk2="$(q "SET TimeZone = 'Asia/Tokyo'; SELECT pgcolumnar.partition_create_ahead('tz_tokyo', '1 day', 2);" | tail -1)"
echo "-- Tokyo local now: $(q "SET TimeZone = 'Asia/Tokyo'; SELECT localtimestamp;" | tail -1); bounds: $(bounds tz_tokyo | tr '\n' ' ')"
check_num "premise: a timestamp parent was given partitions from a session east of UTC" "$(at_least "$tk2" 1)" "1"
check "a timestamp parent made east of UTC covers the local now plus the lead" \
	"$(q "SET TimeZone = 'Asia/Tokyo';
	      SELECT bool_or(localtimestamp + interval '2 days' >= (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'FROM \\(''([^'']+)''\\)'))[1]::timestamp
	                 AND localtimestamp + interval '2 days' < (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \\(''([^'']+)''\\)'))[1]::timestamp)
	      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = 'tz_tokyo'::regclass;" | tail -1)" "t"

check "and its partitions start on the width's boundary in the key's own wall clock" \
	"$(bounds tz_tokyo | awk -F'|' '$1 !~ / 00:00:00$/ {print "not midnight: " $1; bad=1; exit} END {if (!bad) print "ok"}')" "ok"

# ---- refused: a DEFAULT partition -------------------------------------------------
q "CREATE TABLE td (ts timestamptz NOT NULL, v int) PARTITION BY RANGE (ts);
   CREATE TABLE td_default PARTITION OF td DEFAULT USING pgcolumnar;" >/dev/null
check "a parent with a DEFAULT partition is refused" \
	"$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
	   -At -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate \
	   -c "SELECT pgcolumnar.partition_create_ahead('td', '1 day', 2)" 2>&1 >/dev/null |
	   sed -n 's/^ERROR: *\([0-9A-Z]\{5\}\).*/\1/p')" "55000"
# Only a claim when the function exists: with it absent, nothing is created
# for any parent, and this arm passed in the red run.
check "and nothing was created for it" \
	"$(kids td)|$(q "SELECT count(*) FROM pg_proc WHERE proname = 'partition_create_ahead';")" "1|1"

pgc_summary
