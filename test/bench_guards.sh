#!/usr/bin/env bash
#
# The benchmark's own guards (#465).
#
# bench/run_clickbench.sh publishes numbers. A benchmark that reports a failed
# load as a fast one is worse than a benchmark that does not run, because the
# number reaches documentation and nobody re-derives it.
#
# That is not hypothetical. pgcolumnar.parallel_copy prepares one transaction per
# worker, and the stock max_prepared_transactions is 0, so EVERY parallel arm
# errors out instantly. The first harness written against it printed those
# failures as
#
#     0.0s / 0.8s / 1.1s / 1.3s
#
# which is indistinguishable from perfect scaling, and is the shape a reader
# would publish. #465 records it.
#
# So the guards get a suite of their own, and it runs in the matrix even though
# the benchmark it guards does not: the benchmark needs a 15 GB download and a
# tuned cluster, while its arithmetic needs neither. Testing the decision without
# the dataset is the whole point of putting it in a file that can be sourced.
#
# Usage:  test/bench_guards.sh [PG_CONFIG]
# The argument is accepted and ignored; this suite needs no cluster.
# Written fresh for pgColumnar.
set -uo pipefail
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PGC_CHECKS=0
PGC_FAIL=0
check() {
	local name="$1" got="$2" want="$3"
	PGC_CHECKS=$((PGC_CHECKS + 1))
	if [ "$got" = "$want" ]; then
		echo "PASS  $name"
	else
		echo "FAIL  $name: got [$got] want [$want]"
		PGC_FAIL=1
	fi
}

GUARDS="$SRCDIR/bench/cb_guards.sh"
if [ ! -f "$GUARDS" ]; then
	echo "FAIL  bench/cb_guards.sh is missing, so the benchmark's guards are untestable"
	PGC_CHECKS=$((PGC_CHECKS + 1))
	PGC_FAIL=1
	echo; echo "checks run: $PGC_CHECKS"; echo "$(basename "$0"): FAILED"; exit 1
fi
# shellcheck source=/dev/null
. "$GUARDS"

echo "== pgColumnar test: $(basename "$0") =="

# ---- max_prepared_transactions must be preflighted, not discovered ----------
#
# Raising it needs a postmaster restart, so finding out during the load means the
# whole run is wasted. The guard has to answer before any arm is loaded.
check "the stock 0 is refused for an 8-worker parallel arm" \
	"$(cb_prepared_xacts_ok 0 8 && echo ok || echo refused)" "refused"
check "an exact match is accepted" \
	"$(cb_prepared_xacts_ok 8 8 && echo ok || echo refused)" "ok"
check "more than enough is accepted" \
	"$(cb_prepared_xacts_ok 16 8 && echo ok || echo refused)" "ok"
check "one short is refused, which is the off-by-one that would run 7 workers" \
	"$(cb_prepared_xacts_ok 7 8 && echo ok || echo refused)" "refused"

# A serial arm needs none, and must not be blocked by a setting it does not use.
check "a serial arm needs no prepared transactions" \
	"$(cb_prepared_xacts_ok 0 0 && echo ok || echo refused)" "ok"

# The message is the deliverable here: the operator has to know WHAT to set and
# that it costs a restart. A bare "failed" sends them to the load log, which
# reports a per-worker error and not the cause.
msg="$(cb_prepared_xacts_message 0 8)"
check "the message names the setting to change" \
	"$([ "$(grep -c 'max_prepared_transactions' <<<"$msg")" -ge 1 ] && echo yes || echo no)" "yes"
check "and the number it must reach" \
	"$([ "$(grep -c '8' <<<"$msg")" -ge 1 ] && echo yes || echo no)" "yes"
check "and says it needs a restart, which is why this runs first" \
	"$([ "$(grep -ci 'restart' <<<"$msg")" -ge 1 ] && echo yes || echo no)" "yes"

# ---- a load that lost rows is a failure, not a fast result ------------------
check "a short load is refused" \
	"$(cb_rows_ok 1999999 2000000 && echo ok || echo refused)" "refused"
check "an empty load is refused, which is what an errored parallel arm produces" \
	"$(cb_rows_ok 0 2000000 && echo ok || echo refused)" "refused"
check "an exact load is accepted" \
	"$(cb_rows_ok 2000000 2000000 && echo ok || echo refused)" "ok"
# Empty is not zero. A psql that failed produces neither.
#
# BOTH sides empty is the case that matters, and it is the only one of the three
# that a plain `[ "$got" = "$want" ]` gets wrong: one empty side is unequal to a
# number and is refused either way. The first version of this suite asserted only
# the one-sided cases, and a removal proof showed they passed with the numeric
# check deleted, which means they were testing nothing. That is the trap #418
# exists to forbid, met while writing the test for it.
check "two missing measurements are refused, not called equal" \
	"$(cb_rows_ok '' '' && echo ok || echo refused)" "refused"
check "a missing count is refused rather than compared with the expectation" \
	"$(cb_rows_ok '' 2000000 && echo ok || echo refused)" "refused"
check "and a missing expectation is refused too" \
	"$(cb_rows_ok 2000000 '' && echo ok || echo refused)" "refused"

echo
echo "checks run: $PGC_CHECKS"
if [ "$PGC_FAIL" != 0 ]; then
	echo "$(basename "$0"): FAILED"
	exit 1
fi
echo "$(basename "$0"): PASSED"
exit 0
