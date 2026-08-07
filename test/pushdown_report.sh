#!/usr/bin/env bash
#
# pgColumnar: EXPLAIN must report the pushdown the scan performs, not the
# pushdown the planner offered it (#191).
#
# pgcolumnar_enable_qual_pushdown gates pgcolumnar_build_predicates in
# PgColumnarBeginRead, so with the setting off the reader builds no predicates and
# skips no chunk groups. cstate->nScanKeys is the planner's count and does not
# move, so EXPLAIN reported the same "Columnar Pushed-Down Filters: 1" either
# way -- telling someone who had just turned the setting off to test a theory
# that it had not taken effect.
#
# The controls below are the point of the file. Reporting 0 is easy to fake: a
# fix that reported 0 unconditionally, or that broke pushdown outright, would
# pass the headline check. So each reported number is paired with an observable
# consequence in the same plan -- rows removed by the executor's filter, and
# chunk groups skipped by the reader.
#
# Usage:  test/pushdown_report.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=${PGC_PUSHDOWN_ROWS:-200000}

# One matching row in a table many chunk groups wide, so that skipping has
# something substantial to skip and its absence is equally visible.
psql_run "DROP TABLE IF EXISTS pdr;
	CREATE TABLE pdr (id int, k int) USING pgcolumnar;
	SELECT pgcolumnar.set_options('pdr', chunk_group_row_limit => 1000);" >/dev/null
psql_run "INSERT INTO pdr SELECT g, g FROM generate_series(1, $ROWS) g;" >/dev/null

# EXPLAIN ANALYZE of the same query under each setting. COSTS/TIMING off so the
# only things that vary are the counters we are asserting on.
plan() {
	q "SET pgcolumnar.enable_qual_pushdown = $1;
	   EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
	   SELECT * FROM pdr WHERE id = 1;"
}

field() { echo "$1" | grep -oE "$2: [0-9]+" | head -1 | grep -oE '[0-9]+$'; }

# Is this plan the scalar columnar custom scan, and not something else?
#
# "Columnar Projected Columns" is that node's own marker: the vectorized
# aggregate node does not report it, and no other node reports it at all. A
# positive grep for the node's marker is a stronger test than an absence test,
# because a plan that fell back to a seq scan has no Columnar lines to be absent.
is_scalar_scan() {
	grep -q 'Columnar Projected Columns' <<<"$1" && echo yes || echo no
}

on="$(plan on)"
off="$(plan off)"

# --- 0. the node, before any number read from it --------------------------------

# Every check below reads a counter out of these two plans and believes it. If
# the planner ever stops choosing the columnar custom scan here -- a costing
# change, a new path, a GUC default -- those counters go missing or come from
# somewhere else, and a suite that only compared numbers would report a fix
# where there was a plan change. This has to fail before anything is read.
check "the plan under test is a columnar custom scan" "$(is_scalar_scan "$on")" "yes"

# The setting under test must not be changing which node runs; if it did, every
# comparison between the two plans below would be comparing different things.
check "and it is still one with pushdown off" "$(is_scalar_scan "$off")" "yes"

# --- 1. the reported number follows the setting ---------------------------------

check "pushdown on reports a pushed-down filter" \
	"$(field "$on" 'Columnar Pushed-Down Filters')" "1"

check "pushdown off reports none" \
	"$(field "$off" 'Columnar Pushed-Down Filters')" "0"

# --- 2. and the report matches what the scan actually did -----------------------

# With pushdown on the reader skips chunk groups; with it off it reads them all.
# This is what makes the reported 0 truthful rather than merely different.
skipped_on="$(field "$on" 'Columnar Chunk Groups Removed by Filter')"
skipped_off="$(field "$off" 'Columnar Chunk Groups Removed by Filter')"

check "pushdown on skips chunk groups" \
	"$([ "${skipped_on:-0}" -gt 0 ] && echo yes || echo no)" "yes"

check "pushdown off skips none" "${skipped_off:-unset}" "0"

# --- 3. the setting really is doing something (not just being reported) ---------

# The executor's own filter has to remove everything the reader did not skip. If
# a "fix" disabled pushdown rather than reporting it honestly, this check would
# not notice -- but check 3 above would, which is why both are here.
removed_on="$(field "$on" 'Rows Removed by Filter')"
removed_off="$(field "$off" 'Rows Removed by Filter')"

check "the executor filters far more rows with pushdown off" \
	"$([ "${removed_off:-0}" -gt "${removed_on:-0}" ] && echo yes || echo no)" "yes"

check "pushdown off examines every row" "${removed_off:-unset}" "$((ROWS - 1))"

# --- 4. the query still returns the right answer either way ---------------------

# A pushdown that skipped a group it should have read would show up here and
# nowhere else in this file.
check "the answer is unchanged with pushdown on" \
	"$(q "SET pgcolumnar.enable_qual_pushdown = on;
		SELECT count(*) || '/' || coalesce(sum(id), 0) FROM pdr WHERE id BETWEEN 5000 AND 5100;" | tail -1)" \
	"101/510050"

check "the answer is unchanged with pushdown off" \
	"$(q "SET pgcolumnar.enable_qual_pushdown = off;
		SELECT count(*) || '/' || coalesce(sum(id), 0) FROM pdr WHERE id BETWEEN 5000 AND 5100;" | tail -1)" \
	"101/510050"

# --- 5. more than one qual is counted, so the number is a count not a flag ------

two="$(q "SET pgcolumnar.enable_qual_pushdown = on;
	EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
	SELECT * FROM pdr WHERE id > 100 AND id < 200;")"

check "two quals report two pushed-down filters" \
	"$(field "$two" 'Columnar Pushed-Down Filters')" "2"

# --- 6. a filter that is pushed down but cannot exclude anything (#479) ---------
#
# "Columnar Pushed-Down Filters" counts the scan keys the reader was HANDED.
# The reader then converts each into a skip predicate and can drop it -- and a
# dropped key excludes no chunk group at all, while the line above still reports
# it as pushed down. That is how #477 stayed invisible for a year: a bigint
# column against a bare integer literal reported
#
#     Columnar Pushed-Down Filters: 1
#     Columnar Chunk Groups Removed by Filter: 0
#
# which reads as "pushdown works, this predicate is just not selective" and
# actually meant "the predicate was never usable". test/zonemap_cost.sh sat in
# exactly that state for its whole life, and #460's cost discount was validated
# against it.
#
# "Columnar Usable Skip Predicates" is the second number: how many predicates
# the reader built and can exclude with. The two together say which case you are
# in.
#
# The fixture is a DOMAIN column, which the issue's own Test section did not
# propose and which is the shape that survives #478. A domain resolves to its
# base type in GetDefaultOpClass, so pgcolumnar_clause_to_scankey finds a btree
# opfamily and a strategy and builds the key; but in pgcolumnar_make_predicates
# the column type is the domain while the constant's type is the base, so the
# key is cross-type, and integer_ops has no BTORDER proc for (domain, int4).
# #478's fallback drops it. Ordinary SQL, and it prunes nothing.
#
# (The fixture the issue DOES propose -- a same-type predicate on a column with
# no btree comparison -- cannot show this at all: clause_to_scankey rejects such
# a column outright, so no scan key is built and both numbers read 0.)
#
# Both columns hold the same values in the same table, so the two arms differ
# only in the declared type of the column being compared: the physical layout,
# the row groups and their min/max are identical by construction.
psql_run "DROP TABLE IF EXISTS pdr_u;
	DROP DOMAIN IF EXISTS pdr_acct;
	CREATE DOMAIN pdr_acct AS int;
	CREATE TABLE pdr_u (plain int, dom pdr_acct) USING pgcolumnar;
	SELECT pgcolumnar.set_options('pdr_u', stripe_row_limit => 10000);" >/dev/null
psql_run "INSERT INTO pdr_u
	SELECT g, g::pdr_acct FROM generate_series(1, $ROWS) g;" >/dev/null

uplan() {  # uplan <column>
	q "SET pgcolumnar.enable_qual_pushdown = on;
	   EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
	   SELECT count(*) FROM pdr_u WHERE $1 > $((ROWS - 10000));"
}

usable="$(uplan plain)"
unusable="$(uplan dom)"

# The node again, before any number is read out of either plan. Neither of these
# queries is the one checked above and the planner is free to choose differently.
check "the usable arm is a columnar custom scan" "$(is_scalar_scan "$usable")" "yes"
check "the unusable arm is a columnar custom scan" "$(is_scalar_scan "$unusable")" "yes"

# The premise that makes the whole section mean something: these two arms really
# do prune differently. Without this, "1 usable" against "0 usable" could be two
# labels on identical behaviour -- which is the #477 failure repeated one level
# up, asserting a derived number with no physical fact under it.
check "the usable arm removes chunk groups" \
	"$([ "$(field "$usable" 'Columnar Chunk Groups Removed by Filter')" -gt 0 ] \
		&& echo yes || echo no)" "yes"
# This one pins a KNOWN-WRONG behaviour deliberately. A domain column ought to
# prune exactly as its base type does, and it does not (#483). This suite needs
# some predicate the reader cannot use, and that is the only one available on
# current main; when #483 is fixed, this check goes red and whoever fixed it must
# supply a new unusable fixture rather than delete the section. Pinned as an
# assertion and not an echo, because nobody reads a passing suite's output.
check "the unusable arm removes none" \
	"$(field "$unusable" 'Columnar Chunk Groups Removed by Filter')" "0"

# Both are reported as pushed down. This is the defect: the old line alone
# cannot tell these two plans apart.
check "both arms report the filter as pushed down" \
	"$(field "$usable" 'Columnar Pushed-Down Filters')/$(field "$unusable" 'Columnar Pushed-Down Filters')" \
	"1/1"

# And the new line does tell them apart.
check "the usable arm reports one usable skip predicate" \
	"$(field "$usable" 'Columnar Usable Skip Predicates')" "1"
check "the unusable arm reports none" \
	"$(field "$unusable" 'Columnar Usable Skip Predicates')" "0"

# With pushdown off the reader builds no predicates at all, so the new line must
# follow the setting too -- otherwise it would report a capability the run did
# not have, which is the #191 complaint about the old line.
check "pushdown off reports no usable skip predicates" \
	"$(field "$off" 'Columnar Usable Skip Predicates')" "0"

# --- 7. the two vectorized aggregate nodes report it too (#479) -----------------
#
# "Columnar Pushed-Down Filters" is printed by three nodes, not one: the scalar
# scan above, and both vectorized aggregate nodes, which fill it from
# PgColumnarCountConvertibleQuals -- the same built-key count, with the same gap
# under it. Measured on this same domain fixture before the fix, all three
# reported "1" while removing 0 of 20 chunk groups.
#
# Leaving two of the three unfixed would make one line of plan text mean two
# different things depending on which node ran, which is worse than the defect.
#
# Both nodes are opt-in, so each arm asserts its own node fired FIRST. Without
# that, a query the node quietly declines falls back to core Agg over the scalar
# scan -- which now reports the new line correctly, so the check would pass while
# testing the node it was written for not at all.
aggplan() {  # aggplan <guc> <sql>
	q "SET pgcolumnar.enable_qual_pushdown = on;
	   SET $1 = on;
	   EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) $2;"
}
has() { grep -q "$2" <<<"$1" && echo yes || echo no; }

UAGG=pgcolumnar.enable_ungrouped_vector_agg
u_usable="$(aggplan $UAGG "SELECT count(*), sum(plain) FROM pdr_u WHERE plain > $((ROWS - 10000))")"
u_unusable="$(aggplan $UAGG "SELECT count(*), sum(plain) FROM pdr_u WHERE dom > $((ROWS - 10000))")"

check "the ungrouped vectorized aggregate node ran (usable arm)" \
	"$(has "$u_usable" 'Columnar Vectorized Aggregates')" "yes"
check "the ungrouped vectorized aggregate node ran (unusable arm)" \
	"$(has "$u_unusable" 'Columnar Vectorized Aggregates')" "yes"

check "ungrouped: the usable arm removes chunk groups" \
	"$([ "$(field "$u_usable" 'Columnar Chunk Groups Removed by Filter')" -gt 0 ] \
		&& echo yes || echo no)" "yes"
check "ungrouped: the unusable arm removes none" \
	"$(field "$u_unusable" 'Columnar Chunk Groups Removed by Filter')" "0"

check "ungrouped: both arms report the filter as pushed down" \
	"$(field "$u_usable" 'Columnar Pushed-Down Filters')/$(field "$u_unusable" 'Columnar Pushed-Down Filters')" \
	"1/1"
check "ungrouped: and the usable skip predicates tell them apart" \
	"$(field "$u_usable" 'Columnar Usable Skip Predicates')/$(field "$u_unusable" 'Columnar Usable Skip Predicates')" \
	"1/0"

GAGG=pgcolumnar.enable_group_vectorization
g_usable="$(aggplan $GAGG "SELECT dom, count(*) FROM pdr_u WHERE plain > $((ROWS - 10000)) GROUP BY 1")"
g_unusable="$(aggplan $GAGG "SELECT plain, count(*) FROM pdr_u WHERE dom > $((ROWS - 10000)) GROUP BY 1")"

# "Columnar Vectorized Group Keys" is this node's own marker; no other node emits
# it, so a positive grep proves the node rather than an absence a fallback would
# also satisfy.
check "the grouped vectorized aggregate node ran (usable arm)" \
	"$(has "$g_usable" 'Columnar Vectorized Group Keys')" "yes"
check "the grouped vectorized aggregate node ran (unusable arm)" \
	"$(has "$g_unusable" 'Columnar Vectorized Group Keys')" "yes"

check "grouped: the usable arm removes chunk groups" \
	"$([ "$(field "$g_usable" 'Columnar Chunk Groups Removed by Filter')" -gt 0 ] \
		&& echo yes || echo no)" "yes"
check "grouped: the unusable arm removes none" \
	"$(field "$g_unusable" 'Columnar Chunk Groups Removed by Filter')" "0"

check "grouped: both arms report the filter as pushed down" \
	"$(field "$g_usable" 'Columnar Pushed-Down Filters')/$(field "$g_unusable" 'Columnar Pushed-Down Filters')" \
	"1/1"
check "grouped: and the usable skip predicates tell them apart" \
	"$(field "$g_usable" 'Columnar Usable Skip Predicates')/$(field "$g_unusable" 'Columnar Usable Skip Predicates')" \
	"1/0"

pgc_summary
