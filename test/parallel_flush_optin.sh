#!/usr/bin/env bash
#
# pgColumnar: parallel_flush stays OPT-IN, and the metric a default-on gate would
# need cannot separate the shapes (#445).
#
# #445 measured that pgcolumnar.parallel_flush helps one narrow shape -- a large
# flush of many cheap numeric columns -- and regresses the common cases (frequent
# small flushes, wide text, cheap fixed-width). A gate to turn it on by default
# was designed and REFUTED: the metric computable at dispatch time, over the
# buffered .len fields (natts, buffered bytes, bytes per value), does not carry
# per-column encode CPU, which is the variable that decides the outcome. Two
# shapes with byte-identical metrics have opposite best, so no threshold over the
# metric can gate them.
#
# This suite pins the decision, not a gate. It asserts three things:
#  1. the default is OFF, and a default flush dispatches serial;
#  2. opting in is byte-identical to the serial path (and actually dispatches
#     parallel, so the identity is not a silent fall-back);
#  3. the refuted metric COLLIDES: a random and a constant column, opposite in
#     encode cost, produce a byte-identical dispatch metric -- so the metric
#     cannot tell apart shapes whose real best differs.
#
# It is GREEN on current source. Its value is the removal proofs, marked below:
# flip the boot default, or mutate the parallel assembly, and the named arm goes
# RED. The collision arm can only go RED if someone adds a distinguishing term to
# the metric -- which is exactly the signal that a real gate has become possible.
#
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# The ON arms need worker slots; a bulk flush registers min(natts, <=8) workers.
psql_run "ALTER SYSTEM SET max_worker_processes = 16;"
env PATH="$PGC_BINDIR:$PATH" pg_ctl -D "$PGC_PGDATA" restart -w -o "-p $PGC_PORT" >/dev/null 2>&1 || true
sleep 1

q() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atqc "$1" 2>/dev/null
}

# The dispatch line the flush emits once per stripe at DEBUG1. gucSql runs in the
# same session before the insert, so a SET reaches the flush. Returns the tail of
# the line: "rows=.. natts=.. bufbytes=.. valbytes=.. valcount=.. -> serial".
dispatch() { # dispatch <gucSql> <insertSql>
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -c "SET client_min_messages=debug1;" -c "$1" -c "$2" 2>&1 |
		grep -oE 'parallel_flush dispatch: .*-> (parallel|serial)' | tail -1 |
		sed 's/^.*dispatch: //'
}

# LSN-independent storage fingerprint over the stored chunk metadata.
fp() { # fp <table>
	q "SELECT md5(string_agg(group_number || ':' || column_index || ':' || value_count || ':' || encode(encoding_descriptor, 'hex') || ':' || block_codec || ':' || page_length, '|' ORDER BY group_number, column_index)) FROM pgcolumnar.column_chunk WHERE storage_id = pgcolumnar.get_storage_id('$1')"
}

# ---- 1. the default is OFF, and stays that way -----------------------------

check_text "premise: parallel_flush is off by default" \
	"$(q "SHOW pgcolumnar.parallel_flush")" "off"

q "CREATE TABLE wnum (a int, b int, c int, d int, e int, f int, g int, h int) USING pgcolumnar;" >/dev/null

# DEFAULT-OFF PIN. A fresh flush with no SET must dispatch SERIAL.
# REMOVAL PROOF: set the boot default to true in columnar_tableam.c (the
# DefineCustomBoolVariable for pgcolumnar.parallel_flush) -> this line logs
# "-> parallel" and the check goes RED. That red proves the default, not
# incidental structure, keeps the machine off.
d_default="$(dispatch "SELECT 1;" "INSERT INTO wnum SELECT g,g,g,g,g,g,g,g FROM generate_series(1,300000) g;")"
check_text "a default flush dispatches serial" \
	"$([ "${d_default##*-> }" = "serial" ] && echo serial || echo "parallel:[$d_default]")" \
	"serial"

# ---- 2. opting in is byte-identical to serial ------------------------------

q "TRUNCATE wnum;" >/dev/null
d_on="$(dispatch "SET pgcolumnar.parallel_flush=on;" "INSERT INTO wnum SELECT g,g,g,g,g,g,g,g FROM generate_series(1,300000) g;")"
# The identity below is vacuous if ON silently fell back to serial, so assert the
# wide-numeric flush really took the worker path.
check_text "with the GUC on, a wide-numeric flush dispatches parallel (not a silent serial fall-back)" \
	"$([ "${d_on##*-> }" = "parallel" ] && echo parallel || echo "serial:[$d_on]")" \
	"parallel"
fp_on="$(fp wnum)"

q "TRUNCATE wnum;" >/dev/null
q "SET pgcolumnar.parallel_flush=off; INSERT INTO wnum SELECT g,g,g,g,g,g,g,g FROM generate_series(1,300000) g;" >/dev/null
fp_off="$(fp wnum)"

# REMOVAL PROOF: mutate flush_columns_parallel's assembly to reorder or alter a
# column's bytes -> fp_on diverges from fp_off and this goes RED.
check_text "opting in stores byte-identical chunks to the serial path" "$fp_on" "$fp_off"

# ---- 3. the refuted metric collides ----------------------------------------
#
# i5_rand and i5_const have the identical schema and row count, so the dispatch
# metric (rows, natts, bufbytes, valbytes, valcount) is identical -- yet their
# encode cost is opposite: random bigints are incompressible and carry the heavy
# per-column work parallelism spreads, constants are trivial. #445 measured
# opposite best for exactly this kind of pair. A gate over this metric cannot
# tell them apart, which is why default-on is refused.
q "CREATE TABLE i5_rand  (a bigint,b bigint,c bigint,d bigint,e bigint) USING pgcolumnar;" >/dev/null
q "CREATE TABLE i5_const (a bigint,b bigint,c bigint,d bigint,e bigint) USING pgcolumnar;" >/dev/null
m_rand="$(dispatch "SET pgcolumnar.parallel_flush=on;" "INSERT INTO i5_rand  SELECT (random()*9e18)::bigint,(random()*9e18)::bigint,(random()*9e18)::bigint,(random()*9e18)::bigint,(random()*9e18)::bigint FROM generate_series(1,400000) g;")"
m_const="$(dispatch "SET pgcolumnar.parallel_flush=on;" "INSERT INTO i5_const SELECT 7::bigint,7::bigint,7::bigint,7::bigint,7::bigint FROM generate_series(1,400000) g;")"
# strip the -> decision; compare only the metric the gate would read.
check_text "the dispatch metric is byte-identical for a random and a constant column (the metric cannot separate opposite-cost shapes)" \
	"${m_rand% -> *}" "${m_const% -> *}"

# REMOVAL PROOF / future signal: this can only go RED if a distinguishing term
# (e.g. per-column encode cost) is added to the metric -- which is the signal a
# real gate has become possible. A comment at the dispatch says so.

pgc_summary
