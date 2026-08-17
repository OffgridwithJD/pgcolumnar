#!/usr/bin/env bash
#
# pgColumnar delete_vector reads use delete_vector_pkey, not a seq scan.
#
# The delete_vector catalog has a unique index on (storage_id, group_number), and
# the sibling metadata tables (row_group, zone_map, bloom, column_chunk) all pass
# their _pkey to systable_beginscan. delete_vector did not: PgColumnarReadDeleteVectorList,
# the reclaim deleted-count sum, and PgColumnarStorageHasDeleteVector each passed
# InvalidOid / indexOK=false, so every call sequentially scanned the whole
# delete_vector catalog filtered by scan key. ReadDeleteVectorList runs once per
# row group while a scan builds its liveness cache, so on a table with deletes the
# cost was O(groups * delete_vector_rows) -- an unused index turning a per-group
# index probe into a full catalog scan.
#
# This asserts the reads now take the index. The instrument is behavioural and
# size-independent: after a scan of a table with deletes across many groups,
# pg_stat_all_tables for pgcolumnar.delete_vector must show idx_scan > 0 and
# seq_scan = 0. On the pre-fix code every one of those reads was a seq scan
# (idx_scan = 0, seq_scan = groups), so the check flips red when the index is
# removed. pg_stat_force_next_flush makes the counters readable without racing the
# stats collector. A correctness arm pins the delete result so the index switch is
# proven not to change visibility.
#
# Usage:  test/native_delete_vector_index.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null

# One session, so stripe_row_limit applies to the INSERT: 40000 rows / 2000 = 20
# row groups. Delete id % 500 = 0 (80 rows) so every group gets a delete_vector row.
q "SET pgcolumnar.stripe_row_limit=2000;
   CREATE TABLE t (id int, v bigint) USING pgcolumnar;
   INSERT INTO t SELECT g, g FROM generate_series(1,40000) g;
   DELETE FROM t WHERE id % 500 = 0;" >/dev/null

check "the delete produced one delete_vector row per group" \
	"$(q "SELECT count(*) FROM pgcolumnar.delete_vector;")" "20"

# Reset, run a full scan that builds the liveness cache (reads delete_vector per
# group), then force the stats out and read them.
q "SELECT pg_stat_reset();" >/dev/null
q "SELECT sum(v) FROM t;" >/dev/null
q "SELECT pg_stat_force_next_flush();" >/dev/null

check "delete_vector reads used the index (idx_scan > 0)" \
	"$(q "SELECT idx_scan > 0 FROM pg_stat_all_tables WHERE relname='delete_vector' AND schemaname='pgcolumnar';")" \
	"t"
check "delete_vector reads did NOT sequentially scan the catalog (seq_scan = 0)" \
	"$(q "SELECT coalesce(seq_scan,0) FROM pg_stat_all_tables WHERE relname='delete_vector' AND schemaname='pgcolumnar';")" \
	"0"

# Correctness: the index switch must not change which rows are visible. Live sum =
# sum(1..40000) - sum(deleted) = 800020000 - 1620000.
check "the deletes are still applied (visibility unchanged by the index switch)" \
	"$(q "SELECT sum(v) FROM t;")" "798400000"

pgc_summary
