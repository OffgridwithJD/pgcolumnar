#!/usr/bin/env bash
#
# The skip loop must resolve pgcolumnar.zone_map ONCE per scan, not once per
# chunk group per predicate column (#744).
#
# What it cost. pgcolumnar_native_group_can_match calls
# PgColumnarReadZoneMapForColumn for every group a predicate could exclude, and
# that call used to run open_columnar_table (pgcolumnar_schema_oid,
# get_relname_relid, table_open with a lock and a resource-owner remember) plus
# pgcolumnar_index_oid (a second get_relname_relid), then close again. The
# md_flush reuse cache could not help: it is gated on md_flush.active, which only
# columnar_write_state.c ever sets, so the read path never reached it.
#
# Measured at 160 chunk groups, one predicate column, the same binary with only
# the cache defeated, backend instructions with the process pinned to one PMU:
#
#     baseline  18,280,385 instructions per query
#     cached    14,013,418
#     saved     4,266,968  =  26,669 per chunk group,  1.304x
#
# That is 87% of the whole locate cost #744 priced at this size, so what remains
# is the systable index probe. Buffers did NOT move (186/314/567 at N=40/80/160
# on both arms): a catcache or relcache lookup reads no buffers once warm, so
# the buffer cost of a probe is the index scan alone and the CPU cost was mostly
# the open. The two instruments measure different halves and neither alone
# prices this.
#
# WHAT THIS SUITE ASSERTS is the work done, not the answer. A scan returns the
# same rows either way, so a correctness test cannot see this land or regress.
# The runner's DEBUG1 witness reports probes and real opens, and the pair is the
# assertion: probes scales with the group count, opens must stay at one.
#
# The lifetime arms are here because the first implementation of this was WRONG
# in a way no correctness test caught. It held the relation in a static shared
# across scans, and a scan that ereports never runs its end hook, so after a
# subtransaction rollback the next scan reused a Relation the subtransaction's
# resource owner had already released. Every functional check still passed: a
# released relcache entry is refcount-decremented rather than freed, so the
# stale pointer read correctly. It showed up only as a missing witness. The
# session now lives in the scan's own read state, so nothing crosses scans.
#
# Usage:  test/native_zonemap_session.sh [PG_CONFIG]
# Written fresh for pgColumnar.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

N=40
ROWS=$((N * 10000))
psql_run "DROP TABLE IF EXISTS zs;
	CREATE TABLE zs (k bigint, w bigint, v bigint) USING pgcolumnar;
	SELECT pgcolumnar.set_options('zs', stripe_row_limit => 10000);
	INSERT INTO zs SELECT g, g, g FROM generate_series(1, $ROWS) g;" >/dev/null 2>&1

# The group count comes FROM THE DATA, never from rows/stripe_row_limit.
groups=$(q "SELECT count(*) FROM pgcolumnar.row_group
            WHERE storage_id = pgcolumnar.get_storage_id('zs');")
check "premise: the fixture really has more than one chunk group" \
	"$([ "${groups:-0}" -gt 1 ] && echo yes || echo no)" "yes"

witness() {	# witness "<where clause>" -> "probes=N opens=M"
	psql_run "SET client_min_messages=debug1; SET max_parallel_workers_per_gather=0;
		SET enable_indexscan=off; SET enable_bitmapscan=off;
		SELECT count(*) FROM zs WHERE $1;" 2>&1 |
		grep -oE 'probes=[0-9]+ opens=[0-9]+' | tail -1
}
w="$(witness 'k <= 10000')"
probes="$(printf '%s' "$w" | grep -oE 'probes=[0-9]+' | grep -oE '[0-9]+')"
opens="$(printf '%s' "$w" | grep -oE 'opens=[0-9]+' | grep -oE '[0-9]+')"
echo "-- one predicate column over $groups groups: $w"

# The premise first: if the scan probed nothing, "opens=1" would be trivially
# satisfied by a scan that did no work at all, which is the shape that let
# zonemap_cost price pruning for a year while pruning zero groups.
check "premise: the scan really probed the zone maps, once per group" \
	"$probes" "$groups"
check "the scan resolves zone_map ONCE, not once per group (#744)" "$opens" "1"

# A second predicate column must not add a second open either. It adds only one
# probe here, not one per group: native_zone_excludes returns as soon as the
# first predicate rules a group out, so the second column is consulted only for
# the group that survives.
w2="$(witness 'k <= 10000 AND w <= 10000')"
echo "-- two predicate columns: $w2"
check "a second predicate column still resolves zone_map once" \
	"$(printf '%s' "$w2" | grep -oE 'opens=[0-9]+' | grep -oE '[0-9]+')" "1"
check "and the short circuit means it adds one probe, not one per group" \
	"$(printf '%s' "$w2" | grep -oE 'probes=[0-9]+' | grep -oE '[0-9]+')" "$((groups + 1))"

# ---- lifetime -------------------------------------------------------------
psql_run "DROP TABLE IF EXISTS zs2;
	CREATE TABLE zs2 (k bigint, v bigint) USING pgcolumnar;
	SELECT pgcolumnar.set_options('zs2', stripe_row_limit => 1000);
	INSERT INTO zs2 SELECT g, g FROM generate_series(1,20000) g;" >/dev/null 2>&1

nested=$(q "SET enable_indexscan=off; SET max_parallel_workers_per_gather=0;
	SELECT count(*) FROM zs2 a JOIN zs2 b ON a.k = b.k
	 WHERE a.k <= 1000 AND b.k <= 1000;" | tail -1)
check "nested columnar scans each hold their own handle" "$nested" "1000"

# An erroring scan never runs its end hook. What must be true afterwards is that
# the NEXT scan opens for itself rather than inheriting anything.
cat > "$PGC_WORKDIR/zsub.sql" <<'SQL'
SET client_min_messages=debug1;
SET enable_indexscan=off;
SELECT count(*) FROM zs2 WHERE k <= 1000;
BEGIN;
SAVEPOINT s1;
SELECT count(*) FROM zs2 WHERE k <= 5000 AND 1/(v-4000) > 0;
ROLLBACK TO s1;
SELECT count(*) FROM zs2 WHERE k <= 1000;
COMMIT;
SELECT count(*) FROM zs2 WHERE k <= 1000;
SQL
out="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
	-d "$PGC_DB" -At -v ON_ERROR_STOP=0 -f "$PGC_WORKDIR/zsub.sql" 2>&1)"
check "premise: the middle scan really did error inside the subtransaction" \
	"$(printf '%s' "$out" | grep -c 'division by zero')" "1"
# THREE scans complete: before, after ROLLBACK TO, after COMMIT. Each must
# report. Two would mean one of them ran on state left behind by the error,
# which is exactly the defect the first implementation had.
check "every scan around an aborted one reports its own session (#744)" \
	"$(printf '%s' "$out" | grep -c 'zone map read: probes=')" "3"
check "and each of them opened exactly once" \
	"$(printf '%s' "$out" | grep -c 'zone map read: probes=[0-9]* opens=1')" "3"
check "the scan after the subtransaction abort returns the right answer" \
	"$(printf '%s' "$out" | grep -cE '^1000$')" "3"

pgc_summary
