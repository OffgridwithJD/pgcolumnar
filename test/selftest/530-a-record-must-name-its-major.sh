# ---- a record that names no major is a row nothing can seed (#1121) ---------
#
# `pgc_record` writes `${PGC_MAJOR:-unknown}`, and PGC_MAJOR is set inside
# `pgc_setup`. A suite that records but never calls `pgc_setup` writes every check
# against the literal string `unknown`.
#
# THE GATE MATCHES A ROW ONLY WHERE ITS MAJORS INTERSECT THE RUN'S, and no run ever
# observes `unknown`. So such a check cannot be seeded, and a row for it could never
# be matched again. Measured on PG17 before the fix:
#
#     smoke 9/9   audit 31/31   objstore_stash_recovery 17/17   phase2 42/42
#     phase3 32/32   phase4 38/38   phase5 36/36   phase6 43/43
#     ---- 248 of 248 records named no major ----
#
# #1109 had already fixed three more the same way (concurrency, unique_conc,
# update_conc); these eight were simply not in that sweep.
#
# A STATIC RULE CANNOT DO THIS JOB AND I TRIED TWICE.
#
#   * "sources lib.sh and defines no check() of its own" finds 5 and misses
#     `audit`, whose own `check()` body calls `pgc_record`. Defining a local check
#     says nothing about whether it records.
#   * "the file contains the string pgc_record" finds 7 and misses
#     `objstore_stash_recovery`, which uses lib.sh's `check()` directly, so the
#     string never appears in the file.
#
# The truth was 8 both times. Whether a suite records is a RUNTIME property, so the
# guard reads the records. That is the #545 rule again: define a population by what
# it DOES, not by what it is named or what it looks like.
#
# The reader is evalled out of the runner rather than restated here, per selftest
# 320: a check that recomputes a rule tests the world instead of the code.
# ---------------------------------------------------------------------------

_rv530="$PGC_TESTDIR/run_all_versions.sh"

check "premise: the runner defines the reader this part evals" \
	"$(grep -c '^pgc_unknown_major_records()' "$_rv530")" "1"

eval "$(sed -n '/^pgc_unknown_major_records()/,/^}/p' "$_rv530")"

check "premise: it is callable" \
	"$(type -t pgc_unknown_major_records)" "function"

_d530="$(mktemp -d)"

# A record's major is field 6. The fixtures are written as the producer writes them,
# tab separated, so a change to that layout breaks this part rather than passing it.
printf 'RESULT\tdemo\tpart1\tone\tPASS\t17\t\n'      >"$_d530/good.log"
printf 'RESULT\tdemo\tpart1\ttwo\tPASS\t17\t\n'     >>"$_d530/good.log"
printf 'checks run: 2\n'                            >>"$_d530/good.log"

printf 'RESULT\tdemo\tpart1\tone\tPASS\tunknown\t\n'  >"$_d530/bad.log"
printf 'RESULT\tdemo\tpart1\ttwo\tPASS\tunknown\t\n' >>"$_d530/bad.log"
printf 'RESULT\tdemo\tpart1\tthree\tPASS\t17\t\n'    >>"$_d530/bad.log"
printf 'checks run: 3\n'                             >>"$_d530/bad.log"

printf 'checks run: 0\n'                             >"$_d530/norecords.log"

# ASSERTED AS A PAIR. "0 unknown" is also what an absent reader, an unreadable file
# and a wrong field number all produce, so the clean case is never asserted alone.
check "a log whose records all name a major counts none, while a mixed one counts its own" \
	"$(pgc_unknown_major_records "$_d530/good.log")/$(pgc_unknown_major_records "$_d530/bad.log")" \
	"0/2"

# THE MIXED LOG IS THE POINT. A suite can record some checks before `pgc_setup` and
# some after, and a reader that stopped at the first record would report 1 or 0.
check "and it counts every offending record, not just the first" \
	"$(pgc_unknown_major_records "$_d530/bad.log")" "2"

check "a log with no records at all is not an offender" \
	"$(pgc_unknown_major_records "$_d530/norecords.log")" "0"

# A MISSING FILE MUST NOT READ AS CLEAN. The runner skips empty logs before calling
# this, but a reader that answers 0 for a file it could not open is one that reports
# success having asked nothing.
check "premise: an unreadable log is indistinguishable from a clean one, so the caller must guard it" \
	"$(pgc_unknown_major_records "$_d530/does-not-exist.log")" "0"

# FIELD 6, NOT "anywhere in the line". A reason field containing the word would
# otherwise be counted, and reasons are free text.
printf 'RESULT\tdemo\tpart1\tfour\tPASS\t17\tthe major was unknown at first\n' >"$_d530/reason.log"
check "the word in a REASON is not a record that names no major" \
	"$(pgc_unknown_major_records "$_d530/reason.log")" "0"

# ---- the wiring, not only the reader ---------------------------------------
#
# Proving the reader correct says nothing about whether the runner calls it or acts
# on the answer.
_w530() { grep -vE '^[[:space:]]*#' "$_rv530"; }

check "the runner calls the reader over every suite's log" \
	"$(_w530 | grep -c 'pgc_unknown_major_records "\$builddir/\${s}.log"')" "1"

# BOUNDED TO THE GUARD'S OWN BLOCK. The first version of this arm scanned from the
# `_unk_total` test to the next `verfail=1` ANYWHERE below it, and the runner has many
# later ones -- so deleting the guard's own `verfail=1` left the arm green, finding a
# different block's. Mutation testing caught it: removing the line reddened nothing.
# The window now stops at the block's closing `fi`, so only that block can satisfy it.
check "and a suite that names no major fails the major, rather than only printing" \
	"$(_w530 | awk '/_unk_total" != 0/{f=1} f{print} f && /^\tfi$/{exit}' \
		| grep -c 'verfail=1')" "1"

# NAMED, NOT COUNTED. The count says something is wrong; the names say which suite
# needs the one line.
check "and the message names the offending suites" \
	"$(_w530 | grep -c '\${_unk_suites}')" "1"

rm -rf "$_d530"
