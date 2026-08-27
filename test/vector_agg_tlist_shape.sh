#!/usr/bin/env bash
#
# The vectorized aggregate accepts a target list that CONTAINS aggregates, not
# only one that IS them (#755).
#
# The ungrouped vectorized path used to require every target-list entry to be a
# bare Aggref. An entry that merely contained one -- `count(*)::text`,
# `avg(a)+avg(b)`, `round(avg(a),2)`, `max(a)-min(a)` -- fell off the path
# entirely, and on an unfiltered columnar table that is the difference between
# answering from the zone maps and scanning the whole relation. Measured on
# 8,000,000 rows before the change: count(*) 0.030 ms against count(*)::text
# 634.1 ms.
#
# THE RISK IS A WRONG ANSWER, NOT A SLOW ONE. The node emits one bare aggregate
# per output column and a projection above it computes the expressions, so a
# mis-built projection returns the wrong column, the wrong aggregate, or the
# right value in the wrong place. Every arm below therefore asserts the ANSWER
# against a heap table holding identical rows, and asserts the plan separately.
# A plan check alone cannot see a wrong result; an answer check alone cannot see
# that the fast path was never taken.
#
# Usage:  test/vector_agg_tlist_shape.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# NULLs and duplicate values on purpose: an aggregate's null handling is part of
# what the projection must not disturb, and ties are where a wrong column shows.
psql_run "CREATE TABLE h (id int, a int, b int, v float8, t text) USING heap;"
psql_run "INSERT INTO h SELECT g,
                CASE WHEN g % 101 = 0 THEN NULL ELSE (g * 7919) % 1000 END,
                (g * 104729) % 97,
                (g % 13)::float8,
                'v' || (g % 7)
           FROM generate_series(1, 20000) g;"
psql_run "CREATE TABLE c (LIKE h) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('c', stripe_row_limit => 2000, chunk_group_row_limit => 500);"
psql_run "INSERT INTO c SELECT * FROM h;"
psql_run "ANALYZE h; ANALYZE c;"

# ansq below compares through pgc_seq_hash, which is order-sensitive. Assert the
# oracle can actually fail on order before relying on it (selftest 260).
pgc_check_ordered_oracle

check "premise: both tables hold the same rows" \
	"$(q 'SELECT count(*) FROM c;')" "$(q 'SELECT count(*) FROM h;')"
check "premise: the sort column has NULLs, which the aggregates must skip" \
	"$([ "$(q 'SELECT count(*) FROM c WHERE a IS NULL;')" -gt 0 ] && echo yes || echo no)" "yes"

# Vectorized-aggregate node count in the plan. The whole question is which path
# ran, so this is asserted per arm rather than assumed.
vec() { q "SELECT count(*) FROM (SELECT 1) z;" >/dev/null
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "EXPLAIN (COSTS OFF) $1" 2>/dev/null \
		| grep -cE 'Columnar Vectorized Aggregates: [1-9]'; }

# ansq LABEL QUERY-with-%T : identical answer from heap and columnar.
ansq() {
	local label="$1" tmpl="$2"
	check_text "$label" "$(pgc_seq_hash "${tmpl//%T/c}")" "$(pgc_seq_hash "${tmpl//%T/h}")"
}
# both: the plan took the fast path AND the answer matches heap
both() {
	local label="$1" tmpl="$2" q_c="${2//%T/c}"
	check "$label: vectorized" "$([ "$(vec "$q_c")" -gt 0 ] && echo yes || echo no)" "yes"
	ansq "$label: answer matches heap" "$tmpl"
}

# ---------------------------------------------------------- already worked

both "a bare aggregate"            'SELECT avg(a) FROM %T'
both "two bare aggregates"         'SELECT avg(a), avg(b) FROM %T'
both "count(*)"                    'SELECT count(*) FROM %T'
both "min and max"                 'SELECT min(a), max(a) FROM %T'

# ------------------------------------------------- newly accepted shapes

both "a cast on an aggregate"      'SELECT count(*)::text FROM %T'
both "a sum of two aggregates"     'SELECT avg(a)+avg(b) FROM %T'
both "a difference of aggregates"  'SELECT max(a)-min(a) FROM %T'
both "an aggregate in a function"  'SELECT round(avg(a)::numeric, 2) FROM %T'
both "an aggregate times a const"  'SELECT avg(a)*2 FROM %T'
both "mixed bare and wrapped"      'SELECT count(*), count(*)::text, avg(a) FROM %T'
both "a constant beside aggregates" 'SELECT 1, count(*), avg(a) FROM %T'
both "the same aggregate twice"    'SELECT avg(a)+avg(a) FROM %T'
both "aggregates in both orders"   'SELECT max(a)-min(a), min(a)-max(a) FROM %T'
both "a CASE over aggregates"      'SELECT CASE WHEN count(*) > 0 THEN avg(a) ELSE NULL END FROM %T'

# A WHERE routes to the SCAN-FOLD path, which is behind
# pgcolumnar.enable_ungrouped_vector_agg and that GUC is OFF by default. So a
# filtered aggregate declines with or without this change, and an arm that did
# not set it would be measuring the opt-in rather than the target-list shape.
# With it on, the relaxation applies there too.
vec_sf() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "SET pgcolumnar.enable_ungrouped_vector_agg=on" \
		-c "EXPLAIN (COSTS OFF) $1" 2>/dev/null \
		| grep -cE 'Columnar Vectorized Aggregates: [1-9]'
}
check "premise: the scan-fold GUC is off by default, so a filter declines" \
	"$([ "$(vec 'SELECT avg(a) FROM c WHERE b < 40')" -gt 0 ] && echo yes || echo no)" "no"
check "premise: and a BARE aggregate takes it once the GUC is on" \
	"$([ "$(vec_sf 'SELECT avg(a) FROM c WHERE b < 40')" -gt 0 ] && echo yes || echo no)" "yes"
check "a wrapped aggregate takes the scan-fold path too" \
	"$([ "$(vec_sf 'SELECT round(avg(a)::numeric,2) FROM c WHERE b < 40')" -gt 0 ] && echo yes || echo no)" "yes"
ansq "and the filtered wrapped answer matches heap" \
	'SELECT round(avg(a)::numeric,2) FROM %T WHERE b < 40'
both "count of a nullable column wrapped" 'SELECT count(a)::text, count(*)::text FROM %T'

# Column ORDER is what a mis-built projection gets wrong while every individual
# value is still right, so an arm whose columns are deliberately not in
# aggregate order.
both "output order differs from aggregate order" \
	'SELECT max(a), min(a), count(*), avg(a) FROM %T'
both "an aggregate used in two different expressions" \
	'SELECT avg(a)+1, avg(a)*2, avg(a) FROM %T'

# --------------------------------------------------------- refusal arms
#
# Shapes that must still decline. These pass trivially if the feature were
# removed, so the over-accepting mutation in the PR is what proves them.

check "REFUSE: a bare column is not an ungrouped aggregate shape" \
	"$([ "$(vec 'SELECT a, count(*) FROM c GROUP BY a')" -gt 0 ] && echo yes || echo no)" "no"
ansq "and GROUP BY still answers correctly" \
	'SELECT a, count(*) FROM %T GROUP BY a ORDER BY a NULLS LAST'

check "REFUSE: an unsupported aggregate declines the whole target list" \
	"$([ "$(vec "SELECT count(*)::text, string_agg(t, ',') FROM c")" -gt 0 ] && echo yes || echo no)" "no"
ansq "and it still answers correctly" \
	"SELECT count(*)::text, length(string_agg(t, ',')) FROM %T"

check "REFUSE: an aggregate over an expression of two columns" \
	"$([ "$(vec 'SELECT sum(a + b) FROM c')" -gt 0 ] && echo yes || echo no)" "no"
ansq "and it still answers correctly" 'SELECT sum(a + b) FROM %T'

pgc_summary
