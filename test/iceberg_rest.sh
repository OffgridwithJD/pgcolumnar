#!/usr/bin/env bash
#
# pgColumnar Iceberg REST Catalog client, 7a (#388 phase 7). iceberg_scan reads
# a table given a metadata path; the REST client resolves a table NAMED by a
# catalog (catalog URI + namespace + table) over HTTP into its current metadata
# location, which the reader (already remote-capable since phase 6) then reads.
#
# 7a lands the transport (objstore ABI v5 generic http_request) and its first
# consumer, iceberg_rest_table_location(catalog, ns, table) -> the current
# metadata-location text. The proof runs against a hermetic REST fixture
# (test/iceberg_rest_server.py) that VERIFIES the Authorization: Bearer header,
# so a green resolve proves the C client and an independent server agree on the
# request. The bearer token is read from the SERVER PROCESS ENVIRONMENT
# (PGCOLUMNAR_ICEBERG_REST_TOKEN), never a SQL argument -- so it never lands in
# a log; the suite asserts exactly that.
#
# TLS is not re-proven here: http_request rides the same os_connect/
# os_tls_handshake path objstore_tls_read.sh already gates, unchanged.
#
# Usage:  test/iceberg_rest.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

python3 -c 'import json' 2>/dev/null || pgc_skip python "python3 is needed"
MODDIR="$("$PGC_PG_CONFIG" --pkglibdir)"
[ -f "$MODDIR/pgcolumnar_objstore.so" ] \
	|| pgc_skip objstore "the object-store module is not installed"

TOKEN="s3cr3t-rest-token-do-not-log"
REST_PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
REST_LOG="$PGC_WORKDIR/rest.log"
# 7a only returns the location text, so any URI serves; use a realistic one.
MDLOC="file:///tmp/pgc_ice_rest/db/events/metadata/00001.metadata.json"
SRV_PID=""

rest_teardown() {
	[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
	pgc_teardown
}
trap rest_teardown EXIT INT TERM

sqlstate_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
$1;
SQLEOF
}

# restart the postmaster with a given environment prefix (the REST token lives
# in the server process environment, like the objstore AWS_* credentials).
pg_restart_env() {
	pgc_pg "pg_ctl -D '$PGC_PGDATA' stop -m fast -w" >/dev/null 2>&1
	pgc_pg "$* pg_ctl -D '$PGC_PGDATA' -l '$PGC_LOGFILE' start -w" >/dev/null 2>&1
	for _ in $(seq 1 30); do [ -n "$(q 'SELECT 1')" ] && return 0; sleep 0.5; done
	echo "FATAL: cluster did not come back after env restart"; exit 1
}

# ---- start the hermetic REST catalog, token-protected -----------------------
python3 "$(dirname "${BASH_SOURCE[0]}")/iceberg_rest_server.py" \
	--port "$REST_PORT" --log "$REST_LOG" --token "$TOKEN" \
	--namespace db --table events \
	--metadata-location "$MDLOC" \
	> "$PGC_WORKDIR/rest_server.out" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do grep -q READY "$PGC_WORKDIR/rest_server.out" 2>/dev/null && break; sleep 0.1; done
check "premise: rest fixture server is up" \
	"$(grep -c READY "$PGC_WORKDIR/rest_server.out" 2>/dev/null)" "1"

CAT="http://127.0.0.1:$REST_PORT"

# bring the token into the postmaster environment and allow the local endpoint
pg_restart_env "PGCOLUMNAR_ICEBERG_REST_TOKEN='$TOKEN'"
q "ALTER SYSTEM SET pgcolumnar.objstore_allowed_endpoints = '127.0.0.1'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null

# ---- the core resolve -------------------------------------------------------
check "loadTable resolves the current metadata-location" \
	"$(q "SELECT pgcolumnar.iceberg_rest_table_location('$CAT','db','events')")" \
	"$MDLOC"

# the request actually carried a bearer header (else the fixture would 401)
check "the loadTable request carried an Authorization header" \
	"$(grep -c 'GET /v1/namespaces/db/tables/events AUTH=yes' "$REST_LOG" 2>/dev/null)" "1"

# ---- the token never leaks --------------------------------------------------
# it is not a SQL argument, so it is absent from a log_statement='all' PG log,
# and the fixture records only AUTH=yes/no, never the value.
q "ALTER SYSTEM SET log_statement='all'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
q "SELECT pgcolumnar.iceberg_rest_table_location('$CAT','db','events')" >/dev/null
q "ALTER SYSTEM SET log_statement='none'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
check "the token never appears in the server (PG) log" \
	"$(grep -c "$TOKEN" "$PGC_LOGFILE" 2>/dev/null)" "0"
check "the token value never appears in the catalog request log" \
	"$(grep -c "$TOKEN" "$REST_LOG" 2>/dev/null)" "0"

# ---- auth failures surface cleanly (28000) ----------------------------------
pg_restart_env "PGCOLUMNAR_ICEBERG_REST_TOKEN='wrong-token'"
q "ALTER SYSTEM SET pgcolumnar.objstore_allowed_endpoints = '127.0.0.1'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
check "a wrong bearer token is refused (28000)" \
	"$(sqlstate_of "SELECT pgcolumnar.iceberg_rest_table_location('$CAT','db','events')")" \
	"28000"

pg_restart_env ""   # no token in the environment at all
q "ALTER SYSTEM SET pgcolumnar.objstore_allowed_endpoints = '127.0.0.1'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
check "an anonymous request to a token-protected catalog is refused (28000)" \
	"$(sqlstate_of "SELECT pgcolumnar.iceberg_rest_table_location('$CAT','db','events')")" \
	"28000"

# restore the good token for the remaining arms
pg_restart_env "PGCOLUMNAR_ICEBERG_REST_TOKEN='$TOKEN'"

# ---- the allow-list is the SSRF boundary (42501) ----------------------------
check "a catalog endpoint off the allow-list is refused (42501)" \
	"$(sqlstate_of "SET pgcolumnar.objstore_allowed_endpoints='127.0.0.1';
	                SELECT pgcolumnar.iceberg_rest_table_location('http://127.0.0.2:$REST_PORT','db','events')")" \
	"42501"

# a link-local / instance-metadata catalog is refused even when allow-listed
check "a link-local catalog host is refused even if allow-listed (42501)" \
	"$(sqlstate_of "SET pgcolumnar.objstore_allowed_endpoints='169.254.169.254';
	                SELECT pgcolumnar.iceberg_rest_table_location('http://169.254.169.254/','db','events')")" \
	"42501"

# ---- a response beyond the cap is refused (54000) ---------------------------
check "an over-cap catalog response is refused (54000)" \
	"$(sqlstate_of "SET pgcolumnar.objstore_allowed_endpoints='127.0.0.1';
	                SELECT pgcolumnar.iceberg_rest_table_location('$CAT','db','toobig')")" \
	"54000"

# ---- an unknown table surfaces the catalog 404 cleanly (42P01) --------------
check "an unknown table surfaces a clean not-found (42P01)" \
	"$(sqlstate_of "SET pgcolumnar.objstore_allowed_endpoints='127.0.0.1';
	                SELECT pgcolumnar.iceberg_rest_table_location('$CAT','db','nosuch')")" \
	"42P01"

# ---- a non-object /v1/config body is refused, never walked (XX001) ----------
# an untrusted catalog whose config is a JSON array/scalar must not reach the
# object-only key lookup: a debug build would Assert-crash, a release build would
# read out of bounds. A second fixture serves "[]" for /v1/config.
BAD_PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
python3 "$(dirname "${BASH_SOURCE[0]}")/iceberg_rest_server.py" \
	--port "$BAD_PORT" --log "$PGC_WORKDIR/badcfg.log" --bad-config \
	--metadata-location "$MDLOC" \
	> "$PGC_WORKDIR/badcfg.out" 2>&1 &
BAD_PID=$!
for _ in $(seq 1 50); do grep -q READY "$PGC_WORKDIR/badcfg.out" 2>/dev/null && break; sleep 0.1; done
check "a non-object catalog config is refused, not walked (XX001)" \
	"$(sqlstate_of "SET pgcolumnar.objstore_allowed_endpoints='127.0.0.1';
	                SELECT pgcolumnar.iceberg_rest_table_location('http://127.0.0.1:$BAD_PORT','db','events')")" \
	"XX001"
kill "$BAD_PID" 2>/dev/null

# ---- backend still healthy after the refusals -------------------------------
check "backend still up after the REST refusals" "$(q 'SELECT 1')" "1"

pgc_summary
