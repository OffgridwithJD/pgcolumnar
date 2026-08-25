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

# And the directories it makes writable are DERIVED from where the
# instrumentation landed. Objects are in src/ and objstore/ today; a hardcoded
# src/ would stop covering a directory added later, silently.
check "the counter directories are derived from the .gcno files, not named (#740)" \
	"$(awk '/id -u/,/^fi$/' "$_cov" | grep -c 'gcno')" "1"
