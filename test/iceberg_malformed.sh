#!/usr/bin/env bash
#
# pgColumnar Iceberg read-path robustness (#388 phase 4a, #644). The Iceberg
# reader takes an untrusted metadata.json / manifest / manifest list written by
# whoever authored the table, and is called by an honest pg_read_server_files
# role that named only the trusted metadata pointer. A crafted manifest must be
# REFUSED cleanly, never crash the backend. Each arm has a control so a vacuous
# pass is visible, and a "backend still up" probe after every refusal proves the
# refusal was an error, not a segfault. Fixtures are hand-crafted
# (test/fixtures/iceberg/warehouse_malformed) because no writer emits these
# shapes; see gen_malformed_fixture.py.
#
# Usage:  test/iceberg_malformed.sh [PG_CONFIG]

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

# Run one statement under a HARD wall-clock cap. A cancel-resistant open (a FIFO)
# cannot be ended by statement_timeout, so the external `timeout` is the only
# reliable detector. Prints the 5-char SQLSTATE the backend raised, or the
# literal HANG when psql was KILLed by the cap (exit 124/137). No SQL-level
# statement_timeout is set, so a merely-slow legit path is never a false HANG.
FIFO_CAP=5
sqlstate_or_hang() {
	local out rc
	out="$(timeout -s KILL "$FIFO_CAP" env PATH="$PGC_BINDIR:$PATH" psql \
		-h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -qtA 2>&1 <<SQLEOF
\\set VERBOSITY sqlstate
$1;
SQLEOF
)"
	rc=$?
	if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then echo HANG; return; fi
	printf '%s\n' "$out" | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
}

# Release a backend that is blocked in open(2) on a FIFO (main only): opening the
# write end lets its open return; it then hits EOF/short-read and errors out, so
# cluster teardown is clean. No-op after the fix (nothing is ever blocked).
fifo_release() { exec 9<>"$1" 2>/dev/null; exec 9>&- 2>/dev/null; }

FX="$(dirname "${BASH_SOURCE[0]}")/fixtures/iceberg"
WHM="$FX/warehouse_malformed"
[ -f "$WHM/nullpath/db/t/metadata/t.metadata.json" ] \
	&& [ -f "$WHM/nullseq_ml/ml.avro" ] \
	&& [ -f "$WHM/danglingschema/db/t/metadata/t.metadata.json" ] \
	|| pgc_skip fixture "malformed iceberg fixtures are missing"
python3 -c 'import json' 2>/dev/null || pgc_skip python "python3 is needed"

# relocate so the recorded root (/tmp/pgc_ice_malformed) != actual root, which
# exercises the same path rebasing the honest read path uses
DEST="$PGC_WORKDIR/malformed"
rm -rf "$DEST"; mkdir -p "$DEST"
cp -r "$WHM"/* "$DEST/"
chmod -R u+rwX "$DEST"

# =========================================================================
# #7  an Avro record schema whose "fields" element is a JSON array crashed the
#     backend (an object-container Assert / OOB heap read). It must now be a
#     clean malformed-schema error, and the control must still decode.
# =========================================================================
check "an array-valued schema \"fields\" element is refused, not crashed (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.read_avro_manifest('$DEST/arrayfield/evil.avro')")" \
	"XX001"
check "backend still up after the malformed-schema refusal" "$(q 'SELECT 1')" "1"
check "control: a well-formed field object still decodes (0 entries)" \
	"$(q "SELECT count(*) FROM pgcolumnar.read_avro_manifest('$DEST/arrayfield/good.avro')")" \
	"0"

# =========================================================================
# #2  a data_file with a NULL file_path (nullable union, null branch) crashed
#     both entry points via pstrdup(NULL) / ice_strip_scheme(NULL). It must now
#     be a clean DATA_CORRUPTED refusal; the control (file_path present) reads.
# =========================================================================
NP="$DEST/nullpath/db/t/metadata/t.metadata.json"
check "a NULL data-file path is refused in iceberg_data_files (XX001, not a crash)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_data_files('$NP')")" "XX001"
check "backend still up after the lister refusal" "$(q 'SELECT 1')" "1"
check "a NULL data-file path is refused in iceberg_scan (XX001, not a crash)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$NP') AS t(id bigint)")" "XX001"
check "backend still up after the scan refusal" "$(q 'SELECT 1')" "1"
check "control: a present file_path lists one data file" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_data_files('$DEST/nullpath_ctl/db/t/metadata/t.metadata.json')")" \
	"1"

# =========================================================================
# #1  a non-regular file (FIFO) named on any Iceberg-reachable open must be
#     refused (XX001), never block the backend cancel-resistant. RED on main is
#     HANG (psql KILLed by the cap); GREEN is XX001, well under the cap.
# =========================================================================
FIFODIR="$PGC_WORKDIR/fifo"; mkdir -p "$FIFODIR"
FIFO="$FIFODIR/x"; mkfifo "$FIFO"

# Site A -- ice_slurp_text, FIFO as the metadata argument (three entry points)
check "iceberg_current_snapshot on a FIFO is refused, not a hang (XX001)" \
	"$(sqlstate_or_hang "SELECT * FROM pgcolumnar.iceberg_current_snapshot('$FIFO')")" \
	"XX001"; fifo_release "$FIFO"
check "iceberg_data_files on a FIFO is refused, not a hang (XX001)" \
	"$(sqlstate_or_hang "SELECT * FROM pgcolumnar.iceberg_data_files('$FIFO')")" \
	"XX001"; fifo_release "$FIFO"
check "iceberg_scan on a FIFO is refused, not a hang (XX001)" \
	"$(sqlstate_or_hang "SELECT * FROM pgcolumnar.iceberg_scan('$FIFO') AS t(id bigint)")" \
	"XX001"; fifo_release "$FIFO"

# Site C -- av_slurp_file, FIFO as the argument (both entry points)
check "read_avro_manifest on a FIFO is refused, not a hang (XX001)" \
	"$(sqlstate_or_hang "SELECT * FROM pgcolumnar.read_avro_manifest('$FIFO')")" \
	"XX001"; fifo_release "$FIFO"
check "read_manifest_list on a FIFO is refused, not a hang (XX001)" \
	"$(sqlstate_or_hang "SELECT * FROM pgcolumnar.read_manifest_list('$FIFO')")" \
	"XX001"; fifo_release "$FIFO"

# Site D -- pq_source_open_cfg via the single-file parquet API (sibling)
check "read_parquet on a FIFO is refused, not a hang (XX001)" \
	"$(sqlstate_or_hang "SELECT * FROM pgcolumnar.read_parquet('$FIFO') AS t(id bigint)")" \
	"XX001"; fifo_release "$FIFO"

check "backend still up after the FIFO refusals" "$(q 'SELECT 1')" "1"

# Site B -- ice_slurp_bin, FIFO named as the manifest-list INSIDE metadata.json.
# realpath() on the FIFO succeeds and passes ice_open_path's containment, so only
# the S_ISREG guard inside ice_slurp_bin stops it.
MLROOT="$FIFODIR/tbl"; mkdir -p "$MLROOT/db/t/metadata"
MLFIFO="$MLROOT/db/t/metadata/ml.avro"; mkfifo "$MLFIFO"
MDJSON="$MLROOT/db/t/metadata/t.metadata.json"
cat > "$MDJSON" <<JSON
{"format-version":2,"location":"file://$MLROOT/db/t",
 "current-snapshot-id":4242,"current-schema-id":0,
 "schemas":[{"schema-id":0,"type":"struct","fields":[]}],
 "snapshots":[{"snapshot-id":4242,"timestamp-ms":0,"sequence-number":1,
   "schema-id":0,"manifest-list":"file://$MLROOT/db/t/metadata/ml.avro",
   "summary":{"operation":"append"}}]}
JSON
check "a manifest-list that is a FIFO is refused, not a hang (XX001)" \
	"$(sqlstate_or_hang "SELECT * FROM pgcolumnar.iceberg_data_files('$MDJSON')")" \
	"XX001"; fifo_release "$MLFIFO"
check "backend still up after the manifest-list FIFO refusal" "$(q 'SELECT 1')" "1"

# =========================================================================
# #4  a manifest_file.sequence_number that is the union's NULL branch decoded
#     silently as 0. A v2/v3 list always carries a concrete number, so a null is
#     corrupt: it understates a data file's seq and mis-applies an older delete
#     -> a dropped row. Refuse it; keep v1 (absent column) -> 0.
# =========================================================================
NSML="$DEST/nullseq_ml"
check "a null manifest-list sequence_number decodes as NULL, not 0" \
	"$(q "SELECT sequence_number IS NULL FROM pgcolumnar.read_manifest_list('$NSML/ml.avro')")" \
	"t"
check "control: a present manifest-list sequence_number decodes to its value" \
	"$(q "SELECT sequence_number FROM pgcolumnar.read_manifest_list('$NSML/ml_ctl.avro')")" \
	"5"

NS="$DEST/nullseq/db/t/metadata/t.metadata.json"
NSC="$DEST/nullseq_ctl/db/t/metadata/t.metadata.json"
check "iceberg_scan refuses a null manifest seq an ADDED entry must inherit (XX001, not a silent wrong row)" \
	"$(sqlstate_of "SELECT count(*) FROM pgcolumnar.iceberg_scan('$NS') AS t(id bigint, region text, amount int)")" \
	"XX001"
check "backend still up after the null-sequence refusal" "$(q 'SELECT 1')" "1"
check "control: a concrete manifest seq scans all 5 rows (seq-3 delete is older than seq-5 data)" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$NSC') AS t(id bigint, region text, amount int)")" \
	"5"

# =========================================================================
# #8  a dangling current-schema-id (names a schema absent from "schemas")
#     must be REFUSED as DATA_CORRUPTED, not silently resolved to the
#     deprecated top-level "schema" (which binds columns through a stale
#     schema and misprojects every row). Asymmetric with ice_current_snapshot.
# =========================================================================
DS="$DEST/danglingschema/db/t/metadata/t.metadata.json"
check "a dangling current-schema-id is refused (XX001), not silently stale-read" \
	"$(sqlstate_of "SELECT amount FROM pgcolumnar.iceberg_scan('$DS') AS t(amount int)")" \
	"XX001"
check "backend still up after the dangling-schema refusal" "$(q 'SELECT 1')" "1"
# control: the SAME data with a RESOLVABLE current-schema-id reads the correct
# column (amount = field id 3 = 10..50). Proves only the dangling id flips it.
DSC="$DEST/danglingschema_ctl/db/t/metadata/t.metadata.json"
check "control: a resolvable current-schema-id reads the correct amount column" \
	"$(q "SELECT string_agg(amount::text, ',' ORDER BY amount)
	      FROM pgcolumnar.iceberg_scan('$DSC') AS t(amount int)")" \
	"10,20,30,40,50"
# green control: a legit legacy-only table (top-level "schema", no "schemas"
# array, no current-schema-id) must STILL read -- the fix must not reject it.
LS="$DEST/legacyschema/db/t/metadata/t.metadata.json"
check "control: a legacy-only-schema table still reads (5 rows)" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$LS')
	      AS t(id bigint, region text, amount int)")" "5"
check "control: the legacy table binds amount correctly (10..50)" \
	"$(q "SELECT string_agg(amount::text, ',' ORDER BY amount)
	      FROM pgcolumnar.iceberg_scan('$LS') AS t(id bigint, region text, amount int)")" \
	"10,20,30,40,50"

pgc_summary
