#!/usr/bin/env bash
#
# pgColumnar Iceberg data-file resolver (#388 phase 3b). Chains a real Apache
# Iceberg table (written by pyiceberg, committed under
# test/fixtures/iceberg/warehouse/) from its metadata.json through the manifest
# list and manifests to the live data files at the current snapshot, and asserts
# them against pyiceberg's own view (expected_files.json). The warehouse is
# committed at a fixed recorded root and copied elsewhere at test time, so the
# path rebasing (recorded location -> actual location) is exercised for real.
#
# Usage:  test/iceberg_data_files.sh [PG_CONFIG]

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
WH="$FX/warehouse"
[ -d "$WH/db/events/metadata" ] || pgc_skip fixture "iceberg warehouse fixture is missing"
python3 -c 'import json, zlib' 2>/dev/null || pgc_skip python "python3 (json, zlib) is needed"

# copy the committed warehouse somewhere else, so the recorded root baked into
# the fixture differs from where it now sits: that difference is the rebasing.
DEST="$PGC_WORKDIR/relocated"
rm -rf "$DEST"; mkdir -p "$DEST"
cp -r "$WH/db" "$DEST/db"
chmod -R u+rwX "$DEST"
MD="$(ls "$DEST"/db/events/metadata/*.metadata.json | sort | tail -1)"

# ---- data files match pyiceberg's oracle -----------------------------------
# oracle rows "record_count|region|basename", sorted
ORACLE="$(python3 - "$FX/warehouse/expected_files.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
rows = ["%d|%s|%s" % (r["record_count"], r["region"], r["file_basename"])
        for r in o["data_files"]]
print("\n".join(sorted(rows)))
PY
)"
DECODED="$(q "SELECT record_count || '|' || split_part(partition,'=',2) || '|' ||
                     (regexp_match(file_path,'[^/]+\$'))[1]
              FROM pgcolumnar.iceberg_data_files('$MD') ORDER BY 1")"
check "data files == pyiceberg oracle (record_count|region|basename)" \
	"$DECODED" "$ORACLE"

check "every data file is PARQUET" \
	"$(q "SELECT bool_and(file_format='PARQUET') FROM pgcolumnar.iceberg_data_files('$MD')")" "t"

# ---- rebasing proof: paths point at the ACTUAL location, not the recorded --
# the fixture's recorded root is /tmp/pgc_ice_wh; the resolver must return paths
# under $DEST, never the recorded root.
check "returned paths are rebased under the actual location" \
	"$(q "SELECT bool_and(file_path LIKE '$DEST/%') FROM pgcolumnar.iceberg_data_files('$MD')")" "t"
check "no returned path leaks the recorded root" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_data_files('$MD')
	      WHERE file_path LIKE '/tmp/pgc_ice_wh/%'")" "0"

# ---- a path outside the table location is refused, not read ----------------
# point a copied metadata.json's manifest-list at an absolute path outside the
# recorded location; the resolver must refuse rather than open it.
ESC="$PGC_WORKDIR/escape.metadata.json"
python3 - "$MD" "$ESC" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
s = m["snapshots"][-1]
s["manifest-list"] = "file:///etc/passwd"      # outside the table location
json.dump(m, open(sys.argv[2], "w"))
PY
chmod 644 "$ESC"
check "a manifest-list outside the table location is refused (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_data_files('$ESC')")" "22023"

# ---- deletes are refused, not ignored --------------------------------------
# pyiceberg 0.11.1 cannot write merge-on-read deletes, so craft the deny input:
# a table whose current snapshot's manifest-list carries a delete manifest
# (manifest_file.content = 1). The resolver must refuse (0A000) on seeing it,
# without opening the delete manifest.
DT="$PGC_WORKDIR/deltbl/db/t"
mkdir -p "$DT/metadata"
python3 - "$DT" <<'PY'
import json, sys, zlib, os
DT = sys.argv[1]
def varint(u):
    out = bytearray()
    while True:
        b = u & 0x7f; u >>= 7
        out.append(b | 0x80 if u else b)
        if not u: break
    return bytes(out)
def zz(n): return varint((n << 1) ^ (n >> 63) & 0xFFFFFFFFFFFFFFFF) if n < 0 else varint(n << 1)
def s(bs): return zz(len(bs)) + bs
# a reduced manifest_file schema carrying exactly the fields the reader projects,
# with content declared so a delete manifest (content=1) is expressible.
schema = json.dumps({"type":"record","name":"manifest_file","fields":[
    {"name":"manifest_path","type":"string"},
    {"name":"manifest_length","type":"long"},
    {"name":"partition_spec_id","type":"int"},
    {"name":"content","type":"int"},
    {"name":"sequence_number","type":"long"},
    {"name":"min_sequence_number","type":"long"},
    {"name":"added_snapshot_id","type":"long"},
    {"name":"added_files_count","type":"int"},
    {"name":"existing_files_count","type":"int"},
    {"name":"deleted_files_count","type":"int"},
    {"name":"added_rows_count","type":"long"},
    {"name":"existing_rows_count","type":"long"},
    {"name":"deleted_rows_count","type":"long"}]}).encode()
# one manifest_file record: content = 1 (a delete manifest)
rec  = s(b"file:///tmp/pgc_ice_wh/db/t/metadata/delete-m0.avro")  # manifest_path
rec += zz(100)          # manifest_length
rec += zz(0)            # partition_spec_id
rec += zz(1)            # content = 1  <-- the delete manifest
rec += zz(1) + zz(1)    # sequence_number, min_sequence_number
rec += zz(1)            # added_snapshot_id
rec += zz(1) + zz(0) + zz(0)   # added/existing/deleted files_count
rec += zz(1) + zz(0) + zz(0)   # added/existing/deleted rows_count
sync = b"\x00" * 16
meta = zz(2) + s(b"avro.schema") + s(schema) + s(b"avro.codec") + s(b"null") + zz(0)
ocf  = b"Obj\x01" + meta + sync
ocf += zz(1) + zz(len(rec)) + rec + sync        # one block, null codec
open(os.path.join(DT, "metadata", "delete-list.avro"), "wb").write(ocf)
# a metadata.json whose current snapshot points at that crafted delete-list
md = {
    "format-version": 2,
    "location": "file:///tmp/pgc_ice_wh/db/t",
    "current-snapshot-id": 1,
    "snapshots": [{
        "snapshot-id": 1, "sequence-number": 1, "timestamp-ms": 0,
        "manifest-list": "file:///tmp/pgc_ice_wh/db/t/metadata/delete-list.avro",
        "summary": {"operation": "overwrite"}, "schema-id": 0}],
}
open(os.path.join(DT, "metadata", "v1.metadata.json"), "w").write(json.dumps(md))
PY
check "a snapshot with a delete manifest is refused (feature_not_supported 0A000)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_data_files('$DT/metadata/v1.metadata.json')")" "0A000"
check "backend still up after the delete refusal" "$(q 'SELECT 1')" "1"

# ---- no current snapshot: zero rows ----------------------------------------
NOSNAP="$PGC_WORKDIR/no_current.metadata.json"
python3 - "$MD" "$NOSNAP" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m.pop("current-snapshot-id", None)
json.dump(m, open(sys.argv[2], "w"))
PY
chmod 644 "$NOSNAP"
check "a table with no current snapshot yields no data files" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_data_files('$NOSNAP')")" "0"

# ---- privilege: needs pg_read_server_files ---------------------------------
psql_run "DROP ROLE IF EXISTS icedf_unpriv; CREATE ROLE icedf_unpriv LOGIN;"
check "an unprivileged role is refused (42501)" \
	"$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U icedf_unpriv -d "$PGC_DB" \
		-qtA 2>&1 <<SQL | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
SELECT count(*) FROM pgcolumnar.iceberg_data_files('$MD');
SQL
)" "42501"

pgc_summary
