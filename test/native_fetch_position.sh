#!/usr/bin/env bash
#
# pgColumnar fetch-by-row-number: cost independent of position (issue #143).
#
# #148 made a fetch decode its row group once and cache it, which removed the
# repeated decode but not the walk to the row. Reaching row r's value still meant
# counting the validity bits below r and then decoding and discarding that many
# values, so a cache hit cost O(r) and fetching a whole group stayed quadratic.
# Two indexes built with the decoded group -- a rank prefix over the validity
# bitmap, and an offset table for varying-length columns -- make it O(1).
#
# Four things are asserted.
#
# 1. The values are right, which is where this change can go wrong quietly. The
#    rank has to count present values, not rows, so a column with many nulls is
#    the case that separates a correct index from a plausible one; an off-by-one
#    in the rank returns a neighbouring row's value rather than an error. Checked
#    differentially against a heap mirror over fixed-length, varying-length and
#    heavily-null columns.
#
# 2. The cost no longer depends on where the row is. Timed as a ratio: the same
#    number of index-driven fetches against the first tenth of one big row group
#    and against the last tenth. Before the change the far end walked most of the
#    group per row and the ratio ran with the group size; now both are constant
#    work. A ratio is portable where a millisecond count is not.
#
# 3. Fetching a whole group is no longer quadratic in the group. Doubling the
#    group size while fetching the same number of rows should not double the
#    cost, because neither the rank nor the offset lookup grows with it.
#
# Usage:  test/native_fetch_position.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=${PGC_FETCHPOS_ROWS:-120000}

# --- 1. the values are right ---------------------------------------------------

# every fourth row null in the nullable columns, so the rank and the row number
# diverge widely by the end of the group
psql_run "DROP TABLE IF EXISTS fp_c; DROP TABLE IF EXISTS fp_h;
	SET pgcolumnar.stripe_row_limit = $ROWS;
	SET pgcolumnar.chunk_group_row_limit = $ROWS;
	CREATE TABLE fp_c (id int, fixed bigint, txt text, sparse int, stxt text)
		USING pgcolumnar;
	INSERT INTO fp_c
		SELECT g, g * 7,
			   repeat('x', 1 + (g % 40)) || g,
			   CASE WHEN g % 4 = 0 THEN NULL ELSE g END,
			   CASE WHEN g % 4 = 0 THEN NULL ELSE 's' || g END
		FROM generate_series(1, $ROWS) g;
	CREATE INDEX fp_c_id ON fp_c (id);
	CREATE TABLE fp_h (LIKE fp_c);
	INSERT INTO fp_h SELECT * FROM fp_c;" >/dev/null 2>&1

check "the rows are in one row group" \
	"$(q "SELECT count(*) FROM pgcolumnar.row_group r
		JOIN pgcolumnar.storage s ON s.storage_id = r.storage_id
		WHERE s.relation_oid = 'fp_c'::regclass;")" \
	"1"

# Fetch by row number is what an index scan drives, so force one. Each leading
# SET prints its own line ahead of the result, so these queries take the last.
FORCE="SET enable_seqscan = off; SET enable_bitmapscan = off;
	SET max_parallel_workers_per_gather = 0;"

# rows spread across the whole group, including the far end where the old walk
# was longest
mismatch="$(q "$FORCE
	SELECT count(*) FROM fp_c c JOIN fp_h h USING (id)
	WHERE c.fixed IS DISTINCT FROM h.fixed
	   OR c.txt IS DISTINCT FROM h.txt
	   OR c.sparse IS DISTINCT FROM h.sparse
	   OR c.stxt IS DISTINCT FROM h.stxt;" | tail -1)"
check "every column matches the heap mirror" "$mismatch" "0"

# the same through the fetch path one row at a time, at positions where an
# off-by-one in the rank would land on a neighbour
bad=""
for pos in 1 2 3 4 5 999 1000 1001 $((ROWS / 2)) $((ROWS - 1)) "$ROWS"; do
	got="$(q "$FORCE SELECT fixed || '|' || txt || '|' ||
		coalesce(sparse::text, 'N') || '|' || coalesce(stxt, 'N')
		FROM fp_c WHERE id = $pos;" | tail -1)"
	want="$(q "SELECT fixed || '|' || txt || '|' ||
		coalesce(sparse::text, 'N') || '|' || coalesce(stxt, 'N')
		FROM fp_h WHERE id = $pos;" | tail -1)"
	[ "$got" = "$want" ] || bad="$bad id=$pos(got=$got want=$want)"
done
check "single-row fetches are right at every position" "${bad:-same}" "same"

# --- 2. the cost does not depend on the position -------------------------------

N=$((ROWS / 20))
NEAR_LO=1
NEAR_HI=$N
FAR_LO=$((ROWS - N + 1))
FAR_HI=$ROWS

upd_ms() {  # id-low, id-high
	local start end
	start=$(date +%s%N)
	psql_run "$FORCE UPDATE fp_c SET fixed = fixed + 1
		WHERE id BETWEEN $1 AND $2;" >/dev/null 2>&1
	end=$(date +%s%N)
	echo $(( (end - start) / 1000000 ))
}

near="$(upd_ms $NEAR_LO $NEAR_HI)"
far="$(upd_ms $FAR_LO $FAR_HI)"
echo "-- $N fetches: first tenth ${near} ms, last tenth ${far} ms"

check "fetching from the far end of a group costs about what the near end does" \
	"$(awk -v n="$near" -v f="$far" \
		'BEGIN { print (n > 0 && f / n < 3) ? "yes" : "no (near=" n "ms far=" f "ms)" }')" \
	"yes"

# --- 3. a bigger group does not cost more per fetch ----------------------------

build() {  # table, rows
	psql_run "DROP TABLE IF EXISTS $1;
		SET pgcolumnar.stripe_row_limit = $2;
		SET pgcolumnar.chunk_group_row_limit = $2;
		CREATE TABLE $1 (id int, v bigint, t text) USING pgcolumnar;
		INSERT INTO $1 SELECT g, g * 3, 't' || g FROM generate_series(1, $2) g;
		CREATE INDEX ${1}_id ON $1 (id);" >/dev/null 2>&1
}

# The rows fetched must sit at the END of the group. Fetching the first K rows
# costs the same in a big group as in a small one even with the old walk, because
# the walk is to the row's position and those rows are near the start either way:
# that check would pass on both sides and prove nothing.
fetch_ms() {  # table, table-rows, count
	local start end
	start=$(date +%s%N)
	psql_run "$FORCE UPDATE $1 SET v = v + 1 WHERE id > $(( $2 - $3 ));" \
		>/dev/null 2>&1
	end=$(date +%s%N)
	echo $(( (end - start) / 1000000 ))
}

build fp_small $((ROWS / 2))
build fp_big "$ROWS"

K=$((ROWS / 20))
small="$(fetch_ms fp_small $((ROWS / 2)) $K)"
big="$(fetch_ms fp_big "$ROWS" $K)"
echo "-- $K fetches at the far end: group of $((ROWS / 2)) took ${small} ms, group of $ROWS took ${big} ms"

check "doubling the row group does not double the cost of the same fetches" \
	"$(awk -v s="$small" -v b="$big" \
		'BEGIN { print (s > 0 && b / s < 1.8) ? "yes" : "no (small=" s "ms big=" b "ms)" }')" \
	"yes"

# --- 4. the indexes that make it O(1) are present ------------------------------

# The timing checks above are the real evidence. These pin the mechanism, so a
# future change that quietly reintroduces a walk fails by name rather than by a
# ratio drifting under whatever machine happens to run it.
#
# They read the source tree, not the built .so, and that difference is worth
# knowing: if these two pass while the timing checks fail, the library under test
# is older than the source beside it. That is not hypothetical -- it happened
# while writing this, when a copied tree carried mtimes older than the objects
# already built from it and make had nothing to do.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"

check "the rank comes from a prefix rather than a loop over earlier rows" \
	"$(grep -c 'present = columnar_rank_before' "$SRC/columnar_reader.c")" "1"

check "a varying-length column reaches its value through an offset table" \
	"$(grep -c 'entry->valOffset\[c\]\[present\]' "$SRC/columnar_reader.c")" "1"

pgc_summary
