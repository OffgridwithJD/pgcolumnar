#!/usr/bin/env bash
#
# nbtree's deletion passes must never destroy an index entry for a LIVE row.
#
# table_index_delete_tuples asks "is this entry dead to EVERYONE". nbtree acts on
# the answer in _bt_delitems_delete: the items are removed from the leaf page
# physically, inside a critical section, WAL-logged. Nothing puts them back, and
# a transaction abort does not.
#
# heapam answers from a GLOBAL visibility test (InitNonVacuumableSnapshot over
# GlobalVisTestFor). Answering from the calling backend's MVCC snapshot instead
# is a different question: a row this very transaction deleted but has not
# committed reads as "not live to me" while still being live to everyone else.
#
# The observable end of that is silent and severe. With version churn on a
# non-indexed column, so that index_unchanged_by_update() sets nbtree's
# indexUnchanged hint and triggers the bottom-up pass:
#
#     SELECT count(*) FROM cc WHERE a = 1;   -- 228, via Index Only Scan
#     SELECT count(b) FROM cc WHERE a = 1;   -- 400, via the columnar scan
#
# at SHIPPED DEFAULTS, on a table whose 400 rows are all live. The planner picks
# the index-only scan on its own; no setting is needed to be wrong, only to look.
#
# The controls carry the argument. Without them a failing arm would only say that
# index churn loses rows in general, which is not the claim:
#
#   * churn on the INDEXED column makes index_unchanged_by_update() false, so no
#     bottom-up pass runs. Must stay complete.
#   * a heap table with a second index, so HOT is defeated and its index takes
#     the same indexUnchanged hint. Must stay complete.
#
# Usage:  test/index_delete_liveness.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

N=400
ROUNDS=12

churn() {	# churn <table> <set-clause> <COMMIT|ROLLBACK>
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq -c "
		BEGIN;
		DO \$\$ BEGIN FOR i IN 1..$ROUNDS LOOP UPDATE $1 SET $2; END LOOP; END \$\$;
		$3;" >/dev/null 2>&1
}
# The truth: a plan that cannot use the index at all.
truth() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq \
		-c "SET enable_indexscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off;" \
		-c "SELECT count(*) FROM $1 WHERE a = 1;" 2>&1 | tail -1
}
# The same question through the index.
viaindex() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq \
		-c "SET enable_seqscan=off; SET enable_indexonlyscan=off; SET pgcolumnar.enable_custom_scan=off;" \
		-c "SELECT count(b) FROM $1 WHERE a = 1;" 2>&1 | tail -1
}
viaindexplan() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atq \
		-c "SET enable_seqscan=off; SET enable_indexonlyscan=off; SET pgcolumnar.enable_custom_scan=off;" \
		-c "EXPLAIN (COSTS OFF) SELECT count(b) FROM $1 WHERE a = 1;" 2>&1 | tr '\n' ' '
}

mk() {	# mk <table> <USING clause> [extra index]
	psql_run "CREATE TABLE $1(a int, b text) $2;"
	psql_run "CREATE INDEX ${1}i ON $1(a);"
	[ -n "${3:-}" ] && psql_run "CREATE INDEX ${1}i2 ON $1(b);"
	psql_run "INSERT INTO $1 SELECT 1, repeat('x',20) FROM generate_series(1,$N);"
}

# ---- arm A: columnar, churn on the NON-indexed column, ROLLBACK -------------
mk ca "USING pgcolumnar"
check_num "premise: arm A holds $N rows before the churn" "$(truth ca)" "$N"
churn ca "b = b || 'y'" ROLLBACK
check "premise: arm A really plans an Index Scan, so the arm measures the index" \
	"$(case "$(viaindexplan ca)" in *"Index Scan"*) echo yes ;; *) echo "no: $(viaindexplan ca)" ;; esac)" "yes"
a_t="$(truth ca)"; a_i="$(viaindex ca)"
echo "-- arm A columnar, non-indexed churn, ROLLBACK: rows=$a_t via-index=$a_i"
check_num "arm A: a ROLLBACK leaves every live row reachable through the index" "$a_i" "$a_t"

# ---- control B: columnar, churn ON the indexed column -----------------------
mk cb "USING pgcolumnar"
churn cb "a = a" ROLLBACK
b_t="$(truth cb)"; b_i="$(viaindex cb)"
echo "-- control B columnar, INDEXED-column churn: rows=$b_t via-index=$b_i"
check_num "control B: indexed-column churn triggers no bottom-up pass and loses nothing" "$b_i" "$b_t"

# ---- control C: heap under the same hint ------------------------------------
mk hb "" second
churn hb "b = b || 'y'" ROLLBACK
c_t="$(truth hb)"; c_i="$(viaindex hb)"
echo "-- control C heap, same indexUnchanged hint: rows=$c_t via-index=$c_i"
check_num "control C: the heap loses nothing under the same churn" "$c_i" "$c_t"

# ---- arm D: committed churn, and the answer at SHIPPED DEFAULTS -------------
# An abort is not required, and no setting is required to get a wrong answer.
mk cc "USING pgcolumnar"
churn cc "b = b || 'y'" COMMIT
d_t="$(truth cc)"; d_i="$(viaindex cc)"
echo "-- arm D columnar, non-indexed churn, COMMIT: rows=$d_t via-index=$d_i"
check_num "arm D: a COMMIT leaves every live row reachable through the index" "$d_i" "$d_t"

def_star="$(q "SELECT count(*) FROM cc WHERE a = 1;")"
def_b="$(q "SELECT count(b) FROM cc WHERE a = 1;")"
echo "-- at shipped defaults: count(*)=$def_star  count(b)=$def_b  (truth $d_t)"
echo "-- the plan count(*) gets at defaults: $(q "EXPLAIN (COSTS OFF) SELECT count(*) FROM cc WHERE a = 1;" | tr '\n' ' ')"
check_num "at shipped defaults count(*) is right" "$def_star" "$d_t"
check_num "at shipped defaults the table answers the same to count(*) and count(b)" \
	"$def_star" "$def_b"

# ---- heap oracle on the same shape ------------------------------------------
mk hc "" second
churn hc "b = b || 'y'" COMMIT
check_num "oracle: the heap answers count(*) correctly after the same churn" \
	"$(q "SELECT count(*) FROM hc WHERE a = 1;")" "$N"

pgc_summary
