# ---- a missing pyarrow declines a suite; other dependencies still fail -----
#
# THE OWNER'S DECISION, 2026-10-12 (#1215). When pyarrow is absent, the 25 suites
# that call `pgc_skip pyarrow` report SKIPPED and exit 66, and the run does not
# fail. Every other missing dependency still FAILS unless it is waived, because
# the decision was about pyarrow only: `temporal.sh` without btree_gist is still
# a box that cannot gate that suite.
#
# Why a skip is safe for pyarrow and was not before: the nightly installs pyarrow
# and refuses to continue when the suites' interpreter cannot import it, so CI
# cannot lose these suites silently. A developer box without pyarrow is a
# supported configuration, and the run summary still names every skipped suite.
#
# The suites here source lib.sh and call pgc_skip without pgc_setup, so no
# cluster starts. Each differs from the others in one respect.

_mpd_lib="$PGC_TESTDIR/lib.sh"
_mpd_dir="$PGC_WORKDIR/missing_pyarrow"; mkdir -p "$_mpd_dir"

check "premise: lib.sh defines pgc_skip" \
	"$(grep -c '^pgc_skip()' "$_mpd_lib")" "1"

_mpd_make() {	# _mpd_make NAME BODY
	{
		printf '#!/usr/bin/env bash\n'
		printf '. "%s"\n' "$_mpd_lib"
		printf 'PGC_SUITE=%s\n' "$1"
		printf '%s\n' "$2"
	} > "$_mpd_dir/$1.sh"
	chmod 755 "$_mpd_dir/$1.sh"
}

# Run with every waiver cleared, so the caller's environment cannot decide the
# answer. `env -u` on a name that is not set is a no-op.
_mpd_run() {	# _mpd_run NAME [VAR=VALUE ...] -> "<exit> <verdict-word>"
	local name="$1" out rc; shift
	out="$(env -u PGC_ALLOW_MISSING -u PGC_ALLOW_MISSING_PYARROW \
		-u PGC_ALLOW_MISSING_BTREE_GIST "$@" bash "$_mpd_dir/$name.sh" 2>&1)"; rc=$?
	printf '%s %s' "$rc" "$(printf '%s' "$out" | grep -oE '(PASSED|FAILED|INCOMPLETE|SKIPPED)' | tail -1)"
}

_mpd_records() {	# _mpd_records NAME VERDICT -> how many RESULT records carry VERDICT
	env -u PGC_ALLOW_MISSING -u PGC_ALLOW_MISSING_PYARROW \
		-u PGC_ALLOW_MISSING_BTREE_GIST bash "$_mpd_dir/$1.sh" 2>&1 |
		awk -F'\t' -v v="$2" '$1 == "RESULT" && $5 == v' | wc -l | tr -d ' '
}

_mpd_make nopyarrow 'pgc_skip pyarrow "pyarrow is required to write the fixture"'
_mpd_make nogist 'pgc_skip btree_gist "btree_gist is required for WITHOUT OVERLAPS"'

check "a missing pyarrow declines the suite instead of failing it" \
	"$(_mpd_run nopyarrow)" "66 SKIPPED"
check "and it records a skip under the check's own name, not a failure" \
	"$(_mpd_records nopyarrow SKIP)/$(_mpd_records nopyarrow FAIL)" "1/0"

check "control: a missing btree_gist still fails the suite" \
	"$(_mpd_run nogist)" "1 FAILED"
check "control: and an explicit waiver still turns that failure into a skip" \
	"$(_mpd_run nogist PGC_ALLOW_MISSING_BTREE_GIST=1)" "66 SKIPPED"

rm -rf "$_mpd_dir"
