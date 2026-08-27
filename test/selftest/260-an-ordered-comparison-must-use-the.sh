# ---- an ordered comparison must use the ordered oracle ---------------------
#
# diff_query hashes string_agg(_row::text, chr(10) ORDER BY t): it SORTS the
# rendered rows before comparing them. That is a set comparison, which is what
# almost every site wants, and it means a wrong row order is invisible to it.
# Measured on the oracle expression itself -- five rows forward and the same five
# reversed both hash to 2603e60e802d02d5370794d279cb522a, while a genuinely
# different row set hashes differently, so it is order-blind, not broken.
#
# Five sites named an ORDER BY and so asserted an ordering they could not fail
# on. Two of them were in sorted_projection.sh, whose entire subject is sorted
# output. They now use diff_query_ordered, which hashes ORDER BY row_number()
# and keeps the query's own output order.
#
# The check below is the drift guard, and it is the load-bearing one: the fix is
# five call sites today, and the sixth is written by whoever adds the next
# ordered comparison. It fails closed -- a new `diff_query "..." "... ORDER BY
# ..."` reddens here rather than passing silently for a year.

_lib="$TESTDIR/lib.sh"

check "premise: both oracles are present" \
	"$(grep -c '^pgc_set_hash()\|^pgc_seq_hash()' "$_lib")" "2"
check "premise: both comparison helpers are present" \
	"$(grep -c '^diff_query()\|^diff_query_ordered()' "$_lib")" "2"

# They must actually differ in what they order by, or diff_query_ordered is the
# order-blind oracle under a reassuring name. This is the failure that would
# otherwise leave every check in this file passing while nothing was fixed.
check "the set oracle orders by the rendered row, so it is order-blind" \
	"$(awk '/^pgc_set_hash\(\)/,/^}/' "$_lib" | grep -c 'ORDER BY t)')" "1"
check "the ordered oracle orders by row_number, so it keeps the query's order" \
	"$(awk '/^pgc_seq_hash\(\)/,/^}/' "$_lib" | grep -c 'ORDER BY n)')" "1"
check "the ordered oracle numbers the rows as they arrive" \
	"$(awk '/^pgc_seq_hash\(\)/,/^}/' "$_lib" | grep -c 'row_number() OVER ()')" "1"

# Both must keep the #418 sentinels. An ordered oracle that dropped them would
# reopen empty-vs-empty and error-vs-error passing vacuously.
check "the ordered oracle keeps the empty-result sentinel" \
	"$(awk '/^pgc_seq_hash\(\)/,/^}/' "$_lib" | grep -c 'EMPTY')" "1"
check "the ordered oracle keeps the unique query-error sentinel" \
	"$(awk '/^pgc_seq_hash\(\)/,/^}/' "$_lib" | grep -c 'QUERY_ERROR')" "1"

# ---- the guard itself ------------------------------------------------------
# Every diff_query call site whose query names an ORDER BY must be the ordered
# one. Counted over call sites rather than files so the message can name how many.
# Continuations are joined FIRST. Greping the call line alone misses a call whose
# query sits on a continuation line, and that is not a hypothetical style: 13
# diff_query calls in the tree are already written that way (8 in
# native_fastdecode.sh, 5 in native_groupagg.sh), so it is the shape the next
# author is most likely to copy. Measured on the unjoined check, same suite, same
# query, only the line break differing: single-line 1 (caught), continued 0 (fails
# open). This guard is the durable half of the split, so it has to see both.
_join_calls() {
	for _f in "$TESTDIR"/*.sh; do
		sed -e :a -e '/\\$/N; s/\\\n//; ta' "$_f"
	done
}

# ... and the joining must actually be exercised, or the three checks below are
# the unjoined ones under a new name.
check "premise: the tree really contains continued diff_query calls to join" \
	"$([ "$(grep -hE '^[[:space:]]*diff_query.*\\$' "$TESTDIR"/*.sh | wc -l)" -gt 0 ] \
	   && echo yes || echo no)" "yes"

_ordblind=$(_join_calls | grep -E '^[[:space:]]*diff_query ' | grep -ci 'order by')
check "no diff_query site names an ORDER BY it cannot test (use diff_query_ordered)" \
	"$_ordblind" "0"

# And the converse, so the split stays meaningful in both directions: an ordered
# comparison that names no ORDER BY is comparing an order the query never asked
# for, which is a flapping test waiting to happen.
_ordnoorder=$(_join_calls | grep -E '^[[:space:]]*diff_query_ordered ' | grep -civ 'order by')
check "every diff_query_ordered site actually names an ORDER BY" \
	"$_ordnoorder" "0"

# The sites that prompted this must still be ordered ones, so a later edit that
# reverts them is caught by name rather than only by the counts above.
check "sorted_projection's two comparisons are ordered, its subject being order" \
	"$(grep -cE '^[[:space:]]*diff_query_ordered ' "$TESTDIR/sorted_projection.sh")" "2"

# A static check cannot see whether the ordered oracle really keeps order, so
# every suite that uses diff_query_ordered runs pgc_check_ordered_oracle against
# the cluster under test. native_format.sh originally had the ordered comparison
# and no premise, which is what this check exists to stop recurring.
# lib.sh is excluded from both sides: it DEFINES these, and the definition line
# `pgc_check_ordered_oracle() {` matched the caller pattern, which counted the
# library as a suite and made this check fail 4-vs-3 the first time it ran.
# The call pattern also requires the name to stand alone on the line, so the
# definition cannot match it again.
# diff_query_ordered is the wrapper; pgc_seq_hash is the oracle underneath it,
# and a suite that calls the oracle directly needs the same premise for the same
# reason. sorted_pathkeys.sh does exactly that: it compares a columnar answer
# against a heap one in ROW ORDER without going through the pair helpers,
# because its tables are not t_heap/t_col. Counting only the wrapper made the
# premise it does assert look like one premise too many.
_ord_users=$(grep -lE '^[[:space:]]*diff_query_ordered |pgc_seq_hash ' "$TESTDIR"/*.sh \
	| grep -cv '/lib\.sh$')
_ord_premised=$(grep -lE '^[[:space:]]*pgc_check_ordered_oracle[[:space:]]*$' "$TESTDIR"/*.sh \
	| grep -cv '/lib\.sh$')
check "premise: some suite uses the ordered oracle, or the next check is vacuous" \
	"$([ "$_ord_users" -gt 0 ] && echo yes || echo no)" "yes"
check "every suite using the ordered oracle asserts its premise" \
	"$_ord_premised" "$_ord_users"
