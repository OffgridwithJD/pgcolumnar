#!/usr/bin/env bash
#
# pgColumnar Iceberg foreign-data wrapper: identity-partition pruning (#388).
# iceberg_scan is a bare SRF that receives no predicate; the FDW gives Iceberg a
# predicate-bearing scan node and prunes whole data files whose identity-
# partition value cannot match a qual, reading the file's partition value out of
# the manifest (already decoded and typed) before opening it. Pruning is only an
# optimization: the proof is that pruned reads return the SAME rows as
# iceberg_scan of the same table with the same predicate, and EXPLAIN shows the
# files were pruned. A predicate on a non-partition column prunes nothing yet
# still returns correct rows.
#
# The committed warehouse/db/events is identity-partitioned by region (eu: 2
# rows, us: 3 rows).
#
# Usage:  test/iceberg_fdw.sh [PG_CONFIG]

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

python3 -c 'import json' 2>/dev/null || pgc_skip python "python3 is needed"
FX="$(dirname "${BASH_SOURCE[0]}")/fixtures/iceberg"
WH="$FX/warehouse"
[ -f "$(ls "$WH"/db/events/data/*/*.parquet 2>/dev/null | head -1)" ] \
	|| pgc_skip fixture "iceberg warehouse data files are missing"

DEST="$PGC_WORKDIR/wh"
rm -rf "$DEST"; mkdir -p "$DEST"
cp -r "$WH/db" "$DEST/db"
chmod -R u+rwX "$DEST"
MD="$(ls "$DEST"/db/events/metadata/*.metadata.json | sort | tail -1)"

q "CREATE SERVER ice FOREIGN DATA WRAPPER pgcolumnar_iceberg" >/dev/null
q "CREATE FOREIGN TABLE ev (id bigint, region text, amount int)
   SERVER ice OPTIONS (metadata_path '$MD')" >/dev/null

# number of "Files Pruned" reported by EXPLAIN ANALYZE for a query
fp() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) $1" 2>/dev/null \
		| grep -oE 'Files Pruned: [0-9]+' | grep -oE '[0-9]+' | head -1
}

# ---- premise: the foreign table reads the whole table like iceberg_scan ------
check "the FDW reads the whole table (5 rows, no predicate)" \
	"$(q "SELECT id||'|'||region||'|'||amount FROM ev ORDER BY id")" \
	"$(printf '1|eu|10\n2|eu|20\n3|us|30\n4|us|40\n5|us|50')"
check "no predicate prunes no files" "$(fp "SELECT * FROM ev")" "0"

# ---- SAME ORACLE: a partition predicate returns iceberg_scan's rows ----------
FDW_EU="$(q "SELECT id||'|'||region||'|'||amount FROM ev WHERE region='eu' ORDER BY id")"
SCAN_EU="$(q "SELECT id||'|'||region||'|'||amount
              FROM pgcolumnar.iceberg_scan('$MD') AS t(id bigint, region text, amount int)
              WHERE region='eu' ORDER BY id")"
check "region='eu' returns the eu rows" "$FDW_EU" "$(printf '1|eu|10\n2|eu|20')"
check_text "the FDW matches iceberg_scan under the same predicate (same oracle)" \
	"$FDW_EU" "$SCAN_EU"

# ---- and it PRUNED the us file (EXPLAIN, both arms) --------------------------
check "region='eu' prunes the us file (Files Pruned: 1)" \
	"$(fp "SELECT * FROM ev WHERE region='eu'")" "1"
check "region='us' prunes the eu file (Files Pruned: 1)" \
	"$(fp "SELECT * FROM ev WHERE region='us'")" "1"
check "region='us' returns the three us rows" \
	"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM ev WHERE region='us'")" \
	"3,4,5"

# ---- a value in no partition prunes everything, returns nothing --------------
check "region='zz' prunes both files (Files Pruned: 2)" \
	"$(fp "SELECT * FROM ev WHERE region='zz'")" "2"
check "region='zz' returns no rows" \
	"$(q "SELECT count(*) FROM ev WHERE region='zz'")" "0"

# ---- metrics pruning: a NON-partition int column prunes by file min/max ------
# amount bounds: region=eu file [10,20], region=us file [30,50].
check "amount > 25 prunes the eu file by metrics (Files Pruned: 1)" \
	"$(fp "SELECT * FROM ev WHERE amount > 25")" "1"
check "amount > 25 still returns the right rows" \
	"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM ev WHERE amount > 25")" \
	"3,4,5"
check "amount < 15 prunes the us file by metrics (Files Pruned: 1)" \
	"$(fp "SELECT * FROM ev WHERE amount < 15")" "1"
check "amount < 15 returns only id 1" \
	"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM ev WHERE amount < 15")" "1"
check "amount = 30 prunes the eu file, keeps us (Files Pruned: 1)" \
	"$(fp "SELECT * FROM ev WHERE amount = 30")" "1"
check "amount = 30 returns id 3" \
	"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM ev WHERE amount = 30")" "3"
check "amount = 100 prunes both files by metrics (Files Pruned: 2)" \
	"$(fp "SELECT * FROM ev WHERE amount = 100")" "2"
check "amount = 100 returns no rows" \
	"$(q "SELECT count(*) FROM ev WHERE amount = 100")" "0"
check_text "a metrics-pruned query matches iceberg_scan (same oracle)" \
	"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM ev WHERE amount >= 30")" \
	"$(q "SELECT string_agg(id::text, ',' ORDER BY id)
	      FROM pgcolumnar.iceberg_scan('$MD') AS t(id bigint, region text, amount int)
	      WHERE amount >= 30")"

# ---- a DATE identity partition must NOT over-prune (the #660 bug) ------------
# the FDW cannot convert a date partition cell, so it must read the file in full
# and let the recheck qual filter -- never NULL-fill and prune, which would drop
# rows. dt=2020-01-01 -> ids 1,2 ; dt=2020-02-01 -> ids 3,4.
if [ -f "$FX/warehouse_datepart/db/byday/metadata/00001-08bb95d5-d5eb-442f-b2f4-11b44457c66a.metadata.json" ]; then
	DDEST="$PGC_WORKDIR/whd"; rm -rf "$DDEST"; mkdir -p "$DDEST"
	cp -r "$FX/warehouse_datepart/db" "$DDEST/db"; chmod -R u+rwX "$DDEST"
	MDD="$(ls "$DDEST"/db/byday/metadata/*.metadata.json | sort | tail -1)"
	q "CREATE FOREIGN TABLE evd (id bigint, dt date, amount int)
	   SERVER ice OPTIONS (metadata_path '$MDD')" >/dev/null
	check "a date-partitioned FDW reads the whole table (4 rows)" \
		"$(q "SELECT count(*) FROM evd")" "4"
	check "dt='2020-01-01' returns its rows, not over-pruned to zero" \
		"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM evd WHERE dt=DATE '2020-01-01'")" \
		"1,2"
	check_text "the date FDW matches iceberg_scan under the same predicate" \
		"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM evd WHERE dt=DATE '2020-01-01'")" \
		"$(q "SELECT string_agg(id::text, ',' ORDER BY id)
		      FROM pgcolumnar.iceberg_scan('$MDD') AS t(id bigint, dt date, amount int)
		      WHERE dt=DATE '2020-01-01'")"
	check "a date partition prunes nothing in this release (Files Pruned: 0)" \
		"$(fp "SELECT * FROM evd WHERE dt=DATE '2020-01-01'")" "0"
fi

# ---- bucket[N] partition pruning (murmur3 cross-checked vs pyiceberg) --------
# warehouse_bucket is partitioned by bucket[8](id); pyiceberg wrote the buckets
# (1->4, 4->6, 3->3), so a green same-oracle read proves the C murmur3/bucket
# agrees with Iceberg. 5 files (buckets 1,3,4,6,7); WHERE id=k keeps one.
if [ -f "$FX/warehouse_bucket/db/byid/data/id_bucket=4/00000-0-aa63bd5e-94cd-4a44-a529-fde21cc16eab.parquet" ]; then
	BDEST="$PGC_WORKDIR/whb"; rm -rf "$BDEST"; mkdir -p "$BDEST"
	cp -r "$FX/warehouse_bucket/db" "$BDEST/db"; chmod -R u+rwX "$BDEST"
	MDB="$(ls "$BDEST"/db/byid/metadata/*.metadata.json | sort | tail -1)"
	q "CREATE FOREIGN TABLE evb (id bigint, val text, amount int)
	   SERVER ice OPTIONS (metadata_path '$MDB')" >/dev/null
	check "the bucket FDW reads the whole table (8 rows)" \
		"$(q "SELECT count(*) FROM evb")" "8"
	check "id = 1 keeps only its bucket file (Files Pruned: 4)" \
		"$(fp "SELECT * FROM evb WHERE id = 1")" "4"
	check "id = 1 returns row 1" \
		"$(q "SELECT string_agg(id::text||'|'||val, ',' ORDER BY id) FROM evb WHERE id = 1")" \
		"1|v1"
	check "id = 4 keeps only its bucket file (Files Pruned: 4)" \
		"$(fp "SELECT * FROM evb WHERE id = 4")" "4"
	check "id = 4 returns row 4" \
		"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM evb WHERE id = 4")" "4"
	check_text "a bucket-pruned equality matches iceberg_scan (murmur3 oracle)" \
		"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM evb WHERE id = 3")" \
		"$(q "SELECT string_agg(id::text, ',' ORDER BY id)
		      FROM pgcolumnar.iceberg_scan('$MDB') AS t(id bigint, val text, amount int)
		      WHERE id = 3")"
	check "id = 3 returns row 3" \
		"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM evb WHERE id = 3")" "3"
	# id=5 (bucket 7): metrics alone keeps bucket-3 [3,7] AND bucket-7 (prunes 3),
	# but bucket pruning drops bucket-3 too (prunes 4). This distinguishes bucket
	# pruning from metrics, so it is the removal-proof target.
	check "id = 5 bucket-prunes past metrics (Files Pruned: 4)" \
		"$(fp "SELECT * FROM evb WHERE id = 5")" "4"
	check "id = 5 returns row 5" \
		"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM evb WHERE id = 5")" "5"
	# a RANGE predicate cannot bucket-prune (the hash destroys order); metrics
	# pruning still applies to id's own min/max, so 2 all-<=4 bucket files drop.
	check "id > 4 prunes by metrics not bucket, correctly (Files Pruned: 2)" \
		"$(fp "SELECT * FROM evb WHERE id > 4")" "2"
	check "id > 4 still returns the right rows" \
		"$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM evb WHERE id > 4")" \
		"5,6,7,8"
fi

# ---- an invalid option is rejected by the validator -------------------------
check "an unknown table option is refused (FDW_INVALID_OPTION_NAME)" \
	"$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
CREATE FOREIGN TABLE bad (id bigint) SERVER ice OPTIONS (nosuch 'x');
SQLEOF
)" "HV00D"

pgc_summary
