#!/usr/bin/env bash
#
# A bloom filter must be sized by its DISTINCT count, not its value count (#467).
#
# PgColumnarBloomBuild takes n = the number of hashes, which is the stripe's row
# count, and both of its guards test that same n. At the default stripe limit
# neither fires: `n < 64` is false because n is 150,000, and the BLOOM_MAX_BITS
# refusal only fires above n = 209,715. So every bloomable column of every stripe
# gets next_pow2(n * 10) bits regardless of cardinality -- 256 KB for a column
# with five distinct values and 256 KB for a unique one.
#
# Measured on 2M ClickBench rows: 19.3x over-provisioned, filters 361 MB raw
# against a 262 MB table, and 29% of load time.
#
# WHAT IS ASSERTED, AND WHY THIS SHAPE
#
# The defect is a SIZE, and `pgcolumnar.bloom.filter` is a bytea in a catalog
# table, so it is measured directly with octet_length. No timing, so nothing here
# is subject to PGC_SKIP_TIMING.
#
# The assertion is the RELATION between two cardinalities in the same table, not
# a literal byte count. A literal would snapshot today's next_pow2 constants and
# fail the next time BLOOM_BITS_PER_VALUE is tuned, which is not this suite's
# business.
#
# The selectivity arm is the one that matters adversarially: shrinking a filter by
# making it useless would satisfy every size check here. A filter that no longer
# skips is worthless at any size.
#
# Usage:  test/bloom_sizing.sh [PG_CONFIG]
# Written fresh for pgColumnar.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=20000

# One table, one stripe, two columns that differ ONLY in cardinality. Same rows,
# same type, same filter code path -- so a difference in filter size can only be
# cardinality, which is what makes this able to discriminate at all.
psql_run "DROP TABLE IF EXISTS bs;
	CREATE TABLE bs (lo int, hi int, pad text) USING pgcolumnar;
	SELECT pgcolumnar.set_options('bs', stripe_row_limit => $ROWS);
	INSERT INTO bs SELECT g % 5, g, md5(g::text) FROM generate_series(1, $ROWS) g;
	ANALYZE bs;" >/dev/null 2>&1

SID=$(q "SELECT pgcolumnar.get_storage_id('bs')")
flt() {	# $1 = 1-based column index -> stored filter bytes, or empty when absent
	q "SELECT octet_length(filter) FROM pgcolumnar.bloom
	   WHERE storage_id = $SID AND column_index = $(( $1 - 1 ))
	   ORDER BY group_number LIMIT 1"
}

# ---- premises, or a smaller filter proves nothing ---------------------------
#
# octet_length of a MISSING row is empty, not 0, and an empty side compares equal
# to another empty side under plain check (#418). Every size assertion below
# needs the row to exist first.
check_num "premise: every row loaded" "$(q 'SELECT count(*) FROM bs')" "$ROWS"
check_num "premise: the whole table is one row group" \
	"$(q "SELECT count(*) FROM pgcolumnar.row_group WHERE storage_id = $SID")" "1"
check_num "premise: the low-cardinality column really is low" \
	"$(q 'SELECT count(DISTINCT lo) FROM bs')" "5"
check_num "premise: the high-cardinality column really is high" \
	"$(q 'SELECT count(DISTINCT hi) FROM bs')" "$ROWS"

LO=$(flt 1)
HI=$(flt 2)
echo "-- filter bytes: lo (5 distinct) = ${LO:-none}, hi ($ROWS distinct) = ${HI:-none}"
check_num "premise: the low-cardinality column HAS a filter" \
	"$([ -n "$LO" ] && echo 1 || echo 0)" "1"
check_num "premise: the high-cardinality column HAS a filter" \
	"$([ -n "$HI" ] && echo 1 || echo 0)" "1"

# ---- the assertion ----------------------------------------------------------
#
# Sized by distinct count, `lo` needs next_pow2(5 * 10) = 64 bits and `hi` needs
# next_pow2(20000 * 10) = 262,144. Sized by value count they are identical, which
# is the defect. A bound of 8x is far inside the real ratio and far outside any
# rounding effect.
check_num "a five-value column does not get a unique column's filter (#467)" \
	"$(awk "BEGIN{print (${LO:-0} * 8 <= ${HI:-0}) ? 1 : 0}")" "1"

# ---- the arm that stops this being satisfied by a useless filter ------------
#
# Shrinking a filter to nothing would pass every size check above. What a filter
# is FOR is skipping groups on an equality probe, so that has to survive. A value
# outside the column's five must still be excluded.
check_num "a value that is absent is still reported absent" \
	"$(q 'SELECT count(*) FROM bs WHERE lo = 999')" "0"
check_num "and a value that is present is still found" \
	"$(q 'SELECT count(*) FROM bs WHERE lo = 3')" "$(( ROWS / 5 ))"

# ---- equivalence: a smaller filter may not change an answer -----------------
#
# The filter is an optimisation, so the same query must return the same rows with
# it and without it. Both sides go through check_text, which refuses an empty
# side: a down cluster returns nothing on both arms and would otherwise compare
# equal.
ON=$(q "SELECT md5(string_agg(hi::text, ',' ORDER BY hi)) FROM bs WHERE lo = 2")
OFF=$(q "SET pgcolumnar.enable_bloom_filter = off;
         SELECT md5(string_agg(hi::text, ',' ORDER BY hi)) FROM bs WHERE lo = 2" | tail -1)
check_text "results are identical with the filter and without it" "$ON" "$OFF"

pgc_summary
