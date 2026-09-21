#!/usr/bin/env bash
#
# pgColumnar: a base scan must not be priced from sibling projection pages.
#
# Projections share the relation's main fork. relation_estimate_size reports
# smgrnblocks of that file as rel->pages, so a scan of the BASE storage is
# charged for every projection stored beside it. Adding a covering projection
# does not make the base scan read more bytes; the planner must not quote it
# as if it did.
#
# This suite pins the PLANNER number, not a runtime. Independent of
# test/pytest/test_base_scan_io.py: same public seam (EXPLAIN cost of a base
# scan before and after a sibling projection lands), own fixture, own
# observations.
#
# Usage:  test/base_scan_io.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/lib/postgresql/18/bin/pg_config}"

N=20000
psql_run "CREATE TABLE bsio (nid int, blob text) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('bsio', stripe_row_limit => 1000, chunk_group_row_limit => 250);"
psql_run "INSERT INTO bsio SELECT nid, repeat('p', 850) FROM generate_series(1, $N) nid ORDER BY md5(nid::text);"
psql_run "ANALYZE bsio;"

explain_base() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq \
		-c "SET max_parallel_workers_per_gather = 0;" \
		-c "SET pgcolumnar.enable_ungrouped_vector_agg = off;" \
		-c "SET pgcolumnar.enable_group_vectorization = off;" \
		-c "SET jit = off;" \
		-c "SET seq_page_cost = 1000;" \
		-c "SET cpu_tuple_cost = 0;" \
		-c "SET cpu_operator_cost = 0;" \
		-c "SET cpu_index_tuple_cost = 0;" \
		-c "SET pgcolumnar.enable_projection_scan = off;" \
		-c "EXPLAIN (COSTS ON) $1" \
		| grep -v '^SET$'
}

scan_cost_pair() {
	echo "$1" | grep -F "Custom Scan (PgColumnarScan)" | head -1 \
		| grep -oE "cost=[0-9.]+\.\.[0-9.]+" | head -1 \
		| sed -E "s/cost=([0-9.]+)\\.\\.([0-9.]+)/\\1 \\2/"
}

run_of() {
	local pair start total
	pair="$(scan_cost_pair "$1")"
	start="${pair%% *}"
	total="${pair##* }"
	awk -v t="$total" -v s="$start" "BEGIN{ print t-s }"
}

SQL="SELECT nid, blob FROM bsio"
before_plan="$(explain_base "$SQL")"
before_run="$(run_of "$before_plan")"
before_bytes="$(q "SELECT pg_relation_size('bsio')")"

check "premise: the table holds every inserted row" \
	"$(q "SELECT count(*) FROM bsio")" "$N"

check "premise: the plan is a base columnar scan" \
	"$(echo "$before_plan" | grep -c 'Custom Scan (PgColumnarScan)')" "1"

check "premise: the base scan does not name a covering projection" \
	"$(echo "$before_plan" | grep -c 'Columnar Projection:')" "0"

check "premise: the base scan has a positive run cost" \
	"$(awk -v c="$before_run" "BEGIN{ print (c>0) ? \"yes\" : \"no\" }")" "yes"

psql_run "SELECT pgcolumnar.add_projection('bsio', 'bynid', ARRAY['nid','blob'], ARRAY['nid']);"

after_bytes="$(q "SELECT pg_relation_size('bsio')")"
after_plan="$(explain_base "$SQL")"
after_run="$(run_of "$after_plan")"
ratio="$(awk -v a="$after_run" -v b="$before_run" "BEGIN{ if (b<=0) print 0; else printf \"%.3f\", a/b }")"

echo "-- before_run=$before_run after_run=$after_run ratio=$ratio"
echo "-- before_bytes=$before_bytes after_bytes=$after_bytes"

check "premise: a covering projection exists" \
	"$(q "SELECT count(*) FROM pgcolumnar.projection_declaration WHERE rel = 'bsio'::regclass AND name = 'bynid'")" "1"

# Without this, a pass could mean the projection wrote nothing and both
# formulae agree because the file did not grow.
check "premise: adding the projection enlarged the relation file" \
	"$(awk -v a="$after_bytes" -v b="$before_bytes" "BEGIN{ print (b>0 && a > b*1.3) ? \"grew\" : \"stayed before=\" b \" after=\" a }")" \
	"grew"

check "premise: the later plan is still a base columnar scan" \
	"$(echo "$after_plan" | grep -c 'Custom Scan (PgColumnarScan)')" "1"

check "premise: the later plan still does not name a covering projection" \
	"$(echo "$after_plan" | grep -c 'Columnar Projection:')" "0"

# Unfixed: after_run tracks the whole file, so ratio is about the size jump.
# Fixed: the base scan still charges the base storage, so ratio stays near 1.
check "a base scan is not priced from sibling projection pages" \
	"$(awk -v r="$ratio" "BEGIN{ print (r+0 > 1.25) ? \"inflated ratio=\" r : \"stable\" }")" \
	"stable"

pgc_summary
