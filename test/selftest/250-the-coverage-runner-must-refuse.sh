# ---- the coverage runner must refuse a run that captured no counters --------
#
# #740. The nightly coverage job failed every night from the night it was added
# (2026-07-31) and had never measured anything. It runs under sudo, so the build
# is root-owned, while lib.sh runs the server as `postgres` when it is root
# (lib.sh:150). gcov writes each .gcda beside its object, as the process that ran
# the code, so the backend could not create one and `lcov --capture` found
# nothing.
#
# What kept it unexamined for 25 nights was the ORDER of the failure. lcov failing
# on an empty tree reports "capture produced nothing", which reads as a broken
# tool rather than as a permission problem, so nobody looked. run_coverage.sh now
# refuses the run itself, before lcov, and says where the counters should have
# been. That ordering is the thing worth pinning: with the refusal after the
# capture it would be dead code and the misleading message would be back.

_cov="$TESTDIR/run_coverage.sh"
check "premise: the coverage runner is present and parses" \
	"$(bash -n "$_cov" 2>/dev/null && echo yes || echo no)" "yes"

_cov_guard=$(grep -n 'no .gcda counters were written' "$_cov" | cut -d: -f1 | head -1)
# The CAPTURE specifically. The runner also calls `lcov --directory ...
# --zerocounters` BEFORE the suites, at a lower line number, and matching that
# one made this check compare the guard against the wrong call and report a
# defect that was not there.
_cov_lcov=$(grep -n 'lcov --directory .*--capture' "$_cov" | cut -d: -f1 | head -1)

check "premise: both the counter refusal and the lcov capture were located" \
	"$([ -n "$_cov_guard" ] && [ -n "$_cov_lcov" ] && echo yes || echo no)" "yes"

# The whole point: refuse BEFORE lcov turns an empty tree into a tooling error.
check "the coverage runner refuses zero counters before it calls lcov (#740)" \
	"$([ -n "$_cov_guard" ] && [ -n "$_cov_lcov" ] &&
	   [ "$_cov_guard" -lt "$_cov_lcov" ] && echo yes || echo no)" "yes"

# ---- and the counters must be redirected somewhere always writable ---------
#
# Chowning the object directories to the server user was the first fix and it is
# NOT sufficient: creating a file needs execute on every ANCESTOR too, and in CI
# the tree sits under the runner's home. With an ancestor at mode 700 the chown
# succeeds, the directories are writable in themselves, and zero counters are
# still written. GCOV_PREFIX sidesteps the whole question by sending them to
# /tmp, which is world-writable and world-traversable.
#
# Two ORDERING facts carry the fix, and order is what these check. Neither is
# visible from the presence of the lines alone.
_cov_export=$(grep -n '^export GCOV_PREFIX' "$_cov" | cut -d: -f1 | head -1)
_cov_run=$(grep -n 'bash "\$SRCDIR/test/\${s}\.sh"' "$_cov" | cut -d: -f1 | head -1)
_cov_back=$(grep -n 'counters returned beside their objects' "$_cov" | cut -d: -f1 | head -1)

check "premise: the redirect, the suite invocation and the copy-back were located" \
	"$([ -n "$_cov_export" ] && [ -n "$_cov_run" ] && [ -n "$_cov_back" ] &&
	   echo yes || echo no)" "yes"

# Set after the suites have run, it redirects nothing.
check "GCOV_PREFIX is exported before the suites run (#740)" \
	"$([ -n "$_cov_export" ] && [ -n "$_cov_run" ] &&
	   [ "$_cov_export" -lt "$_cov_run" ] && echo yes || echo no)" "yes"

# Copied back after the refusal, the refusal always sees zero.
check "the counters are returned beside their objects before the refusal (#740)" \
	"$([ -n "$_cov_back" ] && [ -n "$_cov_guard" ] &&
	   [ "$_cov_back" -lt "$_cov_guard" ] && echo yes || echo no)" "yes"

# ---- and it must count the directory that is actually captured -------------
#
# Reported on the #745 review. The refusal counted .gcda across the WHOLE tree
# while `lcov --capture` is scoped to src/. objstore/ is a separate shared
# library built alongside this one (Makefile:127) and contributes its own .gcno
# and .gcda, so a tree with zero counters in src/ and one in objstore/ gives the
# guard a non-zero count, it passes, and lcov captures nothing: the "capture
# produced nothing" message this guard exists to pre-empt, back again.
#
# Constructed and confirmed rather than argued: 33 .gcno in src/ with no
# counters, one .gcda in objstore/, tree-wide count 1 (passes), src-scoped
# count 0 (refuses).
#
# Compared as SOURCE TEXT, so this pins the two to each other. Widening the
# capture later without widening the count re-opens the same hole.
_cov_count_dir=$(grep '^_gcda=\$(find ' "$_cov" |
	sed -n 's/.*find "\([^"]*\)".*/\1/p' | head -1)
_cov_cap_dir=$(grep 'lcov --directory .*--capture' "$_cov" |
	sed -n 's/.*--directory "\([^"]*\)".*/\1/p' | head -1)

check "premise: the guard's count directory and the capture's were both located" \
	"$([ -n "$_cov_count_dir" ] && [ -n "$_cov_cap_dir" ] && echo yes || echo no)" "yes"

check "the zero-counter guard counts the directory lcov captures (#740)" \
	"$_cov_count_dir" "$_cov_cap_dir"
