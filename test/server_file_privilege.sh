#!/usr/bin/env bash
#
# pgColumnar server-side-file privilege boundary (#216).
#
# Every entry point that reads or writes a server-side file gates on superuser()
# in C, and on nothing else: there is no SQL-level REVOKE and no shared wrapper,
# so the boundary is seven separate superuser() calls at seven call sites. A new
# entry point that forgets the check would be reachable by any role the schema is
# exposed to, and nothing would notice. This suite is that noticing: it enumerates
# the entry points as data and asserts each one refuses a non-superuser.
#
# The subtlety that makes this test real rather than vacuous: a fresh non-superuser
# cannot even reach these functions, because the pgcolumnar schema does not grant
# USAGE to PUBLIC, so an ungated call fails first with "permission denied for
# schema pgcolumnar" (also SQLSTATE 42501). If the suite left it there it would be
# testing the schema grant, not the superuser() gate, and deleting a superuser()
# call would still show "refused". So the test role is granted USAGE on the schema
# on purpose, which lets the call reach the C gate; the assertion then keys on the
# gate's own word, "superuser", which the schema-usage error and the parse-time
# errors do not contain. "output mentions superuser" therefore holds if and only
# if the call reached and was rejected by the superuser() gate -- delete one gate
# and that one entry point's check turns red, which is the removal proof #216 asks
# for.
#
# Boundary decision (#216): keep superuser() for the alpha, rather than moving to
# pg_read_server_files / pg_write_server_files as core's COPY does. Loosening later
# is backward compatible; tightening later breaks working setups. And the mitigation
# for the residual risk -- a superuser reading a Parquet/Arrow file they did not
# produce, which is the ordinary data-lake case -- is fuzzing the hand-rolled
# parsers (#214), which so far covers Parquet only. Documented in
# docs/administration.md (Security); see also docs/limitations.md.
#
# Usage:  test/server_file_privilege.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

nope="/tmp/pgc_216_does_not_exist.parquet"
out="$PGC_WORKDIR/216_out"

# A non-superuser that CAN reach the functions (schema usage granted, functions
# already PUBLIC-executable) but is not superuser, so what stops it is the gate.
psql_run "DROP ROLE IF EXISTS t_plain;"
psql_run "CREATE ROLE t_plain NOSUPERUSER;"
psql_run "GRANT USAGE ON SCHEMA pgcolumnar TO t_plain;"
psql_run "CREATE TABLE imp_target (id int, v text) USING pgcolumnar;"

# A superuser-created foreign table over the parquet FDW; the scan gate lives in
# BeginForeignScan, so a plain SELECT by t_plain must be refused there.
psql_run "CREATE SERVER pqsrv FOREIGN DATA WRAPPER pgcolumnar_parquet;"
psql_run "CREATE FOREIGN TABLE ft (id int, v text) SERVER pqsrv OPTIONS (path '$nope');"
psql_run "GRANT SELECT ON ft TO t_plain;"

# Run a statement as the non-superuser and return its combined output. SET ROLE
# to t_plain drops superuser for the rest of the connection, so superuser() in C
# sees the non-privileged current user.
run_plain() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -X -v ON_ERROR_STOP=0 -c "SET ROLE t_plain;" -c "$1" 2>&1
}

# The boundary as data: one row per entry point. A new file-reading entry point is
# added here, in one place, rather than remembered.
entry_points=(
	"import_parquet|SELECT pgcolumnar.import_parquet('imp_target'::regclass, '$nope')"
	"read_parquet|SELECT * FROM pgcolumnar.read_parquet('$nope') AS t(id int)"
	"parquet_schema|SELECT * FROM pgcolumnar.parquet_schema('$nope')"
	"export_parquet|SELECT pgcolumnar.export_parquet('imp_target'::regclass, '$out.parquet')"
	"export_arrow|SELECT pgcolumnar.export_arrow('imp_target'::regclass, '$out.arrow')"
	"import_arrow|SELECT pgcolumnar.import_arrow('imp_target'::regclass, '$nope')"
	"parquet_fdw_scan|SELECT * FROM ft"
)

for e in "${entry_points[@]}"; do
	label="${e%%|*}"
	sql="${e#*|}"
	reply="$(run_plain "$sql")"
	check "non-superuser is refused by the superuser() gate: $label" \
		"$(printf '%s' "$reply" | grep -qi "superuser" && echo yes || echo no)" "yes"
done

# Counter-proof that the word "superuser" is the gate and not something incidental:
# the same call as a superuser does NOT report a superuser error. It gets past the
# gate and fails (or succeeds) on the file itself -- a missing file for the reads,
# a written file for the exports. If this said "superuser" the assertion above
# would be meaningless.
su_reply="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
	-d "$PGC_DB" -X -v ON_ERROR_STOP=0 \
	-c "SELECT pgcolumnar.import_parquet('imp_target'::regclass, '$nope');" 2>&1)"
check "a superuser gets past the gate (error is about the file, not privilege)" \
	"$(printf '%s' "$su_reply" | grep -qi "superuser" && echo yes || echo no)" "no"

pgc_summary
