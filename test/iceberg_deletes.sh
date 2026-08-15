#!/usr/bin/env bash
#
# pgColumnar Iceberg row-level deletes (#388 phases 4a position + 4b equality).
# iceberg_scan reads a table whose current snapshot carries delete files and
# drops the deleted rows. The fixture is hand-crafted
# (test/fixtures/iceberg/warehouse_del) because no available writer emits
# merge-on-read deletes; the data and delete Parquet are real pyarrow files and
# the manifests set exact sequence numbers, so both ordering rules (position:
# data_seq <= delete_seq; equality: data_seq < delete_seq, strictly) sit on
# testable boundaries. The oracle is the data rows minus the deletes.
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

# the first ERROR message line, for telling apart same-SQLSTATE refusals
errmsg_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  //p' | head -1
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
# this variant's delete entry is null, inheriting seq 5 from the manifest, so it
# must still apply over the seq-5 data (3 rows survive), proving inheritance.
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

# ---- 4b: equality deletes are applied ---------------------------------------
# per-variant surviving id list from the generator's oracle
eq_oracle() {
	python3 - "$FX/warehouse_del/expected_deletes.json" "$1" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
print(",".join(str(i) for i in o["eq_surviving"][sys.argv[2]]))
PY
}
eq_ids_of() {
	q "SELECT string_agg(id::text, ',' ORDER BY id)
	   FROM pgcolumnar.iceberg_scan('$MDIR/$1.metadata.json')
	     AS t(id bigint, region text, amount int)"
}

check "equality delete drops matching rows (survivors == oracle)" \
	"$(eq_ids_of eqapply)" "$(eq_oracle eqapply)"
# THE boundary that distinguishes the equality rule (strict <) from the position
# rule (<=): the same delete file at a sequence number EQUAL to the data's must
# delete NOTHING (an equality delete never touches same-commit data)
check "an equality delete at an equal sequence number does not apply" \
	"$(eq_ids_of eqboundary)" "$(eq_oracle eqboundary)"
# multi-column equality is an AND: (3,'eu') matches no row (3 is 'us'), so only
# (4,'us') deletes
check "multi-column equality matches all columns (AND, not OR)" \
	"$(eq_ids_of eqmulti)" "$(eq_oracle eqmulti)"
# only the equality_ids columns define the match; the delete file's extra amount
# column carries a wrong value that must be ignored
check "columns beyond equality_ids are ignored for matching" \
	"$(eq_ids_of eqextra)" "$(eq_oracle eqextra)"
# null matches null (IS NULL semantics), and ONLY null: id 6 (region NULL) goes,
# id 7 ('eu') stays
check "a null delete value matches only null data values" \
	"$(eq_ids_of eqnull)" "$(eq_oracle eqnull)"
check "the null-region row is gone, the non-null rows remain" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDIR/eqnull.metadata.json')
	      AS t(id bigint, region text, amount int) WHERE region IS NULL")" "0"
# two delete files with different equality_ids in one manifest: both apply
check "multiple equality-delete files apply their union" \
	"$(eq_ids_of eqtwo)" "$(eq_oracle eqtwo)"
# position and equality deletes in one snapshot: the skip sets merge
check "position and equality deletes combine" \
	"$(eq_ids_of eqmixed)" "$(eq_oracle eqmixed)"
# the delete columns come from the table schema, not the output list: a scan
# projecting only amount must still drop the id-matched rows
check "equality deletes apply when the delete column is not projected" \
	"$(q "SELECT string_agg(amount::text, ',' ORDER BY amount)
	      FROM pgcolumnar.iceberg_scan('$MDIR/eqapply.metadata.json') AS t(amount int)")" \
	"10,30,50"
check "backend still up after the equality applications" "$(q 'SELECT 1')" "1"

# ---- 4b: equality refusal and corruption arms -------------------------------
# content=2 with null equality_ids is corrupt metadata (the spec requires it);
# the pre-4b fixture (equality.metadata.json) has no equality_ids field at all,
# which decodes the same way
check "an equality delete without equality_ids is refused (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/eqnoids.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
check "a manifest schema lacking equality_ids decodes as corrupt too (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/equality.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
# a partition-scoped equality delete would over-delete if applied globally; it is
# refused, and the message must name the partition cause (the SQLSTATE alone
# matches the old blanket refusal)
check "a partition-scoped equality delete is refused (0A000)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/eqpart.metadata.json')
	                AS t(id bigint, region text, amount int)")" "0A000"
check "...and the refusal names the partition scoping" \
	"$(errmsg_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/eqpart.metadata.json')
	              AS t(id bigint, region text, amount int)" | grep -c "partition")" "1"
# an equality column of a type with no supported mapping (timestamp) is refused
# before any file is opened
check "an equality delete on an unsupported column type is refused (0A000)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/eqtype.metadata.json')
	                AS t(id bigint, region text, amount int)")" "0A000"
check "...and the refusal names the type" \
	"$(errmsg_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/eqtype.metadata.json')
	              AS t(id bigint, region text, amount int)" | grep -c "type")" "1"
# an equality column present in the schema and delete file but absent from the
# data file errors loudly (the reader's missing-field-id error), never silently
# skips the delete
check "an equality column missing from the data file errors (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/eqmissing.metadata.json')
	                AS t(id bigint, region text, amount int)")" "22023"
# a delete-file path outside the table root is stopped by the path boundary
# (22023 from the boundary, BEFORE the file is opened; if the boundary were
# gone, /etc/hostname would be read and fail differently)
check "an equality-delete path outside the table location is refused (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/eqescape.metadata.json')
	                AS t(id bigint, region text, amount int)")" "22023"
check "...and the boundary refusal names the escape" \
	"$(errmsg_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/eqescape.metadata.json')
	              AS t(id bigint, region text, amount int)" | grep -c "table location")" "1"
check "backend still up after the equality refusals" "$(q 'SELECT 1')" "1"

# ---- spec: inheritance is ADDED-only; a null seq on an EXISTING entry is bad --
# the spec inherits a null sequence number only for status-1 (ADDED) entries; an
# EXISTING (status 0) entry with a null sequence number is corrupt, and silently
# inheriting the too-new manifest number could keep rows a delete should remove.
check "an EXISTING entry with a null sequence number is refused (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/badseq.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
check "backend still up after the bad-sequence refusal" "$(q 'SELECT 1')" "1"

pgc_summary
