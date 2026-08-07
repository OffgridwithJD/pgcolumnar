#!/usr/bin/env bash
#
# pgColumnar native zone-map row-group skipping (Phase D5b): a native-format
# (PGCN v1) table now takes the custom scan's scalar path, so pushed-down
# predicates drive zone-map skipping of whole row groups whose min/max prove no
# row can match (native spec 7.1). Skipping is a performance optimization only:
# the executor re-applies the full qual, so results are identical whether a group
# is skipped or not. This suite proves both halves: result parity with a heap
# mirror across range and equality predicates, and that groups are actually
# skipped (via the EXPLAIN ANALYZE "Columnar Chunk Groups Removed by Filter"
# counter), including that a non-selective scan skips nothing.
#
# Usage:  test/native_skip.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# 20480 rows, 2048-row groups -> 10 row groups with contiguous, non-overlapping
# id ranges (group k holds ids k*2048+1 .. (k+1)*2048), so range and equality
# predicates on id are highly skippable.
GEN="SELECT g, (g * 10)::bigint, 'lbl-' || (g % 100)
  FROM generate_series(1, 20480) g"

psql_run "CREATE TABLE h (id int, k bigint, label text);"
psql_run "CREATE TABLE n (id int, k bigint, label text) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('n', stripe_row_limit => 2048, chunk_group_row_limit => 1024);"
psql_run "INSERT INTO h $GEN;"
psql_run "INSERT INTO n $GEN;"

# Count of row groups skipped by the zone maps for a query, from EXPLAIN ANALYZE.
skipped() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) $1" 2>/dev/null \
		| grep 'Columnar Chunk Groups Removed by Filter' | grep -oE '[0-9]+' | head -1
}
gt0() { [ "${1:-0}" -gt 0 ] && echo yes || echo no; }

# The node, before any counter read out of it: every skipped() below returns a
# number only the columnar custom scan reports.
check "the plan under test is a columnar custom scan" \
	"$(pgc_is_columnar_scan 'SELECT id FROM n WHERE id BETWEEN 5000 AND 5100')" "yes"

check "row count" "$(q 'SELECT count(*) FROM n;')" "20480"
check "no-predicate scan returns all rows" "$(q 'SELECT count(*) FROM n;')" "$(q 'SELECT count(*) FROM h;')"

# Range predicate confined to one group: correct, and skips the other groups.
check "range result parity" \
	"$(pgc_set_hash 'SELECT id, k, label FROM n WHERE id BETWEEN 5000 AND 5100')" \
	"$(pgc_set_hash 'SELECT id, k, label FROM h WHERE id BETWEEN 5000 AND 5100')"
check "range skips groups" "$(gt0 "$(skipped 'SELECT id FROM n WHERE id BETWEEN 5000 AND 5100')")" "yes"

# Equality on the monotonic column skips groups too.
check "equality result parity" \
	"$(q 'SELECT count(*) FROM n WHERE id = 12345;')" \
	"$(q 'SELECT count(*) FROM h WHERE id = 12345;')"
check "equality skips groups" "$(gt0 "$(skipped 'SELECT id FROM n WHERE id = 12345')")" "yes"

# Predicate on the bigint column (k = id*10) is equally skippable.
check "bigint range parity" \
	"$(pgc_set_hash 'SELECT id FROM n WHERE k BETWEEN 100000::bigint AND 101000::bigint')" \
	"$(pgc_set_hash 'SELECT id FROM h WHERE k BETWEEN 100000::bigint AND 101000::bigint')"
check "bigint range skips groups" "$(gt0 "$(skipped 'SELECT id FROM n WHERE k BETWEEN 100000::bigint AND 101000::bigint')")" "yes"

# ---- the same predicate without the casts (#477) -----------------------------
#
# Those literals were cast to bigint so the comparison would be same-type, and
# this comment used to say cross-type operators were "deliberately not pushed
# down". They were not pushed down, and the consequence was not deliberate: an
# int8 column compared against a bare integer literal skipped NOTHING, which is
# what ordinary SQL looks like. Measured on identical data in two columns, one
# int and one bigint: `idi > 16000` removed 7 groups of 10, `seq > 16000` removed
# 0, and `seq > 16000::bigint` removed 7 again.
#
# EXPLAIN gave no way to see it. `Columnar Pushed-Down Filters` counts scan keys
# handed to the reader, not predicates able to exclude anything, so it read 1
# while zero groups were skipped. test/zonemap_cost.sh's correlated arm has been
# in that state since it was written.
#
# The parity check is first and is not decoration: the risk in comparing an int8
# column against an int4 constant is a WRONG answer, not a slow one, so rows come
# before skipping in the order these are asserted.
check "bigint vs integer literal returns the same rows as heap (#477)" \
	"$(pgc_set_hash 'SELECT id FROM n WHERE k BETWEEN 100000 AND 101000')" \
	"$(pgc_set_hash 'SELECT id FROM h WHERE k BETWEEN 100000 AND 101000')"

check "and it skips groups, which the cast version already did (#477)" \
	"$(gt0 "$(skipped 'SELECT id FROM n WHERE k BETWEEN 100000 AND 101000')")" "yes"

# One-sided and equality too, because they take different branches of
# native_zone_excludes and equality additionally gates the bloom probe.
check "one-sided bigint vs integer literal skips groups (#477)" \
	"$(gt0 "$(skipped 'SELECT id FROM n WHERE k > 150000')")" "yes"
check "one-sided parity" \
	"$(q 'SELECT count(*) FROM n WHERE k > 150000;')" \
	"$(q 'SELECT count(*) FROM h WHERE k > 150000;')"

check "bigint equality vs integer literal skips groups (#477)" \
	"$(gt0 "$(skipped 'SELECT id FROM n WHERE k = 123450')")" "yes"
check "bigint equality parity" \
	"$(q 'SELECT count(*) FROM n WHERE k = 123450;')" \
	"$(q 'SELECT count(*) FROM h WHERE k = 123450;')"

# A value no row holds must still come back empty. Cross-type equality disables
# the bloom probe (the filter hashes column-type values, so an int4 constant
# would probe the wrong slot), so this rides on min/max alone.
check "bigint equality on an absent value returns nothing" \
	"$(q 'SELECT count(*) FROM n WHERE k = 123451;')" "0"

# A predicate every group satisfies must skip nothing (correctness of the bound).
check "non-selective scan skips nothing" "$(skipped 'SELECT id FROM n WHERE id > 0')" "0"
check "non-selective parity" \
	"$(q 'SELECT count(*) FROM n WHERE id > 0;')" \
	"$(q 'SELECT count(*) FROM h WHERE id > 0;')"

# A predicate no group satisfies is fully skipped and returns nothing.
check "out-of-range returns nothing" "$(q 'SELECT count(*) FROM n WHERE id > 1000000;')" "0"

pgc_summary
