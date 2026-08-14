#!/usr/bin/env bash
#
# pgColumnar #619: ListObjectsV2 discovery over remote paths. The FDW and
# read_parquet expand a remote prefix (trailing slash) or a remote glob into the
# set of objects under it, by a paged ListObjectsV2 call behind the object-store
# ABI, and Hive partition columns work over a remote prefix.
#
# The fixture (test/objstore_http_server.py) answers ListObjectsV2 over the
# objects on disk, paged by --list-page-size, so the client's continuation-token
# loop is exercised. It verifies every request's SigV4 against an independent
# implementation, so a listing that reads back also proves the C signer signs the
# ?list-type=2&prefix=... query byte-for-byte.
#
# Usage:  test/objstore_listing.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export PGC_EXTRA_CONF="pgcolumnar.objstore_allowed_endpoints='127.0.0.1'"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

python3 -c 'import pyarrow' 2>/dev/null || pgc_skip pyarrow "pyarrow is required to write the fixture"

S3_PORT="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI")"
S3_LOG="$PGC_WORKDIR/s3.log"
SRV_PID=""
AKID="PGCTESTKEYID"
SECRET="pgctest-secret-shhh"
REGION="pgc-test-1"
BUCKET="pgc-bucket"

listing_teardown() {
	[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
	pgc_teardown
}
trap listing_teardown EXIT INT TERM

pg_restart_env() {
	pgc_pg "pg_ctl -D '$PGC_PGDATA' stop -m fast -w" >/dev/null 2>&1
	pgc_pg "$* pg_ctl -D '$PGC_PGDATA' -l '$PGC_LOGFILE' start -w" >/dev/null 2>&1
	for _ in $(seq 1 30); do
		[ -n "$(q 'SELECT 1')" ] && return 0
		sleep 0.5
	done
	echo "FATAL: cluster did not come back after env restart"; exit 1
}
sqlstate_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
$1;
SQLEOF
}
listn() { grep -cE 'list-type=2' "$S3_LOG" | tr -d ' '; }

# ---- fixtures on disk: a prefix of parts, a nested part, hidden + non-parquet,
#      and a Hive-partitioned layout ------------------------------------------
mkdir -p "$PGC_WORKDIR/$BUCKET/lst/sub" \
         "$PGC_WORKDIR/$BUCKET/hive/dt=2026-01-01" \
         "$PGC_WORKDIR/$BUCKET/hive/dt=2026-01-02"
python3 - "$PGC_WORKDIR/$BUCKET" <<'PYEOF'
import sys, os
import pyarrow as pa, pyarrow.parquet as pq
B = sys.argv[1]
def one(path, ids):
    pq.write_table(pa.table({"id": pa.array(ids, pa.int64())}), path)
# three top-level parts (id 0..2, 10..12, 20..22) + one nested (30..32)
one(os.path.join(B, "lst/part-0000.parquet"), [0, 1, 2])
one(os.path.join(B, "lst/part-0001.parquet"), [10, 11, 12])
one(os.path.join(B, "lst/part-0002.parquet"), [20, 21, 22])
one(os.path.join(B, "lst/sub/part-0003.parquet"), [30, 31, 32])
# a hidden marker and a non-parquet object that must be excluded
open(os.path.join(B, "lst/_SUCCESS"), "w").close()
open(os.path.join(B, "lst/notes.txt"), "w").write("not parquet\n")
# Hive: two partitions, each one object
one(os.path.join(B, "hive/dt=2026-01-01/part.parquet"), [1, 2, 3])
one(os.path.join(B, "hive/dt=2026-01-02/part.parquet"), [4, 5, 6])
PYEOF

# page size 2 forces the continuation-token loop for the 4-object prefix
python3 "$(dirname "${BASH_SOURCE[0]}")/objstore_http_server.py" \
	--dir "$PGC_WORKDIR" --port "$S3_PORT" --log "$S3_LOG" \
	--sigv4-key "$AKID" --sigv4-secret "$SECRET" --sigv4-region "$REGION" \
	--list-page-size 2 > "$PGC_WORKDIR/s3_server.out" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do
	grep -q READY "$PGC_WORKDIR/s3_server.out" 2>/dev/null && break; sleep 0.1
done
check "premise: fixture up" "$(grep -c READY "$PGC_WORKDIR/s3_server.out" 2>/dev/null)" "1"

pg_restart_env "AWS_ENDPOINT_URL='http://127.0.0.1:$S3_PORT'" \
	"AWS_ACCESS_KEY_ID='$AKID'" "AWS_SECRET_ACCESS_KEY='$SECRET'" "AWS_REGION='$REGION'"

psql_run "CREATE SERVER s3srv FOREIGN DATA WRAPPER pgcolumnar_parquet;"

# ---- read_parquet over a remote directory prefix (recursive) ----------------
: > "$S3_LOG"
check "read_parquet over a prefix reads every object under it (4 parts, recursive)" \
	"$(q "SELECT count(*), sum(id) FROM pgcolumnar.read_parquet('s3://$BUCKET/lst/') AS t(id int8);" | tr '|' ' ')" \
	"12 192"
check "the prefix listing paged (more than one list-type=2 request)" \
	"$([ "$(listn)" -ge 2 ] && echo paged)" "paged"

# ---- the FDW over the same prefix -------------------------------------------
psql_run "CREATE FOREIGN TABLE fprefix (id int8) SERVER s3srv OPTIONS (path 's3://$BUCKET/lst/');"
check "FDW over a prefix == read_parquet over the prefix" \
	"$(pgc_set_hash "SELECT * FROM fprefix")" \
	"$(pgc_set_hash "SELECT * FROM pgcolumnar.read_parquet('s3://$BUCKET/lst/') AS t(id int8)")"
check "hidden (_SUCCESS) and non-parquet (notes.txt) objects are excluded" \
	"$(q "SELECT count(*) FROM fprefix")" "12"

# ---- a remote glob applies segment by segment (top level only) --------------
check "glob s3://.../lst/*.parquet matches the 3 top-level parts, not sub/" \
	"$(q "SELECT count(*), sum(id) FROM pgcolumnar.read_parquet('s3://$BUCKET/lst/*.parquet') AS t(id int8);" | tr '|' ' ')" \
	"9 99"

# ---- an exact key is still one GET, no LIST ---------------------------------
: > "$S3_LOG"
psql_run "CREATE FOREIGN TABLE fexact (id int8) SERVER s3srv OPTIONS (path 's3://$BUCKET/lst/part-0000.parquet');"
check "exact-key read returns its rows" "$(q "SELECT count(*), sum(id) FROM fexact" | tr '|' ' ')" "3 3"
check "an exact-key read issues no ListObjectsV2" "$(listn)" "0"

# ---- Hive partition columns over a remote prefix ----------------------------
psql_run "CREATE FOREIGN TABLE fhive (id int8, dt date) SERVER s3srv
          OPTIONS (path 's3://$BUCKET/hive/', partition_columns 'dt');"
check "Hive over a remote prefix stamps the partition column" \
	"$(q "SELECT dt, count(*) FROM fhive GROUP BY dt ORDER BY dt;" | tr '\n|' ' ')" \
	"2026-01-01 3 2026-01-02 3 "
check "a partition predicate prunes a remote file (Files Pruned = 1)" \
	"$(q "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
	      SELECT count(*) FROM fhive WHERE dt = DATE '2026-01-01';" \
		| grep 'Files Pruned' | grep -oE '[0-9]+' | head -1)" "1"

# ---- a non-advancing continuation token is refused, not looped forever ------
# A broken or hostile endpoint that replays one truncated page with the same
# token would spin the paging loop toward the page cap. The client detects the
# token that does not advance and errors (08P01) instead. Removal proof: without
# that check the read loops until statement_timeout (57014), not 08P01.
cat > "$PGC_WORKDIR/__listing_override__" <<'XML'
<?xml version="1.0"?><ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>STUCK</NextContinuationToken><Contents><Key>lst/part-0000.parquet</Key></Contents></ListBucketResult>
XML
check "a non-advancing continuation token is refused, not an infinite paging loop" \
	"$(sqlstate_of "SET statement_timeout='10s'; SELECT count(*) FROM pgcolumnar.read_parquet('s3://$BUCKET/lst/') AS t(id int8)")" "08P01"
rm -f "$PGC_WORKDIR/__listing_override__"

# ---- optional: a real S3 (Garage), same as the sibling suites ---------------
if [ -n "${PGC_S3_INTEGRATION_ENDPOINT:-}" ]; then
	:
fi

pgc_summary
