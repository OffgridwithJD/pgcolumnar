#!/usr/bin/env bash
#
# Documentation style gate: the measurable ASD-STE100 rules (issue #291).
#
# The project writes its user-facing documentation to the ASD-STE100 writing
# rules. A rule that nothing checks is a rule the next writer does not know
# about, and this project has been bitten by that shape before: an empty REGRESS
# made `make installcheck` report success while running nothing. So the rules
# that a machine can check are checked here, and a document that drifts goes red.
#
# WHAT IS NOT CLAIMED. Full ASD-STE100 compliance is defined against the licensed
# ASD Dictionary of approximately 900 approved words, each with one approved
# meaning and one part of speech. That dictionary is not available to this
# project. The approved-vocabulary rule is therefore not enforced and is not
# claimed, here or in the documentation. What is enforced is sentence length,
# idiom, and dash characters. Saying so is the point: an unverifiable claim of
# compliance would be worse than an honest partial one.
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
out="$(python3 "$SRCDIR/test/ste_check.py" $docs 2>&1)"
rc=$?
echo "$out" | sed 's/^/  /'
check "every user-facing document meets the measurable STE rules" "$rc" "0"

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

# CHANGELOG.md: dash characters only. See the scope note above.
dashes=$(grep -c '—\|–' "$SRCDIR/CHANGELOG.md" || true)
check "CHANGELOG.md carries no em or en dash" "$dashes" "0"

echo "checks run: $checks"
if [ "$fail" = 0 ]; then
	echo "docs_style.sh: PASSED"
	exit 0
fi
echo "docs_style.sh: FAILED"
exit 1
