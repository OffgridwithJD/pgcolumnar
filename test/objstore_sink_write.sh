#!/usr/bin/env bash
#
# pgColumnar #394 steps 3-4: the remote sink - exports to s3://, multipart
# above the part size, complete-or-abort, parallel per-worker objects.
#
# The fixture server emulates multipart faithfully (create/parts/complete/
# abort, parts invisible until complete) under the same stdlib SigV4 verifier
# as the read side - now including PAYLOAD HASHES and canonical QUERY strings,
# so every write arm is a cross-implementation signature check of the parts
# M2's read-only signing never exercised. design/ISSUE_394_REMOTE_SINK.md.
#
# The invariant under test is step 1's, verbatim: nothing is ever visible at
# the final name before finish() returns. S3 gives it via multipart; the arms
# that matter are the failure ones - an aborted upload leaves NOTHING, keyed
# or partial.
#
# Usage:  test/objstore_sink_write.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export PGC_EXTRA_CONF=$'pgcolumnar.objstore_allowed_endpoints=\'127.0.0.1\'\nmax_worker_processes=16'

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

S3_PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
S3_LOG="$PGC_WORKDIR/sink.log"
SRV_PID=""
AKID="PGCTESTKEYID"
SECRET="pgctest-secret-shhh"
REGION="pgc-test-1"
BUCKET="pgc-bucket"

objstore_sink_teardown() {
	[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
	pgc_teardown
}
trap objstore_sink_teardown EXIT INT TERM

pg_restart_env() {
	pgc_pg "pg_ctl -D '$PGC_PGDATA' stop -m fast -w" >/dev/null 2>&1
	pgc_pg "$* pg_ctl -D '$PGC_PGDATA' -l '$PGC_LOGFILE' start -w" >/dev/null 2>&1
	for _ in $(seq 1 30); do [ -n "$(q 'SELECT 1')" ] && return 0; sleep 0.5; done
	echo "FATAL: cluster did not come back"; exit 1
}
sqlstate_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
$1;
SQLEOF
}
logn() { grep -cE "$1" "$S3_LOG" | tr -d ' '; }

mkdir -p "$PGC_WORKDIR/$BUCKET"
python3 "$(dirname "${BASH_SOURCE[0]}")/objstore_http_server.py" \
	--dir "$PGC_WORKDIR" --port "$S3_PORT" --log "$S3_LOG" \
	--sigv4-key "$AKID" --sigv4-secret "$SECRET" --sigv4-region "$REGION" \
	> "$PGC_WORKDIR/sink_server.out" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do
	grep -q READY "$PGC_WORKDIR/sink_server.out" 2>/dev/null && break
	sleep 0.1
done
check "premise: sigv4 fixture server is up" \
	"$(grep -c READY "$PGC_WORKDIR/sink_server.out" 2>/dev/null)" "1"

pg_restart_env "AWS_ENDPOINT_URL='http://127.0.0.1:$S3_PORT'" \
	"AWS_ACCESS_KEY_ID='$AKID'" "AWS_SECRET_ACCESS_KEY='$SECRET'" \
	"AWS_REGION='$REGION'"

# ---- fixtures: small (single PUT) and large (multipart) ---------------------
psql_run "CREATE TABLE es_small (id int, t text) USING pgcolumnar;"
psql_run "INSERT INTO es_small SELECT g, 'row-'||g FROM generate_series(1,1000) g;"
psql_run "CREATE TABLE es_big (id int8, pad text) USING pgcolumnar;"
psql_run "INSERT INTO es_big SELECT g, md5(g::text)||md5((g+1)::text) FROM generate_series(1,400000) g;"
psql_run "CREATE SERVER wsrv FOREIGN DATA WRAPPER pgcolumnar_parquet;"

# Force the multipart path on this modest fixture: a 256 KB part means the big
# export crosses several parts without generating tens of MiB. Set inline in
# the same session as the big export (below), the form the injection GUC uses.
PART="SET pgcolumnar.objstore_part_size = 262144;"
qset() {  # qset <sql>  -- scalar under the small-part GUC
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$PART $1" 2>/dev/null | tail -1
}

# ---- step 3: single-object round trips through the module BOTH ways ---------
: > "$S3_LOG"
check_num "small export to s3:// succeeds" \
	"$(q "SELECT pgcolumnar.export_parquet('es_small', 's3://$BUCKET/small.parquet')")" "1000"
check_num "small object went as ONE plain PUT (no multipart)" \
	"$(logn '^PUT /pgc-bucket/small.parquet -')" "1"
psql_run "CREATE FOREIGN TABLE f_small (id int, t text) SERVER wsrv OPTIONS (path 's3://$BUCKET/small.parquet');"
check "small round trip: s3 read-back == source" \
	"$(pgc_set_hash "SELECT * FROM f_small")" "$(pgc_set_hash "SELECT * FROM es_small")"

: > "$S3_LOG"
BIGROWS="$(q "SELECT count(*) FROM es_big")"
check_num "large export to s3:// succeeds" \
	"$(qset "SELECT pgcolumnar.export_parquet('es_big', 's3://$BUCKET/big.parquet')")" "$BIGROWS"
check "premise: the large export took the multipart protocol" \
	"$([ "$(logn '^POST /pgc-bucket/big.parquet uploads=')" -ge 1 ] && [ "$(logn '^PUT /pgc-bucket/big.parquet partNumber=')" -ge 2 ] && echo yes || echo no)" "yes"
check_num "and completed it exactly once (POST with uploadId, no partNumber)" \
	"$(logn '^POST /pgc-bucket/big.parquet uploadId=')" "1"
psql_run "CREATE FOREIGN TABLE f_big (id int8, pad text) SERVER wsrv OPTIONS (path 's3://$BUCKET/big.parquet');"
check "large round trip: s3 read-back == source" \
	"$(pgc_set_hash "SELECT * FROM f_big")" "$(pgc_set_hash "SELECT * FROM es_big")"

# ---- injection: abort mid-part leaves NOTHING -------------------------------
: > "$S3_LOG"
# fail_after well above one part so the fault lands mid-multipart, after at
# least one part and the CreateMultipartUpload.
check "inject: mid-upload failure surfaces as disk-full (53100)" \
	"$(sqlstate_of "$PART SET pgcolumnar.sink_fail_after = 900000; SELECT pgcolumnar.export_parquet('es_big', 's3://$BUCKET/fail.parquet')")" "53100"
check "inject: the key does not exist" \
	"$([ ! -e "$PGC_WORKDIR/$BUCKET/fail.parquet" ] && echo clean)" "clean"
# the money check: every multipart upload STARTED for this key was ABORTED, so
# nothing dangles to bill (robust to exactly where the injected fault landed -
# if it landed before multipart began, both counts are 0).
STARTED="$(logn '^POST /pgc-bucket/fail.parquet uploads=')"
ABORTED="$(logn '^DELETE /pgc-bucket/fail.parquet uploadId=')"
check "premise: the fault landed mid-multipart (an upload was started)" \
	"$([ "${STARTED:-0}" -ge 1 ] && echo yes)" "yes"
check_num "inject: every upload started was aborted (no billable orphan)" \
	"$ABORTED" "$STARTED"

# ---- taxonomy: the write side wears the same gates as the read side ---------
check "allow-list: an unlisted endpoint refuses 42501 before any write" \
	"$(sqlstate_of "SELECT pgcolumnar.export_parquet('es_small', 'http://127.0.0.2:1/x.parquet')")" "42501"
check "arrow export to s3:// also round-trips" \
	"$(q "SELECT pgcolumnar.export_arrow('es_small', 's3://$BUCKET/small.arrow') > 0")" "t"

# Parallel export to a remote prefix is step 4 (the dispatcher's local
# directory prep and key cleanup need remote-awareness); tracked separately.

# ---- optional: a real S3 implementation (Garage) ----------------------------
if [ -n "${PGC_S3_INTEGRATION_ENDPOINT:-}" ]; then
	pg_restart_env "AWS_ENDPOINT_URL='$PGC_S3_INTEGRATION_ENDPOINT'" \
		"AWS_ACCESS_KEY_ID='$PGC_S3_INTEGRATION_KEY'" \
		"AWS_SECRET_ACCESS_KEY='$PGC_S3_INTEGRATION_SECRET'" \
		"AWS_REGION='${PGC_S3_INTEGRATION_REGION:-garage}'"
	pgc_pg "echo \"pgcolumnar.objstore_allowed_endpoints='$(echo "${PGC_S3_INTEGRATION_ENDPOINT#http://}" | cut -d/ -f1 | cut -d: -f1)'\" >> '$PGC_PGDATA/postgresql.conf'"
	psql_run "SELECT pg_reload_conf();"
	IB="${PGC_S3_INTEGRATION_BUCKET:-pgcolumnar-test}"
	check_num "integration: multipart export to real S3 succeeds" \
		"$(q "SELECT pgcolumnar.export_parquet('es_big', 's3://$IB/m2sink-$$.parquet')")" "$BIGROWS"
	psql_run "CREATE FOREIGN TABLE f_real (id int8, pad text) SERVER wsrv OPTIONS (path 's3://$IB/m2sink-$$.parquet');"
	check "integration: real S3 read-back == source" \
		"$(pgc_set_hash "SELECT * FROM f_real")" "$(pgc_set_hash "SELECT * FROM es_big")"
else
	echo "note: PGC_S3_INTEGRATION_ENDPOINT unset; the stdlib-verifier arms carry the proof alone"
fi

pgc_summary
