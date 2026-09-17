#!/usr/bin/env bash
#
# pgColumnar: a table-AM parallel scan must share work across workers.
#
# With the custom scan off, Parallel Seq Scan goes through the AM. The AM
# used to treat phs_nallocated as a first-wins flag: one backend claimed
# the whole scan and the others marked themselves exhausted. Workers
# launched, one backend read.
#
# The custom-scan path already claims distinct row groups from a shared
# counter. This suite pins the AM path to the same property, via EXPLAIN
# ANALYZE worker rows -- not internals. Leader participation is off so
# the two launched workers are the claimers under test, not the leader.
# Many small row groups keep both workers busy before either finishes
# the table.
#
# Independent of test/pytest/test_parallel_am_scan.py: same public seam, own
# fixture, own observations.
#
# Usage:  test/parallel_am_scan.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

N=50000
psql_run "CREATE TABLE pam (id int, k int, payload text) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('pam', chunk_group_row_limit => 100, stripe_row_limit => 1000);"
psql_run "INSERT INTO pam SELECT g, g%23, md5(g::text) FROM generate_series(1,$N) g;"
psql_run "ALTER TABLE pam SET (parallel_workers = 2);"
psql_run "ANALYZE pam;"

setg() { q "ALTER DATABASE $PGC_DB SET $1 = $2;" >/dev/null; }
setg pgcolumnar.enable_custom_scan off
setg parallel_setup_cost 0
setg parallel_tuple_cost 0
setg min_parallel_table_scan_size 0
setg jit off
setg parallel_leader_participation off

explain_text() {
	# $1 = max_parallel_workers_per_gather
	# $2 = ANALYZE or empty
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq \
		-c "SET max_parallel_workers_per_gather = $1;" \
		-c "EXPLAIN (COSTS OFF, VERBOSE $2) SELECT id FROM pam;"
}

serial_plan="$(explain_text 0 "")"
par_plan="$(explain_text 2 "")"
par_ana="$(explain_text 2 ", ANALYZE, TIMING OFF, SUMMARY OFF")"

echo "-- serial plan --"
echo "$serial_plan"
echo "-- parallel plan --"
echo "$par_plan"
echo "-- parallel analyze --"
echo "$par_ana"

# Per-worker actual rows from ANALYZE text. A worker that produced nothing
# still prints rows=0, so a missing line is not a zero -- it is no measurement.
worker_rows() {
	echo "$1" | grep -oE 'Worker [0-9]+:.*rows=[0-9]+' \
		| grep -oE 'rows=[0-9]+' | grep -oE '[0-9]+'
}

rows_list="$(worker_rows "$par_ana")"
n_lines="$(echo "$rows_list" | grep -c . || true)"
n_busy="$(echo "$rows_list" | awk '$1>0{n++} END{print n+0}')"
echo "-- worker rows: $(echo "$rows_list" | tr "\n" " ") busy=$n_busy lines=$n_lines"

check "premise: the table holds every inserted row" \
	"$(q "SELECT count(*) FROM pam")" "$N"

check "premise: with the custom scan off the serial plan is a Seq Scan" \
	"$(echo "$serial_plan" | grep -c 'Seq Scan')" "1"

check "premise: the serial plan is not a columnar custom scan" \
	"$(echo "$serial_plan" | grep -c 'Custom Scan')" "0"

check "premise: the parallel plan has Gather" \
	"$(echo "$par_plan" | grep -c 'Gather')" "1"

check "premise: the parallel plan uses two workers" \
	"$(echo "$par_plan" | grep -oE 'Workers Planned: [0-9]+' | head -1 | grep -oE '[0-9]+')" "2"

check "premise: the parallel plan is still a Seq Scan, not a custom scan" \
	"$(echo "$par_ana" | grep -c 'Seq Scan')" "1"

check "premise: EXPLAIN ANALYZE launched two workers" \
	"$(echo "$par_ana" | grep -oE 'Workers Launched: [0-9]+' | head -1 | grep -oE '[0-9]+')" "2"

check "premise: ANALYZE printed a rows= line per launched worker" \
	"$n_lines" "2"

serial_cnt="$(q "SET max_parallel_workers_per_gather = 0; SELECT count(*) FROM pam;" | grep -v '^SET$' | tail -1)"
par_cnt="$(q "SET max_parallel_workers_per_gather = 2; SELECT count(*) FROM pam;" | grep -v '^SET$' | tail -1)"
check "a parallel table-AM scan returns the same row count as serial" \
	"$par_cnt" "$serial_cnt"

# THE DEFECT: one backend's rows=N and every other worker's rows=0.
# Sharing means both launched workers produced rows.
check "workers share the table-AM scan, it is not a single claimer" \
	"$n_busy" "2"

# ---- a parallel INDEX BUILD is the other consumer of the shared claim --------
#
# Everything above drives the shared group claim through a parallel SEQ SCAN.
# A parallel index build reaches the same pgcolumnar_next_group_index through
# table_beginscan_parallel, and it is the consumer where a claim bug is silent:
# a scan that double-claims returns duplicate rows and someone notices, while an
# index that SKIPS a group is simply missing entries and every query using it
# quietly returns fewer rows.
#
# THE WORKER COUNT IS NOT A pgcolumnar GUC, AND max_parallel_maintenance_workers
# ALONE WILL NOT PRODUCE ONE. That GUC is a gate -- 0 builds serially -- but core
# sizes the request in plan_create_index_workers() from relpages, and a columnar
# table reports very few pages for many rows (measured: 69 pages for 2,000,000),
# so the size heuristic grants ONE worker however large the table is. The table's
# `parallel_workers` reloption is the only dial that produces real parallelism
# here, which is why it is set below and why a bigger fixture would not help.
psql_run "ALTER TABLE pam SET (parallel_workers = 4);"

# Own reader: `q` runs psql without -q, so a multi-statement call prints a SET
# line per SET and the value under test would be whatever came last. This takes
# the final line after dropping those. grep -v and tail both read to EOF, so
# neither can SIGPIPE the writer (#486).
_pam_read() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq -c "$1" 2>/dev/null | grep -v '^SET$' | tail -1
}

_pam_mark="pam_build_$$"
q "DO \$\$ BEGIN RAISE LOG '$_pam_mark'; END \$\$;" >/dev/null
q "DROP INDEX IF EXISTS pam_idx;" >/dev/null
q "SET log_min_messages = debug1;
   SET max_parallel_maintenance_workers = 4;
   SET min_parallel_table_scan_size = 0;
   CREATE INDEX pam_idx ON pam (id);" >/dev/null

# Scoped to a marker this run wrote, so a build from an earlier run in the same
# cluster cannot answer for this one.
_pam_req="$(awk -v m="$_pam_mark" '
		p && /with request for/ { print; exit }
		$0 ~ m                  { p = 1 }
	' "${PGC_LOGFILE:-/dev/null}")"
_pam_nreq="$(printf '%s' "$_pam_req" | tr -dc '0-9 ' | awk '{print $1+0}')"

check "premise: the index build requested parallel workers" \
	"$([ -n "$_pam_req" ] && [ "${_pam_nreq:-0}" -ge 2 ] && echo yes || echo "no (${_pam_nreq:-none})")" "yes"

# The plan is classified from a captured string with `case`, not a pipe into an
# early-exit reader.
_pam_planout="$(_pam_read "SET enable_seqscan=off;
                           SET pgcolumnar.enable_custom_scan=off;
                           EXPLAIN (COSTS OFF) SELECT count(*) FROM pam WHERE id > 0;")"
_pam_planall="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq -c "SET enable_seqscan=off;
		                      SET pgcolumnar.enable_custom_scan=off;
		                      EXPLAIN (COSTS OFF) SELECT count(*) FROM pam WHERE id > 0;" 2>/dev/null)"
case "$_pam_planall" in
	*"Index Only Scan"*)	_pam_node="Index Only Scan" ;;
	*"Index Scan"*)		_pam_node="Index Scan" ;;
	*"Seq Scan"*)		_pam_node="Seq Scan" ;;
	*)			_pam_node="" ;;
esac

check "premise: the comparison reads the table through the index" \
	"$_pam_node" "Index Only Scan"

# THE PROPERTY: the index built in parallel describes the whole table. Compared
# as an aggregate through the index against the same aggregate through a
# sequential scan -- a count alone would miss a group read twice and a group
# skipped cancelling out, which the sum does not.
_pam_idx="$(_pam_read "SET enable_seqscan=off; SET pgcolumnar.enable_custom_scan=off;
                       SELECT count(*) || '|' || coalesce(sum(id),0) FROM pam WHERE id > 0;")"
_pam_seq="$(_pam_read "SET enable_indexscan=off; SET enable_bitmapscan=off;
                       SELECT count(*) || '|' || coalesce(sum(id),0) FROM pam WHERE id > 0;")"

check "premise: both sides of the comparison returned a value" \
	"$([ -n "$_pam_idx" ] && [ -n "$_pam_seq" ] && echo yes || echo no)" "yes"

# FAIL CLOSED. If the build errored, BOTH reads come back empty and comparing
# "" against "" reports PASS -- measured: mutating the shared claim so every
# participant walks its own index made the build fail, both reads returned
# nothing, and this check passed on a tree where the property was broken. The
# premise above caught it, but a headline check that says PASS when it measured
# nothing is worse than no check. Distinct sentinels cannot collide.
check "a parallel index build indexes every row of the table" \
	"${_pam_idx:-<the index read returned nothing>}" \
	"${_pam_seq:-<the sequential read returned nothing>}"

pgc_summary
