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
pgc_summary
