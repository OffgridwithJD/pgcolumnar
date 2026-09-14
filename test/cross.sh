#!/usr/bin/env bash
# smallest K at which the planner leaves the index, under whatever .so is built here
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "/usr/local/pg18a/bin/pg_config"
N=1000000
psql_run "CREATE TABLE ifc (id int, a int, b int) USING pgcolumnar;"
psql_run "INSERT INTO ifc SELECT g, g % 10, g % 100 FROM generate_series(1,$N) g;"
psql_run "CREATE INDEX ifc_id ON ifc(id);"
psql_run "ANALYZE ifc;"
q() { env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -Atq -c "$1" 2>&1; }
S="SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; SET max_parallel_workers_per_gather=0; SET jit=off;"
node() { q "$S EXPLAIN (COSTS OFF) SELECT sum(a) FROM ifc WHERE id <= $1" | grep -m1 -oE 'Index Only Scan|Index Scan|Custom Scan|Seq Scan'; }
lo=1000; hi=200000
[ "$(node $hi)" = "Custom Scan" ] || { echo "NO CROSSOVER below $hi"; exit 0; }
while [ $((hi-lo)) -gt 250 ]; do
  mid=$(((lo+hi)/2))
  if [ "$(node $mid)" = "Custom Scan" ]; then hi=$mid; else lo=$mid; fi
done
echo "CROSSOVER: index at K=$lo, custom scan at K=$hi"
for K in 10000 20000 30000 40000; do echo "  K=$K -> $(node $K)"; done
