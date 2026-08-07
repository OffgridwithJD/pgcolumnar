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

# ---- stand up a squatter on a port we will then hand to the suite -----------
SQ_DIR="$(mktemp -d /tmp/pgc-squatter.XXXXXX)"
# A port nothing is already listening on. Drawing blindly would let a collision
# turn into a silent SKIP, and since the self-test runs first in the matrix, a
# quiet skip means the guard stops being tested that run without anyone noticing.
_port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
SQ_PORT=0
for _try in $(seq 1 20); do
	# Inside the band portlib.sh carves below the ephemeral floor. The squatter
	# must hold its port for the whole test, which it cannot do reliably from
	# inside the range the kernel also allocates outbound connections from.
	_cand=$(( PGC_PORT_LO + RANDOM % (PGC_PORT_HI - PGC_PORT_LO) ))
	if _port_free "$_cand"; then
		SQ_PORT=$_cand
		break
	fi
done
if [ "$SQ_PORT" = 0 ]; then
	echo "SKIP  could not find a free port for the squatter cluster"
	rm -rf "$SQ_DIR"
	exit 0
fi
_runpg=(env)
if [ "$(id -u)" = "0" ]; then
	_runpg=(runuser -u postgres --)
	chown -R postgres "$SQ_DIR"
fi
chmod 711 "$SQ_DIR"

"${_runpg[@]}" env PATH="$_bindir:$PATH" \
	initdb -D "$SQ_DIR/data" -A trust >/dev/null 2>&1
echo "port=$SQ_PORT" >> "$SQ_DIR/data/postgresql.conf"
echo "listen_addresses='127.0.0.1'" >> "$SQ_DIR/data/postgresql.conf"
"${_runpg[@]}" env PATH="$_bindir:$PATH" \
	pg_ctl -D "$SQ_DIR/data" -l "$SQ_DIR/log" -w start >/dev/null 2>&1

squatter_down() {
	"${_runpg[@]}" env PATH="$_bindir:$PATH" \
		pg_ctl -D "$SQ_DIR/data" -m immediate -w stop >/dev/null 2>&1 || true
	rm -rf "$SQ_DIR"
}
# Arm cleanup immediately: pgc_setup can exit 1 on its own (that is the behaviour
# under test), and until it installs its trap this is the only thing that would
# stop the squatter.
trap squatter_down EXIT

sq_datadir() {
	env PATH="$_bindir:$PATH" psql -h 127.0.0.1 -p "$SQ_PORT" -U postgres \
		-d postgres -At -c 'SHOW data_directory' 2>/dev/null
}

if [ -z "$(sq_datadir)" ]; then
	echo "SKIP  could not stand up a squatter cluster to test against"
	squatter_down
	exit 0
fi
echo "-- squatter listening on $SQ_PORT ($(sq_datadir))"

# ---- point a real suite setup at exactly that port --------------------------
export PGC_PORT="$SQ_PORT"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "$PGC_SELFTEST_PG_CONFIG"

# pgc_setup replaced our trap with its own (pgc_teardown); chain both back on.
trap 'pgc_teardown; squatter_down' EXIT

# ---- assertions -------------------------------------------------------------
check "suite did not settle on the squatter's port" \
	"$([ "$PGC_PORT" = "$SQ_PORT" ] && echo same || echo moved)" "moved"

check "suite's cluster is its own" \
	"$(pgc_norm_path "$(pgc_cluster_datadir)")" "$(pgc_norm_path "$PGC_PGDATA")"

check "squatter survived untouched" "$(pgc_norm_path "$(sq_datadir)")" \
	"$(pgc_norm_path "$SQ_DIR/data")"

# The point of the guard: objects this suite creates are visible to this suite.
psql_run "CREATE TABLE selftest_marker (id int);"
psql_run "INSERT INTO selftest_marker VALUES (42);"
check "suite's own objects are visible to it" \
	"$(q 'SELECT id FROM selftest_marker;')" "42"

# and are absent from the squatter, i.e. nothing leaked across
check "nothing leaked into the squatter" \
	"$(env PATH="$_bindir:$PATH" psql -h 127.0.0.1 -p "$SQ_PORT" -U postgres \
		-d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname = '$PGC_DB';" 2>/dev/null)" \
	"0"

# pgc_port_free must agree with reality on both a used and an unused port
check "pgc_port_free says the squatter's port is busy" \
	"$(pgc_port_free "$SQ_PORT" && echo free || echo busy)" "busy"

# ---- the detection primitive itself -----------------------------------------
# The assertions above are invariants: they hold even with the identity check
# removed, because a squatter holding the port makes bind genuinely fail and the
# retry happens anyway. They do not, on their own, prove the guard works. The
# case the guard exists for is pg_ctl -w reporting success while another
# postmaster owns the port, and that timing cannot be synthesised reliably here.
#
# So pin the mechanism directly instead: pointed at a foreign cluster,
# pgc_cluster_datadir must report *that* cluster, which is exactly what makes the
# comparison in pgc_setup reject it. If this reports our own directory, or
# nothing, the guard would wave a foreign cluster through.
_saved_port="$PGC_PORT"
PGC_PORT="$SQ_PORT"
_foreign="$(pgc_cluster_datadir)"
PGC_PORT="$_saved_port"

check "detection reports a foreign cluster's directory" \
	"$(pgc_norm_path "$_foreign")" "$(pgc_norm_path "$SQ_DIR/data")"
check "detection distinguishes it from ours" \
	"$([ "$(pgc_norm_path "$_foreign")" = "$(pgc_norm_path "$PGC_PGDATA")" ] \
		&& echo same || echo different)" "different"

# Drive the guard predicate itself, not just its inputs: it must accept our own
# cluster and reject the foreign one. This is the decision the start loop makes.
check "guard accepts our own cluster" \
	"$(pgc_cluster_is_ours && echo ours || echo foreign)" "ours"
_saved_port="$PGC_PORT"
PGC_PORT="$SQ_PORT"
_verdict="$(pgc_cluster_is_ours && echo ours || echo foreign)"
PGC_PORT="$_saved_port"
check "guard rejects a foreign cluster" "$_verdict" "foreign"

# ---------------------------------------------------------------------------
# Every suite must be registered in the matrix.
#
# A suite that run_all_versions.sh does not list is never run by any gate. It
# passes review, it sits in the tree, and the first change to the code under it
# breaks it silently. This has happened repeatedly: four consecutive PRs added a
# suite without registering it, and two older suites (native_reclaim_reconcile
# among them) had never been run by a gate at all.
#
# The allowlist is deliberately short and each entry needs a reason, because the
# easy way to satisfy this check is to add a name to it.
# ---------------------------------------------------------------------------

TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$TESTDIR/run_all_versions.sh"

# Not suites: the two shared libraries (lib.sh, and portlib.sh which lib.sh and
# the standalone suites source for their port), the two runners, and the two developer helpers
# that build rather than test. build_all_versions compiles against every major
# and is run before merging a change that touches a version guard; it takes no
# cluster and reports per major, so the matrix cannot run it as a suite. native_scale is a suite but is opt-in by
# design and says so in its own header: it runs at a row count the matrix should
# not carry. pg_upgrade takes two pg_configs (an old major and a new one)
# rather than one, so the matrix cannot invoke it the way it invokes a suite; it
# is a second gate run explicitly, like run_san.
# build_san builds the ASAN+UBSAN PostgreSQL and run_san is the
# sanitizer gate (#224): they are a separate instrumented build and its runner,
# not a suite the ordinary five-major matrix can carry.
not_a_suite() {
	case "$1" in
		lib|portlib|run_all_versions|build_all_versions|devloop|rebuild|native_scale|build_san|run_san|run_coverage|pg_upgrade|extension_upgrade) return 0 ;;
		*) return 1 ;;
	esac
}

# the SUITES=( ... ) array, flattened to one name per line
# Ask the runner, rather than parsing its source. stderr is dropped because a
# runner carrying the stray-name mistake reports "command not found" on the way
# past it, which is the diagnosis and not this function's output.
listed_suites() {
	local _r="${1:-$RUNNER}"
	bash "$_r" --list-suites 2>/dev/null
}

# ---- the list must be read the way the RUNNER reads it ----------------------
#
# The two checks below rest on listed_suites, so what listed_suites believes is
# load-bearing. It used to believe its own parser: an awk range plus sed plus
# grep, which is a reimplementation of bash's array parsing, and the two disagree
# on exactly the mistake this project keeps making.
#
# Appending a name AFTER the closing paren is valid shell. `bash -n` passes. To
# bash the name is a stray COMMAND and not a member, so the suite never runs. To
# the awk parser it was a member, so "every suite is registered" passed and the
# suite silently did not run. The tally cannot catch it either, because
# "suites that ran: N of M" takes M from ${#SUITES[@]} and is self-consistent
# with the suite missing.
#
# Measured before this was fixed: bash reported "stray_suite: command not found"
# while listed_suites reported it as registered.
#
# So the fixture below is the real runner with that exact mistake applied, and
# the assertion is that the extraction agrees with bash rather than with awk.
_fx="$(mktemp /tmp/pgc-runner-fixture.XXXXXX.sh)"
awk '
	/^SUITES=\(/ { inarr = 1 }
	inarr && /\)/ && !seen { print $0 " stray_not_a_suite"; seen = 1; inarr = 0; next }
	{ print }
' "$RUNNER" > "$_fx"

check_num "premise: the fixture really does carry the stray name" \
	"$(grep -c 'stray_not_a_suite' "$_fx")" "1"
check_num "a name after the array's closing paren is not read as a registered suite" \
	"$(listed_suites "$_fx" | grep -cx stray_not_a_suite)" "0"

# And the mistake is worse than a stray command, which is worth pinning because
# the first version of this test assumed otherwise and asserted the opposite.
#
#     SUITES=(alpha beta gamma) stray_name
#     -> stray_name: command not found
#     -> ${#SUITES[@]} is 0
#
# `NAME=value cmd` scopes the assignment to that one command, and an array
# literal is no exception. So the name after the paren does not join the array,
# it DESTROYS it: every suite disappears and the matrix would run none of them.
# The runner's "NO SUITES RAN" guard is the backstop for that, and this is what
# stops the registration check above from calling the wreck healthy.
check_num "and the mistake empties the whole array rather than appending to it" \
	"$(listed_suites "$_fx" | grep -c .)" "0"

# The control has to be a runner that is NOT sabotaged, because for the fixture
# above an empty answer is the correct one. Reading the real runner is what shows
# the extraction can return names at all.
check_num "positive control: the real runner's list is read, and contains isolation" \
	"$(listed_suites | grep -cx isolation)" "1"
check "positive control: and it is a whole list, not one lucky line" \
	"$([ "$(listed_suites | grep -c .)" -gt 50 ] && echo yes || echo no)" "yes"
rm -f "$_fx"

# ---- the list stays sorted, which is what actually stops the conflicts ------
#
# One name per line was not enough on its own. Measured, on this repository, by
# branching twice and merging:
#
#   one line,     both additions on the same line          CONFLICT
#   one per line, both appended at the end                 CONFLICT
#   one per line + sorted, names far apart                 clean
#   one per line + sorted, names that sort adjacently      CONFLICT
#
# Everyone appends at the end, which is the shape all four of #469's conflicts
# had, so one-per-line alone would have left them all conflicting. Sorted gives a
# new suite an insertion point decided by its NAME, so two unrelated additions
# land in different places and merge. It is a large reduction and not a cure:
# two names that sort next to each other still collide.
#
# This check is what keeps the property true. Without it the order decays the
# first time somebody appends by hand, and the reduction quietly goes away.
_sorted_expected="$(listed_suites | sort)"
_sorted_actual="$(listed_suites)"
check "the suite list is sorted, so two new suites land in different places" \
	"$([ "$_sorted_actual" = "$_sorted_expected" ] && echo sorted || echo "not sorted")" "sorted"

unregistered=""
for f in "$TESTDIR"/*.sh; do
	name="$(basename "$f" .sh)"
	not_a_suite "$name" && continue
	listed_suites | grep -qx "$name" || unregistered="$unregistered $name"
done
check "every suite is registered in run_all_versions.sh" \
	"$([ -z "$unregistered" ] && echo none || echo "unregistered:$unregistered")" "none"

# The reverse: a name in SUITES with no file is a rename or a typo, and the
# runner would report it as a failure only when it tried to run it.
missing_file=""
while read -r name; do
	[ -f "$TESTDIR/$name.sh" ] || missing_file="$missing_file $name"
done < <(listed_suites)
check "every registered suite has a file" \
	"$([ -z "$missing_file" ] && echo none || echo "missing:$missing_file")" "none"

# ---- no suite hands every run the same default port ------------------------

# #184 derived the port per run in lib.sh and in the matrix runner, which is
# where the collisions that cost three gates came from. It did not reach the
# suites that carry their own harness, and they were still starting on fixed
# 54321 through 54327 -- so two standalone runs of the same suite still collided
# by construction.
#
# This asserts the property rather than the absence of one literal, because a
# check naming 54329 passed while seven other files still collided. That is how
# the gap survived the first fix.
_fixed_ports="$(grep -lE 'PGC_(BASE_)?PORT:-[0-9]+' "$TESTDIR"/*.sh 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"

check "no suite hands every run the same default port" \
	"${_fixed_ports:-none}" "none"

# --- no port picker may draw from inside the ephemeral range --------------
#
# The sweep that moved every picker below the kernel's ephemeral floor was a
# one-time edit, and one-time edits come back. This asserts the property instead
# of trusting it: any *PORT assignment in test/ whose literals reach into the
# ephemeral range is a regression of the intermittent bind collision that cost
# this project several days.
#
# An earlier version of the devloop comment claimed exactly this check existed
# when it did not, which is the reason it exists now.
_eph="$(pgc_ephemeral_floor)"
_offenders=""
for _f in "$(dirname "${BASH_SOURCE[0]}")"/*.sh; do
	# Any *PORT assignment, not only the arithmetic form: a plain
	# FOO_PORT=45000 would otherwise slip a check whose comment claims to cover
	# every assignment. Comment lines are excluded so prose about the old ranges
	# does not read as an offender.
	while IFS= read -r _line; do
		# Every integer literal in the expression; flag any at or above the floor.
		for _n in $(printf '%s\n' "$_line" | grep -oE '[0-9]{4,}'); do
			if [ "$_n" -ge "$_eph" ]; then
				_offenders="$_offenders $(basename "$_f"):$_n"
			fi
		done
	done <<-EOF
		$(grep -hE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_]*PORT=' "$_f" 2>/dev/null | grep -vE '^[[:space:]]*#')
	EOF
done
check "no test picks a port from inside the ephemeral range" \
	"$([ -z "$_offenders" ] && echo none || echo "$_offenders")" "none"

# ---- the assertions that refuse an empty measurement (#418) -----------------
#
# check "" "" prints PASS. Every way a measurement goes missing produces exactly
# that, so check_num and check_ratio exist to refuse it. Those two are now
# load-bearing, and a guard nobody tests is a guard that quietly stops working.
#
# Each probe runs in a subshell, because a deliberate failure must not fail this
# suite: PGC_FAIL and PGC_CHECKS are the harness's own state. The probe reports
# PGC_FAIL, so 1 means the assertion rejected what it was given.
_probe() {	# _probe <fn> <args...> -> 0 when the assertion passed, 1 when it failed
	( PGC_FAIL=0; PGC_CHECKS=0; "$@" >/dev/null 2>&1; echo "$PGC_FAIL" )
}

check "check compares two empty strings and passes, which is why the rest exist" \
	"$(_probe check "empty vs empty" "" "")" "0"
check "check_num refuses two empty strings" \
	"$(_probe check_num "empty vs empty" "" "")" "1"
check "check_num refuses a psql error message" \
	"$(_probe check_num "error text" "ERROR:  relation does not exist" "42")" "1"
check "check_num refuses the word a yes/no check would produce" \
	"$(_probe check_num "yes" "yes" "yes")" "1"
check "check_num still compares two real numbers" \
	"$(_probe check_num "equal" "42" "42")" "0"
check "check_num still fails two unequal numbers" \
	"$(_probe check_num "unequal" "41" "42")" "1"
check "check_num accepts a decimal and a sign" \
	"$(_probe check_num "decimal" "-1.5" "-1.5")" "0"

check "check_text refuses two empty strings, where plain check passes" \
	"$(_probe check_text "empty vs empty" "" "")" "1"
check "check_text refuses one empty side" \
	"$(_probe check_text "one empty" "abc" "")" "1"
check "check_text compares two md5 hashes, which check_num cannot" \
	"$(_probe check_text "md5" "9dd4e461268c8034f5c8564e155c67a6" "9dd4e461268c8034f5c8564e155c67a6")" "0"
check "check_text still fails two different strings" \
	"$(_probe check_text "differ" "abc" "def")" "1"
check "check_num refuses an md5, which is why check_text exists" \
	"$(_probe check_num "md5" "9dd4e461268c8034f5c8564e155c67a6" "9dd4e461268c8034f5c8564e155c67a6")" "1"

check "check_ratio refuses an empty measurement" \
	"$(_probe check_ratio "empty" "" "100" "0.5")" "1"
check "check_ratio refuses a zero denominator rather than dividing by it" \
	"$(_probe check_ratio "zero denom" "10" "0" "0.5")" "1"
# The numerator matters as much, and for a while this helper only checked the
# denominator while its comment claimed both. A measurement of zero is inside
# every bound, so it passed.
check "check_ratio refuses a zero numerator, which is inside every bound" \
	"$(_probe check_ratio "zero numerator" "0" "100" "0.5")" "1"
check "check_ratio passes a ratio inside its bound" \
	"$(_probe check_ratio "inside" "10" "100" "0.5")" "0"
check "check_ratio fails a ratio outside its bound" \
	"$(_probe check_ratio "outside" "90" "100" "0.5")" "1"

check "pgc_require_tools passes on tools that exist" \
	"$(_probe pgc_require_tools awk sed)" "0"
check "pgc_require_tools fails on one that does not" \
	"$(_probe pgc_require_tools pgc_no_such_tool_exists)" "1"

pgc_summary
