#!/usr/bin/env bash
#
# Documentation style gate: the measurable plain-language rules (issue #291).
#
# The project writes its user-facing documentation to ISO 24495-1:2023, Plain
# language - Part 1: Governing principles and guidelines. A rule that nothing
# checks is a rule the next writer does not know about, and this project has been
# bitten by that shape before: an empty REGRESS made `make installcheck` report
# success while running nothing. So the rules that a machine can check are
# checked here, and a document that drifts goes red.
#
# WHAT IS NOT CLAIMED. ISO 24495-1 gives four governing principles -- relevant,
# findable, understandable, usable -- and only the third has any mechanically
# checkable content, and only in part. Its own test for "usable" is that a reader
# acts on the document successfully, which no checker performs. So a green run
# means the measurable subset holds, NOT that the documentation is plain. Saying
# so is the point: an unverifiable claim of conformity would be worse than an
# honest partial one.
#
# Two of the four checks are this project's typographic house rules rather than
# anything the standard requires: no em or en dash, and no double hyphen as a
# dash in prose. They are named as house rules wherever they appear so nobody
# mistakes a preference for a requirement.
#
# SCOPE, which is a decision rather than an oversight:
#
#   docs/*.md and README.md are user-facing prose and are checked in full.
#
#   CHANGELOG.md is a record of what happened, written at the time it happened.
#   Rewriting landed entries would edit history, so it is checked for dash
#   characters only.
#
#   design/ holds internal engineering records and is not checked. Code comments
#   are not checked either. Both explain WHY, and the reasoning in them is worth
#   more than the uniformity would be.
#
# Usage:  test/docs_style.sh [PG_CONFIG]
# The argument is accepted and ignored; this suite needs no cluster.
# Written fresh for pgColumnar.

set -uo pipefail
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

checks=0
fail=0
check() {
	local name="$1" got="$2" want="$3"
	checks=$((checks + 1))
	if [ "$got" = "$want" ]; then
		echo "PASS  $name"
	else
		echo "FAIL  $name: got [$got] want [$want]"
		fail=1
	fi
}

command -v python3 >/dev/null || { echo "FAIL  python3 not found"; exit 1; }

echo "== pgColumnar test: docs_style.sh =="

# The full rules over every user-facing document.
docs=$(ls "$SRCDIR"/docs/*.md "$SRCDIR"/README.md 2>/dev/null)
out="$(python3 "$SRCDIR/test/plain_language_check.py" $docs 2>&1)"
rc=$?
echo "$out" | sed 's/^/  /'
check "every user-facing document meets the measurable plain-language rules" "$rc" "0"

# The control. A checker that examines nothing reports nothing, and this suite
# would then pass on an empty docs/ directory or a broken glob.
n=$(echo "$out" | grep -c '^  ok' || true)
check "and it actually examined the documents" \
	"$([ "$n" -ge 10 ] && echo yes || echo "no (examined $n)")" "yes"

# The roadmap has to stay reachable. It went unfound once because the only routes to it
# were a raw GitHub link and a line in the changelog (#395). A page that is not in the nav
# is not published, and nothing else would notice.
#
# Reachability is two facts, so both are asserted. The nav check alone passes when the
# PAGE is deleted and the entry is kept, which is a broken link rather than reachability.
# That case is also caught by "mkdocs build --strict" in docs.yml, which fails on a nav
# entry pointing at nothing. Half a property here and half in a workflow is how the
# missing half goes unnoticed, so both halves are stated here.
nav_roadmap=$(grep -c "roadmap.md" "$SRCDIR/mkdocs.yml" || true)
check "the roadmap is in the documentation nav" "$([ "$nav_roadmap" -ge 1 ] && echo yes || echo no)" "yes"
check "and the page that nav entry points at exists" \
	"$([ -f "$SRCDIR/docs/roadmap.md" ] && echo yes || echo no)" "yes"

# Merge conflict markers. These reached main and were published: three of them sat
# in docs/limitations.md under "Vacuum and compaction", and every other check in
# this file passed with them there, because they are valid Markdown text.
#
# The prose checker reads prose and the nav check reads mkdocs.yml. Neither asks
# whether the page is a coherent document. This does.
conflicts=$(grep -rlE '^(<<<<<<< |>>>>>>> )' "$SRCDIR/docs" "$SRCDIR"/*.md 2>/dev/null | tr '\n' ' ')
check "no document carries a merge conflict marker" \
	"$([ -z "$conflicts" ] && echo none || echo "$conflicts")" "none"

# CHANGELOG.md: dash characters only. See the scope note above.
dashes=$(grep -c '—\|–' "$SRCDIR/CHANGELOG.md" || true)
check "CHANGELOG.md carries no em or en dash" "$dashes" "0"
# ---- a document that quotes the version must quote the current one ----------
#
# Nothing reads the VERSION file mechanically: no Makefile rule, no CI step. Two
# documents cite it AND hardcode the string beside the citation:
#
#     CHANGELOG.md         the version marker is `1.0-alpha`, recorded in `VERSION`
#     docs/limitations.md  The version marker is `1.0-alpha`, recorded in `VERSION`,
#
# So a release that bumps VERSION and pgcolumnar.control, and forgets these, ships
# documentation asserting the previous version. Nothing else would notice: the
# upgrade path is gated by extension_upgrade.sh, which compares control against
# the installed extension and never reads prose.
#
# The pairing is what makes it checkable. A document that says "recorded in
# `VERSION`" is pointing at a file whose content is knowable, so the two can be
# compared instead of trusted to be edited together.
_ver="$(cat "$SRCDIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
check "premise: the VERSION file has a version to compare against" \
	"$([ -n "$_ver" ] && echo yes || echo no)" "yes"

_verdocs="$(grep -rln 'recorded in `VERSION`' "$SRCDIR/CHANGELOG.md" "$SRCDIR/docs" 2>/dev/null | sort)"
check "premise: at least one document cites the VERSION file" \
	"$([ -n "$_verdocs" ] && echo yes || echo no)" "yes"

_stale=""
for _d in $_verdocs; do
	grep -q "\`$_ver\`, recorded in \`VERSION\`" "$_d" || _stale="$_stale $(basename "$_d")"
done
check "every document citing VERSION quotes the version VERSION holds" \
	"$(printf '%s' "$_stale" | sed 's/^ //')" ""


echo "checks run: $checks"
if [ "$fail" = 0 ]; then
	echo "docs_style.sh: PASSED"
	exit 0
fi
echo "docs_style.sh: FAILED"
exit 1
