#!/usr/bin/env bash
# Regression: the index-fetch cost penalty must size row groups by the table's
# effective stripe_row_limit (the per-table option when set), not the GUC. The
# penalty exists to price the row-group decode a columnar index fetch forces, and
# that decode's size is the effective limit. Reading only the GUC mis-prices a
# table that set the option. Here, changing the per-table option must change the
# estimated index-scan cost; on the unfixed build it did not.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE TABLE ct (id int, v int) USING pgcolumnar" >/dev/null
q "INSERT INTO ct SELECT g, g FROM generate_series(1, 200000) g" >/dev/null
q "CREATE INDEX ct_id ON ct (id)" >/dev/null
q "ANALYZE ct" >/dev/null

topcost() {  # total cost of the top plan node for an index-forced range scan
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -qtA \
		-c "SET enable_seqscan=off" \
		-c "EXPLAIN (COSTS on, FORMAT text) SELECT * FROM ct WHERE id BETWEEN 1 AND 100000" 2>/dev/null \
		| grep -oiE 'cost=[0-9.]+\.\.[0-9.]+' | head -1 | sed 's/.*\.\.//'
}

q "SELECT pgcolumnar.set_options('ct', stripe_row_limit => 2000)" >/dev/null
c1="$(topcost)"
q "SELECT pgcolumnar.set_options('ct', stripe_row_limit => 150000)" >/dev/null
c2="$(topcost)"
echo "-- index-scan total cost: stripe_row_limit=2000 -> $c1 ; =150000 -> $c2"

check "the index-fetch cost responds to the per-table stripe_row_limit (c1 is a number)" \
	"$(echo "$c1" | grep -qE '^[0-9.]+$' && echo num)" "num"
check "changing the per-table stripe_row_limit changes the estimated cost" \
	"$([ -n "$c1" ] && [ -n "$c2" ] && [ "$c1" != "$c2" ] && echo differ)" "differ"
check "backend alive" "$(q 'SELECT 1')" "1"
pgc_summary
