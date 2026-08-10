#!/usr/bin/env bash
#
# pgColumnar: the projection READ helpers are a privilege boundary (#562).
#
# pgcolumnar.read_projection() and pgcolumnar.reconstruct_via_projection() opened
# a caller-supplied regclass and returned its contents with no privilege check of
# any kind, and CREATE FUNCTION grants EXECUTE to PUBLIC with no REVOKE in the
# install script. Any role with USAGE on the pgcolumnar schema could read any
# columnar table that had a projection.
#
# reconstruct_via_projection is the worse of the two and the reason the title
# says EVERY column: it reconstructs NON-COVERED columns from the base relation
# by row number, so the projection is not the bound on what leaks, it is only the
# entry ticket. One projection on any column exposed the whole row.
#
# The bar is ACL_SELECT on the BASE relation rather than ownership, and that is a
# correctness argument rather than a leniency one: reconstruct returns columns
# the projection does not store, so SELECT on the base is precisely the privilege
# that governs reading those columns by any other route. Ownership is a stricter
# bar that happens to work, which is a different and worse property.
#
# Usage:  test/projection_privilege.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=2000

psql_run "CREATE TABLE secret (id int, ssn text, note text) USING pgcolumnar;"
psql_run "INSERT INTO secret SELECT g, 'ssn-'||g, 'note-'||g FROM generate_series(1,$ROWS) g;"
# The projection covers id and ssn. It does NOT cover note, which is the whole
# point: reconstruct returns note anyway.
psql_run "SELECT pgcolumnar.add_projection('secret','p1',ARRAY['id','ssn'],ARRAY['id']);"
psql_run "SELECT pgcolumnar.rebuild_projections('secret');"
psql_run "REVOKE ALL ON secret FROM PUBLIC;"

# Three roles, one per layer, so a refusal can be attributed rather than guessed.
#
#   t_prjnone  schema USAGE only.        Must be stopped by the SQL REVOKE.
#   t_prjexec  USAGE + EXECUTE granted.  Passes the SQL layer on purpose, so the
#              call reaches the C privilege check and can only be stopped there.
#   t_prjsel   USAGE + EXECUTE + SELECT. Must SUCCEED. This is the arm that
#              distinguishes ACL_SELECT from ownership: an owner-only bar refuses
#              it, and refusing it would be a regression, not a fix.
#
# A RULE FOR ANYONE EDITING THE PREMISES BELOW. A premise about a role is
# connectivity-safe only if THAT ROLE is the one running it. count_as() maps any
# non-numeric output to "refused", so a FATAL at login satisfies a deny arm just
# as well as a privilege error does, and a premise the OWNER runs -- a catalog
# lookup like has_function_privilege -- cannot see that. t_prjexec was exposed
# exactly that way until the premise below was added; t_prjnone and t_prjsel are
# covered only because their premises happen to be statements those roles
# execute themselves (a literal 'permission denied' match, and a row count).
# Tidying either of those into the count_as idiom reopens the hole silently, and
# only the error-text checks would still catch it. Keep the role in the driving
# seat of its own premise.
for r in t_prjnone t_prjexec t_prjsel; do
	psql_run "DROP ROLE IF EXISTS $r;"
	psql_run "CREATE ROLE $r NOSUPERUSER LOGIN;"
	psql_run "GRANT USAGE ON SCHEMA pgcolumnar TO $r;"
done
for r in t_prjexec t_prjsel; do
	psql_run "GRANT EXECUTE ON FUNCTION pgcolumnar.read_projection(regclass,text) TO $r;"
	psql_run "GRANT EXECUTE ON FUNCTION pgcolumnar.reconstruct_via_projection(regclass,text) TO $r;"
done
psql_run "GRANT SELECT ON secret TO t_prjsel;"

as() {  # as <role> <sql>
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U "$1" \
		-d "$PGC_DB" -At -c "$2" 2>&1
}
# Rows, or the string "refused". A count is the answer and an error is not a
# count, which is what keeps a broken call from reading as a denial.
count_as() {  # count_as <role> <function>
	local out
	out="$(as "$1" "SELECT count(*) FROM pgcolumnar.$2('secret','p1');" | head -1)"
	case "$out" in
		''|*[!0-9]*) echo refused ;;
		*) echo "$out" ;;
	esac
}

# ---- premises: the fixture, and that the functions WORK ----------------------
#
# The owner arms are not decoration. A DENIED result and a BROKEN result are
# indistinguishable from outside, so a suite that concludes anything from a
# refusal needs an arm on the SAME call that is expected to succeed. Measured,
# not hypothetical: an earlier probe of these functions passed a column
# definition list, every arm died with "a column definition list is only allowed
# for functions returning record", and all five read as refusals.
#
# And the owner arm asserts a ROW COUNT rather than absence of error. If a later
# change made these return zero rows for everyone, a no-error owner arm would
# stay green while the deny arms stayed green and the suite would pass over a
# function that does nothing.
check_num "premise: the owner reads the projection, and gets rows" \
	"$(q "SELECT count(*) FROM pgcolumnar.read_projection('secret','p1');")" "$ROWS"
check_num "premise: the owner reconstructs, and gets rows" \
	"$(q "SELECT count(*) FROM pgcolumnar.reconstruct_via_projection('secret','p1');")" "$ROWS"
# Both functions RETURN SETOF text: one row is a single pipe-joined string, not
# a record. A column definition list is rejected outright, which is how an
# earlier probe of these functions produced five arms that all looked like
# refusals and were actually call errors. Match the text.
check "premise: reconstruct really does return the NON-COVERED column" \
	"$(q "SELECT pgcolumnar.reconstruct_via_projection('secret','p1') LIKE '%note-%' LIMIT 1;")" \
	"t"
check "premise: and read_projection does NOT, so the two differ as the issue says" \
	"$(q "SELECT pgcolumnar.read_projection('secret','p1') LIKE '%note-%' LIMIT 1;")" \
	"f"
check "premise: the test roles are not superusers" \
	"$(q "SELECT bool_and(NOT rolsuper) FROM pg_roles WHERE rolname LIKE 't_prj%';")" "t"
check "premise: the unprivileged role cannot read the table by any ordinary route" \
	"$(as t_prjnone 'SELECT count(*) FROM secret;' | grep -c 'permission denied')" "1"
check "premise: t_prjsel CAN read the table, so its arm below tests the bar" \
	"$(as t_prjsel 'SELECT count(*) FROM secret;' | head -1)" "$ROWS"

# ---- layer one: the SQL grant ------------------------------------------------
check "a role with only schema USAGE is refused read_projection" \
	"$(count_as t_prjnone read_projection)" "refused"
check "and is refused reconstruct_via_projection" \
	"$(count_as t_prjnone reconstruct_via_projection)" "refused"

# WHICH layer refused, not merely that one did. Both layers reject this role, so
# a bare "refused" stays true if the REVOKE is deleted and the C check catches it
# instead -- measured: with the REVOKE removed this suite still passed 14 of 14.
# The error text is the only thing that attributes the refusal, so it is asserted
# here to tell the layers apart rather than in place of behaviour.
check "and the refusal comes from the SQL grant, naming the function" \
	"$(as t_prjnone "SELECT count(*) FROM pgcolumnar.read_projection('secret','p1');" | grep -c 'permission denied for function')" \
	"1"

# ---- layer two: the C check, reached only because EXECUTE was granted --------
#
# This role clears the SQL layer deliberately. If it is refused, the refusal
# cannot be the REVOKE and cannot be the schema.
check "premise: t_prjexec really does hold EXECUTE, so it reaches the C gate" \
	"$(q "SELECT has_function_privilege('t_prjexec','pgcolumnar.read_projection(regclass,text)','EXECUTE');")" "t"
# And that it can CONNECT. The line above is a catalog lookup run as the owner,
# so it is blind to whether this role can open a session at all -- and count_as
# turns any non-numeric output into "refused", which a FATAL at login satisfies
# just as well as a privilege error does. Measured, not hypothetical: with
# `ALTER ROLE t_prjexec NOLOGIN` injected, the EXECUTE premise above and both
# "is refused" checks below still PASSED, and only the error-text check caught
# it. A deny arm is evidence only if the call reached the code that denies it.
check "premise: t_prjexec can open a session, so a refusal below is a refusal" \
	"$(as t_prjexec 'SELECT 1;' | head -1)" "1"
check "a role with EXECUTE but no SELECT is refused read_projection" \
	"$(count_as t_prjexec read_projection)" "refused"
check "and is refused reconstruct_via_projection, which leaks non-covered columns" \
	"$(count_as t_prjexec reconstruct_via_projection)" "refused"
check "and THAT refusal names the table, so it is the C check and not the grant" \
	"$(as t_prjexec "SELECT count(*) FROM pgcolumnar.read_projection('secret','p1');" | grep -c 'permission denied for table')" \
	"1"

# ---- the bar is SELECT, not ownership ---------------------------------------
#
# Without these two the fix could pass by refusing everyone, which is not a fix,
# it is a broken function with a good error message.
check "a role WITH SELECT still reads the projection" \
	"$(count_as t_prjsel read_projection)" "$ROWS"
check "and still reconstructs" \
	"$(count_as t_prjsel reconstruct_via_projection)" "$ROWS"

# ---- row-level security, closed by #563 -------------------------------------
#
# These two arms were pinned as assertions of the WRONG value while #563 was
# open: they asserted that a policy-restricted caller got every row, so that the
# eventual fix would turn this suite red on purpose rather than pass quietly over
# a closed hole. That is exactly what happened, and this is the update the pin
# was designed to force.
#
# ACL_SELECT answers "may this role read this table". RLS answers "which rows".
# The direct-storage paths cannot answer the second, because policies are applied
# by the rewriter and these functions never build a query, so they now refuse a
# relation whose policies apply to the caller. See test/rls_direct_storage.sh for
# the full surface and docs/limitations.md for the user-facing statement.
psql_run "ALTER TABLE secret ENABLE ROW LEVEL SECURITY;"
psql_run "CREATE POLICY p_one ON secret FOR SELECT TO t_prjsel USING (id = 1);"

check_num "premise: the policy is in force for ordinary SQL" \
	"$(as t_prjsel 'SELECT count(*) FROM secret;' | head -1)" "1"
check "read_projection now refuses a policy-restricted caller (#563)" \
	"$(count_as t_prjsel read_projection)" "refused"
check "and so does reconstruct_via_projection" \
	"$(count_as t_prjsel reconstruct_via_projection)" "refused"
check "and the refusal names row-level security, not the table ACL" \
	"$(as t_prjsel "SELECT count(*) FROM pgcolumnar.read_projection('secret','p1');" | grep -c '^ERROR:.*row-level security')" \
	"1"

pgc_summary
