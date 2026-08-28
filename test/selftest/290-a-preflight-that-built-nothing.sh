# A preflight that built nothing must not report PASSED.
#
# test/build_all_versions.sh answers "does this compile on every major". Its
# verdict reads only `failed`, and only a build that RUNS and FAILS sets it. A
# pg_config that is not executable takes the `continue` above that, so a run
# where every major was skipped reaches the end with failed=0 and prints
# PASSED, exit 0, having invoked no compiler at all.
#
# FOUND THE EXPENSIVE WAY, 2026-08-28 (#809). The defaults are /usr/local/pg15,
# pg16, pg17, pgsql and pg19. The audit container has none of them -- every
# assert build there is a-suffixed, pg15a through pg19a -- so the no-argument
# form can never build anything on that machine. It was recorded as a green
# five-major preflight for a pull request and caught only by reading the body
# above the verdict:
#
#   SKIP  /usr/local/pg15/bin/pg_config      (not executable)     [x5]
#   build_all_versions.sh: PASSED
#
# WHY A COUNT RATHER THAN A STRICTER DEFAULT LIST. Hard-coding this box's paths
# would move the problem to the next machine. The verdict is what is wrong: it
# collapses "built five" and "built none" into one word. Its sibling
# run_all_versions.sh already prints `versions run: N of M configured`, and that
# line is the whole fix -- a reader sees the denominator, and zero is refused.
#
# SCOPE. This pins the all-skip case only. Whether a PARTIAL run (three of five
# present) should fail or warn is a judgement about how people run this, and is
# deliberately not decided here.

_bav_src="$PGC_TESTDIR/build_all_versions.sh"

# Run a COPY, in a scratch tree, because the real script ends with
# `make -C "$SRCDIR" clean` and SRCDIR is derived from the script's own
# location. Run in place, this selftest would wipe the object tree of the very
# build the surrounding suite is testing. In the scratch tree that make has no
# Makefile to find and fails into the script's own `|| true`.
_bav_dir="$(mktemp -d)"
mkdir -p "$_bav_dir/test"
cp "$_bav_src" "$_bav_dir/test/build_all_versions.sh"

# Three pg_config paths that certainly do not exist, so every major skips.
_bav_out="$(bash "$_bav_dir/test/build_all_versions.sh" \
	/nonexistent-a/bin/pg_config /nonexistent-b/bin/pg_config \
	/nonexistent-c/bin/pg_config 2>&1)"
_bav_rc=$?
rm -rf "$_bav_dir"

# PREMISE. The arm has to actually be the all-skip case. If a path above ever
# existed, or the skip line were reworded, every assertion below would be
# testing a run that did something, and would pass or fail for the wrong reason.
check "premise: the probe run skipped every major" \
	"$(printf '%s\n' "$_bav_out" | grep -c 'SKIP')" "3"
check "premise: and it built none of them" \
	"$(printf '%s\n' "$_bav_out" | grep -cE '^[[:space:]]*OK')" "0"

# The three things a verdict on zero builds must do.
check "a preflight that built nothing says how many it built" \
	"$(printf '%s\n' "$_bav_out" | grep -cE 'built 0 of 3')" "1"
check "a preflight that built nothing does not report PASSED" \
	"$(printf '%s\n' "$_bav_out" | grep -c 'build_all_versions.sh: PASSED')" "0"
check "a preflight that built nothing exits non-zero" \
	"$([ "$_bav_rc" -ne 0 ] && echo nonzero || echo "zero")" "nonzero"
