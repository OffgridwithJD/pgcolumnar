#!/usr/bin/env bash
# Regression for the shared full-scan cost helper (#12): the grouped vector
# aggregate's no-serial-survivor fallback must price its input scan the same way
# the columnar scan node does (projected width, per-column decode CPU, zone-map
# survival), not with the bare seqscan formula that under-priced it on a wide
# table. This asserts the fold path is chosen and, decisively, that it returns
# the same aggregate a plain (non-fold) plan does on a WIDE table.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# wide table: many columns so the per-column decode CPU term the fallback was
# missing is material.
DEF="g int"; for i in $(seq 0 24); do DEF="$DEF, c$i bigint"; done
q "CREATE TABLE wa ($DEF) USING pgcolumnar" >/dev/null
VALS="g%16$(for i in $(seq 0 24); do printf ', g*%d' $((i + 1)); done)"
q "INSERT INTO wa SELECT $VALS FROM generate_series(1, 40000) g" >/dev/null
q "ANALYZE wa" >/dev/null

# The whole grouped result reduced to one comparable string, computed in SQL so
# there is no shell ordering or row-count artifact.
Q="SELECT string_agg(g||':'||s0||':'||s24||':'||c, '|' ORDER BY g)
   FROM (SELECT g, sum(c0) s0, sum(c24) s24, count(*) c FROM wa GROUP BY g) r"
EXPLAINQ="SELECT g, sum(c0) FROM wa GROUP BY g"

# reference: no vectorized grouping
ref="$(q "SET pgcolumnar.enable_group_vectorization=off; SET pgcolumnar.enable_ungrouped_vector_agg=off; $Q" | tail -1)"

# fold path: parallel ungrouped vector agg on (the shape that drops the serial
# scan path and takes the fallback this fix corrects)
FOLD="SET pgcolumnar.enable_ungrouped_vector_agg=on; SET pgcolumnar.enable_parallel_vector_agg=on; SET max_parallel_workers_per_gather=4;"
got="$(q "$FOLD $Q" | tail -1)"

plan="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -qtA \
	-c "$FOLD" -c "EXPLAIN (COSTS OFF, VERBOSE) $EXPLAINQ" 2>/dev/null)"
foldcnt="$(printf '%s' "$plan" | grep -ciE 'Batch Fold|Custom Scan')"
echo "-- fold path markers: $foldcnt"

check "the fold path is used on the wide grouped aggregate" \
	"$([ "$foldcnt" -gt 0 ] && echo yes)" "yes"
check "the fold result matches a plain aggregate on a wide table" "$got" "$ref"
check "backend alive" "$(q 'SELECT 1')" "1"
pgc_summary
