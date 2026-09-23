#!/usr/bin/env bash
#
# Retiring a row group must probe its five catalogs through their primary
# keys, and so must the two scans beside it on the compaction path.
#
# delete_group_rows() opens its catalog from a `const char *tableName`
# PARAMETER and PgColumnarDeleteGroupMetadata calls it five times, for
# delete_vector, column_chunk, zone_map, bloom and row_group. One
# systable_beginscan in the source is therefore FIVE sequential scans per
# retired group at run time, and a static enumeration by relation handle
# cannot see any of them: at the call site the relation has no name.
#
# It was found by reconciliation rather than by reading. Probing all 44
# systable_beginscan sites in columnar_metadata.c and requiring
#
#     sum(probes that ran with InvalidOid) == sum(seq_scan over pgcolumnar)
#
# failed at 41 counted against 22 probed. Before the fix the compaction path
# cost 7 x (retired groups) + 3 sequential scans, of which delete_group_rows
# was five sevenths.
#
# Every one of the seven keys is a prefix of an index that already exists, so
# nothing here needs a catalog migration:
#
#     delete_vector_pkey  (storage_id, group_number)              exact
#     row_group_pkey      (storage_id, group_number)              exact
#     column_chunk_pkey   (storage_id, group_number, column_index)
#     bloom_pkey          (storage_id, group_number, column_index)
#     zone_map_pkey       (storage_id, group_number, column_index, vector_index)
#     free_space_pkey     (storage_id, file_offset)
#
# WHY THE PREMISES ARE NOT DECORATION. Every arm below expects seq_scan = 0,
# and a compaction that retired nothing reports 0 just as loudly as one that
# retired forty groups through an index. The premises establish that the
# instrument measured something: the table holds its rows, the delete removed
# half of them, and the compaction actually moved the file.
#
# Usage:  test/catalog_delete_index.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null

# WHICH BUILD KIND THIS RUN MEASURED, printed rather than asserted.
#
# Two of the nine converted scan sites are in PgColumnarCheckFreeSpaceNoOverlap,
# which is assert-only. On a release build they do not execute, so every arm
# below is a WEAKER claim there: it says nothing about those two sites rather
# than clearing them. A green on `debug_assertions = off` is not the same
# statement as a green on `on`.
#
# That distinction cost real time. The probe run that closed the account for
# #1207 was on a release build and reported the compaction path FULLY CLEAN,
# while the assert-enabled suite still showed one sequential scan on each of two
# catalogs. Nothing in the measurement said which build it was, so the zero read
# as an answer rather than as a partial one. Suggested by @OffgridwithJD.
#
# Printed and NOT made an arm on purpose: it records the condition the run
# happened in, and a removal proof cannot reach a value like that -- breaking
# the code under test cannot change it. An arm here could not fail for any
# reason this suite is about.
echo "-- debug_assertions=$(q "SHOW debug_assertions;")  (off = the two assert-only sites did not run)"

# A second columnar table in the same catalogs. A sequential scan walks its
# rows too; an index probe does not. Without it every arm below could pass on
# a catalog that happens to hold one storage's rows.
q "CREATE TABLE del_noise (id int) USING pgcolumnar;
   SELECT pgcolumnar.set_options('del_noise', stripe_row_limit => 1000);
   INSERT INTO del_noise SELECT g FROM generate_series(1,20000) g;
   CREATE TABLE del_cat (id int, v int) USING pgcolumnar;
   SELECT pgcolumnar.set_options('del_cat', stripe_row_limit => 1000);
   INSERT INTO del_cat SELECT g, g % 100 FROM generate_series(1,40000) g;" >/dev/null

check_num "premise: the measured table holds its rows" \
	"$(q "SELECT count(*) FROM del_cat;")" "40000"

# Retire every other 1000-row group, so half the groups go and half stay.
q "DELETE FROM del_cat WHERE ((id - 1) / 1000) % 2 = 0;" >/dev/null

check_num "premise: the delete removed the groups it was aimed at" \
	"$(q "SELECT count(*) FROM del_cat;")" "20000"

# HOW MANY GROUPS EXIST BEFORE THE COMPACTION. The arms below all expect
# seq_scan = 0, and a compaction that retired nothing reports 0 just as
# loudly as one that retired twenty groups through an index. This is the
# quantity that says the instrument measured something.
groups_before="$(q "SELECT count(*) FROM pgcolumnar.row_group r
	JOIN pgcolumnar.storage s USING (storage_id)
	WHERE s.relation_oid = 'del_cat'::regclass::oid;")"

# READ THE COUNTERS BEFORE ANY OTHER QUERY. pg_stat_all_tables accumulates,
# and the premises below are themselves planned queries over a columnar
# table, which read these same catalogs. An earlier draft read the counters
# last and saw row_group 42 and free_space 22 where the compaction accounts
# for 41 and 21: the difference was the premise's own SELECT. One query, six
# rows, so no arm can describe a different reading from its sibling.
q "SELECT pg_stat_reset();" >/dev/null
q "SELECT pgcolumnar.compact('del_cat');" >/dev/null
q "SELECT pg_stat_force_next_flush();" >/dev/null

counters="$(q "SELECT relname || ' ' || coalesce(idx_scan,0)::text || ' ' ||
		coalesce(seq_scan,0)::text
	FROM pg_stat_all_tables
	WHERE schemaname = 'pgcolumnar'
	  AND relname IN ('delete_vector','column_chunk','zone_map','bloom',
			  'row_group','free_space')
	ORDER BY relname;")"

groups_after="$(q "SELECT count(*) FROM pgcolumnar.row_group r
	JOIN pgcolumnar.storage s USING (storage_id)
	WHERE s.relation_oid = 'del_cat'::regclass::oid;")"
echo "-- row groups ${groups_before} -> ${groups_after}"

check_num "premise: the table had every group to retire from" \
	"$groups_before" "40"
check_num "premise: the compaction retired the emptied groups" \
	"$((groups_before - groups_after))" "20"

check_num "premise: the compaction kept every surviving row" \
	"$(q "SELECT count(*) FROM del_cat;")" "20000"

# The reading must cover every catalog asked about. A missing row would
# otherwise read as a catalog that was never touched, which is the answer
# these arms are looking for.
check_num "premise: the reading covers every catalog the arms name" \
	"$(printf '%s\n' "$counters" | grep -c .)" "6"

while read -r cat idx seq; do
	[ -n "$cat" ] || continue
	echo "-- $cat idx_scan=$idx seq_scan=$seq"
	if [ "$idx" -ge 1 ]; then
		idx_ok=1
	else
		idx_ok=$idx
	fi
	check_num "retiring a group probed pgcolumnar.$cat by index" "$idx_ok" "1"
	check_num "retiring a group did not sequentially scan pgcolumnar.$cat" \
		"$seq" "0"
done <<<"$counters"

# ---------------------------------------------------------------------------
# The VACUUM path, which reaches a different row_group scan.
#
# PgColumnarVMSetVisibleForRelation calls PgColumnarComputeAllVisibleGroups,
# and NOTHING ABOVE REACHES IT. An earlier draft of this suite converted that
# scan and proved nothing about it: probing every site during a run of the
# section above showed PgColumnarComputeAllVisibleGroups never fired, so the
# change to it rode along on arms that could not fail if it were reverted.
# ---------------------------------------------------------------------------

q "SELECT pg_stat_reset();" >/dev/null
q "VACUUM del_cat;" >/dev/null
q "SELECT pg_stat_force_next_flush();" >/dev/null

vac="$(q "SELECT coalesce(idx_scan,0)::text || ' ' || coalesce(seq_scan,0)::text
	FROM pg_stat_all_tables
	WHERE schemaname = 'pgcolumnar' AND relname = 'row_group';")"
vac_idx="${vac%% *}"
vac_seq="${vac##* }"
echo "-- VACUUM: row_group idx_scan=$vac_idx seq_scan=$vac_seq"

# THE PREMISE IS NOT THE CLAIM. It reads delete_vector -- a DIFFERENT catalog
# from the one the arms below are about -- so it cannot be satisfied by
# whatever makes those arms pass.
#
# TWO MORE OBVIOUS PREMISES WERE MEASURED AND ARE BOTH THE WRONG QUANTITY:
#
#   relallvisible stays 0 on this fixture however many times the table is
#   vacuumed (measured at six consecutive vacuums), and 0 again on a table with
#   no deletes at all. An arm resting on it would have refused a vacuum that
#   HAD reached the visibility-map path -- PgColumnarComputeAllVisibleGroups
#   fires once per vacuum here, confirmed by probe.
#
#   vacuum_count and last_vacuum in pg_stat_all_tables stay 0 and NULL for a
#   columnar table, because this table access method's vacuum does not report
#   through them. "The vacuum did not run" and "the counter cannot see this
#   vacuum" are the same reading.
check_num "premise: the vacuum walked this table's groups" \
	"$(q "SELECT CASE WHEN coalesce(idx_scan,0) >= 1 THEN 1 ELSE 0 END
		FROM pg_stat_all_tables
		WHERE schemaname = 'pgcolumnar' AND relname = 'delete_vector';")" "1"

if [ "$vac_idx" -ge 1 ]; then
	vac_idx_ok=1
else
	vac_idx_ok=$vac_idx
fi
check_num "the vacuum probed pgcolumnar.row_group by index" "$vac_idx_ok" "1"
check_num "the vacuum did not sequentially scan pgcolumnar.row_group" \
	"$vac_seq" "0"

pgc_summary
