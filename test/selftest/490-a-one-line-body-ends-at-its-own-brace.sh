# ---- a one-line function definition ends at its own brace ------------------
#
# #1042. `skip-loop-arms.py` decides which functions record a check by reading
# each one's body, and it took that body as everything up to the next brace at
# COLUMN ZERO. A definition that closes on its own line has none:
#
#	test/audit.sh:122   q() { run_pg "$PSQL -c \"$1\""; }
#
# so `q`'s body ran on into the NEXT function's and swallowed every `check` call
# between them. `q` -- a psql wrapper that records nothing -- then classified as a
# RECORDER, and its first argument, SQL text, entered a set of valid check names.
# The corpus has 199 one-line definitions, so this is the common form.
#
# THE DEFECT CHANGED NO VERDICT ON THE TREE AS IT STOOD, and that is why it needs
# an arm rather than only a fix. A/B on `db74d9e9c` between the two extractors:
# `loops 8 / compared 6 / interpolated 1 / armless 1` from both, byte-identical.
# So the two are indistinguishable from the tool's own output, and a regression
# would be invisible to every existing check. The fixture below is the only thing
# that separates them.
#
# WHY THE TOOL GREW `--emitters`. Without it the only observable is the mismatch
# total, which this defect does not move. A guard that can only read the total
# cannot see the classification, so the tool prints it and this part reads it --
# the real function over a fixture, rather than a reimplementation of it here.

_ol_py="$TESTDIR/../.github/scripts/skip-loop-arms.py"

check "premise: the skip-loop tool is present" \
	"$([ -r "$_ol_py" ] && echo yes || echo no)" "yes"

_ol_dir="$(mktemp -d)"

# A one-line wrapper that records NOTHING, above a function that DOES. The
# swallowed body is the only reason the two could be confused.
cat > "$_ol_dir/offender.sh" <<'PGC_OL_BAD'
q() { psql -c "$1"; }

arm() {
	check "the property" "$got" "$want"
}
PGC_OL_BAD

# The same file WITHOUT the wrapper, so "arm is a recorder" is not credited to the
# fixture being shaped oddly.
cat > "$_ol_dir/control.sh" <<'PGC_OL_GOOD'
arm() {
	check "the property" "$got" "$want"
}
PGC_OL_GOOD

# AND THE OTHER DIRECTION, which the two fixtures above cannot reach. A "fix"
# that ended EVERY body at the first `}` on any line would also drop `q` and pass
# both of them -- and would truncate a real recorder whose body contains a nested
# block, dropping it from the emitter set. Only a MULTI-LINE function with an
# inner `{ ... }`, which must still be classified as a recorder, says whether the
# depth counting is right or off by one. Raised by @jdatcmd, whose point is that
# the form is copied from `unrunnable-arm-names.py` and a copy is exactly where
# this goes wrong.
cat > "$_ol_dir/nested.sh" <<'PGC_OL_NEST'
deep() {
	local n
	for n in 1 2 3; do
		if [ "$n" = 2 ]; then
			printf '%s\n' "{ not a block }"
		fi
	done
	check "the property after a nested block" "$got" "$want"
}
PGC_OL_NEST

_ol_bad="$(python3 "$_ol_py" --emitters "$_ol_dir/offender.sh" 2>&1)"
_ol_ctl="$(python3 "$_ol_py" --emitters "$_ol_dir/control.sh" 2>&1)"
_ol_nest="$(python3 "$_ol_py" --emitters "$_ol_dir/nested.sh" 2>&1)"

echo "-- emitters(offender): $_ol_bad"
echo "-- emitters(control):  $_ol_ctl"
echo "-- emitters(nested):   $_ol_nest"

# THE POPULATION IS THE PREMISE. A tool that printed nothing at all would satisfy
# "q is absent" outright, which is the arm below.
check "premise: the tool answers with an emitter set, so 'q is absent' is about q" \
	"$(printf '%s\n' "$_ol_bad" | tr ' ' '\n' | grep -c '^arm$')" "1"

check "a one-line wrapper that records nothing is NOT counted as a recorder (#1042)" \
	"$(printf '%s\n' "$_ol_bad" | tr ' ' '\n' | grep -c '^q$')" "0"

check "control: and the recorder below it is still found, so the fixture discriminates" \
	"$(printf '%s\n' "$_ol_ctl" | tr ' ' '\n' | grep -c '^arm$')" "1"

check "control: a recorder whose body contains a nested block is still a recorder" \
	"$(printf '%s\n' "$_ol_nest" | tr ' ' '\n' | grep -c '^deep$')" "1"

# ---- and the walk SAYS when a body never closes ----------------------------
#
# Counting braces is defeated by an unbalanced one inside a QUOTED STRING, which
# is not parseable without a shell lexer and is not worth one: 912 of 913
# definitions in this corpus close cleanly. What IS worth it is the silence.
# A body that runs to end-of-file swallows every function after it, and the walk
# already knows that and used to discard it.
#
# ASSERTED ON A FIXTURE, NOT ON THE TREE'S COUNT. The tree has exactly one such
# definition today (`400-...:_us_unbound`, misclassified by the shipped tool as
# well as by this one -- a pre-existing defect this change does not remove), and
# pinning "1" here would mean editing this arm when someone fixes it, which is
# neither a defect nor a paydown.
cat > "$_ol_dir/unbalanced.sh" <<'PGC_OL_UNB'
swallower() {
	grep -oE '\$\{?[A-Za-z_]' "$1" | tr -d '${'
}

after() {
	check "a property after the swallower" "$got" "$want"
}
PGC_OL_UNB

# WHAT IS PINNED HERE IS THE REPORTING, NOT THE DEFECT. The first version of this
# arm asserted that `after` is ABSENT from the emitter set, on the reasoning that
# `swallower` had eaten it. That is the wrong mechanism and the suite said so:
# every definition line is scanned independently, so swallowing does not REMOVE
# the swallowed function, it ADDS a false one. The failure is a false POSITIVE.
#
# And pinning the false positive itself would turn a known gap into the expected
# state -- the same argument the parity arm's docstring makes about incomplete
# ports. So what is asserted is that the tool SAYS the body never closed, which is
# what this change adds and what a reader needs in order to distrust the entry.
# WHAT THESE FIXTURES DO NOT COVER, stated because "I do not think it is
# reachable" was wrong when I said it about this. Measured over the 907
# definitions the tool scans, heredocs blanked:
#
#     with a nested block                     27
#     with an unbalanced quoted brace          1
#     with BOTH                                1   <- and it is the same one
#
# So the corpus's only pathological definition, `_us_unbound`, is the COMBINED
# case, and `deep()` and `swallower()` each model one half of it. That is
# adequate for the OUTCOME -- an unbalanced `{` means the depth never returns to
# zero whatever the nesting does, so the body runs to EOF either way, which is
# what the tool reports.
#
# THE WHOLE POPULATION IS TWO, ONE IN EACH DIRECTION, and that bound is worth
# more than either instance. Walk each definition's depth twice -- once as the
# tool does, once with quoted segments removed -- and flag where the two walks
# end on different lines. No guess about where a body ought to end; they disagree
# only when a brace inside quotes is doing the work. Over all 907 definitions:
#
#     400-a-check-result-must-be-machine.sh:338  _us_unbound   OVER-RUN
#         tool body 229 lines | quote-aware 21   -- in emitters(): YES, and
#         reported by the unclosed line this change adds
#     220-an-opt-in-upgrade-guard-must.sh:42     _upg_refuses  EARLY CLOSE
#         tool body 2 lines | quote-aware 4      -- in emitters(): no, and
#         reported by NOTHING
#
# One live and visible, one harmless and invisible, and no third case anywhere.
# The discriminator is @jdatcmd's; the bound is what neither of our earlier probes
# could state, because mine over-reported every one-line definition and theirs was
# blind to a body that runs to EOF -- each was blind to exactly the case the other
# found.
#
# A body that closes EARLY truncates rather than swallows, and
# `unclosed_definitions` cannot report it because the body DID close. Early, but
# closed. The visibility this change adds covers over-running only.
#
#     test/selftest/220-an-opt-in-upgrade-guard-must.sh:42  _upg_refuses()
#         ( eval "$(sed -n '/^not_a_suite()/,/^}/p' "$TESTDIR/run_coverage.sh")"
#     walked 2 lines, true body 4; the `/^}/p` inside the sed script closes it.
#
# It needs no unbalanced `{`: the definition line already supplies the +1, so a
# lone stray `}` in a quoted string is enough (@jdatcmd, who found it after I had
# enumerated the compound case and concluded the shape was unreachable).
#
# HARMLESS TODAY, checked rather than assumed: the two truncated lines contain no
# recorder, so `_upg_refuses` is correctly absent from `emitters()` either way.
# Not fixtured here -- reporting a body whose last line is not a closing brace is
# a separate change, and pinning the current behaviour would make the truncation
# the expected state.
_ol_rep="$(python3 "$_ol_py" "$_ol_dir" 2>&1)"
echo "-- the tool on the fixture dir:"
printf '%s\n' "$_ol_rep" | sed 's/^/     /'

check "premise: the tool reports an unclosed count at all, so a zero below means zero" \
	"$(printf '%s\n' "$_ol_rep" | grep -c '^unclosed [0-9]')" "1"
check "a body that never closes is NAMED rather than silently swallowing the file" \
	"$(printf '%s\n' "$_ol_rep" | grep -c '^UNCLOSED unbalanced.sh:swallower$')" "1"
check "control: and a file whose bodies all close is not named" \
	"$(printf '%s\n' "$_ol_rep" | grep -c '^UNCLOSED control.sh')" "0"

rm -rf "$_ol_dir"
unset _ol_py _ol_dir _ol_bad _ol_ctl _ol_nest _ol_rep
