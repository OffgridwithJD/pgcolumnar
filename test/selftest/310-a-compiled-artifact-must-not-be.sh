# A compiled Python artifact must not be tracked, and the tree must ignore one.
#
# CPython writes a compiled copy of every module it imports into __pycache__.
# Those files are build output: derived, machine-specific, and rewritten by the
# interpreter without anyone asking. Committing one gives it a life of its own.
#
# FOUND THE EXPENSIVE WAY, 2026-08-31 (#854). test/__pycache__/ste_check.cpython-312.pyc
# was tracked at 0e4884c1. Its source, test/ste_check.py, was renamed to
# test/plain_language_check.py in e9de048 -- 135 commits earlier. The .pyc did
# not follow the rename, so the tree carried 6,028 bytes of compiled code for a
# module that no longer exists and that CPython would never open anyway: it
# reads a __pycache__ entry only when the matching source sits beside it.
#
# It had already attached itself to an unrelated commit. cec104f is a logical
# replication fix (#435) and its diffstat carries
# "test/__pycache__/ste_check.cpython-312.pyc | Bin 6028 -> 6028 bytes". Exactly
# two bytes differ, at offsets 9 and 10 -- the PEP 552 source-timestamp word,
# 1785516574 -> 1785525429. The compiled code was identical either side
# (src_size 4164 on both). Somebody's checkout re-stamped the source, Python
# rewrote the header, git recorded a binary diff, and it rode into a commit
# about logical replication. That is the whole failure mode: a tracked build
# artifact joins whichever commit is next.
#
# WHY THE RULE IS ANCHORED ON git AND NOT ON THE FILESYSTEM. "no __pycache__
# under test/" would redden any developer who has just run the interpreter, and
# their tree being dirty is not this project's business. What is this project's
# business is what the repository RECORDS, and that is a question only git can
# answer. It is also the second half of the rule: ignoring the directory is
# what stops the deletion being undone by the next `git add -A`.
#
# WHY THIS FAILS RATHER THAN SKIPS OUTSIDE A CHECKOUT. A guard that can be
# silenced by deleting .git is not a guard. So every arm below answers `no-repo`
# where there is no repository, rather than the answer git gives by default:
# `ls-files` prints nothing, which is indistinguishable from a clean tree, and
# `check-ignore` says "not ignored", which reports a present rule as missing.
# Both would mislead, in opposite directions, and the second one did -- see #855.
# The premises then name the cause rather than leaving a reader to infer it.
#
# WHERE THIS SUITE ACTUALLY RUNS, surveyed rather than assumed, because the first
# version of this comment claimed "every environment is a checkout" and one was
# not:
#   CI                    actions/checkout writes .git.                     ok
#   run_all_versions.sh   stages with `cp -a "$SRCDIR/."`, which copies .git
#                         (and, from a linked worktree, copies the gitfile,
#                         whose path is absolute and still resolves).        ok
#   the audit container   worktrees of a clone.                             ok
#   test/devloop.sh       stages with `tar --exclude=.git`, deliberately: it
#                         is 32 MB and the loop is meant to be cheap. That
#                         produced FIVE reds on a clean tree. devloop.sh now
#                         writes a one-line gitfile into the build dir, which
#                         costs no bytes and makes the question answerable.  ok
#   an agent's staged     `tar --exclude=.git` into ANOTHER MACHINE, where
#   working copy          devloop's fix does not transfer: the gitfile would
#                         name a path on the host that the container cannot
#                         resolve. Stage the gitdir once inside the container
#                         and point every tree at that instead.              ok
#                         Measured: twenty reds and `rc=1 FAILED` without it,
#                         `rc=0 PASSED` with. READ-ONLY consumers only -- N
#                         trees sharing one stage share HEAD and the index, so
#                         fetch and check out in the tree that owns a real
#                         .git and stage the result. Verified that reads leave
#                         the stage byte-identical.
#
# THAT FIFTH ONE COST A WHOLE SESSION, which is why it is here rather than in a
# commit message. Twenty permanently-red arms do not merely lose their own
# signal: they make the suite's VERDICT unreadable, so a later change that
# turned the run EXIT_INCOMPLETE was not missed, it was unreachable. The reds
# had an explanation, the explanation was correct, and it was load-bearing for
# a whole session of wrong conclusions.
#
# SCOPE. Python artifacts, and git bundles. The tree tracks Iceberg
# .avro/.puffin and Parquet fixtures, which are inputs rather than output and are
# meant to be there; .gitignore already covers the C artifacts (*.o, *.so, *.bc).
# Whether every derived file deserves one rule is still a larger judgement and is
# still not decided here.
#
# THE SECOND CLASS WAS ADDED THE SAME WAY AS THE FIRST: expensively. Nine git
# bundles, 76,194 bytes, went into c697c8cd -- a merged commit whose subject is a
# check name in sorted_pathkeys.sh. I made them in my clone to move a branch into a
# container and then staged with `git add -A`, which is the same mechanism the
# comment above calls out for the .pyc: a tracked artifact joins whichever commit is
# next. Nothing caught it. Five suites and the whole selftest ran green either side,
# because no suite has any opinion about files it does not read.
#
# A BUNDLE IS A TRANSFER ARTIFACT, which is why it belongs with the .pyc and not
# with the Parquet fixtures. It is derived from commits that are already in the
# history, it is named after whatever branch was in flight, nothing in the tree
# opens one, and the next person to make one will give it a different name -- so it
# can never be a fixture somebody depends on. The same two-part rule therefore
# applies: not tracked, and ignored, because ignoring is what stops the deletion
# being undone by the next `git add -A`.

_pyc_root="$(cd "$PGC_TESTDIR/.." && pwd)"
_pyc_repo="$(git -C "$_pyc_root" rev-parse --is-inside-work-tree 2>/dev/null || echo no)"

# Every arm goes through these two, so that "there is no repository to ask" is
# never reported as an answer about the repository.
_pyc_tracked_list() {
	[ "$_pyc_repo" = true ] || { printf 'no-repo'; return; }
	git -C "$_pyc_root" ls-files -- '*.pyc' '*.pyo' '*/__pycache__/*' '__pycache__/*' \
		| sort | tr '\n' ' '
}
_pyc_ignored() {  # _pyc_ignored PATH -> ignored | not-ignored | no-repo
	[ "$_pyc_repo" = true ] || { echo no-repo; return; }
	git -C "$_pyc_root" check-ignore -q -- "$1" && echo ignored || echo not-ignored
}

_pyc_bundles() {	# -> the tracked git bundles, or `no-repo`
	[ "$_pyc_repo" = true ] || { printf 'no-repo'; return; }
	git -C "$_pyc_root" ls-files -- '*.bundle' | sort | tr '\n' ' '
}

# PREMISE. git has to be able to answer, and it has to be answering about THIS
# tree.
check_text "premise: the source tree is a git checkout" "$_pyc_repo" "true"

# PREMISE. And it has to see a populated tree. A working `git` pointed at the
# wrong directory, or an index nobody has written, returns success and nothing.
check_text "premise: and git ls-files sees the harness it is being asked about" \
	"$(git -C "$_pyc_root" ls-files --error-unmatch test/lib.sh 2>/dev/null)" \
	"test/lib.sh"

# PREMISE, positive control. check-ignore has to say "ignored" for something the
# tree already ignores, or the second arm below fails for the wrong reason
# before the fix and cannot fail at all after it.
check_text "premise: check-ignore agrees a build object is already ignored" \
	"$(_pyc_ignored foo.o)" "ignored"

# PREMISE, negative control. And it has to say "not ignored" for a source file,
# or a check-ignore that answers "ignored" to everything makes the arm vacuous.
check_text "premise: and that a tracked source file is not" \
	"$(_pyc_ignored test/lib.sh)" "not-ignored"

# ---- the rule itself --------------------------------------------------------

# Named, not merely counted: the failure has to say which file, because the
# next one will not be this one.
_pyc_tracked="$(_pyc_tracked_list)"
check_text "no compiled Python artifact is tracked" \
	"$([ "$_pyc_tracked" = no-repo ] && echo no-repo \
		|| printf '%s tracked' "$(printf '%s' "$_pyc_tracked" | wc -w)")" \
	"0 tracked"
check_text "and the tracked list names none of them" \
	"[${_pyc_tracked}]" "[]"

# The other half: with no ignore rule, the deletion above lasts until the next
# `git add -A` on a tree where somebody has imported a module.
#
# Two rules are needed and each probe below is chosen so that exactly one of
# them answers it. A probe named `x.cpython-312.pyc` would be ignored by either
# rule, which would leave neither provably load-bearing:
#
#   test/__pycache__/x.cpython-312.pyc.140234  only `__pycache__/` catches this.
#       Not a contrived name: CPython writes the compiled file atomically, to
#       `<final>.<id>` and then renames, so a killed interpreter leaves one.
#   test/x.pyc                                 only `*.pyc` catches this, and it
#       is where CPython put compiled files before PEP 3147.
check_text "and the tree ignores the directory Python writes them to" \
	"$(_pyc_ignored test/__pycache__/x.cpython-312.pyc.140234)" "ignored"

check_text "and a compiled artifact written beside its source" \
	"$(_pyc_ignored test/x.pyc)" "ignored"

# ---- and a transfer artifact is the same rule, for the same reason ------------

# Counted rather than compared against an empty string: `check_text` refuses a side
# that is empty, because "nothing was compared" and "the two agreed" are the same
# observation otherwise. My first version of these three arms compared against "" and
# all three were refused on exactly that ground -- the harness catching an arm that
# asserted nothing.
_pyc_bund="$(_pyc_bundles)"
check_text "no git bundle is tracked" \
	"$([ "$_pyc_bund" = no-repo ] && echo no-repo \
		|| printf '%s tracked' "$(printf '%s' "$_pyc_bund" | wc -w)")" \
	"0 tracked"
# Named for the thing it lists, not "them": the Python half four arms up already owns
# `and the tracked list names none of them`, and the ledger's duplicate-name detector
# caught the collision on the first merge -- `distinct checks this merge=866` against
# `checks run=867`. #982's defect, created in the session that finished removing the
# last of its 24 instances.
check_text "and the tracked BUNDLE list names none of them" \
	"[${_pyc_bund}]" "[]"

# The other half, as for the .pyc: without the ignore rule the deletion lasts until
# the next `git add -A` in a clone where somebody has moved a branch about.
check_text "and the tree ignores a git bundle, so the next add cannot re-add it" \
	"$(_pyc_ignored some-branch.bundle)" "ignored"

# CONTROL. The rule keys on the SUFFIX, so a source file merely named like one must
# not be swept up -- and without this, a check-ignore answering "ignored" to
# everything would make the arm above vacuous.
check_text "control: a source file named like a bundle is not ignored" \
	"$(_pyc_ignored test/bundle_notes.sh)" "not-ignored"

unset _pyc_root _pyc_tracked _pyc_repo _pyc_bund
unset -f _pyc_tracked_list _pyc_ignored _pyc_bundles
