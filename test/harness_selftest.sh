#!/usr/bin/env bash
#
# Self-test for the harness's own cluster-identity guard.
#
# lib.sh retries a failed start on a fresh port, and pg_ctl -w only proves that
# *something* answers there. Without a guard, a suite whose port is already owned
# by another postmaster runs every statement against that cluster: its log grows a
# stray "database already exists" while this suite's own objects are invisible.
# That hides real failures as easily as it invents fake ones, so the guard is
# load-bearing and gets a test of its own.
#
# This stands up a squatter cluster on a known port, points a suite straight at
# it, and asserts the suite ends up on a cluster it owns, that the squatter is
# left alone, and that the suite's own objects are actually there.
#
# Usage:  test/harness_selftest.sh [PG_CONFIG]
# Written fresh for pgColumnar.


# portlib.sh alone, not lib.sh: this suite carries its own harness, and the port
# band is needed before any of it runs. Sourcing portlib twice is harmless.
. "$(dirname "${BASH_SOURCE[0]}")/portlib.sh"

set -uo pipefail

PGC_SELFTEST_PG_CONFIG="${1:-/usr/local/pg17/bin/pg_config}"
_bindir="$("$PGC_SELFTEST_PG_CONFIG" --bindir)"

# ---- the checks themselves live in test/selftest/, one file per subject ------
#
# They used to be appended here, and that is what #554 is about: three PRs in one
# day each added a block at the end of this file and each pair conflicted, while
# the one PR that edited the middle merged clean. It is the same failure this
# file argues about for SUITES, in the file that argues it -- "one per line, both
# appended at the end -> CONFLICT".
#
# The fix is the same shape as the SUITES fix: give an addition an insertion
# point decided by its content rather than by "the end". Here the unit is a FILE,
# so adding a subject touches no line anybody else is editing. The glob is
# sorted, so the order is the numeric prefix and not the order of the loop.
#
# Sourced, not executed: they share the squatter cluster, the helpers above and
# the check counter, exactly as they did when they were one file.
# The parts are SOURCED, so ${BASH_SOURCE[0]} inside one of them names the part,
# not this file: `dirname` would give test/selftest and every path built from it
# would miss by a directory. So the directory is resolved ONCE here and the parts
# use it. Measured the hard way -- the first split kept BASH_SOURCE in the parts,
# every helper lookup resolved to test/selftest/lib.sh, and the suite ran zero
# checks while every static check I had (byte-identity, parse, check-name order)
# still passed.
PGC_TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _sf in "$PGC_TESTDIR"/selftest/*.sh; do
	[ -e "$_sf" ] || { echo "FAIL  no selftest parts found; the suite would report zero checks"; PGC_FAIL=1; break; }
	# shellcheck source=/dev/null
	. "$_sf"
done

pgc_summary

