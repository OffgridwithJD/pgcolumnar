# ---- an arm's failure must say what it measured (#1164) ---------------------
#
#     check "..." "$([ "$WF" -le $((NF * 2)) ] && echo yes || echo no)" "yes"
#
# Two measured numbers, reduced to `yes`/`no` before the comparison. The failure
# reads `got no want yes`, which is the word FAILED spelled twice. A reader who
# hits that red at 3am learns nothing about WF, NF, or how far apart they were.
#
# WHAT IT COST, measured rather than imagined. A PG 15 leg reddened one arm of
# `sorted_pathkeys`, and two sessions spent an afternoon unable to say whether the
# ORACLE (a six-buffer spurious gap) or the CONTROL (a fourteen-buffer collapse)
# had failed -- different defects with different owners. Four further experiments
# were aimed at a target whose identity was unknown.
#
# AND THE SHELL SIDE IS WHERE THE LESSON LANDS HARDEST, because the shell suite
# for that very property had ALWAYS carried its numbers --
#
#     no (on=$PB_NOORDER_ON off=$PB_NOORDER_OFF over $PB_GROUPS groups)
#
# -- and the pytest PORT dropped them. Two of the four pairs repaired under #1164
# were port regressions of exactly that shape. `compare_to_bash` grades the check
# NAME, so both halves graded `missing: 0` while one printed its measurement and
# the other printed `got 0 want 1`. Name parity does not preserve diagnostics.
#
# WHY THIS IS A LIST AND NOT A ZERO. The pytest corpus reaches zero and its twin
# asserts zero. This corpus holds 77 such arms across 52 suites, and a rule that
# went red on arrival with 77 offenders would be switched off within a week. So
# the debt is TRACKED, in `test/lossy_arms.tsv`, and the gate refuses BOTH
# directions: an unlisted offender fails by name, and a listed arm that has since
# been repaired fails until its row goes. The list may only shrink, and it does so
# by construction rather than by anyone maintaining a number.
#
# The asymmetry between the two halves is deliberate. The corpora are in different
# states, and a guard that asserted zero over both would claim a property this
# tree does not have.
#
# THE RULE. An `$([ TEST ] && echo A || echo B)` handed to a recorder is refused
# -- and so is `$([ TEST ] && echo A)` with no else, which is WORSE: it reports
# `got [] want [ok]`, losing the measurement and the verdict together.
# when both hold:
#
#   (a) the failing set has MORE THAN ONE MEMBER, so the boolean does not say
#       which state was reached; AND
#   (b) NEITHER echo carries a value, so the message cannot recover it.
#
# Determinate, and deliberately out of scope: unary file and string tests
# (`-f`, `-n`, `-z` and the rest), equality (`=`, `!=`, `-eq`, `-ne`), and
# nothing-versus-something (`-gt 0`, `-ge 1`) where exactly one value fails.
#
# THOSE CARVE-OUTS ARE NOT TIDINESS, THEY WERE MEASURED. Three drafts of this
# sweep over-reported, each caught by reading what it SELECTED rather than by
# trusting the count: `-f "$CB"` flagged as lossy (a file test names its own
# failure), `-n "$emsg"` flagged twice after `n` and `z` were dropped from the
# unary set in a rewrite, and equality flagged before it was excluded. The counts
# went 77, then 94, then 55. **A rule that fails toward MORE findings is the
# direction that gets published**, so the carve-outs are driven below rather than
# described.
#
# THE SCOPE IS A SHAPE, NOT A DIRECTORY, and saying only the directory once cost
# 26 arms (#1174). The selector below reads two spellings of a verdict:
#
#   $( [ TEST ] && echo A || echo B )        a test built into the shell
#   $( awk ... print (COND) ? A : B ... )    a verdict computed by awk
#
# The second was invisible until #1174, so `lossy_arms.tsv` read as the debt of
# the shell corpus when it was the debt of one spelling.
#
# THE POPULATION, WITH ITS BUCKETS SUMMING TO IT. Measured over test/*.sh and
# test/selftest/*.sh at f1c3b7a:
#
#     awk-valued recorder arms           136
#       awk as an extractor               57   concludes nothing
#       a branch carries a value          35   correct by the rule
#       both branches constant            44
#         excused by the carve-out        20   nothing-versus-something, equality
#         LOSSY                           24   still unrepaired
#       inputs 136 == sum of buckets 136
#
# THE PARTITION MOVED WITH A REPAIR, AND NOTHING WOULD HAVE NOTICED. It read
# 57/33/46 (20 excused, 26 lossy) until parallel_scan_cost's two "io-kept"
# arms were repaired: each moved from "both constant and lossy" into "a branch
# carries a value", so carries went 33 -> 35, both-constant 46 -> 44 and LOSSY
# 26 -> 24. The TOTAL does not move, because a repaired arm is still an
# awk-valued recorder arm. The tsv count is derived from the rows and follows a
# repair on its own; THESE NUMBERS ARE TYPED PROSE and no check reads them, so
# a repair that leaves them alone leaves the file describing a tree that no
# longer exists. Re-derive them in the commit that repairs an arm.
#
# THE FOURTH BUCKET IS THE ONE THAT MATTERS AND I PUBLISHED THIS WITHOUT IT.
# The first version of this note read "57, 33 and 26", which sums to 116 against
# a stated 136: the 20 the carve-out EXCUSES had been dropped and the 26 was
# labelled "both branches constant" when it means "both constant AND lossy".
# A reader given three buckets cannot tell whether an arm left the population
# because the rule excused it or because the sweep never saw it -- which is the
# distinction this whole file is about. Caught by @OffgridwithJD, against the
# repository rule that a list-derived claim prints `inputs == sum(buckets)`
# beside it. That identity is now printed above, where it can be checked.
#
# STILL OUT OF SCOPE, and named rather than left to be rediscovered:
#
#   A VERDICT COMPUTED INTO A VARIABLE and checked on a later line --
#   `hit="$(awk ... ? 1 : 0)"` then `check "..." "$hit" "1"` -- the same defect
#   with the arm two statements from its name. Naming it needs dataflow this
#   sweep does not do, and guessing from the nearest preceding name charges it to
#   the wrong check: that is measured, not feared, in the matcher below.
#
#   A VERDICT RENDERED BY if/else RATHER THAN A TERNARY --
#   `BEGIN { if (a <= b*2) print "yes"; else print "no" }` -- which is
#   both-constant and throws its operands away, and which the matcher does not
#   read. Zero live sites, swept with continuations folded; the two non-ternary
#   near-misses are printf extractors. Reported by @OffgridwithJD and left open
#   deliberately: the argument that closed `any()` on #1166 was that an author
#   told "your min arm is refused" reaches for it, and nobody rewrites a ternary
#   as if/else to dodge a guard.
#
#   A VERDICT RENDERED BY AN AWK AT THE END OF A PIPE --
#   `$(cmd | awk '{print ($1 <= $2 * 2) ? "yes" : "no"}')` -- which is
#   both-constant, throws its operands away, and which the matcher does not
#   read, because the matcher requires `$(awk` and a pipe puts something else
#   in that position. Reported by @OffgridwithJD; the numbers here are a second
#   sweep, run against a lift of `_lam_sweep` that was validated FIRST by
#   reproducing the shipped list exactly -- 103 found, 103 tracked, both `comm`
#   directions empty -- so what follows is about the matcher and not about a
#   copy of it.
#
#   SEVEN arms render a verdict this way. FIVE are invisible to the sweep, and
#   are outside the 136 above because that population requires `$(awk` too:
#
#       cost_written_geometry.sh            ($1 >= 1)
#       logical_decoding_cdc_recipe.sh      ($1 > 0)
#       native_fetch_interrupt.sh   (x2)    ($1 >= 1)
#       pg_dump_roundtrip.sh                ($1 > 0)
#
#   THE OTHER TWO ARE EXAMINED BY ACCIDENT, and that is the part worth knowing.
#   Both are in `decode_interrupts.sh`, and their FIRST pipe stage is itself a
#   `$(awk ...`, which satisfies the matcher's test; the greedy strip to the
#   last `print` then reads the second stage's condition, correctly. Rewrite
#   that first stage as `grep` and the arm leaves the sweep without its verdict
#   changing at all. Membership, so the two claims can be checked separately:
#   7 piped arms == 2 inside the 136 + 5 outside it.
#
#   ZERO ARE LOSSY TODAY: all seven conditions are `> 0` or `>= 1`, which the
#   carve-out excuses. Proven rather than eyeballed, by putting four arms
#   through the lifted sweep --
#
#       a  piped awk,       excused condition    not flagged   right either way
#       b  substituted awk, same condition       not flagged   carve-out works
#       c  piped awk,       LOSSY condition      NOT FLAGGED   <- the gap
#       d  substituted awk, same LOSSY condition flagged       <- the control
#
#   -- where c and d carry the same condition and the same two constant
#   branches, so the pipe is the whole difference, and d flagging is what says
#   the probe can speak at all. A fifth arm in the `decode_interrupts` shape,
#   with a lossy second stage, IS flagged: that is what "by accident" was
#   measured with rather than asserted.
#
#   RECORDED, NOT CLOSED, for the reason given just above: widening `\$\(awk`
#   to "an awk that is the last stage of the substitution" would cover both
#   spellings and would add zero rows today, and nobody rewrites a substitution
#   as a pipe to dodge a guard.
#
# SCOPED TO test/*.sh AND test/selftest/*.sh, EXCEPT THIS FILE. The first draft
# excluded the whole `selftest/` directory on the grounds that "this file's own
# explanation of the rule, and the control fixture below, both contain the shape
# they exist to describe". That is exactly right for 540 and **it is not a
# property of the directory** -- @OffgridwithJD pointed at
# `410-a-check-must-have-been-red.sh`, an ordinary part carrying a genuinely lossy
# arm by this rule: two computed line numbers compared with `-lt`, both discarded,
# where the comment above it records that the real failure was "definition at line
# 1128, called at 762" -- precisely the two numbers `got [after] want [before]`
# throws away.
#
# Selftest 260's mistake was sweeping the ENFORCER for instances of the rule. The
# enforcer is one file, so one file is what the exclusion covers. 080 records the
# same correction twice, in the other direction: its directory scoping "fell out
# of writing a glob" rather than being decided, and bench/ then held six instances
# it never looked at.

_lam_list="$PGC_TESTDIR/lossy_arms.tsv"

# THE CONTROL RUNS FIRST, because a sweep that matches nothing reports the same
# clean result as a corpus with nothing to find -- the `d41d8cd98f00` shape, where
# an extractor that finds nothing hashes identically on both sides. A planted
# fixture says the matcher can still see the thing it is looking for.
_lam_probe="$PGC_WORKDIR/lam_probe.sh"
cat > "$_lam_probe" <<'PROBE'
check "a threshold whose operands vanish" \
	"$([ "$WF" -le $((NF * 2)) ] && echo yes || echo no)" "yes"
check "a count against a floor" \
	"$([ "${SEEN:-0}" -ge 7 ] && echo yes || echo no)" "yes"
check "determinate: nothing versus something" \
	"$([ "$rows" -gt 0 ] && echo yes || echo no)" "yes"
check "determinate: a file either exists or does not" \
	"$([ -f "$CB" ] && echo yes || echo no)" "yes"
check "determinate: a string is empty or it is not" \
	"$([ -n "$emsg" ] && echo yes || echo no)" "yes"
check "carried: the branch names the number" \
	"$([ "$n" -ge 5 ] && echo yes || echo "no (found $n)")" "yes"
PROBE

_lam_sweep() {  # _lam_sweep FILE -> one "suite<TAB>name" per lossy arm
	awk '
		function determinate(t) {
			# ANCHORED to the start of the test. Searching anywhere matched
			# `grep -c .` inside a command substitution as a unary file test --
			# `c` is in the class -- and silently excused five real offenders.
			if (t ~ /^[[:space:]]*!?[[:space:]]*-[fdersxwLhpSbcgkuGnz][[:space:]]/) return 1
			if (t ~ /(^|[[:space:]])(-eq|-ne|!=|==|=)([[:space:]]|$)/) return 1
			if (t ~ /-(gt|ge)[[:space:]]+"?[01]"?[[:space:]]*$/) return 1
			return 0
		}
		# The same carve-outs the `[` rule uses, written in awk syntax.
		#
		# EXACTLY ONE COMPARISON. `(s>0 && p>0)` ends in `p>0` and would read as
		# nothing-versus-something, while hiding WHICH of two costs went
		# non-positive -- the arm #1172 repaired by hand. A condition carrying
		# more than one comparison is a compound and stays in scope.
		function awk_determinate(c,   n, i) {
			sub(/[[:space:]]*\)*[[:space:]]*$/, "", c)
			n = gsub(/<=|>=|==|!=|<|>/, "&", c)
			if (n != 1) return 0
			if (c ~ /(==|!=)/) return 1
			if (c ~ />[[:space:]]*0$/) return 1
			if (c ~ />=[[:space:]]*1$/) return 1
			return 0
		}
		# CONTINUATIONS ARE FOLDED FIRST. The corpus wraps these arms across
		# lines, and a line-by-line reader sees `&& echo "smaller"` without the
		# `|| echo "UNCHANGED ($ROWS_AFTER of $ROWS_BEFORE)"` that follows it --
		# so four arms that DO carry their values read as though they discard
		# them. Measured: 65 sites before folding, 61 after.
		{
			line = $0
			while (line ~ /\\$/ && (getline nxt) > 0) {
				sub(/\\$/, " ", line)
				line = line nxt
			}
		}
		# The recorder call carries the NAME in its first quoted argument.
		line ~ /(^|[[:space:]])(check|check_num|check_text|check_ratio|pgc_fail|check_skip)[[:space:]]+"/ {
			nm = line
			sub(/^[^"]*"/, "", nm); sub(/".*$/, "", nm)
			name = nm
		}
		# AN AWK-RENDERED VERDICT, same rule and a different spelling (#1174).
		#
		# THE BRANCHES DECIDE, NOT THE PROGRAM. The `[` arm below excuses any arm
		# whose branches contain `$`, because a branch that interpolates carries
		# its value. That test cannot be reused here: an awk program written in
		# DOUBLE quotes interpolates in its CONDITION -- `print ($LO * 8 <= $HI)
		# ? 1 : 0` -- and still throws both operands away. So the two branches are
		# matched as literals, and anything concatenated onto one fails the match
		# and is treated as carrying.
		#
		# A BARE NUMBER IS A CONSTANT TOO. `? 1 : 0` renders `got 0 want 1`, which
		# is the exact symptom #1164 is named for, and a first pass over this
		# corpus keyed on quoted branches alone and reported zero of them.
		# THE RECORDER MUST BE ON THIS LINE. `name` holds the LAST name seen, so
		# a rule that fires on any line would charge an arm to whatever check
		# preceded it. Measured: without this, `test/lib.sh:1347` -- an `if` in a
		# helper -- was reported as `lib: $name`, and three `bloom_hit="$(awk
		# ... ? 1 : 0)"` ASSIGNMENTS in native_join_runtime_filter were charged to
		# unrelated checks. 4 of 32 findings were manufactured that way.
		#
		# A BOOLEAN ASSIGNED TO A VARIABLE AND CHECKED LATER IS THE SAME DEFECT
		# and is deliberately OUT OF SCOPE here: the arm is two statements apart
		# from its name, so naming it needs dataflow this sweep does not do.
		# Recorded rather than mis-attributed.
		line ~ /(^|[[:space:]])(check|check_num|check_text|check_ratio|pgc_fail|check_skip)[[:space:]]+"/ &&
		line ~ /\$\(awk/ {
			t = line
			gsub(/\\"/, "\"", t)   # an awk program in double quotes escapes its own
			if (match(t, /\?[[:space:]]*("[^"]*"|[0-9]+(\.[0-9]+)?)[[:space:]]*:[[:space:]]*("[^"]*"|[0-9]+(\.[0-9]+)?)[[:space:]]*[})]/)) {
				cond = substr(t, 1, RSTART - 1)
				sub(/^.*print[[:space:]]*/, "", cond)
				if (!awk_determinate(cond) && name != "") print suite "\t" name
			}
		}
		line ~ /\$\([[:space:]]*\[[^]]*\][[:space:]]*&&[[:space:]]*echo/ {
			body = line
			sub(/^.*\$\([[:space:]]*\[/, "", body)
			test = body; sub(/\].*$/, "", test)
			arms = body; sub(/^[^]]*\][[:space:]]*/, "", arms)
			# (b) a branch that interpolates carries the value already.
			if (arms ~ /\$/) next
			if (determinate(test)) next
			if (name != "") print suite "\t" name
		}
	' suite="$(basename "${1%.sh}")" "$1"
}

# AND THE SAME RULE OVER AN AWK-RENDERED VERDICT (#1174). A separate fixture, so
# the two controls above keep their numbers and this family is counted on its own.
#
# THE INTERPOLATION RULE CANNOT BE REUSED WHOLESALE. The `[` matcher excuses an
# arm whose branches contain `$`, because a branch that interpolates carries its
# value. An awk program written in DOUBLE quotes carries `$LO` in its CONDITION
# and constants in its branches -- `print ($LO * 8 <= $HI) ? 1 : 0` -- so a test
# for `$` anywhere excuses the whole family. The branches are what must be read.
_lam_probe_awk="$PGC_WORKDIR/lam_probe_awk.sh"
cat > "$_lam_probe_awk" <<'PROBE'
check "an awk verdict whose operands vanish" \
	"$(awk -v a="$WF" -v b="$NF" 'BEGIN{ print (a <= b * 2) ? "yes" : "no" }')" "yes"
check "an awk verdict rendered as a number" \
	"$(awk "BEGIN{print ($LO * 8 <= $HI) ? 1 : 0}")" "1"
check "determinate: an awk count against nothing" \
	"$(awk -v n="$SEEN" 'BEGIN{ print (n > 0) ? "some" : "none" }')" "some"
check "carried: the awk branch names the number" \
	"$(awk -v n="$n" 'BEGIN{ print (n >= 5) ? "yes" : "no (found " n ")" }')" "yes"
PROBE

_lam_probe_hits="$(_lam_sweep "$_lam_probe" | wc -l | tr -d ' ')"
check "control: the sweep sees a threshold arm and a floor arm" \
	"$_lam_probe_hits" "2"

# THE CARVE-OUTS, DRIVEN. Without these the rule refuses most of the corpus, and
# a rule that refuses everything is argued with rather than kept.
_lam_probe_names="$(_lam_sweep "$_lam_probe" | cut -f2 | sort | tr '\n' ';')"
check_text "control: a determinate or carrying arm is not swept up" \
	"$_lam_probe_names" "a count against a floor;a threshold whose operands vanish;"

_lam_awk_hits="$(_lam_sweep "$_lam_probe_awk" | wc -l | tr -d ' ')"
check "control: the sweep sees an awk verdict that discards its operands" \
	"$_lam_awk_hits" "2"

_lam_awk_names="$(_lam_sweep "$_lam_probe_awk" | cut -f2 | sort | tr '\n' ';')"
check_text "control: a determinate or carrying awk arm is not swept up" \
	"$_lam_awk_names" "an awk verdict rendered as a number;an awk verdict whose operands vanish;"

# The corpus, against the tracked debt. Both directions, in one pass.
_lam_found="$PGC_WORKDIR/lam_found.tsv"
: > "$_lam_found"
for _lam_f in "$PGC_TESTDIR"/*.sh "$PGC_TESTDIR"/selftest/*.sh; do
	# This file only: it describes the shape and plants one in its probe.
	case "$_lam_f" in *540-an-arm-must-carry-its-measurement.sh) continue ;; esac
	_lam_sweep "$_lam_f" >> "$_lam_found"
done
sort -u -o "$_lam_found" "$_lam_found"

_lam_tracked="$PGC_WORKDIR/lam_tracked.tsv"
grep -v '^#' "$_lam_list" | grep -v '^[[:space:]]*$' | sort -u > "$_lam_tracked"

# A SWEEP THAT READ NOTHING REPORTS THE SAME CLEAN RESULT AS A CLEAN CORPUS, so
# assert it read the corpus before either comparison is believed.
check "premise: the sweep read the corpus and classified arms in it" \
	"$([ "$(wc -l < "$_lam_found")" -ge 20 ] && echo yes || echo "no ($(wc -l < "$_lam_found"))")" \
	"yes"

_lam_new="$(comm -23 "$_lam_found" "$_lam_tracked" | sed 's/\t/: /' | tr '\n' ';')"
check_text "a new arm that cannot say what it measured is refused by name" \
	"${_lam_new:-none}" "none"

_lam_stale="$(comm -13 "$_lam_found" "$_lam_tracked" | sed 's/\t/: /' | tr '\n' ';')"
check_text "a repaired arm must have its row removed, so the list only shrinks" \
	"${_lam_stale:-none}" "none"
