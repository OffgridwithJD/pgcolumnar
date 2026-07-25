#!/usr/bin/env bash
#
# pgColumnar native zone-map-only aggregates (Phase D5b): an ungrouped, unfiltered
# aggregate over a native-format (PGCN v1) table is answered from the whole-chunk
# zone maps without reading any data pages (native spec 7.1): count(*) from row
# counts, count(col) from value_count, sum/avg(int2,int4) from the zone sum, and
# min/max from the zone min/max. This suite proves the answers equal a heap oracle
# across the supported aggregates, nulls and an empty table; that the metadata path
# is actually taken (EXPLAIN shows the ColumnarAgg node with no data scan); and
# that a filtered or unsupported aggregate falls back and is still correct.
#
# Usage:  test/native_agg.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# id int4 monotonic no nulls; s int4 with nulls; k bigint; label text. Several row
# groups so the aggregate folds across many whole-chunk zone maps.
GEN="SELECT g,
       CASE WHEN g % 5 = 0 THEN NULL ELSE g % 1000 END,
       (g * 7)::bigint,
       'lbl-' || (g % 40)
  FROM generate_series(1, 10000) g"

psql_run "CREATE TABLE h (id int, s int, k bigint, label text);"
psql_run "CREATE TABLE n (id int, s int, k bigint, label text) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.alter_columnar_table_set('n', stripe_row_limit => 2048, chunk_group_row_limit => 1024);"
psql_run "INSERT INTO h $GEN;"
psql_run "INSERT INTO n $GEN;"

# EXPLAIN plan text for a query.
plan() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "EXPLAIN (COSTS OFF) $1" 2>/dev/null
}
# The metadata aggregate path reports "Columnar Vectorized Aggregates: N" and has
# no separate Aggregate node above a scan; a fallback plan has an Aggregate node
# and no such line.
has_aggnode() { echo "$1" | grep -q 'Columnar Vectorized Aggregates' && echo yes || echo no; }
has_gather() { echo "$1" | grep -q 'Gather' && echo yes || echo no; }

# Same, with a parallel plan available: workers allowed, no setup charge, and no
# minimum table size, since the suite runs with max_parallel_workers_per_gather=0
# and a fixture of a few pages, so without this a plan-choice check would never
# see the alternative it is about.
#
# parallel_tuple_cost keeps its default on purpose. Zeroing it makes a Gather of
# raw rows look free, which makes that Gather the cheapest scan path, and the
# cost this check exists to catch was inherited from the cheapest scan path. With
# the charge zeroed the wrong costing still picks the right plan and the check
# passes for a reason that has nothing to do with the fix.
plan_par() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "SET max_parallel_workers_per_gather = 4;
		SET parallel_setup_cost = 0;
		SET min_parallel_table_scan_size = 0;
		EXPLAIN (COSTS OFF) $1" 2>/dev/null
}

# Supported aggregates answered from zone maps must equal the heap oracle.
check "count(*)"          "$(q 'SELECT count(*) FROM n;')"        "$(q 'SELECT count(*) FROM h;')"
check "count(col,nulls)"  "$(q 'SELECT count(s) FROM n;')"       "$(q 'SELECT count(s) FROM h;')"
check "sum(int4)"         "$(q 'SELECT sum(id) FROM n;')"        "$(q 'SELECT sum(id) FROM h;')"
check "sum(int4,nulls)"   "$(q 'SELECT sum(s) FROM n;')"         "$(q 'SELECT sum(s) FROM h;')"
check "avg(int4,nulls)"   "$(q 'SELECT avg(s) FROM n;')"         "$(q 'SELECT avg(s) FROM h;')"
check "min(int4)"         "$(q 'SELECT min(id) FROM n;')"        "$(q 'SELECT min(id) FROM h;')"
check "max(int4)"         "$(q 'SELECT max(id) FROM n;')"        "$(q 'SELECT max(id) FROM h;')"
check "min(int4,nulls)"   "$(q 'SELECT min(s) FROM n;')"         "$(q 'SELECT min(s) FROM h;')"
check "min(text)"         "$(q 'SELECT min(label) FROM n;')"     "$(q 'SELECT min(label) FROM h;')"
check "max(text)"         "$(q 'SELECT max(label) FROM n;')"     "$(q 'SELECT max(label) FROM h;')"
check "multi-agg"         "$(q 'SELECT count(*), sum(id), min(id), max(id) FROM n;')" \
                          "$(q 'SELECT count(*), sum(id), min(id), max(id) FROM h;')"

# The metadata path is actually taken (ColumnarAgg node, no underlying scan).
check "count(*) uses metadata agg node" "$(has_aggnode "$(plan 'SELECT count(*) FROM n')")" "yes"
check "sum/min/max uses metadata agg node" \
	"$(has_aggnode "$(plan 'SELECT sum(id), min(id), max(id) FROM n')")" "yes"

# The path has to win on cost, not only exist. It reads one metadata entry per
# row group; Gather over Partial Aggregate reads the whole table. Costing this
# path at the scan's cost let the parallel plan take work the catalog already
# has (issue #133), so pin the plan the planner picks once a parallel one is on
# the table.
par_count="$(plan_par 'SELECT count(*) FROM n')"
check "count(*) beats a parallel plan"  "$(has_aggnode "$par_count")" "yes"
check "count(*) plan has no Gather"     "$(has_gather "$par_count")"  "no"
par_multi="$(plan_par 'SELECT count(*), sum(id), min(id), max(id) FROM n')"
check "multi-agg beats a parallel plan" "$(has_aggnode "$par_multi")" "yes"
check "multi-agg plan has no Gather"    "$(has_gather "$par_multi")"  "no"

# count(*) is answered from each row group's stored row count, so it has no
# reason to read zone maps at all. Reading them costs one catalog lookup per row
# group returning an entry for every column, and on a 6,000,000-row table that
# was the entire cost of the query (issue #133). Count the scans of
# pgcolumnar.zone_map across the statement: each q is its own backend, and a
# backend flushes its statistics when it exits, so the counter is settled by the
# time the next one reads it.
zm_scans() {
	q "SELECT coalesce(idx_scan, 0) + coalesce(seq_scan, 0)
	     FROM pg_stat_all_tables WHERE relid = 'pgcolumnar.zone_map'::regclass;"
}
zm_before="$(zm_scans)"; q 'SELECT count(*) FROM n;' >/dev/null; zm_after="$(zm_scans)"
check "count(*) reads no zone maps" "$((zm_after - zm_before))" "0"

# The same measurement the other way round, so the check above cannot pass just
# because the counter never moves.
zm_before="$(zm_scans)"; q 'SELECT count(*), sum(id) FROM n;' >/dev/null; zm_after="$(zm_scans)"
check "an aggregate that needs zone maps reads them" \
	"$([ "$((zm_after - zm_before))" -gt 0 ] && echo yes || echo no)" "yes"

# A filtered aggregate falls back (no zone-map answer) but is still correct.
check "filtered aggregate parity" \
	"$(q 'SELECT count(*), sum(id) FROM n WHERE id > 5000;')" \
	"$(q 'SELECT count(*), sum(id) FROM h WHERE id > 5000;')"
check "filtered aggregate not metadata node" \
	"$(has_aggnode "$(plan 'SELECT count(*), sum(id) FROM n WHERE id > 5000')")" "no"

# An unsupported aggregate (sum on bigint) falls back and is still correct.
check "sum(bigint) fallback parity" "$(q 'SELECT sum(k) FROM n;')" "$(q 'SELECT sum(k) FROM h;')"

# Empty native table: count 0, sum/min/max NULL, exactly as SQL.
psql_run "CREATE TABLE e (id int, label text) USING pgcolumnar;"
check "empty count(*)"  "$(q 'SELECT count(*) FROM e;')"                 "0"
check "empty sum NULL"  "$(q 'SELECT sum(id) IS NULL FROM e;')"          "t"
check "empty min NULL"  "$(q 'SELECT min(label) IS NULL FROM e;')"       "t"

pgc_summary
