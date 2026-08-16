#!/usr/bin/env bash
# Repro for HTTP request-line splitting via CR/LF in an object-store URL path.
# A URL path containing \r\n is emitted verbatim into "GET <path> HTTP/1.1", so
# an unfixed build sends a split request (the injected line reaches the server as
# its own header/request). Post-fix the request is rejected before it is sent.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
CAP="$PGC_WORKDIR/req_capture.txt"
python3 "$(dirname "${BASH_SOURCE[0]}")/crlf_listener.py" "$PORT" "$CAP" 2>"$PGC_WORKDIR/lst.log" &
LPID=$!
for _ in $(seq 1 50); do grep -q LISTENING "$PGC_WORKDIR/lst.log" 2>/dev/null && break; sleep 0.1; done

q "ALTER SYSTEM SET pgcolumnar.objstore_allowed_endpoints='127.0.0.1'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null

# URL whose path smuggles a second line: /x<CR><LF>X-Injected: yes
URL="http://127.0.0.1:$PORT/x"$'\r'$'\n'"X-Injected: yes"
env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
	-c "SELECT * FROM pgcolumnar.read_parquet('$URL') AS t(v int)" >/dev/null 2>"$PGC_WORKDIR/crlf.err"
wait "$LPID" 2>/dev/null || true

echo "-- psql error:"; grep -iE 'ERROR' "$PGC_WORKDIR/crlf.err" | head -1 | sed 's/^/     /'
echo "-- captured request bytes:"; sed 's/^/     /' "$CAP" 2>/dev/null | head -4

# Post-fix: the query is rejected with a CR/LF error and nothing is smuggled.
rej="$(grep -ciE 'CR or LF' "$PGC_WORKDIR/crlf.err" 2>/dev/null | head -1)"
check "a CR/LF in the URL path is rejected before the request is sent" "$rej" "1"
inj="$(grep -ciE 'X-Injected' "$CAP" 2>/dev/null | head -1)"
check "no injected line reached the listener (no request splitting)" "$inj" "0"
check "backend alive" "$(q 'SELECT 1')" "1"
pgc_summary
