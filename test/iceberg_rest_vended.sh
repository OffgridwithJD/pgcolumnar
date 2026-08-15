#!/usr/bin/env bash
#
# pgColumnar Iceberg REST catalog VENDED credentials (#656). A REST catalog
# returns, in its loadTable reply, short-lived scoped storage credentials; the
# reader must sign its S3 data/metadata/delete reads with THOSE, not with any
# ambient environment credential. The proof: the postmaster environment holds NO
# AWS_* credentials, the warehouse is served over the SigV4-verifying S3 fixture,
# and a green read can only happen if the request was signed with the vended
# credentials the SigV4 fixture is configured to accept.
#
# Two hermetic servers: the S3 fixture (test/objstore_http_server.py, SigV4) and
# the REST catalog (test/iceberg_rest_server.py) whose loadTable points at an
# s3:// metadata-location and vends the S3 fixture's key/secret/region/endpoint.
#
# Usage:  test/iceberg_rest_vended.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

python3 -c 'import json' 2>/dev/null || pgc_skip python "python3 is needed"
MODDIR="$("$PGC_PG_CONFIG" --pkglibdir)"
[ -f "$MODDIR/pgcolumnar_objstore.so" ] \
	|| pgc_skip objstore "the object-store module is not installed"

FX="$(dirname "${BASH_SOURCE[0]}")/fixtures/iceberg"
[ -f "$FX/warehouse_del/db/t/metadata/apply.metadata.json" ] \
	|| pgc_skip fixture "iceberg fixtures are missing"

AKID="VENDEDKEYID"; SECRET="vended-secret-shh"; REGION="pgc-test-1"; BUCKET="pgc-bucket"
RESTTOK="rest-token-vend"
# One free port is picked per server only AFTER the previous one binds:
# pgc_pick_free_port does not hold the port, so picking six up front returns the
# same number six times (nothing is bound between the picks).
S3_PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
PIDS=""
LAST_PORT=""

vend_teardown() { for p in $PIDS; do kill "$p" 2>/dev/null; done; pgc_teardown; }
trap vend_teardown EXIT INT TERM

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
start_rest() {  # $@=extra args; picks a fresh free port into LAST_PORT
	LAST_PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
	python3 "$(dirname "${BASH_SOURCE[0]}")/iceberg_rest_server.py" \
		--port "$LAST_PORT" --log "$PGC_WORKDIR/rest_$LAST_PORT.log" \
		--namespace db --table t \
		--metadata-location "s3://$BUCKET/db/t/metadata/apply.metadata.json" \
		"$@" > "$PGC_WORKDIR/rest_$LAST_PORT.out" 2>&1 &
	PIDS="$PIDS $!"
	for _ in $(seq 1 50); do grep -q READY "$PGC_WORKDIR/rest_$LAST_PORT.out" 2>/dev/null && break; sleep 0.1; done
}

# ---- serve the warehouse over the SigV4 S3 fixture ---------------------------
mkdir -p "$PGC_WORKDIR/$BUCKET"
cp -r "$FX/warehouse_del/db" "$PGC_WORKDIR/$BUCKET/db"
chmod -R u+rwX "$PGC_WORKDIR/$BUCKET"
python3 "$(dirname "${BASH_SOURCE[0]}")/objstore_http_server.py" \
	--dir "$PGC_WORKDIR" --port "$S3_PORT" --log "$PGC_WORKDIR/s3.log" \
	--sigv4-key "$AKID" --sigv4-secret "$SECRET" --sigv4-region "$REGION" \
	> "$PGC_WORKDIR/s3.out" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 50); do grep -q READY "$PGC_WORKDIR/s3.out" 2>/dev/null && break; sleep 0.1; done
check "premise: the SigV4 S3 fixture is up" \
	"$(grep -c READY "$PGC_WORKDIR/s3.out" 2>/dev/null)" "1"

S3EP="http://127.0.0.1:$S3_PORT"
# the catalog that vends the correct S3 creds + endpoint
start_rest --token "$RESTTOK" \
	--vend-key "$AKID" --vend-secret "$SECRET" --vend-region "$REGION" --vend-endpoint "$S3EP"
CAT="http://127.0.0.1:$LAST_PORT"

# NO AWS_* credentials in the environment: a read can only work with vended ones.
pg_restart_env "PGCOLUMNAR_ICEBERG_REST_TOKEN='$RESTTOK'"
q "ALTER SYSTEM SET pgcolumnar.objstore_allowed_endpoints = '127.0.0.1'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null

# ---- CORE: vended creds sign the S3 reads (no ambient creds exist) -----------
# apply.metadata.json drops ordinals 1,3 (id 2, id 4); survivors 1,3,5.
check "iceberg_rest_scan reads via vended credentials (no ambient creds set)" \
	"$(q "SELECT id || '|' || region || '|' || amount
	      FROM pgcolumnar.iceberg_rest_scan('$CAT','db','t') AS t(id bigint, region text, amount int)
	      ORDER BY id")" \
	"$(printf '1|eu|10\n3|us|30\n5|us|50')"

# ---- a WRONG vended secret is used and refused (403 -> 28000), not bypassed --
start_rest --token "$RESTTOK" \
	--vend-key "$AKID" --vend-secret "wrong-vended-secret" --vend-region "$REGION" --vend-endpoint "$S3EP"
BAD_PORT="$LAST_PORT"
check "a wrong vended secret is refused by S3, not bypassed (28000)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_rest_scan('http://127.0.0.1:$BAD_PORT','db','t')
	                AS t(id bigint, region text, amount int)")" \
	"28000"

# ---- storage-credentials: longest-prefix entry (correct) beats catch-all ----
start_rest --token "$RESTTOK" \
	--vend-key "$AKID" --vend-secret "$SECRET" --vend-region "$REGION" --vend-endpoint "$S3EP" \
	--storage-cred-prefix "s3://$BUCKET/db/t"
SC_PORT="$LAST_PORT"
check "storage-credentials longest-prefix match selects the right creds" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_rest_scan('http://127.0.0.1:$SC_PORT','db','t')
	      AS t(id bigint, region text, amount int)")" \
	"3"

# ---- vended creds do NOT bypass the allow-list ------------------------------
# a catalog that vends an endpoint off the allow-list is refused at the read.
start_rest --token "$RESTTOK" \
	--vend-key "$AKID" --vend-secret "$SECRET" --vend-region "$REGION" \
	--vend-endpoint "http://127.0.0.2:$S3_PORT"
LL_PORT="$LAST_PORT"
check "vended creds for an off-allow-list endpoint are refused (42501)" \
	"$(sqlstate_of "SET pgcolumnar.objstore_allowed_endpoints='127.0.0.1';
	                SELECT * FROM pgcolumnar.iceberg_rest_scan('http://127.0.0.1:$LL_PORT','db','t')
	                AS t(id bigint, region text, amount int)")" \
	"42501"

# ---- ambient still works when the catalog vends nothing ---------------------
start_rest --token "$RESTTOK"   # no --vend-key: config is empty
AMB_PORT="$LAST_PORT"
pg_restart_env "PGCOLUMNAR_ICEBERG_REST_TOKEN='$RESTTOK'" \
	"AWS_ENDPOINT_URL='$S3EP'" "AWS_ACCESS_KEY_ID='$AKID'" \
	"AWS_SECRET_ACCESS_KEY='$SECRET'" "AWS_REGION='$REGION'"
q "ALTER SYSTEM SET pgcolumnar.objstore_allowed_endpoints = '127.0.0.1'" >/dev/null
q "SELECT pg_reload_conf()" >/dev/null
check "a table vending no creds still reads with ambient (cfg NULL path)" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_rest_scan('http://127.0.0.1:$AMB_PORT','db','t')
	      AS t(id bigint, region text, amount int)")" \
	"3"

check "backend still up after the vended-credential arms" "$(q 'SELECT 1')" "1"

pgc_summary
