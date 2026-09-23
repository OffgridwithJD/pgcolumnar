# ---- deciding "is this a checkout" must ask git, not stat .git (#1224) -------
#
# A linked worktree's `.git` is a regular FILE containing `gitdir: <path>`, not a
# directory. So does a tree staged with the one-line gitfile devloop.sh writes
# into its build dir, and so does an agent's copy staged across a container
# boundary. In all three git answers perfectly and `[ -d "$SRCDIR/.git" ]` is
# false.
#
# extension_upgrade.sh decided that way in two places and skipped its default
# path in every one of those environments -- including "the audit container,
# worktrees of a clone", which selftest 310 names as one of the five
# environments this harness runs in. A supported environment could not run that
# suite.
#
# THE TREE ALREADY HAD THE RIGHT TEST, TWO DIRECTORIES AWAY. devloop.sh uses
# `rev-parse --absolute-git-dir` and says why: "SRC may itself be a linked
# worktree, where .git is a FILE and that path is not a git directory."
# docs_style.sh and native_upgrade_converge.sh use rev-parse too. The defect was
# one file against three, not a missing idiom.
#
# THIS ARM IS A CLASS GUARD, NOT A LIST. It asks whether any suite decides the
# question by stat-ing `.git`, which is derived from the text rather than
# enumerated -- so a fourth file adopting the wrong form is caught without
# anyone maintaining a roster.

# PREMISE FIRST: the sweep must be able to match something. A pattern that
# cannot match reports zero, and zero is exactly the answer this arm wants --
# which is how a guard for wrong patterns ships with a wrong pattern.
_ck_mentions="$(sed 's/#.*//' "$PGC_TESTDIR"/*.sh 2>/dev/null | grep -c '\.git')"
check_num "premise: the sweep sees .git mentioned in the suites at all" \
	"$(if [ "$_ck_mentions" -ge 1 ]; then echo 1; else echo 0; fi)" "1"

# AND that the correct idiom exists, so arm two is not asserting an empty world.
_ck_right="$(grep -lE 'rev-parse --(git-dir|absolute-git-dir|is-inside-work-tree)' \
	"$PGC_TESTDIR"/*.sh 2>/dev/null | wc -l)"
check_num "premise: some suite already asks git whether it can answer" \
	"$(if [ "$_ck_right" -ge 1 ]; then echo 1; else echo 0; fi)" "1"

_ck_stat="$(sed 's/#.*//' "$PGC_TESTDIR"/*.sh "$PGC_TESTDIR"/selftest/*.sh 2>/dev/null |
	grep -cE '\-d[[:space:]]+"?\$?\{?[A-Za-z_]*\}?/?\.git')"
check_num "no suite decides it is a checkout by stat-ing .git as a directory" \
	"$_ck_stat" "0"

# THE BEHAVIOUR THE ARM ABOVE IS ABOUT, driven rather than described, so the
# rule is not just a spelling preference. A gitfile is what every one of the
# three environments produces.
# STATED WITH stat, NOT PROBED WITH THE FORBIDDEN FORM. The first version of
# this arm demonstrated the point by writing `[ -d "$_ck_dir/.git" ]` -- and the
# sweep above then counted its own demonstration and stayed red after both real
# sites were fixed. A guard whose own text satisfies its pattern is the defect
# it exists to catch, one level up.
_ck_dir="$(mktemp -d)"
printf 'gitdir: %s\n' "$_ck_dir/nowhere" > "$_ck_dir/.git"
check_text "a gitfile is a regular file, which a directory test cannot accept" \
	"$(stat -c %F "$_ck_dir/.git" 2>/dev/null)" "regular file"
check_text "and it is still a .git that a reader must not skip on" \
	"$(if test -e "$_ck_dir/.git"; then echo present; else echo absent; fi)" "present"
rm -rf "$_ck_dir"
