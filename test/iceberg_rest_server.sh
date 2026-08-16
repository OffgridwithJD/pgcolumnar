#!/usr/bin/env bash
#
# pgColumnar Iceberg REST catalog FOREIGN SERVER + USER MAPPING credentials
# (#656). The iceberg_rest_* functions accept a FOREIGN SERVER name in place of a
# catalog URI: the server holds catalog_uri, and the current role's USER MAPPING
# holds the bearer token (kept role-private in pg_user_mapping, never a SQL
# argument or a log line). The proof: with NO PGCOLUMNAR_ICEBERG_REST_TOKEN in
# the environment, a server-name call still authenticates -- so the mapping
# token, not ambient, is what signed the request (the hermetic fixture 401s a
# wrong/absent token).
#
# Usage:  test/iceberg_rest_server.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

python3 -c 'import json' 2>/dev/null || pgc_skip python "python3 is needed"
MODDIR="$("$PGC_PG_CONFIG" --pkglibdir)"
[ -f "$MODDIR/pgcolumnar_objstore.so" ] \
	|| pgc_skip objstore "the object-store module is not installed"

TOKEN="s3cr3t-mapping-token-xyz"
REST_PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
REST_LOG="$PGC_WORKDIR/rest.log"
MDLOC="file:///tmp/pgc_rest/db/events/metadata/00001.metadata.json"
SRV_PID=""

st_teardown() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; pgc_teardown; }
trap st_teardown EXIT INT TERM

sqlstate_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
$1;
SQLEOF
}
pg_restart_env() {
	pgc_pg "pg_ctl -D '$PGC_PGDATA' stop -m fast -w" >/dev/null 2>&1
	pgc_pg "$* pg_ctl -D '$PGC_PGDATA' -l '$PGC_LOGFILE' start -w" >/dev/null 2>&1
	for _ in $(seq 1 30); do [ -n "$(q 'SELECT 1')" ] && return 0; sleep 0.5; done
	echo "FATAL: cluster did not come back after env restart"; exit 1
}

python3 "$(dirname "${BASH_SOURCE[0]}")/iceberg_rest_server.py" \
	--port "$REST_PORT" --log "$REST_LOG" --token "$TOKEN" \
	--namespace db --table events --metadata-location "$MDLOC" \
	> "$PGC_WORKDIR/rest.out" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do grep -q READY "$PGC_WORKDIR/rest.out" 2>/dev/null && break; sleep 0.1; done
check "premise: rest fixture up" "$(grep -c READY "$PGC_WORKDIR/rest.out" 2>/dev/null)" "1"

CAT="http://127.0.0.1:$REST_PORT"
# NO token in the environment: only a USER MAPPING can authenticate.
pg_restart_env ""
q "ALTER SYSTEM SET pgcolumnar.objstore_allowed_endpoints = '127.0.0.1'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null

q "CREATE SERVER cat FOREIGN DATA WRAPPER pgcolumnar_iceberg_catalog
   OPTIONS (catalog_uri '$CAT')" >/dev/null
q "CREATE USER MAPPING FOR postgres SERVER cat OPTIONS (token '$TOKEN')" >/dev/null

# ---- a server-name call authenticates with the mapping token -----------------
check "iceberg_rest_table_location('cat',...) reads via the mapping token" \
	"$(q "SELECT pgcolumnar.iceberg_rest_table_location('cat','db','events')")" \
	"$MDLOC"
check "the request carried an Authorization header" \
	"$(grep -c 'GET /v1/namespaces/db/tables/events AUTH=yes' "$REST_LOG" 2>/dev/null)" "1"

# ---- the mapping token never appears in the PG log ---------------------------
q "ALTER SYSTEM SET log_statement='all'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
q "SELECT pgcolumnar.iceberg_rest_table_location('cat','db','events')" >/dev/null
q "ALTER SYSTEM SET log_statement='none'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
check "the mapping token never appears in the PG server log" \
	"$(grep -c "$TOKEN" "$PGC_LOGFILE" 2>/dev/null)" "0"

# ---- a wrong mapping token is refused by the catalog (28000) -----------------
q "ALTER USER MAPPING FOR postgres SERVER cat OPTIONS (SET token 'wrong-token')" >/dev/null
check "a wrong mapping token is refused (28000)" \
	"$(sqlstate_of "SELECT pgcolumnar.iceberg_rest_table_location('cat','db','events')")" \
	"28000"

# ---- no credential at all (no mapping, no env token) is refused --------------
q "DROP USER MAPPING FOR postgres SERVER cat" >/dev/null
check "no mapping and no env token is refused, not bypassed (28000)" \
	"$(sqlstate_of "SELECT pgcolumnar.iceberg_rest_table_location('cat','db','events')")" \
	"28000"
q "CREATE USER MAPPING FOR postgres SERVER cat OPTIONS (token '$TOKEN')" >/dev/null

# ---- validator: secrets only on a user mapping, uri only on a server ---------
check "a token option on the SERVER is rejected (HV00D)" \
	"$(sqlstate_of "CREATE SERVER bad1 FOREIGN DATA WRAPPER pgcolumnar_iceberg_catalog OPTIONS (catalog_uri '$CAT', token 'x')")" \
	"HV00D"
check "a catalog_uri option on the USER MAPPING is rejected (HV00D)" \
	"$(sqlstate_of "ALTER USER MAPPING FOR postgres SERVER cat OPTIONS (ADD catalog_uri 'x')")" \
	"HV00D"

# ---- OAuth2 client-credentials: mint a bearer, then use it -------------------
# A second fixture requires a client id/secret at POST /v1/oauth/tokens and, on a
# match, mints OATOKEN -- which loadTable then requires. So a green read proves
# the full mint->use flow, with NO env token and NO static mapping token. The
# secret travels only in the POST body; it must appear in neither log.
OCID="client-abc"; OCSEC="s3cr3t-oauth-secret"; OATOKEN="minted-bearer-777"
OPORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
OLOG="$PGC_WORKDIR/orest.log"
python3 "$(dirname "${BASH_SOURCE[0]}")/iceberg_rest_server.py" \
	--port "$OPORT" --log "$OLOG" --token "$OATOKEN" \
	--oauth-client-id "$OCID" --oauth-client-secret "$OCSEC" \
	--namespace db --table events --metadata-location "$MDLOC" \
	> "$PGC_WORKDIR/orest.out" 2>&1 &
OSRV_PID=$!
for _ in $(seq 1 50); do grep -q READY "$PGC_WORKDIR/orest.out" 2>/dev/null && break; sleep 0.1; done
OCAT="http://127.0.0.1:$OPORT"
q "CREATE SERVER ocat FOREIGN DATA WRAPPER pgcolumnar_iceberg_catalog
   OPTIONS (catalog_uri '$OCAT')" >/dev/null
q "CREATE USER MAPPING FOR postgres SERVER ocat
   OPTIONS (oauth_client_id '$OCID', oauth_client_secret '$OCSEC')" >/dev/null

check "a server with an OAuth2 mapping reads by a minted bearer" \
	"$(q "SELECT pgcolumnar.iceberg_rest_table_location('ocat','db','events')")" \
	"$MDLOC"
check "the OAuth2 token endpoint was called (POST /v1/oauth/tokens)" \
	"$(grep -c 'POST /v1/oauth/tokens' "$OLOG" 2>/dev/null)" "1"
check "loadTable then carried the minted bearer (Authorization present)" \
	"$(grep -c 'GET /v1/namespaces/db/tables/events AUTH=yes' "$OLOG" 2>/dev/null)" "1"
check "the client secret never appears in the fixture request log" \
	"$(grep -c "$OCSEC" "$OLOG" 2>/dev/null)" "0"
q "ALTER SYSTEM SET log_statement='all'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
q "SELECT pgcolumnar.iceberg_rest_table_location('ocat','db','events')" >/dev/null
q "ALTER SYSTEM SET log_statement='none'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
check "the client secret never appears in the PG server log" \
	"$(grep -c "$OCSEC" "$PGC_LOGFILE" 2>/dev/null)" "0"

q "ALTER USER MAPPING FOR postgres SERVER ocat OPTIONS (SET oauth_client_secret 'wrong-secret')" >/dev/null
check "a wrong OAuth2 client secret is refused (28000)" \
	"$(sqlstate_of "SELECT pgcolumnar.iceberg_rest_table_location('ocat','db','events')")" \
	"28000"
q "ALTER USER MAPPING FOR postgres SERVER ocat OPTIONS (DROP oauth_client_secret)" >/dev/null
check "a half OAuth2 credential (id, no secret) is refused before any request (28000)" \
	"$(sqlstate_of "SELECT pgcolumnar.iceberg_rest_table_location('ocat','db','events')")" \
	"28000"
check "oauth options are accepted on a USER MAPPING (no error)" \
	"$(sqlstate_of "ALTER USER MAPPING FOR postgres SERVER ocat OPTIONS (ADD oauth_scope 'catalog')")" \
	""
check "an oauth option on the SERVER is rejected (HV00D)" \
	"$(sqlstate_of "CREATE SERVER bad2 FOREIGN DATA WRAPPER pgcolumnar_iceberg_catalog OPTIONS (catalog_uri '$OCAT', oauth_client_secret 'x')")" \
	"HV00D"

# ---- SSRF: a hostile oauth_token_uri is refused by the endpoint allow-list ---
# oauth_token_uri is user-controlled, and the mint POST rides the same guarded
# transport as every catalog request, so a link-local (cloud-metadata) target is
# refused BEFORE any request leaves the backend, not followed. The allow-list is
# 127.0.0.1 here, so 169.254.169.254 is off-list AND link-local; the refusal is
# 42501 (as objstore_allowlist.sh asserts for read_parquet). A complete OAuth
# credential is restored first so the resolver reaches the mint, not the earlier
# half-credential guard.
q "ALTER USER MAPPING FOR postgres SERVER ocat OPTIONS (ADD oauth_client_secret '$OCSEC')" >/dev/null 2>&1
q "ALTER USER MAPPING FOR postgres SERVER ocat OPTIONS (ADD oauth_token_uri 'http://169.254.169.254/v1/oauth/tokens')" >/dev/null
check "a link-local oauth_token_uri is refused by the allow-list (42501)" \
	"$(sqlstate_of "SELECT pgcolumnar.iceberg_rest_table_location('ocat','db','events')")" \
	"42501"
q "ALTER USER MAPPING FOR postgres SERVER ocat OPTIONS (SET oauth_token_uri 'http://10.11.12.13/v1/oauth/tokens')" >/dev/null
check "an off-allow-list oauth_token_uri host is refused (42501)" \
	"$(sqlstate_of "SELECT pgcolumnar.iceberg_rest_table_location('ocat','db','events')")" \
	"42501"
kill "$OSRV_PID" 2>/dev/null

# ---- the URI form still works when the env token is present ------------------
pg_restart_env "PGCOLUMNAR_ICEBERG_REST_TOKEN='$TOKEN'"
q "ALTER SYSTEM SET pgcolumnar.objstore_allowed_endpoints='127.0.0.1'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
check "the catalog-URI form still works with the env token" \
	"$(q "SELECT pgcolumnar.iceberg_rest_table_location('$CAT','db','events')")" \
	"$MDLOC"

check "backend still up" "$(q 'SELECT 1')" "1"
pgc_summary
