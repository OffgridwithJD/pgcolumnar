#!/usr/bin/env bash
#
# Compile the extension against every installed major.
#
# The per-PR gate runs the suites on two majors, which is the right trade for
# test time and cannot see a defect on a major it never builds. That is not
# hypothetical: scan_analyze_next_block changed signature at PG17, a change
# guarded the callback at PG18 instead, and PG15, PG16, PG18 and PG19 all built
# fine while main did not compile on PG17 at all. A two-major gate reported it
# green.
#
# This is the cheap half of the answer: no clusters, no suites, just a compile
# against each major, which takes about a minute for all five. Run it before
# merging anything that touches a version guard, a table AM callback signature,
# or columnar_compat.h. The full matrix remains the thorough half.
#
# Usage:
#   test/build_all_versions.sh [pg_config ...]
#
# With no arguments it builds against the same default set the version matrix
# uses. Exits non-zero on the first major that fails, and prints its errors.

set -uo pipefail

SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULT_CONFIGS=(
	/usr/local/pg15/bin/pg_config
	/usr/local/pg16/bin/pg_config
	/usr/local/pg17/bin/pg_config
	/usr/local/pgsql/bin/pg_config
	/usr/local/pg19/bin/pg_config
)

if [ "$#" -gt 0 ]; then
	CONFIGS=("$@")
else
	CONFIGS=("${DEFAULT_CONFIGS[@]}")
fi

echo "== pgColumnar build check across majors =="

failed=0
for pgc in "${CONFIGS[@]}"; do
	if [ ! -x "$pgc" ]; then
		printf '  SKIP  %-34s (not executable)\n' "$pgc"
		continue
	fi

	ver="$("$pgc" --version)"
	log="$(mktemp /tmp/pgc-build-XXXXXX.log)"

	make -C "$SRCDIR" clean PG_CONFIG="$pgc" >/dev/null 2>&1
	if make -C "$SRCDIR" PG_CONFIG="$pgc" > "$log" 2>&1; then
		# -Werror is not set, so a warning still builds; report it rather than
		# let a new one accumulate unnoticed across majors.
		warns="$(grep -cE '^[^ ].*\bwarning:' "$log")"
		printf '  OK    %-34s %s warning(s)\n' "$ver" "$warns"
		[ "$warns" != "0" ] && grep -E '^[^ ].*\bwarning:' "$log" | head -5 | sed 's/^/          /'
	else
		printf '  FAIL  %s\n' "$ver"
		grep -E '\berror:' "$log" | head -8 | sed 's/^/          /'
		failed=1
	fi
	rm -f "$log"
done

# Leave no object tree behind from whichever major happened to be last: the next
# build against a different major would link objects compiled for this one.
make -C "$SRCDIR" clean >/dev/null 2>&1 || true

if [ "$failed" != "0" ]; then
	echo "build_all_versions.sh: FAILED"
	exit 1
fi
echo "build_all_versions.sh: PASSED"
