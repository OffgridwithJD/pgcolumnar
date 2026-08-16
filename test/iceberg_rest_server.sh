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

# ---- the URI form still works when the env token is present ------------------
pg_restart_env "PGCOLUMNAR_ICEBERG_REST_TOKEN='$TOKEN'"
q "ALTER SYSTEM SET pgcolumnar.objstore_allowed_endpoints='127.0.0.1'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
check "the catalog-URI form still works with the env token" \
	"$(q "SELECT pgcolumnar.iceberg_rest_table_location('$CAT','db','events')")" \
	"$MDLOC"

check "backend still up" "$(q 'SELECT 1')" "1"
pgc_summary
