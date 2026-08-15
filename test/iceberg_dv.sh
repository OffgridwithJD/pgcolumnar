#!/usr/bin/env bash
#
# pgColumnar Iceberg v3 deletion vectors (#388 phase 4c). iceberg_scan reads a
# table whose current snapshot carries Puffin deletion vectors and drops the
# rows they name. Fixtures are hand-crafted (test/fixtures/iceberg/
# warehouse_del, generator gen_delete_fixture.py): pyroaring portable bitmaps
# wrapped in hand-built Puffin files, hand-encoded manifests, exact sequence
# numbers. The hand-derived oracle is cross-checked against two independent
# engines (pyiceberg and DuckDB) by crosscheck_dv.py; the two arms where those
# engines deviate from the spec are documented there, and this suite asserts
# the spec behavior.
#
# Usage:  test/iceberg_dv.sh [PG_CONFIG]

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
[ -f "$WHD/db/t/metadata/dvapply.metadata.json" ] || pgc_skip fixture "deletion-vector fixtures are missing"
python3 -c 'import json' 2>/dev/null || pgc_skip python "python3 is needed"

# relocate so recorded root (/tmp/pgc_ice_del) != actual root (rebasing)
DEST="$PGC_WORKDIR/dv"
rm -rf "$DEST"; mkdir -p "$DEST"
cp -r "$WHD/db" "$DEST/db"
chmod -R u+rwX "$DEST"
MDIR="$DEST/db/t/metadata"

dv_oracle() {
	python3 - "$FX/warehouse_del/expected_deletes.json" "$1" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
print(",".join(str(i) for i in o["dv_surviving"][sys.argv[2]]))
PY
}
dv_ids_of() {
	q "SELECT string_agg(id::text, ',' ORDER BY id)
	   FROM pgcolumnar.iceberg_scan('$MDIR/$1.metadata.json')
	     AS t(id bigint, region text, amount int)"
}

# ---- deletion vectors are applied -------------------------------------------
# THE <= boundary: a DV at the data file's own sequence number applies (same
# rule as 4a position-delete files; a strict > would wrongly exclude it)
check "a deletion vector at an equal sequence number applies (survivors == oracle)" \
	"$(dv_ids_of dvapply)" "$(dv_oracle dvapply)"
# the other side: a DV strictly older than the data applies to nothing
check "a deletion vector older than the data does not apply" \
	"$(dv_ids_of dvnoapply)" "$(dv_oracle dvnoapply)"
# the spec's supersede rule: a position-delete FILE applies only when no DV
# must be applied to the data file. The fixture's DV drops ordinal 1 and its
# (also applicable) Parquet posdel names ordinals 1 and 3; a UNION would drop
# both, supersede drops only ordinal 1.
check "an applicable DV supersedes position-delete files for its data file" \
	"$(dv_ids_of dvsupersede)" "$(dv_oracle dvsupersede)"
# supersede is per data file: a posdel targeting a DIFFERENT data file still
# applies alongside the DV
check "supersede is per data file, not global" \
	"$(dv_ids_of dvother)" "$(dv_oracle dvother)"
# roaring coverage: run-form containers plus a second 64-bit bucket
check "a DV with run containers and a high-bucket position decodes" \
	"$(dv_ids_of dvwide)" "$(dv_oracle dvwide)"
# cookie 12347 (run containers marked in the run bitset)
check "a run-optimized DV (cookie 12347) decodes" \
	"$(dv_ids_of dvrun)" "$(dv_oracle dvrun)"
# a bitset container (cardinality above 4096)
check "a bitset-container DV decodes" \
	"$(dv_ids_of dvbitset)" "$(dv_oracle dvbitset)"
# one Puffin file carrying two DV blobs for two data files
check "two DV blobs in one Puffin file each apply to their own data file" \
	"$(dv_ids_of dvtwo)" "$(dv_oracle dvtwo)"
check "backend still up after the DV applications" "$(q 'SELECT 1')" "1"

# ---- refusal and corruption arms --------------------------------------------
# two DV entries referencing one data file: the spec says scan results are
# undefined and readers may raise; we raise rather than guess
check "two DV entries for one data file are refused (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvdup.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
check "a corrupted DV CRC is refused (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvbadcrc.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
check "a wrong DV blob magic is refused (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvbadmagic.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
# the manifest's content_offset must exactly match the footer's blob offset
check "a manifest/footer offset mismatch is refused (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvoffmismatch.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
# referenced_data_file is required for DVs
check "a DV entry without referenced_data_file is refused (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvnoref.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
# record_count is defined as the DV's cardinality
check "a record_count that disagrees with the DV cardinality is refused (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvbadcount.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
# deletion-vector-v1 blobs must not declare a compression codec
check "a DV blob declaring a compression codec is refused (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvcompressed.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
# a compressed Puffin footer is refused loudly, never misparsed
check "a compressed Puffin footer is refused (0A000)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvflags.metadata.json')
	                AS t(id bigint, region text, amount int)")" "0A000"
check "...and the refusal names the compressed footer" \
	"$(errmsg_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvflags.metadata.json')
	              AS t(id bigint, region text, amount int)" | grep -c "compressed")" "1"
# deletion vectors are v3-only
check "a deletion vector in a format-version 2 table is refused (0A000)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvv2.metadata.json')
	                AS t(id bigint, region text, amount int)")" "0A000"
check "...and the refusal names the format version" \
	"$(errmsg_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvv2.metadata.json')
	              AS t(id bigint, region text, amount int)" | grep -c "format-version")" "1"
# a Puffin path outside the table root is stopped by the path boundary
check "a Puffin path outside the table location is refused (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/dvescape.metadata.json')
	                AS t(id bigint, region text, amount int)")" "22023"
check "backend still up after the DV refusals" "$(q 'SELECT 1')" "1"

pgc_summary
