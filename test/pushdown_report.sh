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
	echo "$1" | grep -q 'Columnar Projected Columns' && echo yes || echo no
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

pgc_summary
