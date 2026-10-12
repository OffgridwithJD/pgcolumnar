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
check_num "from no partitions it creates enough to reach now plus three days" \
	"$made" "$(q "SELECT 4;")"
check_num "premise: the parent now has the partitions it reported" "$(kids tl)" "$made"
check "every partition it creates is columnar" "$(ams tl)" "pgcolumnar"
check "they are contiguous, each one day wide" \
	"$(bounds tl | awk -F'|' 'NR>1 && $1!=prev {gap++} {prev=$2} END {print gap+0}')|$(q "SELECT count(DISTINCT upper - lower) FROM (SELECT (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \\(''([^'']+)''\\)'))[1]::timestamptz AS upper, (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'FROM \\(''([^'']+)''\\)'))[1]::timestamptz AS lower FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = 'tl'::regclass) b;")" \
	"0|1"
check "and they cover now() plus three days" \
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
