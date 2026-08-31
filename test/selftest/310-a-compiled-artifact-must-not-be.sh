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
# silenced by deleting .git is not a guard, and the two arms below have no
# meaning without it: `git ls-files` printing nothing and `git ls-files` finding
# nothing wrong are the same output. Every environment this suite runs in is a
# checkout -- CI checks out with .git, run_all_versions.sh stages the tree with
# `cp -a "$SRCDIR/."` which copies it, and the container worktrees are clones.
#
# SCOPE. Python only. The tree tracks Iceberg .avro/.puffin and Parquet
# fixtures, which are inputs rather than output and are meant to be there;
# .gitignore already covers the C artifacts (*.o, *.so, *.bc). Whether every
# derived file in the tree deserves one rule is a larger judgement and is
# deliberately not decided here.

_pyc_root="$(cd "$PGC_TESTDIR/.." && pwd)"

# PREMISE. git has to be able to answer, and it has to be answering about THIS
# tree. Without this the two arms below pass on an empty answer.
check_text "premise: the source tree is a git checkout" \
	"$(git -C "$_pyc_root" rev-parse --is-inside-work-tree 2>/dev/null || echo no)" \
	"true"

# PREMISE. And it has to see a populated tree. A working `git` pointed at the
# wrong directory, or an index nobody has written, returns success and nothing.
check_text "premise: and git ls-files sees the harness it is being asked about" \
	"$(git -C "$_pyc_root" ls-files --error-unmatch test/lib.sh 2>/dev/null)" \
	"test/lib.sh"

# PREMISE, positive control. check-ignore has to say "ignored" for something the
# tree already ignores, or the second arm below fails for the wrong reason
# before the fix and cannot fail at all after it.
check_text "premise: check-ignore agrees a build object is already ignored" \
	"$(git -C "$_pyc_root" check-ignore -q -- foo.o && echo ignored || echo not-ignored)" \
	"ignored"

# PREMISE, negative control. And it has to say "not ignored" for a source file,
# or a check-ignore that answers "ignored" to everything makes the arm vacuous.
check_text "premise: and that a tracked source file is not" \
	"$(git -C "$_pyc_root" check-ignore -q -- test/lib.sh && echo ignored || echo not-ignored)" \
	"not-ignored"

# ---- the rule itself --------------------------------------------------------

# Named, not merely counted: the failure has to say which file, because the
# next one will not be this one.
_pyc_tracked="$(git -C "$_pyc_root" ls-files -- '*.pyc' '*.pyo' '*/__pycache__/*' '__pycache__/*' \
	| sort | tr '\n' ' ')"
check_num "no compiled Python artifact is tracked" \
	"$(printf '%s' "$_pyc_tracked" | wc -w)" "0"
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
	"$(git -C "$_pyc_root" check-ignore -q -- test/__pycache__/x.cpython-312.pyc.140234 \
		&& echo ignored || echo not-ignored)" \
	"ignored"

check_text "and a compiled artifact written beside its source" \
	"$(git -C "$_pyc_root" check-ignore -q -- test/x.pyc && echo ignored || echo not-ignored)" \
	"ignored"

unset _pyc_root _pyc_tracked
