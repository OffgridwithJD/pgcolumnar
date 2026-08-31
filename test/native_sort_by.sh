#!/usr/bin/env bash
#
# pgColumnar declarative sort_by clustering key (#288). set_options(t, sort_by =>
# ARRAY[...]) declares a persisted physical sort key; vacuum_sorted(t) with no
# explicit columns applies it (the PostgreSQL CLUSTER model: remember the key,
# re-apply on demand). Unlike the numeric-only Z-order cluster(), the sorted
# rewrite handles any btree-orderable column, TEXT included, so an equality
# predicate on a text segment key skips chunk groups once the table is sorted.
# This suite proves: heap-parity, that sorting drives group skipping, the
# declared-key round-trip, set/reset, multi-column keys, and clean errors for a
# stale/dropped key, a bad column, a virtual generated column, and no-key.
# Written fresh for pgColumnar.
#
# Usage:  test/native_sort_by.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# 40960 rows, 50 text hosts scattered in insert order (h000..h049 cycled), so
# before sorting each 1024-row chunk group holds all 50 hosts and its host
# min/max spans the whole range -- an equality on one host skips nothing. Small
# stripe/chunk limits so many groups form.
GEN="SELECT g AS id,
       'h' || lpad((g % 50)::text, 3, '0') AS host,
       ('2024-01-01'::timestamptz + ((g % 1440) * interval '1 minute')) AS ts,
       'p' || (g % 7) AS payload
  FROM generate_series(1, 40960) g"

psql_run "CREATE TABLE h (id int, host text, ts timestamptz, payload text);"
psql_run "CREATE TABLE n (id int, host text, ts timestamptz, payload text) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('n', stripe_row_limit => 2048, chunk_group_row_limit => 1024);"
psql_run "INSERT INTO h $GEN;"
psql_run "INSERT INTO n $GEN;"

# chunk groups removed by the zone maps for a query, from EXPLAIN ANALYZE
skipped() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) $1" 2>/dev/null \
		| grep 'Columnar Chunk Groups Removed by Filter' | grep -oE '[0-9]+' | head -1
}
fails() {
	if env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -v ON_ERROR_STOP=1 -c "$1" >/dev/null 2>&1; then echo no; else echo yes; fi
}

EQ="host = 'h007'"

check "row count" "$(q 'SELECT count(*) FROM n;')" "40960"
check "the plan under test is a columnar custom scan" \
	"$(pgc_is_columnar_scan "SELECT id FROM n WHERE $EQ")" "yes"
check "equality parity (pre-sort)" \
	"$(pgc_set_hash "SELECT id, host, ts, payload FROM n WHERE $EQ")" \
	"$(pgc_set_hash "SELECT id, host, ts, payload FROM h WHERE $EQ")"

before="$(skipped "SELECT id FROM n WHERE $EQ")"; before="${before:-0}"

# ---- declare the key, then apply it with the zero-arg form ----
psql_run "SELECT pgcolumnar.set_options('n', sort_by => ARRAY['host','ts']);"
check "declared sort_by round-trips" \
	"$(q "SELECT sort_by::text FROM pgcolumnar.options WHERE regclass = 'n'::regclass")" \
	"{host,ts}"

psql_run "SELECT pgcolumnar.vacuum_sorted('n');"   # no columns -> use declared key

check "row count after sort" "$(q 'SELECT count(*) FROM n;')" "40960"
check "full-table parity after sort" \
	"$(pgc_set_hash 'SELECT id, host, ts, payload FROM n ORDER BY id')" \
	"$(pgc_set_hash 'SELECT id, host, ts, payload FROM h ORDER BY id')"
check "equality parity (post-sort)" \
	"$(pgc_set_hash "SELECT id, host, ts, payload FROM n WHERE $EQ")" \
	"$(pgc_set_hash "SELECT id, host, ts, payload FROM h WHERE $EQ")"

after="$(skipped "SELECT id FROM n WHERE $EQ")"; after="${after:-0}"
echo "  (chunk groups skipped for $EQ: before=$before after=$after)"
check "sorting a text key enables group skipping" \
	"$([ "$after" -gt "$before" ] && [ "$after" -gt 0 ] && echo yes || echo no)" "yes"

# ---- explicit columns still work and equal the declared-key result ----
psql_run "SELECT pgcolumnar.vacuum_sorted('n', 'host', 'ts');"
check "explicit-column sort parity" \
	"$(pgc_set_hash 'SELECT id, host, ts, payload FROM n ORDER BY id')" \
	"$(pgc_set_hash 'SELECT id, host, ts, payload FROM h ORDER BY id')"

# ---- reset clears the key; zero-arg then errors ----
psql_run "SELECT pgcolumnar.reset_options('n', sort_by => true);"
check "sort_by cleared" \
	"$(q "SELECT sort_by IS NULL FROM pgcolumnar.options WHERE regclass = 'n'::regclass")" "t"
check "zero-arg errors when no key declared" \
	"$(fails "SELECT pgcolumnar.vacuum_sorted('n')")" "yes"

# ---- validation errors ----
check "set_options rejects a nonexistent sort_by column" \
	"$(fails "SELECT pgcolumnar.set_options('n', sort_by => ARRAY['nope'])")" "yes"

# stale declared key: declare, drop the column, then the zero-arg apply must error
psql_run "SELECT pgcolumnar.set_options('n', sort_by => ARRAY['payload']);"
psql_run "ALTER TABLE n DROP COLUMN payload;"
check "zero-arg errors on a dropped declared column" \
	"$(fails "SELECT pgcolumnar.vacuum_sorted('n')")" "yes"
psql_run "SELECT pgcolumnar.reset_options('n', sort_by => true);"

# ---- edge cases: empty and single-row tables sort cleanly ----
psql_run "CREATE TABLE e (id int, host text) USING pgcolumnar;"
check "empty table sorts without error" \
	"$(fails "SELECT pgcolumnar.vacuum_sorted('e', 'host')")" "no"
psql_run "INSERT INTO e VALUES (1, 'x');"
check "single-row table sorts without error" \
	"$(fails "SELECT pgcolumnar.vacuum_sorted('e', 'host')")" "no"
check "single-row parity" "$(q 'SELECT count(*) FROM e')" "1"

# ---- virtual generated column rejected as a key (PG18+; inert earlier) ----
PGV="$("$PGC_BINDIR/pg_config" --version | grep -oE '[0-9]+' | head -1)"
if [ "${PGV:-0}" -ge 18 ]; then
	psql_run "CREATE TABLE v (id int, k int, kv int GENERATED ALWAYS AS (k * 2) VIRTUAL) USING pgcolumnar;"
	psql_run "INSERT INTO v (id, k) SELECT g, g % 10 FROM generate_series(1, 100) g;"
	check "set_options rejects a virtual generated sort_by column" \
		"$(fails "SELECT pgcolumnar.set_options('v', sort_by => ARRAY['kv'])")" "yes"
	check "vacuum_sorted rejects an explicit virtual generated column" \
		"$(fails "SELECT pgcolumnar.vacuum_sorted('v', 'kv')")" "yes"
else
	echo "  (skipping virtual-generated-column cases: PostgreSQL < 18)"
fi

pgc_summary
