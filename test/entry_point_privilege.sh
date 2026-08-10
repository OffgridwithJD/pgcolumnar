#!/usr/bin/env bash
#
# pgColumnar: every relation-taking entry point has a decided privilege bar (#569).
#
# This suite exists because three separate coverage scans in this tree each lost
# members of the class they were written to enumerate, and each reported success
# while doing it:
#
#   - test/server_file_privilege.sh scans for functions declaring a file-path
#     argument, so it cannot see any relation-taking function without one.
#   - the projection suite has no coverage arm at all.
#   - two enumerations written on 2026-08-10, independently, both derived the C
#     symbol as pgcolumnar_<sqlname> and therefore silently dropped
#     get_storage_id (-> pgcolumnar_relation_storageid) and columnar_handler
#     (-> pgcolumnar_handler). Nothing errored. The lists just came out shorter.
#
# Three design choices follow from those failures, and they are the whole point
# of this file:
#
#   1. ENUMERATE FROM THE CATALOG, NOT THE SCRIPT. pg_proc.prosrc IS the C
#      symbol, resolved by the server with no parsing, so no naming convention
#      can be broken. The install script is then cross-checked against it as a
#      set, which catches a function declared but not installed, or installed
#      under a different symbol.
#   2. BUCKET ON THE TYPE, NOT ON A PARAMETER NAME. "Takes a relation" is
#      proargtypes[0] = 'regclass'::regtype. Nine of these functions name that
#      parameter tablename or target rather than rel, and several put it on a
#      continuation line, so every name-based or line-oriented regex drops most
#      of the class.
#   3. ASSERT SQLSTATE, NOT ERROR TEXT. A deny arm that greps for "permission
#      denied" is satisfied by a login FATAL, a missing function (42883), a bad
#      argument (22023), or a transaction-block refusal (25001). Only
#      aclcheck_error produces 42501.
#
# Usage:  test/entry_point_privilege.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

SQLFILE="$(dirname "${BASH_SOURCE[0]}")/../pgcolumnar--1.0-alpha.sql"

# Functions that take no relation and therefore have no relation-level bar to
# decide. Written out by name on purpose: adding a new no-relation function
# fails the coverage arm until somebody names it here and says why.
#
#   columnar_handler       returns the table AM routine to core, no arguments
#   parquet_fdw_handler    returns the FDW routine to core, no arguments
#   parquet_fdw_validator  validates an option list, no relation
#   parquet_schema         reads a FILE, gated by the server-file role (#559)
#   read_parquet           reads a FILE, gated by the server-file role (#559)
#   file_split_offsets     reads a FILE, gated by the server-file role (#559)
#
# Kept on ONE line and matched after whitespace normalisation. A multi-line list
# here is matched by `case " $EXEMPT " in *" $fn "*`, and the name sitting at a
# line end is followed by a newline rather than a space, so it silently fails to
# match and reads as an unbucketed function. That is not hypothetical: it is what
# the first run of this suite reported for parquet_fdw_validator.
EXEMPT="columnar_handler parquet_fdw_handler parquet_fdw_validator parquet_schema read_parquet file_split_offsets"
EXEMPT="$(echo $EXEMPT)"

# Relation-taking entry points with NO privilege check of any kind on main.
# PINNED AS THE WRONG VALUE, deliberately, per CONTEXT.md: when a fix lands this
# suite goes red and forces the list to shrink on purpose, rather than a comment
# nobody re-reads. Each carries the issue that owns it.
# One line, for the same reason as EXEMPT above.
#
# #558 and #562 landed on 2026-08-10 (merges d0d7309 and 77b530d), so
# read_projection, reconstruct_via_projection, vm_is_visible and vm_selftest have
# moved out of this list and into GUARDED_BEHAVIOURAL below.
KNOWN_UNGUARDED="export_arrow export_parquet import_arrow import_parquet get_storage_id"
KNOWN_UNGUARDED="$(echo $KNOWN_UNGUARDED)"

# Relation-taking entry points that are supposed to REFUSE an unprivileged
# caller, asserted behaviourally rather than believed.
GUARDED_BEHAVIOURAL="read_projection reconstruct_via_projection vm_is_visible vm_selftest"
GUARDED_BEHAVIOURAL="$(echo $GUARDED_BEHAVIOURAL)"

# ---- the enumeration, from the catalog -------------------------------------
#
# prosrc is the C symbol. proargtypes[0] is the first argument's type oid. Both
# come from the server, so neither can be lost to a naming convention or a line
# break in the install script.

installed="$(q "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'pgcolumnar' AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'c');")"
symbols="$(q "SELECT string_agg(DISTINCT p.prosrc, ' ' ORDER BY p.prosrc)
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'pgcolumnar' AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'c');")"
relfns="$(q "SELECT string_agg(DISTINCT p.proname, ' ' ORDER BY p.proname)
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'pgcolumnar' AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'c')
               AND p.proargtypes[0] = 'regclass'::regtype;")"
allfns="$(q "SELECT string_agg(DISTINCT p.proname, ' ' ORDER BY p.proname)
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'pgcolumnar' AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'c');")"

# ---- premises: the enumeration is real -------------------------------------
#
# An empty or tiny enumeration would satisfy every assertion below by having
# nothing to check. This is the floor that stops a broken query reading as a
# clean bill of health.
check "premise: the extension is installed and C entry points were found" \
	"$([ "${installed:-0}" -ge 20 ] && echo yes || echo no)" "yes"
check "premise: at least one relation-taking entry point was found" \
	"$([ -n "$relfns" ] && echo yes || echo no)" "yes"

# The catalog and the install script must agree as SETS. A function declared in
# the script but not installed, or installed under a different symbol, is a hole
# in the enumeration rather than a fact about the code.
#
# Comments are blanked first: a doc comment mentioning pgcolumnar.storage is not
# a declaration, and counting one is how a census comes out wrong in the other
# direction.
src_syms="$(sed 's,--.*,,' "$SQLFILE" \
	| tr '\n' ' ' \
	| grep -o "AS 'MODULE_PATHNAME'[, ]*'[a-z_]*'" \
	| grep -o "'[a-z_]*'$" | tr -d "'" | sort -u | tr '\n' ' ')"
cat_syms="$(printf '%s\n' $symbols | sort -u | tr '\n' ' ')"
check "premise: the install script declares MODULE_PATHNAME symbols at all" \
	"$([ "$(printf '%s\n' $src_syms | grep -c .)" -ge 20 ] && echo yes || echo no)" "yes"
check "the catalog and the install script agree on the symbol set" \
	"$(diff <(printf '%s\n' $src_syms) <(printf '%s\n' $cat_syms) >/dev/null && echo same || echo differs)" \
	"same"

# ---- the coverage assertion ------------------------------------------------
#
# Every C entry point lands in exactly one bucket, and the buckets sum to the
# input. This is the line that makes the rest a fact rather than a list.

exempt_seen=0 rel_seen=0 unbucketed=""
for fn in $allfns; do
	case " $EXEMPT " in *" $fn "*) exempt_seen=$((exempt_seen + 1)); continue ;; esac
	case " $relfns " in *" $fn "*) rel_seen=$((rel_seen + 1)); continue ;; esac
	unbucketed="$unbucketed $fn"
done
n_all="$(printf '%s\n' $allfns | grep -c .)"

check_num "coverage: inputs == sum(buckets)" \
	"$n_all" "$(( exempt_seen + rel_seen + $(printf '%s\n' $unbucketed | grep -c .) ))"
check "coverage: no entry point is unbucketed" \
	"$([ -z "${unbucketed// /}" ] && echo none || echo "$unbucketed")" "none"

# The EXEMPT list is an escape hatch, so it needs a guard of its own. Without
# this, adding a real relation-taking function to EXEMPT removes it from the
# population and NOTHING fails: the coverage arm still balances, because the
# function was counted as exempt rather than dropped. Proven by mutation on
# 2026-08-10 -- inserting `vacuum` into EXEMPT produced a fully green run, which
# is the same "a check too tight to fail" shape this suite exists to prevent.
#
# An exempt name that takes a relation is a contradiction: exempt means "has no
# relation-level bar to decide", and proargtypes says otherwise.
overclaimed=""
for fn in $EXEMPT; do
	case " $relfns " in *" $fn "*) overclaimed="$overclaimed $fn" ;; esac
done
check "no exempt name actually takes a relation" \
	"$([ -z "${overclaimed// /}" ] && echo none || echo "$overclaimed")" "none"

# Every relation-taking function splits into pinned-as-unguarded or
# claimed-guarded. The obvious loop here is a TRAP and the first version of this
# file fell into it: asserting that each function is "pinned or claimed-guarded"
# is true by construction, because claimed-guarded is the else branch. It passed
# for every function including one the whitespace bug had already mis-sorted.
#
# So assert things that CAN be false instead.
#
# 1. Every pinned name still exists as a relation-taking entry point. A pin for a
#    function that was renamed or dropped is a stale pin that silently stops
#    guarding anything.
stale=""
for fn in $KNOWN_UNGUARDED; do
	case " $relfns " in *" $fn "*) ;; *) stale="$stale $fn" ;; esac
done
check "no pinned name is stale (all still exist and take a relation)" \
	"$([ -z "${stale// /}" ] && echo none || echo "$stale")" "none"

# 2. The split is exhaustive and the two sides sum to the population, printed
#    from the data rather than retyped.
pinned_n=0 guarded_n=0
for fn in $relfns; do
	case " $KNOWN_UNGUARDED " in
		*" $fn "*) pinned_n=$((pinned_n + 1)) ;;
		*)         guarded_n=$((guarded_n + 1)) ;;
	esac
done
n_rel="$(printf '%s\n' $relfns | grep -c .)"
check_num "coverage: relation-taking == pinned + claimed-guarded" \
	"$n_rel" "$(( pinned_n + guarded_n ))"

# 3. The pinned count is exactly the size of the known class. This is the arm
#    that reddens when a fix lands, which is the entire purpose of the pins: the
#    engineer who closes one must come here and remove the name.
check_num "KNOWN WRONG (#559/#566): entry points still ungated on this build" \
	"$pinned_n" "5"

# THE COUNT ABOVE IS NOT ENOUGH, AND THIS SUITE PROVED IT ON ITSELF.
#
# When #558 and #562 merged, four of the nine names here became genuinely
# guarded, and this file stayed FULLY GREEN. The arm counts names in a list I
# maintain, so it measures my intent rather than the world: a fix can land and
# the list can go stale with nothing to say so. That is the same "measure the
# work, never the intent" failure this suite exists to catch, built into the
# suite itself.
#
# The arms below are the correction. Each makes the call and reads the SQLSTATE,
# so a fix landing turns the relevant arm red on its own, whatever the list says.

# ---- the pins, which are assertions of the WRONG value ----------------------
#
# Each of these is a live defect on main. When its fix lands, the function stops
# being reachable without privilege, this arm goes RED, and whoever fixed it must
# remove the name from KNOWN_UNGUARDED. That is the intended behaviour and not a
# failure of this suite.
#
# The arm is behavioural, not a list lookup: it calls the function as a role with
# schema USAGE and nothing on the relation, and asserts the SQLSTATE. 42501 is
# produced only by aclcheck_error, so no unrelated error can satisfy it, and a
# function that is genuinely ungated returns something that is not 42501 at all.
psql_run "CREATE TABLE ep_target (id int, v text) USING pgcolumnar;"
psql_run "INSERT INTO ep_target SELECT g, 'v'||g FROM generate_series(1,10) g;"
psql_run "REVOKE ALL ON ep_target FROM PUBLIC;"
psql_run "DROP ROLE IF EXISTS t_ep;"
psql_run "CREATE ROLE t_ep NOSUPERUSER LOGIN;"
psql_run "GRANT USAGE ON SCHEMA pgcolumnar TO t_ep;"

as_ep() {  # as_ep <sql> -> the SQLSTATE, or the literal noerror
	#
	# VERBOSITY is set with -v, NOT with -c "\\set ...". psql treats a -c argument
	# beginning with a backslash as a meta-command and takes a different code
	# path; that is how a sibling suite ended up with deny arms that could never
	# go green. -v sets the same psql variable with no meta-command involved.
	#
	# The SQLSTATE is then read from the ERROR line rather than from a bare line
	# of its own, because psql prefixes it. The first version of this helper
	# required a line matching ^[0-9A-Z]{5}$ and therefore returned empty for
	# every real error, including one the server log showed it had raised.
	local out
	out="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U t_ep -d "$PGC_DB" \
		-At -v VERBOSITY=sqlstate -v ON_ERROR_STOP=0 -c "$1" 2>&1)"
	printf '%s\n' "$out" | sed -n 's/^.*ERROR:[[:space:]]*\([0-9A-Z]\{5\}\).*$/\1/p' | head -1 \
		| grep -q . && printf '%s\n' "$out" | sed -n 's/^.*ERROR:[[:space:]]*\([0-9A-Z]\{5\}\).*$/\1/p' | head -1 \
		|| echo noerror
}

# The premise that makes every SQLSTATE arm below mean anything: this role can
# open a session. A deny arm is evidence only if the call reached the code that
# denies it, and a login FATAL carries no SQLSTATE at all.
check "premise: t_ep can open a session" \
	"$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U t_ep -d "$PGC_DB" -At -c 'SELECT 1;' 2>&1 | head -1)" \
	"1"
check "premise: t_ep cannot read the table by any ordinary route" \
	"$(as_ep 'SELECT count(*) FROM ep_target;')" "42501"

# get_storage_id takes exactly one regclass and nothing else, so its call needs
# no argument vector to be invented. It is the pin this slice proves
# behaviourally; the remaining eight need their own valid argument vectors and
# are covered by the bucketing arm above until those are written (#569).
# A projection is needed before the projection entry points can be called at all,
# and the REACHED premise below is what makes each deny arm mean anything: the
# owner making the identical call must succeed, or a refusal is indistinguishable
# from a broken call.
psql_run "SELECT pgcolumnar.add_projection('ep_target','p1',ARRAY['id'],ARRAY['id']);"
psql_run "SELECT pgcolumnar.rebuild_projections('ep_target');"

call_for() {  # call_for <fn> -> a valid argument vector for that function
	case "$1" in
		read_projection|reconstruct_via_projection) echo "SELECT pgcolumnar.$1('ep_target','p1');" ;;
		vm_is_visible|vm_selftest)                  echo "SELECT pgcolumnar.$1('ep_target',0);" ;;
		get_storage_id)                             echo "SELECT pgcolumnar.$1('ep_target');" ;;
		*) echo "" ;;
	esac
}

# THE ROLE MUST CLEAR THE SQL LAYER FIRST, OR THIS PROVES NOTHING.
#
# #562's fix ships two layers: a REVOKE of EXECUTE from PUBLIC, and a C-level
# pg_class_aclcheck. Both raise 42501. A role holding only schema USAGE is
# stopped by the REVOKE, so the SQLSTATE is identical whether or not the C check
# exists, and deleting the C guard leaves this suite fully green.
#
# That is not hypothetical. It was measured on 2026-08-10: both guards were
# removed from src/columnar_projection.c, the extension rebuilt, and this file
# reported 22 of 22 passing.
#
# Granting EXECUTE puts the role PAST the SQL layer on purpose, so the only thing
# left that can refuse it is the C check. Now 42501 attributes to one layer.
for fn in $GUARDED_BEHAVIOURAL; do
	psql_run "GRANT EXECUTE ON FUNCTION pgcolumnar.$fn($(case "$fn" in read_projection|reconstruct_via_projection) echo "regclass,text" ;; *) echo "regclass,int" ;; esac)) TO t_ep;" 2>/dev/null
done
check "premise: t_ep now holds EXECUTE, so a refusal below can only be the C check" \
	"$(q "SELECT bool_and(has_function_privilege('t_ep', p.oid, 'EXECUTE'))
	      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	      WHERE n.nspname='pgcolumnar' AND p.proname IN ('read_projection','reconstruct_via_projection','vm_is_visible','vm_selftest');")" \
	"t"

for fn in $GUARDED_BEHAVIOURAL; do
	sql="$(call_for "$fn")"
	check "premise: the owner can call $fn, so a refusal below is a refusal" \
		"$(q "$sql" >/dev/null 2>&1 && echo ok || echo broken)" "ok"
	check "$fn refuses an unprivileged caller with 42501" \
		"$(as_ep "$sql")" "42501"
done

# The four import/export siblings, pinned BEHAVIOURALLY rather than by name.
#
# A pin that counts names in a list cannot see a fix land; that is recorded above
# and it is the defect that let four names go stale when #558 and #562 merged.
# These four need a server-file role before they reach any table-level check, and
# a real fixture file would duplicate test/import_export_privilege.sh, which owns
# their full behaviour under the split for #569.
#
# So discriminate on the SHAPE of the failure with a path that cannot exist. It
# needs no fixture and it distinguishes the two states exactly:
#
#   ungated -> the call runs past the (absent) privilege check and dies at the
#              file layer:   could not open file "/nonexistent/..."
#   guarded -> aclcheck_error fires first:   permission denied for table
#
# Measured on main before the fix: all four report the file error, which is
# itself the proof that nothing checked the relation first. When #559's fix lands
# these arms go RED, and whoever landed it removes the names from
# KNOWN_UNGUARDED. That is the point of a pin.
psql_run "GRANT pg_read_server_files, pg_write_server_files TO t_ep;"
check "premise: t_ep holds the server-file roles, so it reaches the table check" \
	"$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U t_ep -d "$PGC_DB" -At \
		-c "SELECT pg_has_role('t_ep','pg_read_server_files','member');" 2>&1 | head -1)" "t"

for fn in export_arrow export_parquet import_arrow import_parquet; do
	out="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U t_ep -d "$PGC_DB" -At \
		-c "SELECT pgcolumnar.$fn('ep_target','/nonexistent/dir/x');" 2>&1 | head -1)"
	case "$out" in
		*"permission denied for table"*) state=refused ;;
		*"could not open file"*)         state=reached-the-file-layer ;;
		*)                               state="unexpected: $out" ;;
	esac
	check "KNOWN WRONG (#559): $fn reaches the file layer for a caller with no privilege" \
		"$state" "reached-the-file-layer"
done

# get_storage_id is the one whose argument vector needs nothing invented.
sqlstate="$(as_ep "$(call_for get_storage_id)")"
check "premise: the owner can call get_storage_id" \
	"$(q "$(call_for get_storage_id)" >/dev/null 2>&1 && echo ok || echo broken)" "ok"
check "KNOWN WRONG (#566): get_storage_id answers an unprivileged caller instead of raising 42501" \
	"$([ "$sqlstate" = "42501" ] && echo refused || echo answered)" "answered"

pgc_summary
