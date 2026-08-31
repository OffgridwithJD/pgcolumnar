#!/usr/bin/env bash
#
# pgColumnar #394 step 1: the export byte sink — every write checked, and
# nothing ever visible at the final name before the export commits.
#
# The two defects this pins (found mapping the write path, PR #604): all 17
# fwrite sites ignored their return values, so a disk-full mid-export was
# detected only if the final flush happened to fail; and serial exports wrote
# directly to the final path, leaving a partial file there on error.
#
# Arms:
#   census    zero fwrite calls remain in either export file. The 13-vs-17
#             lesson made a property of the tree, so the count can never be
#             hand-maintained (and never wrong) again. RED on the old shape.
#   round     exports still round-trip: parquet and arrow files import back
#             into tables that hash-match the source, and no *.tmp.* debris
#             remains after success.
#   inject    pgcolumnar.sink_fail_after drives the SAME error path a full
#             disk takes: the export errors SQLSTATE 53100, the FINAL path
#             does not exist, and no temp file remains. The arrow arm's
#             fail_after is derived from the measured full size so the
#             failure lands inside write_record_batch — the helper the
#             13-site census missed, which the design doc requires the proof
#             to reach.
#
# Usage:  test/export_sink.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

SRC="$(dirname "${BASH_SOURCE[0]}")/../src"

sqlstate_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
$1;
SQLEOF
}
no_debris() { find "$PGC_WORKDIR" -name '*.tmp.*' | wc -l | tr -d ' '; }

# ---- census -----------------------------------------------------------------
check_num "census: zero fwrite remain in columnar_parquet.c" \
	"$(grep -c 'fwrite(' "$SRC/columnar_parquet.c")" "0"
check_num "census: zero fwrite remain in columnar_arrow.c" \
	"$(grep -c 'fwrite(' "$SRC/columnar_arrow.c")" "0"

# ---- fixture ----------------------------------------------------------------
ROWS=40000
psql_run "CREATE TABLE es_src (id int, v int8, t text) USING pgcolumnar;"
psql_run "INSERT INTO es_src SELECT g, g*17, 'row-'||g FROM generate_series(1,$ROWS) g;"

# ---- round-trip and no-debris ----------------------------------------------
PQF="$PGC_WORKDIR/es.parquet"
ARF="$PGC_WORKDIR/es.arrow"
check_num "parquet export succeeds through the sink" \
	"$(q "SELECT pgcolumnar.export_parquet('es_src', '$PQF')")" "$ROWS"
check_num "arrow export succeeds through the sink" \
	"$(q "SELECT pgcolumnar.export_arrow('es_src', '$ARF')")" "$ROWS"
check_num "no temp debris after successful exports" "$(no_debris)" "0"

psql_run "CREATE TABLE es_back_pq (id int, v int8, t text) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.import_parquet('es_back_pq', '$PQF');"
check "parquet round-trip hash-matches the source" \
	"$(pgc_set_hash "SELECT * FROM es_back_pq")" "$(pgc_set_hash "SELECT * FROM es_src")"
psql_run "CREATE TABLE es_back_ar (id int, v int8, t text) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.import_arrow('es_back_ar', '$ARF');"
check "arrow round-trip hash-matches the source" \
	"$(pgc_set_hash "SELECT * FROM es_back_ar")" "$(pgc_set_hash "SELECT * FROM es_src")"

ARROW_SIZE="$(stat -c %s "$ARF" 2>/dev/null || echo 0)"
check "premise: measured arrow size supports a mid-batch injection point" \
	"$([ "${ARROW_SIZE:-0}" -gt 4200 ] 2>/dev/null && echo yes)" "yes"

# ---- injection: parquet, mid page body -------------------------------------
FAILP="$PGC_WORKDIR/es_fail.parquet"
check "inject: parquet export fails as disk-full (53100)" \
	"$(sqlstate_of "SET pgcolumnar.sink_fail_after = 8192; SELECT pgcolumnar.export_parquet('es_src', '$FAILP')")" "53100"
check "inject: nothing exists at the parquet FINAL path" \
	"$([ ! -e "$FAILP" ] && echo clean)" "clean"
check_num "inject: no parquet temp debris" "$(no_debris)" "0"

# ---- injection: arrow, inside write_record_batch ----------------------------
# fail_after = fullsize - 100: the last 100 bytes belong to the final record
# batch (only the 8-byte EOS marker follows it), so the failing write is
# inside the helper by arithmetic, not by luck. The schema message is bounded
# well under the premise-checked 4200.
FAILA="$PGC_WORKDIR/es_fail.arrow"
check "inject: arrow export fails inside write_record_batch (53100)" \
	"$(sqlstate_of "SET pgcolumnar.sink_fail_after = $((ARROW_SIZE - 100)); SELECT pgcolumnar.export_arrow('es_src', '$FAILA')")" "53100"
check "inject: nothing exists at the arrow FINAL path" \
	"$([ ! -e "$FAILA" ] && echo clean)" "clean"
check_num "inject: no arrow temp debris" "$(no_debris)" "0"

# ---- the injection is session state, not lingering damage -------------------
check_num "after RESET, exports work again" \
	"$(q "SELECT pgcolumnar.export_parquet('es_src', '$PGC_WORKDIR/es2.parquet')")" "$ROWS"

pgc_summary
