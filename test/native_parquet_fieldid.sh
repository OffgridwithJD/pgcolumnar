#!/usr/bin/env bash
#
# pgColumnar field-id projection through read_parquet (#388 phase 3c). pyarrow --
# an independent writer -- writes a Parquet file whose columns carry field ids
# that are OUT OF ORDER and disjoint from position (alpha=7, beta=3, gamma=12).
# read_parquet(path, field_ids) must bind each output column to the file column
# with the requested id, reading a subset in the requested order, not the file's.
# A reader fabricating ids from position cannot pass.
#
# Usage:  test/native_parquet_fieldid.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

sqlstate_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
$1;
SQLEOF
}

python3 -c 'import pyarrow.parquet' 2>/dev/null || pgc_skip pyarrow "pyarrow is needed to write the field-id fixture"

FID="$PGC_WORKDIR/fieldid.parquet"       # alpha=7, beta=3, gamma=12
NOID="$PGC_WORKDIR/noid.parquet"         # no field ids at all
DUP="$PGC_WORKDIR/dup.parquet"           # two columns share id 5
python3 - "$FID" "$NOID" "$DUP" <<'PY'
import sys, pyarrow as pa, pyarrow.parquet as pq
fid, noid, dup = sys.argv[1], sys.argv[2], sys.argv[3]

schema = pa.schema([
    pa.field("alpha", pa.int32(),  metadata={b"PARQUET:field_id": b"7"}),
    pa.field("beta",  pa.string(), metadata={b"PARQUET:field_id": b"3"}),
    pa.field("gamma", pa.int32(),  metadata={b"PARQUET:field_id": b"12"}),
])
pq.write_table(pa.table({
    "alpha": pa.array([10, 20, 30], pa.int32()),
    "beta":  pa.array(["x", "y", "z"], pa.string()),
    "gamma": pa.array([100, 200, 300], pa.int32()),
}, schema=schema), fid)

# a file with no field ids at all
pq.write_table(pa.table({"n": pa.array([1, 2], pa.int32())}), noid)

# a file where two columns carry the SAME field id (5)
dschema = pa.schema([
    pa.field("p", pa.int32(), metadata={b"PARQUET:field_id": b"5"}),
    pa.field("q", pa.int32(), metadata={b"PARQUET:field_id": b"5"}),
])
pq.write_table(pa.table({"p": pa.array([1], pa.int32()),
                         "q": pa.array([2], pa.int32())}, schema=dschema), dup)
PY
chmod 644 "$FID" "$NOID" "$DUP"

# ---- projection + reorder: bind by id, not position ------------------------
# ARRAY[12,7] AS t(g int, a int): output g <- id 12 (gamma), a <- id 7 (alpha),
# in THAT order. Positional binding would put alpha(10,20,30) in g -- the value
# is the discriminator, so this arm alone proves id binding.
check "field-id projection binds and reorders by id (g=gamma, a=alpha)" \
	"$(q "SELECT g || '|' || a FROM pgcolumnar.read_parquet('$FID', ARRAY[12,7])
	      AS t(g int, a int) ORDER BY a")" \
	"$(printf '100|10\n200|20\n300|30')"

# ---- projection subset: read one of three columns --------------------------
check "field-id projection reads a subset (only id 3 = beta)" \
	"$(q "SELECT b FROM pgcolumnar.read_parquet('$FID', ARRAY[3]) AS t(b text) ORDER BY b")" \
	"$(printf 'x\ny\nz')"

# positional read still works unchanged (regression guard on the shared path)
check "positional read_parquet is unaffected" \
	"$(q "SELECT alpha || '|' || beta || '|' || gamma
	      FROM pgcolumnar.read_parquet('$FID') AS t(alpha int, beta text, gamma int)
	      ORDER BY alpha")" \
	"$(printf '10|x|100\n20|y|200\n30|z|300')"

# ---- refusals, each its own SQLSTATE ---------------------------------------
check "an absent field id is refused (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.read_parquet('$FID', ARRAY[999]) AS t(x int)")" "22023"
check "a duplicate field id in the file is refused (42702)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.read_parquet('$DUP', ARRAY[5]) AS t(x int)")" "42702"
check "a nested/array output column is refused (0A000)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.read_parquet('$FID', ARRAY[7]) AS t(a int[])")" "0A000"
check "a field_ids/column-count mismatch is refused (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.read_parquet('$FID', ARRAY[7,3]) AS t(a int)")" "22023"
check "a file with no field ids is refused (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.read_parquet('$NOID', ARRAY[1]) AS t(x int)")" "22023"
# a duplicate REQUESTED id (two output columns asking for one file column) is
# refused up front with a clear cause, not left to fail deep in the decode with a
# message that wrongly blames the file (ChronicallyJD's #638 note).
check "a duplicate requested field id is refused (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.read_parquet('$FID', ARRAY[7,7]) AS t(a1 int, a2 int)")" "22023"
check "the duplicate-requested-id error names the id, not the file" \
	"$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -qtA \
		-c "SELECT * FROM pgcolumnar.read_parquet('$FID', ARRAY[7,7]) AS t(a1 int, a2 int)" 2>&1 \
		| grep -c 'requested more than once')" "1"
check "backend still up after the refusals" "$(q 'SELECT 1')" "1"

pgc_summary
