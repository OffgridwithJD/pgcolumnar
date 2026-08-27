# A set_options call must use IN-RANGE values, unless its error is the point.
#
# pgcolumnar.set_options RAISES on an out-of-range limit. A suite that calls it
# and discards the output therefore runs on DEFAULT limits while the script
# reads as though it were configured, and every later assertion is about a
# fixture that was never built. Found by OffgridwithJD on 2026-08-27: several
# probes passed stripe_row_limit => 500, which errors with "must be at least
# 1000", and the fixtures silently ran on defaults.
#
# SCOPE. This checks NUMERIC BOUNDS only. set_options also raises on an unknown
# compression or encode_effort, and on a sort_by naming a column that does not
# exist or is virtual -- silent in exactly the same way, and not checkable from
# a literal without resolving the relation. Those are deliberately not covered,
# so the title of this file is narrower than "every value set_options will
# reject".
#
# WHY THE NAIVE FORM OF THIS GUARD WOULD BE REVERTED IN A WEEK. Measured on this
# tree before writing it: 182 set_options calls, and exactly THREE out-of-range
# literals -- all in audit.sh, all deliberate, all wrapped in expect_error,
# because rejecting them is what that suite tests. A guard that flags every
# out-of-range value is wrong on 3 of 3 and gets deleted. The discriminator is
# already the house vocabulary: a call whose result is INSPECTED is fine, one
# whose output is DISCARDED is the one that fails silently.
#
# LINE CONTINUATIONS ARE JOINED FIRST. audit.sh:208 and :210 are backslash
# continued, so a line-based grep sees neither the expect_error nor the value.
# Here that would fail SAFE, but the same blindness fails OPEN on a real
# multi-line offender, and multi-line set_options calls are common.
#
# Bounds are set_options' own: stripe >= 1000, chunk_group >= 100,
# compression_level 1..22.

_so_scan() {
	# $1: extra files to include (used by the positive control)
	local extra="${1:-}"
	local f
	for f in "$PGC_SRCDIR"/test/*.sh "$PGC_SRCDIR"/bench/*.sh $extra; do
		[ -f "$f" ] || continue
		awk -v F="$f" '{
			line = $0; n = NR
			while (sub(/\\$/, "", line)) { if ((getline nxt) > 0) line = line nxt; else break }
			print F ":" n ":" line
		}' "$f"
	done
}

# every joined line that calls set_options, minus the ones whose error is the point
_so_calls() { _so_scan "${1:-}" | grep 'set_options(' ; }
_so_offenders() {
	_so_calls "${1:-}" | grep -v 'expect_error' | while IFS= read -r L; do
		_so_check "$L" stripe_row_limit 1000 2147483647
		_so_check "$L" chunk_group_row_limit 100 2147483647
		_so_check "$L" compression_level 1 22
	done
}
_so_check() {
	local L="$1" name="$2" lo="$3" hi="$4" v
	printf '%s\n' "$L" | grep -oE "$name *=> *[0-9]+" | grep -oE '[0-9]+$' | while read -r v; do
		if [ "$v" -lt "$lo" ] || [ "$v" -gt "$hi" ]; then
			printf '%s %s => %s (allowed %s..%s)\n' "$(printf '%s' "$L" | cut -d: -f1,2)" "$name" "$v" "$lo" "$hi"
		fi
	done
}

_SO_CALLS="$(_so_calls | grep -c 'set_options(')"

# The sweep must have READ something. A path typo makes every check below
# vacuously green forever, which is the failure this file exists to prevent in
# other people's suites.
check "premise: the set_options sweep read a substantial number of calls" \
	"$([ "${_SO_CALLS:-0}" -ge 100 ] && echo yes || echo "no ($_SO_CALLS)")" "yes"

# ...and it must have read EVERYTHING. The premise above proves the sweep read
# something; it cannot see a whole directory the glob does not reach. The globs
# are test/*.sh and bench/*.sh, which do NOT match test/selftest/*.sh or
# test/pbt/*.sh, so a suite added under either would be silently unguarded --
# the exact fail-open class this file exists to prevent elsewhere. Today the
# tree has no set_options call outside the globs, so the guard is complete by
# accident of its current shape rather than by construction.
#
# Fixed with a premise rather than a wider glob, because a wider glob only ever
# covers the directories someone thought of. Comparing the files that CONTAIN a
# call against the files the sweep actually READ fails loudly the day one
# appears anywhere new, with nobody having to predict where (OffgridwithJD,
# #780 review).
#
# This file is the one legitimate exclusion, and it excludes ITSELF by path
# rather than by name: it necessarily contains the bad pattern as its own test
# data (the positive control writes an out-of-range call that is deliberately
# not wrapped in expect_error), so sweeping it would flag the probe that proves
# the sweep works. Keyed on BASH_SOURCE so it cannot drift into a
# hand-maintained list of exceptions.
_so_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
_so_have="$(grep -rl 'set_options(' --include='*.sh' "$PGC_SRCDIR" 2>/dev/null \
	| grep -vF "$(basename "$_so_self")" | LC_ALL=C sort -u)"
_so_read="$(_so_calls | cut -d: -f1 | LC_ALL=C sort -u)"
_so_missed="$(LC_ALL=C comm -23 <(printf '%s\n' "$_so_have") <(printf '%s\n' "$_so_read"))"
[ -n "$_so_missed" ] && printf '%s\n' "$_so_missed" | sed 's/^/    unswept: /'
check "premise: every file containing a set_options call is in the sweep" \
	"$([ -z "$_so_missed" ] && echo complete || echo "$(printf '%s\n' "$_so_missed" | wc -l) unswept")" \
	"complete"

# POSITIVE CONTROL. The three known out-of-range values in audit.sh are skipped
# because they are expect_error, so their absence from the report proves nothing
# on its own -- a detector that finds NOTHING would also pass. Run it over a
# synthetic file carrying one of the same values NOT wrapped in expect_error.
_so_tmp="$(mktemp)"
cat > "$_so_tmp" <<'PROBE'
psql_run "SELECT pgcolumnar.set_options('t', stripe_row_limit => 500);"
PROBE
check "premise: the detector fires on an out-of-range value that is NOT expect_error" \
	"$([ -n "$(_so_offenders "$_so_tmp" | grep "$_so_tmp")" ] && echo fires || echo BLIND)" "fires"
cat > "$_so_tmp" <<'PROBE'
expect_error "reject it" \
	"SELECT pgcolumnar.set_options('t', stripe_row_limit => 500);"
PROBE
check "premise: and does NOT fire when the error is the point, across a continuation" \
	"$([ -z "$(_so_offenders "$_so_tmp" | grep "$_so_tmp")" ] && echo quiet || echo "fired")" "quiet"
rm -f "$_so_tmp"

_SO_BAD="$(_so_offenders)"
[ -n "$_SO_BAD" ] && printf '%s\n' "$_SO_BAD" | sed 's/^/    /'
check "no suite calls set_options with a value it will reject" \
	"$([ -z "$_SO_BAD" ] && echo clean || echo "$(printf '%s\n' "$_SO_BAD" | wc -l) offender(s)")" "clean"
