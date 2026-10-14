#!/usr/bin/env bash
#
# pgColumnar delete visibility agrees across every access path.
#
# The delete-vector fold (OR the group's bitmaps into one mask) and the per-row
# bit test are consulted by four independent paths: the sequential scan, the
# index fetch, the index-only scan, and the buffered (read-your-writes) path. The
# fold is single-sourced in pgcolumnar_merge_delete_vectors and the bit test in
# dv_row_deleted, so a deleted row is invisible through all of them identically.
#
# This is the characterization test for that seam: it deletes a known set and
# asserts every path returns the same live set. It does not go red when the seam
# is un-refactored (the paths behaved the same before), which is the point -- it
# guards the INVARIANT the shared helpers protect, so a future change that breaks
# one path's fold or bit test fails here rather than only under one plan shape.
#
# Usage:  test/native_delete_visibility_paths.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null
# Small stripes so the 5000 rows span five groups (each builds its own mask).
q "SET pgcolumnar.stripe_row_limit=1000;
   CREATE TABLE t (id int, v int) USING pgcolumnar;
   INSERT INTO t SELECT g, g FROM generate_series(1,5000) g;
   CREATE UNIQUE INDEX t_id ON t (id);
   DELETE FROM t WHERE id % 7 = 0;" >/dev/null

# Live count = 5000 - floor(5000/7) = 5000 - 714 = 4286. Five row groups.
LIVE=4286

# The last line of each probe is the count; SET/BEGIN precede it under a
# multi-statement send.
last() { q "$1" | tail -1; }

# A qual on the non-indexed column forces a real row-emitting sequential scan
# (which applies the delete mask per row), not the unqualified count(*) metadata
# fast-path (which subtracts delete counts and never reaches the bit test).
check "sequential scan sees the live set (row-emitting path)" \
	"$(last 'SET enable_indexscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; SELECT count(*) FROM t WHERE v >= 0;')" "$LIVE"
check "index / bitmap scan sees the live set" \
	"$(last 'SET enable_seqscan=off; SET enable_indexonlyscan=off; SELECT count(*) FROM t WHERE id >= 0;')" "$LIVE"
check "index-only scan sees the live set" \
	"$(last 'SET enable_seqscan=off; SET enable_indexonlyscan=on; SELECT count(id) FROM t WHERE id >= 0;')" "$LIVE"
check "aggregate over the whole table sees the live set" \
	"$(q 'SELECT count(*) FROM t;')" "$LIVE"

# A specific deleted row is invisible, and its live neighbour visible, via the
# index fetch (which reaches the same bit test through a different path).
check "a deleted row is invisible via the index" \
	"$(last 'SET enable_seqscan=off; SELECT count(*) FROM t WHERE id = 700;')" "0"
check "a live row is visible via the index" \
	"$(last 'SET enable_seqscan=off; SELECT count(*) FROM t WHERE id = 701;')" "1"
# The buffered (same-transaction) path: delete more inside a txn, then read it back.
check "a row deleted in-transaction is invisible in the same transaction" \
	"$(q 'BEGIN; DELETE FROM t WHERE id = 8; SELECT count(*) FROM t WHERE id = 8; ROLLBACK;' | grep -E '^[0-9]+$' | head -1)" "0"

# A DELETE whose qual deletes another row of the same table (#1394). The inner DELETE's
# scan start writes the outer statement's buffered marks, and its statement end writes
# its own mark to the same row group, both in one command. The second write updated a
# delete_vector row the first had written in that command, and failed with "attempted
# to update invisible tuple". Run on heap too; the columnar answer must be heap's.
psql_run "CREATE FUNCTION del_next(i int, t text) RETURNS int LANGUAGE plpgsql AS \$\$
BEGIN EXECUTE format('DELETE FROM %s WHERE id = %s', t, i + 1); RETURN 1; END \$\$;"
for am in pgcolumnar heap; do
	psql_run "CREATE TABLE dn_$am (id int, v int) USING $am;
	          INSERT INTO dn_$am SELECT g, 0 FROM generate_series(1, 20) g;"
done
dn() {	# dn AM -> ok, or the SQLSTATE the DELETE fails with
	local out
	out=$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-X -At -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate \
		-c "DELETE FROM dn_$1 WHERE id % 2 = 0 AND del_next(id, 'dn_$1') IS NOT NULL" 2>&1 >/dev/null)
	[ -z "$out" ] && { echo ok; return; }
	echo "$out" | sed -n 's/^ERROR: *\([0-9A-Z]\{5\}\).*/\1/p' | head -1
}
dn_after() { q "SELECT count(*) || '|' || coalesce(sum(id), 0) FROM dn_$1"; }
check "a DELETE whose qual deletes another row of the table succeeds and leaves heap's rows (#1394)" \
	"$(dn pgcolumnar)|$(dn_after pgcolumnar)" "$(dn heap)|$(dn_after heap)"

pgc_summary
