# ---- a declined capability is not a silent one ------------------------------
#
# capability_sweep.sh classifies each pyarrow suite by what it lost when pyarrow
# was masked. #1215 made 25 of them decline with a SKIP, and the owner's rule of
# 2026-10-12 is that a missing capability may be skipped but no test may be
# silent. So the verdict has four outcomes and the sweep must keep the last two
# apart. The sweep runs nightly and needs every pyarrow suite twice; the verdict
# is a pure function, so its cases are asserted here, from the sweep's own text.

_dcs_src="$PGC_TESTDIR/capability_sweep.sh"
_dcs_fn="$(sed -n '/^pgc_capability_verdict() {/,/^}/p' "$_dcs_src")"

check_num "premise: the sweep defines its verdict where this part reads it" \
	"$(printf '%s\n' "$_dcs_fn" | grep -c '^pgc_capability_verdict() {')" "1"

eval "$_dcs_fn"

check_text "the verdict: no name lost is preserved" \
	"$(pgc_capability_verdict 0 0 0)" "preserved"
check_text "the verdict: names lost beside a failure are refused" \
	"$(pgc_capability_verdict 3 1 0)" "refused"
check_text "the verdict: names lost beside a skip naming the capability are declined" \
	"$(pgc_capability_verdict 3 0 1)" "declined"
check_text "the verdict: names lost with neither a failure nor a skip are silent" \
	"$(pgc_capability_verdict 3 0 0)" "silent"

unset -f pgc_capability_verdict
