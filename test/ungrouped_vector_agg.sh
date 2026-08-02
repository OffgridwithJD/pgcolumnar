#!/usr/bin/env bash
#
# pgColumnar ungrouped vectorized aggregate (#289).
#
# pgcolumnar.enable_ungrouped_vector_agg routes an ungrouped aggregate that a
# zone map cannot answer -- one with a WHERE filter, or sum/avg over
# int8/float/numeric -- to a single-pass scan-fold node instead of the row-wise
# core Agg. This suite proves the new path returns byte-for-byte what core Agg
# returns (the fold reuses columnar_apply_one in scan order, so floats match
# exactly), across types, nulls, filters, empty and all-null inputs; and it
# ASSERTS THE PREMISE that the new path actually runs with the GUC on and does
# not with it off, so the A/B is never vacuous.
#
# Usage:  test/ungrouped_vector_agg.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

GUC=pgcolumnar.enable_ungrouped_vector_agg

# Pin serial execution in both arms. The new node is serial; a parallel core Agg
# would sum floats in a different order, so an unpinned oracle could differ from
# the serial fold by float reassociation -- a test artifact, not a code defect.
NOPAR="SET max_parallel_workers_per_gather=0"

# run a scalar query and echo its value, at a given setting of the new GUC
val() {  # val <on|off> <sql>
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq -c "$NOPAR" -c "SET $GUC=$1" -c "$2" 2>&1
}
# echo the plan text at a given setting
plan() {  # plan <on|off> <sql>
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq -c "$NOPAR" -c "SET $GUC=$1" -c "EXPLAIN (COSTS OFF) $2" 2>&1
}
# oracle A/B: the new path (on) must equal core Agg (off), byte for byte
ab() {  # ab <label> <sql>
	local off on
	off="$(val off "$2")"
	on="$(val on "$2")"
	check "$1 :: on==off ($on)" "$on" "$off"
}

# A columnar table with a filter column (k), the four sum/avg input types, nulls
# scattered, and float values spanning magnitudes so any reassociation would show.
psql_run "DROP TABLE IF EXISTS t;
          CREATE TABLE t (id int, k int, i4 int, i8 bigint, v float8, n numeric, txt text)
              USING pgcolumnar;
          SELECT pgcolumnar.set_options('t'::regclass, stripe_row_limit => 2000);
          INSERT INTO t
          SELECT g,
                 g % 1000,
                 (g % 7) - 3,
                 (g::bigint * 1000003),
                 CASE WHEN g % 50 = 0 THEN NULL
                      ELSE ((g % 13) - 6)::float8 * (10.0 ^ (g % 5)) END,
                 CASE WHEN g % 37 = 0 THEN NULL ELSE (g % 100)::numeric / 7 END,
                 'r' || g
          FROM generate_series(1, 60000) g;" >/dev/null

# ---- premise: the new path runs with the GUC on, and not with it off --------
P_ON="$(plan on  "SELECT count(*), sum(v), avg(v) FROM t WHERE v > 0")"
P_OFF="$(plan off "SELECT count(*), sum(v), avg(v) FROM t WHERE v > 0")"
check "premise: vectorized agg node used when GUC on" \
	"$(printf '%s' "$P_ON"  | grep -qi 'Columnar Vectorized Aggregates' && echo yes || echo no)" yes
check "premise: core Agg (no vectorized node) when GUC off" \
	"$(printf '%s' "$P_OFF" | grep -qi 'Columnar Vectorized Aggregates' && echo yes || echo no)" no
check "premise: the filter is pushed into the scan (EXPLAIN shows it)" \
	"$(printf '%s' "$P_ON"  | grep -qi 'Columnar Pushed-Down Filters' && echo yes || echo no)" yes

# ---- filtered aggregates over each type (the q6 shape) -----------------------
ab "filtered float sum"        "SELECT sum(v)::text            FROM t WHERE k > 500"
ab "filtered float avg"        "SELECT avg(v)::text            FROM t WHERE k > 500"
ab "q6-like count+avg filter"  "SELECT count(*)||'/'||coalesce(avg(v)::text,'z') FROM t WHERE v > 0"
ab "filtered int8 sum"         "SELECT sum(i8)::text           FROM t WHERE k < 250"
ab "filtered int8 avg"         "SELECT avg(i8)::text           FROM t WHERE k < 250"
ab "filtered numeric sum"      "SELECT sum(n)::text            FROM t WHERE k <> 3"
ab "filtered numeric avg"      "SELECT avg(n)::text            FROM t WHERE k <> 3"
ab "filtered int sum/avg/cnt"  "SELECT sum(i4)||'/'||avg(i4)::text||'/'||count(i4) FROM t WHERE k >= 100"
ab "filtered min/max float"    "SELECT coalesce(min(v)::text,'z')||'/'||coalesce(max(v)::text,'z') FROM t WHERE k > 900"
ab "filtered count(*)"         "SELECT count(*)               FROM t WHERE k BETWEEN 100 AND 200"

# ---- extended aggregates with NO filter (scan-fold via the type, not a qual) -
ab "unfiltered int8 sum"       "SELECT sum(i8)::text           FROM t"
ab "unfiltered float sum"      "SELECT sum(v)::text            FROM t"
ab "unfiltered float avg"      "SELECT avg(v)::text            FROM t"
ab "unfiltered numeric avg"    "SELECT avg(n)::text            FROM t"

# ---- adversarial: nulls, empty result, all-null column ----------------------
ab "all rows filtered out"     "SELECT count(*)||'/'||coalesce(sum(v)::text,'z')||'/'||coalesce(avg(v)::text,'z') FROM t WHERE k > 100000"
ab "avg over a null-heavy col" "SELECT coalesce(avg(v)::text,'z') FROM t WHERE k % 50 = 0"
psql_run "DROP TABLE IF EXISTS t_allnull;
          CREATE TABLE t_allnull (id int, k int, v float8) USING pgcolumnar;
          INSERT INTO t_allnull SELECT g, g%10, NULL FROM generate_series(1,5000) g;" >/dev/null
check "all-null float sum on==off" \
	"$(val on  "SELECT coalesce(sum(v)::text,'NULL') FROM t_allnull WHERE k > 2")" \
	"$(val off "SELECT coalesce(sum(v)::text,'NULL') FROM t_allnull WHERE k > 2")"
check "all-null float avg on==off" \
	"$(val on  "SELECT coalesce(avg(v)::text,'NULL') FROM t_allnull WHERE k > 2")" \
	"$(val off "SELECT coalesce(avg(v)::text,'NULL') FROM t_allnull WHERE k > 2")"

# ---- the metadata path (no filter, zone-map answerable) is unchanged ---------
ab "count(*) no filter (metadata)"  "SELECT count(*)      FROM t"
ab "min/max no filter (metadata)"   "SELECT min(v)::text||'/'||max(v)::text FROM t"
ab "sum(int4) no filter (metadata)" "SELECT sum(i4)::text FROM t"

# ---- a delete makes a group dirty; the filtered scan must still match --------
psql_run "DELETE FROM t WHERE id IN (5, 2005, 40001)" >/dev/null
ab "filtered avg after deletes"     "SELECT coalesce(avg(v)::text,'z') FROM t WHERE k > 500"
ab "count(*) filter after deletes"  "SELECT count(*) FROM t WHERE k > 500"

check "server still up" "$(q "SELECT 1")" 1
pgc_summary
