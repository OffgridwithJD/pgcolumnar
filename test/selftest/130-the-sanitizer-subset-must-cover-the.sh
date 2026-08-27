# ---- the sanitizer subset must cover the C-level encoding selftest -----------
#
# test/run_san.sh runs a SUBSET of the suites, and a suite that is not in it is
# not sanitized -- silently, since nothing reports the omission.
#
# encode_invariants is the only suite that drives pgcolumnar_debug_encoding_selftest,
# which exercises bitunpack at every width 1..64 across counts 1,2,3,7,8,9,17,64,129
# plus a derived count per width. That matters because it is the only fixture that
# crosses bitunpack's fast/tail boundary in both directions: nFast is 0 until the
# encoded body reaches nine bytes, so small counts are all tail. Measured with a
# probe build, counting backends that reached the tail loop:
#
#     encode_invariants  21
#     differential        0
#
# differential's chunks are large enough that nFast == n throughout, so a
# sanitizer pass that includes differential and not encode_invariants covers one
# of bitunpack's two paths -- over exactly the code #514 rewrote.
#
# Asked as "every suite that drives the selftest" rather than by name, so moving
# the selftest to another suite cannot quietly narrow this.
# Ask the runner rather than parsing the source (CONTEXT.md, #473) -- but with
# PGC_SAN_SUITES cleared, because the claim under test is about the SHIPPED
# DEFAULT, not about whatever an operator overrode it with for one run.
#
# Both halves are load-bearing and each fixes a different defect. Asking the
# runner means this cannot drift from what run_san.sh actually iterates. Clearing
# the variable means a developer with an override exported does not get a red
# from a check that is not about their override -- which is what a plain
# --list-suites here produces, verified: with PGC_SAN_SUITES='smoke differential'
# the runner reports no encode_invariants and this check would fail while the
# shipped default is perfectly correct.
_san_suites="$(env -u PGC_SAN_SUITES bash "$PGC_SRCDIR/test/run_san.sh" --list-suites 2>/dev/null)"
check "premise: run_san.sh's default subset was found and is non-empty" \
	"$([ -n "$_san_suites" ] && echo yes || echo no)" "yes"

_san_missing=""
_san_drivers=0
for _f in "$PGC_SRCDIR"/test/*.sh; do
	# No self-skip. This block used to live in test/harness_selftest.sh, which
	# this loop globs, so it matched itself -- the same self-match that makes
	# `pgrep -f <pattern>` find its own command line. It now lives in
	# test/selftest/, which `test/*.sh` does not glob, so the searcher is no
	# longer in the searched set. The skip is removed rather than left in place
	# because a condition that can never be true is a check that can never fail,
	# and the differential in #554 proves _san_drivers is unchanged by the move.
	grep -q 'debug_encoding_selftest' "$_f" || continue
	_san_drivers=$((_san_drivers + 1))
	_b="$(basename "$_f" .sh)"
	grep -qw "$_b" <<<"$_san_suites" || _san_missing="$_san_missing $_b"
done
check "premise: at least one suite drives the C-level encoding selftest" \
	"$([ "$_san_drivers" -ge 1 ] && echo yes || echo no)" "yes"

check "the sanitizer subset runs every suite that drives the encoding selftest" \
	"$(printf '%s' "$_san_missing" | sed 's/^ //')" ""


# ---- and every suite that is the ONLY guard on a deliberate over-write -------
#
# decode_fsst_shared stores each symbol as one fixed 8-byte write and allocates
# FSST_DECODE_SLACK bytes past rawLen so the tail of that write is inside the
# allocation (#768). Nothing in the ordinary matrix can see the slack removed:
# the over-write lands 1 to 7 bytes past a palloc'd chunk, which does not fault
# and does not change any answer. **The sanitizer is the only thing that
# catches it**, and it does so precisely -- with the slack deleted,
# write_fsst_compressed reports
# `heap-buffer-overflow ... columnar_encoding.c in decode_fsst_shared`.
#
# So a suite that exercises FSST decoding must stay in the subset. Dropping one
# would not fail anything; it would silently remove the only guard there is.
# Asked by which suites DRIVE FSST rather than by name, so moving the coverage
# to another suite cannot quietly narrow it.
_fsst_missing=""
_fsst_drivers=0
for _f in "$PGC_SRCDIR"/test/*.sh; do
	grep -qE "encode_effort *=> *'full'|fsst" "$_f" || continue
	_fsst_drivers=$((_fsst_drivers + 1))
	_b="$(basename "$_f" .sh)"
	grep -qw "$_b" <<<"$_san_suites" || _fsst_missing="$_fsst_missing $_b"
done
check "premise: at least one suite drives FSST encoding" \
	"$([ "$_fsst_drivers" -ge 1 ] && echo yes || echo "no ($_fsst_drivers)")" "yes"
check "the sanitizer subset runs at least one suite that drives FSST decoding" \
	"$([ "$_fsst_drivers" -gt "$(printf '%s' "$_fsst_missing" | wc -w)" ] && echo covered || echo "none covered")" \
	"covered"
