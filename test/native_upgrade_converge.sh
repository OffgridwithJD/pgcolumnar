#!/usr/bin/env bash
#
# The shipped upgrade scripts converge: a database on any previously released
# version, after ALTER EXTENSION pgcolumnar UPDATE, has a catalog byte-identical
# to a fresh install of the current default_version.
#
# This is the real guarantee behind "run one command to upgrade". The 1.0-alpha2
# cycle renamed the extension's C link symbols (columnar_* -> pgcolumnar_*, #382),
# added Iceberg/object-store/maintenance functions and two foreign-data wrappers,
# added two pgcolumnar.storage columns, and revoked PUBLIC execute on the internal
# projection and visibility-map functions. Every one of those deltas has to be in
# the upgrade script, or an upgraded database silently diverges from a fresh one:
# a missed C-symbol rewrite leaves an existing columnar table unreadable ("could
# not find function columnar_handler"), a missed REVOKE leaves an internal
# function world-executable.
#
# Released starting points, both of which must reach 1.0-alpha2:
#   1.0-dev   -- what the v1.0-alpha tag actually installed (default_version=1.0-dev)
#   1.0-alpha -- what a build from main installed after the #382 rename landed
# PostgreSQL walks dev->alpha->alpha2 or alpha->alpha2 from the shipped upgrade
# scripts. The old base install scripts are NOT shipped (project convention drops
# them); they live here as frozen fixtures purely to stand up an old-version
# database to upgrade.
#
# This CI test exercises the alpha->alpha2 leg, which is the one this release
# introduces and the one a single installed library can stand up per PostgreSQL
# major in the matrix. The dev leg cannot run against one library: a C function
# resolves its link symbol unconditionally at CREATE FUNCTION (check_function_bodies
# does not gate it), and the pre-#382 1.0-dev base names columnar_* symbols the
# 1.0-alpha2 library no longer exports. Standing up 1.0-dev therefore needs that
# release's own library. The full dev->alpha->alpha2 chain -- including that an
# existing columnar table still reads across the C-symbol rename, and that the
# upgraded catalog converges to a fresh install -- is validated by the two-build
# gate test/extension_upgrade.sh (run under PGC_RUN_UPGRADE=1, not in the per-major
# matrix, because it builds the previous release's shared library alongside this one).
#
# The snapshot compares, across the pgcolumnar schema: every function's full
# definition (pg_get_functiondef, which includes the AS '...','symbol' clause, so
# a wrong link symbol shows up here), its ACL, and its comment; every relation's
# kind, ACL, and comment; every column's type, NOT NULL, and comment; every
# non-base type; and every foreign-data wrapper's handler and validator.
# Convergence = an empty diff on all of it. The comment (pg_description) is in the
# snapshot on purpose: pg_get_functiondef does NOT emit COMMENT, so without this a
# generator that diffs only function definitions is blind to a missing comment,
# and an upgraded install silently loses the 44 function comments a fresh install
# carries (found in review of this release).
#
# Removal proof: this test caught three defects in the generated upgrade script
# before it went green -- psql command tags captured into the SQL body, function
# definitions concatenated without a terminating semicolon, and the ACL REVOKEs
# omitted entirely (the def-only diff that generated the script could not see an
# ACL-only change). Mutate the upgrade script (drop a REVOKE line, or a
# CREATE OR REPLACE) and the matching leg goes FAIL.
#
# Usage:  test/native_upgrade_converge.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

EXTDIR="$("$PGC_PG_CONFIG" --sharedir)/extension"
TARGET="$(sed -n "s/^default_version *= *'\\(.*\\)'.*/\\1/p" "$HERE/../pgcolumnar.control")"
check "control default_version is 1.0-alpha4" "$TARGET" "1.0-alpha4"

# Stage the frozen old base install scripts so an old-version extension can be
# created. These are fixtures, not shipped; remove them at the end.
STAGED=()
for v in 1.0-alpha 1.0-alpha2 1.0-alpha3; do
	src="$HERE/fixtures/pgcolumnar--$v.sql"
	dst="$EXTDIR/pgcolumnar--$v.sql"
	if [ -f "$src" ] && [ ! -f "$dst" ]; then
		cp "$src" "$dst"; STAGED+=("$dst")
	fi
done
cleanup() { for f in "${STAGED[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done; }
trap cleanup EXIT

# ---- each fixture must be what its tag actually shipped (#901) --------------
#
# THE FIXTURES ARE THE PREMISE OF EVERY ARM BELOW. This suite claims that each
# released starting point upgrades to the current catalog, and it can only claim
# that if the fixture IS the released starting point.
#
# They were made by renaming the root base script when the next cycle opened. A
# rename at cycle-open equals the release only if nothing touched the file between
# the tag and the rename, and for `1.0-alpha2` something did: two post-release
# `set_options` fixes. The fixture was the released script plus those, so this
# suite spent two cycles upgrading from a state no user ever had.
#
# Comparing BLOB IDS rather than diffing, because a blob id is a lookup. No
# similarity heuristic and no pathspec can distort it, and a rename-detection
# argument once turned a content-preserving move into a fabricated `R098` here.
#
# `1.0-alpha` IS DELIBERATELY ABSENT FROM THIS LIST, and that is the finding this
# check exists to stop being invisible. `v1.0-alpha` shipped
# `pgcolumnar--1.0-dev.sql` with `default_version = 1.0-dev`; there is no
# `pgcolumnar--1.0-alpha.sql` at that tag or any other. Its fixture is constructed
# rather than released, and it cannot be replaced by the real `1.0-dev` script:
# that script names the pre-rename C symbol and the current library does not
# export it.
#
#     ERROR:  could not find function "columnar_handler" in file "pgcolumnar.so"
#
# So no single-library test can start from a genuine `1.0-dev` or `1.0-alpha`
# install. The arm is kept because it is the only cover for the
# `1.0-dev--1.0-alpha` and `1.0-alpha--1.0-alpha2` upgrade scripts, which ship.
# What it tests is catalog shape, not a released artifact, and it is named that
# way rather than counted with the others.
_FX_TAGGED="1.0-alpha2 1.0-alpha3 1.0-alpha4"

_fx_git() { git -C "$HERE/.." "$@" 2>/dev/null; }
if ! _fx_git rev-parse --git-dir >/dev/null; then
	_fx_why="no git repository in the tree under test"
elif [ -z "$(_fx_git tag -l 'v1.0-alpha*')" ]; then
	# CI checks out at depth 1 with no tags, so this cannot run there. It runs
	# locally and in the five-major release gate, which is where a fixture is
	# captured and therefore where it can be captured wrongly.
	_fx_why="no release tags in this checkout"
else
	_fx_why=""
fi

for v in $_FX_TAGGED; do
	_fx_name="the $v fixture is byte-identical to what v$v shipped"
	if [ -n "$_fx_why" ]; then
		check_skip "$_fx_name" "SKIP  $_fx_name ($_fx_why)" "$_fx_why"
		continue
	fi
	_fx_tag="$(_fx_git rev-parse "v$v:pgcolumnar--$v.sql" || echo "no such path at v$v")"
	_fx_fix="$(_fx_git hash-object "$HERE/fixtures/pgcolumnar--$v.sql" || echo "fixture missing")"
	check "$_fx_name" "$_fx_fix" "$_fx_tag"
done

P() { env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -tAq "$@"; }

# Comprehensive catalog snapshot of the pgcolumnar schema, one line per object.
snap() {
	P -d "$1" -F'|' -c "
	  SELECT 'FN|'||p.oid::regprocedure||'|'||md5(pg_get_functiondef(p.oid))||'|'||coalesce(p.proacl::text,'(def)')||'|'||md5(coalesce(obj_description(p.oid,'pg_proc'),''))
	    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='pgcolumnar'
	  UNION ALL SELECT 'REL|'||c.relkind::text||'|'||c.relname||'|'||coalesce(c.relacl::text,'(def)')||'|'||md5(coalesce(obj_description(c.oid,'pg_class'),''))
	    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='pgcolumnar'
	  UNION ALL SELECT 'COL|'||c.relname||'.'||a.attname||'|'||format_type(a.atttypid,a.atttypmod)||'|'||a.attnotnull::text||'|'||md5(coalesce(col_description(c.oid,a.attnum),''))
	    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid
	    WHERE n.nspname='pgcolumnar' AND c.relkind IN ('r','p') AND a.attnum>0 AND NOT a.attisdropped
	  UNION ALL SELECT 'TYP|'||t.typname||'|'||t.typtype::text FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
	    WHERE n.nspname='pgcolumnar' AND t.typtype<>'b'
	  UNION ALL SELECT 'FDW|'||w.fdwname||'|'||coalesce(h.oid::regproc::text,'-')||'|'||coalesce(v.oid::regproc::text,'-')
	    FROM pg_foreign_data_wrapper w LEFT JOIN pg_proc h ON h.oid=w.fdwhandler LEFT JOIN pg_proc v ON v.oid=w.fdwvalidator
	    WHERE w.fdwname LIKE 'pgcolumnar%'
	  ORDER BY 1;" | sort
}

# Fresh install of the target version is the reference.
P -d postgres -c "DROP DATABASE IF EXISTS conv_fresh;" >/dev/null
P -d postgres -c "CREATE DATABASE conv_fresh;" >/dev/null
P -d conv_fresh -c "CREATE EXTENSION pgcolumnar VERSION '$TARGET';" >/dev/null
REF="$(mktemp)"; snap conv_fresh > "$REF"
check "fresh $TARGET install has objects to compare" \
	"$([ "$(wc -l <"$REF")" -gt 100 ] && echo yes || echo no)" "yes"

# Each released starting point must upgrade to an identical catalog.
for from in 1.0-alpha 1.0-alpha2 1.0-alpha3; do
	[ -f "$EXTDIR/pgcolumnar--$from.sql" ] || { check "fixture for $from present" "missing" "present"; continue; }
	db="conv_from_$(echo "$from" | tr '.-' '__')"
	P -d postgres -c "DROP DATABASE IF EXISTS $db;" >/dev/null
	P -d postgres -c "CREATE DATABASE $db;" >/dev/null
	P -d "$db" -c "CREATE EXTENSION pgcolumnar VERSION '$from';" >/dev/null
	err="$(P -d "$db" -c "ALTER EXTENSION pgcolumnar UPDATE TO '$TARGET';" 2>&1)"
	check "$from -> $TARGET upgrade applies without error" "${err:-OK}" "OK"
	check "$from is at $TARGET after upgrade" \
		"$(P -d "$db" -c "SELECT extversion FROM pg_extension WHERE extname='pgcolumnar';")" "$TARGET"
	got="$(mktemp)"; snap "$db" > "$got"
	d="$(diff "$REF" "$got" || true)"
	check "$from -> $TARGET converges to a fresh $TARGET catalog" "${d:-CONVERGED}" "CONVERGED"
	[ -n "$d" ] && { echo "---- divergence ($from) ----"; echo "$d" | head -40; echo "----"; }
	rm -f "$got"
	P -d postgres -c "DROP DATABASE IF EXISTS $db;" >/dev/null
done
rm -f "$REF"
P -d postgres -c "DROP DATABASE IF EXISTS conv_fresh;" >/dev/null

pgc_summary
