# ---- a check that could not run is a third state, not a pass ----------------
#
# WHY THIS EXISTS. Every check in this harness has two outcomes: it printed PASS
# or it printed FAIL. When a check's INPUT is absent -- a fixture that did not
# build, a capability the server lacks, a file the probe reads that is not there
# -- the check either passes vacuously or fails for a reason that has nothing to
# do with the property under test. Neither answer is true. The suite says
# "checks run: N" either way, and a reader counting greens counts one that never
# asked its question.
#
# That is the same defect as a permanent SKIP one level down: a skip you wrote is
# a check you did not write. `pgc_skip` already refuses to let a MISSING
# DEPENDENCY read as a pass -- it FAILS unless waived deliberately. This gives a
# single CHECK the same honesty at check granularity.
#
# THE STATE MUST NOT BE A PASS AT THE SUITE LEVEL EITHER, which is the whole
# point: a suite holding an unrunnable check exits PGC_EXIT_INCOMPLETE, not 0, so
# a runner cannot report it green. Failure still dominates -- a suite with both a
# FAIL and an UNRUN is FAILED, because the failure is the more urgent fact.
#
# WHY A NEW EXIT CODE AND NOT 66. 66 means "ran no checks". A suite with one
# unrunnable check DID run checks, and collapsing the two states would lose the
# distinction between "this suite is inert" and "this suite could not evaluate
# one thing". 67 is chosen on the same grounds 66 was: bash produces 1, 2, 126,
# 127 and 128+n; psql produces 1, 2, 3; make produces 1 and 2. And as with 66,
# the code alone is not trusted -- the runner must also see the INCOMPLETE line
# in the log, because `set -e` can propagate any status an aborting command
# returns.

_cur_lib="$PGC_TESTDIR/lib.sh"

check "premise: the harness library is where this part thinks it is" \
	"$([ -f "$_cur_lib" ] && echo yes || echo no)" "yes"

check "lib.sh defines check_unrunnable" \
	"$(grep -c '^check_unrunnable()' "$_cur_lib")" "1"

check "lib.sh defines the INCOMPLETE exit status" \
	"$(grep -c '^PGC_EXIT_INCOMPLETE=' "$_cur_lib")" "1"

# ---- the four states, each run as its own suite ----------------------------
#
# A source-shape fixture: it sources lib.sh and calls the primitives without
# pgc_setup, so no cluster is started and the four arms cost nothing. Each arm
# differs from the others in exactly one respect, so a single behaviour is under
# test in each.

_cur_dir="$PGC_WORKDIR/unrun"; mkdir -p "$_cur_dir"

_cur_make() {	# _cur_make NAME BODY
	{
		printf '#!/usr/bin/env bash\n'
		printf '. "%s"\n' "$_cur_lib"
		printf '%s\n' "$2"
		printf 'pgc_summary\n'
	} > "$_cur_dir/$1.sh"
	chmod 755 "$_cur_dir/$1.sh"
}

_cur_run() {	# _cur_run NAME -> "<exit> <verdict-word>"
	local out rc
	out="$(bash "$_cur_dir/$1.sh" 2>&1)"; rc=$?
	printf '%s %s' "$rc" "$(printf '%s' "$out" | grep -oE '(PASSED|FAILED|INCOMPLETE|SKIPPED)' | tail -1)"
}

_cur_out() {	# _cur_out NAME -> the whole output
	bash "$_cur_dir/$1.sh" 2>&1
}

_cur_make onlypass 'check "a" ok ok'
_cur_make passunrun 'check "a" ok ok
check_unrunnable "b" ABSENT_FIXTURE "the parquet corpus was not built"'
_cur_make failunrun 'check "a" ok NOPE
check_unrunnable "b" ABSENT_FIXTURE "the parquet corpus was not built"'
_cur_make onlyunrun 'check_unrunnable "b" ABSENT_FIXTURE "the parquet corpus was not built"'

check "a suite whose checks all passed still exits 0 PASSED" \
	"$(_cur_run onlypass)" "0 PASSED"

check "one unrunnable check makes the suite INCOMPLETE, not passed" \
	"$(_cur_run passunrun)" "67 INCOMPLETE"

# This arm reads "1 FAILED" whether or not check_unrunnable exists, because the
# fixture also holds a real failure -- so the exit code ALONE cannot distinguish
# the feature from its absence. Assert the accounting line instead, which only a
# suite that recorded BOTH states can print.
check "a failure outranks an unrunnable check, and both are still counted" \
	"$(_cur_out failunrun | grep -oE 'accounting: [0-9]+ passed \+ [0-9]+ failed \+ [0-9]+ unrunnable')" \
	"accounting: 0 passed + 1 failed + 1 unrunnable"

# The distinction 66 cannot carry: this suite RAN a check. Reporting it as
# "ran no checks" would merge "inert suite" with "could not evaluate one thing".
check "a suite of nothing but unrunnable checks is INCOMPLETE, not SKIPPED" \
	"$(_cur_run onlyunrun)" "67 INCOMPLETE"

check "and it is not reported as having run no checks" \
	"$(_cur_out onlyunrun | grep -c 'ran no checks')" "0"

# The reason travels with the state. A third state that does not say why is a
# skip with better manners.
check "the unrunnable check names itself, its reason code and its detail" \
	"$(_cur_out passunrun | grep -c '^UNRUN  b: ABSENT_FIXTURE: the parquet corpus was not built')" "1"

# Counting: an unrunnable check is still a check that was reached, so it counts
# toward the total, and it is reported separately so the total can be split.
check "an unrunnable check counts toward checks run" \
	"$(_cur_out passunrun | grep -oE 'checks run: [0-9]+' | grep -oE '[0-9]+')" "2"

check "and the unrunnable ones are reported as their own count" \
	"$(_cur_out passunrun | grep -oE 'checks unrunnable: [0-9]+' | grep -oE '[0-9]+')" "1"

check "a suite with none says so as zero rather than staying silent" \
	"$(_cur_out onlypass | grep -c 'checks unrunnable: 0')" "1"

# The reason is an enum plus a detail, not prose. Phase 3 has to group these, and
# a free-text reason would mean rewriting every call site later. A code outside
# the set is a FAILURE rather than a silent acceptance, so the enum cannot rot on
# first use by someone inventing a code.
_cur_make badcode 'check_unrunnable "b" NOT_A_REAL_CODE "x"'
check "an unrunnable reason outside the enum fails rather than being accepted" \
	"$(_cur_run badcode)" "1 FAILED"

# Every state is in a total, or it is a state that can go missing. 3,762 check
# sites is well past what anyone notices by reading.
check "the summary reconciles the three states against the total" \
	"$(_cur_out passunrun | grep -oE 'accounting: [0-9]+ passed \+ [0-9]+ failed \+ [0-9]+ unrunnable = [0-9]+')" \
	"accounting: 1 passed + 0 failed + 1 unrunnable = 2"

check "and a suite with no unrunnable checks reconciles too" \
	"$(_cur_out onlypass | grep -oE 'accounting: [0-9]+ passed \+ [0-9]+ failed \+ [0-9]+ unrunnable = [0-9]+')" \
	"accounting: 1 passed + 0 failed + 0 unrunnable = 1"

unset _cur_lib _cur_dir
unset -f _cur_make _cur_run _cur_out
