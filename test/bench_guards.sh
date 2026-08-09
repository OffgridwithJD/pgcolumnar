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

# ---- max_worker_processes, the other setting that costs a restart -----------
#
# parallel_copy registers one background worker per loader, plus a coordinator,
# and the logical replication launcher already holds one slot. So an N-worker arm
# needs N + 2, not N. The stock default is 8, which is why an 8-worker arm fails
# at "could not register pgcolumnar parallel_copy loader 7 of 8" and leaves an
# EMPTY table -- a fast, wrong, publishable-looking result.
#
# N + 2 is measured, not reasoned. Sweeping max_worker_processes against three
# worker counts on the bench, the smallest value that loaded every row was:
#
#     workers 2 -> 4      workers 4 -> 6      workers 8 -> 10
#
# and one below each failed on the LAST loader with the table left empty.
check "the stock 8 is refused for an 8-worker arm, which is the case that bit us" \
	"$(cb_worker_slots_ok 8 8 && echo ok || echo refused)" "refused"
check "N + 1 is still refused: the coordinator needs a slot too" \
	"$(cb_worker_slots_ok 9 8 && echo ok || echo refused)" "refused"
check "N + 2 is accepted, the measured minimum" \
	"$(cb_worker_slots_ok 10 8 && echo ok || echo refused)" "ok"
check "more than enough is accepted" \
	"$(cb_worker_slots_ok 32 8 && echo ok || echo refused)" "ok"
check "the rule holds at another worker count (4 needs 6)" \
	"$(cb_worker_slots_ok 6 4 && echo ok || echo refused)" "ok"
check "and one below it does not" \
	"$(cb_worker_slots_ok 5 4 && echo ok || echo refused)" "refused"

# A serial arm registers no workers at all.
check "a serial arm needs no worker slots" \
	"$(cb_worker_slots_ok 0 0 && echo ok || echo refused)" "ok"

# Non-numeric input must be refused rather than compared. A psql that failed
# yields an empty string, and "" -ge "" is not a comparison anyone wants.
check "a missing current value is refused, not compared" \
	"$(cb_worker_slots_ok "" 8 && echo ok || echo refused)" "refused"

wmsg="$(cb_worker_slots_message 8 8)"
check "the worker-slot message names the setting" \
	"$([ "$(grep -c 'max_worker_processes' <<<"$wmsg")" -ge 1 ] && echo yes || echo no)" "yes"
check "and the value it must reach, not merely the worker count" \
	"$([ "$(grep -c '10' <<<"$wmsg")" -ge 1 ] && echo yes || echo no)" "yes"
check "and says it needs a restart" \
	"$([ "$(grep -ci 'restart' <<<"$wmsg")" -ge 1 ] && echo yes || echo no)" "yes"

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

# ---- a report must not claim a cold run it did not perform (#506) ----------
#
# The old harness tested [ -w /proc/sys/vm/drop_caches ], fell back to sudo, and
# otherwise did nothing at all, silently -- while the report printed the
# lukewarm-cold-run tag unconditionally. An unprivileged container is exactly
# such a host: the file belongs to a uid outside the namespace and refuses even
# the container's own root. So the run published a protocol claim it had not met.
#
# The claim is the deliverable being guarded here, not the drop. Whether a given
# kernel permits the drop is not something a matrix suite can decide; whether the
# report is honest about what happened is pure arithmetic, and belongs here.
tag_none="$(cb_cold_tag none 2>/dev/null)"
# Assert the premise, because the negative check below is vacuous without it: an
# absent cb_cold_tag yields an empty string, an empty string does not contain
# "lukewarm-cold-run", and "the run was not called cold" therefore PASSES against
# no implementation whatever. Seen, not reasoned about -- it passed exactly that
# way on the first red run of this suite.
check "premise: the guard exists and emitted a tag to judge" \
	"$([ -n "$tag_none" ] && echo yes || echo no)" "yes"
check "a host that could not drop the page cache is not called a cold run" \
	"$(grep -qi 'lukewarm-cold-run' <<<"$tag_none" && echo claimed || echo not-claimed)" \
	"not-claimed"
# Matched case-sensitively and as WARM-RUN rather than as "warm": the string
# "lukewarm-cold-run" contains "warm", so a loose match would pass on precisely
# the wrong output this check exists to catch.
check "and the tag says plainly that the run was warm" \
	"$(grep -q 'WARM-RUN' <<<"$tag_none" && echo yes || echo no)" "yes"

# ---- a win is decided on the times, not on the printed string (#531) --------
#
# The defect: the report counted wins from the "%.2f" ratio it had already
# formatted for the table, so columnar ahead by less than half a percent printed
# 1.00, failed `r < 1`, and was counted a LOSS -- against the legend printed
# directly above it. The 2026-08-09 run reported 33 wins and 10 losses where the
# times give 36 and 7.
#
# The three numbers below are that run's q13, the smallest real case: heap
# 1588.095 ms, columnar 1582.859 ms, and a warm-try scatter of 0.99 percent.
check "premise: the verdict helpers are present to be judged" \
	"$(type -t cb_verdict)/$(type -t cb_warm_spread)/$(type -t cb_band)" \
	"function/function/function"

check "a clear win is a win" "$(cb_verdict 500 1000 0.02)" "win"
check "a clear loss is a loss" "$(cb_verdict 2000 1000 0.02)" "loss"
# The regression case, stated as the defect: rounding to 1.00 must not flip the
# sign of the verdict. With no band this is a win; it must never be a loss.
check "columnar ahead by 0.33 percent is not a LOSS, which is the #531 defect" \
	"$(cb_verdict 1582.859 1588.095 0.0000)" "win"
check "and under a band wider than the gap it is a tie, not a win either" \
	"$(cb_verdict 1582.859 1588.095 0.0099)" "tie"
check "a gap just outside the band is still called" \
	"$(cb_verdict 900 1000 0.05)" "win"
check "and a loss just outside it likewise" \
	"$(cb_verdict 1100 1000 0.05)" "loss"

# Scatter is measured from the tries, and an unknown scatter must not read as
# zero: "-" through cb_band must suppress the verdict rather than license a
# strict comparison on an arm nobody measured twice.
check "spread is the fractional range over the best" "$(cb_warm_spread 100 103)" "0.0300"
check "order does not matter, and ERR tries are dropped" \
	"$(cb_warm_spread 103 100 ERR)" "0.0300"
check "a single warm try has no measurable scatter" "$(cb_warm_spread 100)" "0.0000"
check "no usable try yields no spread, not zero" "$(cb_warm_spread '' ERR)" "-"
check "a zero best is refused rather than divided by" "$(cb_warm_spread 0 5)" "-"
check "the band is the wider of the two arms" "$(cb_band 0.0100 0.0290)" "0.0290"
check "and is unknown if either arm is unknown" "$(cb_band - 0.0290)" "-"
check "an unknown band suppresses the verdict, it does not strict-compare" \
	"$(cb_verdict 1582.859 1588.095 -)" "-"
check "an errored arm has no verdict" "$(cb_verdict ERR 1000 0.02)" "-"
check "and neither does a zero baseline" "$(cb_verdict 500 0 0.02)" "-"

echo
echo "checks run: $PGC_CHECKS"
if [ "$PGC_FAIL" != 0 ]; then
	echo "$(basename "$0"): FAILED"
	exit 1
fi
echo "$(basename "$0"): PASSED"
exit 0
