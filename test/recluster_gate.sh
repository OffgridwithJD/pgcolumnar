#!/usr/bin/env bash
#
# pgColumnar #415: recluster() self-gates -- it returns 0 without a full rewrite
# when the relation is already Z-order clustered by exactly the requested key
# with nothing appended since. Being unconditionally eager (a full rewrite on
# every call, even with zero decay) is a production hazard and blocks the
# maintenance daemon that would call it speculatively.
#
# The signal that would-have-caught this: recluster on an unchanged, already-
# clustered table must NOT churn the physical relation. We pin it on both the
# return value (0 = nothing reclustered) AND the relfilenode staying put.
#
# Usage:  test/recluster_gate.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

CG=1000

mk() {
	psql_run "CREATE TABLE $1 (a int, b int, pad text) USING pgcolumnar;"
	psql_run "SELECT pgcolumnar.set_options('$1', chunk_group_row_limit => $CG);"
	psql_run "INSERT INTO $1 SELECT (g*2654435761)::bigint % 1000, g, md5(g::text) FROM generate_series(1,20000) g;"
}
# A falsifiable PHYSICAL signal for "was this rewritten": the per-group
# (group_number, file_offset, rowcount) multiset from stats(). A rewrite retires
# groups and reallocates file offsets; a no-op leaves them byte-identical.
# relfilenode does NOT change on any recluster path -- pgcolumnar rewrites inside
# its own storage -- so it could never falsify a rewrite (jdatcmd, #614 review).
physlayout() { q "SELECT md5(string_agg(stripeid::text||':'||fileoffset::text||':'||rowcount::text, ',' ORDER BY stripeid)) FROM pgcolumnar.stats('$1');"; }

# ---- fixture: cluster once by (a) --------------------------------------------
mk rg_t
FIRST="$(q "SELECT pgcolumnar.recluster('rg_t','a');")"
check "premise: the first recluster does real work (>0 groups)" \
	"$([ "${FIRST:-0}" -gt 0 ] && echo yes || echo no)" "yes"
check "premise: sort_status now reports the clustering key (was NULL before #415)" \
	"$(q "SELECT sort_key::text FROM pgcolumnar.sort_status('rg_t');")" "{a}"
check "premise: the run covers the whole relation (0 appended groups)" \
	"$(q "SELECT appended_groups FROM pgcolumnar.sort_status('rg_t');")" "0"

# ---- the gate: a second recluster by the same key is a no-op -----------------
PHYS_BEFORE="$(physlayout rg_t)"
SECOND="$(q "SELECT pgcolumnar.recluster('rg_t','a');")"
PHYS_AFTER="$(physlayout rg_t)"
check_num "recluster by the same key on an unchanged table reclusters 0 groups" "$SECOND" "0"
check "and it leaves the physical layout byte-identical (group offsets unmoved)" \
	"$([ "$PHYS_BEFORE" = "$PHYS_AFTER" ] && echo same || echo rewritten)" "same"
THIRD="$(q "SELECT pgcolumnar.recluster('rg_t','a');")"
check_num "a third identical recluster is also a no-op" "$THIRD" "0"

# ---- appended data un-gates it ----------------------------------------------
psql_run "INSERT INTO rg_t SELECT (g*2654435761)::bigint % 1000, g, md5(g::text) FROM generate_series(1,5000) g;"
check "premise: the insert appended unsorted groups" \
	"$(q "SELECT appended_groups > 0 FROM pgcolumnar.sort_status('rg_t');")" "t"
AFTER_APPEND="$(q "SELECT pgcolumnar.recluster('rg_t','a');")"
check "recluster after appends does real work again (>0)" \
	"$([ "${AFTER_APPEND:-0}" -gt 0 ] && echo yes || echo no)" "yes"
check "and it folds the new data back into the run (0 appended after)" \
	"$(q "SELECT appended_groups FROM pgcolumnar.sort_status('rg_t');")" "0"

# ---- a DIFFERENT key still forces a full re-cluster (contract preserved) -----
DIFF="$(q "SELECT pgcolumnar.recluster('rg_t','b');")"
check "recluster by a NEW key is NOT a no-op -- it re-clusters (>0)" \
	"$([ "${DIFF:-0}" -gt 0 ] && echo yes || echo no)" "yes"
check "and sort_status now reports the new key" \
	"$(q "SELECT sort_key::text FROM pgcolumnar.sort_status('rg_t');")" "{b}"
# ...and now the no-op holds for the new key
check_num "a repeat recluster by the new key is a no-op" \
	"$(q "SELECT pgcolumnar.recluster('rg_t','b');")" "0"

# ---- correctness: the data is unchanged by the no-op (oracle vs heap) --------
psql_run "CREATE TABLE rg_h (a int, b int, pad text);"
psql_run "INSERT INTO rg_h SELECT a,b,pad FROM rg_t;"
check "no-op recluster preserved the exact row set (columnar == heap mirror)" \
	"$(q "SELECT count(*)||'/'||sum(a)||'/'||sum(b)||'/'||md5(string_agg(pad,',' ORDER BY b)) FROM rg_t;")" \
	"$(q "SELECT count(*)||'/'||sum(a)||'/'||sum(b)||'/'||md5(string_agg(pad,',' ORDER BY b)) FROM rg_h;")"

pgc_summary
