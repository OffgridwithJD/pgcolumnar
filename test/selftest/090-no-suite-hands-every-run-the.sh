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
for _f in "$PGC_TESTDIR"/*.sh; do
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

