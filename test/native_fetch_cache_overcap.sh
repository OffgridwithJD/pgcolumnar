#!/usr/bin/env bash
#
# The fetch cache above its size cap (issue #433).
#
# columnar_reader.c:2583 resets the WHOLE cache entry at the end of every fetch
# when the row group's raw stored size exceeds COLUMNAR_FETCH_CACHE_MAX_BYTES
# (32 MB, columnar.h:192):
#
#     if (rg->byteLength > COLUMNAR_FETCH_CACHE_MAX_BYTES)
#         pgcolumnar_fetch_entry_reset(entry);
#
# So above the cap the hit rate is not low, it is ZERO BY CONSTRUCTION: every
# fetch populates the entry, uses it for one row, and discards it. Fetching N
# rows in key order from one group costs N full group reads.
#
# Nothing in the suite reaches that branch. test/native_fetch_cache.sh builds
# (id int, v int, t text) with repeat('a',150), which compresses far below the
# cap, so :2583 never executes anywhere. That is why the regime survived #143,
# #157 and #359.
#
# WHAT IS ASSERTED, and why it is buffers rather than milliseconds:
#
#  1. the premise, that the fixture's row group actually EXCEEDS the cap. Without
#     it every check below passes against the under-cap path and proves nothing.
#     This is the assertion with teeth and it is checked twice: on disk, and
#     against the compression the fixture must not have.
#  2. reuse BELOW the cap, which is the control. It passes today. Without it a
#     broken measurement looks identical to the bug.
#  3. reuse ABOVE the cap. This FAILS on main and is the property #433 is about.
#
# Buffers, not wall clock: exact, reproducible on a shared runner, and they show
# the mechanism directly. A timing check would pass on a fast box with a warm
# page cache while the group was still being re-read every row.
#
# Usage:  test/native_fetch_cache_overcap.sh [PG_CONFIG]
# Written fresh for pgColumnar.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

CAP_BYTES=33554432		# COLUMNAR_FETCH_CACHE_MAX_BYTES, columnar.h:192

# Buffers touched by one query, index path forced.
#
# pgcolumnar.enable_custom_scan=off is what actually leaves the index path
# available: enable_seqscan=off alone is not enough, because our custom scan is
# a third option the planner will take instead.
FORCE="SET pgcolumnar.enable_custom_scan=off; SET enable_seqscan=off; SET enable_bitmapscan=off;"
bufs() {  # bufs <sql> -> total shared buffers touched, or empty
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq -c "$FORCE" -c "EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) $1" 2>&1 |
		grep -m1 -oE 'Buffers: shared[^)]*' |
		grep -oE '(hit|read)=[0-9]+' | cut -d= -f2 |
		awk '{ n += $1 } END { print n + 0 }'
}
planof() {  # planof <sql> -> the scan node
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq -c "$FORCE" -c "EXPLAIN (COSTS OFF) $1" 2>&1 |
		grep -oE 'Index Scan|Seq Scan|Custom Scan \([A-Za-z]+\)' | head -1
}

# ---------------------------------------------------------------------------
# Fixture. The payload must be genuinely incompressible or the row group never
# reaches the cap and this whole file tests the under-cap path.
#
# Two ways to get that wrong, both of which produced a green run that measured
# nothing while this was being written:
#   repeat(md5(x), 64)                     one string repeated, compressed 17:1
#   (SELECT ... FROM generate_series(1,64)) uncorrelated, so PostgreSQL evaluates
#                                          it ONCE and every row is identical
# Correlating on both g and s is what makes every row and every block differ.
# ---------------------------------------------------------------------------
ROWS=${PGC_OVERCAP_ROWS:-60000}
psql_run "CREATE TABLE oc (k bigint, payload bytea) USING pgcolumnar;
          INSERT INTO oc
          SELECT g,
                 decode((SELECT string_agg(md5(g::text || s::text), '')
                           FROM generate_series(1,64) s), 'hex')
          FROM generate_series(1,$ROWS) g;
          CREATE INDEX oc_k ON oc (k);
          ANALYZE oc;" >/dev/null

# The control: same shape, small enough that its group stays under the cap.
psql_run "CREATE TABLE uc (k bigint, payload bytea) USING pgcolumnar;
          INSERT INTO uc
          SELECT g, decode(md5(g::text), 'hex')
          FROM generate_series(1,$ROWS) g;
          CREATE INDEX uc_k ON uc (k);
          ANALYZE uc;" >/dev/null

check "fixture rows" "$(q 'SELECT count(*) FROM oc')" "$ROWS"

OC_BYTES=$(q "SELECT pg_total_relation_size('oc')")
UC_BYTES=$(q "SELECT pg_total_relation_size('uc')")

# Premise 1, the one that makes everything else meaningful. The over-cap table's
# largest ROW GROUP must exceed the cap. Asserted from the catalog rather than
# from the relation size, because :2583 tests the group and not the table.
# byte_length is the exact field columnar_reader.c:2583 branches on, so this
# reads the quantity the code tests rather than a reconstruction of it.
GROUP_BYTES=$(q "SELECT coalesce(max(byte_length), 0) FROM pgcolumnar.row_group
                  WHERE storage_id = pgcolumnar.get_storage_id('oc')")
check "premise: the over-cap fixture has a row group above the ${CAP_BYTES}-byte cap" \
	"$([ "${GROUP_BYTES:-0}" -gt "$CAP_BYTES" ] && echo yes || echo "no (largest group ${GROUP_BYTES:-unknown})")" \
	"yes"
# And the control's must not be, or the two arms are the same test.
UC_GROUP=$(q "SELECT coalesce(max(byte_length), 0) FROM pgcolumnar.row_group
                WHERE storage_id = pgcolumnar.get_storage_id('uc')")
check "premise: the control fixture stays below the cap" \
	"$([ "${UC_GROUP:-0}" -lt "$CAP_BYTES" ] && echo yes || echo "no (largest group ${UC_GROUP:-unknown})")" \
	"yes"
echo "      over-cap group: ${GROUP_BYTES} bytes   control group: ${UC_GROUP} bytes"

# Premise 2: the payload really did not compress. A fixture that compressed
# would satisfy premise 1 only by being enormous, and would change what is
# measured.
check "premise: the over-cap payload is incompressible" \
	"$([ "$OC_BYTES" -gt $(( ROWS * 700 )) ] && echo yes || echo "no ($(( OC_BYTES / ROWS )) bytes per row)")" \
	"yes"

# Premise 3: both arms must actually use the index, or we are timing a scan.
check "premise: the over-cap arm plans an index scan" \
	"$(planof 'SELECT length(payload) FROM oc WHERE k = 1')" "Index Scan"
check "premise: the control arm plans an index scan" \
	"$(planof 'SELECT length(payload) FROM uc WHERE k = 1')" "Index Scan"

# ---------------------------------------------------------------------------
# The measurement. One row against sixteen CONSECUTIVE rows, in key order, from
# the same row group. Consecutive and in order is the friendliest possible
# access pattern: if there is any reuse at all, this is where it shows.
# ---------------------------------------------------------------------------
one_uc=$(bufs "SELECT length(payload) FROM uc WHERE k = 1")
many_uc=$(bufs "SELECT count(length(payload)) FROM uc WHERE k BETWEEN 1 AND 16")
one_oc=$(bufs "SELECT length(payload) FROM oc WHERE k = 1")
many_oc=$(bufs "SELECT count(length(payload)) FROM oc WHERE k BETWEEN 1 AND 16")
echo "      control  : 1 row = ${one_uc} buffers, 16 rows = ${many_uc}"
echo "      over-cap : 1 row = ${one_oc} buffers, 16 rows = ${many_oc}"

# The control passes today. It is here so that a broken measurement, which would
# fail both, is distinguishable from the bug, which fails only the second.
check_ratio "control: 16 consecutive fetches cost far less than 16 separate ones" \
	"$many_uc" "$one_uc" 8

# The property #433 is about. On main this FAILS: the whole group is re-read per
# row, so sixteen fetches cost about sixteen times one. Any fix that gives the
# over-cap path some reuse brings this under the bound.
check_ratio "over cap: 16 consecutive fetches cost far less than 16 separate ones" \
	"$many_oc" "$one_oc" 8

pgc_summary
