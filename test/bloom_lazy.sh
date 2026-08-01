#!/usr/bin/env bash
#
# pgColumnar bloom filter reads (#310, #314): a bloom filter is only consulted for an
# equality predicate whose zone map did not already rule the group out. The
# reader used to load every candidate group's bloom filters before evaluating
# any predicate, so a scan that skipped 19 of 20 groups still paid for the bloom
# filters of all 20.
#
# The cost scaled with the column count and with the group size, because a bloom
# filter holds one bitmap per column sized by the group's distinct values. It was
# the dominant per-skipped-group cost.
#
# This suite measures block reads against pgcolumnar.bloom directly, rather than
# a total buffer count or a wall-clock time, so what it asserts is the thing that
# changed: how much of that catalog the scan touches. The governing property is
# that bloom reads follow the groups the scan KEEPS, not the groups it examines.
#
# The second half covers #314, the same principle across the other axis: a
# predicate probes one column, so a group that IS examined needs the filters of
# the columns carrying predicates and no others. The reader used to fetch every
# column's filter for the group.
#
# Usage:  test/bloom_lazy.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# Twelve columns, so a group's bloom filters are worth measuring. seg is
# monotonic with insertion order, so a zone map alone can exclude every group
# except the one that holds the value.
COLS="a int, b int, c int, d int, e int, f int, g1 int, h int, i int, j int, k int"
# k repeats every 1000 rows, so every group holds every k value and no zone map
# can exclude a group on it. That is what lets a single equality predicate keep
# all the groups, which the control below needs. The rest are unique.
VALS="g,g,g,g,g,g,g,g,g,g,g % 1000"

build() {			# build(table, rows_per_group, group_count)
	local t="$1" s="$2" n="$3"
	psql_run "DROP TABLE IF EXISTS $t;" >/dev/null 2>&1
	psql_run "CREATE TABLE $t (seg int, $COLS) USING pgcolumnar;"
	psql_run "SELECT pgcolumnar.set_options('$t', stripe_row_limit => $s, chunk_group_row_limit => 1024);"
	psql_run "INSERT INTO $t SELECT g/$s, $VALS FROM generate_series(0, $((s * n - 1))) g;"
	psql_run "ANALYZE $t;"
}

# Blocks fetched from pgcolumnar.bloom while running one query. The statistics
# collector is asynchronous, so each reading is forced to flush first; without
# that the deltas are whatever happened to have been reported already.
bloom_blocks() {
	local sql="$1" before after
	psql_run "SELECT pg_stat_force_next_flush();" >/dev/null
	before="$(q "SELECT pg_stat_get_blocks_fetched('pgcolumnar.bloom'::regclass);")"
	q "$sql" >/dev/null
	psql_run "SELECT pg_stat_force_next_flush();" >/dev/null
	after="$(q "SELECT pg_stat_get_blocks_fetched('pgcolumnar.bloom'::regclass);")"
	echo "$((after - before))"
}

groups_read() {
	q "EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF) $1;" \
		| grep -oP 'Chunk Groups Read: \K[0-9]+' | head -1
}
groups_total() {
	q "EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF) $1;" \
		| grep -oP 'Chunk Groups Total: \K[0-9]+' | head -1
}

# Same rows per group and same query shape in both tables. Only the number of
# groups the scan must examine differs, by a factor of five.
build small 20000 6
build large 20000 30

Q_SMALL="SELECT count(*) FROM small WHERE seg = 3"
Q_LARGE="SELECT count(*) FROM large WHERE seg = 3"

check "the small table has the groups it should" "$(groups_total "$Q_SMALL")" "6"
check "the large table has the groups it should" "$(groups_total "$Q_LARGE")" "30"
check "the small scan keeps one group" "$(groups_read "$Q_SMALL")" "1"
check "the large scan keeps one group" "$(groups_read "$Q_LARGE")" "1"

SMALL_BLK="$(bloom_blocks "$Q_SMALL")"
LARGE_BLK="$(bloom_blocks "$Q_LARGE")"

echo "      bloom blocks fetched: 6 groups -> $SMALL_BLK, 30 groups -> $LARGE_BLK"

# The property. Both scans keep exactly one group, so both should read about one
# group's bloom filters. Five times as many skipped groups must not cost five
# times as many bloom blocks. The bound is deliberately loose: the claim is that
# the cost does not follow the skipped groups, not that it is any exact number.
check "bloom reads do not follow the skipped groups" \
	"$( [ "$LARGE_BLK" -le $((SMALL_BLK * 2 + 20)) ] && echo yes || echo no )" "yes"

# A scan that keeps every group still reads bloom filters, so the lazy path is
# deferring the read and not suppressing it. Without this, a change that simply
# stopped reading bloom filters would pass the assertion above.
#
# One equality predicate in both cases, so the only thing that differs is how
# many groups survive to reach it: k = 7 is present in every group, seg = 3 in
# one. An earlier version of this control used a column whose values were unique
# across the table, so its zone map excluded every group but one and it was
# measuring the column count instead of the group count.
ALL="SELECT count(*) FROM large WHERE k = 7"
check "the control query really does keep every group" \
	"$(groups_read "$ALL")" "$(groups_total "$ALL")"
check "a scan that keeps every group reads more" \
	"$( [ "$(bloom_blocks "$ALL")" -gt "$LARGE_BLK" ] && echo yes || echo no )" "yes"

# Correctness is the point of the filter, so the answers must not move.
psql_run "CREATE TABLE h_mirror (seg int, $COLS);"
psql_run "INSERT INTO h_mirror SELECT g/20000, $VALS FROM generate_series(0, 599999) g;"
check "equality on the segment key agrees with the heap" \
	"$(q 'SELECT count(*) FROM large WHERE seg = 3;')" \
	"$(q 'SELECT count(*) FROM h_mirror WHERE seg = 3;')"
check "equality that no group holds agrees with the heap" \
	"$(q 'SELECT count(*) FROM large WHERE k = -999;')" \
	"$(q 'SELECT count(*) FROM h_mirror WHERE k = -999;')"
check "equality on a scattered column agrees with the heap" \
	"$(q 'SELECT count(*) FROM large WHERE a = 123456;')" \
	"$(q 'SELECT count(*) FROM h_mirror WHERE a = 123456;')"
check "two equality predicates agree with the heap" \
	"$(q 'SELECT count(*) FROM large WHERE seg = 3 AND k = 60001;')" \
	"$(q 'SELECT count(*) FROM h_mirror WHERE seg = 3 AND k = 60001;')"
check "a range predicate still agrees with the heap" \
	"$(q 'SELECT count(*) FROM large WHERE seg BETWEEN 4 AND 9;')" \
	"$(q 'SELECT count(*) FROM h_mirror WHERE seg BETWEEN 4 AND 9;')"
check "full set parity" \
	"$(pgc_set_hash 'SELECT seg, a, k FROM large')" \
	"$(pgc_set_hash 'SELECT seg, a, k FROM h_mirror')"

# With bloom filters turned off the results must still agree, which shows the
# filter is a pruning step and never the source of an answer.
# A compound statement returns the SET acknowledgement first, so take the value.
nobloom() { q "SET pgcolumnar.enable_bloom_filter = off; $1" | tail -1; }
check "results agree with bloom filters disabled" \
	"$(nobloom 'SELECT count(*) FROM large WHERE a = 123456;')" \
	"$(q 'SELECT count(*) FROM h_mirror WHERE a = 123456;')"
check "an absent value agrees with bloom filters disabled" \
	"$(nobloom 'SELECT count(*) FROM large WHERE k = -999;')" \
	"$(q 'SELECT count(*) FROM h_mirror WHERE k = -999;')"

# ---------------------------------------------------- reads follow the columns

# #314. Twelve columns whose values repeat identically in every group, so no
# zone map can exclude anything: every group is kept and every equality
# predicate reaches its bloom filter. The only thing that varies between the two
# queries is how many columns carry a predicate.
psql_run "CREATE TABLE wide (p0 int, p1 int, p2 int, p3 int, p4 int, p5 int,
						   q0 int, q1 int, q2 int, q3 int, q4 int, q5 int) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('wide', stripe_row_limit => 20000, chunk_group_row_limit => 1024);"
psql_run "INSERT INTO wide SELECT g % 500, g % 500, g % 500, g % 500, g % 500, g % 500,
							   g % 500, g % 500, g % 500, g % 500, g % 500, g % 500
					   FROM generate_series(1, 400000) g;"
psql_run "ANALYZE wide;"

ONE_PRED="SELECT count(*) FROM wide WHERE p0 = 1"
SIX_PRED="SELECT count(*) FROM wide WHERE p0 = 1 AND p1 = 1 AND p2 = 1 AND p3 = 1 AND p4 = 1 AND p5 = 1"

check "no group is excluded, so every predicate is reached" \
	"$(groups_read "$ONE_PRED")" "$(groups_total "$ONE_PRED")"

ONE_BLK="$(bloom_blocks "$ONE_PRED")"
SIX_BLK="$(bloom_blocks "$SIX_PRED")"

echo "      bloom blocks fetched: 1 predicate -> $ONE_BLK, 6 predicates -> $SIX_BLK"

# The property. Six columns' filters cost more to read than one column's. When
# the reader fetched the whole group's filters these two were identical, because
# the work did not depend on the query at all.
check "bloom reads follow the columns a query filters on" \
	"$( [ "$SIX_BLK" -gt "$ONE_BLK" ] && echo yes || echo no )" "yes"

# The one-predicate query must not be paying for all twelve columns. Six
# predicates is half the columns, so reading all twelve would put the single
# predicate at or above the six-predicate cost rather than well below it.
check "one predicate costs well less than six" \
	"$( [ $((ONE_BLK * 2)) -lt "$SIX_BLK" ] && echo yes || echo no )" "yes"

check "the filtered answers agree with a heap mirror" \
	"$(q "$ONE_PRED;")" "800"
check "six predicates give the same answer as one here" \
	"$(q "$SIX_PRED;")" "800"

pgc_summary
