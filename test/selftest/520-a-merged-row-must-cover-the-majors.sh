# ---- a merged row that covers fewer majors than the ledger must say so ------
#
# #1071. `pgc_ledger.py merge` writes a row whose `majors` covers only the majors it
# was handed, and nothing warns. A contributor adds checks, runs the suite on ONE
# major, merges that log, and the row lands with `majors = 18`. The gate considers a
# row only where its majors intersect the run's, so:
#
#     suites (PG 18)   matches the row, `new this run=0`, GREEN
#     suites (PG 17)   cannot match it, reads it as a check never seen, RED
#
# and the red names the contributor's own checks with `(on major 17)`, which reads as
# though their suite is broken on 17 when it passes there.
#
# FIVE AUTHORS IN A ROW, including the person who wrote the tool, on a PR that was
# itself about ledger hygiene: #1039, #1063, #1065, #1068, #1070, each writing 6-10
# rows at `18` against a ledger where every other row carried `15;16;17;18;19`. When
# everyone makes the same mistake it is the tool's shape rather than five lapses.
#
# THE TOOL ALREADY KNEW. The distribution it prints for its summary line is computed
# from the same rows, so `merge` could see the new row was a strict subset of what the
# rest of the ledger carries and said nothing.
#
# WHY THE DEFENCES DID NOT FIRE. The recipe the gate prints said `<log>`, singular, so
# following it exactly produces the broken row. A local `harness_selftest.sh` cannot
# catch it, because the gate runs from `run_all_versions.sh`. Every author verified
# locally and was green.
#
# THE PREDICATE IS STRICT SUBSET, not inequality: a row naming a major the ledger has
# never carried is how a new major legitimately enters. And it is REPORTING, not a
# refusal -- seeding one major at a time is how a contributor without five installed
# majors makes progress, so refusing would block the honest case to catch the careless
# one.
#
# This part drives the real tool over files it builds here. It asserts the
# DISCRIMINATION rather than the wording: the same checks merged correctly must not
# warn, or a tool that warned unconditionally would pass and the warning would stop
# being read.
# ---------------------------------------------------------------------------

_led520="$PGC_TESTDIR/pgc_ledger.py"
_d520="$(mktemp -d)"

check "premise: the ledger tool this part drives is present" \
	"$([ -f "$_led520" ] && echo yes || echo no)" "yes"

_mk520_ledger() {	# _mk520_ledger PATH -- two rows carrying all five majors
	printf 'demo\tpart1\told one\t15;16;17;18;19\tnever\t-\n' >"$1"
	printf 'demo\tpart1\told two\t15;16;17;18;19\tnever\t-\n' >>"$1"
}

_mk520_log() {	# _mk520_log PATH MAJOR NAME...
	local p="$1" maj="$2"; shift 2
	: >"$p"
	local n=0
	for _c in "$@"; do
		printf 'RESULT\tdemo\tpart1\t%s\tPASS\t%s\t\n' "$_c" "$maj" >>"$p"
		n=$((n + 1))
	done
	printf 'checks run: %s\n' "$n" >>"$p"
}

# THE RC COMES BACK THROUGH A FILE, not through a variable set inside the function.
# The first version of this helper set `_rc520=$?` and was called as `$(_merge520 ...)`
# -- a command substitution is a SUBSHELL, so the assignment died with it and the next
# read aborted the part under `set -u`. Loud rather than silent, which is the only
# reason it was not a green run asserting nothing.
_merge520() {	# _merge520 OUTFILE LEDGER LOG... -- output to OUTFILE, rc is the caller's $?
	local out="$1" ledger="$2"; shift 2
	python3 "$_led520" merge --ledger "$ledger" --date 2026-09-13 "$@" >"$out" 2>&1
}

# ---- the defect: one major merged into a five-major ledger ------------------

_mk520_ledger "$_d520/bad.tsv"
_mk520_log "$_d520/b18.log" 18 "new one" "new two"
_merge520 "$_d520/bad.out" "$_d520/bad.tsv" "$_d520/b18.log"; _badrc520=$?
_bad520="$(cat "$_d520/bad.out")"

check "premise: the single-major merge really did write the minority set" \
	"$(awk -F'\t' '$3=="new one"{print $4}' "$_d520/bad.tsv")" "18"

check "a row covering fewer majors than the ledger is warned about" \
	"$(printf '%s\n' "$_bad520" | grep -c 'WARNING')" "1"

# THE MAJORS ARE READ OUT OF THE TEXT. A grep for `15` is also satisfied by the
# prevailing set printed on the same line, so a loose search would pass for a warning
# that named no missing major at all.
check "and it names exactly the majors the gate will redden on" \
	"$(printf '%s\n' "$_bad520" | sed -n 's/.*reddens on \([0-9;]*\).*/\1/p')" "15;16;17;19"

check "and names the set that was merged, so both sides are visible" \
	"$(printf '%s\n' "$_bad520" | grep -c 'majors=18')" "1"

# THE OFFENDING CHECKS ARE NAMED, not counted. A count tells the reader something is
# wrong; the names tell them which rows to re-merge.
# A CHARACTER CLASS, not `\t`. `grep -E` does not interpret `\t` as a tab -- it
# matches a literal `t` -- so the first version of this arm counted 0 and read as
# "the tool names nothing" when the tool was naming both rows correctly.
check "and names the checks whose rows are short" \
	"$(printf '%s\n' "$_bad520" | grep -cE '^[[:space:]]+demo[[:space:]]+part1[[:space:]]+new (one|two)$')" "2"

# REPORTING, NOT A REFUSAL, and the row is still written. A warning that also failed
# the merge would block seeding a major at a time, which is legitimate.
check "the warning does not fail the merge" "$_badrc520" "0"

check "and the row is written anyway, so the warning is advice not a veto" \
	"$(awk -F'\t' '$3=="new two"{print $4}' "$_d520/bad.tsv")" "18"

# ---- the control: the same checks, merged correctly -------------------------
#
# Five LOGS, not one log naming five majors: the same name twice in one log is a
# duplicate sharing a row, which is a different thing and would make this unfaithful.

_mk520_ledger "$_d520/good.tsv"
for _m520 in 15 16 17 18 19; do
	_mk520_log "$_d520/g$_m520.log" "$_m520" "new one" "new two"
	_merge520 "$_d520/g$_m520.out" "$_d520/good.tsv" "$_d520/g$_m520.log"
done
_mk520_log "$_d520/gnoop.log" 15 "new one"
_merge520 "$_d520/gnoop.out" "$_d520/good.tsv" "$_d520/gnoop.log"
_good520="$(cat "$_d520/gnoop.out")"

check "premise: the five-log merge wrote the full major set" \
	"$(awk -F'\t' '$3=="new one"{print $4}' "$_d520/good.tsv")" "15;16;17;18;19"

check "and a correct merge does not warn at all" \
	"$(printf '%s\n' "$_good520" | grep -c 'WARNING' || true)" "0"

# ---- the cases that must NOT warn ------------------------------------------

# An empty ledger has nothing to be a subset OF. A warning here would fire on every
# first merge, and one that fires when nothing is wrong is not read by the third time.
: >"$_d520/empty.tsv"
_mk520_log "$_d520/s18.log" 18 "new one"
_merge520 "$_d520/seed.out" "$_d520/empty.tsv" "$_d520/s18.log"; _seedrc520=$?
_seed520="$(cat "$_d520/seed.out")"
check "seeding a ledger with no prevailing set is not warned" \
	"$(printf '%s\n' "$_seed520" | grep -c 'WARNING' || true)" "0"
check "and seeding still succeeds" "$_seedrc520" "0"

# STRICT SUBSET, not inequality. A run on a major the ledger has never carried is how
# a new major legitimately enters, and warning about it would make this wrong in
# exactly the case the project wants to encourage.
_mk520_ledger "$_d520/newmaj.tsv"
_mk520_log "$_d520/n20.log" 20 "new one"
_merge520 "$_d520/new.out" "$_d520/newmaj.tsv" "$_d520/n20.log"
_new520="$(cat "$_d520/new.out")"
check "a row naming a major the ledger has never seen is not a subset" \
	"$(printf '%s\n' "$_new520" | grep -c 'WARNING' || true)" "0"

# ONLY ROWS THIS MERGE TOUCHED. Every untouched row in a partly-seeded ledger is a
# subset of the prevailing set, so a sweep over the whole file would reprint the
# ledger's history on every merge and bury the one row that matters.
_mk520_ledger "$_d520/hist.tsv"
printf 'demo\tpart1\thistoric\t18\tnever\t-\n' >>"$_d520/hist.tsv"
_mk520_log "$_d520/t15.log" 15 "old one"
_merge520 "$_d520/hist.out" "$_d520/hist.tsv" "$_d520/t15.log"
_hist520="$(cat "$_d520/hist.out")"
check "a pre-existing minority row is not re-reported on an unrelated merge" \
	"$(printf '%s\n' "$_hist520" | grep -c 'WARNING' || true)" "0"

# ---- the recipe that produced the defect -----------------------------------
#
# The gate printed `merge --ledger ... --date <today> <log>`, singular. Following it
# exactly writes a row covering one major, which is how at least five PRs got here.
check "the gate's printed recipe names one log per gated major" \
	"$(grep -c 'log-pg15> <log-pg16> <log-pg17> <log-pg18> <log-pg19>' "$_led520")" "1"

check "and the old singular recipe is gone from the tool" \
	"$(grep -v '^[[:space:]]*#' "$_led520" | grep -c -- '--date <today> <log>"' || true)" "0"

rm -rf "$_d520"
