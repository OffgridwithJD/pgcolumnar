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

FX="$(dirname "${BASH_SOURCE[0]}")/fixtures/iceberg"
WHM="$FX/warehouse_malformed"
[ -f "$WHM/nullpath/db/t/metadata/t.metadata.json" ] \
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

pgc_summary
