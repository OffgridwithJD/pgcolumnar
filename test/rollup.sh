#!/usr/bin/env bash
#
# Incremental rollups, phase 1: append-only (#1294).
#
# WRITTEN BEFORE THE CODE, against the API proposed on #1294:
#
#     pgcolumnar.create_rollup(rollup, source, ts_column, width, origin, group_by name[],
#                              agg_functions text[], agg_columns name[], access_method)
#     pgcolumnar.refresh_rollup(rollup regclass) -> rows folded
#     pgcolumnar.rebase_rollup(rollup regclass) -> row groups recorded
#
# The rollup is a table, one row per (bucket, group_by...) key, with columns
# `bucket`, the group_by columns, then one per aggregate named `count`, or
# <function>_<column> (sum_v, min_v, max_v, avg_f).
#
# THE ORACLE is a full recompute of the same GROUP BY over the source, every
# time. Exactness is fixed by the design on #1294 so it cannot be loosened here:
# count, integer sum, min and max exact; avg of float8 within a relative 1e-12.
#
# A refresh is one statement and so one snapshot: rows committed while it runs
# are neither folded nor recorded, and the next refresh takes them, exactly once
# (pgcolumnar.rollup_pause, a developer setting, holds it open for that arm).
# Phase 1 refuses any change but appends, until phase 2's dirty buckets.
#
# Usage:  test/rollup.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

at_least() { [ -z "$1" ] && return; [ "$1" -lt "$2" ] && echo "$1" || echo "$2"; }
sqlstate() {	# sqlstate SQL -> the SQLSTATE it fails with, or ok
	local out
	out=$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-X -At -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -c "$1" 2>&1 >/dev/null)
	[ -z "$out" ] && { echo ok; return; }
	echo "$out" | sed -n 's/^ERROR: *\([0-9A-Z]\{5\}\).*/\1/p' | head -1
}

sqlstate_or() {	# sqlstate_or SQL -> the single value it returns, or the SQLSTATE it fails with
	local out
	out=$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-X -At -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -c "$1" 2>&1)
	case "$out" in ERROR:*) sed -n 's/^ERROR: *\([0-9A-Z]\{5\}\).*/\1/p' <<<"$out" | head -1;; *) echo "$out";; esac
}
q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null
check_num "premise: the rollup functions exist" \
	"$(q "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	      WHERE n.nspname = 'pgcolumnar' AND p.proname IN ('create_rollup', 'refresh_rollup', 'rebase_rollup');")" "3"

ORIGIN="2026-01-01 00:00:00+00"
q "CREATE TABLE src (ts timestamptz, dev int, v bigint, f float8) USING pgcolumnar;
   SELECT pgcolumnar.set_options('src', stripe_row_limit => 4000);" >/dev/null
load() {	# load FROM TO START-TS: rows g in [FROM, TO], 37 s apart from START-TS
	# bigint: g * 104729 overflows int past g = 20,505, the INSERT then fails, and
	# every arm below would measure an empty table (the first red run did).
	q "INSERT INTO src SELECT '$3'::timestamptz + (g - $1) * interval '37 s', g % 7, (g * 7919) % 100003,
	   ((g * 104729) % 9973) / 13.0 FROM generate_series($1::bigint, $2) g;" >/dev/null
}
load 1 30000 "2026-03-01 00:00:00+00"
check_num "premise: the source holds every row" "$(q "SELECT count(*) FROM src;")" "30000"

# The oracle, and the rollup read the same way: exact columns hashed, avg kept apart.
RECOMPUTE="SELECT date_bin('1 hour', ts, '$ORIGIN') AS bucket, dev, count(*) AS count,
           sum(v)::numeric AS sum_v, min(v) AS min_v, max(v) AS max_v, avg(f) AS avg_f
           FROM src GROUP BY 1, 2"
# concat_ws over coalesce: a plain || makes a row with any NULL into NULL, and
# string_agg then drops it, so NULL keys would be compared by not being there.
exact() { q "SELECT count(*) || '|' || md5(string_agg(concat_ws(',', coalesce(bucket::text, '~'),
             coalesce(dev::text, '~'), count, coalesce(sum_v::text, '~'), coalesce(min_v::text, '~'),
             coalesce(max_v::text, '~')), ';' ORDER BY bucket NULLS FIRST, dev NULLS FIRST)) FROM ($1) x;"; }
# the worst relative difference of avg_f between the rollup and the recompute
avg_gap() {
	q "SELECT coalesce(max(abs(r.avg_f - o.avg_f) / greatest(abs(o.avg_f), 1e-300)), 0) < 1e-12
	   AND count(*) = (SELECT count(*) FROM ($RECOMPUTE) z)
	   FROM r_hourly r JOIN ($RECOMPUTE) o USING (bucket, dev);"
}
matches() { echo "$(exact "SELECT * FROM r_hourly")|$(avg_gap)"; }
oracle() { echo "$(exact "$RECOMPUTE")|t"; }

AGGS="'{count,sum,min,max,avg}', '{*,v,v,v,f}'"
q "SELECT pgcolumnar.create_rollup('r_hourly', 'src', 'ts', '1 hour', '$ORIGIN', '{dev}', $AGGS);" >/dev/null
check "the rollup table exists with the documented columns" \
	"$(q "SELECT string_agg(attname, ',' ORDER BY attnum) FROM pg_attribute
	      WHERE attrelid = to_regclass('r_hourly') AND attnum > 0 AND NOT attisdropped;")" \
	"bucket,dev,count,sum_v,min_v,max_v,avg_f"

check_num "the first refresh folds every row" "$(q "SELECT pgcolumnar.refresh_rollup('r_hourly');")" "30000"
check "and after the first refresh the rollup equals a full recompute" "$(matches)" "$(oracle)"
check_num "a refresh with nothing new folds nothing" "$(q "SELECT pgcolumnar.refresh_rollup('r_hourly');")" "0"
check "and leaves the rollup as it was" "$(matches)" "$(oracle)"

# Appends, including late data: rows whose timestamps land in buckets the rollup
# already has. A time watermark would never see them.
load 30001 33000 "2026-03-13 08:00:00+00"
load 33001 34500 "2026-03-02 05:00:00+00"
check_num "a refresh after appends folds exactly the appended rows, late ones included" \
	"$(q "SELECT pgcolumnar.refresh_rollup('r_hourly');")" "4500"
check "and the rollup still equals a full recompute" "$(matches)" "$(oracle)"

# Rows committed while a refresh runs: not in its snapshot, so the NEXT refresh
# folds them, once.
load 34501 35000 "2026-03-14 00:00:00+00"
env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -X -At \
	-c "SET pgcolumnar.rollup_pause = on" -c "SELECT 'folded=' || pgcolumnar.refresh_rollup('r_hourly')" \
	> "$PGC_WORKDIR/paused.out" 2>&1 &
refresher=$!
sleep 1
load 35001 35300 "2026-03-14 06:00:00+00"
wait "$refresher"
check "the paused refresh folded what was there before it began" \
	"$(sed -n 's/^folded=//p' "$PGC_WORKDIR/paused.out")" "500"
check_num "the next refresh folds the rows committed during the last one, once" \
	"$(q "SELECT pgcolumnar.refresh_rollup('r_hourly');")" "300"
check "and after the refresh that ran beside an insert the rollup equals a full recompute" "$(matches)" "$(oracle)"

# Two refreshes at once: the second waits for the first, then has nothing to fold.
load 35301 37300 "2026-03-15 00:00:00+00"
for i in 1 2; do
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -X -At \
		-c "SELECT pgcolumnar.refresh_rollup('r_hourly')" > "$PGC_WORKDIR/both_$i.out" 2>&1 &
done
wait
check "two refreshes started together fold the new rows once between them" \
	"$(cat "$PGC_WORKDIR/both_1.out" "$PGC_WORKDIR/both_2.out" | sort -n | tr '\n' ' ')" "0 2000 "
check "and after two refreshes started together the rollup equals a full recompute" "$(matches)" "$(oracle)"

# The bucket is a pure function of ts: refreshes from different zones agree.
for z in UTC Asia/Kolkata; do
	r="r_$(tr '/' '_' <<<"$z" | tr 'A-Z' 'a-z')"
	q "SET TimeZone = '$z'; SELECT pgcolumnar.create_rollup('$r', 'src', 'ts', '1 hour', '$ORIGIN', '{dev}', $AGGS);
	   SELECT pgcolumnar.refresh_rollup('$r');" >/dev/null
done
check "refreshes from sessions in different time zones build the same rollup" \
	"$(exact "SELECT * FROM r_utc")" "$(exact "SELECT * FROM r_asia_kolkata")"
# Empty equals empty: in the first red run both were, and the arm above passed.
check_num "the zone rollups hold a row per key of the recompute" \
	"$(q "SELECT count(*) FROM r_utc;")" "$(q "SELECT count(*) FROM ($RECOMPUTE) z;")"
check_num "and that is not zero" "$(at_least "$(q "SELECT count(*) FROM r_utc;")" 1)" "1"

# Cost: after a small append to the whole table, a refresh reads the new groups.
# The source is grown first: on a 26-page table the refresh's fixed cost (the
# group list, the storage id) is itself more than a fifth (measured: 15 blocks).
load 100001 300000 "2026-04-01 00:00:00+00"
check_num "a refresh folds a bulk append" "$(q "SELECT pgcolumnar.refresh_rollup('r_hourly');")" "200000"
check "and after the bulk append the rollup equals a full recompute" "$(matches)" "$(oracle)"
load 37301 38300 "2026-03-16 00:00:00+00"
q "SELECT pg_stat_reset();" >/dev/null
env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -At \
	-c "SELECT pgcolumnar.refresh_rollup('r_hourly')" -c "SELECT pg_stat_force_next_flush()" >/dev/null 2>&1
read_blocks="$(q "SELECT coalesce(heap_blks_read, 0) + coalesce(heap_blks_hit, 0) FROM pg_statio_user_tables WHERE relname = 'src';")"
pages="$(q "SELECT pg_relation_size('src') / 8192;")"
echo "-- refresh after a 1000-row append read $read_blocks of $pages blocks"
check_num "the refresh after a small append read the source at all" "$(at_least "$read_blocks" 1)" "1"
# Reading nothing also reads under a fifth: the arm requires a read.
check_num "a refresh after a small append reads under a fifth of the source" \
	"$( [ -n "$read_blocks" ] && [ "$read_blocks" -ge 1 ] && at_least $((pages - 5 * read_blocks)) 1 || echo "read ${read_blocks:-nothing}")" "1"
check "and after the small append the rollup equals a full recompute" "$(matches)" "$(oracle)"

# A rewrite renumbers every row group (#1294 point 9): the snapshot no longer names
# the source's groups, so a refresh is refused, and rebase_rollup records the
# current groups without touching the rollup.
# The identity is the storage id and the group numbers: measured, pgcolumnar.vacuum
# gives a table a new storage id and may keep its group numbers.
groups_before="$(q "SELECT pgcolumnar.get_storage_id('src') || ':' || string_agg(group_number::text, ',' ORDER BY group_number)
	FROM pgcolumnar.row_group WHERE storage_id = pgcolumnar.get_storage_id('src');")"
q "SELECT pgcolumnar.vacuum('src');" >/dev/null
groups_after="$(q "SELECT pgcolumnar.get_storage_id('src') || ':' || string_agg(group_number::text, ',' ORDER BY group_number)
	FROM pgcolumnar.row_group WHERE storage_id = pgcolumnar.get_storage_id('src');")"
check "premise: pgcolumnar.vacuum gave the source's row groups new identities" \
	"$([ -n "$groups_after" ] && [ "$groups_after" != "$groups_before" ] && echo renumbered || echo "same: $groups_after")" "renumbered"
vb="$(exact "SELECT * FROM r_hourly")"
check_num "the rollup holds rows before the rewrite" "$(at_least "$(q "SELECT count(*) FROM r_hourly;")" 1)" "1"
check "a refresh after the source was rewritten is refused, naming rebase_rollup" \
	"$(sqlstate "SELECT pgcolumnar.refresh_rollup('r_hourly');")|$(exact "SELECT * FROM r_hourly")" "55000|$vb"
check_num "rebase_rollup records the source's current row groups" \
	"$(at_least "$(q "SELECT pgcolumnar.rebase_rollup('r_hourly');")" 1)" "1"
check "and leaves the rollup's rows alone" "$(exact "SELECT * FROM r_hourly")" "$vb"
load 38301 39100 "2026-03-17 00:00:00+00"
check_num "after a rebase the next refresh folds exactly the appended rows" \
	"$(q "SELECT pgcolumnar.refresh_rollup('r_hourly');")" "800"
check "and after the rebase the rollup equals a full recompute" "$(matches)" "$(oracle)"

# Phase 1 folds appends only; anything else is refused, and the rollup is untouched.
before="$(exact "SELECT * FROM r_hourly")"
check_num "the rollup holds rows before the delete" "$(at_least "$(q "SELECT count(*) FROM r_hourly;")" 1)" "1"
q "DELETE FROM src WHERE dev = 3 AND ts < '2026-03-01 06:00:00+00';" >/dev/null
check "a refresh after a delete is refused until phase 2" \
	"$(sqlstate "SELECT pgcolumnar.refresh_rollup('r_hourly');")" "0A000"
check "and the refused refresh changed nothing" "$(exact "SELECT * FROM r_hourly")" "$before"

# Refused at creation.
# Each new group is read through a TID range built from its row numbers. The
# mapping is the access method's (row_tid, in C), not restated in SQL: 291 rows
# per block holds only at the default block size (#1319 review). Every group's
# range must hold exactly its rows.
check "each row group's TID range holds exactly that group's rows" \
	"$(q "SELECT count(*) FILTER (WHERE got <> want) || '|' || count(*) FROM (
	        SELECT g.row_count - g.deleted_count AS want,
	               (SELECT count(*) FROM src WHERE ctid >= pgcolumnar.row_tid(g.first_row_number)
	                  AND ctid <= pgcolumnar.row_tid(g.first_row_number + g.row_count - 1)) AS got
	          FROM pgcolumnar.rollup_source_groups('src') g) x;")" \
	"0|$(q "SELECT count(*) FROM pgcolumnar.row_group WHERE storage_id = pgcolumnar.get_storage_id('src');")"

# NULL group keys and NULL timestamps: the fold matches keys with IS NOT DISTINCT
# FROM, and a NULL ts is a NULL bucket. Measured right by @jdatcmd on #1319; an
# = in place of IS NOT DISTINCT FROM would duplicate the NULL partials.
q "CREATE TABLE nk (ts timestamptz, dev int, v bigint) USING pgcolumnar;
   SELECT pgcolumnar.set_options('nk', stripe_row_limit => 1000);
   INSERT INTO nk SELECT CASE WHEN g % 11 = 0 THEN NULL ELSE '2026-06-01'::timestamptz + g * interval '61 s' END,
          CASE WHEN g % 7 = 0 THEN NULL ELSE g % 5 END, g FROM generate_series(1, 3000) g;" >/dev/null
q "SELECT pgcolumnar.create_rollup('r_nk', 'nk', 'ts', '1 hour', '$ORIGIN', '{dev}', '{count,sum,min,max}', '{*,v,v,v}');
   SELECT pgcolumnar.refresh_rollup('r_nk');" >/dev/null
q "INSERT INTO nk SELECT CASE WHEN g % 11 = 0 THEN NULL ELSE '2026-06-01'::timestamptz + g * interval '61 s' END,
          CASE WHEN g % 7 = 0 THEN NULL ELSE g % 5 END, g FROM generate_series(3001, 4500) g;" >/dev/null
check_num "the second refresh of the NULL-key rollup folded the append" "$(q "SELECT pgcolumnar.refresh_rollup('r_nk');")" "1500"
NKR="SELECT date_bin('1 hour', ts, '$ORIGIN') AS bucket, dev, count(*) AS count, sum(v)::numeric AS sum_v,
     min(v) AS min_v, max(v) AS max_v FROM nk GROUP BY 1, 2"
check "a rollup with NULL keys and NULL timestamps equals a full recompute" \
	"$(exact "SELECT * FROM r_nk")|$(q "SELECT count(*) FROM r_nk WHERE dev IS NULL;") $(q "SELECT count(*) FROM r_nk WHERE bucket IS NULL;")" \
	"$(exact "$NKR")|$(q "SELECT count(*) FROM ($NKR) z WHERE dev IS NULL;") $(q "SELECT count(*) FROM ($NKR) z WHERE bucket IS NULL;")"
check_num "premise: and the fixture has NULL-key and NULL-bucket groups" \
	"$(at_least "$(q "SELECT count(*) FROM ($NKR) z WHERE dev IS NULL OR bucket IS NULL;")" 2)" "2"

# Retention keeps history (owner's decision on #1294 point 2): groups that expire
# retires are recorded in pgcolumnar.retired_group (#1314), and a refresh drops
# them from its snapshot without touching their buckets. Any other missing group
# is still refused (the delete arm above).
q "CREATE TABLE hist (ts timestamptz, v int) USING pgcolumnar;
   SELECT pgcolumnar.set_options('hist', stripe_row_limit => 1000);
   INSERT INTO hist SELECT now() - interval '200 days' + g * interval '1 min', g FROM generate_series(1, 3000) g;
   INSERT INTO hist SELECT now() - interval '1 day' + g * interval '10 s', g FROM generate_series(1, 2000) g;" >/dev/null
q "SELECT pgcolumnar.create_rollup('r_hist', 'hist', 'ts', '1 day', '$ORIGIN', '{}', '{count,sum}', '{*,v}');" >/dev/null
check_num "the history rollup folded every row" "$(q "SELECT pgcolumnar.refresh_rollup('r_hist');")" "5000"
hb="$(q "SELECT md5(string_agg(bucket || ':' || count || ':' || sum_v, ',' ORDER BY bucket)) FROM r_hist;")"
ob="$(q "SELECT count(*) FROM r_hist WHERE bucket < now() - interval '100 days';")"
check_num "the history rollup holds old buckets" "$(at_least "${ob:-0}" 1)" "1"
q "SELECT pgcolumnar.set_options('hist', ttl_column => 'ts', ttl_interval => '30 days');" >/dev/null
retired="$(q "SELECT pgcolumnar.expire('hist');")"
check_num "premise: expire retired the old row groups" "$(at_least "${retired:-0}" 1)" "1"
check "a refresh after retention folds nothing, refuses nothing, and keeps every bucket" \
	"$(sqlstate_or "SELECT pgcolumnar.refresh_rollup('r_hist');")|$(q "SELECT md5(string_agg(bucket || ':' || count || ':' || sum_v, ',' ORDER BY bucket)) FROM r_hist;")" \
	"0|$hb"
q "INSERT INTO hist SELECT now() - interval '2 hours' + g * interval '1 s', g FROM generate_series(1, 500) g;" >/dev/null
check_num "and after retention an append still folds" "$(q "SELECT pgcolumnar.refresh_rollup('r_hist');")" "500"
check "and the recent buckets equal a recompute, while the expired ones keep their history" \
	"$(q "SELECT md5(string_agg(bucket || ':' || count || ':' || sum_v, ',' ORDER BY bucket)) FROM r_hist WHERE bucket >= now() - interval '30 days';")|$(q "SELECT count(*) FROM r_hist WHERE bucket < now() - interval '100 days';")" \
	"$(q "SELECT md5(string_agg(b || ':' || n || ':' || s, ',' ORDER BY b)) FROM (SELECT date_bin('1 day', ts, '$ORIGIN') b, count(*) n, sum(v)::numeric s FROM hist WHERE ts >= now() - interval '30 days' GROUP BY 1) x WHERE b >= now() - interval '30 days';")|$ob"

# Not only for superusers: a superuser bypasses row-level security, so every arm
# above ran past the policies on pgcolumnar.rollup and rollup_group. A table's
# owner can roll it up; another role sees nothing of it and cannot refresh it.
# PUBLIC has no USAGE on schema pgcolumnar (measured: 42501 for any call), so the
# roles get it as an administrator would grant it; what is then tested is the
# row-level security on the rollup catalogs.
q "CREATE ROLE ru_a; CREATE ROLE ru_b; GRANT USAGE, CREATE ON SCHEMA public TO ru_a, ru_b;
   GRANT USAGE ON SCHEMA pgcolumnar TO ru_a, ru_b;" >/dev/null
as_role() { env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -X -At \
	-v VERBOSITY=sqlstate -c "SET ROLE $1" -c "$2" 2>&1 | grep -v '^SET$' | tail -1; }
as_role ru_a "CREATE TABLE own_src (ts timestamptz, v int) USING pgcolumnar" >/dev/null
as_role ru_a "INSERT INTO own_src SELECT '2026-05-01'::timestamptz + g * interval '1 min', g FROM generate_series(1, 5000) g" >/dev/null
check "a table's owner, not a superuser, creates a rollup of it" \
	"$(as_role ru_a "SELECT pgcolumnar.create_rollup('own_r', 'own_src', 'ts', '1 day', '$ORIGIN', '{}', '{count,sum}', '{*,v}')")" "own_r"
check_num "and refreshes it" "$(as_role ru_a "SELECT pgcolumnar.refresh_rollup('own_r')")" "5000"
check "and reads what a recompute gives" \
	"$(as_role ru_a "SELECT string_agg(bucket || ':' || count || ':' || sum_v, ' ' ORDER BY bucket) FROM own_r")" \
	"$(q "SELECT string_agg(b || ':' || n || ':' || s, ' ' ORDER BY b) FROM (SELECT date_bin('1 day', ts, '$ORIGIN') b, count(*) n, sum(v)::numeric s FROM own_src GROUP BY 1) x;")"
check "another role sees none of its rollup catalog rows" \
	"$(as_role ru_b "SELECT count(*) FROM pgcolumnar.rollup") $(as_role ru_b "SELECT count(*) FROM pgcolumnar.rollup_group")" "0 0"
# Row-level security hides the catalog row, so to that role it is no rollup at
# all (42704), which also says nothing about whether one exists.
check "and cannot refresh it" "$(as_role ru_b "SELECT pgcolumnar.refresh_rollup('public.own_r')" | sed -n 's/^ERROR: *\([0-9A-Z]\{5\}\).*/\1/p')" "42704"

# access_method: the partials need not be columnar (#1294 point 12 measures which
# serves a hot rollup better). A heap rollup folds and matches the same way.
q "SELECT pgcolumnar.create_rollup('r_heap', 'src', 'ts', '1 hour', '$ORIGIN', '{dev}', $AGGS, 'heap');" >/dev/null
check "a rollup kept in a heap table refreshes and equals a full recompute" \
	"$(q "SELECT a.amname FROM pg_class c JOIN pg_am a ON a.oid = c.relam WHERE c.oid = 'r_heap__partials'::regclass;")|$(q "SELECT pgcolumnar.refresh_rollup('r_heap') > 0;")|$(exact "SELECT * FROM r_heap")" \
	"heap|t|$(exact "$RECOMPUTE")"

# REPEATABLE READ: the caller's snapshot would predate the refresh's lock, and a
# refresh that waited for another would fold the same groups again.
check "a refresh at REPEATABLE READ is refused" \
	"$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -X -At \
	   -v VERBOSITY=sqlstate -c "BEGIN ISOLATION LEVEL REPEATABLE READ" \
	   -c "SELECT pgcolumnar.refresh_rollup('r_utc')" -c "ROLLBACK" 2>&1 |
	   sed -n 's/^ERROR: *\([0-9A-Z]\{5\}\).*/\1/p' | head -1)" "25000"

# Refused at creation, each with 22023: the aggregates are structured input
# checked against the five that combine, never SQL text (#1294 point 11).
refused_create() { sqlstate "SELECT pgcolumnar.create_rollup('$1', 'src', 'ts', '$2', '$ORIGIN', '{}', '$3', '$4');"; }
check "a width with months is refused" "$(refused_create r_m '1 month' '{count}' '{*}')" "22023"
check "an aggregate that does not combine is refused" "$(refused_create r_p '1 hour' '{median}' '{v}')" "22023"
# More columns than functions: a shorter columns array would be caught by the
# column check instead, and the arm would not see this check go.
check "aggregate functions and columns of different lengths are refused" \
	"$(refused_create r_l '1 hour' '{count}' '{*,v}')" "22023"
# Under min: under sum the "cannot be folded" check would catch it first.
check "an aggregate column the source does not have is refused" \
	"$(refused_create r_c '1 hour' '{min}' '{nosuch}')" "22023"
check "* with anything but count is refused" "$(refused_create r_s '1 hour' '{sum}' '{*}')" "22023"
# An arm, not a premise: with a refusal removed, the create succeeds and leaves a
# table (the months-check mutation did), so a repository change reddens it.
check_num "and no refused rollup left a table behind" \
	"$(q "SELECT count(*) FROM pg_class WHERE relname IN ('r_m', 'r_p', 'r_l', 'r_c', 'r_s');")" "0"

pgc_summary
