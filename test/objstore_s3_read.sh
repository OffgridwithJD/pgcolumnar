#!/usr/bin/env bash
#
# pgColumnar #393 M2: SigV4-signed s3:// reads, verified against an INDEPENDENT
# implementation of the signature.
#
# The fixture server (test/objstore_http_server.py, sigv4 mode) recomputes
# every request's AWS Signature Version 4 with python's stdlib hmac/hashlib and
# refuses 403 on any mismatch, so every green data check below proves the C
# signer and a second implementation agree on every byte of the canonical
# request. Arms, per design/ISSUE_393_M2_SIGV4.md:
#
#   config   an s3:// read with no AWS_* in the postmaster environment errors
#            28000 naming AWS_ENDPOINT_URL, before any connection exists to
#            fail differently.
#   A        differential oracle vs the byte-identical local file, including a
#            key that needs percent-encoding (space in both directory and
#            file name): an encoding disagreement cannot pass the verifier.
#   B        the M1 request arithmetic holds unchanged under signing
#            (open = HEAD + 3 GETs, data = one GET per needed chunk).
#   token    the postmaster env carries AWS_SESSION_TOKEN and the server
#            REQUIRES x-amz-security-token inside the signed set, so the data
#            arms prove token signing rather than merely tolerating it.
#   403      a tamper bucket the server verifies against a different secret:
#            correct client signature, always refused; must surface 28000 and
#            never rows. 404 on the real bucket stays 58P01, and its
#            reachability doubles as proof requests pass verification first.
#   https    an https:// endpoint is refused 0A000 (TLS is M3), never
#            silently downgraded.
#
# The postmaster environment is the ambient credential source (the decided
# default), so the suite restarts its own cluster between phases instead of
# pretending env can change per-session.
#
# Usage:  test/objstore_s3_read.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The endpoint allow-list (#393) defaults to deny-all; this suite's fixture is
# the documented configuration example for a trusted local endpoint.
export PGC_EXTRA_CONF="pgcolumnar.objstore_allowed_endpoints='127.0.0.1'"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

python3 -c 'import pyarrow' 2>/dev/null || pgc_skip pyarrow "pyarrow is required to write the fixture"

S3_PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
S3_LOG="$PGC_WORKDIR/s3.log"
SRV_PID=""

AKID="PGCTESTKEYID"
SECRET="pgctest-secret-shhh"
REGION="pgc-test-1"
TOKEN="pgctest-session-token"
BUCKET="pgc-bucket"

objstore_s3_teardown() {
	[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
	pgc_teardown
}
trap objstore_s3_teardown EXIT INT TERM

# Restart OUR cluster with the given environment strings in the postmaster.
pg_restart_env() {
	pgc_pg "pg_ctl -D '$PGC_PGDATA' stop -m fast -w" >/dev/null 2>&1
	pgc_pg "$* pg_ctl -D '$PGC_PGDATA' -l '$PGC_LOGFILE' start -w" >/dev/null 2>&1
	for _ in $(seq 1 30); do
		[ -n "$(q 'SELECT 1')" ] && return 0
		sleep 0.5
	done
	echo "FATAL: cluster did not come back after env restart"
	exit 1
}

sqlstate_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
$1;
SQLEOF
}

reqs() { wc -l < "$S3_LOG" | tr -d ' '; }

# ---- fixture ----------------------------------------------------------------
G=3
NCOLS=8
ROWS_PER_GROUP=8000
mkdir -p "$PGC_WORKDIR/$BUCKET/dir with space"

python3 - "$PGC_WORKDIR/$BUCKET/fixture.parquet" <<PYEOF
import sys, shutil
import pyarrow as pa, pyarrow.parquet as pq
G, NCOLS, RPG = $G, $NCOLS, $ROWS_PER_GROUP
n = G * RPG
cols = {("c%d" % i): pa.array([(i + 1) * v for v in range(n)], pa.int64())
        for i in range(NCOLS)}
pq.write_table(pa.table(cols), sys.argv[1], row_group_size=RPG,
               data_page_size=1024, compression="NONE", use_dictionary=False)
shutil.copyfile(sys.argv[1],
                sys.argv[1].rsplit("/", 1)[0] + "/dir with space/f 1.parquet")
PYEOF
check "premise: fixture written" \
	"$([ -s "$PGC_WORKDIR/$BUCKET/fixture.parquet" ] && echo yes)" "yes"

python3 "$(dirname "${BASH_SOURCE[0]}")/objstore_http_server.py" \
	--dir "$PGC_WORKDIR" --port "$S3_PORT" --log "$S3_LOG" \
	--sigv4-key "$AKID" --sigv4-secret "$SECRET" --sigv4-region "$REGION" \
	--sigv4-token "$TOKEN" --tamper-bucket "tamperbkt" \
	> "$PGC_WORKDIR/s3_server.out" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do
	grep -q READY "$PGC_WORKDIR/s3_server.out" 2>/dev/null && break
	sleep 0.1
done
check "premise: sigv4 fixture server is up" \
	"$(grep -c READY "$PGC_WORKDIR/s3_server.out" 2>/dev/null)" "1"

COLDEFS="$(python3 -c "print(', '.join('c%d int8' % i for i in range($NCOLS)))")"
SUM_ALL="$(python3 -c "print(' + '.join('sum(c%d)' % i for i in range($NCOLS)))")"

psql_run "CREATE SERVER s3srv FOREIGN DATA WRAPPER pgcolumnar_parquet;"
psql_run "CREATE FOREIGN TABLE flocal ($COLDEFS) SERVER s3srv OPTIONS (path '$PGC_WORKDIR/$BUCKET/fixture.parquet');"
psql_run "CREATE FOREIGN TABLE fs3 ($COLDEFS) SERVER s3srv OPTIONS (path 's3://$BUCKET/fixture.parquet');"
psql_run "CREATE FOREIGN TABLE fs3enc ($COLDEFS) SERVER s3srv OPTIONS (path 's3://$BUCKET/dir with space/f 1.parquet');"
psql_run "CREATE FOREIGN TABLE fs3tamper ($COLDEFS) SERVER s3srv OPTIONS (path 's3://tamperbkt/fixture.parquet');"
psql_run "CREATE FOREIGN TABLE fs3miss ($COLDEFS) SERVER s3srv OPTIONS (path 's3://$BUCKET/no_such.parquet');"

# ---- phase 1: no AWS environment at all ------------------------------------
check "config: s3 read with no environment is 28000" \
	"$(sqlstate_of "SELECT count(*) FROM fs3")" "28000"

# ---- phase 2: full ambient environment, fixture endpoint --------------------
pg_restart_env "AWS_ENDPOINT_URL='http://127.0.0.1:$S3_PORT'" \
	"AWS_ACCESS_KEY_ID='$AKID'" "AWS_SECRET_ACCESS_KEY='$SECRET'" \
	"AWS_REGION='$REGION'" "AWS_SESSION_TOKEN='$TOKEN'"

check "A: full scan s3 == local" \
	"$(pgc_set_hash "SELECT * FROM fs3")" "$(pgc_set_hash "SELECT * FROM flocal")"
check "A: projection s3 == local" \
	"$(pgc_set_hash "SELECT c1, c6 FROM fs3")" "$(pgc_set_hash "SELECT c1, c6 FROM flocal")"
check "A: percent-encoded key s3 == local" \
	"$(pgc_set_hash "SELECT * FROM fs3enc")" "$(pgc_set_hash "SELECT * FROM flocal")"
check_num "A: count(*) over s3" "$(q "SELECT count(*) FROM fs3")" "$((G * ROWS_PER_GROUP))"

K_FULL=$((4 + G * NCOLS))
: > "$S3_LOG"
q "SELECT $SUM_ALL FROM fs3" >/dev/null
FULL_SIGNED="$(reqs)"
check "premise: signed run logged requests" \
	"$([ "${FULL_SIGNED:-0}" -gt 0 ] 2>/dev/null && echo yes)" "yes"
check_num "B: signing left the request arithmetic unchanged" "$FULL_SIGNED" "$K_FULL"

check "403: tamper bucket surfaces 28000" \
	"$(sqlstate_of "SELECT count(*) FROM fs3tamper")" "28000"
check "403 ordering premise: verified requests still reach 404 = 58P01" \
	"$(sqlstate_of "SELECT count(*) FROM fs3miss")" "58P01"

# ---- phase 3: an https endpoint is never silently downgraded ---------------
# The property is no-downgrade; its SQLSTATE depends on the build. A module
# built with OpenSSL (M3) ACCEPTS the endpoint and then fails the TLS
# handshake against this plain-HTTP fixture, 08006 -- proving the bytes went
# TLS, not cleartext. A module built without OpenSSL refuses outright, 0A000.
# Either way a silent cleartext read (a row count) is the red.
pg_restart_env "AWS_ENDPOINT_URL='https://127.0.0.1:$S3_PORT'" \
	"AWS_ACCESS_KEY_ID='$AKID'" "AWS_SECRET_ACCESS_KEY='$SECRET'" \
	"AWS_REGION='$REGION'"
MOD_SO="$(pgc_pg "$PGC_BINDIR/pg_config --pkglibdir" | tail -1)/pgcolumnar_objstore.so"
if pgc_pg "ldd '$MOD_SO'" 2>/dev/null | grep -q libssl; then
	HTTPS_WANT="08006"
else
	HTTPS_WANT="0A000"
fi
check "https endpoint is not downgraded (want $HTTPS_WANT for this build)" \
	"$(sqlstate_of "SELECT count(*) FROM fs3")" "$HTTPS_WANT"

# ---- phase 4: optional integration against a real S3 implementation --------
if [ -n "${PGC_S3_INTEGRATION_ENDPOINT:-}" ]; then
	pg_restart_env "AWS_ENDPOINT_URL='$PGC_S3_INTEGRATION_ENDPOINT'" \
		"AWS_ACCESS_KEY_ID='$PGC_S3_INTEGRATION_KEY'" \
		"AWS_SECRET_ACCESS_KEY='$PGC_S3_INTEGRATION_SECRET'" \
		"AWS_REGION='${PGC_S3_INTEGRATION_REGION:-garage}'"
	IB="${PGC_S3_INTEGRATION_BUCKET:-pgcolumnar-test}"
	IKEY="m2/integration-$$.parquet"
	if env AWS_ACCESS_KEY_ID="$PGC_S3_INTEGRATION_KEY" \
		AWS_SECRET_ACCESS_KEY="$PGC_S3_INTEGRATION_SECRET" \
		AWS_DEFAULT_REGION="${PGC_S3_INTEGRATION_REGION:-garage}" \
		aws --endpoint-url "$PGC_S3_INTEGRATION_ENDPOINT" \
		s3 cp "$PGC_WORKDIR/$BUCKET/fixture.parquet" "s3://$IB/$IKEY" \
		>/dev/null 2>&1
	then
		psql_run "CREATE FOREIGN TABLE fs3real ($COLDEFS) SERVER s3srv OPTIONS (path 's3://$IB/$IKEY');"
		check "integration: real S3 implementation == local" \
			"$(pgc_set_hash "SELECT * FROM fs3real")" \
			"$(pgc_set_hash "SELECT * FROM flocal")"
	else
		echo "note: integration endpoint set but the upload helper failed;" \
			"the stdlib-verifier arms above carry the proof alone"
	fi
else
	echo "note: PGC_S3_INTEGRATION_ENDPOINT unset; the stdlib-verifier arms" \
		"above carry the proof alone"
fi

pgc_summary
