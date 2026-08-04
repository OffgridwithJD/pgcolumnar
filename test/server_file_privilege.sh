#!/usr/bin/env bash
#
# pgColumnar server-side-file privilege boundary (#216, #330).
#
# Every entry point that reads or writes a server-side file gates in C on the
# matching core role -- pg_read_server_files for a read, pg_write_server_files for
# a write -- and on nothing else. There is no SQL-level REVOKE and no shared
# wrapper, so the boundary is one role check per call site. A new entry point that
# forgets the check would be reachable by any role the schema is exposed to, and
# nothing would notice. This suite is that noticing.
#
# It enumerates the entry points as data and asserts two things per point:
#   1. a role WITHOUT the matching server-file role is refused, and the error
#      names the role -- so the check reached the gate, not the schema-usage or
#      parse-time errors, which do not contain the role name;
#   2. a role WITH the matching role gets PAST the gate (it then fails on the
#      missing file, or the write succeeds) -- so the gate is the role and not
#      something incidental.
# And a coverage check: every SQL function that takes a file path must appear in
# the list, so a new server-file function fails the gate instead of slipping past.
#
# The schema does not grant USAGE to PUBLIC, so both test roles are granted USAGE
# on purpose; that lets the call reach the C gate rather than stopping at the
# schema.
#
# #330: this replaced the superuser() gate. See docs/administration.md. The read
# functions parse files this project wrote, so widening them to a role widens who
# reaches those parsers; the mitigation is the parser fuzzing tracked in #214.
#
# Usage:  test/server_file_privilege.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# parallel_copy prepares one xact per worker; parallel_export spawns workers.
export PGC_EXTRA_CONF=$'max_prepared_transactions=4\nmax_worker_processes=8'
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# Derived from the control file, not hardcoded. This broke once when the install script
# was renamed for a version bump, and a hardcoded name would break again at the next one.
_root="$(dirname "${BASH_SOURCE[0]}")/.."
_ver=$(grep -oE "default_version = '[^']+'" "$_root/pgcolumnar.control" | sed "s/.*'\(.*\)'/\1/")
SQLFILE="$_root/pgcolumnar--$_ver.sql"
[ -f "$SQLFILE" ] || { echo "FAIL  install script $SQLFILE not found"; exit 1; }
nope="/tmp/pgc_sfp_does_not_exist.parquet"
out="$PGC_WORKDIR/sfp_out"
outdir="$PGC_WORKDIR/sfp_dir"

psql_run "CREATE TABLE imp_target (id int, v text) USING pgcolumnar;"

# t_none: reaches the functions (schema usage) but holds no server-file role.
psql_run "DROP ROLE IF EXISTS t_none;"
psql_run "CREATE ROLE t_none NOSUPERUSER;"
psql_run "GRANT USAGE ON SCHEMA pgcolumnar TO t_none;"

# t_priv: holds both roles plus the table grants, so it clears the gate and then
# meets the file. Not a superuser -- that is the point, the role is the gate.
psql_run "DROP ROLE IF EXISTS t_priv;"
psql_run "CREATE ROLE t_priv NOSUPERUSER;"
psql_run "GRANT USAGE ON SCHEMA pgcolumnar TO t_priv;"
psql_run "GRANT pg_read_server_files, pg_write_server_files TO t_priv;"
psql_run "GRANT SELECT, INSERT ON imp_target TO t_priv;"

# foreign table over the parquet FDW; the gate is in BeginForeignScan.
psql_run "CREATE SERVER pqsrv FOREIGN DATA WRAPPER pgcolumnar_parquet;"
psql_run "CREATE FOREIGN TABLE ft (id int, v text) SERVER pqsrv OPTIONS (path '$nope');"
psql_run "GRANT SELECT ON ft TO t_none, t_priv;"

run_as() {	# role sql -> combined output; SET ROLE drops to the test role in C
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -X -v ON_ERROR_STOP=0 -c "SET ROLE $1;" -c "$2" 2>&1
}

# one row per entry point: name | read|write | SQL
entry_points=(
	"import_parquet|read|SELECT pgcolumnar.import_parquet('imp_target'::regclass, '$nope')"
	"read_parquet|read|SELECT * FROM pgcolumnar.read_parquet('$nope') AS t(id int)"
	"parquet_schema|read|SELECT * FROM pgcolumnar.parquet_schema('$nope')"
	"import_arrow|read|SELECT pgcolumnar.import_arrow('imp_target'::regclass, '$nope')"
	"file_split_offsets|read|SELECT pgcolumnar.file_split_offsets('$nope', 2)"
	"parallel_copy|read|SELECT pgcolumnar.parallel_copy('imp_target'::regclass, '$nope', 2)"
	"parquet_fdw_scan|read|SELECT * FROM ft"
	"export_parquet|write|SELECT pgcolumnar.export_parquet('imp_target'::regclass, '$out.parquet')"
	"export_arrow|write|SELECT pgcolumnar.export_arrow('imp_target'::regclass, '$out.arrow')"
	"parallel_export_parquet|write|SELECT pgcolumnar.parallel_export_parquet('imp_target'::regclass, '$outdir', 2)"
)

declare -A listed
for e in "${entry_points[@]}"; do
	label="${e%%|*}"; rest="${e#*|}"; dir="${rest%%|*}"; sql="${rest#*|}"
	listed["$label"]=1
	role="pg_${dir}_server_files"

	# 1. no role -> refused, and the error names the role (reached the gate)
	reply="$(run_as t_none "$sql")"
	check "no role is refused by the $role gate: $label" \
		"$(printf '%s' "$reply" | grep -qi "$role" && echo yes || echo no)" "yes"

	# 2. with the role -> past the gate (no role name in the output)
	rm -rf "$out".parquet "$out".arrow "$outdir" 2>/dev/null || true
	preply="$(run_as t_priv "$sql")"
	check "the $role role gets past the gate: $label" \
		"$(printf '%s' "$preply" | grep -qi "$role" && echo yes || echo no)" "no"
done

# coverage: every SQL function that declares a file-path argument must be listed
# above, so a new server-file function without a test entry turns this red.
discovered="$(awk '
	/CREATE FUNCTION pgcolumnar\./ { cap=1; buf="" }
	cap { buf = buf " " $0
	      if (buf ~ /\)/) {
	          if (buf ~ /path text/ || buf ~ /filename text/) {
	              match(buf, /pgcolumnar\.[a-z_]+/)
	              print substr(buf, RSTART + 11, RLENGTH - 11)
	          }
	          cap = 0
	      } }' "$SQLFILE" | sort -u)"
for fn in $discovered; do
	[ -n "${listed[$fn]:-}" ] && r=yes || r=no
	check "server-file function is covered by the boundary test: $fn" "$r" "yes"
done
check "coverage check found the file functions (not an empty scan)" \
	"$([ "$(printf '%s\n' "$discovered" | grep -c .)" -ge 7 ] && echo yes || echo no)" "yes"

pgc_summary
