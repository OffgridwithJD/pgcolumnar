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

