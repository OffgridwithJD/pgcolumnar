# ---- no suite pipes a captured string into an early-exit reader (#486) -------
#
# `echo "$s" | grep -q PATTERN` under `set -o pipefail` answers "not found" when
# the WRITER fails, whatever the string contained. The reader exits as soon as it
# has its answer, the writer takes EPIPE, and pipefail calls the pipeline failed.
# The `&&` arm never runs and the helper reports absence.
#
# This is not theoretical and it is not new here. #473 found it in this file's own
# membership test, and it came back in native_agg.sh, where it reported "the
# metadata aggregate node did not run" on PG18 CI for a plan that contained the
# node -- a red that reads exactly like a planner regression in the area #133 and
# #140 live in. The tell was a `Broken pipe` line beside a result the same run's
# summary contradicted.
#
# The failure direction is what makes it worth a rule: it always reports the
# thing you were looking for as ABSENT, which is the answer that sends someone
# looking for a defect that is not there.
#
# The control below runs first, because a rule with no demonstrated failure is a
# style preference, and this one is not.
_epipe_demo="$PGC_WORKDIR/epipe_demo.sh"
cat > "$_epipe_demo" <<'DEMO'
set -uo pipefail
big="MATCHME
$(head -c 300000 /dev/zero | tr '\0' 'y')"
piped() { echo "$1" | grep -q 'MATCHME' && echo yes || echo no; }
cased() { case "$1" in *MATCHME*) echo yes ;; *) echo no ;; esac; }
echo "piped=$(piped "$big" 2>/dev/null) cased=$(cased "$big")"
DEMO
_epipe_result="$(bash "$_epipe_demo" 2>/dev/null)"

# The string CONTAINS the pattern, on its first line, in both arms. Only the
# answers differ. Written large on purpose: at a few kilobytes the write fits in
# the pipe buffer and completes before the reader can exit, which is why this
# shape passes almost every time and then does not.
check "control: piping a large string into grep -q reports a match as absent" \
	"$_epipe_result" "piped=no cased=yes"

# The rule itself. A pipeline whose left side is a shell builtin writing a
# captured string, and whose right side is a reader that exits early AND whose
# EXIT STATUS is the answer being read. That last part is the whole rule: the
# damage is a wrong verdict, not a wrong message.
#
# So `grep -q` is in scope and `| head -1` inside a diagnostic string is not.
# Those exist here (analyze_stats.sh prints a plan's first line that way) and
# they can lose their pipeline's status without changing any check, because the
# substitution is used as text. They are left alone on purpose rather than
# missed; the worst they do is print to stderr.
#
# Scoped to echo and printf deliberately for the same reason. A pipeline out of
# psql or a file is a different question with a different answer, and a rule that
# flagged those too would be argued with rather than kept.
# bench/ IS SCANNED TOO, and it was not. The PATTERN scoping to echo and printf
# is a stated decision above. The DIRECTORY scoping to test/ was never a decision
# at all -- it fell out of writing "$TESTDIR"/*.sh -- and bench/ held six
# instances of the exact shape this rule forbids, one of them guarding a premise
# loop with `|| continue`, in files the rule never looked at.
#
# They were latent rather than live: each writer is a printf of a few arm names,
# far under the 64 KB pipe buffer, so it completes before grep -q exits and never
# takes EPIPE. That is precisely the "passes almost every time and then does not"
# the control above demonstrates, which is the reason to fix them rather than to
# record that they happen to work.
#
# NON-RECURSIVE, one glob per directory, which is what the original did: it
# passed "$TESTDIR"/*.sh, so its -r never applied. Handing grep the DIRECTORIES
# instead would activate it and sweep test/selftest/ -- where this file's own
# explanation of the rule, and the deliberate piped() demo above, both match the
# pattern they exist to describe. Sweeping the file that enforces a rule for
# instances of that rule is selftest 260's mistake once removed.
_epipe_globs=("$TESTDIR"/*.sh)
[ -d "$TESTDIR/../bench" ] && _epipe_globs+=("$TESTDIR"/../bench/*.sh)
_epipe_hits="$(grep -nE '(echo|printf)[^|]*\|[[:space:]]*grep -[a-zA-Z]*q' \
	"${_epipe_globs[@]}" 2>/dev/null | grep -v '/harness_selftest.sh:' || true)"
_epipe_count="$(printf '%s' "$_epipe_hits" | grep -c . || true)"
[ -n "$_epipe_hits" ] || _epipe_count=0
check "no suite pipes a captured string into an early-exit reader" \
	"$_epipe_count" "0"
[ "$_epipe_count" = "0" ] || printf '%s\n' "$_epipe_hits" | sed 's/^/      /' | head -20

# And the scan has to be looking at something. A glob that matched nothing, or a
# TESTDIR that moved, would report zero hits and read as compliance.
_epipe_scanned="$(grep -lE 'grep' "${_epipe_globs[@]}" 2>/dev/null | grep -c . || true)"
check "and the scan examined the suites rather than finding nothing to read" \
	"$([ "${_epipe_scanned:-0}" -ge 20 ] && echo yes || echo "no (scanned $_epipe_scanned)")" "yes"

# bench/ IS SEPARATELY ASSERTED, and the check above cannot stand in for it.
# The bench glob is added conditionally, so if $TESTDIR/../bench ever stops
# resolving -- bench moved or renamed, this file relocated, a differently laid
# out worktree -- the && quietly drops it and the sweep reverts to test/ only.
#
# The count premise does not notice: test/*.sh alone matches 'grep' in 159 files
# against a threshold of 20, so it passes with bench/ silently absent. A count of
# files scanned is a premise that the sweep read SOMETHING. It is not a premise
# that it read the directory this rule was widened to cover, and it cannot tell
# "scanned test/ and bench/" from "scanned test/ and gave up on bench/".
#
# Which is this rule's own failure mode one level up: coverage narrowing with
# nothing able to see that it narrowed.
# Asserted on THE GLOB LIST THE SWEEP ACTUALLY USED, not by globbing bench/
# again here. The first version of this check did the latter -- it counted
# bench/*.sh matching 'grep' independently -- and so it asserted that bench/
# EXISTS, not that the sweep read it. Deleting the bench glob from _epipe_globs
# left it green. A check that cannot fail for the reason it names is the thing
# this whole file is about, and it took its own removal proof to see it.
_epipe_bench="$(printf '%s\n' "${_epipe_globs[@]}" | grep -c '/bench/' || true)"
check "and bench/ was in the scan, which is the hole this rule had" \
	"$([ "${_epipe_bench:-0}" -ge 1 ] && echo yes || echo "no (bench globs in sweep: $_epipe_bench)")" "yes"

