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
#
# Asked ONCE, for the real runner, and cached. The checks below call this inside
# two loops over every test file, so the first version forked a fresh bash 250-odd
# times. Under a six-way matrix that is slow and, worse, fragile: a transient
# failure to fork returns an empty list, and an empty list reads as "that suite is
# unregistered". It did exactly that in the #473 matrix, failing on PG16 and PG17
# with four names each, different names each time, while PG15/18/19 passed. An
# intermittent red naming innocent suites is the worst kind, so the premise below
# makes an empty answer say what it is.
#
# THAT DIAGNOSIS WAS WRONG, or at best incomplete, and the caching did not cure
# the symptom it was written for. The real cause is this file's own `set -o
# pipefail` meeting a reader that exits early:
#
#     listed_suites | grep -qx "$name"
#
# `grep -q` returns the moment it matches, which closes the pipe while printf is
# still writing. printf then takes EPIPE and exits non-zero, and under pipefail
# the PIPELINE reports that failure even though grep matched -- so a registered
# suite is recorded as unregistered. It is a race between grep exiting and printf
# finishing, which is why it never reproduces locally, why it names innocent
# suites, and why it names DIFFERENT ones each run.
#
# Measured directly rather than reasoned about: 4,000 names, matching the first,
# 200 attempts. With pipefail, 18 false negatives. Without it, 0. It surfaced
# again on #476's CI (PG18) with "unregistered: parquet_nested_import" beside a
# "printf: write error: Broken pipe" from line 209, on a run whose own summary
# listed that suite as having passed.
#
# The fix is to stop piping. The membership test below is a case over the cached
# string, which cannot lose a race it no longer runs.
_SUITE_LIST="$(bash "$RUNNER" --list-suites 2>/dev/null)"
check "premise: the runner answered --list-suites, so the two checks below mean something" \
	"$([ -n "$_SUITE_LIST" ] && echo yes || echo "no (empty)")" "yes"

listed_suites() {
	if [ $# -gt 0 ]; then
		bash "$1" --list-suites 2>/dev/null
	else
		printf '%s\n' "$_SUITE_LIST"
	fi
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

# A case over the cached list rather than `listed_suites | grep -qx`. The pipe
# was the defect: grep -q returns on its match, printf takes EPIPE, and pipefail
# turns that into a failed pipeline for a suite that IS registered. See the note
# above line 201. Newlines around both sides make it a whole-line match, which is
# what grep -x provided and what keeps a name from matching inside another.
# Both directions first, because a membership test that always matched would make
# the check below pass for every suite including genuinely unregistered ones --
# which is the same green-by-construction failure the pipe version produced in
# reverse. The replacement has to be shown to answer, not merely to stop failing.
case $'\n'"$_SUITE_LIST"$'\n' in
	*$'\n'isolation$'\n'*) _ctl_present=present ;;
	*) _ctl_present=absent ;;
esac
check "positive control: the membership test finds a name that is registered" \
	"$_ctl_present" "present"

case $'\n'"$_SUITE_LIST"$'\n' in
	*$'\n'no_such_suite_exists$'\n'*) _ctl_absent=present ;;
	*) _ctl_absent=absent ;;
esac
check "negative control: and does not find one that is not" \
	"$_ctl_absent" "absent"

# A partial name must not match a whole entry, which is what grep -x guaranteed
# and what the surrounding newlines preserve.
case $'\n'"$_SUITE_LIST"$'\n' in
	*$'\n'isolatio$'\n'*) _ctl_partial=present ;;
	*) _ctl_partial=absent ;;
esac
check "and a prefix of a registered name is not treated as registered" \
	"$_ctl_partial" "absent"

unregistered=""
for f in "$TESTDIR"/*.sh; do
	name="$(basename "$f" .sh)"
	not_a_suite "$name" && continue
	case $'\n'"$_SUITE_LIST"$'\n' in
		*$'\n'"$name"$'\n'*) ;;
		*) unregistered="$unregistered $name" ;;
	esac
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

# ---- no suite pipes a captured string into an early-exit reader (#486) -------
#
# `echo "$s" | grep -q PATTERN` under `set -o pipefail` answers "not found" when
# the WRITER fails, whatever the string contained. The reader exits as soon as it
# has its answer, the writer takes EPIPE, and pipefail calls the pipeline failed.
# The `&&` arm never runs and the helper reports absence.
#
# This is not theoretical and it is not new here. #473 found it in this file's own
# membership test, and it came back in native_agg.sh, where it reported "the
# metadata aggregate node did not run" on PG18 CI for a plan that contained the
# node -- a red that reads exactly like a planner regression in the area #133 and
# #140 live in. The tell was a `Broken pipe` line beside a result the same run's
# summary contradicted.
#
# The failure direction is what makes it worth a rule: it always reports the
# thing you were looking for as ABSENT, which is the answer that sends someone
# looking for a defect that is not there.
#
# The control below runs first, because a rule with no demonstrated failure is a
# style preference, and this one is not.
_epipe_demo="$PGC_WORKDIR/epipe_demo.sh"
cat > "$_epipe_demo" <<'DEMO'
set -uo pipefail
big="MATCHME
$(head -c 300000 /dev/zero | tr '\0' 'y')"
piped() { echo "$1" | grep -q 'MATCHME' && echo yes || echo no; }
cased() { case "$1" in *MATCHME*) echo yes ;; *) echo no ;; esac; }
echo "piped=$(piped "$big" 2>/dev/null) cased=$(cased "$big")"
DEMO
_epipe_result="$(bash "$_epipe_demo" 2>/dev/null)"

# The string CONTAINS the pattern, on its first line, in both arms. Only the
# answers differ. Written large on purpose: at a few kilobytes the write fits in
# the pipe buffer and completes before the reader can exit, which is why this
# shape passes almost every time and then does not.
check "control: piping a large string into grep -q reports a match as absent" \
	"$_epipe_result" "piped=no cased=yes"

# The rule itself. A pipeline whose left side is a shell builtin writing a
# captured string, and whose right side is a reader that exits early AND whose
# EXIT STATUS is the answer being read. That last part is the whole rule: the
# damage is a wrong verdict, not a wrong message.
#
# So `grep -q` is in scope and `| head -1` inside a diagnostic string is not.
# Those exist here (analyze_stats.sh prints a plan's first line that way) and
# they can lose their pipeline's status without changing any check, because the
# substitution is used as text. They are left alone on purpose rather than
# missed; the worst they do is print to stderr.
#
# Scoped to echo and printf deliberately for the same reason. A pipeline out of
# psql or a file is a different question with a different answer, and a rule that
# flagged those too would be argued with rather than kept.
_epipe_hits="$(grep -rnE '(echo|printf)[^|]*\|[[:space:]]*grep -[a-zA-Z]*q' \
	"$TESTDIR"/*.sh 2>/dev/null | grep -v '/harness_selftest.sh:' || true)"
_epipe_count="$(printf '%s' "$_epipe_hits" | grep -c . || true)"
[ -n "$_epipe_hits" ] || _epipe_count=0
check "no suite pipes a captured string into an early-exit reader" \
	"$_epipe_count" "0"
[ "$_epipe_count" = "0" ] || printf '%s\n' "$_epipe_hits" | sed 's/^/      /' | head -20

# And the scan has to be looking at something. A glob that matched nothing, or a
# TESTDIR that moved, would report zero hits and read as compliance.
_epipe_scanned="$(grep -rlE 'grep' "$TESTDIR"/*.sh 2>/dev/null | grep -c . || true)"
check "and the scan examined the suites rather than finding nothing to read" \
	"$([ "${_epipe_scanned:-0}" -ge 20 ] && echo yes || echo "no (scanned $_epipe_scanned)")" "yes"

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

# ---- the harness must say which binary it is testing (#508 follow-up) -------
#
# Three separate defects this session were a suite reporting checks against a
# binary nobody had just built: a compile failure the harness did not check
# (#508), a PGC_SKIP_BUILD run that skipped the INSTALL and exercised a
# guard-removed leftover, and objects from another major linked into a third.
# Every one produced a plausible PASS/FAIL list, and every one is one line of
# md5sum away from being obvious.
#
# The first check is the line existing; the second is the one with teeth. It
# compares what is INSTALLED against what was just BUILT, using the build tree as
# an independent source rather than recomputing the installed hash the same way
# twice. Equal means the install actually happened.
_so_line="$(pgc_so_line)"
echo "$_so_line"

check "pgc_setup reports the installed .so" \
	"$(grep -cE '^-- \.so: [0-9a-f]{12} ' <<<"$_so_line")" "1"

_so_installed="$(awk '{print $3}' <<<"$_so_line")"
_so_built="$(md5sum "$PGC_SRCDIR/pgcolumnar.so" 2>/dev/null | cut -c1-12)"
check "the installed .so is the one this run built" \
	"$([ -n "$_so_built" ] && [ "$_so_installed" = "$_so_built" ] && echo yes \
		|| echo "no (installed $_so_installed, built ${_so_built:-<none>})")" \
	"yes"

# ---- a failing suite must surface the FIRST fatal event, not just the tail ---
#
# On failure pgc_summary tails 40 lines of the server log. That is the right
# thing to show when one statement failed, and the wrong thing after a crash:
# the first fatal event is at the TOP of the log and everything below it is
# aftermath, so the tail shows recovery messages and not the cause.
#
# Measured, on a deliberate heap overrun run through this harness under the
# pg18_san build: 67 AddressSanitizer reports in an 8,777-line log, the first at
# line 12. The tail showed lines 8738-8777 -- 8,765 lines of crash recovery below
# the answer -- and then pgc_teardown removed the file, so there was nowhere left
# to look. The suite reported 123 failures and not one word about why.
#
# This stands that up without needing a sanitizer build: a fatal-looking line,
# then enough filler to push it past the tail window, then a real failure.
_fatal_marker="AddressSanitizer: heap-buffer-overflow PGCSELFTEST"
_sub="$(mktemp /tmp/pgcolumnar-subsuite.XXXXXX.sh)"
cat > "$_sub" <<SUBEOF
#!/bin/bash
set -uo pipefail
. "$PGC_SRCDIR/test/lib.sh"
pgc_setup "\$1"
# RAISE LOG writes to the server log at a level the default log_min_messages
# keeps, which is how this gets a line into the log without a crash.
psql_run "DO \\\$\\\$ BEGIN RAISE LOG '$_fatal_marker'; END \\\$\\\$;"
psql_run "DO \\\$\\\$ BEGIN FOR i IN 1..60 LOOP RAISE LOG 'selftest filler %', i; END LOOP; END \\\$\\\$;"
check "deliberate failure so the summary runs" "got" "want"
pgc_summary
SUBEOF
chmod +x "$_sub"
# PGC_SKIP_BUILD: this sub-suite is testing the summary, not the build, and the
# .so was already verified above.
_subout="$(PGC_SKIP_BUILD=1 bash "$_sub" "$PGC_PG_CONFIG" 2>&1)"
rm -f "$_sub"

# The premise: the sub-suite must actually have failed, and its filler must
# actually have pushed the marker out of the tail window. Without both, the
# check below passes for the wrong reason.
check "premise: the sub-suite failed, so its summary ran" \
	"$(grep -cE ': FAILED$' <<<"$_subout")" "1"
check "premise: the 40-line tail is filler, not the marker" \
	"$(sed -n '/---- server log tail ----/,$p' <<<"$_subout" | grep -c "$_fatal_marker")" "0"

# Scoped to the new section rather than to the whole output, and asked as
# "is it there" rather than "how many times". PostgreSQL emits a STATEMENT: line
# beside the message, so the marker legitimately appears twice; an exact count
# would be asserting a detail of PostgreSQL's logging and would go red the day
# that changed, without anything being wrong.
check "a failing suite names the first fatal event in its log" \
	"$([ "$(sed -n '/---- first fatal events/,/---- server log tail ----/p' <<<"$_subout" \
		| grep -c "$_fatal_marker")" -ge 1 ] && echo yes || echo no)" \
	"yes"

pgc_summary
