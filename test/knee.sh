#!/usr/bin/env bash
# Where does the half-group cap bind, relative to the 50,000 rows the suite pins?
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "/usr/local/pg18a/bin/pg_config"

N=1000000
psql_run "CREATE TABLE ifc (id int, a int, b int) USING pgcolumnar;"
psql_run "INSERT INTO ifc SELECT g, g % 10, g % 100 FROM generate_series(1,$N) g;"
psql_run "CREATE INDEX ifc_id ON ifc(id);"
psql_run "ANALYZE ifc;"

q() { env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -Atq -c "$1" 2>&1; }

echo "relpages/reltuples: $(q "SELECT relpages||' '||reltuples FROM pg_class WHERE relname='ifc'")"
echo "stripe_row_limit:   $(q "SHOW pgcolumnar.stripe_row_limit")"
echo
printf '%-10s %-14s %-16s %s\n' "rows(K)" "idxscan cost" "chosen node" "delta vs prev"
prev=""
for K in 1000 5000 10000 20000 30000 40000 50000 80000 120000 200000 400000; do
  SETS="SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; SET max_parallel_workers_per_gather=0; SET jit=off;"
  # the index path's own cost, with the custom scan out of the way
  c=$(q "$SETS SET pgcolumnar.enable_custom_scan=off; EXPLAIN SELECT sum(a) FROM ifc WHERE id <= $K" | grep -m1 -oE 'cost=[0-9.]+\.\.[0-9.]+' | sed 's/.*\.\.//')
  node=$(q "$SETS EXPLAIN (COSTS OFF) SELECT sum(a) FROM ifc WHERE id <= $K" | grep -m1 -oE 'Index Only Scan|Index Scan|Custom Scan|Seq Scan')
  d=""
  [ -n "$prev" ] && d=$(awk -v a="$c" -v b="$prev" 'BEGIN{printf "%+.1f", a-b}')
  printf '%-10s %-14s %-16s %s\n' "$K" "$c" "$node" "$d"
  prev="$c"
done
pgc_summary 2>/dev/null || true
