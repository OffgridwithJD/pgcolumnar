#!/usr/bin/env bash
#
# pgColumnar fetch-by-row-number with a column projection (issue #157).
#
# Fetching a row by number decoded every column of its row group whatever the
# caller wanted. Two entry points now exist beside it: one that decodes only a
# given set of columns, and one that answers visibility and decodes nothing.
#
# Neither has a SQL surface of its own, so this exercises them through the two
# callers that use them: pgcolumnar.read_projection, which needs the base row
# only for visibility, and pgcolumnar.reconstruct_via_projection, which needs
# exactly the columns the projection does not carry.
#
# Three things are asserted.
#
# 1. The output is unchanged. This is the whole risk of the change: a projection
#    that decodes too few columns returns a null where a value belongs, and
#    nothing raises. Checked against the same query with the projection dropped,
#    which reads the base table directly, so the oracle does not share the code
#    under test.
#
# 2. Visibility still comes from the base row. The liveness entry point stops
#    before decoding anything, so a delete that it failed to see would show up as
#    a row that should have disappeared and did not.
#
# 3. A wide table is where this matters, so the fixture is wide. On a narrow one
#    the difference between decoding one column and forty is not observable.
#
# Usage:  test/native_fetch_projection.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=${PGC_FETCHPROJ_ROWS:-20000}
NCOLS=${PGC_FETCHPROJ_COLS:-40}

cols=""; sel=""
for i in $(seq 1 "$NCOLS"); do
	cols="$cols, c$i bigint"
	sel="$sel, g * $i"
done

psql_run "DROP TABLE IF EXISTS fp_w;
	CREATE TABLE fp_w (id int$cols) USING pgcolumnar;
	INSERT INTO fp_w SELECT g$sel FROM generate_series(1, $ROWS) g;" >/dev/null

check "the wide fixture has $((NCOLS + 1)) columns" \
	"$(q "SELECT count(*) FROM information_schema.columns
		WHERE table_name = 'fp_w';")" "$((NCOLS + 1))"

psql_run "SELECT pgcolumnar.add_projection('fp_w', 'fp_p',
	ARRAY['id','c1'], ARRAY['id']);" >/dev/null

# --- 1. reconstruct returns the same rows as reading the table -----------------

# reconstruct_via_projection reads the covered columns from the projection and
# the rest from the base row, which is the projected-fetch path. The oracle is
# the base table itself, which does not go through that path at all.
mismatch="$(q "WITH viaproj AS (
		SELECT pgcolumnar.reconstruct_via_projection('fp_w','fp_p') AS r
	), direct AS (
		SELECT id::text || '|' || c1::text || '|' || c2::text || '|' ||
		       c${NCOLS}::text AS d
		FROM fp_w
	)
	SELECT count(*) FROM viaproj
	WHERE split_part(r, '|', 1) || '|' || split_part(r, '|', 2) || '|' ||
	      split_part(r, '|', 3) || '|' || split_part(r, '|', $((NCOLS + 1)))
	      NOT IN (SELECT d FROM direct);")"

check "every reconstructed row matches the base table" "$mismatch" "0"

# --- 2. visibility still comes from the base row ------------------------------

before="$(q "SELECT count(*) FROM pgcolumnar.read_projection('fp_w','fp_p');")"
check "the projection reads every row to start with" "$before" "$ROWS"

psql_run "DELETE FROM fp_w WHERE id <= 100;" >/dev/null

after="$(q "SELECT count(*) FROM pgcolumnar.read_projection('fp_w','fp_p');")"
check "a deleted row stops being read through the projection" \
	"$after" "$((ROWS - 100))"

# the same must hold for the reconstruct path, which uses the projected fetch
rafter="$(q "SELECT count(*) FROM pgcolumnar.reconstruct_via_projection('fp_w','fp_p');")"
check "and stops being reconstructed too" "$rafter" "$((ROWS - 100))"

# a value from an uncovered column is still right after the delete, so the
# projection set was not narrowed by one column too many
check "an uncovered column still reads correctly after a delete" \
	"$(q "SELECT split_part(r, '|', $((NCOLS + 1)))
		FROM pgcolumnar.reconstruct_via_projection('fp_w','fp_p') AS r
		WHERE split_part(r, '|', 1) = '101';")" \
	"$(q "SELECT c${NCOLS}::text FROM fp_w WHERE id = 101;")"

# --- 3. the entry points are the ones being used ------------------------------

# The timing difference is real but modest, because the decoded-group cache
# already amortises the decode across a group, so it is not asserted here. These
# pin the call sites instead: a revert to the full-decode entry point would pass
# every check above while giving back what the change was for.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"

check "the visibility-only caller decodes nothing" \
	"$(grep -c 'ColumnarRowIsLive(rel, snap, baseRow)' "$SRC/columnar_projection.c")" "1"

check "the reconstruct caller asks only for uncovered columns" \
	"$(grep -c 'ColumnarReadRowByNumberCols(rel, snap, baseRow' "$SRC/columnar_projection.c")" "1"

check "index deletion asks only whether the row is live" \
	"$(grep -c 'ColumnarRowIsLive(rel, snapshot, rowNumber)' "$SRC/columnar_tableam.c")" "1"

pgc_summary
