# ---- an addition must be a FILE, not a block at the end (#554) --------------
#
# This suite grew by appending. On 2026-08-09 three PRs each added a block at the
# end of harness_selftest.sh and every pair of them conflicted, while the one PR
# that edited the middle merged clean:
#
#     #544 -> #549   CONFLICT      #553 -> #544   clean
#     #544 -> #551   CONFLICT      #553 -> #549   clean
#     #549 -> #551   CONFLICT      #553 -> #551   clean
#
# That is row two of the measurement in the section above -- "one per line, both
# appended at the end -> CONFLICT" -- occurring in the file that argues it.
#
# So the unit of addition is now a file in test/selftest/. Two agents adding two
# subjects create two files and share no line. The property is the same one that
# makes SUITES work: the insertion point is decided by content, not by "the end".
#
# These checks keep the driver empty of checks, because the moment one is added
# back the collision returns and nothing else would notice.
check "premise: the parts directory exists and was sourced" \
	"$([ -d "$TESTDIR/selftest" ] && [ "$(ls "$TESTDIR/selftest"/*.sh 2>/dev/null | wc -l)" -gt 1 ] && echo yes || echo no)" \
	"yes"

# The driver must contain no checks of its own. Counted on lines that START a
# check, so a `check` named inside a comment or a fixture heredoc does not count.
check "the driver holds no checks; they all live in parts" \
	"$(grep -c '^check ' "$TESTDIR/harness_selftest.sh")" "0"

# And every part must be sourced by the glob rather than named individually: a
# hand-maintained list is the shared line this change exists to remove.
check "the driver sources the parts by glob, not by a list" \
	"$([ "$(grep -c 'selftest/\*\.sh' "$TESTDIR/harness_selftest.sh")" -ge 1 ] && echo yes || echo no)" \
	"yes"
