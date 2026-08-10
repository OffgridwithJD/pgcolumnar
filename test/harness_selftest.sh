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
#
# LC_ALL=C, and the collation is part of the property rather than a detail (#552).
# "Sorted" is not machine-independent: C compares byte by byte so `_` (0x5F)
# precedes `e`, while en_US.UTF-8 ignores punctuation at the first level and
# compares `sortstatus` against `sortedprojection`. The array holds sort_status
# then sorted_projection, so it is sorted in one and unsorted in the other, and
# this check pinned neither. On a clean main it FAILED under en_US.UTF-8 and
# passed here only because the container defaults to C.UTF-8, which collates
# like C.
#
# The ambiguity is worse than the false red. Sorted order is what gives two
# agents' new suites different insertion points; if two contributors disagree
# about what sorted means they insert in different places, and the property stops
# delivering the merges it exists for.
_sorted_expected="$(listed_suites | LC_ALL=C sort)"
_sorted_actual="$(listed_suites)"
check "the suite list is sorted in C order, so two new suites land in different places" \
	"$([ "$_sorted_actual" = "$_sorted_expected" ] && echo sorted || echo "not sorted")" "sorted"

# The pair that decides it, asserted directly so a future edit that "fixes" the
# order to UTF-8 collation fails here with the reason rather than only failing
# the comparison above.
check "premise: C collation puts sort_status before sorted_projection" \
	"$(printf 'sorted_projection\nsort_status\n' | LC_ALL=C sort | head -1)" "sort_status"

# ---- and comm's two inputs must be sorted the SAME way (#552 follow-up) -----
#
# `comm` requires both inputs sorted in one collation and does not check. Fed
# inconsistently-sorted input it does not error; it returns the wrong lines.
#
# test/rebuild.sh:130 does `comm -23` over two `sort -u` outputs, neither pinned.
# They agree today because they share a locale. The plausible next edit is
# somebody pinning ONE of them because this PR taught them to, and the result is
# a symbol check that silently reports the wrong unresolved symbols -- either a
# false red, or the worse direction, a real unresolved symbol not reported.
#
# Asserted over source text, which is the weaker kind, because reproducing it
# needs two locales and a built .so. Premised on the comm still existing, or the
# grep approves a file that no longer has one.
_cm_files="$(grep -ln 'comm -' "$(dirname "${BASH_SOURCE[0]}")"/*.sh 2>/dev/null)"
check "premise: some suite still uses comm, or the check below is vacuous" \
	"$([ -n "$_cm_files" ] && echo yes || echo no)" "yes"

_cm_unpinned=""
for _f in $_cm_files; do
	# every `| sort` in a file that uses comm must carry LC_ALL=C
	if grep -qE '\|[[:space:]]*sort' "$_f" && grep -E '\|[[:space:]]*sort' "$_f" | grep -qv 'LC_ALL=C'; then
		_cm_unpinned="$_cm_unpinned $(basename "$_f")"
	fi
done
check "a file that uses comm pins the collation of every sort feeding it" \
	"$(printf '%s' "$_cm_unpinned" | sed 's/^ //')" ""

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

# ---- the sanitizer subset must cover the C-level encoding selftest -----------
#
# test/run_san.sh runs a SUBSET of the suites, and a suite that is not in it is
# not sanitized -- silently, since nothing reports the omission.
#
# encode_invariants is the only suite that drives pgcolumnar_debug_encoding_selftest,
# which exercises bitunpack at every width 1..64 across counts 1,2,3,7,8,9,17,64,129
# plus a derived count per width. That matters because it is the only fixture that
# crosses bitunpack's fast/tail boundary in both directions: nFast is 0 until the
# encoded body reaches nine bytes, so small counts are all tail. Measured with a
# probe build, counting backends that reached the tail loop:
#
#     encode_invariants  21
#     differential        0
#
# differential's chunks are large enough that nFast == n throughout, so a
# sanitizer pass that includes differential and not encode_invariants covers one
# of bitunpack's two paths -- over exactly the code #514 rewrote.
#
# Asked as "every suite that drives the selftest" rather than by name, so moving
# the selftest to another suite cannot quietly narrow this.
# Ask the runner rather than parsing the source (CONTEXT.md, #473) -- but with
# PGC_SAN_SUITES cleared, because the claim under test is about the SHIPPED
# DEFAULT, not about whatever an operator overrode it with for one run.
#
# Both halves are load-bearing and each fixes a different defect. Asking the
# runner means this cannot drift from what run_san.sh actually iterates. Clearing
# the variable means a developer with an override exported does not get a red
# from a check that is not about their override -- which is what a plain
# --list-suites here produces, verified: with PGC_SAN_SUITES='smoke differential'
# the runner reports no encode_invariants and this check would fail while the
# shipped default is perfectly correct.
_san_suites="$(env -u PGC_SAN_SUITES bash "$PGC_SRCDIR/test/run_san.sh" --list-suites 2>/dev/null)"
check "premise: run_san.sh's default subset was found and is non-empty" \
	"$([ -n "$_san_suites" ] && echo yes || echo no)" "yes"

_san_missing=""
_san_drivers=0
for _f in "$PGC_SRCDIR"/test/*.sh; do
	# Skip this file. It names the function in the pattern just below, so a
	# blind sweep matches the searcher as well as the searched -- the same
	# self-match that makes `pgrep -f <pattern>` find its own command line.
	[ "$(basename "$_f")" = "$(basename "${BASH_SOURCE[0]}")" ] && continue
	grep -q 'debug_encoding_selftest' "$_f" || continue
	_san_drivers=$((_san_drivers + 1))
	_b="$(basename "$_f" .sh)"
	grep -qw "$_b" <<<"$_san_suites" || _san_missing="$_san_missing $_b"
done
check "premise: at least one suite drives the C-level encoding selftest" \
	"$([ "$_san_drivers" -ge 1 ] && echo yes || echo no)" "yes"

check "the sanitizer subset runs every suite that drives the encoding selftest" \
	"$(printf '%s' "$_san_missing" | sed 's/^ //')" ""

# ---- a cluster that will not start must report WHY (#537) -------------------
#
# The failure path printed eight identical retry lines and a verdict naming none
# of the eight causes, while pg_ctl -l had been writing the reason to server.log
# the whole time. The workdir is removed on exit, so the evidence was gone by the
# time anyone read the verdict.
#
# These are text decisions, so they are tested without standing anything up, for
# the same reason bench_guards exists (#465).

check "premise: the harness exposes its fatal pattern to be judged" \
	"$(type -t pgc_fatal_pattern)" "function"

_m() { grep -cE "$(pgc_fatal_pattern)" <<<"$1"; }

check "the fatal pattern matches a library that will not load" \
	"$(_m 'FATAL:  could not load library "/usr/local/pg19/lib/pgcolumnar.so": undefined symbol: get_relation_info_hook')" \
	"1"
check "and still matches an AddressSanitizer report" \
	"$(_m '==1==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x1')" "1"
check "and still matches a PANIC" \
	"$(_m 'PANIC:  could not write to file')" "1"
check "and still matches a signal death" \
	"$(_m 'server process was terminated by signal 11: Segmentation fault')" "1"
check "but not a routine statement error" \
	"$(_m 'ERROR:  division by zero')" "0"
check "nor an ordinary log line" \
	"$(_m 'LOG:  database system is ready to accept connections')" "0"

# ---- the verdict must not assert a cause it has not established -------------
#
# "(refusing to run against a cluster this suite does not own)" is ONE reason a
# start can fail, and it was not the reason in #537: nothing was squatting, our
# own postmaster died on eight different ports. The loop already knows which case
# it saw; the message collapsed them.
check "premise: the verdict is composed somewhere it can be judged" \
	"$(type -t pgc_start_failure_message)" "function"

check "the ownership claim is made when a squatter held the port every time" \
	"$([ "$(pgc_start_failure_message 8 15208 8 | grep -c 'does not own')" -ge 1 ] && echo yes || echo no)" "yes"
# The mixed case is the one a sticky flag got wrong: one squatter then seven
# genuine start failures used to print the squatter verdict for all eight.
check "a mixed run reports both causes and neither as the whole story" \
	"$([ "$(pgc_start_failure_message 8 15208 1 | grep -c '1 of 8')" -ge 1 ] && \
	   [ "$(pgc_start_failure_message 8 15208 1 | grep -c 'other 7 failed to start')" -ge 1 ] && echo yes || echo no)" \
	"yes"
check "and is NOT made when our own postmaster died, which is the #537 case" \
	"$(pgc_start_failure_message 8 15208 0 | grep -c 'does not own')" "0"
check "the port is named either way" \
	"$(pgc_start_failure_message 8 15208 0 | grep -c '15208')" "1"
check "and so is the attempt count" \
	"$(pgc_start_failure_message 8 15208 0 | grep -c '8 attempts')" "1"
check "and the no-squatter verdict points at the server log" \
	"$([ "$(pgc_start_failure_message 8 15208 0 | grep -ci 'log')" -ge 1 ] && echo yes || echo no)" "yes"

# ---- and the log report must show the cause, not just that there was one ----
check "premise: the log report is a function that can be fed a fixture" \
	"$(type -t pgc_start_log_report)" "function"

_lf="$(mktemp /tmp/pgc-537.XXXXXX)"; chmod 644 "$_lf"
{
	echo 'LOG:  starting PostgreSQL 19beta2'
	echo 'FATAL:  could not load library "/usr/local/pg19/lib/pgcolumnar.so": undefined symbol: get_relation_info_hook'
	echo 'LOG:  database system is shut down'
} > "$_lf"
_rep="$(pgc_start_log_report "$_lf" 2>&1)"
# At least once, not exactly once: the line legitimately appears twice, in the
# first-fatal block and again in the tail, and pinning it to one would fail on
# correct output.
check "the report names the symbol that was actually missing" \
	"$([ "$(grep -c 'undefined symbol: get_relation_info_hook' <<<"$_rep")" -ge 1 ] && echo yes || echo no)" \
	"yes"
check "and a log with no fatal line still reports rather than staying silent" \
	"$([ -n "$(printf 'LOG:  all fine\n' > "$_lf"; pgc_start_log_report "$_lf" 2>&1)" ] && echo yes || echo no)" \
	"yes"
rm -f "$_lf"

# ---- and lib.sh must ASK these functions, not merely contain them -----------
#
# The checks above feed the three functions fixtures and prove their arithmetic.
# None of them proves the failure path calls any of them. Measured, not reasoned:
# with the pgc_start_log_report call deleted from pgc_setup, every check above
# still PASSED, 70 of 70. That is the same gap #538 found in #532's bench guards,
# found again in the fix for #537 by an adversarial review.
#
# These are checks over source text, which is the weaker kind. They are here
# because the failure path needs a cluster that will not start, which this suite
# cannot stand up, and a weak check on the call site beats none.

_LIB="$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check "premise: lib.sh is readable, or every grep below approves nothing" \
	"$([ -r "$_LIB" ] && echo yes || echo no)" "yes"
# Without this the three greps could pass against a file that no longer HAS a
# start-failure path, which is the vacuous form of all of them.
check "premise: the start-failure path still exists to be judged" \
	"$([ "$(grep -c 'no cluster of our own' "$_LIB")" -ge 1 ] && echo yes || echo no)" "yes"

check "the failure path asks pgc_start_log_report for the reason" \
	"$([ "$(grep -c 'pgc_start_log_report "' "$_LIB")" -ge 1 ] && echo yes || echo no)" "yes"
check "and asks pgc_start_failure_message for the verdict" \
	"$([ "$(grep -c 'pgc_start_failure_message "' "$_LIB")" -ge 1 ] && echo yes || echo no)" "yes"
# The verdict text must live in ONE place. An inline echo beside the call is how
# the old hardcoded parenthetical would come back wearing the same words.
# Matched on the START-FAILURE verdict specifically. A looser grep for
# `echo "       (refusing` finds two unrelated lines about the previously
# installed .so (#513) and reports a defect that is not there -- which is the
# same prefix-matching trap this suite already guards for suite names.
check "and the old start-failure verdict is not echoed inline anywhere" \
	"$(grep -c 'refusing to run against a cluster' "$_LIB")" "0"
check "the summary path asks pgc_fatal_pattern rather than hardcoding it" \
	"$([ "$(grep -c 'grep -nE .\$(pgc_fatal_pattern)' "$_LIB")" -ge 1 ] && echo yes || echo no)" "yes"
check "and the start path asks pgc_start_fatal_pattern, its deliberately wider one" \
	"$([ "$(grep -c 'pgc_start_fatal_pattern)' "$_LIB")" -ge 1 ] && echo yes || echo no)" "yes"

# ---- the port walk must WRAP, not walk off the ceiling (#548) ---------------
#
# pgc_pick_free_port seeds a base from the PID and scans forward. It used to
# `break` at hi, so a seed near the ceiling got a truncated scan: the failure
# needs the ports at the top of the band to be BUSY, and then the walk gives up
# with the whole band free beneath it. About 1 replication run in 2000, which
# across five majors is roughly 1 CI run in 400, presenting as an unattributable
# red that moved between majors.
#
# The band must be made busy to test this. A first version of these checks asked
# the picker for a port with the band EMPTY, where the old code also succeeds --
# they passed with the no-wrap walk restored, which is to say they tested
# nothing. The stub is the whole point.

_w=$(( PGC_AUX_PORT_HI - PGC_AUX_PORT_LO ))
check "premise: the auxiliary band has a width to wrap within" \
	"$([ "$_w" -gt 400 ] && echo yes || echo no)" "yes"

_realfree=$(declare -f pgc_port_free)

# Every port in the TOP 400 is busy; everything below is free. A walk that stops
# at hi finds nothing from a base inside that region. A walk that wraps lands in
# the free part below.
pgc_port_free() { [ "$1" -lt $(( PGC_AUX_PORT_HI - 400 )) ]; }
check "premise: the stub really does refuse the top of the band" \
	"$(pgc_port_free $(( PGC_AUX_PORT_HI - 1 )) && echo free || echo busy)" "busy"
check "premise: and really does allow the bottom" \
	"$(pgc_port_free "$PGC_AUX_PORT_LO" && echo free || echo busy)" "free"

_top="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI" $(( _w - 1 )) || echo NONE)"
check "a seed at the ceiling wraps past a busy top and still finds a port" \
	"$([ "$_top" != "NONE" ] && [ -n "$_top" ] && echo yes || echo no)" "yes"
check "and the port it found is below the busy region, which is where wrapping lands" \
	"$([ "$_top" != "NONE" ] && [ "$_top" -lt $(( PGC_AUX_PORT_HI - 400 )) ] && [ "$_top" -ge "$PGC_AUX_PORT_LO" ] && echo yes || echo no)" \
	"yes"

# A band with every port busy must report itself full rather than spin. The
# bound is half the fix; without it the wrap turns a hard failure into a hang,
# which is worse than the failure it replaces.
pgc_port_free() { return 1; }
_none="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI" 5 || echo NONE)"
check "an entirely busy band reports itself full and terminates" "$_none" "NONE"

# The caller says "no free port for the restore cluster in [lo,hi)". That names
# the WHOLE band, so the picker has to have swept the whole band before it may
# say nothing is free. It used to stop after 300 probes, which meant a free port
# 500 away from the base was reported as a full band -- #548's own defect
# surviving inside #548's fix, and #537's defect in the message.
#
# One free port, deliberately further from the base than the old 300 bound.
pgc_port_free() { [ "$1" = "$(( PGC_AUX_PORT_LO + 500 ))" ]; }
check "premise: the stub frees exactly one port, 500 past the floor" \
	"$(pgc_port_free $(( PGC_AUX_PORT_LO + 500 )) && echo free || echo busy)/$(pgc_port_free $(( PGC_AUX_PORT_LO + 200 )) && echo free || echo busy)" \
	"free/busy"
_far="$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI" 0 || echo NONE)"
check "a free port beyond the old 300-probe bound is still found" \
	"$_far" "$(( PGC_AUX_PORT_LO + 500 ))"

eval "$_realfree"
check "premise: the real prober was restored, or every check after this lies" \
	"$(pgc_port_free 1 && echo probing || echo stubbed)" "probing"


# ---- an in-tree build must not reuse another major's objects (#536) ---------
#
# lib.sh builds in $PGC_SRCDIR with no clean and no record of which major the
# objects belong to. The MATRIX is not affected -- run_all_versions.sh cleans
# each per-major copy right after its cp -a, measured after #536 was filed
# claiming otherwise. This guard is for the single-suite path only.
check "premise: the build-stamp decision is exposed to be judged" \
	"$(type -t pgc_build_needs_clean)" "function"

check "building the same major again needs no clean" \
	"$(pgc_build_needs_clean 18 18 yes)" "no"
check "building a DIFFERENT major needs a clean, which is the #536 case" \
	"$(pgc_build_needs_clean 18 19 yes)" "yes"
check "and in the other direction too" \
	"$(pgc_build_needs_clean 19 18 yes)" "yes"
check "an unparseable stamp cleans rather than guessing" \
	"$(pgc_build_needs_clean garbage 18 yes)" "yes"
check "and an empty WANT is refused rather than compared" \
	"$(pgc_build_needs_clean 18 "" yes)" "yes"

# The case the end-to-end proof exposed. A tree built BY HAND leaves objects and
# NO stamp; reading that as "nothing to contaminate" let the first version stay
# silent on exactly the path it exists for.
check "objects with NO stamp are unknown provenance and must be cleaned" \
	"$(pgc_build_needs_clean "" 18 yes)" "yes"
check "but a tree with no objects at all needs nothing, stamp or not" \
	"$(pgc_build_needs_clean "" 18 no)" "no"

_bmsg_unknown="$(pgc_build_stale_message "" 19)"
check "an unknown provenance is not reported as a major" \
	"$(grep -c 'PG?' <<<"$_bmsg_unknown")" "0"
check "and it says plainly that no major was recorded" \
	"$([ "$(grep -ci 'no recorded major' <<<"$_bmsg_unknown")" -ge 1 ] && echo yes || echo no)" "yes"

# The stamp must be the bare major and nothing else, and this exercises LIB.SH'S
# WRITER rather than a copy of it. Two earlier versions of this check were
# useless: one wrote its own temp file with a correct printf and verified that,
# which cannot fail; the other grepped for the bad form with a pattern that
# matched the GOOD form, so it could never pass. Both were caught by the gate.
check "premise: the stamp writer is a function that can be exercised" \
	"$(type -t pgc_write_build_stamp)" "function"

_stmp="$(mktemp)"
pgc_write_build_stamp "$_stmp" 19
check "the stamp lib.sh writes is exactly the major" \
	"$(cat "$_stmp")" "19"
check "and it is 3 bytes, not an escaped literal" \
	"$(wc -c < "$_stmp" | tr -d ' ')" "3"
rm -f "$_stmp"

check "the build path asks pgc_build_needs_clean rather than merely naming it" \
	"$([ "$(grep -c 'pgc_build_needs_clean "' "$TESTDIR/lib.sh")" -ge 1 ] && echo yes || echo no)" "yes"


pgc_summary
