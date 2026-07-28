#!/usr/bin/env bash
#
# pgColumnar: ANALYZE must estimate the row count, not zero.
#
# A block was mapped to its row group by comparing the block's logical offset
# against the group's file_offset -- but the block's offset had
# COLUMNAR_FIRST_LOGICAL_OFFSET subtracted from it while the group's had not,
# since a group's file_offset is already absolute and the first one a table can
# have is that constant itself. Every block therefore compared two blocks low.
#
# A table whose only row group starts at the beginning matched no block at all:
#
#     INFO: "av": scanned 3 of 3 pages, containing 0 live rows ...
#     reltuples = 0        for a table holding 10,000 rows
#
# So the planner believed every columnar table smaller than one stripe was
# empty, and larger ones were short by whatever the shift dropped -- 150,000 of
# 200,000 at the default stripe size.
#
# Zero is the sharp case and it is what this file is built around: an estimate
# that is merely imprecise costs a plan, an estimate of zero costs the shape of
# every plan that joins the table.
#
# heap is the oracle. ANALYZE samples, so the columnar estimate is not required
# to be exact -- it is required to be as close as heap's is on the same data,
# which on these sizes is exact.
#
# Usage:  test/analyze_reltuples.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

reltuples() {  # table
	q "SELECT reltuples::bigint FROM pg_class WHERE oid = '$1'::regclass;" | tail -1
}

# Build the same data in both access methods and compare the estimate. Separate
# psql_run calls so a failure on one side cannot stop the other from being built.
both() {  # label, rows, column ddl, value expression
	local lab="$1" n="$2" ddl="$3" ex="$4"
	psql_run "DROP TABLE IF EXISTS ar_c; CREATE TABLE ar_c ($ddl) USING pgcolumnar;" >/dev/null 2>&1
	psql_run "INSERT INTO ar_c SELECT $ex FROM generate_series(1,$n) g;" >/dev/null 2>&1
	psql_run "DROP TABLE IF EXISTS ar_h; CREATE TABLE ar_h ($ddl);" >/dev/null 2>&1
	psql_run "INSERT INTO ar_h SELECT $ex FROM generate_series(1,$n) g;" >/dev/null 2>&1
	psql_run "ANALYZE ar_c;" >/dev/null 2>&1
	psql_run "ANALYZE ar_h;" >/dev/null 2>&1

	local c h
	c="$(reltuples ar_c)"
	h="$(reltuples ar_h)"

	# not zero, and within 5% of the truth -- the same bar heap clears
	check "$lab: estimate is not zero" \
		"$(awk -v v="$c" 'BEGIN { print (v > 0) ? "nonzero" : "ZERO" }')" "nonzero"
	check "$lab: within 5% of actual (heap says $h)" \
		"$(awk -v v="$c" -v n="$n" 'BEGIN { d = (v > n ? v - n : n - v); print (d <= n * 0.05) ? "close" : "off by " d }')" \
		"close"
}

# A single row group starting at the first logical offset is the case that
# reported zero; the larger sizes cover the partial shift.
both "10k rows"        10000  "id int, v int"  "g, g*2"
both "50k rows"        50000  "id int, v int"  "g, g*2"
both "200k rows"       200000 "id int, v int"  "g, g*2"
both "text column"     50000  "id int, v text" "g, 'x' || g"

# Several stripes, so more than one group has to be mapped.
psql_run "DROP TABLE IF EXISTS ar_s;
	SET pgcolumnar.stripe_row_limit = 1000;
	CREATE TABLE ar_s (id int, v int) USING pgcolumnar;" >/dev/null 2>&1
psql_run "SET pgcolumnar.stripe_row_limit = 1000;
	INSERT INTO ar_s SELECT g, g FROM generate_series(1,20000) g;" >/dev/null 2>&1
psql_run "ANALYZE ar_s;" >/dev/null 2>&1
check "20 stripes: within 5% of actual" \
	"$(awk -v v="$(reltuples ar_s)" 'BEGIN { d = (v > 20000 ? v - 20000 : 20000 - v); print (d <= 1000) ? "close" : "off by " d }')" \
	"close"

# The estimate has to follow deletes down, not just up.
psql_run "DELETE FROM ar_s WHERE id % 2 = 0;" >/dev/null 2>&1
psql_run "ANALYZE ar_s;" >/dev/null 2>&1
check "after deleting half, the estimate follows" \
	"$(awk -v v="$(reltuples ar_s)" 'BEGIN { d = (v > 10000 ? v - 10000 : 10000 - v); print (d <= 500) ? "close" : "off by " d }')" \
	"close"

# The sampling quality this mapping exists to protect must survive the fix: a
# clustered column still has to report its true n_distinct rather than the
# per-group count, which is what whole-group sampling would give.
psql_run "DROP TABLE IF EXISTS ar_n;
	SET pgcolumnar.stripe_row_limit = 1000;
	CREATE TABLE ar_n (id int, k int) USING pgcolumnar;" >/dev/null 2>&1
psql_run "SET pgcolumnar.stripe_row_limit = 1000;
	INSERT INTO ar_n SELECT g, g / 20 FROM generate_series(1,20000) g;" >/dev/null 2>&1
psql_run "ANALYZE ar_n;" >/dev/null 2>&1
check "a clustered column still reports many distinct values" \
	"$(q "SELECT CASE WHEN n_distinct < 0 THEN 'ratio'
			WHEN n_distinct > 500 THEN 'many' ELSE 'few:' || n_distinct END
		FROM pg_stats WHERE tablename = 'ar_n' AND attname = 'k';" | tail -1)" \
	"many"

pgc_summary
