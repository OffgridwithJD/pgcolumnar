#!/usr/bin/env bash
#
# pgColumnar Iceberg over object storage (#388 phase 6). iceberg_scan reads a
# table whose metadata.json, manifests, data files, and delete files live in an
# S3 endpoint, not the local filesystem. The proof is that the SAME hand-crafted
# warehouses (warehouse_del, warehouse_nm) and the SAME oracles as the
# filesystem suites (iceberg_deletes, iceberg_name_mapping) read identically
# when served over S3 -- object storage changes the byte source, never the rows.
#
# The endpoint is the local SigV4 fixture server (test/objstore_http_server.py),
# the same one objstore_s3_read.sh uses, so the suite runs in CI without the
# Garage container. The reader reaches it through the pgcolumnar_objstore module
# and ambient AWS_* credentials in the postmaster environment; the recorded
# file:// paths in the committed fixtures rebase onto the s3:// table location,
# exactly as the filesystem relocation test rebases onto $PGC_WORKDIR.
#
# Usage:  test/iceberg_objstore.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# the endpoint allow-list defaults deny-all; trust the local fixture endpoint
export PGC_EXTRA_CONF="pgcolumnar.objstore_allowed_endpoints='127.0.0.1'"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

python3 -c 'import json' 2>/dev/null || pgc_skip python "python3 is needed"

FX="$(dirname "${BASH_SOURCE[0]}")/fixtures/iceberg"
[ -f "$FX/warehouse_del/db/t/metadata/apply.metadata.json" ] \
	|| pgc_skip fixture "iceberg fixtures are missing"

AKID="PGCTESTKEYID"; SECRET="pgctest-secret-shhh"; REGION="pgc-test-1"; BUCKET="pgc-bucket"
S3_PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
S3_LOG="$PGC_WORKDIR/s3.log"
SRV_PID=""

objstore_iceberg_teardown() {
	[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
	pgc_teardown
}
trap objstore_iceberg_teardown EXIT INT TERM

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

# ---- serve the warehouses under the bucket, at their recorded db/t layout ---
# The committed metadata records file:///tmp/pgc_ice_del/db/t ; served here as
# s3://BUCKET/db/t so the actual root the reader derives (dirname twice of the
# metadata URL) is s3://BUCKET/db/t and the recorded paths rebase onto it.
mkdir -p "$PGC_WORKDIR/$BUCKET"
cp -r "$FX/warehouse_del/db" "$PGC_WORKDIR/$BUCKET/db"
cp -r "$FX/warehouse_nm/db/t" "$PGC_WORKDIR/$BUCKET/db/t_nm"
chmod -R u+rwX "$PGC_WORKDIR/$BUCKET"

python3 "$(dirname "${BASH_SOURCE[0]}")/objstore_http_server.py" \
	--dir "$PGC_WORKDIR" --port "$S3_PORT" --log "$S3_LOG" \
	--sigv4-key "$AKID" --sigv4-secret "$SECRET" --sigv4-region "$REGION" \
	> "$PGC_WORKDIR/s3_server.out" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do grep -q READY "$PGC_WORKDIR/s3_server.out" 2>/dev/null && break; sleep 0.1; done
check "premise: sigv4 fixture server is up" \
	"$(grep -c READY "$PGC_WORKDIR/s3_server.out" 2>/dev/null)" "1"

MDROOT="s3://$BUCKET/db/t/metadata"
NMROOT="s3://$BUCKET/db/t_nm/metadata"

# ---- an s3 read with no credentials in the environment is refused -----------
check "config: an s3 iceberg read with no AWS environment is refused (28000)" \
	"$(sqlstate_of "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDROOT/apply.metadata.json')
	                AS t(id bigint, region text, amount int)")" "28000"

# ---- bring up the ambient credentials, then read over s3 --------------------
pg_restart_env "AWS_ENDPOINT_URL='http://127.0.0.1:$S3_PORT'" \
	"AWS_ACCESS_KEY_ID='$AKID'" "AWS_SECRET_ACCESS_KEY='$SECRET'" "AWS_REGION='$REGION'"

del_oracle() {
	python3 - "$FX/warehouse_del/expected_deletes.json" "$1" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
key = {"eq": "eq_surviving", "dv": "dv_surviving"}[sys.argv[2].split(":")[0]]
print(",".join(str(i) for i in o[key][sys.argv[2].split(":")[1]]))
PY
}

# position deletes over s3: same oracle as the filesystem apply arm (3 rows)
check "position deletes read over s3 (surviving == filesystem oracle)" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDROOT/apply.metadata.json')
	      AS t(id bigint, region text, amount int)")" "3"
check "the position-deleted ids are gone over s3" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDROOT/apply.metadata.json')
	      AS t(id bigint, region text, amount int) WHERE id IN (2,4)")" "0"
# equality deletes over s3
check "equality deletes read over s3 (survivors == oracle)" \
	"$(q "SELECT string_agg(id::text, ',' ORDER BY id)
	      FROM pgcolumnar.iceberg_scan('$MDROOT/eqapply.metadata.json')
	        AS t(id bigint, region text, amount int)")" "$(del_oracle eq:eqapply)"
# deletion vectors (Puffin) over s3
check "deletion vectors read over s3 (survivors == oracle)" \
	"$(q "SELECT string_agg(id::text, ',' ORDER BY id)
	      FROM pgcolumnar.iceberg_scan('$MDROOT/dvapply.metadata.json')
	        AS t(id bigint, region text, amount int)")" "$(del_oracle dv:dvapply)"
# a plain (delete-free would be ideal; noapply applies nothing) full read
check "a scan whose delete does not apply reads all rows over s3" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDROOT/noapply.metadata.json')
	      AS t(id bigint, region text, amount int)")" "5"
# name mapping over s3: an id-less data file bound by name, read remotely
check "name mapping reads an id-less file over s3 (5 rows)" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$NMROOT/nmapply.metadata.json')
	      AS t(id bigint, region text, amount int)")" "5"
check "backend still up after the s3 reads" "$(q 'SELECT 1')" "1"

# ---- refusals over s3 -------------------------------------------------------
# a recorded delete path pointing outside the table location (the eqescape
# fixture names file:///etc/hostname) is refused by the lexical containment,
# never fetched
check "a delete path outside the table location is refused over s3 (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDROOT/eqescape.metadata.json')
	                AS t(id bigint, region text, amount int)")" "22023"
check "backend still up after the s3 refusal" "$(q 'SELECT 1')" "1"

# ---- an endpoint not on the allow-list is refused ---------------------------
pg_restart_env "AWS_ENDPOINT_URL='http://127.0.0.2:$S3_PORT'" \
	"AWS_ACCESS_KEY_ID='$AKID'" "AWS_SECRET_ACCESS_KEY='$SECRET'" "AWS_REGION='$REGION'"
check "an endpoint not on objstore_allowed_endpoints is refused" \
	"$(sqlstate_of "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDROOT/apply.metadata.json')
	                AS t(id bigint, region text, amount int)" | grep -cE '.')" "1"
check "backend still up after the endpoint refusal" "$(q 'SELECT 1')" "1"

pgc_summary
