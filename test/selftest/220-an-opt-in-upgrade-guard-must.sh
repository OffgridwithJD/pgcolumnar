# ---- an opt-in upgrade guard must run somewhere, and not in the wrong runner --
#
# #741. test/extension_upgrade.sh is the guard for the break that is invisible
# until a user upgrades, and in CI it had never verified an upgrade. Two separate
# defects, which is why there are two groups of checks here.
#
# 1. run_all_versions.sh gates both upgrade suites behind PGC_RUN_UPGRADE, and
#    run_coverage.sh's not_a_suite() excluded pg_upgrade but not
#    extension_upgrade. So the coverage runner discovered it and ran it with no
#    old source, its ref fallback could not resolve in a tagless CI checkout, and
#    run_coverage counted the environment shortfall as a failed suite. The
#    nightly read "1 failed ( extension_upgrade)" every night.
#
# 2. Nothing in .github/workflows set PGC_RUN_UPGRADE or invoked the suite, so
#    the guard never actually ran anywhere. That is the failure mode #257 exists
#    to close, and the comment at run_all_versions.sh:856-860 is about the last
#    time it happened to this same suite (#396).
#
# The opt-in suites are DERIVED from run_all_versions.sh rather than named here.
# A third one added to that block is then covered by this check on the day it is
# added, which a hand-maintained list of two names cannot do.

_upg_block() {	# the suites run_all_versions invokes only under PGC_RUN_UPGRADE
	awk '/if \[ "\$\{PGC_RUN_UPGRADE:-0\}" = 1 \]; then/,/^fi$/' \
		"$TESTDIR/run_all_versions.sh" |
		grep -oE 'test/[a-z_]+\.sh' | sed 's|test/||; s|\.sh$||' | sort -u
}
_upg_optin="$(_upg_block)"

check "premise: the PGC_RUN_UPGRADE block was found and names at least one suite" \
	"$([ -n "$_upg_optin" ] && echo yes || echo no)" "yes"
echo "-- opt-in upgrade suites, derived: $(echo $_upg_optin)"

# not_a_suite is the thing under test, so it is evaluated rather than grepped.
# Its call site is asserted separately: a function nothing calls would pass every
# check below while the runner went on discovering the suite anyway.
check "premise: run_coverage.sh defines not_a_suite and calls it" \
	"$([ "$(grep -c '^not_a_suite()' "$TESTDIR/run_coverage.sh")" -ge 1 ] &&
	   [ "$(grep -c 'not_a_suite "\$n"' "$TESTDIR/run_coverage.sh")" -ge 1 ] &&
	   echo yes || echo no)" "yes"

_upg_refuses() {	# 0 when run_coverage.sh's not_a_suite refuses $1
	( eval "$(sed -n '/^not_a_suite()/,/^}/p' "$TESTDIR/run_coverage.sh")"
	  not_a_suite "$1" )
}

# The instrument must be able to say both things, or "nothing was missed" is not
# evidence. A name that is plainly a suite must NOT be refused.
check "premise: not_a_suite says no to an ordinary suite, so its yes means something" \
	"$(_upg_refuses smoke && echo refused || echo run)" "run"

_upg_missing=""
for _u in $_upg_optin; do
	_upg_refuses "$_u" || _upg_missing="$_upg_missing $_u"
done
check "every PGC_RUN_UPGRADE-gated suite is excluded from the coverage runner (#741)" \
	"$(printf '%s' "$_upg_missing" | sed 's/^ //')" ""

# ---- and the guard must actually be run by something ------------------------
#
# Premised on the workflow directory being non-empty, because a population that
# is empty makes the search below pass without looking at anything.
_upg_wfdir="$TESTDIR/../.github/workflows"
_upg_wfcount=$(ls "$_upg_wfdir"/*.yml 2>/dev/null | wc -l)
check "premise: there are workflow files to search" \
	"$([ "$_upg_wfcount" -ge 1 ] && echo yes || echo no)" "yes"

# An invocation, not a mention: a commented-out line naming the suite would
# otherwise satisfy this and the guard would still never run.
_upg_ci=$(grep -rhE '^[^#]*(extension_upgrade\.sh|PGC_RUN_UPGRADE=1)' \
	"$_upg_wfdir"/*.yml 2>/dev/null | wc -l)
check "CI runs the extension-upgrade guard somewhere (#741)" \
	"$([ "$_upg_ci" -ge 1 ] && echo yes || echo no)" "yes"

# ---- and the two not_a_suite lists must actually agree ----------------------
#
# There are two copies of this list, and run_coverage.sh's own comment says it is
# "Kept in step with harness_selftest.sh's list". It was not: the selftest copy
# in 040 already named extension_upgrade and run_coverage's did not, which is the
# whole of #741's second half. A comment claiming two things agree is not a
# mechanism that makes them agree.
#
# So the claim is asserted over the WHOLE population of test files rather than
# for the two names that happened to drift, and in both directions. A name either
# copy would treat differently is a failure whichever copy is wrong, which is
# what makes this able to catch the next drift rather than this one.
#
# Both functions are extracted from their files and evaluated, so this compares
# what the runners will actually do, not two pieces of source text that look
# alike.
_upg_fn_cov="$(sed -n '/^not_a_suite()/,/^}/p' "$TESTDIR/run_coverage.sh")"
_upg_fn_self="$(sed -n '/^not_a_suite()/,/^}/p' "$TESTDIR"/selftest/040-*.sh)"

check "premise: both not_a_suite definitions were found" \
	"$([ -n "$_upg_fn_cov" ] && [ -n "$_upg_fn_self" ] && echo yes || echo no)" "yes"

_upg_pop=0
_upg_disagree=""
for _f in "$TESTDIR"/*.sh; do
	_b="$(basename "$_f" .sh)"
	_upg_pop=$((_upg_pop + 1))
	_c=$( ( eval "$_upg_fn_cov";  not_a_suite "$_b" ) && echo excl || echo run )
	_s=$( ( eval "$_upg_fn_self"; not_a_suite "$_b" ) && echo excl || echo run )
	[ "$_c" = "$_s" ] || _upg_disagree="$_upg_disagree ${_b}(coverage=$_c,selftest=$_s)"
done

# Printed from the data, beside the claim it supports.
echo "-- not_a_suite agreement: $_upg_pop test files compared,\
 $(printf '%s' "$_upg_disagree" | wc -w) disagreements"

check "premise: the population is the real test directory, not an empty glob" \
	"$([ "$_upg_pop" -gt 50 ] && echo yes || echo no)" "yes"

check "the coverage runner's not_a_suite agrees with the selftest's, both ways (#741)" \
	"$(printf '%s' "$_upg_disagree" | sed 's/^ //')" ""
