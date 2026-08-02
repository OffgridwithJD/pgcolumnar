#!/usr/bin/env bash
#
# pgColumnar parallel Parquet export suite (#300).
#
# pgcolumnar.parallel_export_parquet(target, dir, workers) fans a read-only
# export across N background workers, each writing part-NNNN.parquet into one
# directory that pgcolumnar.read_parquet reads back as a single relation. This
# suite proves parallel export == serial export == the source, for a single
# columnar table (split by row-group ranges) and a partitioned columnar table
# (one file per partition), across 1/2/4 workers; that each worker wrote its own
# file and the files partition the source; empty input; and the error cases.
#
# Oracle = pgc_set_hash, which is order-independent, so file and row ordering do
# not matter. The read-back uses pgcolumnar.read_parquet, so no pyarrow.
#
# Usage:  test/parallel_export_parquet.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# parallel_export spawns N read-only workers (no coordinator), so the cluster
# needs at least that many worker slots.
export PGC_EXTRA_CONF=$'max_worker_processes=16'

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

COLS="id int, k int, v float8, txt text"
RB="id int, k int, v float8, txt text"		# read_parquet column list

nfiles() { ls "$1"/*.parquet 2>/dev/null | wc -l | tr -d ' '; }

# run a query, echo stdout+stderr (capture-then-grep, so pipefail cannot hide it)
err_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atc "$1" 2>&1 || true
}

expect_error() {
	local label="$1" sql="$2" out
	out="$(err_of "$sql")"
	check "$label" "$(printf '%s' "$out" | grep -qi "ERROR" && echo error || echo ok)" error
}

# ---- single columnar table: split by row-group ranges -----------------------
# A small stripe_row_limit gives many row groups (80000/5000 = 16), so W up to 4
# actually splits the table and writes W distinct files.
psql_run "DROP TABLE IF EXISTS t_col;
          CREATE TABLE t_col ($COLS) USING pgcolumnar;
          SELECT pgcolumnar.set_options('t_col'::regclass, stripe_row_limit => 5000);
          INSERT INTO t_col SELECT g, g%1000, g::float8/7, 'r'||g
                            FROM generate_series(1,80000) g;" >/dev/null
SRC="$(pgc_set_hash "SELECT * FROM t_col")"
NSRC="$(q "SELECT count(*) FROM t_col")"

# serial export is a second oracle
SER="$PGC_WORKDIR/serial.parquet"
q "SELECT pgcolumnar.export_parquet('t_col'::regclass, '$SER')" >/dev/null
SER_HASH="$(pgc_set_hash "SELECT * FROM pgcolumnar.read_parquet('$SER') AS t($RB)")"
check "serial export read-back == source" "$SER_HASH" "$SRC"

for W in 1 2 4; do
	D="$PGC_WORKDIR/st_$W"
	n="$(q "SELECT pgcolumnar.parallel_export_parquet('t_col'::regclass, '$D', $W)")"
	check "single($W): rows returned == source count" "$n" "$NSRC"
	rb="$(pgc_set_hash "SELECT * FROM pgcolumnar.read_parquet('$D') AS t($RB)")"
	check "single($W): read-back == source" "$rb" "$SRC"
	check "single($W): read-back == serial export" "$rb" "$SER_HASH"
	check "single($W): wrote exactly $W files (distinct per worker)" "$(nfiles "$D")" "$W"
done

# ---- partitioned columnar table: one file per partition ---------------------
# k = g%600 -> t_p3 (750..) gets no rows, so one partition is empty.
psql_run "DROP TABLE IF EXISTS t_part CASCADE;
          CREATE TABLE t_part ($COLS) PARTITION BY RANGE (k);
          CREATE TABLE t_p0 PARTITION OF t_part FOR VALUES FROM (0) TO (250) USING pgcolumnar;
          CREATE TABLE t_p1 PARTITION OF t_part FOR VALUES FROM (250) TO (500) USING pgcolumnar;
          CREATE TABLE t_p2 PARTITION OF t_part FOR VALUES FROM (500) TO (750) USING pgcolumnar;
          CREATE TABLE t_p3 PARTITION OF t_part FOR VALUES FROM (750) TO (2000) USING pgcolumnar;
          INSERT INTO t_part SELECT g, g%600, g::float8/7, 'r'||g
                             FROM generate_series(1,80000) g;" >/dev/null
PSRC="$(pgc_set_hash "SELECT * FROM t_part")"
NPART="$(q "SELECT count(*) FROM t_part")"
for W in 1 2 4; do
	D="$PGC_WORKDIR/pt_$W"
	n="$(q "SELECT pgcolumnar.parallel_export_parquet('t_part'::regclass, '$D', $W)")"
	check "part($W): rows returned == source count" "$n" "$NPART"
	check "part($W): read-back == source" \
		"$(pgc_set_hash "SELECT * FROM pgcolumnar.read_parquet('$D') AS t($RB)")" "$PSRC"
	check "part($W): one file per partition (4, incl the empty one)" "$(nfiles "$D")" "4"
done

# ---- empty input: a valid zero-row file, read-back is the empty set ---------
psql_run "DROP TABLE IF EXISTS t_empty; CREATE TABLE t_empty ($COLS) USING pgcolumnar;" >/dev/null
DE="$PGC_WORKDIR/empty"
ne="$(q "SELECT pgcolumnar.parallel_export_parquet('t_empty'::regclass, '$DE', 2)")"
check "empty: rows returned == 0" "$ne" 0
check "empty: read-back is the empty set" \
	"$(pgc_set_hash "SELECT * FROM pgcolumnar.read_parquet('$DE') AS t($RB)")" \
	"$(pgc_set_hash "SELECT * FROM t_empty")"

# ---- consistency: export INSIDE a transaction with uncommitted rows ---------
# All workers import ONE exported snapshot, so the export is the committed image
# at call time: no duplication, and rows the caller wrote but did not commit are
# absent. This is jdatcmd's #329 repro; a broken snapshot handoff duplicated the
# table and dropped the caller's rows, and no autocommit fixture could see it.
psql_run "DROP TABLE IF EXISTS t_tx;
          CREATE TABLE t_tx ($COLS) USING pgcolumnar;
          SELECT pgcolumnar.set_options('t_tx'::regclass, stripe_row_limit => 3000);
          INSERT INTO t_tx SELECT g, g, g::float8/7, 'c'||g FROM generate_series(1,20000) g;" >/dev/null
NC="$(q "SELECT count(*) FROM t_tx")"		# committed rows
DTX="$PGC_WORKDIR/tx"
# one psql session, one transaction: uncommitted INSERT, then export, then commit
psql_run "BEGIN;
          INSERT INTO t_tx SELECT g, g, g::float8/7, 'u'||g FROM generate_series(100001,100500) g;
          SELECT pgcolumnar.parallel_export_parquet('t_tx'::regclass, '$DTX', 4);
          COMMIT;" >/dev/null
check "in-txn export: read-back count == committed count (no duplication)" \
	"$(q "SELECT count(*) FROM pgcolumnar.read_parquet('$DTX') AS t($RB)")" "$NC"
check "in-txn export: no duplicate ids in the read-back" \
	"$(q "SELECT count(DISTINCT id) FROM pgcolumnar.read_parquet('$DTX') AS t($RB)")" "$NC"
check "in-txn export: read-back == committed rows (uncommitted rows absent)" \
	"$(pgc_set_hash "SELECT * FROM pgcolumnar.read_parquet('$DTX') AS t($RB)")" \
	"$(pgc_set_hash "SELECT id,k,v,txt FROM t_tx WHERE txt LIKE 'c%'")"

# ---- error cases ------------------------------------------------------------
# st_1 was written above, so it is non-empty
expect_error "reject a non-empty output directory" \
	"SELECT pgcolumnar.parallel_export_parquet('t_col'::regclass, '$PGC_WORKDIR/st_1', 2)"
psql_run "DROP TABLE IF EXISTS t_heap2; CREATE TABLE t_heap2 ($COLS);" >/dev/null
expect_error "reject a non-columnar target" \
	"SELECT pgcolumnar.parallel_export_parquet('t_heap2'::regclass, '$PGC_WORKDIR/heaptgt', 2)"

check "server still up after the exports" "$(q "SELECT 1")" 1

pgc_summary
