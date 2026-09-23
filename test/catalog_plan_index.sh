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

pgc_summary
