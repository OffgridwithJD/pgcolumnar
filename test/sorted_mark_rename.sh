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
# The mark's CONTENT is unchanged either way, because rewriting it with the same
# names produces the same names. So content alone cannot see whether the write
# was skipped; xmin can. Without the early return this arm goes red while every
# other arm in the file stays green.
XMIN="$(q "SELECT xmin::text FROM pgcolumnar.storage WHERE storage_id = pgcolumnar.get_storage_id('vr_o');")"
psql_run "ALTER TABLE vr_o RENAME COLUMN spare TO spare2;"
check "renaming an unrelated column does not disturb the mark" "$(markof vr_o)" "$M"
check "and does not rewrite the storage row at all (xmin unchanged)" \
	"$(q "SELECT xmin::text FROM pgcolumnar.storage WHERE storage_id = pgcolumnar.get_storage_id('vr_o');")" \
	"$XMIN"
check "premise: xmin CAN move, so the arm above is not comparing two constants" \
	"$(psql_run "ALTER TABLE vr_o RENAME COLUMN a TO a2;" >/dev/null 2>&1;
	   NEW="$(q "SELECT xmin::text FROM pgcolumnar.storage WHERE storage_id = pgcolumnar.get_storage_id('vr_o');")";
	   psql_run "ALTER TABLE vr_o RENAME COLUMN a2 TO a;" >/dev/null 2>&1;
	   [ "$NEW" != "$XMIN" ] && echo moved || echo stuck)" "moved"
S="$(storid vr_o)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vr_o','a');"
check "and the gate still fires" \
	"$([ "$S" = "$(storid vr_o)" ] && echo noop || echo rewrote)" "noop"

# ==================== inheritance and partitions =============================
# A column rename CASCADES to children, which are separate relations with their
# own storage and their own marks. PostgreSQL refuses
# "ALTER TABLE child RENAME COLUMN" with "cannot rename inherited column", so
# for a columnar partition the parent is the ONLY route: a hook that looked at
# the relation named in the statement would never fire for the child at all.
#
# This is the wrong-ANSWER half of #778, not the redundant-work half. The stale
# name still resolves, so #751's pathkey code reads the mark and claims an
# ordering that does not hold: ORDER BY plans no Sort and returns unordered rows.

# ---- declarative partition -------------------------------------------------
psql_run "CREATE TABLE prt (k int, j int) PARTITION BY RANGE (k);"
psql_run "CREATE TABLE prt1 PARTITION OF prt FOR VALUES FROM (0) TO (100000) USING pgcolumnar;"
psql_run "INSERT INTO prt SELECT (g*7919::bigint)%2000, (g*104729::bigint)%2000
          FROM generate_series(1,20000) g;"
check_num "premise: the partition holds every row" "$(q "SELECT count(*) FROM prt1;")" "20000"
psql_run "SELECT pgcolumnar.vacuum_sorted('prt1','k');"
check "premise: the partition is ordered by k and its mark says so" \
	"$([ "$(descents prt1 k)" -eq 0 ] && echo ordered || echo unordered)/$(markof prt1)" \
	"ordered/{k}/lexicographic"
check "premise: the parent is NOT itself columnar, so gating on it would skip the child" \
	"$(q "SELECT COALESCE((SELECT am.amname FROM pg_class c JOIN pg_am am ON am.oid=c.relam WHERE c.relname='prt'),'none');")" \
	"none"
# the rename can only be issued on the parent
psql_run "ALTER TABLE prt RENAME COLUMN k TO tmp_swap;"
psql_run "ALTER TABLE prt RENAME COLUMN j TO k;"
psql_run "ALTER TABLE prt RENAME COLUMN tmp_swap TO j;"
check "premise: after the swap the partition's ordered column is named j" \
	"$([ "$(descents prt1 j)" -eq 0 ] && echo ordered || echo unordered)" "ordered"
check "premise: and the column now named k is NOT ordered" \
	"$([ "$(descents prt1 k)" -gt 0 ] && echo unordered || echo ordered)" "unordered"
check "the PARTITION's mark follows a rename issued on the parent" "$(markof prt1)" "{j}/lexicographic"
S="$(storid prt1)"
psql_run "SELECT pgcolumnar.vacuum_sorted('prt1','k');"
check "so vacuum_sorted on the partition does the work" \
	"$([ "$S" = "$(storid prt1)" ] && echo "SKIPPED (gate fired wrongly)" || echo rewrote)" "rewrote"
check_num "and the partition really is ordered by k afterwards" "$(descents prt1 k)" "0"

# ---- INHERITS child --------------------------------------------------------
psql_run "CREATE TABLE inp (k int, j int);"
psql_run "CREATE TABLE inc (LIKE inp) INHERITS (inp) USING pgcolumnar;"
psql_run "INSERT INTO inc SELECT (g*7919::bigint)%2000, (g*104729::bigint)%2000
          FROM generate_series(1,20000) g;"
psql_run "SELECT pgcolumnar.vacuum_sorted('inc','k');"
check "premise: the inheritance child is ordered by k" \
	"$([ "$(descents inc k)" -eq 0 ] && echo ordered || echo unordered)" "ordered"
psql_run "ALTER TABLE inp RENAME COLUMN k TO tmp_swap;"
psql_run "ALTER TABLE inp RENAME COLUMN j TO k;"
psql_run "ALTER TABLE inp RENAME COLUMN tmp_swap TO j;"
check "the CHILD's mark follows a rename issued on the parent" "$(markof inc)" "{j}/lexicographic"
S="$(storid inc)"
psql_run "SELECT pgcolumnar.vacuum_sorted('inc','k');"
check "so vacuum_sorted on the child does the work" \
	"$([ "$S" = "$(storid inc)" ] && echo "SKIPPED (gate fired wrongly)" || echo rewrote)" "rewrote"

# ---- the WRONG-ANSWER shape: ORDER BY with no Sort over unordered rows ------
# This is why the cascade is not a cosmetic gap. #751 reads the same mark to
# claim a pathkey, so a stale mark makes the planner drop the Sort.
sorts() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -At \
		-c "EXPLAIN (COSTS OFF) $1" 2>/dev/null \
		| grep -qE '^ *(->)? *(Incremental )?Sort' && echo yes || echo no
}
psql_run "CREATE TABLE wp (k int, j int) PARTITION BY RANGE (k);"
psql_run "CREATE TABLE wp1 PARTITION OF wp FOR VALUES FROM (0) TO (100000) USING pgcolumnar;"
psql_run "INSERT INTO wp SELECT (g*7919::bigint)%2000, (g*104729::bigint)%2000
          FROM generate_series(1,20000) g;"
psql_run "SELECT pgcolumnar.vacuum_sorted('wp1','k');"
check "premise: with the mark true, ORDER BY k needs no Sort" "$(sorts 'SELECT k FROM wp1 ORDER BY k')" "no"
psql_run "ALTER TABLE wp RENAME COLUMN k TO tmp_swap;"
psql_run "ALTER TABLE wp RENAME COLUMN j TO k;"
psql_run "ALTER TABLE wp RENAME COLUMN tmp_swap TO j;"
check "after the swap, ORDER BY on the now-unordered column plans a Sort" \
	"$(sorts 'SELECT k FROM wp1 ORDER BY k')" "yes"
check_num "THE WRONG-ANSWER ARM: and the rows really do come back ordered" \
	"$(q "SELECT count(*) FROM (SELECT k < lag(k) OVER () AS d FROM (SELECT k FROM wp1 ORDER BY k) x) z WHERE d;")" \
	"0"
check "and ORDER BY on the column that IS ordered still needs no Sort" \
	"$(sorts 'SELECT j FROM wp1 ORDER BY j')" "no"

# ==================== the DECLARED key (options.sort_by) =====================
# vacuum_sorted(t) with no columns resolves options.sort_by. Maintaining the
# mark WITHOUT maintaining this would make the two catalogs name different
# columns, so the same call with the same declared intent would silently rewrite
# on a different physical key than it did yesterday.
mk sb
psql_run "SELECT pgcolumnar.set_options('sb', sort_by => ARRAY['a']);"
psql_run "SELECT pgcolumnar.vacuum_sorted('sb');"
check "premise: a bare vacuum_sorted() used the declared key" \
	"$([ "$(descents sb a)" -eq 0 ] && echo ordered || echo unordered)" "ordered"
swap sb
check "the DECLARED key follows the rename too" \
	"$(q "SELECT sort_by::text FROM pgcolumnar.options WHERE regclass = 'sb'::regclass;")" "{b}"
check "so the two catalogs still agree after the rename" \
	"$([ "$(q "SELECT sort_by::text FROM pgcolumnar.options WHERE regclass='sb'::regclass;")" \
	    = "$(q "SELECT sorted_by::text FROM pgcolumnar.storage WHERE storage_id = pgcolumnar.get_storage_id('sb');")" ] \
	  && echo agree || echo DISAGREE)" "agree"
S="$(storid sb)"
psql_run "SELECT pgcolumnar.vacuum_sorted('sb');"
check "and a bare vacuum_sorted() is a no-op, not a rewrite on a different key" \
	"$([ "$S" = "$(storid sb)" ] && echo noop || echo rewrote)" "noop"

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
