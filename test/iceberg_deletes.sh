#!/usr/bin/env bash
#
# pgColumnar Iceberg position deletes (#388 phase 4a). iceberg_scan reads a table
# whose current snapshot carries a position-delete file and drops the deleted
# rows. The fixture is hand-crafted (test/fixtures/iceberg/warehouse_del) because
# no available writer emits merge-on-read deletes; the data and delete Parquet
# are real pyarrow files and the manifests set exact sequence numbers, so the
# ordering rule (a delete applies only to data with a lower sequence number) is
# testable. The oracle is the data rows minus the deleted positions.
#
# Usage:  test/iceberg_deletes.sh [PG_CONFIG]

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

FX="$(dirname "${BASH_SOURCE[0]}")/fixtures/iceberg"
WHD="$FX/warehouse_del"
[ -f "$WHD/db/t/metadata/apply.metadata.json" ] || pgc_skip fixture "delete fixture is missing"
python3 -c 'import json' 2>/dev/null || pgc_skip python "python3 is needed"

# relocate so recorded root (/tmp/pgc_ice_del) != actual root (rebasing)
DEST="$PGC_WORKDIR/del"
rm -rf "$DEST"; mkdir -p "$DEST"
cp -r "$WHD/db" "$DEST/db"
chmod -R u+rwX "$DEST"
MDIR="$DEST/db/t/metadata"

# the full data, ignoring deletes, is 5 rows -- the baseline the delete removes from
check "premise: the data file has 5 rows before deletes" \
	"$(q "SELECT count(*) FROM pgcolumnar.read_parquet('$DEST/db/t/data/data.parquet')
	      AS t(id bigint, region text, amount int)")" "5"

# ---- position deletes are applied ------------------------------------------
ORACLE="$(python3 - "$FX/warehouse_del/expected_deletes.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
print("\n".join("%d|%s|%d" % (r["id"], r["region"], r["amount"]) for r in o["surviving"]))
PY
)"
check "position deletes drop the listed rows (surviving == oracle)" \
	"$(q "SELECT id || '|' || region || '|' || amount
	      FROM pgcolumnar.iceberg_scan('$MDIR/apply.metadata.json')
	        AS t(id bigint, region text, amount int) ORDER BY id")" \
	"$ORACLE"
check "the deleted ids (2, 4) are gone" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDIR/apply.metadata.json')
	      AS t(id bigint, region text, amount int) WHERE id IN (2,4)")" "0"
check "exactly the two deleted rows were removed (5 - 2 = 3)" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDIR/apply.metadata.json')
	      AS t(id bigint, region text, amount int)")" "3"
# deletes are by row ordinal, independent of column projection: reading only one
# column must still drop the same rows (the ordinal is the row index, not a
# column value)
check "position deletes apply under column projection (id only -> 1,3,5)" \
	"$(q "SELECT string_agg(id::text, ',' ORDER BY id)
	      FROM pgcolumnar.iceberg_scan('$MDIR/apply.metadata.json') AS t(id bigint)")" \
	"1,3,5"

# ---- sequence-number ordering ----------------------------------------------
# The apply arm above uses a delete at the SAME sequence number as the data (5),
# which the spec says applies (data_seq <= delete_seq) -- the boundary that a
# strict > would wrongly exclude. This arm is the other side: a delete OLDER than
# the data (seq 4 < data seq 5) must NOT apply, so all five rows survive.
check "a delete older than the data (lower seq) does not apply (5 rows)" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDIR/noapply.metadata.json')
	      AS t(id bigint, region text, amount int)")" "5"
check "the would-be-deleted ids survive when the delete is older than the data" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDIR/noapply.metadata.json')
	      AS t(id bigint, region text, amount int) WHERE id IN (2,4)")" "2"

# ---- the delete's sequence number is inherited when the entry leaves it null -
# real writers record a null entry sequence number and inherit the manifest's;
# this variant's delete entry is null, inheriting seq 2 from the manifest, so it
# must still apply over the seq-1 data (3 rows survive), proving inheritance.
check "a position delete with an inherited (null-entry) sequence number applies" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDIR/inherit.metadata.json')
	      AS t(id bigint, region text, amount int)")" "3"

# ---- per-file scoping: a delete naming a different data file does not apply -
# the delete is applicable by sequence, but its rows target another data file, so
# none of data.parquet's rows may be dropped (proves the path match excludes, not
# just includes -- a basename-only or always-true match would wrongly delete).
check "a position delete naming a different data file deletes nothing (5 rows)" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDIR/wrongpath.metadata.json')
	      AS t(id bigint, region text, amount int)")" "5"

# ---- equality deletes are refused, not misapplied --------------------------
check "an equality delete is refused (0A000)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/equality.metadata.json')
	                AS t(id bigint, region text, amount int)")" "0A000"
check "backend still up after the equality refusal" "$(q 'SELECT 1')" "1"

pgc_summary
