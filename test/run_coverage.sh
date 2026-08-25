#!/usr/bin/env bash
#
# Line and branch coverage over the suites, for one major.
#
# A discovery tool, not a gate. There is no threshold here and nothing in CI
# fails on the number, deliberately. A coverage threshold creates pressure to
# write tests that execute lines rather than tests that prove properties, and the
# assertions in this project's suites are the reason its defects get found. What
# the report answers is the complementary question a passing suite cannot: which
# code does nothing execute at all. For hand-rolled Parquet and Arrow decoders
# full of error paths, that is worth knowing.
#
# Expect the percentage to look unremarkable and expect that to be correct. A
# table access method carries defensive branches that should never be taken and
# columnar_compat.h carries version shims of which only one arm compiles per
# major. Read the report for holes, not for the number.
#
# Why the suites are driven directly rather than through run_all_versions.sh: the
# matrix builds its own copy of the tree in a temporary directory and removes it
# when the major finishes, which takes the .gcda counters with it. Coverage has to
# accumulate next to the objects it was compiled from, so this builds once in the
# working tree, installs that build, and runs every suite against it with
# PGC_SKIP_BUILD=1.
#
# Usage:  test/run_coverage.sh [PG_CONFIG]
#   PGC_COV_SUITES=<list>   override the suite list
#   PGC_COV_OUT=<dir>       output directory (default coverage/)
#
# Written fresh for pgColumnar.

set -uo pipefail

PGC="${1:-/usr/local/pg17/bin/pg_config}"
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${PGC_COV_OUT:-$SRCDIR/coverage}"

command -v lcov >/dev/null || { echo "FAIL  lcov not found" >&2; exit 1; }
command -v genhtml >/dev/null || { echo "FAIL  genhtml not found" >&2; exit 1; }
[ -x "$PGC" ] || { echo "FAIL  no pg_config at $PGC" >&2; exit 1; }

echo "== coverage: $("$PGC" --version)"

# COPT reaches both CFLAGS and LDFLAGS through PostgreSQL's Makefile.global, so
# one variable instruments the compile and links the runtime.
echo "-- build with --coverage"
make -C "$SRCDIR" clean >/dev/null 2>&1
if ! make -C "$SRCDIR" PG_CONFIG="$PGC" COPT="--coverage" >/dev/null 2>"$OUT.build.err"; then
	echo "FAIL  instrumented build failed" >&2
	tail -20 "$OUT.build.err" >&2
	exit 1
fi
make -C "$SRCDIR" PG_CONFIG="$PGC" COPT="--coverage" install >/dev/null 2>&1 || {
	echo "FAIL  install failed" >&2; exit 1; }

# Every suite except the drivers, the libraries, and the ones that build their
# own server or need two majors. Kept in step with harness_selftest.sh's list.
#
# The two upgrade suites are excluded TOGETHER, and that pairing is the point
# (#741). run_all_versions.sh gates both behind PGC_RUN_UPGRADE, in one block and
# for one reason: they build a second copy of the extension and need an old
# source this runner has no way to supply. pg_upgrade was excluded here when it
# was written and extension_upgrade was not, so this runner discovered it, ran it
# with no old source, and its ref fallback could not resolve in a tagless CI
# checkout. run_coverage maps only rc 66 to SKIP, so that environment shortfall
# was counted as a failed suite and the nightly read "1 failed
# ( extension_upgrade)" every night while nothing was wrong with the product.
#
# Deciding to run an opt-in guard is run_all_versions.sh's job, not this one's.
# test/selftest/220 derives the gated list from that block and asserts every name
# in it is refused here, so a third upgrade suite cannot repeat this.
not_a_suite() {
	case "$1" in
		lib|portlib|run_all_versions|build_all_versions|devloop|rebuild) return 0 ;;
		native_scale|build_san|run_san|run_coverage) return 0 ;;
		pg_upgrade|extension_upgrade) return 0 ;;
		*) return 1 ;;
	esac
}

SUITES="${PGC_COV_SUITES:-}"
if [ -z "$SUITES" ]; then
	for f in "$SRCDIR"/test/*.sh; do
		n="$(basename "$f" .sh)"
		not_a_suite "$n" && continue
		SUITES="$SUITES $n"
	done
fi

mkdir -p "$OUT"
lcov --directory "$SRCDIR/src" --zerocounters >/dev/null 2>&1

# Below the ephemeral floor, like every other port in this tree (portlib.sh).
. "$SRCDIR/test/portlib.sh"
port="$(pgc_pick_port)"

pass=0; fail=0; failed=""; skip=0; skipped=""
for s in $SUITES; do
	port=$((port + 1))
	# PGC_SKIP_TIMING, because a --coverage build is instrumented and its wall
	# clock means nothing. The wall-clock suites assert ratios and absolute
	# timeouts; run here without the flag they fail for the instrumentation rather
	# than for the code, and this runner discovers every test/*.sh including any
	# added later. The matrix is where those numbers are taken.
	PGC_SKIP_BUILD=1 PGC_SKIP_TIMING=1 PGC_PORT="$port" \
		bash "$SRCDIR/test/${s}.sh" "$PGC" >"$OUT/${s}.log" 2>&1
	rc=$?
	if [ "$rc" = 0 ]; then
		pass=$((pass + 1))
	elif [ "$rc" = 66 ] && grep -q 'SKIPPED (ran no checks)' "$OUT/${s}.log" 2>/dev/null; then
		# Ran no checks (#447). It contributed no coverage either, so counting it
		# as a pass overstates what this report measured.
		skip=$((skip + 1)); skipped="$skipped $s"
	else
		fail=$((fail + 1)); failed="$failed $s"
	fi
done
echo "-- suites: $pass passed, $fail failed${failed:+ ($failed)}, $skip skipped${skipped:+ ($skipped)}"
# A coverage report built from nothing is not a coverage report. run_san grew this
# guard and this runner did not, so its only verdict was "nothing failed" -- which
# a box where every suite aborts satisfies perfectly.
if [ "$pass" = 0 ]; then
	echo "-- NO SUITE RAN, so this measures no coverage"
	fail=$((fail + 1))
fi

echo "-- collect"
lcov --directory "$SRCDIR/src" --capture --output-file "$OUT/coverage.info" \
	--rc branch_coverage=1 --ignore-errors inconsistent >/dev/null 2>&1 || {
		echo "FAIL  lcov capture produced nothing" >&2; exit 1; }
# Only this project's sources; PostgreSQL's headers are not what is being measured.
lcov --extract "$OUT/coverage.info" "$SRCDIR/src/*" \
	--output-file "$OUT/coverage.info" --rc branch_coverage=1 \
	--ignore-errors inconsistent >/dev/null 2>&1

# --ignore-errors inconsistent, and only that one. lcov 2.x rejects a tracefile
# when gcov reports a line as hit while recording no evaluated branches on it,
# which gcc emits routinely for lines carrying compiler-generated branches. It is
# an artifact of the two tools' disagreement rather than bad data. "corrupt" is
# deliberately not bypassed: that one would hide a genuinely unreadable file.
genhtml "$OUT/coverage.info" --output-directory "$OUT/html" \
	--branch-coverage --legend --ignore-errors inconsistent >/dev/null 2>&1 || {
		echo "FAIL  genhtml failed" >&2; exit 1; }

echo
lcov --summary "$OUT/coverage.info" --rc branch_coverage=1 \
	--ignore-errors inconsistent 2>&1 | grep -vE "^(Reading|lcov: (WARNING|Note))" | sed 's/^/  /'
echo
echo "-- per file, least covered first"
lcov --list "$OUT/coverage.info" --rc branch_coverage=1 \
	--ignore-errors inconsistent 2>/dev/null \
	| awk '/\|/ && !/Total:/ && !/^Filename/ {print}' \
	| sort -t'|' -k2 -n | head -20 | sed 's/^/  /'
echo
echo "report: $OUT/html/index.html"

# The suites failing is worth a non-zero exit; the coverage number never is.
[ "$fail" = 0 ]
