#!/usr/bin/env bash
#
# Compile the extension against every installed major.
#
# The per-PR gate runs the suites on two majors, which is the right trade for
# test time and cannot see a defect on a major it never builds. That is not
# hypothetical: scan_analyze_next_block changed signature at PG17, a change
# guarded the callback at PG18 instead, and PG15, PG16, PG18 and PG19 all built
# fine while main did not compile on PG17 at all. A two-major gate reported it
# green.
#
# This is the cheap half of the answer: no clusters, no suites, just a compile
# against each major, which takes about a minute for all five. Run it before
# merging anything that touches a version guard, a table AM callback signature,
# or columnar_compat.h. The full matrix remains the thorough half.
#
# Usage:
#   test/build_all_versions.sh [pg_config ...]
#
# With no arguments it builds against the same default set the version matrix
# uses. Exits non-zero on the first major that fails, and prints its errors.

set -uo pipefail

SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# THE MATRIX'S LIST, READ RATHER THAN COPIED (#1219).
#
# This file carried its own copy of run_all_versions.sh's DEFAULT_CONFIGS. The two
# were identical, so the rot was latent rather than live -- but a major moving in
# one and not the other means this compiles against a set the GATE DOES NOT USE,
# and reporting "builds on every major" about the wrong majors is the failure this
# script exists to prevent, one level up.
#
# Not hypothetical as a shape: the runner's PG18 is /usr/local/pgsql, which is
# not the path a reader guesses, and @jdatcmd spent four probes on a phantom
# regression after hand-picking pg18_nc as "the" PG18 instead of reading this
# array. A person choosing majors by hand makes the same mistake a stale copy
# does.
#
# Evalled out of the runner the way selftest 530 evals its reader, rather than
# restating it: a check that recomputes a rule tests the world instead of the code.

# THE DEFAULT LIST IS ONLY READ WHEN IT IS GOING TO BE USED (@jdatcmd, review).
#
# The refusals below tell the reader that naming pg_config paths as arguments
# bypasses them. That was FALSE while the block was read before `$#` was
# examined: someone with a malformed array who did exactly what the message said
# got the same refusal. A message that sends the reader where the code will not
# take them is this file's own subject, one level in.
if [ "$#" -gt 0 ]; then
	CONFIGS=("$@")
else
	_bav_runner="$SRCDIR/test/run_all_versions.sh"

	# THE CAPTURED BLOCK IS VALIDATED BEFORE IT IS EVALLED, and that is not
	# belt-and-braces (@jdatcmd, #1225 review).
	#
	# `/^)/` does not match an INDENTED terminator, and the runner's own `SUITES=(`
	# closes with a tab before the paren -- so matching that style is a natural edit
	# rather than a hypothetical. With a tabbed `)` the sed range runs to end of file
	# and eval executes about 1500 lines of the runner: it clobbers this script's
	# variables (SRCDIR among them, which its own refusal then prints as `//test/...`)
	# and is stopped only by `set -u` hitting an unbound variable. Bounded by accident
	# rather than by design.
	#
	# So: accept either terminator, and refuse anything whose lines are not the
	# opener, a path, or the closer. A handful of lines, never fifteen hundred.
	_bav_block="$(sed -n '/^DEFAULT_CONFIGS=(/,/^[[:space:]]*)[[:space:]]*$/p' \
		"$_bav_runner" 2>/dev/null)"
	_bav_junk="$(printf '%s\n' "$_bav_block" | grep -cvE \
		'^(DEFAULT_CONFIGS=\(|[[:space:]]*/[A-Za-z0-9._/+-]+[[:space:]]*|[[:space:]]*\)[[:space:]]*)$')"
	# TWO CAUSES, TWO SENTENCES. An absent array and a malformed one are different
	# repairs -- one adds it back, the other fixes its shape -- and printing "N lines
	# were something else" for an EMPTY capture would be the same defect this file
	# already fixes for "could not read" versus "none installed", one level in.
	if [ -z "$_bav_block" ]; then
		echo "FATAL: no DEFAULT_CONFIGS array found in $_bav_runner" >&2
		echo "       (naming pg_config paths as arguments bypasses this)" >&2
		exit 1
	elif [ "$_bav_junk" -ne 0 ]; then
		echo "FATAL: the major list in $_bav_runner is not the shape this reads" >&2
		echo "       (expected DEFAULT_CONFIGS=( , paths, ) and nothing else;" >&2
		echo "        $_bav_junk line(s) were something else, so nothing was evalled)" >&2
		exit 1
	fi
	eval "$_bav_block"
	CONFIGS=("${DEFAULT_CONFIGS[@]:-}")
	# A LIST THAT COULD NOT BE READ IS NOT A LIST OF ZERO MAJORS, and the two
	# must not print the same sentence. Without this, a renamed array or a moved
	# runner gives "built 0 of 0" -- which reads exactly like a host that has
	# none of the majors installed, and sends the reader to their PATH instead of
	# to this line.
	if [ "${#CONFIGS[@]}" -eq 0 ] || [ -z "${CONFIGS[0]}" ]; then
		echo "FATAL: no default majors could be read from $_bav_runner" >&2
		echo "       (expected a DEFAULT_CONFIGS=( ... ) array there; naming" >&2
		echo "        pg_config paths as arguments bypasses this)" >&2
		exit 1
	fi
fi

echo "== pgColumnar build check across majors =="

failed=0
# Remove every build artifact from a tree, and SAY WHETHER IT WORKED (#1219).
#
# The final sweep used to be `make -C "$SRCDIR" clean >/dev/null 2>&1 || true`
# with no PG_CONFIG. PGXS resolves `pg_config` from PATH, so on a box with no
# packaged one that make fails, the `|| true` eats the failure, and the tree
# keeps the last major's objects while the script still prints PASSED. Measured,
# same tree, pg18a then pg19a:
#
#     normal PATH              built 2 of 2  PASSED   objects left:  0
#     PATH with no pg_config   built 2 of 2  PASSED   objects left: 36
#
# PASSING A pg_config IS NOT THE FIX. `make clean` needs PGXS loaded to do
# anything at all, objects live in src/ AND objstore/, and a clean whose failure
# is swallowed cannot be told from one that worked. So: try make when a
# pg_config is at hand, because PGXS knows about artifacts this sweep does not
# name; then remove by find, which needs no pg_config; then VERIFY, because a
# sweep that reports nothing is the defect being fixed.
# THE DETECTOR IS ITS OWN FUNCTION so it can be judged directly. Folded into
# the cleaner it was unreachable: in every fixture the sweep works, so `clean` is
# the right answer and a cleaner that ALWAYS says `clean` reddens nothing.
# Measured -- that mutation passed all five arms. Splitting it out is what gives
# the detection logic a killer; the belt-and-braces re-check inside the cleaner
# still only fires when the sweep fails, which cannot be staged as root, and
# that residue is recorded rather than papered over.
pgc_bav_tree_has_objects() {	# pgc_bav_tree_has_objects DIR -> yes|no
	local _d="${1:-}"
	[ -n "$_d" ] && [ -d "$_d" ] || { echo no; return; }
	if [ -n "$(find "$_d" \( -name '*.o' -o -name '*.bc' -o -name '*.so' \) -type f 2>/dev/null | head -1)" ]; then
		echo yes
	else
		echo no
	fi
}

pgc_bav_clean_tree() {	# pgc_bav_clean_tree SRCDIR [PG_CONFIG] -> clean|dirty
	local _d="${1:-}" _pgc="${2:-}"
	[ -n "$_d" ] && [ -d "$_d" ] || { echo dirty; return; }
	[ -n "$_pgc" ] && make -C "$_d" clean PG_CONFIG="$_pgc" >/dev/null 2>&1
	find "$_d" \( -name '*.o' -o -name '*.bc' -o -name '*.so' \) -type f -delete 2>/dev/null
	[ "$(pgc_bav_tree_has_objects "$_d")" = yes ] && echo dirty || echo clean
}

built=0
for pgc in "${CONFIGS[@]}"; do
	if [ ! -x "$pgc" ]; then
		printf '  SKIP  %-34s (not executable)\n' "$pgc"
		continue
	fi

	ver="$("$pgc" --version)"
	log="$(mktemp /tmp/pgc-build-XXXXXX.log)"

	make -C "$SRCDIR" clean PG_CONFIG="$pgc" >/dev/null 2>&1
	if make -C "$SRCDIR" PG_CONFIG="$pgc" > "$log" 2>&1; then
		# -Werror is not set, so a warning still builds; report it rather than
		# let a new one accumulate unnoticed across majors.
		warns="$(grep -cE '^[^ ].*\bwarning:' "$log")"
		built=$((built + 1))
		printf '  OK    %-34s %s warning(s)\n' "$ver" "$warns"
		[ "$warns" != "0" ] && grep -E '^[^ ].*\bwarning:' "$log" | head -5 | sed 's/^/          /'
	else
		printf '  FAIL  %s\n' "$ver"
		grep -E '\berror:' "$log" | head -8 | sed 's/^/          /'
		failed=1
	fi
	rm -f "$log"
done

# Leave no object tree behind from whichever major happened to be last: the next
# build against a different major would link objects compiled for this one. The
# verdict is read rather than discarded -- the previous form swallowed its own
# failure and left the tree dirty on any box without a pg_config on PATH (#1219).
if [ "$(pgc_bav_clean_tree "$SRCDIR" "${pgc:-}")" != clean ]; then
	echo "build_all_versions: objects remain in $SRCDIR after the final sweep;" >&2
	echo "       the next build against another major would link them" >&2
	failed=1
fi

# What was actually compiled, next to what was asked for. Without this line the
# verdict below collapses "built five" and "built none" into the same word: a
# pg_config that is not executable is skipped above without touching `failed`,
# so a run that invoked no compiler at all reached PASSED and exit 0 (#809). The
# sibling run_all_versions.sh prints the same shape, `versions run: N of M`.
echo "  built $built of ${#CONFIGS[@]}"

if [ "$failed" != "0" ]; then
	echo "build_all_versions.sh: FAILED"
	exit 1
fi

# Zero is refused rather than reported. A preflight that compiled nothing has
# not answered the question it was run to answer, and the most likely cause is
# that this machine keeps its builds somewhere other than the default list --
# which is a reason to name the paths, not a reason to call the run clean.
#
# A PARTIAL run is deliberately left passing. Whether three of five present
# should fail or warn is a judgement about how people run this; the count above
# makes it visible either way, and only the zero case is unambiguously wrong.
if [ "$built" = "0" ]; then
	echo "build_all_versions.sh: FAILED (built nothing: every pg_config was skipped)"
	echo "       name the pg_config paths explicitly, e.g."
	echo "       test/build_all_versions.sh /usr/local/pg15a/bin/pg_config ..."
	exit 1
fi
echo "build_all_versions.sh: PASSED"
