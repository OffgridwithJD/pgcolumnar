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


