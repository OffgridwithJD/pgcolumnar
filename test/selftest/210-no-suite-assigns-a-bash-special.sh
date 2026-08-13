# ---- no suite assigns to a bash special variable (#616, retracted) ----------
#
# Bash pre-defines variables with magic semantics, and the worst of them ignore
# assignment SILENTLY: `GROUPS="$(...)"` leaves the caller's group array in
# place, so the variable reads the runner's primary gid (0, for root) forever,
# while every debug probe that merely READS a fresh substitution shows the
# right value. That asymmetry cost two hours on 2026-08-13 and produced a
# wrongly filed defect report against pgcolumnar.stats() (#616): the failure
# survives cat -A, stream separation, and rewrites, because the bug is the
# NAME, not the bytes. UID, EUID, PPID, BASHPID and friends fail the same way;
# RANDOM, SECONDS and LINENO accept assignment but do something magic rather
# than what a suite author means.
#
# The control below runs first: a rule whose instrument has never fired is a
# style preference. A fixture that assigns to GROUPS must be caught, or the
# sweep is a grep that can only ever say yes.

# Two classes. Assignments to the first are silently IGNORED (or readonly),
# so writing one is always a bug. RANDOM and SECONDS are excluded from the
# assignment rule on purpose: assigning them is the documented way to seed the
# RNG (fuzz.sh does, deliberately, for reproducible runs) and reset the timer,
# so there the assignment does exactly what its author means. Using ANY special
# as a for/read target is broken either way and stays forbidden for all.
_ignored='GROUPS|UID|EUID|PPID|BASHPID|FUNCNAME|PIPESTATUS|DIRSTACK|SHELLOPTS|BASHOPTS|LINENO'
_specials="${_ignored}|RANDOM|SECONDS"
_special_pat="(^|[^A-Za-z0-9_#])(${_ignored})=|(^|[[:space:]])(for|read)[[:space:]]+(${_specials})([[:space:];]|$)"

# comments stripped first, so prose ABOUT the trap (this file included) cannot
# trip the sweep that enforces it
_special_hits() {	# _special_hits FILE...
	sed 's/[[:space:]]*#.*$//' "$@" | grep -cE "$_special_pat"
}

_demo="$PGC_WORKDIR/special_demo.sh"
cat > "$_demo" <<'DEMO'
GROUPS="$(echo 6)"
for UID in 1 2; do :; done
read SECONDS
DEMO
check "control: the sweep catches an assignment to a bash special" \
	"$([ "$(_special_hits "$_demo")" -ge 3 ] && echo caught || echo missed)" "caught"
_demo_clean="$PGC_WORKDIR/special_clean.sh"
cat > "$_demo_clean" <<'DEMO'
NGROUPS="$(echo 6)"   # reads RANDOM legally: p=$((RANDOM % 5))
p=$((RANDOM % 5))
RANDOM=42
SECONDS=0
DEMO
check "control: reads, longer names, and the deliberate RANDOM/SECONDS seeds are not flagged" \
	"$(_special_hits "$_demo_clean")" "0"

# The sweep: every suite, the harness itself, and these selftest parts. This
# part excludes ITSELF by name: the control fixtures above must spell the
# forbidden assignments somewhere, and the file defining the instrument is
# where they live.
_offenders=""
for _f in "$PGC_TESTDIR"/*.sh "$PGC_TESTDIR"/selftest/*.sh; do
	[ "${_f##*/}" = "210-no-suite-assigns-a-bash-special.sh" ] && continue
	if [ "$(_special_hits "$_f")" -gt 0 ]; then
		_offenders="$_offenders ${_f##*/}"
	fi
done
check "no suite assigns to a bash special variable" \
	"[${_offenders# }]" "[]"
