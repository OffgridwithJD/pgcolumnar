#!/usr/bin/env bash
#
# pgColumnar Hive-style partition pruning for the Parquet FDW (Phase G).
#
# A layout like events/dt=2026-01-02/region=eu/part.parquet carries column values
# in its directory names. The columns are DECLARED through the partition_columns
# table option, not inferred from the tree: inference would mean guessing which
# path components are partitions, and a wrong guess silently changes which rows a
# query returns.
#
# This suite checks that the values materialize, that a predicate on a partition
# column drops whole files before they are opened (asserted through the EXPLAIN
# counter, not timing), that partition and file predicates combine, and that a
# tree which does not match the declaration fails loudly.
#
# Usage:  test/native_parquet_partition.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

if ! python3 -c 'import pyarrow.parquet' 2>/dev/null; then
	echo "SKIP  pyarrow not available; partition suite needs it"
	pgc_summary
	exit 0
fi

W="$PGC_WORKDIR"
ROOT="$W/events"

# Four leaf files across two partition columns: dt (date) and region (text).
# Each file's ids are disjoint so a row count identifies which files were read.
python3 - "$ROOT" <<'PY'
import os, sys
import pyarrow as pa, pyarrow.parquet as pq
ROOT = sys.argv[1]
plan = [("2026-01-01", "eu", 0), ("2026-01-01", "us", 1000),
        ("2026-01-02", "eu", 2000), ("2026-01-02", "us", 3000)]
for dt, region, base in plan:
    d = os.path.join(ROOT, f"dt={dt}", f"region={region}")
    os.makedirs(d, exist_ok=True)
    t = pa.table({"id": pa.array(range(base, base + 1000), pa.int32()),
                  "v":  pa.array([f"r{i}" for i in range(base, base + 1000)])})
    pq.write_table(t, os.path.join(d, "part.parquet"), compression="none",
                   row_group_size=250)
PY

psql_run "CREATE SERVER pq FOREIGN DATA WRAPPER pgcolumnar_parquet;"
psql_run "CREATE FOREIGN TABLE ev (id int, v text, dt date, region text)
          SERVER pq OPTIONS (path '$ROOT', partition_columns 'dt,region');"

files_for() {  # files_for WHERE -> files actually read
	q "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
	   SELECT count(*) FROM ev WHERE $1" \
		| grep -E '^\s*Files:' | grep -oE '[0-9]+' | head -1
}
pruned_for() {  # pruned_for WHERE -> files dropped before opening
	local out
	out="$(q "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
	          SELECT count(*) FROM ev WHERE $1" \
		| grep 'Files Pruned' | grep -oE '[0-9]+' | head -1)"
	[ -z "$out" ] && out=0
	echo "$out"
}
errs() {
	local out
	out="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" \
		-U postgres -d "$PGC_DB" -At -c "$1" 2>&1)"
	case "$out" in
		*ERROR*) echo OK ;;
		*) echo "NO ERROR" ;;
	esac
}

# ---- the values are real columns -------------------------------------------
check "all four partitions read" "$(q 'SELECT count(*) FROM ev;')" "4000"
check "partition values materialize" \
	"$(q "SELECT dt || ' ' || region FROM ev WHERE id = 2500;")" \
	"2026-01-02 eu"
check "partition column is typed, not text" \
	"$(q "SELECT count(*) FROM ev WHERE dt = DATE '2026-01-01';")" "2000"
check "group by a partition column" \
	"$(q "SELECT region || '=' || count(*) FROM ev GROUP BY region ORDER BY region;" | tr '\n' ' ')" \
	"eu=2000 us=2000 "

# ---- pruning drops whole files before they are opened ----------------------
check "one partition value prunes half the files" "$(pruned_for "dt = DATE '2026-01-02'")" "2"
check "and reads the other half" "$(files_for "dt = DATE '2026-01-02'")" "2"
check "both columns prune down to one file" \
	"$(pruned_for "dt = DATE '2026-01-02' AND region = 'eu'")" "3"
check "pruned scan still returns the right rows" \
	"$(q "SELECT count(*), min(id), max(id) FROM ev
	      WHERE dt = DATE '2026-01-02' AND region = 'eu';" | tr '|' ' ')" \
	"1000 2000 2999"
check "an inequality on a partition column prunes" \
	"$(pruned_for "dt > DATE '2026-01-01'")" "2"
check "IN on a partition column prunes" \
	"$(pruned_for "region IN ('eu')")" "2"
check "a predicate matching everything prunes nothing" \
	"$(pruned_for "dt >= DATE '2026-01-01'")" "0"
check "a predicate on a file column prunes no files" "$(pruned_for 'id < 10')" "0"

# The point of pruning is that the file is never opened, so its row groups must
# not appear in the row-group counter either.
groups_all="$(q "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM ev" \
	| grep -E '^\s*Row Groups:' | grep -oE '[0-9]+' | head -1)"
groups_one="$(q "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
                 SELECT count(*) FROM ev WHERE dt = DATE '2026-01-02' AND region = 'eu'" \
	| grep -E '^\s*Row Groups:' | grep -oE '[0-9]+' | head -1)"
check "a pruned file's row groups are never counted" "$groups_all $groups_one" "16 4"

# ---- partition and file predicates combine ---------------------------------
check "partition prune plus row-group skip" \
	"$(q "SELECT count(*) FROM ev WHERE region = 'eu' AND id BETWEEN 2100 AND 2199;")" "100"
check "row groups are still skipped inside the surviving files" \
	"$(q "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
	      SELECT count(*) FROM ev WHERE region = 'eu' AND id BETWEEN 2100 AND 2199" \
		| grep 'Row Groups Skipped' | grep -oE '[0-9]+' | head -1)" "7"

# ---- a volatile clause must not decide a whole file ------------------------
#
# Pruning evaluates a clause once per file. That is only equivalent to the
# executor's per-row evaluation when the clause is a function of the partition
# values alone, and a volatile function is not: one draw would keep or drop every
# row of the file. pull_varattnos cannot see this, since it reports Vars only.
#
# The check is deterministic rather than statistical. vol_odd() advances a
# sequence, so it is true on its first call and alternates. Files are read in
# sorted path order, and OR short-circuits, so without the guard the first
# dt=2026-01-01 file calls it and is kept, the second calls it and is pruned,
# and the two dt=2026-01-02 files never call it because dt already matched.
# Exactly one file is pruned without the guard, and none with it.
psql_run "CREATE SEQUENCE volseq;"
psql_run "CREATE FUNCTION vol_odd() RETURNS boolean LANGUAGE sql VOLATILE
          AS \$\$ SELECT nextval('volseq') % 2 = 1 \$\$;"
check "a volatile clause prunes nothing" \
	"$(pruned_for "dt = DATE '2026-01-02' OR vol_odd()")" "0"
# and the rows that must be there regardless of the volatile half still are
check "a volatile clause keeps every matching partition row" \
	"$(q "SELECT count(*) FROM ev
	      WHERE (dt = DATE '2026-01-02' OR vol_odd()) AND dt = DATE '2026-01-02';")" \
	"2000"

# A stable function stays eligible: stable is constant within a statement, which
# is the guarantee pruning needs, so this one still prunes.
check "a stable clause still prunes" \
	"$(pruned_for "dt = (DATE '2026-01-02' + 0)")" "2"

# ---- a tree that does not match the declaration fails loudly ---------------
mkdir -p "$ROOT/dt=2026-01-03"
cp "$ROOT/dt=2026-01-01/region=eu/part.parquet" "$ROOT/dt=2026-01-03/loose.parquet"
check "a file missing a declared partition component errors" \
	"$(errs 'SELECT count(*) FROM ev;')" "OK"
rm -rf "$ROOT/dt=2026-01-03"

# Only components between the root and the file are partition components, so a
# file named like one does not set a column from its own basename.
cp "$ROOT/dt=2026-01-01/region=eu/part.parquet" "$ROOT/dt=2026-01-01/region=eu/dt=1999-01-01.parquet"
check "a file whose basename looks like a partition component is unaffected" \
	"$(q "SELECT count(*) FROM ev WHERE dt = DATE '1999-01-01';")" "0"
rm -f "$ROOT/dt=2026-01-01/region=eu/dt=1999-01-01.parquet"

psql_run "CREATE FOREIGN TABLE ev_bad (id int, v text, dt date, region text)
          SERVER pq OPTIONS (path '$ROOT', partition_columns 'dt,nosuch');"
check "an unknown partition column errors rather than being ignored" \
	"$(errs 'SELECT count(*) FROM ev_bad;')" "OK"

check "an empty partition_columns option is rejected" \
	"$(errs "CREATE FOREIGN TABLE ev_empty (id int) SERVER pq
	         OPTIONS (path '$ROOT', partition_columns '');")" "OK"

# A declared partition column is not bound against the file's leaves, so the
# file's own column count still has to match what is left. Declaring a column
# that the file DOES carry as a partition column must therefore fail.
psql_run "CREATE FOREIGN TABLE ev_dup (id int, v text, dt date, region text)
          SERVER pq OPTIONS (path '$ROOT', partition_columns 'dt,region,v');"
check "declaring a file column as a partition column errors" \
	"$(errs 'SELECT count(*) FROM ev_dup;')" "OK"
check "backend survived the bad declarations" "$(q 'SELECT 1;')" "1"

# ---- Hive value encoding ---------------------------------------------------
#
# A path component cannot hold a slash, and an equals sign would be ambiguous
# against the key separator, so writers percent-encode them. Reading the value
# literally gives a different value with no error, which is why this is part of
# reading a partition rather than a nicety. __HIVE_DEFAULT_PARTITION__ is the
# marker Hive and Spark write when the partition value is null.
ENC="$W/enc"
python3 - "$ENC" <<'PYENC'
import os, sys
import pyarrow as pa, pyarrow.parquet as pq
ENC = sys.argv[1]
# region=a=b percent-encoded, and a null partition marker
plan = [("a%3Db", 0), ("__HIVE_DEFAULT_PARTITION__", 1000), ("plain", 2000)]
for region, base in plan:
    d = os.path.join(ENC, "region=" + region)
    os.makedirs(d, exist_ok=True)
    pq.write_table(pa.table({"id": pa.array(range(base, base + 100), pa.int32())}),
                   os.path.join(d, "part.parquet"), compression="none")
PYENC

psql_run "CREATE FOREIGN TABLE ev_enc (id int, region text)
          SERVER pq OPTIONS (path '$ENC', partition_columns 'region');"

check "a percent-encoded partition value decodes" \
	"$(q "SELECT DISTINCT region FROM ev_enc WHERE id < 100;")" "a=b"
check "the encoded value is queryable as itself" \
	"$(q "SELECT count(*) FROM ev_enc WHERE region = 'a=b';")" "100"
check "__HIVE_DEFAULT_PARTITION__ reads as null" \
	"$(q "SELECT count(*) FROM ev_enc WHERE region IS NULL;")" "100"
check "a null partition value is not the literal marker" \
	"$(q "SELECT count(*) FROM ev_enc WHERE region = '__HIVE_DEFAULT_PARTITION__';")" "0"
check "an unencoded value is unaffected" \
	"$(q "SELECT count(*) FROM ev_enc WHERE region = 'plain';")" "100"
check "all three partitions still read" "$(q 'SELECT count(*) FROM ev_enc;')" "300"

# A null partition value prunes like any other: IS NOT NULL excludes exactly the
# file whose directory carries the marker.
check "a null partition value prunes" \
	"$(q "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
	      SELECT count(*) FROM ev_enc WHERE region IS NOT NULL" \
		| grep 'Files Pruned' | grep -oE '[0-9]+' | head -1)" "1"

# Percent-encoding can carry any byte, and the value becomes a PostgreSQL text
# datum, so two byte sequences have to be refused rather than passed through.
# A NUL would truncate the value silently (everything downstream is a C string),
# and a byte invalid in the server encoding would admit invalid text, which
# textin does not check. Both are what a path written by another tool can contain.
mkdir -p "$ENC/region=a%00b" "$ENC/region=a%FFb"
cp "$ENC/region=plain/part.parquet" "$ENC/region=a%00b/part.parquet"
cp "$ENC/region=plain/part.parquet" "$ENC/region=a%FFb/part.parquet"
# The NUL case is caught by the encoding validation as well as by the explicit
# check, so this asserts the pair rather than either one; removing the explicit
# check leaves it passing, which was verified rather than assumed.
check "an encoded null byte in a partition value is rejected" \
	"$(errs 'SELECT count(*) FROM ev_enc;')" "OK"
rm -rf "$ENC/region=a%00b"
check "a byte invalid in the server encoding is rejected" \
	"$(errs 'SELECT count(*) FROM ev_enc;')" "OK"
rm -rf "$ENC/region=a%FFb"
check "the tree reads again once both are gone" "$(q 'SELECT count(*) FROM ev_enc;')" "300"
check "backend survived the malformed partition values" "$(q 'SELECT 1;')" "1"

pgc_summary
