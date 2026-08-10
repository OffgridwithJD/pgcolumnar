# ---- and lib.sh must ASK these functions, not merely contain them -----------
#
# The checks above feed the three functions fixtures and prove their arithmetic.
# None of them proves the failure path calls any of them. Measured, not reasoned:
# with the pgc_start_log_report call deleted from pgc_setup, every check above
# still PASSED, 70 of 70. That is the same gap #538 found in #532's bench guards,
# found again in the fix for #537 by an adversarial review.
#
# These are checks over source text, which is the weaker kind. They are here
# because the failure path needs a cluster that will not start, which this suite
# cannot stand up, and a weak check on the call site beats none.

_LIB=""$PGC_TESTDIR"/lib.sh"
check "premise: lib.sh is readable, or every grep below approves nothing" \
	"$([ -r "$_LIB" ] && echo yes || echo no)" "yes"
# Without this the three greps could pass against a file that no longer HAS a
# start-failure path, which is the vacuous form of all of them.
check "premise: the start-failure path still exists to be judged" \
	"$([ "$(grep -c 'no cluster of our own' "$_LIB")" -ge 1 ] && echo yes || echo no)" "yes"

check "the failure path asks pgc_start_log_report for the reason" \
	"$([ "$(grep -c 'pgc_start_log_report "' "$_LIB")" -ge 1 ] && echo yes || echo no)" "yes"
check "and asks pgc_start_failure_message for the verdict" \
	"$([ "$(grep -c 'pgc_start_failure_message "' "$_LIB")" -ge 1 ] && echo yes || echo no)" "yes"
# The verdict text must live in ONE place. An inline echo beside the call is how
# the old hardcoded parenthetical would come back wearing the same words.
# Matched on the START-FAILURE verdict specifically. A looser grep for
# `echo "       (refusing` finds two unrelated lines about the previously
# installed .so (#513) and reports a defect that is not there -- which is the
# same prefix-matching trap this suite already guards for suite names.
check "and the old start-failure verdict is not echoed inline anywhere" \
	"$(grep -c 'refusing to run against a cluster' "$_LIB")" "0"
check "the summary path asks pgc_fatal_pattern rather than hardcoding it" \
	"$([ "$(grep -c 'grep -nE .\$(pgc_fatal_pattern)' "$_LIB")" -ge 1 ] && echo yes || echo no)" "yes"
check "and the start path asks pgc_start_fatal_pattern, its deliberately wider one" \
	"$([ "$(grep -c 'pgc_start_fatal_pattern)' "$_LIB")" -ge 1 ] && echo yes || echo no)" "yes"

