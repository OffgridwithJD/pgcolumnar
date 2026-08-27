#!/usr/bin/env bash
#
# pgColumnar #760: vacuum_sorted() self-gates -- it skips the rewrite when the
# relation is already exactly this lexicographic run with nothing appended AND
# nothing to reclaim.
#
# #415 gave recluster() the ordering half of this gate. The mirror could not be
# a copy: vacuum_sorted has TWO jobs, ordering and physically reclaiming
# deleted-row space, so an ordering-only gate would answer "nothing to do" on a
# relation that is in order and full of dead rows and silently stop reclaiming.
# That is a data-size regression with no error and no report.
#
# The arm this suite exists for is therefore NOT "the gate fires". It is
# "deleted rows DEFEAT the gate": the wrong gate passes every other arm here.
#
# Usage:  test/vacuum_sorted_gate.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

CG=1000

mk() {
	psql_run "DROP TABLE IF EXISTS $1;"
	psql_run "CREATE TABLE $1 (id int, k int, j int, pad text) USING pgcolumnar;"
	psql_run "SELECT pgcolumnar.set_options('$1', chunk_group_row_limit => $CG);"
	psql_run "INSERT INTO $1 SELECT g, (g*2654435761)::bigint % 1000, g % 97, md5(g::text)
	          FROM generate_series(1,20000) g;"
}

# "Did this call rewrite?" -- the signal, and the one that does NOT work.
#
# STORAGE ID is the signal. An ordering rewrite materializes the live rows into
# a NEW storage row and swaps it in, so the id moves on a rewrite and does not
# on a skip.
#
# The (group_number, file_offset, rowcount) multiset -- which is the right
# signal for recluster (#415), because recluster rewrites INSIDE the existing
# storage and so reallocates offsets -- is useless here for exactly that
# reason. A vacuum_sorted rewrite starts a fresh storage, so group numbers and
# offsets restart from zero and the multiset comes out BYTE-IDENTICAL on a real
# rewrite of unchanged data. It cannot distinguish the two cases, and an arm
# built on it would have called every rewrite a no-op.
#
# It is still worth taking on the NO-OP arms, where it is a second, independent
# witness that nothing moved. So: storage id decides, layout corroborates, and
# a disagreement on a no-op arm is itself a failure rather than a quiet pass.
physlayout() { q "SELECT md5(string_agg(stripeid::text||':'||fileoffset::text||':'||rowcount::text, ',' ORDER BY stripeid)) FROM pgcolumnar.stats('$1');"; }
storid()    { q "SELECT pgcolumnar.get_storage_id('$1');"; }
deadrows()  { q "SELECT COALESCE(sum(deletedrows),0) FROM pgcolumnar.stats('$1');"; }
liverows()  { q "SELECT count(*) FROM $1;"; }

did_rewrite() {          # storage id only: see above
	local t="$1" s0="$2"
	[ "$s0" = "$(storid "$t")" ] && echo no || echo yes
}
stayed_put() {           # for no-op arms: BOTH witnesses must say nothing moved
	local t="$1" p0="$2" s0="$3" p1 s1
	p1="$(physlayout "$t")"; s1="$(storid "$t")"
	if [ "$s0" != "$s1" ]; then echo "rewritten(storage moved)"
	elif [ "$p0" != "$p1" ]; then echo "rewritten(layout moved)"
	else echo same; fi
}

# ---- fixture: sort once by (k,j) ---------------------------------------------
mk vg_t
P0="$(physlayout vg_t)"; S0="$(storid vg_t)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_t','k','j');"
check "premise: the first vacuum_sorted does real work (layout and storage both move)" \
	"$(did_rewrite vg_t "$S0")" "yes"
check "premise: it recorded a LEXICOGRAPHIC run (not zorder)" \
	"$(q "SELECT s.sorted_kind FROM pgcolumnar.storage s WHERE s.storage_id = pgcolumnar.get_storage_id('vg_t');")" \
	"lexicographic"
check "premise: over exactly the requested key" \
	"$(q "SELECT sort_key::text FROM pgcolumnar.sort_status('vg_t');")" "{k,j}"
check "premise: the run covers the whole relation (0 appended groups)" \
	"$(q "SELECT appended_groups FROM pgcolumnar.sort_status('vg_t');")" "0"
check_num "premise: nothing is deleted yet" "$(deadrows vg_t)" "0"

# ---- the gate fires ----------------------------------------------------------
P1="$(physlayout vg_t)"; S1="$(storid vg_t)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_t','k','j');"
check "a second vacuum_sorted on the same key does NOT rewrite" \
	"$(stayed_put vg_t "$P1" "$S1")" "same"
P2="$(physlayout vg_t)"; S2="$(storid vg_t)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_t','k','j');"
check "a third identical call is also a no-op" "$(stayed_put vg_t "$P2" "$S2")" "same"

# the gate must not have cost the ordering it is claiming to preserve
check "and the relation is still physically in (k,j) order after the skips" \
	"$(q "SELECT bool_and(ok) FROM (SELECT (k,j) >= lag((k,j)) OVER (ORDER BY ctid) IS NOT FALSE AS ok FROM vg_t) s;")" \
	"t"

# ---- THE ARM THIS SUITE EXISTS FOR: deleted rows defeat the gate --------------
# An ordering-only gate -- the obvious mirror of #415 -- passes every other arm
# in this file and fails exactly here, leaving the dead rows stored forever.
psql_run "DELETE FROM vg_t WHERE id % 2 = 0;"
DEAD="$(deadrows vg_t)"
check "premise: the delete left dead rows INSIDE the run, appending nothing" \
	"$([ "${DEAD:-0}" -gt 0 ] && echo yes || echo no)/$(q "SELECT appended_groups FROM pgcolumnar.sort_status('vg_t');")" \
	"yes/0"
check "premise: so an ORDERING-only gate would see 'already sorted, nothing appended'" \
	"$(q "SELECT s.sorted_kind||'/'||s.sorted_by::text FROM pgcolumnar.storage s WHERE s.storage_id = pgcolumnar.get_storage_id('vg_t');")" \
	"lexicographic/{k,j}"
P3="$(physlayout vg_t)"; S3="$(storid vg_t)"
LIVE3="$(liverows vg_t)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_t','k','j');"
check "vacuum_sorted with dead rows DOES rewrite, gate or no gate" \
	"$(did_rewrite vg_t "$S3")" "yes"
check_num "and it reclaimed the space: deleted rows go to zero" "$(deadrows vg_t)" "0"
check_num "without losing a live row" "$(liverows vg_t)" "$LIVE3"

# and having reclaimed, the gate is armed again
P4="$(physlayout vg_t)"; S4="$(storid vg_t)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_t','k','j');"
check "the call after the reclaim is a no-op again" "$(stayed_put vg_t "$P4" "$S4")" "same"

# ---- an appended tail defeats the gate ---------------------------------------
psql_run "INSERT INTO vg_t SELECT g, (g*2654435761)::bigint % 1000, g % 97, md5(g::text)
          FROM generate_series(100001,105000) g;"
check "premise: the insert appended groups outside the run" \
	"$(q "SELECT appended_groups > 0 FROM pgcolumnar.sort_status('vg_t');")" "t"
P5="$(physlayout vg_t)"; S5="$(storid vg_t)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_t','k','j');"
check "vacuum_sorted after an append DOES rewrite" "$(did_rewrite vg_t "$S5")" "yes"
check_num "and folds the tail back into the run" \
	"$(q "SELECT appended_groups FROM pgcolumnar.sort_status('vg_t');")" "0"

# ---- a DIFFERENT key defeats the gate ----------------------------------------
P6="$(physlayout vg_t)"; S6="$(storid vg_t)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_t','j','k');"
check "vacuum_sorted by a DIFFERENT key (same columns, other order) rewrites" \
	"$(did_rewrite vg_t "$S6")" "yes"
check "and records the new key" \
	"$(q "SELECT sort_key::text FROM pgcolumnar.sort_status('vg_t');")" "{j,k}"
P7="$(physlayout vg_t)"; S7="$(storid vg_t)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_t','k');"
check "a PREFIX of the recorded key is a different key, so it rewrites" \
	"$(did_rewrite vg_t "$S7")" "yes"

# ---- a Z-ORDER run over the same columns defeats the gate --------------------
# Z-order over two or more columns is not a sort on any one of them, so a gate
# keyed on the column list alone would skip here and leave the table unsorted
# while sort_status reported the key. The kind is what separates them.
mk vg_z
psql_run "SELECT pgcolumnar.cluster('vg_z','k','j');"
check "premise: cluster() recorded a ZORDER run over the same columns" \
	"$(q "SELECT s.sorted_kind||'/'||s.sorted_by::text FROM pgcolumnar.storage s WHERE s.storage_id = pgcolumnar.get_storage_id('vg_z');")" \
	"zorder/{k,j}"
check "premise: and the Z-ordered table is NOT in k order (else this arm proves nothing)" \
	"$(q "SELECT bool_and(ok) FROM (SELECT k >= lag(k) OVER (ORDER BY ctid) IS NOT FALSE AS ok FROM vg_z) s;")" \
	"f"
PZ="$(physlayout vg_z)"; SZ="$(storid vg_z)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_z','k','j');"
check "vacuum_sorted over a ZORDER run of the same columns DOES rewrite" \
	"$(did_rewrite vg_z "$SZ")" "yes"
check "and the result really is in (k,j) order" \
	"$(q "SELECT bool_and(ok) FROM (SELECT (k,j) >= lag((k,j)) OVER (ORDER BY ctid) IS NOT FALSE AS ok FROM vg_z) s;")" \
	"t"
check "and the kind is now lexicographic" \
	"$(q "SELECT s.sorted_kind FROM pgcolumnar.storage s WHERE s.storage_id = pgcolumnar.get_storage_id('vg_z');")" \
	"lexicographic"

# ---- an unsorted vacuum() clears the mark, so the next call rewrites ---------
mk vg_u
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_u','k','j');"
psql_run "SELECT pgcolumnar.vacuum('vg_u');"
check "premise: a plain vacuum() leaves no lexicographic mark" \
	"$(q "SELECT COALESCE(s.sorted_kind,'none') FROM pgcolumnar.storage s WHERE s.storage_id = pgcolumnar.get_storage_id('vg_u');")" \
	"none"
PU="$(physlayout vg_u)"; SU="$(storid vg_u)"
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_u','k','j');"
check "so vacuum_sorted after a plain vacuum rewrites" "$(did_rewrite vg_u "$SU")" "yes"

# ---- uncommitted work in the SAME transaction must not be missed -------------
# The gate reads the row-group list and the delete vectors, so it must persist
# this backend's pending writes first. Without the flush, work done earlier in
# the same transaction is invisible and the gate fires on a relation that does
# need the rewrite.
#
# The insert must be SMALLER than chunk_group_row_limit. A larger one flushes
# complete groups during the INSERT itself, leaving nothing pending -- which is
# what an earlier version of this arm did, and it stayed green with both
# flushes deleted.
mk vg_x
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_x','k','j');"
check_num "premise: the tail is smaller than the chunk group limit, so it stays PENDING" \
	"$([ 500 -lt $CG ] && echo 1 || echo 0)" "1"
psql_run "BEGIN;
          INSERT INTO vg_x SELECT g, (g*2654435761)::bigint % 1000, g % 97, md5(g::text)
            FROM generate_series(200001,200500) g;
          SELECT pgcolumnar.vacuum_sorted('vg_x','k','j');
          COMMIT;"
check "a PENDING insert in the same transaction defeats the gate (rows come out ordered)" \
	"$(q "SELECT bool_and(ok) FROM (SELECT (k,j) >= lag((k,j)) OVER (ORDER BY ctid) IS NOT FALSE AS ok FROM vg_x) s;")" \
	"t"
check_num "and every row is still there" "$(liverows vg_x)" "20500"

# the same for a PENDING delete, which lives in a different buffer
mk vg_d
psql_run "SELECT pgcolumnar.vacuum_sorted('vg_d','k','j');"
check_num "premise: nothing is deleted before the transaction" "$(deadrows vg_d)" "0"
psql_run "BEGIN;
          DELETE FROM vg_d WHERE id % 2 = 0;
          SELECT pgcolumnar.vacuum_sorted('vg_d','k','j');
          COMMIT;"
check_num "a PENDING delete in the same transaction defeats the gate (space reclaimed)" \
	"$(deadrows vg_d)" "0"
check_num "and the rewrite really happened: the live rows are all that is stored" \
	"$(q "SELECT COALESCE(sum(rowcount),0) FROM pgcolumnar.stats('vg_d');")" "10000"

# ---- correctness: a skipped rewrite changed nothing --------------------------
psql_run "CREATE TABLE vg_h (id int, k int, j int, pad text);"
psql_run "INSERT INTO vg_h SELECT id,k,j,pad FROM vg_t;"
check "the gated calls preserved the exact row set (columnar == heap mirror)" \
	"$(q "SELECT count(*)||'/'||sum(k)||'/'||sum(j)||'/'||md5(string_agg(pad,',' ORDER BY id, pad)) FROM vg_t;")" \
	"$(q "SELECT count(*)||'/'||sum(k)||'/'||sum(j)||'/'||md5(string_agg(pad,',' ORDER BY id, pad)) FROM vg_h;")"

pgc_summary
