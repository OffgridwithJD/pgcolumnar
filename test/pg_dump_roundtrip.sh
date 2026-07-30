#!/usr/bin/env bash
#
# pg_dump / restore round-trip for a columnar table: the basic "can I get my
# data back out" guarantee, which nothing else in the suite covered. Builds a
# USING pgcolumnar table with data, a per-table option, and an index; then
# exercises BOTH dump paths and restores each into a fresh database (restoring
# over the live one collides on the extension's own schema):
#
#   - plain SQL       (pg_dump -f ...   -> psql -f)
#   - custom archive  (pg_dump -Fc ...  -> pg_restore), the format most real
#                     backups use, which drives a different restore code path
#
# For each it asserts the row count, a content checksum, the access method, and
# that the surviving index actually answers a point lookup (not merely that a
# catalog row exists). Restore success is judged by the client's EXIT CODE
# (ON_ERROR_STOP / pg_restore --exit-on-error), not by grepping for the word
# "ERROR", which is localised.
#
# Per-table options set through pgcolumnar.set_options live in the
# pgcolumnar.options catalog, not as reloptions, so pg_dump does not emit them
# (issue #248). This suite reports whether they survive rather than asserting it,
# so a known gap does not redden the round-trip gate.
#
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

DUMP_SQL="$PGC_WORKDIR/rt.sql"
DUMP_FC="$PGC_WORKDIR/rt.dump"
run() { env PATH="$PGC_BINDIR:$PATH" "$@"; }
on() { run psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$1" -At -c "$2"; }

# --- build: data + an option + an index ------------------------------------
psql_run "CREATE TABLE dt (id bigint, kind int, payload text) USING pgcolumnar;" >/dev/null
psql_run "SELECT pgcolumnar.set_options('dt', encode_effort => 'fast');" >/dev/null
psql_run "INSERT INTO dt SELECT g, g % 7, 'p'||g FROM generate_series(1,50000) g;" >/dev/null
psql_run "CREATE INDEX dt_id_idx ON dt (id);" >/dev/null

sum_sql="SELECT coalesce(sum(hashtextextended(id::text||'|'||kind::text||'|'||payload, 0)), 0) FROM dt"
am_sql="SELECT a.amname FROM pg_class c JOIN pg_am a ON a.oid = c.relam WHERE c.relname = 'dt'"
# A scalar subquery, so the answer is defined whether or not a row exists. The
# plain form returned zero rows after a restore -- pg_dump does not emit the
# options row at all -- and coalesce cannot rescue a missing row, so the result
# was empty rather than '<none>' and the pinned assertion below read as a
# different bug than the one it is pinning.
opt_sql="SELECT coalesce((SELECT encode_effort FROM pgcolumnar.options WHERE regclass = 'dt'::regclass), '<none>')"
# Force the planner off seqscan so the point lookup exercises the restored index;
# the returned value proves both the data and the index survived and work.
idx_sql="SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT id FROM dt WHERE id = 12345"

before_count="$(q "SELECT count(*) FROM dt;")"
before_sum="$(q "$sum_sql;")"
before_opt="$(q "$opt_sql;")"

verify() {  # label db
	local label="$1" db="$2" ao
	check "$label: row count survives"           "$(on "$db" "SELECT count(*) FROM dt;")" "$before_count"
	check "$label: row data survives (checksum)" "$(on "$db" "$sum_sql;")" "$before_sum"
	check "$label: access method is pgcolumnar"  "$(on "$db" "$am_sql;")" "pgcolumnar"
	# tail -1: the two SET statements each emit a command tag before the result.
	check "$label: restored index answers a point lookup" "$(on "$db" "$idx_sql;" | tail -1)" "12345"
	# Pinned as an assertion of the CURRENT, WRONG behaviour rather than echoed.
	#
	# An echo in a passing suite is read by nobody, so a known gap recorded that
	# way is a gap that gets forgotten. Asserting what happens today keeps the
	# round-trip gate green while #248 is open, and makes fixing #248 turn this
	# check RED -- which is exactly when someone needs reminding that this line
	# and its expectation have to change. A known-wrong behaviour that is pinned
	# cannot be fixed silently.
	#
	# When #248 lands: flip the expectation to "$before_opt" and delete this note.
	check "$label: encode_effort is NOT preserved (pinned; see #248)" \
		"$(on "$db" "$opt_sql;")" "<none>"
	on postgres "DROP DATABASE IF EXISTS $db;" >/dev/null 2>&1
}

freshdb() { on postgres "DROP DATABASE IF EXISTS $1;" >/dev/null 2>&1; on postgres "CREATE DATABASE $1;" >/dev/null; }

# --- plain SQL format ------------------------------------------------------
run pg_dump -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -f "$DUMP_SQL"; rc=$?
check "plain: pg_dump exited 0" "$rc" "0"
check "plain: dump recreates the table on the columnar AM" \
	"$(grep -cE "USING pgcolumnar|default_table_access_method = pgcolumnar" "$DUMP_SQL" | awk '{print ($1>0)?"yes":"no"}')" "yes"
freshdb "${PGC_DB}_p"
run psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "${PGC_DB}_p" -v ON_ERROR_STOP=1 -q -f "$DUMP_SQL" >/dev/null 2>&1; rc=$?
check "plain: restore exited 0 (ON_ERROR_STOP)" "$rc" "0"
verify plain "${PGC_DB}_p"

# --- custom archive format -------------------------------------------------
run pg_dump -Fc -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -f "$DUMP_FC"; rc=$?
check "custom: pg_dump -Fc exited 0" "$rc" "0"
freshdb "${PGC_DB}_c"
run pg_restore --exit-on-error -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "${PGC_DB}_c" "$DUMP_FC" >/dev/null 2>&1; rc=$?
check "custom: pg_restore exited 0 (--exit-on-error)" "$rc" "0"
verify custom "${PGC_DB}_c"

pgc_summary
