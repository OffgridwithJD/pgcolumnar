#!/usr/bin/env bash
#
# pgColumnar native index-only scan (Phase D6c): after VACUUM marks a native
# (PGCN v1) table's all-visible row groups in the visibility map, an index-only
# scan over an all-visible range skips the fetch (Heap Fetches: 0) and returns the
# same rows as a heap mirror. A delete clears the VM bit (clear-on-write), so the
# scan falls back to the fetch and never returns a deleted row.
#
# Usage:  test/native_ios.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# One row group (large stripe limit) so an interior id range maps to blocks wholly
# inside an all-visible group.
psql_run "CREATE TABLE ioh (id int, v text);"
psql_run "CREATE TABLE ios (id int, v text) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('ios', stripe_row_limit => 16384);"
GEN="SELECT g, 'r'||g FROM generate_series(1, 8000) g"
psql_run "INSERT INTO ioh $GEN;"
psql_run "INSERT INTO ios $GEN;"
psql_run "CREATE INDEX ios_id ON ios (id);"

psql_run "ALTER DATABASE $PGC_DB SET pgcolumnar.enable_index_only_scan = on;"
psql_run "ALTER DATABASE $PGC_DB SET pgcolumnar.enable_custom_scan = off;"
psql_run "ALTER DATABASE $PGC_DB SET enable_seqscan = off;"
psql_run "ALTER DATABASE $PGC_DB SET enable_bitmapscan = off;"

psql_run "VACUUM ios;"   # mark all-visible row groups in the VM fork

check "row count" "$(q 'SELECT count(*) FROM ios;')" "8000"

planon="$(q 'EXPLAIN (COSTS OFF) SELECT id FROM ios WHERE id BETWEEN 1000 AND 5000;')"
check "index-only scan chosen" "$(printf '%s' "$planon" | grep -c 'Index Only Scan')" "1"

eaav="$(q 'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT id FROM ios WHERE id BETWEEN 1000 AND 5000;')"
check "all-visible interior: zero heap fetches" \
	"$(printf '%s' "$eaav" | grep -oE 'Heap Fetches: [0-9]+' | grep -oE '[0-9]+' | head -1)" "0"

check "index-only results match heap (all-visible)" \
	"$(pgc_set_hash 'SELECT id FROM ios WHERE id BETWEEN 1000 AND 5000')" \
	"$(pgc_set_hash 'SELECT id FROM ioh WHERE id BETWEEN 1000 AND 5000')"

# --- the VM has to be recorded in the catalog, not only written (#507) --------
#
# The zero-fetch check above proves the VM fork is populated. That is not the
# whole job: rel->allvisfrac is derived from pg_class.relallvisible, and core's
# cost_index prices an index-only scan by it. A relation whose VM is full and
# whose relallvisible is 0 is therefore priced as though every row needs a fetch,
# and the planner declines the scan it should choose. Measured on 20,000,000
# rows: the index-only scan ran 187.8 ms against the 361.4 ms plan preferred over
# it, priced 48,117 against 24,628.
#
# The heap mirror is the oracle rather than a number written here, so this
# asserts "the same thing core does for a heap on the same rows" rather than a
# constant that would have to be maintained alongside the code it checks.
psql_run "VACUUM ioh;"
check "premise: core records all-visible pages for the heap mirror (#507 oracle)" \
	"$(q "SELECT relallvisible > 0 FROM pg_class WHERE relname = 'ioh';")" "t"
check "VACUUM records the all-visible pages in pg_class (#507)" \
	"$(q "SELECT relallvisible > 0 FROM pg_class WHERE relname = 'ios';")" "t"

# Non-zero is not the same as right, and the way this goes wrong is a unit error
# rather than a logic one. The VM is keyed by SYNTHETIC blocks (rowNumber / K)
# while relpages counts stored pages; on a 20,000,000-row table that is 68,730
# against 45,994. Storing a block count would satisfy the check above and give
# core an all-visible fraction of 1.49 to divide with.
#
# Premise first: relallvisible is meaningless if relpages is zero, and the
# conversion is skipped entirely in that case, so a silent no-op would otherwise
# reach the checks below as a division by zero rather than as a failure.
check "premise: the relation has pages and rows to be a fraction of (#507)" \
	"$(q "SELECT relpages > 0 AND reltuples > 0 FROM pg_class WHERE relname = 'ios';")" "t"

# An upper bound that owes nothing to this implementation: a relation cannot
# have more all-visible pages than pages. A synthetic block count is free to
# exceed it, and on a large relation it does.
check "the all-visible page count cannot exceed the relation (#507)" \
	"$(q "SELECT relallvisible <= relpages FROM pg_class WHERE relname = 'ios';")" "t"

# ...and a lower bound, because a fraction can be arithmetically sane and still
# wrong. The heap mirror on identical rows is the oracle rather than a number
# written here. Deliberately loose: our bits are set only for blocks lying
# ENTIRELY within an all-visible run, so the partial block at each end stays
# clear and the columnar fraction is legitimately a little under the heap's.
# Half is far below that boundary loss and far above either failure mode -- a
# wrong unit lands above the heap's fraction, a stray small value well under it.
check "the all-visible fraction is most of the relation, as the heap's is (#507)" \
	"$(q "SELECT (SELECT relallvisible::float8 / relpages FROM pg_class WHERE relname = 'ios')
	          >= 0.5 * (SELECT relallvisible::float8 / relpages FROM pg_class WHERE relname = 'ioh');")" "t"

# A delete clears the VM bit for the affected blocks; the scan falls back to the
# fetch there and must never return a deleted row.
psql_run "DELETE FROM ios WHERE id BETWEEN 2000 AND 2200;"
psql_run "DELETE FROM ioh WHERE id BETWEEN 2000 AND 2200;"
check "index-only results match heap after delete" \
	"$(pgc_set_hash 'SELECT id FROM ios WHERE id BETWEEN 1000 AND 5000')" \
	"$(pgc_set_hash 'SELECT id FROM ioh WHERE id BETWEEN 1000 AND 5000')"
eadel="$(q 'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT id FROM ios WHERE id BETWEEN 1000 AND 5000;')"
hf="$(printf '%s' "$eadel" | grep -oE 'Heap Fetches: [0-9]+' | grep -oE '[0-9]+' | head -1)"
check "after delete: some heap fetches occur" "$([ "${hf:-0}" -gt 0 ] && echo yes || echo no)" "yes"

pgc_summary
