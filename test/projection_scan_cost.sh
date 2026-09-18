#!/usr/bin/env bash
#
# pgColumnar: a covering projection scan must not be priced at half the base.
#
# PgColumnarSetRelPathlist offers a covering-projection path by taking the
# base custom-scan run cost and multiplying by 0.5. That constant does not
# depend on the restriction, so a 5% range on the sort key is quoted the
# same as a 50% range. The projection is stored sorted on that key; the
# planner number has to move with selectivity, the way zone-map survival
# already does for the base scan.
#
# This suite pins the PLANNER number, not a runtime. Independent of
# test/pytest/test_projection_scan_cost.py: same public seam (EXPLAIN of a
# columnar scan with and without pgcolumnar.enable_projection_scan), own
# fixture, own observations.
#
# Usage:  test/projection_scan_cost.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/lib/postgresql/18/bin/pg_config}"

N=20000
TIGHT_HI=1000
LOOSE_HI=10000
psql_run "CREATE TABLE prsc (k int, payload text) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('prsc', stripe_row_limit => 1000, chunk_group_row_limit => 500);"
# Physical order is scrambled so the BASE scan cannot prune on k. The
# covering projection is stored sorted on k, which is the only reason it
# should be cheaper than the base for a range on k.
psql_run "INSERT INTO prsc SELECT k, repeat('x', 64) FROM generate_series(1, $N) k ORDER BY md5(k::text);"
psql_run "SELECT pgcolumnar.add_projection('prsc', 'byk', ARRAY['k'], ARRAY['k']);"
psql_run "ANALYZE prsc;"

explain_scan() {
	# $1 = on|off for pgcolumnar.enable_projection_scan
	# $2 = SQL
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq \
		-c "SET max_parallel_workers_per_gather = 0;" \
		-c "SET pgcolumnar.enable_ungrouped_vector_agg = off;" \
		-c "SET pgcolumnar.enable_group_vectorization = off;" \
		-c "SET jit = off;" \
		-c "SET pgcolumnar.enable_projection_scan = $1;" \
		-c "EXPLAIN (COSTS ON) $2" \
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

SQL_TIGHT="SELECT k FROM prsc WHERE k BETWEEN 1 AND $TIGHT_HI"
SQL_LOOSE="SELECT k FROM prsc WHERE k BETWEEN 1 AND $LOOSE_HI"

tight_proj="$(explain_scan on "$SQL_TIGHT")"
loose_proj="$(explain_scan on "$SQL_LOOSE")"
tight_base="$(explain_scan off "$SQL_TIGHT")"
loose_base="$(explain_scan off "$SQL_LOOSE")"

t_proj_run="$(run_of "$tight_proj")"
l_proj_run="$(run_of "$loose_proj")"
t_base_run="$(run_of "$tight_base")"
l_base_run="$(run_of "$loose_base")"

t_ratio="$(awk -v p="$t_proj_run" -v b="$t_base_run" "BEGIN{ if (b<=0) print 0; else printf \"%.3f\", p/b }")"
l_ratio="$(awk -v p="$l_proj_run" -v b="$l_base_run" "BEGIN{ if (b<=0) print 0; else printf \"%.3f\", p/b }")"

echo "-- tight proj_run=$t_proj_run base_run=$t_base_run ratio=$t_ratio"
echo "-- loose proj_run=$l_proj_run base_run=$l_base_run ratio=$l_ratio"

check "premise: the table holds every inserted row" \
	"$(q "SELECT count(*) FROM prsc")" "$N"

check "premise: a covering projection exists" \
	"$(q "SELECT count(*) FROM pgcolumnar.projection_declaration WHERE rel = 'prsc'::regclass AND name = 'byk'")" "1"

check "premise: the tight plan uses the covering projection" \
	"$(echo "$tight_proj" | grep -c 'Columnar Projection: byk')" "1"

check "premise: the loose plan uses the covering projection" \
	"$(echo "$loose_proj" | grep -c 'Columnar Projection: byk')" "1"

check "premise: without the projection scan, the tight plan is a base columnar scan" \
	"$(echo "$tight_base" | grep -c 'Columnar Projection')" "0"

check "premise: without the projection scan, the loose plan is a base columnar scan" \
	"$(echo "$loose_base" | grep -c 'Columnar Projection')" "0"

check "premise: every compared scan has a positive run cost" \
	"$(awk -v a="$t_proj_run" -v b="$t_base_run" -v c="$l_proj_run" -v d="$l_base_run" \
		"BEGIN{ print (a>0 && b>0 && c>0 && d>0) ? \"yes\" : \"no\" }")" "yes"

# The unfixed path multiplies the whole run by 0.5, so both ratios are 0.500.
# A constant other than 0.5 can dodge the "both halved" pin; it cannot make
# a 5% range cheaper relative to the base than a 50% range.
check "a tight covering projection is cheaper relative to the base than a loose one" \
	"$(awk -v t="$t_ratio" -v l="$l_ratio" "BEGIN{ print (t < l) ? \"tighter\" : \"not\" }")" \
	"tighter"

check "tight and loose covering scans are not both priced at half the base" \
	"$(awk -v t="$t_ratio" -v l="$l_ratio" "BEGIN{
		both = (t>0.45 && t<0.55 && l>0.45 && l<0.55);
		print both ? \"both-halved\" : \"scaled\"
	}")" "scaled"


# The projection prunes only on its sort key. A query whose selectivity comes
# from a different column must not be priced as if the sort order produced
# that selectivity. Own table, own N, own column names; not derived from the
# pytest twin.
N_ATTR=20000
psql_run "CREATE TABLE prsk (sk int, kind text) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('prsk', stripe_row_limit => 1000, chunk_group_row_limit => 500);"
psql_run "INSERT INTO prsk SELECT sk, CASE WHEN sk % 1000 = 0 THEN 'odd' ELSE 'usual' END FROM generate_series(1, $N_ATTR) sk ORDER BY md5(sk::text);"
psql_run "SELECT pgcolumnar.add_projection('prsk', 'onsk', ARRAY['sk','kind'], ARRAY['sk']);"
psql_run "ANALYZE prsk;"

SQL_MIS="SELECT sk FROM prsk WHERE sk BETWEEN 1 AND $N_ATTR AND kind = 'odd'"
mis_proj="$(explain_scan on "$SQL_MIS")"
mis_base="$(explain_scan off "$SQL_MIS")"
m_proj_run="$(run_of "$mis_proj")"
m_base_run="$(run_of "$mis_base")"
m_ratio="$(awk -v p="$m_proj_run" -v b="$m_base_run" "BEGIN{ if (b<=0) print 0; else printf \"%.3f\", p/b }")"
echo "-- misattr proj_run=$m_proj_run base_run=$m_base_run ratio=$m_ratio"

check "premise: the misattributed query has a covering projection" \
	"$(q "SELECT count(*) FROM pgcolumnar.projection_declaration WHERE rel = 'prsk'::regclass AND name = 'onsk'")" "1"

check "premise: every misattributed scan has a positive run cost" \
	"$(awk -v a="$m_proj_run" -v b="$m_base_run" "BEGIN{ print (a>0 && b>0) ? \"yes\" : \"no\" }")" "yes"

# rel->rows after every restriction makes this cheap (one-stripe floor over
# heap survival on kind). The sort key is the whole table, so the ratio
# has to sit with the base.
check "a non-sort-key restriction does not cheapen a covering projection" \
	"$(awk -v r="$m_ratio" "BEGIN{ print (r+0 >= 0.8) ? \"not-cheap\" : \"cheap\" }")" \
	"not-cheap"

pgc_summary
