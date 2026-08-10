# ---- the list stays sorted, which is what actually stops the conflicts ------
#
# One name per line was not enough on its own. Measured, on this repository, by
# branching twice and merging:
#
#   one line,     both additions on the same line          CONFLICT
#   one per line, both appended at the end                 CONFLICT
#   one per line + sorted, names far apart                 clean
#   one per line + sorted, names that sort adjacently      CONFLICT
#
# Everyone appends at the end, which is the shape all four of #469's conflicts
# had, so one-per-line alone would have left them all conflicting. Sorted gives a
# new suite an insertion point decided by its NAME, so two unrelated additions
# land in different places and merge. It is a large reduction and not a cure:
# two names that sort next to each other still collide.
#
# This check is what keeps the property true. Without it the order decays the
# first time somebody appends by hand, and the reduction quietly goes away.
#
# LC_ALL=C, and the collation is part of the property rather than a detail (#552).
# "Sorted" is not machine-independent: C compares byte by byte so `_` (0x5F)
# precedes `e`, while en_US.UTF-8 ignores punctuation at the first level and
# compares `sortstatus` against `sortedprojection`. The array holds sort_status
# then sorted_projection, so it is sorted in one and unsorted in the other, and
# this check pinned neither. On a clean main it FAILED under en_US.UTF-8 and
# passed here only because the container defaults to C.UTF-8, which collates
# like C.
#
# The ambiguity is worse than the false red. Sorted order is what gives two
# agents' new suites different insertion points; if two contributors disagree
# about what sorted means they insert in different places, and the property stops
# delivering the merges it exists for.
_sorted_expected="$(listed_suites | LC_ALL=C sort)"
_sorted_actual="$(listed_suites)"
check "the suite list is sorted in C order, so two new suites land in different places" \
	"$([ "$_sorted_actual" = "$_sorted_expected" ] && echo sorted || echo "not sorted")" "sorted"

# The pair that decides it, asserted directly so a future edit that "fixes" the
# order to UTF-8 collation fails here with the reason rather than only failing
# the comparison above.
check "premise: C collation puts sort_status before sorted_projection" \
	"$(printf 'sorted_projection\nsort_status\n' | LC_ALL=C sort | head -1)" "sort_status"

