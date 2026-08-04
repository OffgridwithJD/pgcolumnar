#!/usr/bin/env bash
#
# Regression for #295: compaction must not drop rows committed by another
# transaction while it waited for (or before it took) its read snapshot.
# pgcolumnar_compact_relation used the caller's pre-lock statement snapshot, so a
# row group committed after that snapshot was invisible to the rewrite and was
# destroyed by the relfilenode swap. The fix takes a fresh snapshot after the
# lock. Here session B pins a REPEATABLE READ snapshot, session A commits 100
# rows, then B runs the maintenance op: all 150 rows must survive.
# Covers vacuum() and vacuum_sorted() (pgcolumnar_compact_relation) and cluster()
# (its Z-order twin). Written fresh for pgColumnar.
#
# Usage:  test/native_vacuum_race.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

raw() { env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -tAX "$@"; }

# Run the race for one maintenance call and echo the surviving row count.
race() {  # maintenance_call  table
	local call="$1" tbl="$2"
	psql_run "DROP TABLE IF EXISTS $tbl;" >/dev/null 2>&1
	psql_run "CREATE TABLE $tbl (id int) USING pgcolumnar;" >/dev/null
	psql_run "INSERT INTO $tbl SELECT g FROM generate_series(1,50) g;" >/dev/null
	# B: pin a REPEATABLE READ snapshot (sees 50), wait, then run maintenance
	# under it. All in one explicit transaction so the snapshot is held.
	raw -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM $tbl; SELECT pg_sleep(5); SELECT $call; COMMIT;" >/dev/null 2>&1 &
	local b=$!
	sleep 2   # B has taken its snapshot; commit A's rows during B's wait
	psql_run "INSERT INTO $tbl SELECT g FROM generate_series(51,150) g;" >/dev/null
	wait "$b"
	q "SELECT count(*) FROM $tbl"
}

check "vacuum() keeps rows committed during its snapshot window (#295)" \
	"$(race "pgcolumnar.vacuum('r_vac')" r_vac)" "150"
check "vacuum_sorted() keeps rows committed during its snapshot window (#295)" \
	"$(race "pgcolumnar.vacuum_sorted('r_vsort','id')" r_vsort)" "150"
check "cluster() keeps rows committed during its snapshot window (#295)" \
	"$(race "pgcolumnar.cluster('r_clu','id')" r_clu)" "150"

# And the data is actually correct, not just the count: exactly the 150 distinct
# ids 1..150 are present (no loss, no duplication).
check "vacuum() preserves the exact row set" \
	"$(q 'SELECT count(DISTINCT id) FROM r_vac WHERE id BETWEEN 1 AND 150')" "150"

pgc_summary
