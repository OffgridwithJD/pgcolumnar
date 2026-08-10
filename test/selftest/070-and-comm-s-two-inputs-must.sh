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

_cm_unpinned=""
for _f in $_cm_files; do
	# every `| sort` in a file that uses comm must carry LC_ALL=C
	if grep -qE '\|[[:space:]]*sort' "$_f" && grep -E '\|[[:space:]]*sort' "$_f" | grep -qv 'LC_ALL=C'; then
		_cm_unpinned="$_cm_unpinned $(basename "$_f")"
	fi
done
check "a file that uses comm pins the collation of every sort feeding it" \
	"$(printf '%s' "$_cm_unpinned" | sed 's/^ //')" ""

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

