#!/usr/bin/env bash
#
# Planning a columnar query must probe pgcolumnar.options and
# pgcolumnar.projection through their primary keys.
#
# options_pkey is (regclass) and projection_pkey is (storage_id,
# projection_id). The planner looks options up by regclass and projections
# up by storage_id, and both scans passed InvalidOid, so every plan
# sequentially scanned those catalogs. A database with many columnar
# tables pays that on a query that touches one of them.
#
# After one filtered scan of this suite's own table, pg_stat_all_tables
# must show idx_scan > 0 and seq_scan = 0 for both catalogs. The filtered
# scan is its own psql, so the session that wrote the rows is not the
# session being measured.
#
# Usage:  test/catalog_plan_index.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null

# Other columnar tables sit in the same catalogs. A sequential scan of
# options or projection walks their rows too; an index probe does not.
q "CREATE TABLE noise_a (id int) USING pgcolumnar;
   CREATE TABLE noise_b (id int) USING pgcolumnar;
   INSERT INTO noise_a SELECT g FROM generate_series(1,40) g;
   INSERT INTO noise_b SELECT g FROM generate_series(1,60) g;
   CREATE TABLE plan_cat (id int) USING pgcolumnar;
   INSERT INTO plan_cat SELECT g FROM generate_series(1,800) g;" >/dev/null

check_num "premise: the measured table holds its rows" \
	"$(q "SELECT count(*) FROM plan_cat;")" "800"

q "SELECT pg_stat_reset();" >/dev/null
q "SELECT count(*) FROM plan_cat WHERE id > 0;" >/dev/null
q "SELECT pg_stat_force_next_flush();" >/dev/null

check_num "premise: the filtered scan returned every row" \
	"$(q "SELECT count(*) FROM plan_cat WHERE id > 0;")" "800"

opt="$(q "SELECT coalesce(idx_scan,0)::text || ' ' || coalesce(seq_scan,0)::text
	FROM pg_stat_all_tables
	WHERE schemaname = 'pgcolumnar' AND relname = 'options';")"
opt_idx="${opt%% *}"
opt_seq="${opt##* }"
echo "-- options idx_scan=$opt_idx seq_scan=$opt_seq"
if [ "$opt_idx" -ge 1 ]; then
	opt_idx_ok=1
else
	opt_idx_ok=$opt_idx
fi
check_num "planning probed pgcolumnar.options through options_pkey" \
	"$opt_idx_ok" "1"
check_num "planning did not sequentially scan pgcolumnar.options" \
	"$opt_seq" "0"

prj="$(q "SELECT coalesce(idx_scan,0)::text || ' ' || coalesce(seq_scan,0)::text
	FROM pg_stat_all_tables
	WHERE schemaname = 'pgcolumnar' AND relname = 'projection';")"
prj_idx="${prj%% *}"
prj_seq="${prj##* }"
echo "-- projection idx_scan=$prj_idx seq_scan=$prj_seq"
if [ "$prj_idx" -ge 1 ]; then
	prj_idx_ok=1
else
	prj_idx_ok=$prj_idx
fi
check_num "planning probed pgcolumnar.projection through projection_pkey" \
	"$prj_idx_ok" "1"
check_num "planning did not sequentially scan pgcolumnar.projection" \
	"$prj_seq" "0"

# ---- and pgcolumnar.storage, through storage_pkey (#1237) -------------------
#
# Two readers key on storage_id and both passed InvalidOid, so both scanned the
# catalog sequentially on the one column storage_pkey is a UNIQUE btree over:
#
#     PgColumnarGetSortedInfo           PLANNING, via pgcolumnar_sorted_pathkeys
#     PgColumnarCheckNativeFormatVersion EXECUTION, once per relation scanned
#
# THE TWO SHAPES ARE DIFFERENT ARMS BECAUSE THEY REACH DIFFERENT CODE, and a
# single shape cannot tell them apart. Measured on the unfixed tree, scans of
# pgcolumnar.storage per planned query by shape:
#
#     count(*), no qual                  0 at planning, 1 at execution
#     qual on a plain column             1
#     qual on a column with a projection 4
#     two columnar relations, one qual   4   <- 2 limit lookups + 2 sorted lookups
#
# A `count(*)` never reaches the row-group-limit lookup, so the ONLY storage
# access it makes is the format-version one. That makes seq_scan == 0 a clean
# reading for that site and nothing else.
#
# THE JOIN IS MEASURED ON idx_scan RATHER THAN seq_scan, deliberately. Its two
# remaining sequential scans come from pgcolumnar_written_stripe_row_limit,
# which keys on relation_oid and has NO index to name -- that is #1210 and
# #1211 and is not this change. Asserting seq_scan == 0 there would fail for a
# defect this change does not claim to fix, and asserting seq_scan == 2 would
# pin a number that #1210 is expected to move.
q "CREATE TABLE plan_cat_j (id int) USING pgcolumnar;
   INSERT INTO plan_cat_j SELECT g FROM generate_series(1,800) g;" >/dev/null

storage_stat() {	# -> "idx_scan seq_scan"
	q "SELECT coalesce(idx_scan,0)::text || ' ' || coalesce(seq_scan,0)::text
		FROM pg_stat_all_tables
		WHERE schemaname = 'pgcolumnar' AND relname = 'storage';"
}

q "SELECT pg_stat_reset();" >/dev/null
q "SELECT count(*) FROM plan_cat;" >/dev/null
q "SELECT pg_stat_force_next_flush();" >/dev/null
st="$(storage_stat)"
st_idx="${st%% *}"
st_seq="${st##* }"
echo "-- storage after count(*)  idx_scan=$st_idx seq_scan=$st_seq"

check_num "premise: a no-qual count over a columnar table touched storage at all" \
	"$(if [ "$((st_idx + st_seq))" -ge 1 ]; then echo 1; else echo 0; fi)" "1"
check_num "a no-qual count did not sequentially scan pgcolumnar.storage" \
	"$st_seq" "0"

q "SELECT pg_stat_reset();" >/dev/null
q "SELECT count(*) FROM plan_cat a JOIN plan_cat_j b ON a.id = b.id WHERE a.id > 0;" >/dev/null
q "SELECT pg_stat_force_next_flush();" >/dev/null
sj="$(storage_stat)"
sj_idx="${sj%% *}"
sj_seq="${sj##* }"
echo "-- storage after a two-relation join  idx_scan=$sj_idx seq_scan=$sj_seq"

check_num "premise: the join reached storage more than once" \
	"$(if [ "$((sj_idx + sj_seq))" -ge 2 ]; then echo 1; else echo 0; fi)" "1"
check_num "planning a join probed pgcolumnar.storage through storage_pkey" \
	"$(if [ "$sj_idx" -ge 2 ]; then echo 1; else echo 0; fi)" "1"

pgc_summary
