#!/usr/bin/env bash
#
# pgColumnar #393 M1: the HTTP ranged byte source, with the request count
# ASSERTED rather than reported (the M1 test spec agreed on the issue).
#
# Four arms, per design/ISSUE_393_M1_HTTP_SOURCE.md:
#   A  differential oracle: a foreign table over http://127.0.0.1 returns the
#      same rows as the byte-identical local file. Premise for everything else.
#   B  request count, both arms in one run: buffered requests == K where K is
#      arithmetic from the fixture's structure (open = 1 HEAD + 3 ranged GETs,
#      data = one GET per needed chunk); unbuffered (dev GUC off) >= 10*K.
#      Removal proof: force the GUC off and the buffered check must go red.
#   C  failure taxonomy on SQLSTATE: unreachable port and 404 name the URL and
#      produce no rows; a Range-ignoring server is an error, never a silent
#      whole-object read.
#   D  cancel: statement_timeout fires within bound while the server stalls
#      mid-body. Removal proof: with the module's WaitLatchOrSocket wait arm
#      deleted, this check hangs or reds.
#
# The fixture server (test/objstore_http_server.py) logs one line per request;
# that log is seam B. The suite tears the server down through a chained trap
# (the bare-trap EXIT gotcha is pinned by harness_selftest).
#
# Usage:  test/objstore_http_read.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

python3 -c 'import pyarrow' 2>/dev/null || pgc_skip pyarrow "pyarrow is required to write the fixture"

HTTP_PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
HTTP_LOG="$PGC_WORKDIR/http.log"
SRV_PID=""

objstore_http_teardown() {
	[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
	pgc_teardown
}
trap objstore_http_teardown EXIT INT TERM

# ---- fixture ---------------------------------------------------------------
# G row groups x NCOLS int64 columns, tiny data pages so the unbuffered arm's
# per-page request count dwarfs the buffered per-chunk count. The arithmetic
# below depends only on G and the projection width, never on the page count.
G=3
NCOLS=8
ROWS_PER_GROUP=8000

python3 - "$PGC_WORKDIR/fixture.parquet" <<PYEOF
import sys
import pyarrow as pa, pyarrow.parquet as pq
G, NCOLS, RPG = $G, $NCOLS, $ROWS_PER_GROUP
n = G * RPG
cols = {("c%d" % i): pa.array([(i + 1) * v for v in range(n)], pa.int64())
        for i in range(NCOLS)}
t = pa.table(cols)
pq.write_table(t, sys.argv[1], row_group_size=RPG, data_page_size=1024,
               compression="NONE", use_dictionary=False)
md = pq.ParquetFile(sys.argv[1]).metadata
assert md.num_row_groups == G, md.num_row_groups
print("fixture: %d groups, %d cols, %d rows" % (md.num_row_groups, md.num_columns, md.num_rows))
PYEOF
check "premise: fixture written" "$([ -s "$PGC_WORKDIR/fixture.parquet" ] && echo yes)" "yes"

# ---- fixture server --------------------------------------------------------
python3 "$(dirname "${BASH_SOURCE[0]}")/objstore_http_server.py" \
	--dir "$PGC_WORKDIR" --port "$HTTP_PORT" --log "$HTTP_LOG" \
	> "$PGC_WORKDIR/http_server.out" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do
	grep -q READY "$PGC_WORKDIR/http_server.out" 2>/dev/null && break
	sleep 0.1
done
check "premise: fixture server is up" \
	"$(grep -c READY "$PGC_WORKDIR/http_server.out" 2>/dev/null)" "1"

BASE="http://127.0.0.1:$HTTP_PORT"
COLDEFS="$(python3 -c "print(', '.join('c%d int8' % i for i in range($NCOLS)))")"

psql_run "CREATE SERVER osrv FOREIGN DATA WRAPPER pgcolumnar_parquet;"
psql_run "CREATE FOREIGN TABLE flocal ($COLDEFS) SERVER osrv OPTIONS (path '$PGC_WORKDIR/fixture.parquet');"
psql_run "CREATE FOREIGN TABLE fhttp  ($COLDEFS) SERVER osrv OPTIONS (path '$BASE/fixture.parquet');"

# SQLSTATE of a failing statement (psql VERBOSITY sqlstate prints the bare code).
sqlstate_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
$1;
SQLEOF
}

# Requests logged since the last truncation.
reqs() { wc -l < "$HTTP_LOG" | tr -d ' '; }

# ---- arm A: differential oracle -------------------------------------------
check "A: full scan http == local" \
	"$(pgc_set_hash "SELECT * FROM fhttp")" "$(pgc_set_hash "SELECT * FROM flocal")"
check "A: projection http == local" \
	"$(pgc_set_hash "SELECT c1, c6 FROM fhttp")" "$(pgc_set_hash "SELECT c1, c6 FROM flocal")"
check_num "A: count(*) over http" "$(q "SELECT count(*) FROM fhttp")" "$((G * ROWS_PER_GROUP))"

# ---- arm B: the asserted request count -------------------------------------
# K is arithmetic from the fixture, stated here, not a remembered literal:
# open = 1 HEAD + 3 ranged GETs (head magic, tail, footer); data = one GET per
# needed chunk = G row groups x the projection's column width. The projections
# are sums so every named column is genuinely pulled (count(*) pulls none and
# would make the width premise silently wrong).
SUM_ALL="$(python3 -c "print(' + '.join('sum(c%d)' % i for i in range($NCOLS)))")"
K_FULL=$((4 + G * NCOLS))
K_PROJ=$((4 + G * 2))

: > "$HTTP_LOG"
q "SELECT $SUM_ALL FROM fhttp" >/dev/null
FULL_BUF="$(reqs)"
: > "$HTTP_LOG"
q "SELECT sum(c1) + sum(c6) FROM fhttp" >/dev/null
PROJ_BUF="$(reqs)"

: > "$HTTP_LOG"
env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -qtA \
	-c "SET pgcolumnar.objstore_buffered = off" \
	-c "SELECT $SUM_ALL FROM fhttp" >/dev/null 2>&1
FULL_UNBUF="$(reqs)"

check "premise: buffered run logged requests" "$([ "${FULL_BUF:-0}" -gt 0 ] 2>/dev/null && echo yes)" "yes"
check "premise: unbuffered run logged requests" "$([ "${FULL_UNBUF:-0}" -gt 0 ] 2>/dev/null && echo yes)" "yes"
# Buffered counts are deterministic (keep-alive, no retries in this phase), so
# they are asserted as equalities: stricter than the spec's <= bound, and it
# catches over-coalescing as well as under.
check_num "B: buffered full-width requests (K = 4 + G*NCOLS)" "$FULL_BUF" "$K_FULL"
check_num "B: buffered 2-col requests (K = 4 + G*2)" "$PROJ_BUF" "$K_PROJ"
check_num "B: unbuffered >= 10x K" \
	"$([ "${FULL_UNBUF:-0}" -ge $((10 * K_FULL)) ] 2>/dev/null && echo 1 || echo 0)" "1"
check_ratio "B: buffered/unbuffered request ratio" "$FULL_BUF" "$FULL_UNBUF" "0.1"

# Every data-phase request carried a Range header (the HEAD is the one allowed
# exception per open). The GET-count premise keeps this from passing vacuously
# on an empty log, which is exactly what the RED run produced.
: > "$HTTP_LOG"
q "SELECT sum(c0) FROM fhttp" >/dev/null
NGETS="$(awk '$1 == "GET"' "$HTTP_LOG" | wc -l | tr -d ' ')"
NORANGE="$(awk '$1 == "GET" && $3 == "-"' "$HTTP_LOG" | wc -l | tr -d ' ')"
check "premise: the range-audit phase logged GETs" \
	"$([ "${NGETS:-0}" -gt 0 ] 2>/dev/null && echo yes)" "yes"
check_num "B: every GET carried a Range header" "$NORANGE" "0"

# ---- arm C: failure taxonomy ----------------------------------------------
DEADPORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI" $((HTTP_PORT + 7)))"
psql_run "CREATE FOREIGN TABLE fdead ($COLDEFS) SERVER osrv OPTIONS (path 'http://127.0.0.1:$DEADPORT/fixture.parquet');"
psql_run "CREATE FOREIGN TABLE f404  ($COLDEFS) SERVER osrv OPTIONS (path '$BASE/no_such.parquet');"
psql_run "CREATE FOREIGN TABLE fnorange ($COLDEFS) SERVER osrv OPTIONS (path '$BASE/norange/fixture.parquet');"

check "C: unreachable endpoint SQLSTATE" "$(sqlstate_of "SELECT count(*) FROM fdead")" "08006"
check "C: http 404 SQLSTATE" "$(sqlstate_of "SELECT count(*) FROM f404")" "58P01"
check "C: range-ignoring server SQLSTATE" "$(sqlstate_of "SELECT count(*) FROM fnorange")" "08P01"

# ---- arm D: cancel while the server stalls mid-body ------------------------
psql_run "CREATE FOREIGN TABLE fstall ($COLDEFS) SERVER osrv OPTIONS (path '$BASE/stall/fixture.parquet');"
D_START=$(date +%s)
D_STATE="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
	-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
SET statement_timeout = '2s';
SELECT count(*) FROM fstall;
SQLEOF
)"
D_ELAPSED=$(( $(date +%s) - D_START ))
check "D: stalled transfer cancelled with query_canceled" "$D_STATE" "57014"
check_num "D: cancel latency bounded (<=10s)" \
	"$([ "$D_ELAPSED" -le 10 ] 2>/dev/null && echo 1 || echo 0)" "1"

pgc_summary
