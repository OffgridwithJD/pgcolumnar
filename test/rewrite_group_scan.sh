#!/usr/bin/env bash
#
# pgColumnar: a rewrite must read each group once, not once per row (#196).
#
# rewrite_one_group used PgColumnarReadRowByNumber for every row. That call
# decodes the whole group to return one value and depends on the fetch cache to
# make the next call cheap -- and the cache drops any group whose decoded form
# exceeds COLUMNAR_FETCH_CACHE_MAX_BYTES, after every fetch. So a group over the
# cap by any margin made the loop decode the entire group once per row.
#
# It is a cliff, not a slope. Three columns of 150,000 rows with one varlena
# among them decode to 34,713,408 bytes against a 33,554,432 cap -- 3.5% over.
# On an idle box, 200,000 rows with a third of them deleted:
#
#     id int, v text            1859 ms                 ->  462 ms
#     id int, k int, v text     unfinished at 120 s     ->  489 ms
#
# The shape here is chosen to cross that cap, because a smaller table stays
# under it and the check then passes on the unfixed build. Two columns is not
# enough; three all-integer columns is not enough; it needs the varlena.
#
# statement_timeout rather than a stopwatch: against the unfixed build this does
# not finish in any bounded time, and a suite that hangs is worse than one that
# fails. The timeout is generous because the point is the difference between
# "half a second" and "never", not a tight performance bound.
#
# Usage:  test/rewrite_group_scan.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=${PGC_REWRITE_ROWS:-200000}
LIMIT=${PGC_REWRITE_TIMEOUT:-60s}

# Three columns, one of them varlena, so a full group's decoded form crosses the
# fetch cache cap. Deleting a third of the rows puts every group over the
# rewrite threshold.
psql_run "DROP TABLE IF EXISTS rgs; DROP TABLE IF EXISTS rgs_h;
	CREATE TABLE rgs (id int, k int, v text) USING pgcolumnar;" >/dev/null
psql_run "INSERT INTO rgs SELECT g, g % 100, repeat('m', 80) || g
	FROM generate_series(1, $ROWS) g;" >/dev/null
psql_run "DELETE FROM rgs WHERE id % 3 = 0;" >/dev/null

# a heap mirror of exactly the rows that should survive
psql_run "CREATE TABLE rgs_h (id int, k int, v text);" >/dev/null
psql_run "INSERT INTO rgs_h SELECT g, g % 100, repeat('m', 80) || g
	FROM generate_series(1, $ROWS) g WHERE g % 3 <> 0;" >/dev/null

before="$(q "SELECT count(*) || '/' || md5(string_agg(id || ':' || k || ':' || v, ',' ORDER BY id)) FROM rgs;" | tail -1)"

# --- 1. it finishes at all -----------------------------------------------------

err="$(psql_run "SET statement_timeout = '$LIMIT';
	SELECT pgcolumnar.compact_rewrite('rgs', 0.2);" 2>&1 || true)"

check "a rewrite of a group over the cache cap finishes" \
	"$(echo "$err" | grep -ciE 'statement timeout|canceling statement')" "0"

# --- 2. and moved exactly the right rows ---------------------------------------

# The rewrite must be content-preserving. Checking the digest rather than the
# count, because a rewrite that dropped and re-added the same number of rows
# would pass a count.
after="$(q "SELECT count(*) || '/' || md5(string_agg(id || ':' || k || ':' || v, ',' ORDER BY id)) FROM rgs;" | tail -1)"
check "the rewrite preserved every surviving row" "$after" "$before"

check "and it agrees with a heap mirror" \
	"$(q "SELECT count(*) FROM rgs r FULL JOIN rgs_h h USING (id)
		WHERE r.v IS DISTINCT FROM h.v OR r.k IS DISTINCT FROM h.k;" | tail -1)" "0"

# --- 3. the same shape below the cap, which always worked ----------------------

# A control: this table stays under the cap, so it passed before the fix too. If
# this one ever fails while the big one passes, the fix broke the ordinary path
# rather than the pathological one.
psql_run "DROP TABLE IF EXISTS rgs_s;
	CREATE TABLE rgs_s (id int, k int, v text) USING pgcolumnar;" >/dev/null
psql_run "INSERT INTO rgs_s SELECT g, g % 100, repeat('m', 80) || g
	FROM generate_series(1, 20000) g;" >/dev/null
psql_run "DELETE FROM rgs_s WHERE id % 3 = 0;" >/dev/null
small_before="$(q "SELECT count(*) || '/' || coalesce(sum(id), 0) FROM rgs_s;" | tail -1)"
psql_run "SET statement_timeout = '$LIMIT';
	SELECT pgcolumnar.compact_rewrite('rgs_s', 0.2);" >/dev/null 2>&1
check "a group under the cap still rewrites correctly" \
	"$(q "SELECT count(*) || '/' || coalesce(sum(id), 0) FROM rgs_s;" | tail -1)" "$small_before"

# --- 4. the rows are still reachable through an index --------------------------

# A rewrite reinserts every row's index entries under new row numbers. If the
# streaming read handed the writer rows in a different order or skipped one, an
# index lookup is where it shows.
psql_run "CREATE INDEX rgs_id ON rgs (id);" >/dev/null
check "an index lookup finds a rewritten row" \
	"$(q "SET enable_seqscan = off; SET pgcolumnar.enable_custom_scan = off;
		SELECT v FROM rgs WHERE id = $((ROWS / 2 + 1));" | tail -1)" \
	"$(q "SELECT v FROM rgs_h WHERE id = $((ROWS / 2 + 1));" | tail -1)"

pgc_summary
