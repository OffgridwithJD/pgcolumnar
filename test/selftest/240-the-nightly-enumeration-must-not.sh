# ---- the docs' nightly enumeration must not go stale by addition ------------
#
# docs/testing.md enumerates what the nightly contains. An enumeration goes stale
# by ADDITION: it stays true about everything it lists while silently
# under-describing the workflow the moment a job is added. #741 added a fourth
# job and the sentence still named three, which is the same shape as #671.
#
# So the enumeration is derived from the workflow and checked, rather than
# trusted. Two decisions, and the first version got the second one wrong:
#
# 1. The token compared is the JOB KEY, not the display name and not the prose. A
#    key is stable and machine-owned; a display name carries a matrix expression
#    and prose gets reworded. Hyphens and underscores are normalised to spaces, so
#    `upgrade-guard` is satisfied by "extension-upgrade guard".
#
# 2. The search is scoped to the NIGHTLY PARAGRAPH, not the whole file. The first
#    version searched the whole document for the key's first word, and its own
#    removal proof exposed it: delete the sentence naming the upgrade guard and
#    the check STAYED GREEN, because "upgrade" already appears eleven times in
#    this file for unrelated reasons (pg_upgrade, PGC_RUN_UPGRADE). It caught an
#    invented job name and missed the case it was written for, which is the
#    too-loose failure in CONTEXT.md. The proof is what found that, not review.

_nl_wf="$TESTDIR/../.github/workflows/nightly.yml"
_nl_doc="$TESTDIR/../docs/testing.md"

check "premise: the nightly workflow and the testing doc are both present" \
	"$([ -r "$_nl_wf" ] && [ -r "$_nl_doc" ] && echo yes || echo no)" "yes"

# Job keys: the two-space-indented mapping keys under `jobs:`. Read from the
# workflow so a job added later is covered on the day it is added.
_nl_jobs="$(awk '/^jobs:/{inj=1;next} inj && /^  [a-zA-Z_-]+:[[:space:]]*$/{
	k=$1; sub(/:$/,"",k); print k}' "$_nl_wf")"
_nl_n=$(printf '%s\n' "$_nl_jobs" | grep -c .)

echo "-- nightly jobs, derived: $(echo $_nl_jobs) ($_nl_n found)"

# Without this the loop can pass by iterating over nothing, which is the failure
# this file exists to prevent, occurring inside the check for it.
check "premise: at least three nightly jobs were parsed, so the list is real" \
	"$([ "${_nl_n:-0}" -ge 3 ] && echo yes || echo no)" "yes"

# The nightly paragraph alone: from its bold heading to the next blank line,
# with hyphens and underscores flattened so "extension-upgrade guard" reads as
# "extension upgrade guard".
_nl_para="$(awk '/\*\*Nightly at/{p=1} p{print} p&&/^$/{exit}' "$_nl_doc" |
	tr '\n' ' ' | tr '_-' '  ')"

check "premise: the nightly paragraph was located and is not empty" \
	"$([ "$(printf '%s' "$_nl_para" | wc -c)" -gt 100 ] && echo yes || echo no)" "yes"

_nl_missing=""
for _j in $_nl_jobs; do
	_w="$(printf '%s' "$_j" | tr '_-' '  ')"
	grep -qi -- "$_w" <<<"$_nl_para" || _nl_missing="$_nl_missing $_j"
done

check "every nightly job is named in docs/testing.md (#741)" \
	"$(printf '%s' "$_nl_missing" | sed 's/^ //')" ""
