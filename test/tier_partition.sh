#!/usr/bin/env bash
#
# pgcolumnar.tier_partition moves a cold columnar partition to Parquet, in one
# transaction, and a failure at any step leaves the rows exactly once (#1295).
#
# WRITTEN BEFORE THE CODE, against the API proposed on #1295:
#
#     pgcolumnar.tier_partition(partition regclass, server name, path text) -> rows
#
# The owner's decision (#1295, 2026-10-12): atomic, with a brief ACCESS EXCLUSIVE
# on the parent. Export under the partition's SHARE lock, then detach, drop,
# create the foreign table under the partition's own name, and attach it with the
# partition's own bounds.
#
# "EXACTLY ONCE" IS TESTED, NOT ARGUED. pgcolumnar.tier_fault_after raises an
# ERROR right after the step it names. Each fault arm first requires that the
# error raised IS the injected one: a missing function also fails, and leaves
# the rows where they were, so "the rows are still local" alone proves nothing.
#
# A local path stands in for object storage; `s3://` is the same writer with
# another path and is not exercised here.
#
# Usage:  test/tier_partition.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

W="$PGC_WORKDIR/tier"
mkdir -p "$W" && chmod 777 "$W"

# sqlstate SQL... -> the SQLSTATE the last statement fails with, or ok
sqlstate() {
	local out
	out=$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-X -At -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate "${@/#/-c}" 2>&1 >/dev/null)
	[ -z "$out" ] && { echo ok; return; }
	echo "$out" | sed -n 's/^ERROR: *\([0-9A-Z]\{5\}\).*/\1/p' | head -1
}
# errtext SQL... -> the first ERROR line's message, or ok
errtext() {
	local out
	out=$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-X -At -v ON_ERROR_STOP=1 "${@/#/-c}" 2>&1 >/dev/null)
	[ -z "$out" ] && { echo ok; return; }
	echo "$out" | sed -n 's/^ERROR: *//p' | head -1
}

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null
psql_run "CREATE SERVER tier_pq FOREIGN DATA WRAPPER pgcolumnar_parquet;"

# build NAME: a parent with a January and a February columnar partition
build() {
	psql_run "DROP TABLE IF EXISTS $1 CASCADE;"
	psql_run "CREATE TABLE $1 (ts timestamptz NOT NULL, dev int, v bigint, note text)
	          PARTITION BY RANGE (ts);"
	psql_run "CREATE TABLE ${1}_jan PARTITION OF $1
	          FOR VALUES FROM ('2026-01-01') TO ('2026-02-01') USING pgcolumnar;"
	psql_run "CREATE TABLE ${1}_feb PARTITION OF $1
	          FOR VALUES FROM ('2026-02-01') TO ('2026-03-01') USING pgcolumnar;"
	psql_run "INSERT INTO $1 SELECT '2026-01-01'::timestamptz + g * interval '5 min', g % 13,
	          (hashint4(g)::bigint * 7) % 100003, md5(g::text)
	          FROM generate_series(0, 16991) g;"
}
# every row, decoded: an unfiltered count/sum is answered from zone maps
digest() { q "SELECT count(*) || '|' || md5(string_agg(ts::text || dev || v || note, ',' ORDER BY ts)) FROM $1;"; }
# where the January range lives: relkind, access method, and its bound
jan_shape() {
	q "SELECT c.relkind::text || ':' || coalesce(a.amname, '-') || ':' || pg_get_expr(c.relpartbound, c.oid)
	   FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid LEFT JOIN pg_am a ON a.oid = c.relam
	   WHERE i.inhparent = '$1'::regclass AND c.relname = '${1}_jan';"
}
JAN_BOUND="FOR VALUES FROM ('2026-01-01 00:00:00+00') TO ('2026-02-01 00:00:00+00')"

psql_run "SET timezone = 'UTC'; ALTER DATABASE \"$PGC_DB\" SET timezone = 'UTC';"
build m
check_num "premise: the parent holds every row" "$(q "SELECT count(*) FROM m;")" "16992"
check_num "premise: January holds its share" "$(q "SELECT count(*) FROM m_jan;")" "8928"
before="$(digest m)"
check "premise: January is a local columnar partition with its bound" "$(jan_shape m)" "r:pgcolumnar:$JAN_BOUND"
jan_storage="$(q "SELECT pgcolumnar.get_storage_id('m_jan');")"

# ---- the move ---------------------------------------------------------------
check "tier_partition moves January and returns the rows it moved" \
	"$(q "SELECT pgcolumnar.tier_partition('m_jan', 'tier_pq', '$W/m_jan.parquet');")" "8928"
# The relkind rides along: with nothing moved the digest is trivially unchanged.
check "the answers over the parent are the same after the move" \
	"$(digest m)|$(q "SELECT relkind FROM pg_class WHERE oid = 'm_jan'::regclass;")" "$before|f"
check "January is now a foreign partition with its own name and bound" "$(jan_shape m)" "f:-:$JAN_BOUND"
check "the foreign partition reads the exported file" \
	"$(q "SELECT srvname || ':' || array_to_string(ftoptions, ',') FROM pg_foreign_table t
	      JOIN pg_foreign_server s ON s.oid = t.ftserver WHERE t.ftrelid = 'm_jan'::regclass;")" \
	"tier_pq:path=$W/m_jan.parquet"
check_num "the local partition leaves no pgcolumnar storage row behind" \
	"$(q "SELECT count(*) FROM pgcolumnar.storage WHERE storage_id = ${jan_storage:-0};")" "0"
check_num "premise: the storage id was read before the move" "$([ -n "$jan_storage" ] && echo 1 || echo 0)" "1"
check_num "nor any row-group row" \
	"$(q "SELECT count(*) FROM pgcolumnar.row_group WHERE storage_id = ${jan_storage:-0};")" "0"

# ---- pruning over the mixed parent ------------------------------------------
plan_jan="$(q "EXPLAIN SELECT max(v) FROM m WHERE ts < '2026-01-20';")"
plan_feb="$(q "EXPLAIN SELECT max(v) FROM m WHERE ts >= '2026-02-10';")"
check "a January query scans only the foreign partition" \
	"$(grep -c 'Foreign Scan' <<<"$plan_jan")|$(grep -c 'm_feb' <<<"$plan_jan")" "1|0"
check "a February query scans only the local partition, beside a foreign one" \
	"$(grep -c 'Foreign Scan' <<<"$plan_feb")|$(grep -c 'm_feb' <<<"$plan_feb")|$(grep -c 'Foreign Scan' <<<"$plan_jan")" "0|1|1"
check "an insert routed to the tiered range is refused" \
	"$(sqlstate "INSERT INTO m VALUES ('2026-01-15', 1, 1, 'x');")" "0A000"

# ---- refusals, before anything moves ----------------------------------------
# Measured with export_parquet on main: an existing path is overwritten without a
# word, which is why tier_partition must refuse one.
rb="$(digest m)"
psql_run "CREATE TABLE lone (ts timestamptz, v int) USING pgcolumnar;"
check "a table that is not a partition is refused" \
	"$(sqlstate "SELECT pgcolumnar.tier_partition('lone', 'tier_pq', '$W/lone.parquet');")" "42809"
psql_run "CREATE TABLE m_mar PARTITION OF m FOR VALUES FROM ('2026-03-01') TO ('2026-04-01') USING heap;"
check "a partition that is not columnar is refused" \
	"$(sqlstate "SELECT pgcolumnar.tier_partition('m_mar', 'tier_pq', '$W/m_mar.parquet');")" "42809"
psql_run "CREATE TABLE m_def PARTITION OF m DEFAULT USING pgcolumnar;"
check "a DEFAULT partition is refused" \
	"$(sqlstate "SELECT pgcolumnar.tier_partition('m_def', 'tier_pq', '$W/m_def.parquet');")" "0A000"
psql_run "CREATE SERVER tier_ice FOREIGN DATA WRAPPER pgcolumnar_iceberg;"
check "a server of another wrapper is refused" \
	"$(sqlstate "SELECT pgcolumnar.tier_partition('m_feb', 'tier_ice', '$W/m_feb.parquet');")" "42809"
check "an existing path is refused, so no file a table reads is overwritten" \
	"$(sqlstate "SELECT pgcolumnar.tier_partition('m_feb', 'tier_pq', '$W/m_jan.parquet');")" "58P02"
check "and the refusals moved nothing" "$(digest m)" "$rb"
check "premise: February is still local after the refusals" \
	"$(q "SELECT relkind FROM pg_class WHERE oid = 'm_feb'::regclass;")" "r"

# ---- the parent's lock ------------------------------------------------------
build k
kb="$(digest k)"
lock="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -X -At \
	-c "BEGIN" -c "SELECT pgcolumnar.tier_partition('k_jan', 'tier_pq', '$W/k_jan.parquet')" \
	-c "SELECT coalesce(string_agg(mode, ',' ORDER BY mode), 'none') FROM pg_locks
	    WHERE relation = 'k'::regclass AND pid = pg_backend_pid() AND granted" \
	-c "ROLLBACK" 2>&1)"
# Line 2 is the call's result: a rollback of a call that never ran proves nothing.
check "premise: inside the transaction the call moved January" "$(sed -n 2p <<<"$lock")" "8928"
check "the call holds ACCESS EXCLUSIVE on the parent until commit, as the docs say" \
	"$(grep -o 'AccessExclusiveLock' <<<"$lock")" "AccessExclusiveLock"
check "a rollback after the whole call leaves the rows local, exactly once" \
	"$(digest k)|$(jan_shape k)" "$kb|r:pgcolumnar:$JAN_BOUND"

# ---- a failure after each step ----------------------------------------------
for step in export detach drop create attach; do
	build f
	fb="$(digest f)"
	err="$(errtext "SET pgcolumnar.tier_fault_after = '$step'" \
		"SELECT pgcolumnar.tier_partition('f_jan', 'tier_pq', '$W/f_$step.parquet')")"
	check "premise: the call fails with the fault injected after $step" \
		"$(grep -o "injected fault after $step" <<<"$err" || echo "$err")" "injected fault after $step"
	check "a failure after $step leaves the rows exactly once, still local" \
		"$(digest f)|$(jan_shape f)" "$fb|r:pgcolumnar:$JAN_BOUND"
	check_num "and no foreign table behind it after $step" \
		"$(q "SELECT count(*) FROM pg_foreign_table t JOIN pg_class c ON c.oid = t.ftrelid
		      WHERE c.relname LIKE 'f\\_%';")" "0"
done

pgc_summary
