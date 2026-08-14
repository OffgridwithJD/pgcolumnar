#!/usr/bin/env bash
#
# pgColumnar Avro manifest decoder (#388 step 1). Decodes a real Apache Iceberg
# manifest -- one produced by pyiceberg, an independent writer, committed under
# test/fixtures/iceberg/ with an oracle in expected.json -- and asserts the
# decoded data-file entries against that oracle. This is the same shape as the
# pyarrow cross-check in the Parquet suites: an independent writer is the oracle,
# so a green check proves the C decoder and a real Iceberg writer agree, not that
# the decoder agrees with our own encoder.
#
# Usage:  test/avro_manifest.sh [PG_CONFIG]

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
[ -f "$FX/manifest-0.avro" ] || pgc_skip fixture "iceberg manifest fixtures are missing"
python3 -c 'import json' 2>/dev/null || pgc_skip python "python3 is needed to read the oracle"

# copy the fixture where the postgres backend can read it
M0="$PGC_WORKDIR/manifest-0.avro"
cp "$FX/manifest-0.avro" "$M0"
chmod 644 "$M0"

# ---- decode: entry count matches the oracle --------------------------------
EXP_N="$(python3 -c "import json;print(len(json.load(open('$FX/expected.json'))['entries']))")"
check "decoded entry count == oracle" \
	"$(q "SELECT count(*) FROM pgcolumnar.read_avro_manifest('$M0')")" "$EXP_N"

# ---- per-entry: record_count, file_size, partition, file basename ----------
# The oracle rows, rendered as "record_count|file_size|region", sorted.
ORACLE="$(python3 - "$FX/expected.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
rows = []
for e in r["entries"]:
    rows.append("%d|%d|%s" % (e["record_count"], e["file_size_in_bytes"], e["partition"]["region"]))
print("\n".join(sorted(rows)))
PY
)"
DECODED="$(q "SELECT record_count || '|' || file_size_in_bytes || '|' ||
                     split_part(partition, '=', 2)
              FROM pgcolumnar.read_avro_manifest('$M0') ORDER BY 1")"
check "decoded entries == oracle (record_count|file_size|region)" \
	"$DECODED" "$ORACLE"

# the partition is rendered name=value; confirm the field name came from the
# embedded schema, not a hardcoded label
check "partition renders the schema's field name" \
	"$(q "SELECT bool_and(partition LIKE 'region=%') FROM pgcolumnar.read_avro_manifest('$M0')")" "t"

# every entry names a real parquet data file (file_path decoded from the string)
check "every entry's file_path ends in .parquet" \
	"$(q "SELECT bool_and(file_path LIKE '%.parquet') FROM pgcolumnar.read_avro_manifest('$M0')")" "t"
check "all entries are ADDED data files (status=1, content=0)" \
	"$(q "SELECT bool_and(status = 1 AND content = 0) FROM pgcolumnar.read_avro_manifest('$M0')")" "t"

# ---- the manifest LIST (a snapshot's manifest_file entries) -----------------
# The same object-container machinery, a different embedded record. Decode the
# committed real manifest-list and assert its manifest_file entry against the
# writer's oracle (expected_list.json).
ML="$PGC_WORKDIR/manifest-list.avro"
cp "$FX/manifest-list.avro" "$ML"; chmod 644 "$ML"
LORACLE="$(python3 - "$FX/expected_list.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["manifest_files"]
r = m[0]
print("%d|%d|%d|%d|%d|%d|%d" % (r["manifest_length"], r["content"],
      r["partition_spec_id"], r["added_files_count"], r["added_rows_count"],
      r["sequence_number"], r["added_snapshot_id"]))
PY
)"
check "manifest-list entry count == oracle (1)" \
	"$(q "SELECT count(*) FROM pgcolumnar.read_manifest_list('$ML')")" "1"
check "manifest-list entry == oracle (len|content|spec|files|rows|seq|snap)" \
	"$(q "SELECT manifest_length || '|' || content || '|' || partition_spec_id || '|' ||
	             added_files_count || '|' || added_rows_count || '|' ||
	             sequence_number || '|' || added_snapshot_id
	      FROM pgcolumnar.read_manifest_list('$ML')")" "$LORACLE"
check "manifest-list points at an .avro manifest, no existing/deleted files" \
	"$(q "SELECT bool_and(manifest_path LIKE '%.avro' AND existing_files_count = 0
	                      AND deleted_files_count = 0) FROM pgcolumnar.read_manifest_list('$ML')")" "t"

# ---- privilege: needs pg_read_server_files ---------------------------------
psql_run "DROP ROLE IF EXISTS avro_unpriv; CREATE ROLE avro_unpriv LOGIN;"
check "an unprivileged role is refused (42501)" \
	"$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U avro_unpriv -d "$PGC_DB" \
		-qtA 2>&1 <<SQL | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
SELECT count(*) FROM pgcolumnar.read_avro_manifest('$M0');
SQL
)" "42501"

# ---- a non-Avro file is refused cleanly, not crashed -----------------------
printf 'this is not avro at all, not even close, just some bytes' > "$PGC_WORKDIR/notavro.bin"
chmod 644 "$PGC_WORKDIR/notavro.bin"
check "a non-Avro file is rejected (bad magic), backend survives" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.read_avro_manifest('$PGC_WORKDIR/notavro.bin')")" "XX001"
check "backend still up after the bad file" "$(q 'SELECT 1')" "1"

# the file_format decodes to the bare Iceberg enum name (matches the normalized
# oracle, not pyiceberg's Python repr)
check "file_format decodes to the Iceberg enum name" \
	"$(q "SELECT bool_and(file_format = 'PARQUET') FROM pgcolumnar.read_avro_manifest('$M0')")" "t"

# ---- deflate zip-bomb: a crafted manifest must not OOM the backend ----------
# #633 review: count=0 blocks decode no entries yet still inflate, so they bypass
# the per-entry cap; without the per-block free + cumulative decompressed cap a
# small file inflates to hundreds of GB. Craft a minimal valid OCF whose deflate
# blocks inflate past the 1 GB cumulative cap, and assert it is refused
# (program_limit_exceeded, 54000), not OOMed. Each block's buffer is freed as it
# goes, so peak memory stays one block.
python3 - "$PGC_WORKDIR/bomb.avro" <<'PY'
import sys, zlib
def varint(u):
    out = bytearray()
    while True:
        b = u & 0x7f; u >>= 7
        out.append(b | 0x80 if u else b)
        if not u: break
    return bytes(out)
def zz(n): return varint(((n << 1) ^ (n >> 63)) & 0xFFFFFFFFFFFFFFFF)
sync = b'\x00' * 16
schema = b'{"type":"record","name":"x","fields":[]}'
meta = zz(2)
for k, v in ((b'avro.schema', schema), (b'avro.codec', b'deflate')):
    meta += zz(len(k)) + k + zz(len(v)) + v
meta += zz(0)
out = b'Obj\x01' + meta + sync
co = zlib.compressobj(9, zlib.DEFLATED, -15)          # raw deflate
raw = co.compress(b'\x00' * (128 * 1024 * 1024)) + co.flush()
for _ in range(9):                                    # 9 x 128 MiB > 1 GiB cap
    out += zz(0) + zz(len(raw)) + raw + sync
open(sys.argv[1], 'wb').write(out)
PY
chmod 644 "$PGC_WORKDIR/bomb.avro"
check "a deflate zip-bomb is refused by the cumulative cap (54000)" \
	"$(sqlstate_of "SET statement_timeout='60s'; SELECT count(*) FROM pgcolumnar.read_avro_manifest('$PGC_WORKDIR/bomb.avro')")" "54000"
check "backend still up after the zip-bomb" "$(q 'SELECT 1')" "1"

pgc_summary
