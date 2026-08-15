#!/usr/bin/env bash
#
# pgColumnar Iceberg name mapping (#388). An Iceberg data file written outside
# Iceberg (a migrated dataset, an "imported data file") carries no Parquet field
# ids. iceberg_scan reads it by binding its columns by name through the table's
# schema.name-mapping.default property. The fixture is hand-crafted
# (test/fixtures/iceberg/warehouse_nm, gen_name_mapping_fixture.py): a real
# id-less pyarrow data file plus hand-encoded manifests and metadata carrying
# the mapping. The hand-derived oracle (all five rows) is cross-checked against
# pyiceberg and DuckDB by crosscheck_nm.py.
#
# Usage:  test/iceberg_name_mapping.sh [PG_CONFIG]

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

errmsg_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  //p' | head -1
$1;
SQLEOF
}

# the full error text (message + detail + hint), for a cause carried in a HINT
fullerr_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | tr '\n' ' '
$1;
SQLEOF
}

FX="$(dirname "${BASH_SOURCE[0]}")/fixtures/iceberg"
WHN="$FX/warehouse_nm"
[ -f "$WHN/db/t/metadata/nmapply.metadata.json" ] || pgc_skip fixture "name-mapping fixtures are missing"
python3 -c 'import json' 2>/dev/null || pgc_skip python "python3 is needed"

# relocate so the recorded root (/tmp/pgc_ice_nm) != actual root (rebasing)
DEST="$PGC_WORKDIR/nm"
rm -rf "$DEST"; mkdir -p "$DEST"
cp -r "$WHN/db" "$DEST/db"
chmod -R u+rwX "$DEST"
MDIR="$DEST/db/t/metadata"

# premise: the data file carries NO field ids (the whole point of name mapping)
check "premise: the data file carries no field ids" \
	"$(q "SELECT count(*) FROM pgcolumnar.parquet_schema('$DEST/db/t/data/data.parquet')
	      WHERE field_id IS NOT NULL")" "0"

# ---- name mapping binds an id-less file -------------------------------------
check "an id-less data file reads by name mapping (all 5 rows)" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDIR/nmapply.metadata.json')
	      AS t(id bigint, region text, amount int)")" "5"
check "the mapped values are correct" \
	"$(q "SELECT id || '|' || region || '|' || amount
	      FROM pgcolumnar.iceberg_scan('$MDIR/nmapply.metadata.json')
	        AS t(id bigint, region text, amount int) ORDER BY id LIMIT 1")" "1|eu|10"
# the mapping supplies the id->file-column binding; the schema field name may
# differ from the file's column name (a rename after the file was written).
# Output name -> schema id -> mapping name -> file column must all chain.
check "a renamed schema column still reads via the mapping name" \
	"$(q "SELECT string_agg(ident::text, ',' ORDER BY ident)
	      FROM pgcolumnar.iceberg_scan('$MDIR/nmrename.metadata.json')
	        AS t(ident bigint, region text, amount int)")" "1,2,3,4,5"
# id 1 has two mapping names; the file uses the second ("rid")
check "an alias name in the mapping resolves the file column" \
	"$(q "SELECT count(*) FROM pgcolumnar.iceberg_scan('$MDIR/nmalias.metadata.json')
	      AS t(id bigint, region text, amount int) WHERE id IN (1,2,3,4,5)")" "5"
# projecting a subset still binds each requested column by name
check "name mapping applies under column projection (id, amount)" \
	"$(q "SELECT string_agg(amount::text, ',' ORDER BY amount)
	      FROM pgcolumnar.iceberg_scan('$MDIR/nmsubset.metadata.json') AS t(id bigint, amount int)")" \
	"10,20,30,40,50"
check "backend still up after the name-mapping reads" "$(q 'SELECT 1')" "1"

# ---- refusal arms -----------------------------------------------------------
# an id-less file with NO name mapping is refused (there is no spec-defined
# positional fallback), and the message must name the property so the operator
# knows the fix
check "an id-less file with no name mapping is refused (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/nmnomap.metadata.json')
	                AS t(id bigint, region text, amount int)")" "22023"
check "...and the refusal names schema.name-mapping.default" \
	"$(fullerr_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/nmnomap.metadata.json')
	              AS t(id bigint, region text, amount int)" | grep -c "schema.name-mapping.default")" "1"
# a mapping that lists one name under two field ids violates uniqueness
check "a duplicate name in the mapping is refused (XX001)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/nmdup.metadata.json')
	                AS t(id bigint, region text, amount int)")" "XX001"
# the mapping lacks a name for a projected column: that column has no binding
check "a projected column absent from the mapping is refused (22023)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.iceberg_scan('$MDIR/nmmissing.metadata.json')
	                AS t(id bigint, region text, amount int)")" "22023"
check "backend still up after the name-mapping refusals" "$(q 'SELECT 1')" "1"

pgc_summary
