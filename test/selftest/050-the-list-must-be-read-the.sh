# ---- the list must be read the way the RUNNER reads it ----------------------
#
# The two checks below rest on listed_suites, so what listed_suites believes is
# load-bearing. It used to believe its own parser: an awk range plus sed plus
# grep, which is a reimplementation of bash's array parsing, and the two disagree
# on exactly the mistake this project keeps making.
#
# Appending a name AFTER the closing paren is valid shell. `bash -n` passes. To
# bash the name is a stray COMMAND and not a member, so the suite never runs. To
# the awk parser it was a member, so "every suite is registered" passed and the
# suite silently did not run. The tally cannot catch it either, because
# "suites that ran: N of M" takes M from ${#SUITES[@]} and is self-consistent
# with the suite missing.
#
# Measured before this was fixed: bash reported "stray_suite: command not found"
# while listed_suites reported it as registered.
#
# So the fixture below is the real runner with that exact mistake applied, and
# the assertion is that the extraction agrees with bash rather than with awk.
_fx="$(mktemp /tmp/pgc-runner-fixture.XXXXXX.sh)"
awk '
	/^SUITES=\(/ { inarr = 1 }
	inarr && /\)/ && !seen { print $0 " stray_not_a_suite"; seen = 1; inarr = 0; next }
	{ print }
' "$RUNNER" > "$_fx"

check_num "premise: the fixture really does carry the stray name" \
	"$(grep -c 'stray_not_a_suite' "$_fx")" "1"
check_num "a name after the array's closing paren is not read as a registered suite" \
	"$(listed_suites "$_fx" | grep -cx stray_not_a_suite)" "0"

# And the mistake is worse than a stray command, which is worth pinning because
# the first version of this test assumed otherwise and asserted the opposite.
#
#     SUITES=(alpha beta gamma) stray_name
#     -> stray_name: command not found
#     -> ${#SUITES[@]} is 0
#
# `NAME=value cmd` scopes the assignment to that one command, and an array
# literal is no exception. So the name after the paren does not join the array,
# it DESTROYS it: every suite disappears and the matrix would run none of them.
# The runner's "NO SUITES RAN" guard is the backstop for that, and this is what
# stops the registration check above from calling the wreck healthy.
check_num "and the mistake empties the whole array rather than appending to it" \
	"$(listed_suites "$_fx" | grep -c .)" "0"

# The control has to be a runner that is NOT sabotaged, because for the fixture
# above an empty answer is the correct one. Reading the real runner is what shows
# the extraction can return names at all.
check_num "positive control: the real runner's list is read, and contains isolation" \
	"$(listed_suites | grep -cx isolation)" "1"
check "positive control: and it is a whole list, not one lucky line" \
	"$([ "$(listed_suites | grep -c .)" -gt 50 ] && echo yes || echo no)" "yes"
rm -f "$_fx"

