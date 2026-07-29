#!/usr/bin/env bash
#
# pg_dump / restore round-trip for a columnar table: the basic "can I get my
# data back out" guarantee, which nothing else in the suite covered. Builds a
# USING pgcolumnar table with data, a per-table option, and an index; dumps the
# database; restores into a FRESH database (the canonical scenario -- restoring
# over the live one would collide on the extension's own schema); and asserts the
# data, the access method, and the index survive.
#
# Per-table options set through pgcolumnar.set_options live in the
# pgcolumnar.options catalog, not as reloptions, so pg_dump does not know to
# emit them. This suite reports whether they survive rather than asserting it, so
# a change in that behaviour is visible without turning the round-trip gate red.
#
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

DUMP="$PGC_WORKDIR/roundtrip.sql"
RESTORE_LOG="$PGC_WORKDIR/restore.log"
RDB="${PGC_DB}_restore"
run() { env PATH="$PGC_BINDIR:$PATH" "$@"; }
on() { run psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$1" -At -c "$2"; }

# --- build: data + an option + an index ------------------------------------
psql_run "CREATE TABLE dt (id bigint, kind int, payload text) USING pgcolumnar;" >/dev/null
psql_run "SELECT pgcolumnar.set_options('dt', encode_effort => 'fast');" >/dev/null
psql_run "INSERT INTO dt SELECT g, g % 7, 'p'||g FROM generate_series(1,50000) g;" >/dev/null
psql_run "CREATE INDEX dt_id_idx ON dt (id);" >/dev/null

sum_sql="SELECT coalesce(sum(hashtextextended(id::text||'|'||kind::text||'|'||payload, 0)), 0) FROM dt"
am_sql="SELECT a.amname FROM pg_class c JOIN pg_am a ON a.oid = c.relam WHERE c.relname = 'dt'"
opt_sql="SELECT coalesce(encode_effort, '<none>') FROM pgcolumnar.options WHERE regclass = 'dt'::regclass"

before_count="$(q "SELECT count(*) FROM dt;")"
before_sum="$(q "$sum_sql;")"
before_opt="$(q "$opt_sql;")"

# --- dump, then restore into a fresh database ------------------------------
run pg_dump -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -f "$DUMP"
check "pg_dump produced a non-empty dump" "$([ -s "$DUMP" ] && echo yes || echo no)" "yes"
check "the dump recreates the table on the columnar AM" \
	"$(grep -cE "USING pgcolumnar|default_table_access_method = pgcolumnar" "$DUMP" | awk '{print ($1>0)?"yes":"no"}')" "yes"

on postgres "DROP DATABASE IF EXISTS $RDB;" >/dev/null 2>&1
on postgres "CREATE DATABASE $RDB;" >/dev/null
run psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$RDB" -v ON_ERROR_STOP=0 -f "$DUMP" >"$RESTORE_LOG" 2>&1
check "restore into a fresh database reported no ERROR" \
	"$(grep -c 'ERROR:' "$RESTORE_LOG" | awk '{print ($1==0)?"clean":"errors"}')" "clean"

# --- assert the round-trip against the restored database -------------------
check "row count survives the round-trip"  "$(on "$RDB" "SELECT count(*) FROM dt;")" "$before_count"
check "row data survives the round-trip"     "$(on "$RDB" "$sum_sql;")" "$before_sum"
check "access method is still pgcolumnar"    "$(on "$RDB" "$am_sql;")" "pgcolumnar"
check "index survives the round-trip" \
	"$(on "$RDB" "SELECT count(*) FROM pg_indexes WHERE tablename='dt' AND indexname='dt_id_idx';")" "1"

# --- report (not assert) whether per-table options survived ----------------
after_opt="$(on "$RDB" "$opt_sql;")"
echo "-- per-table option encode_effort: before='$before_opt' after='$after_opt'"
if [ "$after_opt" != "$before_opt" ]; then
	echo "-- NOTE: pgcolumnar.set_options state did not survive pg_dump (options live in"
	echo "--       the pgcolumnar.options catalog, which pg_dump does not emit)."
fi

on postgres "DROP DATABASE IF EXISTS $RDB;" >/dev/null 2>&1
pgc_summary
