# ---- the harness must say which binary it is testing (#508 follow-up) -------
#
# Three separate defects this session were a suite reporting checks against a
# binary nobody had just built: a compile failure the harness did not check
# (#508), a PGC_SKIP_BUILD run that skipped the INSTALL and exercised a
# guard-removed leftover, and objects from another major linked into a third.
# Every one produced a plausible PASS/FAIL list, and every one is one line of
# md5sum away from being obvious.
#
# The first check is the line existing; the second is the one with teeth. It
# compares what is INSTALLED against what was just BUILT, using the build tree as
# an independent source rather than recomputing the installed hash the same way
# twice. Equal means the install actually happened.
_so_line="$(pgc_so_line)"
echo "$_so_line"

check "pgc_setup reports the installed .so" \
	"$(grep -cE '^-- \.so: [0-9a-f]{12} ' <<<"$_so_line")" "1"

_so_installed="$(awk '{print $3}' <<<"$_so_line")"
_so_built="$(md5sum "$PGC_SRCDIR/pgcolumnar.so" 2>/dev/null | cut -c1-12)"
check "the installed .so is the one this run built" \
	"$([ -n "$_so_built" ] && [ "$_so_installed" = "$_so_built" ] && echo yes \
		|| echo "no (installed $_so_installed, built ${_so_built:-<none>})")" \
	"yes"

