#!/usr/bin/env bash
#
# The ordering mark survives ALTER TABLE ... RENAME COLUMN (#778).
#
# pgcolumnar.storage records the applied sort key as a list of column NAMES
# (sorted_by name[]), and both ordering self-gates compare that stored list
# against the CURRENT attname of the requested columns -- vacuum_sorted's gate
# (#774) and recluster's (#415), character for character.
#
# Column names are not stable. A three-statement swap moves a name from one
# column to another, and if nothing maintains the mark, the stored name resolves
# to a DIFFERENT column. The gate then reports "already in this order" about a
# column that was never sorted, and skips work it must do. For vacuum_sorted
# that is the exact failure #760 exists to prevent, reached through another door:
# the table ends up neither sorted nor reclaimed, with no error.
#
# THE POSITIVE CONTROL IS LOAD-BEARING. A gate that never fires cannot fire
# wrongly, so every arm below that asserts a gate misfiring is preceded by one
# proving the same gate fires correctly on an untouched table. Without it a
# broken gate and a fixed one look identical.
#
# Usage:  test/sorted_mark_rename.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# Physical order as a DESCENT COUNT over the scan order: 0 means sorted
# ascending. An ORDER BY subquery cannot be used as the oracle here -- the
# planner is free to discard it, which makes both sides the same query and every
# arm pass vacuously.
descents() { q "SELECT count(*) FROM (SELECT $2 < lag($2) OVER () AS d FROM $1) z WHERE d;"; }
markof()   { q "SELECT COALESCE(s.sorted_by::text,'-')||'/'||COALESCE(s.sorted_kind,'-')
                FROM pgcolumnar.storage s WHERE s.storage_id = pgcolumnar.get_storage_id('$1');"; }
layout()   { q "SELECT md5(string_agg(stripeid::text||':'||fileoffset::text, ',' ORDER BY stripeid)) FROM pgcolumnar.stats('$1');"; }
storid()   { q "SELECT pgcolumnar.get_storage_id('$1');"; }

mk() {
	psql_run "DROP TABLE IF EXISTS $1;"
	psql_run "CREATE TABLE $1 (a int, b int) USING pgcolumnar;"
	psql_run "INSERT INTO $1 SELECT (g*7919::bigint)%2000, (g*104729::bigint)%2000
	          FROM generate_series(1,20000) g;"
	check_num "premise: $1 loaded every row (an overflowed INSERT would make an empty table look like a fired gate)" \
		"$(q "SELECT count(*) FROM $1;")" "20000"
}

swap() {   # a <-> b, three ordinary statements
	psql_run "ALTER TABLE $1 RENAME COLUMN a TO tmp_swap;"
	psql_run "ALTER TABLE $1 RENAME COLUMN b TO a;"
	psql_run "ALTER TABLE $1 RENAME COLUMN tmp_swap TO b;"
}

# ============================ vacuum_sorted ==================================
# ---- positive control: the gate fires on an untouched table ------------------
mk vr_ctl
check "premise: before sorting, a is not in order" \
	"$([ "$(descents vr_ctl a)" -gt 0 ] && echo unordered || echo ordered)" "unordered"
psql_run "SELECT pgcolumnar.vacuum_sorted('vr_ctl','a');"
check_num "premise: vacuum_sorted really ordered it by a" "$(descents vr_ctl a)" "0"
S="$(storid vr_ctl)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vr_ctl','a');"
check "CONTROL: a second identical call is a no-op, so the gate does fire" \
	"$([ "$S" = "$(storid vr_ctl)" ] && echo noop || echo rewrote)" "noop"

# ---- the defect: the same gate after a NAME SWAP ----------------------------
mk vr_t
psql_run "SELECT pgcolumnar.vacuum_sorted('vr_t','a');"
check "premise: vr_t is ordered by a" "$([ "$(descents vr_t a)" -eq 0 ] && echo ordered || echo unordered)" "ordered"
check "premise: and NOT by b" "$([ "$(descents vr_t b)" -gt 0 ] && echo unordered || echo ordered)" "unordered"
check "premise: the mark records key {a}" "$(markof vr_t)" "{a}/lexicographic"
swap vr_t
check "premise: after the swap the ordered column is the one now named b" \
	"$([ "$(descents vr_t b)" -eq 0 ] && echo ordered || echo unordered)" "ordered"
check "premise: and the column now named a is NOT ordered" \
	"$([ "$(descents vr_t a)" -gt 0 ] && echo unordered || echo ordered)" "unordered"

check "the mark FOLLOWS the rename, so it still names the ordered column" \
	"$(markof vr_t)" "{b}/lexicographic"

S="$(storid vr_t)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vr_t','a');"
check "THE POINT: vacuum_sorted('a') after the swap does the work" \
	"$([ "$S" = "$(storid vr_t)" ] && echo "SKIPPED (gate fired wrongly)" || echo rewrote)" "rewrote"
check_num "and the table really is ordered by a afterwards" "$(descents vr_t a)" "0"

# and the gate is still armed for the column that IS now recorded
S="$(storid vr_t)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vr_t','a');"
check "the gate still fires for the right key after all that" \
	"$([ "$S" = "$(storid vr_t)" ] && echo noop || echo rewrote)" "noop"

# ---- a rename that touches no sort-key column leaves the mark alone ---------
mk vr_o
psql_run "ALTER TABLE vr_o ADD COLUMN spare int;"
psql_run "SELECT pgcolumnar.vacuum_sorted('vr_o','a');"
M="$(markof vr_o)"
psql_run "ALTER TABLE vr_o RENAME COLUMN spare TO spare2;"
check "renaming an unrelated column does not disturb the mark" "$(markof vr_o)" "$M"
S="$(storid vr_o)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vr_o','a');"
check "and the gate still fires" \
	"$([ "$S" = "$(storid vr_o)" ] && echo noop || echo rewrote)" "noop"

# ============================ recluster (#415) ===============================
# The same comparison, character for character, in the online recluster gate.
mkz() {
	psql_run "DROP TABLE IF EXISTS $1;"
	psql_run "CREATE TABLE $1 (a int, b int, c int) USING pgcolumnar;"
	psql_run "SELECT pgcolumnar.set_options('$1', chunk_group_row_limit => 1000);"
	psql_run "INSERT INTO $1 SELECT (g*7919::bigint)%2000, (g*104729::bigint)%2000, g
	          FROM generate_series(1,20000) g;"
	check_num "premise: $1 loaded every row" "$(q "SELECT count(*) FROM $1;")" "20000"
}
mkz rr_ctl
FIRST="$(q "SELECT pgcolumnar.recluster('rr_ctl','a','b');")"
check "premise: the first recluster does real work" \
	"$([ "${FIRST:-0}" -gt 0 ] && echo yes || echo no)" "yes"
check_num "CONTROL: a repeat recluster on the same key is a no-op, so the gate fires" \
	"$(q "SELECT pgcolumnar.recluster('rr_ctl','a','b');")" "0"

mkz rr_t
psql_run "SELECT pgcolumnar.recluster('rr_t','a','b');"
check "premise: the mark records {a,b} as zorder" "$(markof rr_t)" "{a,b}/zorder"
# move an UNRELATED column onto the name 'b', so {a,b} would resolve to (a,c)
psql_run "ALTER TABLE rr_t RENAME COLUMN b TO b_old;"
psql_run "ALTER TABLE rr_t RENAME COLUMN c TO b;"
check "the mark follows both renames" "$(markof rr_t)" "{a,b_old}/zorder"
AFTER="$(q "SELECT pgcolumnar.recluster('rr_t','a','b');")"
check "recluster on the NEW (a,b) is not skipped as already done" \
	"$([ "${AFTER:-0}" -gt 0 ] && echo rewrote || echo "SKIPPED (gate fired wrongly)")" "rewrote"

pgc_summary
