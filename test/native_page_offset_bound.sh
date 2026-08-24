#!/usr/bin/env bash
#
# column_chunk.page_offset corruption on the whole-group (unprojected) read.
#
# corruption.sh corrupts page_LENGTH and proves it errors cleanly, but only via
# SELECT sum(r): a projection, which reaches pgcolumnar_native_read_projected,
# whose containment check (columnar_reader.c: "chunk ... lies outside row group")
# catches a bad offset while it computes the ranges to read. It never corrupts
# page_OFFSET and never exercises the whole-group read.
#
# The whole-group read (rs->allColumnsWanted -> PgColumnarReadLogicalData) reads
# the group as one span and reaches the shared decode loop, where
#     base = rs->nativeBuffer + (cc->pageOffset - rg->fileOffset)
# indexes into that span. Without a containment check on this path a corrupt
# page_offset (above the group, or below fileOffset so the subtraction wraps)
# points base outside the buffer and the decode reads out of bounds -- an assert
# build takes SIGSEGV. The whole-group path is reached whenever column projection
# is off (pgcolumnar.enable_column_projection = off, a USERSET GUC) or a query
# genuinely wants every column.
#
# This suite pins that path shut. The projected arm is the control (already
# guarded); the enable_column_projection=off arms are the ones that segfault an
# unfixed reader. A sound reader raises ERRCODE_DATA_CORRUPTED on all of them and
# the backend survives.
#
# Removal proof: revert the whole-group guard in columnar_reader.c and the
# "SELECT * (proj off)" arms go from a clean error + alive to a lost connection.
#
# Usage:  test/native_page_offset_bound.sh [PG_CONFIG]
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

alive()  { [ "$(q 'SELECT 1;')" = "1" ] && echo yes || echo no; }
errors() { if psql_run "$1" >/dev/null 2>&1; then echo no; else echo yes; fi; }
sid()    { q "SELECT pgcolumnar.get_storage_id('c');"; }

mkc() {
	psql_run "DROP TABLE IF EXISTS c;" >/dev/null 2>&1
	psql_run "CREATE TABLE c (id int, r bigint, t text) USING pgcolumnar;"
	psql_run "INSERT INTO c SELECT g, (random()*9e18)::bigint, 'v'||(g%5)
	          FROM generate_series(1,20000) g;"
}

# --- control: the projected read already refuses an out-of-group offset --------
echo "-- control: page_offset overrun on a PROJECTED scan (SELECT sum(r)) errors"
mkc
psql_run "UPDATE pgcolumnar.column_chunk SET page_offset = page_offset + 999999999
          WHERE storage_id = $(sid) AND column_index = 1;"
check "projected page_offset overrun errors" "$(errors 'SELECT sum(r) FROM c;')" "yes"
check "alive after projected overrun"        "$(alive)" "yes"

# --- the gap: whole-group read (projection off) with the offset above the group
echo "-- page_offset overrun on the WHOLE-GROUP read (projection off) must error, not crash"
mkc
psql_run "UPDATE pgcolumnar.column_chunk SET page_offset = page_offset + 999999999
          WHERE storage_id = $(sid) AND column_index = 1;"
check "whole-group page_offset overrun errors" \
	"$(errors 'SET pgcolumnar.enable_column_projection=off; SELECT * FROM c;')" "yes"
check "alive after whole-group overrun"        "$(alive)" "yes"

# --- the harsher case: offset below fileOffset -> uint64 wrap on the same path -
echo "-- page_offset driven below the group start (subtraction wraps), projection off"
mkc
psql_run "UPDATE pgcolumnar.column_chunk SET page_offset = 0
          WHERE storage_id = $(sid) AND column_index = 2;"
check "whole-group page_offset=0 errors" \
	"$(errors 'SET pgcolumnar.enable_column_projection=off; SELECT * FROM c;')" "yes"
check "alive after whole-group wrap"     "$(alive)" "yes"

# --- the overflow case: page_offset = -1 arrives as ~UINT64_MAX, so a naive
# --- `page_offset + page_length > group_end` test wraps and passes, letting base
# --- index far outside nativeBuffer. The guard must reject it (the containment
# --- test is written overflow-safe), and specifically the CONTAINMENT guard must
# --- fire -- not a downstream decode error that only incidentally catches the
# --- wrapped read. page_offset is a signed bigint column, so -1 is storable.
guard_fires() {  # guard_fires <sql> ; yes iff the containment guard raised
	# capture-then-grep: piping an erroring psql into grep under pipefail would
	# mask the match (see the pipefail-hides-grep lesson).
	local out
	out="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" \
		-U postgres -d "$PGC_DB" -c "$1" 2>&1)"
	case "$out" in
		*"lies outside row group"*) echo yes ;;
		*) echo no ;;
	esac
}
echo "-- page_offset = -1 (unsigned wrap) must be caught by the containment guard, both paths"
mkc
psql_run "UPDATE pgcolumnar.column_chunk SET page_offset = -1
          WHERE storage_id = $(sid) AND column_index = 1;"
check "whole-group page_offset=-1 hits the containment guard" \
	"$(guard_fires 'SET pgcolumnar.enable_column_projection=off; SELECT * FROM c;')" "yes"
check "alive after whole-group page_offset=-1" "$(alive)" "yes"
check "projected page_offset=-1 hits the containment guard" \
	"$(guard_fires 'SELECT sum(r) FROM c;')" "yes"
check "alive after projected page_offset=-1" "$(alive)" "yes"

pgc_summary
