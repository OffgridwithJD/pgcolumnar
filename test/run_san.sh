#!/usr/bin/env bash
#
# The sanitizer gate (issue #224). The ordinary matrix is five assert builds, none
# instrumented, so a memory-safety defect that does not fault -- an unaligned load,
# an out-of-bounds read that lands inside the process -- passes green on all five.
# #225 was exactly that: an unaligned varlena-header read on the plain write path,
# benign on x86_64, that every one of the 92 suites passed with and without.
#
# This runs a subset of the suites against the ASAN+UBSAN build from
# test/build_san.sh, with sanitizer violations made fatal (UBSAN_OPTIONS and
# ASAN_OPTIONS abort_on_error), so a violation kills the backend and turns its
# suite red rather than printing a line nobody reads. The subset is the write,
# read, encode, and import/decode paths, where the hand-rolled buffer walks live;
# all 92 suites on five majors are neither needed nor affordable under
# instrumentation.
#
# Prove it works the way #224 asks: revert the fix it guards (columnar.h,
# ColumnarVarSizeAnyUnaligned back to the direct 4-byte cast), rebuild, and this
# gate goes red while the ordinary matrix stays green.
#
# Usage:  test/run_san.sh [SAN_PREFIX]      (default /usr/local/pg18_san)
#   PGC_SAN_SUITES=<list>   override the suite subset
#   PGC_SAN_FUZZ_ITERS=<n>  fuzzer mutants under sanitizers (default 200)
#
set -uo pipefail

SAN="${1:-/usr/local/pg18_san}"
PGCONF="$SAN/bin/pg_config"
if [ ! -x "$PGCONF" ]; then
	echo "FAIL  no sanitizer build at $SAN; run test/build_san.sh first"
	exit 1
fi

# A sanitizer violation must abort the backend, not print and continue: that is
# what turns it into a suite failure. detect_leaks/stack_use_after_return are the
# by-design tool leaks and initdb trip from build_san.sh, kept off here too.
export ASAN_OPTIONS="detect_leaks=0:detect_stack_use_after_return=0:abort_on_error=1:print_stacktrace=1"
export UBSAN_OPTIONS="halt_on_error=1:abort_on_error=1:print_stacktrace=1"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "-- building the extension instrumented against $SAN"
make -s clean >/dev/null 2>&1 || true
if ! make -s PG_CONFIG="$PGCONF" install > /tmp/run-san-ext.log 2>&1; then
	echo "FAIL  extension build against the sanitizer PostgreSQL"
	tail -20 /tmp/run-san-ext.log
	exit 1
fi

FUZZ_ITERS="${PGC_SAN_FUZZ_ITERS:-200}"
SUITES="${PGC_SAN_SUITES:-smoke native_writer native_roundtrip native_encoding \
	native_zonemap write_fsst_compressed write_minmax_fastpath encode_effort \
	native_dml native_skip native_fetch_position native_fetch_cache \
	arrow_import arrow_export parquet_import parquet_export native_read_parquet \
	native_parquet_schema hardening corruption differential fuzz_arrow fuzz_parquet}"

echo "-- running the subset under ASAN+UBSAN (fatal)"
fail=0
ran=0
for s in $SUITES; do
	if [ ! -f "test/$s.sh" ]; then
		echo "  SKIP  $s (no such suite)"
		continue
	fi
	ran=$((ran + 1))
	out="$(PGC_SKIP_BUILD=1 PGC_ITERS="$FUZZ_ITERS" timeout 900 \
		bash "test/$s.sh" "$PGCONF" 2>&1)"
	rc=$?
	# A sanitizer report reaches here two ways: the backend aborts (SIGABRT, so the
	# suite's own crash checks or a nonzero rc), or the text appears in the output.
	san="$(printf '%s' "$out" | grep -icE 'runtime error:|AddressSanitizer|UndefinedBehaviorSanitizer|SUMMARY: .*Sanitizer|terminated by signal 6')"
	if [ "$rc" != 0 ] || [ "$san" != 0 ]; then
		fail=$((fail + 1))
		echo "  FAIL  $s  (rc=$rc, sanitizer_lines=$san)"
		printf '%s\n' "$out" | grep -iE 'runtime error:|AddressSanitizer|SUMMARY: .*Sanitizer|FAIL' | head -4 | sed 's/^/        /'
	else
		echo "  PASS  $s"
	fi
done

echo "-- $ran suites under sanitizers, $fail failed"
if [ "$fail" = 0 ]; then
	echo "SANITIZER GATE PASSED"
else
	echo "SANITIZER GATE FAILED"
fi
exit "$fail"
