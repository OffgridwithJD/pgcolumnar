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

# ---- step 4 (#623): parallel_export_parquet to an s3:// prefix --------------
# The workers already write per-worker objects remotely through the sink; this
# arm proves the dispatcher's remote-awareness: it does not choke on the prefix
# in pexport_prepare_dir, and on cancel it removes the completed keys it wrote.
psql_run "CREATE TABLE es_par (id int8, v int) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('es_par', stripe_row_limit => 5000);"
psql_run "INSERT INTO es_par SELECT g, g % 100 FROM generate_series(1,80000) g;"
PARROWS="$(q "SELECT count(*) FROM es_par")"

: > "$S3_LOG"
check_num "parallel export to an s3:// prefix succeeds" \
	"$(q "SELECT pgcolumnar.parallel_export_parquet('es_par'::regclass, 's3://$BUCKET/par', 4)")" "$PARROWS"
NOBJ="$(ls "$PGC_WORKDIR/$BUCKET/par/" 2>/dev/null | grep -c 'part-.*\.parquet$')"
check "parallel: one object per worker was written (4)" "$NOBJ" "4"
check "parallel: every worker PUT went to the prefix" \
	"$([ "$(logn '^PUT /pgc-bucket/par/part-')" -ge 4 ] && echo yes)" "yes"
# #394: a completed remote export writes a _SUCCESS marker object at the prefix,
# put through the same remote sink (a single PUT), so a consumer listing the
# prefix sees the run completed. It is not a part object (NOBJ==4 above).
check "parallel remote: a _SUCCESS marker object exists at the prefix" \
	"$([ -f "$PGC_WORKDIR/$BUCKET/par/_SUCCESS" ] && echo yes || echo no)" "yes"
check "parallel remote: the marker went to the prefix as a PUT" \
	"$([ "$(logn '^PUT /pgc-bucket/par/_SUCCESS')" -ge 1 ] && echo yes)" "yes"
# read each key back and union; the union equals the source (prefix-union read
# is #619, so this reads the four exact keys, not the prefix).
for i in 0 1 2 3; do
	psql_run "CREATE FOREIGN TABLE fpar_$i (id int8, v int) SERVER wsrv OPTIONS (path 's3://$BUCKET/par/part-000$i.parquet');"
done
check "parallel: the union of the per-worker objects == source" \
	"$(pgc_set_hash "SELECT * FROM fpar_0 UNION ALL SELECT * FROM fpar_1 UNION ALL SELECT * FROM fpar_2 UNION ALL SELECT * FROM fpar_3")" \
	"$(pgc_set_hash "SELECT * FROM es_par")"

# a non-empty prefix is a documented caveat, not enforced remotely: a re-run
# into the same prefix overwrites the same keys and still round-trips.
: > "$S3_LOG"
check_num "parallel: a re-run into the same prefix succeeds (overwrite)" \
	"$(q "SELECT pgcolumnar.parallel_export_parquet('es_par'::regclass, 's3://$BUCKET/par', 4)")" "$PARROWS"

# #632 review: a SMALLER re-run into a used prefix must not leave the prior
# larger run's higher-numbered parts under a freshly-stamped _SUCCESS. First 4
# workers, then 2: the reconcile drops the stale part-0002/0003, so the marker
# certifies exactly the 2 parts this run wrote.
q "SELECT pgcolumnar.parallel_export_parquet('es_par'::regclass, 's3://$BUCKET/sr', 4)" >/dev/null
check "shrink: the 4-worker run wrote 4 parts + marker" \
	"$([ "$(ls "$PGC_WORKDIR/$BUCKET/sr/" 2>/dev/null | grep -c 'part-.*parquet$')" = 4 ] && [ -f "$PGC_WORKDIR/$BUCKET/sr/_SUCCESS" ] && echo ok)" "ok"
q "SELECT pgcolumnar.parallel_export_parquet('es_par'::regclass, 's3://$BUCKET/sr', 2)" >/dev/null
check_num "shrink: a smaller re-run leaves exactly its own 2 parts (stale tail dropped)" \
	"$(ls "$PGC_WORKDIR/$BUCKET/sr/" 2>/dev/null | grep -c 'part-.*parquet$')" "2"
check "shrink: parts 0002/0003 from the larger run are gone" \
	"$([ ! -e "$PGC_WORKDIR/$BUCKET/sr/part-0002.parquet" ] && [ ! -e "$PGC_WORKDIR/$BUCKET/sr/part-0003.parquet" ] && echo gone)" "gone"
check "shrink: _SUCCESS certifies the reconciled prefix" \
	"$([ -f "$PGC_WORKDIR/$BUCKET/sr/_SUCCESS" ] && echo yes)" "yes"

# cancel mid-run: the dispatcher removes the completed keys it wrote. Big table
# + small parts so a worker is mid-multipart when the cancel lands.
psql_run "DROP TABLE IF EXISTS es_parbig;
          CREATE TABLE es_parbig (id int8, pad text) USING pgcolumnar;
          SELECT pgcolumnar.set_options('es_parbig', stripe_row_limit => 4000);
          INSERT INTO es_parbig SELECT g, md5(g::text)||md5((g+1)::text)
                                FROM generate_series(1,3000000) g;"
: > "$S3_LOG"
rm -rf "$PGC_WORKDIR/$BUCKET/cx"
env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -Atq \
	-c "SET pgcolumnar.objstore_part_size = 262144" \
	-c "SELECT pgcolumnar.parallel_export_parquet('es_parbig'::regclass, 's3://$BUCKET/cx', 4)" \
	>"$PGC_WORKDIR/cx_bg.out" 2>&1 &
bgpid=$!
wrote=no
for _ in $(seq 1 300); do
	[ "$(logn '^PUT /pgc-bucket/cx/part-')" -ge 1 ] && { wrote=yes; break; }
	sleep 0.1
done
check "premise: a worker was uploading before the cancel" "$wrote" "yes"
q "SELECT pg_cancel_backend(pid) FROM pg_stat_activity
   WHERE query LIKE '%parallel_export_parquet%' AND state = 'active'
     AND pid <> pg_backend_pid()" >/dev/null
wait "$bgpid" 2>/dev/null || true
check "premise: the export was cancelled, not completed" \
	"$(grep -qiE 'canceling statement|canceled on user request' "$PGC_WORKDIR/cx_bg.out" && echo cancelled || echo completed)" "cancelled"
check "cancel: the dispatcher issued DELETE over the known keys" \
	"$([ "$(logn '^DELETE /pgc-bucket/cx/part-')" -ge 1 ] && echo yes)" "yes"
check_num "cancel: no completed object remains at the prefix" \
	"$(ls "$PGC_WORKDIR/$BUCKET/cx/" 2>/dev/null | grep -c 'part-.*\.parquet$')" "0"
# #394: a cancelled remote run writes no completion marker (it is written last,
# only on full success), and the dispatcher's cleanup also drops any stale one.
check "cancel: no _SUCCESS marker at the prefix" \
	"$([ -e "$PGC_WORKDIR/$BUCKET/cx/_SUCCESS" ] && echo present || echo absent)" "absent"

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
