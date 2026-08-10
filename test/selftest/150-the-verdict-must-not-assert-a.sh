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

