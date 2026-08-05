#!/usr/bin/env bash
#
# CREATE INDEX projects only the columns the index needs (issue #413).
#
# pgcolumnar_index_build_range_scan opened its reader with no projection, so building a
# one-column index on a wide table decoded every column. It never had to: the callback
# receives IndexInfo, which carries ii_IndexAttrNumbers and the expression and predicate
# trees. The information was in its own arguments and was thrown away.
#
# Measured on 300,000 rows of 20 columns, index on the key alone, non-assert PG18:
#
#     before   columnar 1,403 ms   heap 149 ms   9.4x slower than heap
#     after    columnar    87 ms   heap 144 ms   1.65x faster
#
# What is asserted, in the order the risk sits:
#
#  1. the projection NARROWED, read from the build's own DEBUG1 line. A fix that
#     silently did nothing passes every correctness check below, and a wall-clock check
#     on a quiet machine, so this is the assertion with teeth.
#  2. expression and partial indexes project their EXTRA columns. Getting those wrong
#     evaluates against unset slot values, which is a wrong answer and not a slow one.
#  3. a forced index scan and a forced seq scan agree over the FULL ordered result.
#     Point lookups can be satisfied by an index that is wrong for keys nobody asked for.
#
# amcheck runs where the build has contrib and skips VISIBLY where it does not. Source
# builds have no contrib, and a silent skip is the defect this file exists to prevent.
#
# Usage:  test/native_index_projection.sh [PG_CONFIG]
# Written fresh for pgColumnar.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=${PGC_IDXPROJ_ROWS:-300000}

# lib.sh's q() emits psql's output for every statement, so "SET ...; SELECT ..." in one
# call returns "SET" as well as the value. Keep the session but read only the result.
qset() {  # $1 = SET clause(s), $2 = query
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -q -c "$1" -c "$2" 2>/dev/null | tail -1
}


# 20 columns: an int key, an int secondary, 18 wide text.
cols="k int, k2 int"
vals="g, g*2"
for i in $(seq 1 18); do cols="$cols, c$i text"; vals="$vals, repeat('x',80)||g"; done
psql_run "CREATE TABLE w ($cols) USING pgcolumnar;"
psql_run "INSERT INTO w SELECT $vals FROM generate_series(1,$ROWS) g;"
check "fixture rows" "$(q 'SELECT count(*) FROM w')" "$ROWS"
check "fixture is wide" \
	"$(q "SELECT count(*) FROM pg_attribute WHERE attrelid='w'::regclass AND attnum>0")" "20"

# The projection each build chose, from its own DEBUG1 line. This is the check a
# do-nothing fix would fail and the correctness checks below would not.
proj() {  # $1 index name, $2 CREATE INDEX statement -> "n of m"
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-c "SET client_min_messages=debug1;" -c "$2" 2>&1 \
		| grep -oE "index build on \"$1\" projecting [0-9]+ of [0-9]+" \
		| grep -oE '[0-9]+ of [0-9]+' | head -1
}

check "plain index projects one column of twenty" \
	"$(proj w_k    'CREATE INDEX w_k ON w (k)')" "1 of 20"
check "two-column index projects two" \
	"$(proj w_k12  'CREATE INDEX w_k12 ON w (k, k2)')" "2 of 20"
check "an index on a late column projects one, not everything before it" \
	"$(proj w_c18  'CREATE INDEX w_c18 ON w (c18)')" "1 of 20"
check "an expression index projects its expression's columns" \
	"$(proj w_expr 'CREATE INDEX w_expr ON w ((k + k2))')" "2 of 20"
check "a partial index projects the predicate's columns too" \
	"$(proj w_part 'CREATE INDEX w_part ON w (k) WHERE k2 > 100')" "2 of 20"
check "an expression over a text column projects that column" \
	"$(proj w_len  'CREATE INDEX w_len ON w ((length(c1)))')" "1 of 20"

# Correctness. An index built from under-projected data indexes unset slot values, so
# each of these must find what a sequential scan finds.
check "plain index finds the row" \
	"$(qset 'SET enable_seqscan=off' 'SELECT k2 FROM w WHERE k = 12345')" "24690"
check "expression index finds the row" \
	"$(qset 'SET enable_seqscan=off' 'SELECT count(*) FROM w WHERE (k + k2) = 30000')" "1"
check "partial index finds the row inside its predicate" \
	"$(qset 'SET enable_seqscan=off' 'SELECT count(*) FROM w WHERE k = 50000 AND k2 > 100')" "1"

# The oracle, depending on nothing but PostgreSQL. Compare the FULL ordered result of a
# forced index scan against a forced seq scan.
agree() {  # $1 label, $2 predicate, $3 selected expression
	local viaix viaseq
	viaix=$(qset "SET enable_seqscan=off; SET enable_bitmapscan=off" \
	              "SELECT md5(string_agg(t::text, ',' ORDER BY t))
	                 FROM (SELECT $3 AS t FROM w WHERE $2) s")
	viaseq=$(qset "SET enable_indexscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off" \
	              "SELECT md5(string_agg(t::text, ',' ORDER BY t))
	                 FROM (SELECT $3 AS t FROM w WHERE $2) s")
	check "$1" "$viaix" "$viaseq"
}
agree "plain index agrees with a sequential scan"   "k BETWEEN 1000 AND 9999"        "k"
agree "late-column index agrees"                    "c18 > repeat('x',80)||'99000'"  "k"
agree "expression index agrees"                     "(k + k2) BETWEEN 300 AND 30000" "k"
agree "partial index agrees on its subset"          "k2 > 100 AND k < 5000"          "k"
agree "text expression index agrees"                "length(c1) = 83"                "k"

# amcheck where available. The skip must be visible: a check that reports nothing is
# indistinguishable from a check that passes, which is what this file is about.
if psql_run "CREATE EXTENSION IF NOT EXISTS amcheck;" >/dev/null 2>&1 &&
	[ "$(q "SELECT count(*) FROM pg_proc WHERE proname='bt_index_check'")" != "0" ]; then
	for ix in w_k w_k12 w_c18 w_expr w_part w_len; do
		out=$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
			-d "$PGC_DB" -c "SELECT bt_index_check('$ix'::regclass)" 2>&1)
		check "bt_index_check($ix)" \
			"$(grep -qE 'ERROR' <<<"$out" && echo bad || echo ok)" "ok"
	done
else
	echo "SKIP  amcheck is not installed on this build; the seq-scan oracle above still ran"
fi

pgc_summary
