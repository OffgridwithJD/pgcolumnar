#!/usr/bin/env bash
#
# The object-store module's packaging and loader (#393).
#
# The module is a SEPARATE, non-preloaded shared library, because pgColumnar loads
# through shared_preload_libraries and anything the main library links is mapped into
# the postmaster and inherited by every backend. This suite asserts that separation
# holds, because it is the property the whole design rests on and it is easy to lose
# by accident: adding one object to the main OBJS list would undo it silently.
#
# It also asserts a remote path reports a remote error. Before this, s3://bucket/key
# reached AllocateFile and reported "No such file or directory", which is true of the
# filesystem and useless to the reader.
#
# Usage:  test/objstore_module.sh [PG_CONFIG]
# Written fresh for pgColumnar.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

LIBDIR="$("$PGC_PG_CONFIG" --pkglibdir 2>/dev/null || echo "")"
[ -n "$LIBDIR" ] || LIBDIR="$(pgc_pg "pg_config --pkglibdir" | tr -d '\r')"

check "the main library is installed" \
	"$(pgc_pg "test -f '$LIBDIR/pgcolumnar.so' && echo yes || echo no")" "yes"
check "the object-store module is installed BESIDE it, not inside it" \
	"$(pgc_pg "test -f '$LIBDIR/pgcolumnar_objstore.so' && echo yes || echo no")" "yes"

# The property the design rests on. If someone adds the module's objects to the main
# OBJS list, this is what notices.
check "the module is a separate file, so nothing it links reaches the postmaster" \
	"$(pgc_pg "readelf -d '$LIBDIR/pgcolumnar.so' | grep -c pgcolumnar_objstore" | tail -1)" "0"
check "and the module exports its single entry point" \
	"$(pgc_pg "nm -D --defined-only '$LIBDIR/pgcolumnar_objstore.so' | grep -c ' T pgcolumnar_objstore_init'")" "1"

# A remote path must report a remote error, from the reader, without a connection.
for url in "s3://bucket/key.parquet" "gs://bucket/key.parquet" "https://host/key.parquet"; do
	out=$(psql_run "SELECT * FROM pgcolumnar.read_parquet('$url') AS (a int)" 2>&1)
	check "a $(cut -d: -f1 <<<"$url") URL reports an object-storage error, not a missing file" \
		"$([ "$(grep -c 'object storage is not implemented\|is not supported' <<<"$out")" -ge 1 ] && echo yes || echo no)" "yes"
	check "and does NOT report it as a missing file" \
		"$(grep -c 'No such file or directory' <<<"$out")" "0"
done

# A local path must be entirely unaffected, which is the regression this could cause.
psql_run "CREATE TABLE lp (a int) USING pgcolumnar; INSERT INTO lp VALUES (1),(2),(3);" >/dev/null 2>&1
check "a local path still works" "$(q 'SELECT count(*) FROM lp')" "3"
check "a relative path is not mistaken for a URL" \
	"$(psql_run "SELECT * FROM pgcolumnar.read_parquet('/nonexistent/x.parquet') AS (a int)" 2>&1 |
	   grep -c 'No such file or directory\|could not open')" "1"
MOD="$LIBDIR/pgcolumnar_objstore.so"
# The arms below MOVE the installed module. That needs write permission on its
# directory, which the suite has when it runs as the installing user and may not
# otherwise. Skip visibly rather than fail: a suite that cannot perform its
# manipulation has not found a defect, and a red gate here would be about the
# environment.
#
# This suite also runs ALONE in the matrix, because the file it moves is shared with
# every other suite in the run.
if ! mv "$MOD" "$MOD.probe" 2>/dev/null; then
	echo "SKIP  cannot move $MOD, so the absent and broken paths are untested here"
	pgc_summary
	exit 0
fi
mv "$MOD.probe" "$MOD" 2>/dev/null

# ---- the module ABSENT, which is a supported configuration --------------------
#
# Two things this asserts, both of which were wrong before:
#
#  1 a missing module must report the remote path as unsupported, not
#    'could not access file "pgcolumnar_objstore"'. signalNotFound = false
#    suppresses a missing SYMBOL; a missing LIBRARY is raised earlier by
#    internal_load_library and needs a PG_TRY.
#
#  2 the SAME query must give the SAME error twice in one session. The cache flag
#    used to be set before the load, so the ereport unwound past the assignment
#    while the static kept its new value: the first read reported the raw load
#    failure and every later one reported the documented message. Two identical
#    queries, one session, two different errors, the second one plausible.
#
# Both reads run in ONE psql session on purpose. Separate sessions cannot see it.
Q="SELECT * FROM pgcolumnar.read_parquet('s3://bucket/key.parquet') AS (a int)"
two_reads() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" \
		-At -q -c "$Q" -c "$Q" 2>&1
}

both=$(two_reads)
check "with the module present, both reads report the same thing" \
	"$(grep -c 'is not implemented yet\|is not supported' <<<"$both")" "2"

mv "$MOD" "$MOD.away" 2>/dev/null
absent=$(two_reads)
mv "$MOD.away" "$MOD" 2>/dev/null
check "premise: the module really was absent for that run" \
	"$([ -f "$MOD" ] && echo restored || echo MISSING)" "restored"
check "with the module absent, neither read leaks the loader's own error" \
	"$(grep -c 'could not access file' <<<"$absent")" "0"
check "and both reads report the SAME unsupported error" \
	"$(grep -c 'is not supported' <<<"$absent")" "2"

# ---- installed but BROKEN is not the same as not installed --------------------
#
# Only "not installed" is supported. A truncated library or a permission problem is the
# operator's to fix, and reporting it as an unsupported scheme sends them elsewhere.
#
# TWO premises, because the first version of this test had neither and passed while doing
# nothing:
#   1 the module must actually BE corrupt during the run. Overwriting it in place fails
#     silently: it is root-owned 0755 and this runs as postgres, which can write the
#     DIRECTORY but not that file. So move it aside and CREATE a new one.
#   2 the SQLSTATE cannot be used to tell the two cases apart. internal_load_library uses
#     errcode_for_file_access() for both the stat failure and the dlopen failure, so
#     missing and "file too short" both arrive as 58P01. Measured. The check is on file
#     presence for that reason.
mv "$MOD" "$MOD.away" 2>/dev/null && printf 'not a shared object' > "$MOD" 2>/dev/null
check "premise: the module really is corrupt for this run, not merely intended to be" \
	"$(stat -c %s "$MOD" 2>/dev/null)" "19"
broken=$(two_reads)
rm -f "$MOD" 2>/dev/null; mv "$MOD.away" "$MOD" 2>/dev/null
check "premise: the real module was restored afterwards" \
	"$([ "$(stat -c %s "$MOD" 2>/dev/null || echo 0)" -gt 1000 ] && echo yes || echo no)" "yes"
check "a broken module does NOT masquerade as an unsupported scheme" \
	"$(grep -c 'is not supported' <<<"$broken")" "0"
check "and the loader's own reason survives" \
	"$([ "$(grep -ci 'could not load library' <<<"$broken")" -ge 1 ] && echo yes || echo no)" "yes"

pgc_summary
