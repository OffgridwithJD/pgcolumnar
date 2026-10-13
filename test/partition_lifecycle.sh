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

sqlstate_or() {	# sqlstate_or SQL -> the single value it returns, or the SQLSTATE it fails with
	local out
	out=$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-X -At -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -c "$1" 2>&1)
	case "$out" in ERROR:*) sed -n 's/^ERROR: *\([0-9A-Z]\{5\}\).*/\1/p' <<<"$out" | head -1;; *) echo "$out";; esac
}
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
check_num "rows within the covered range go in" "$(q "SELECT count(*) FROM tl;")" "101"
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

# ---- inputs that broke the first version (@jdatcmd, #1308 review) ---------------
# A stored generated column: LIKE without INCLUDING GENERATED made it a plain
# column, and ATTACH refused the partition.
q "CREATE TABLE gen (ts timestamptz NOT NULL, v int, w int GENERATED ALWAYS AS (v * 2) STORED)
   PARTITION BY RANGE (ts);" >/dev/null
gen_made="$(sqlstate_or "SELECT pgcolumnar.partition_create_ahead('gen', '1 day', 1);")"
check "a parent with a generated column gets its partitions, and the column stays generated" \
	"$gen_made|$(q "INSERT INTO gen VALUES (now(), 21); SELECT w FROM gen;" | tail -1)" "2|42"

# A 63-character name: the 16-character date suffix must survive, or the second
# partition's name truncates onto the first's.
LONG="p_$(printf 'x%.0s' $(seq 1 61))"
q "CREATE TABLE $LONG (ts timestamptz NOT NULL, v int) PARTITION BY RANGE (ts);" >/dev/null
long_made="$(sqlstate_or "SELECT pgcolumnar.partition_create_ahead('$LONG', '1 day', 2);")"
check "a parent with a 63-character name gets partitions whose names keep their dates" \
	"$long_made|$(q "SELECT count(*) FILTER (WHERE c.relname ~ '_[0-9]{8}T[0-9]{6}\$' AND octet_length(c.relname) <= 63)
	   FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = '$LONG'::regclass;")" "3|3"

# No bound on the work: one call with a tiny width ran for minutes holding locks,
# then failed on the lock table with nothing created. Refused before any DDL.
q "CREATE TABLE many (ts timestamptz NOT NULL, v int) PARTITION BY RANGE (ts);" >/dev/null
t0=$(date +%s%N)
many="$(sqlstate_or "SELECT pgcolumnar.partition_create_ahead('many', '1 second', 20000);")"
many_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
check "a call that would create more than 1000 partitions is refused before any DDL" \
	"$many|$(kids many)|$([ "$many_ms" -lt 5000 ] && echo prompt || echo "took $many_ms ms")" "22023|0|prompt"

# A partition bounded by MAXVALUE: the bound reader ignored it, and the first new
# partition overlapped it.
q "CREATE TABLE tail (ts timestamptz NOT NULL, v int) PARTITION BY RANGE (ts);
   CREATE TABLE tail_rest PARTITION OF tail FOR VALUES FROM ('2026-01-01') TO (MAXVALUE) USING pgcolumnar;" >/dev/null
check "a parent with a partition bounded by MAXVALUE is refused, and nothing is created" \
	"$(sqlstate_or "SELECT pgcolumnar.partition_create_ahead('tail', '1 day', 2);")|$(kids tail)" "55000|1"

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

# ==== the drop half: partition_drop_plan (#1297) ================================
#
#   partition_drop_plan(parent regclass, cutoff timestamptz) -> SETOF text
#
# The statements that retire every partition whose whole range is older than
# cutoff, in range order: DETACH ... CONCURRENTLY, then DROP. They cannot run
# inside a function (DETACH CONCURRENTLY refuses any function, DO block or
# procedure, on every major: #1297 note 1), so the function RETURNS them and
# the caller runs each as its own top-level statement (\gexec). A partition a
# concurrent detach left pending gets DETACH ... FINALIZE instead.
plan() { q "SELECT string_agg(s, E'\n') FROM pgcolumnar.partition_drop_plan('$1', '$2') s;"; }
run_plan() {	# each statement top-level, as \gexec would run it
	local line
	while IFS= read -r line; do
		[ -n "$line" ] && env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
			-d "$PGC_DB" -X -q -v ON_ERROR_STOP=1 -c "$line" >/dev/null 2>&1 || echo "failed: $line"
	done <<<"$(plan "$1" "$2")"
}
q "CREATE TABLE dl (ts timestamptz NOT NULL, v int) PARTITION BY RANGE (ts);
   CREATE TABLE dl_01 PARTITION OF dl FOR VALUES FROM ('2020-01-01 00:00+00') TO ('2020-02-01 00:00+00') USING pgcolumnar;
   CREATE TABLE dl_02 PARTITION OF dl FOR VALUES FROM ('2020-02-01 00:00+00') TO ('2020-03-01 00:00+00') USING pgcolumnar;
   CREATE TABLE dl_03 PARTITION OF dl FOR VALUES FROM ('2020-03-01 00:00+00') TO ('2020-04-01 00:00+00') USING pgcolumnar;
   CREATE TABLE dl_04 PARTITION OF dl FOR VALUES FROM ('2020-04-01 00:00+00') TO ('2020-05-01 00:00+00') USING pgcolumnar;
   INSERT INTO dl SELECT '2020-01-01 00:00+00'::timestamptz + g * interval '1 hour', g FROM generate_series(0, 2903) g;" >/dev/null
check "premise: the drop fixture has four partitions, each holding rows" \
	"$(q "SELECT count(DISTINCT tableoid) FROM dl;")|$(kids dl)" "4|4"
check "the plan retires the partitions wholly before the cutoff, in range order" \
	"$(plan dl '2020-03-15 00:00+00')" \
	"$(printf '%s\n' 'ALTER TABLE dl DETACH PARTITION dl_01 CONCURRENTLY' 'DROP TABLE dl_01' \
	                 'ALTER TABLE dl DETACH PARTITION dl_02 CONCURRENTLY' 'DROP TABLE dl_02')"
check "a cutoff on a partition's upper bound includes it" \
	"$(q "SELECT count(*) FROM pgcolumnar.partition_drop_plan('dl', '2020-03-01 00:00+00') s WHERE s LIKE 'DROP%';")" "2"
check "a cutoff before every partition plans nothing" \
	"$(q "SELECT count(*) FROM pgcolumnar.partition_drop_plan('dl', '2019-06-01 00:00+00');")" "0"
sids="$(q "SELECT string_agg(pgcolumnar.get_storage_id(c)::text, ',') FROM unnest(ARRAY['dl_01','dl_02']::regclass[]) c;")"
run_plan dl '2020-03-15 00:00+00'
check "running the plan leaves only the partitions it did not name" \
	"$(q "SELECT string_agg(c.relname, ',' ORDER BY c.relname) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
	      WHERE i.inhparent = 'dl'::regclass;")|$(q "SELECT count(*) FROM pg_class WHERE relname IN ('dl_01', 'dl_02');")" "dl_03,dl_04|0"
check "and every row the remaining partitions held is still there" \
	"$(q "SELECT count(*) FROM dl;")" "$(q "SELECT count(*) FROM generate_series(0, 2903) g
	   WHERE '2020-01-01 00:00+00'::timestamptz + g * interval '1 hour' >= '2020-03-01 00:00+00';")"
check "and the dropped partitions' pgcolumnar storage rows are gone" \
	"$(q "SELECT count(*) FROM pgcolumnar.storage WHERE storage_id IN (${sids:-0});")" "0"
check "a second plan for the same cutoff is empty" \
	"$(q "SELECT count(*) FROM pgcolumnar.partition_drop_plan('dl', '2020-03-15 00:00+00');")" "0"

# A timestamp (no zone) key: the cutoff is read in the session's zone, as the key's
# wall-clock time.
q "CREATE TABLE dw (ts timestamp NOT NULL) PARTITION BY RANGE (ts);
   CREATE TABLE dw_a PARTITION OF dw FOR VALUES FROM ('2021-01-01') TO ('2021-01-02') USING pgcolumnar;
   CREATE TABLE dw_b PARTITION OF dw FOR VALUES FROM ('2021-01-02') TO ('2021-01-03') USING pgcolumnar;" >/dev/null
check "a timestamp key's bounds are compared in the session's wall-clock time" \
	"$(q "SET TimeZone = 'America/New_York'; SELECT string_agg(s, ';') FROM pgcolumnar.partition_drop_plan('dw', '2021-01-02 00:00-05') s;")" \
	"ALTER TABLE dw DETACH PARTITION dw_a CONCURRENTLY;DROP TABLE dw_a"

# An interrupted concurrent detach leaves the partition pending: a transaction
# holding an older snapshot makes the second phase wait, and a statement timeout
# cancels it there.
q "CREATE TABLE dp (ts timestamptz NOT NULL) PARTITION BY RANGE (ts);
   CREATE TABLE dp_1 PARTITION OF dp FOR VALUES FROM ('2020-01-01 00:00+00') TO ('2020-02-01 00:00+00') USING pgcolumnar;
   CREATE TABLE dp_2 PARTITION OF dp FOR VALUES FROM ('2020-02-01 00:00+00') TO ('2020-03-01 00:00+00') USING pgcolumnar;" >/dev/null
env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -X -q \
	-c "BEGIN ISOLATION LEVEL REPEATABLE READ" -c "SELECT count(*) FROM dp" -c "SELECT pg_sleep(8)" -c "COMMIT" >/dev/null 2>&1 &
holder=$!
sleep 1
env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -X -q \
	-c "SET statement_timeout = '2s'" -c "ALTER TABLE dp DETACH PARTITION dp_1 CONCURRENTLY" >/dev/null 2>&1
wait "$holder"
check "premise: the interrupted detach left dp_1 pending" \
	"$(q "SELECT inhdetachpending FROM pg_inherits WHERE inhrelid = 'dp_1'::regclass;")" "t"
check "a pending detach is finalised, not started again" \
	"$(q "SELECT string_agg(s, ';') FROM pgcolumnar.partition_drop_plan('dp', '2020-02-01 00:00+00') s;")" \
	"ALTER TABLE dp DETACH PARTITION dp_1 FINALIZE;DROP TABLE dp_1"
run_plan dp '2020-02-01 00:00+00'
check "and running it drops the pending partition" \
	"$(q "SELECT count(*) FROM pg_class WHERE relname = 'dp_1';")|$(kids dp)" "0|1"

# Refusals, as partition_create_ahead refuses.
check "a drop plan for a parent with a DEFAULT partition is refused" \
	"$(sqlstate_or "SELECT count(*) FROM pgcolumnar.partition_drop_plan('td', now())")" "55000"
q "CREATE TABLE dn (k int NOT NULL) PARTITION BY RANGE (k);
   CREATE TABLE dnl (k int);" >/dev/null
check "a drop plan for a parent not partitioned on a timestamp is refused" \
	"$(sqlstate_or "SELECT count(*) FROM pgcolumnar.partition_drop_plan('dn', now())")|$(sqlstate_or "SELECT count(*) FROM pgcolumnar.partition_drop_plan('dnl', now())")" "55000|55000"

pgc_summary
