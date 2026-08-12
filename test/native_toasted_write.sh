#!/usr/bin/env bash
#
# pgColumnar: writing a TOASTED varlena is correct (#445 detoast-once).
#
# The writer flattens each varlena value once per row and reuses the flat Datum
# for the encoder, the bloom hash and the min/max comparisons, rather than
# letting each of those detoast the value independently (for a compressed value,
# each is a full decompression -- ~11% of a large-text load, #445's write-path
# detoast_attr). This suite guards the CORRECTNESS of that flatten-once path,
# which the other write suites do not reach because they use short, non-toasted
# values. The perf win is a timing, not a check here; the removal proof for the
# optimisation is the load time, recorded on the PR.
#
# The source is a HEAP table, so its wide values are stored pglz-compressed and
# reading it back hands the columnar writer already-toasted varlenas -- the exact
# input the flatten-once path exists for. The heap mirror is the oracle.
#
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# big is ~3.2 kB and compressible, so heap stores it toasted (pglz). small is a
# non-toasted varlena, so both branches of the flatten (copy vs no-copy) run.
psql_run "CREATE TABLE src (k int, big text, small text);"
psql_run "INSERT INTO src SELECT g, repeat(md5((g % 777)::text), 100) || chr(65 + (g % 26)), (g % 50)::text FROM generate_series(1, 60000) g;"
psql_run "CREATE TABLE h (k int, big text, small text);"
psql_run "CREATE TABLE c (k int, big text, small text) USING pgcolumnar;"
psql_run "INSERT INTO h SELECT * FROM src;"
psql_run "INSERT INTO c SELECT * FROM src;"

q() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atqc "$1" 2>/dev/null
}

# If this ever reads non-pglz, the fixture stopped toasting and the suite is no
# longer exercising the path it exists for.
check_text "premise: the source values are toasted (pglz)" \
	"$(q "SELECT pg_column_compression(big) FROM src LIMIT 1")" "pglz"

# The value bytes must survive the flatten-once path exactly.
check_text "toasted values are byte-identical to the heap mirror" \
	"$(q "SELECT md5(string_agg(big, '|' ORDER BY k)) FROM c")" \
	"$(q "SELECT md5(string_agg(big, '|' ORDER BY k)) FROM h")"

# min/max is built from the flattened value; a range prune must match heap.
check_num "the min/max zone map is correct (range count matches heap)" \
	"$(q "SELECT count(*) FROM c WHERE big > repeat('z', 10)")" \
	"$(q "SELECT count(*) FROM h WHERE big > repeat('z', 10)")"

# the bloom hash is taken from the flattened value; equality must match heap.
check_num "equality on a toasted value (bloom + recheck) matches heap" \
	"$(q "SELECT count(*) FROM c WHERE big = (SELECT big FROM src WHERE k = 12345)")" \
	"$(q "SELECT count(*) FROM h WHERE big = (SELECT big FROM src WHERE k = 12345)")"

# the short non-toasted column must be unaffected.
check_text "the non-toasted column is byte-identical too" \
	"$(q "SELECT md5(string_agg(small, '|' ORDER BY k)) FROM c")" \
	"$(q "SELECT md5(string_agg(small, '|' ORDER BY k)) FROM h")"

pgc_summary
