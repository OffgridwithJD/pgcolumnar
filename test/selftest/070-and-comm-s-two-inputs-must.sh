# ---- and comm's two inputs must be sorted the SAME way (#552 follow-up) -----
#
# `comm` requires both inputs sorted in one collation and does not check. Fed
# inconsistently-sorted input it does not error; it returns the wrong lines.
#
# test/rebuild.sh:130 does `comm -23` over two `sort -u` outputs, neither pinned.
# They agree today because they share a locale. The plausible next edit is
# somebody pinning ONE of them because this PR taught them to, and the result is
# a symbol check that silently reports the wrong unresolved symbols -- either a
# false red, or the worse direction, a real unresolved symbol not reported.
#
# Asserted over source text, which is the weaker kind, because reproducing it
# needs two locales and a built .so. Premised on the comm still existing, or the
# grep approves a file that no longer has one.
_cm_files="$(grep -ln 'comm -' "$PGC_TESTDIR"/*.sh 2>/dev/null)"
check "premise: some suite still uses comm, or the check below is vacuous" \
	"$([ -n "$_cm_files" ] && echo yes || echo no)" "yes"

# ---- widened to reach process substitution, and to read code only (#1112) ---
#
# THE OLD PATTERN WAS A PIPE. `grep -E '\|[[:space:]]*sort'` cannot match
# `comm -23 <(sort "$1") <(sort "$2")`, which is not a pipeline at all. Measured on
# `run_all_versions.sh`: zero matches for the piped form, three process-substituted
# sorts feeding `comm`, and this guard passed the file. One of the three had been
# there since #928. Found by @OffgridwithJD reviewing #1110.
#
# PINNING THE COMM IS NOT ENOUGH, and this is the half that changes the fix rather
# than the description. `LC_ALL=C comm <(sort a) <(sort b)` pins only comm's own
# comparison: the substitutions run in subshells of the PARENT and inherit ITS
# locale. A guard that accepted `LC_ALL=C` anywhere on the line would bless exactly
# the form a reader writes after reading this guard's name. So the two halves are
# asserted separately.
#
# AND IT READS CODE ONLY. The guard used to scan every line, prose included, so a
# comment explaining the rule violates it: a note in `run_all_versions.sh` reading
# "reads only the piped form" contained the literal string this greps for, on a line
# with no `LC_ALL=C`, and flagged the file for its own comment. A rule that cannot be
# written down is a rule people stop writing down.
#
# The readers are functions so the planted fixtures below can drive the same code the
# corpus arm uses. A check that re-implements its subject agrees with it by
# construction.

# A MIXED LINE FAILS WITHOUT ANY EXTRA WORK, and this reader is deliberately shorter
# than the first draft. Both patterns require `sort` IMMEDIATELY after the `|` or the
# `<(`, so a pinned `<(LC_ALL=C sort ...)` never matches in the first place and an
# unpinned one on the same line still does. The draft also substituted the pinned form
# away before matching; mutation testing removed that line and NOTHING changed -- nine
# arms stayed green -- so it was dead, and a dead line in a guard reads as load-bearing
# to the next person. A line-level `grep -v LC_ALL=C` is the thing that would have
# needed it, and that is the design this does not use.
_cm_unpinned_sorts() {	# _cm_unpinned_sorts FILE -> offending lines
	grep -vE '^[[:space:]]*#' "$1" \
	| grep -E '(\|[[:space:]]*sort([[:space:]]|$)|<\([[:space:]]*sort([[:space:]]|$))' \
	|| true
}

_cm_unpinned_comms() {	# _cm_unpinned_comms FILE -> offending lines
	grep -vE '^[[:space:]]*#' "$1" \
	| grep -E '(^|[^_[:alnum:]])comm[[:space:]]' \
	| grep -v 'LC_ALL=C comm[[:space:]]' \
	|| true
}

_cm_unpinned=""
_cm_unpinned_c=""
for _f in $_cm_files; do
	[ -n "$(_cm_unpinned_sorts "$_f")" ] && _cm_unpinned="$_cm_unpinned $(basename "$_f")"
	[ -n "$(_cm_unpinned_comms "$_f")" ] && _cm_unpinned_c="$_cm_unpinned_c $(basename "$_f")"
done
check "a file that uses comm pins the collation of every sort feeding it" \
	"$(printf '%s' "$_cm_unpinned" | sed 's/^ //')" ""
check "and pins the comm itself, whose prefix does not reach its substitutions" \
	"$(printf '%s' "$_cm_unpinned_c" | sed 's/^ //')" ""

# ---- the arms above are EMPTY on this corpus, so they are proved by planting ----
#
# Both readers select nothing today, measured before this was written. An arm that
# can only ever report "none" is a check that cannot fail, so each form it must catch
# is planted here and required to be caught, and the two forms it must NOT catch are
# planted too.
_cm_d="$(mktemp -d)"

printf 'x() {\n\tcomm -23 <(sort "$1") <(sort "$2")\n}\n'            >"$_cm_d/sub.sh"
printf 'x() {\n\tcat a | sort > b\n\tcomm -23 b c\n}\n'            >"$_cm_d/pipe.sh"
printf 'x() {\n\tcomm -23 <(LC_ALL=C sort "$1") <(sort "$2")\n}\n'   >"$_cm_d/half.sh"
printf 'x() {\n\tLC_ALL=C comm -23 <(sort "$1") <(sort "$2")\n}\n'   >"$_cm_d/commonly.sh"
printf 'x() {\n\tLC_ALL=C comm -23 <(LC_ALL=C sort "$1") <(LC_ALL=C sort "$2")\n}\n' >"$_cm_d/good.sh"
printf '# this note explains that a bare `| sort` feeding comm is refused\nx() {\n\tLC_ALL=C comm -23 <(LC_ALL=C sort "$1") <(LC_ALL=C sort "$2")\n}\n' >"$_cm_d/prose.sh"

check "a process-substituted sort with no pin is caught, which the old pattern missed" \
	"$(_cm_unpinned_sorts "$_cm_d/sub.sh" | grep -c . || true)" "1"
check "and the piped form the old pattern did catch is still caught" \
	"$(_cm_unpinned_sorts "$_cm_d/pipe.sh" | grep -c . || true)" "1"
check "a line with ONE of two sorts pinned is still caught" \
	"$(_cm_unpinned_sorts "$_cm_d/half.sh" | grep -c . || true)" "1"
check "pinning only the comm does not pin its substitutions" \
	"$(_cm_unpinned_sorts "$_cm_d/commonly.sh" | grep -c . || true)" "1"
check "and a fully pinned line is not flagged, so the reader can report none" \
	"$(_cm_unpinned_sorts "$_cm_d/good.sh" | grep -c . || true)" "0"
check "prose describing the rule does not violate it" \
	"$(_cm_unpinned_sorts "$_cm_d/prose.sh" | grep -c . || true)" "0"

check "an unpinned comm is caught by its own reader" \
	"$(_cm_unpinned_comms "$_cm_d/sub.sh" | grep -c . || true)" "1"
check "and a pinned comm is not" \
	"$(_cm_unpinned_comms "$_cm_d/good.sh" | grep -c . || true)" "0"

rm -rf "$_cm_d"

# A case over the cached list rather than `listed_suites | grep -qx`. The pipe
# was the defect: grep -q returns on its match, printf takes EPIPE, and pipefail
# turns that into a failed pipeline for a suite that IS registered. See the note
# above line 201. Newlines around both sides make it a whole-line match, which is
# what grep -x provided and what keeps a name from matching inside another.
# Both directions first, because a membership test that always matched would make
# the check below pass for every suite including genuinely unregistered ones --
# which is the same green-by-construction failure the pipe version produced in
# reverse. The replacement has to be shown to answer, not merely to stop failing.
case $'\n'"$_SUITE_LIST"$'\n' in
	*$'\n'isolation$'\n'*) _ctl_present=present ;;
	*) _ctl_present=absent ;;
esac
check "positive control: the membership test finds a name that is registered" \
	"$_ctl_present" "present"

case $'\n'"$_SUITE_LIST"$'\n' in
	*$'\n'no_such_suite_exists$'\n'*) _ctl_absent=present ;;
	*) _ctl_absent=absent ;;
esac
check "negative control: and does not find one that is not" \
	"$_ctl_absent" "absent"

# A partial name must not match a whole entry, which is what grep -x guaranteed
# and what the surrounding newlines preserve.
case $'\n'"$_SUITE_LIST"$'\n' in
	*$'\n'isolatio$'\n'*) _ctl_partial=present ;;
	*) _ctl_partial=absent ;;
esac
check "and a prefix of a registered name is not treated as registered" \
	"$_ctl_partial" "absent"

unregistered=""
for f in "$TESTDIR"/*.sh; do
	name="$(basename "$f" .sh)"
	not_a_suite "$name" && continue
	case $'\n'"$_SUITE_LIST"$'\n' in
		*$'\n'"$name"$'\n'*) ;;
		*) unregistered="$unregistered $name" ;;
	esac
done
check "every suite is registered in run_all_versions.sh" \
	"$([ -z "$unregistered" ] && echo none || echo "unregistered:$unregistered")" "none"

# The reverse: a name in SUITES with no file is a rename or a typo, and the
# runner would report it as a failure only when it tried to run it.
missing_file=""
while read -r name; do
	[ -f "$TESTDIR/$name.sh" ] || missing_file="$missing_file $name"
done < <(listed_suites)
check "every registered suite has a file" \
	"$([ -z "$missing_file" ] && echo none || echo "missing:$missing_file")" "none"

