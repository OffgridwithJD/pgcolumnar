#!/usr/bin/env bash
#
# A column's collation changed without a rewrite (#1327).
#
# ALTER COLUMN ... TYPE text COLLATE <other> keeps the relfilenode: the type is
# the same, so PostgreSQL rewrites nothing. The zone maps kept the min and max
# computed under the OLD collation, and the reader compared them under the new
# one, so chunk-group pruning and the min/max path skipped rows the new
# collation orders differently. Reported by @jdatcmd while reviewing #1325, on
# main at 036d452: min|max read B|m where heap read a|m, and WHERE s < 'B'
# returned nothing where heap returned a,b.
#
# THE ORACLE IS HEAP: the same rows, the same ALTER, the same queries.
#
# A collation that orders 'a' before 'B' is needed, which "C" does not. libc's
# en_US.utf8 is used. A server without one is an environment defect (pgc_skip
# fails it unless PGC_ALLOW_MISSING_EN_US_COLLATION waives it), never a pass on a
# collation that cannot show the bug.
#
# Usage:  test/collation_change.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null

COLL="$(q "SELECT collname FROM pg_collation WHERE collname IN ('en_US.utf8', 'en_US.UTF-8', 'en_US')
           AND collencoding IN (-1, pg_char_to_encoding(current_setting('server_encoding')))
           ORDER BY collname LIMIT 1;")"
[ -n "$COLL" ] || pgc_skip en_us_collation "the server has no en_US collation to change a C column to"
check "premise: the new collation orders 'a' before 'B', which C does not" \
	"$(q "SELECT ('a' < 'B' COLLATE \"$COLL\")::text || '|' || ('a' < 'B' COLLATE \"C\")::text;")" "true|false"

# Three row groups, each holding upper- and lower-case values, so a group's C
# minimum is an upper-case letter that the new collation sorts AFTER some of its
# lower-case values: under C every group's minimum is >= 'B', so a stale zone map
# prunes every group from WHERE s < 'B'.
for t in cc ch; do
	am="USING pgcolumnar"; [ "$t" = ch ] && am=""
	q "CREATE TABLE $t (k int, s text COLLATE \"C\") $am;" >/dev/null
done
q "SELECT pgcolumnar.set_options('cc', stripe_row_limit => 1000, chunk_group_row_limit => 1000);" >/dev/null
for t in cc ch; do
	q "INSERT INTO $t SELECT g, CASE g % 4 WHEN 0 THEN 'a' WHEN 1 THEN 'B' WHEN 2 THEN 'm' ELSE 'b' END || (g % 7)
	   FROM generate_series(1, 3000) g;" >/dev/null
done
check "premise: the columnar table has three row groups" \
	"$(q "SELECT count(*) FROM pgcolumnar.row_group WHERE storage_id = pgcolumnar.get_storage_id('cc');")" "3"
before="$(q "SELECT pg_relation_filenode('cc');")"
for t in cc ch; do
	q "ALTER TABLE $t ALTER COLUMN s TYPE text COLLATE \"$COLL\";" >/dev/null
done
check "premise: the collation change rewrote nothing" "$(q "SELECT pg_relation_filenode('cc');")" "$before"

same() {	# same SQL-with-%T -> "same", or both answers when they differ
	local c h
	c="$(q "${1//%T/cc}")"; h="$(q "${1//%T/ch}")"
	[ "$c" = "$h" ] && echo same || echo "columnar [$c] heap [$h]"
}
check "after the collation change min and max are heap's" "$(same "SELECT min(s) || '|' || max(s) FROM %T;")" "same"
check "and a range below 'B' returns heap's rows" \
	"$(same "SELECT count(*) || ':' || string_agg(DISTINCT s, ',' ORDER BY s) FROM %T WHERE s < 'B';")" "same"
check "and an equality on a value C sorts first returns heap's rows" \
	"$(same "SELECT count(*) FROM %T WHERE s = 'a0';")" "same"

# The extent (#1325) stores a min and max per column too; column_extent() prints
# what the planner would read, which must not be the old collation's.
check "the column's extent is not the old collation's bound" \
	"$(q "SELECT coalesce((SELECT minimum || '|' || maximum FROM pgcolumnar.column_extent('cc', 's')), 'none')
	         IN ('none', (SELECT min(s) || '|' || max(s) FROM ch))::text;")" "true"

# Rows written after the change are under the new collation; the answers stay heap's.
for t in cc ch; do
	q "INSERT INTO $t SELECT g, 'A' || (g % 5) FROM generate_series(3001, 4200) g;" >/dev/null
done
check "rows written after the change join heap's answer" \
	"$(same "SELECT count(*) || ':' || min(s) || '|' || max(s) FROM %T WHERE s < 'B';")" "same"

# A change rolled back leaves the old collation's zone maps, which are right for it.
q "CREATE TABLE rb (s text COLLATE \"C\") USING pgcolumnar;
   INSERT INTO rb VALUES ('a'), ('B'), ('m'), ('b');" >/dev/null
q "BEGIN; ALTER TABLE rb ALTER COLUMN s TYPE text COLLATE \"$COLL\"; ROLLBACK;" >/dev/null
check "a collation change rolled back leaves the C answer" \
	"$(q "SELECT min(s) || '|' || max(s) || '|' || count(*) FILTER (WHERE s < 'B') FROM rb;")" "B|m|0"

# Through a partitioned parent: the ALTER recurses to a columnar partition.
q "CREATE TABLE pp (k int, s text COLLATE \"C\") PARTITION BY RANGE (k);
   CREATE TABLE pp1 PARTITION OF pp FOR VALUES FROM (0) TO (100000) USING pgcolumnar;
   INSERT INTO pp SELECT k, s FROM ch WHERE k <= 3000;
   ALTER TABLE pp ALTER COLUMN s TYPE text COLLATE \"$COLL\";" >/dev/null
check "a collation change made through a partitioned parent reaches the columnar partition" \
	"$(q "SELECT (SELECT count(*) FROM pp1 WHERE s < 'B') = (SELECT count(*) FROM ch WHERE k <= 3000 AND s < 'B');")" "t"

pgc_summary
