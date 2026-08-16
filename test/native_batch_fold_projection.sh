#!/usr/bin/env bash
# Regression for #10: the ungrouped batch fold's per-row loops now step over
# compact needed-column lists (keyCols/payloadCols) instead of masking 0..natts.
# A bug there would silently return a wrong aggregate, so this proves the loops
# still gather exactly the right columns on a WIDE table (many columns, few
# referenced). Built on parallel_vector_agg.sh's recipe (which fires the fold),
# widened with filler columns and summing a high-index one, with a selective key
# so the deferred-payload path (phase 2) runs.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# wide table: 44 filler bigints, then the aggregated column v LAST, so the fold's
# one payload column sits at a high index -- an under-built payload list would
# drop it and change sum(v). (Summing a second column flips the plan off the fold
# on a wide table, so the fold fires with a single aggregated column.)
FILL=""; for i in $(seq 0 43); do FILL="$FILL, f$i bigint"; done
q "CREATE TABLE t (id int, k int$FILL, v float8) USING pgcolumnar" >/dev/null
q "SELECT pgcolumnar.set_options('t'::regclass, stripe_row_limit => 40000)" >/dev/null
FVALS=""; for i in $(seq 0 43); do FVALS="$FVALS, g*$((i + 2))"; done
q "INSERT INTO t SELECT g, g % 1000 $FVALS,
       CASE WHEN g % 50 = 0 THEN NULL ELSE ((g % 13) - 6)::float8 END
   FROM generate_series(1, 400000) g" >/dev/null
q "ANALYZE t" >/dev/null

# k < 400 is a pushable, selective key so the fold defers the (high-index) payload.
INNER="SELECT count(*) n, sum(v) sv FROM t WHERE k < 400"

PAR="SET max_parallel_workers_per_gather=4; SET parallel_setup_cost=0; SET parallel_tuple_cost=0; SET min_parallel_table_scan_size=0; SET min_parallel_index_scan_size=0;"
FOLDOFF="$PAR SET pgcolumnar.enable_ungrouped_vector_agg=off; SET pgcolumnar.enable_group_vectorization=off;"
FOLDON="$PAR SET pgcolumnar.enable_ungrouped_vector_agg=on; SET pgcolumnar.enable_parallel_vector_agg=on;"

ref="$(q "$FOLDOFF $INNER" | tail -1)"
got="$(q "$FOLDON $INNER" | tail -1)"
echo "-- ref=[$ref]"
echo "-- got=[$got]"

plan="$(env PATH="$PGC_BINDIR:$PATH" psql -h "127.0.0.1" -p "$PGC_PORT" -U postgres -d "$PGC_DB" -qtA \
	-c "$FOLDON" -c "EXPLAIN (COSTS OFF, VERBOSE) $INNER" 2>/dev/null)"
foldcnt="$(printf '%s' "$plan" | grep -ciE 'Batch Fold: yes')"

check "the ungrouped batch fold actually ran (Batch Fold: yes)" \
	"$([ "$foldcnt" -gt 0 ] && echo yes)" "yes"
check "ref is a non-empty result (not a vacuous empty compare)" \
	"$(case "$ref" in ''|'<none>') echo no ;; *) echo yes ;; esac)" "yes"
check "the folded aggregate equals the non-fold aggregate (payload columns correct)" "$got" "$ref"
check "backend alive" "$(q 'SELECT 1')" "1"
pgc_summary
