# ---- the objects decide which major built them, not a stamp we wrote (#1219) --
#
# pgc_build_needs_clean compares the build STAMP against the major being built.
# Neither side is a property of the objects actually in the tree, so a HAND-RUN
# `make` for another major leaves foreign objects and never touches the stamp:
# have=18 and want=18 agree, the clean is skipped, make finds everything up to
# date, and one major's objects are installed into another's prefix. Measured by
# @OffgridwithJD while building the cross-major preflight -- a suite died on
# `undefined symbol: build_simple_rel_hook`, which is the PG19 name, during a
# PG18 run.
#
# THE STAMP FAILS CLOSED IN ONE DIRECTION AND OPEN IN THE OTHER. A stale or
# absent stamp forces an unnecessary clean, which is safe. A stamp that MATCHES
# while the objects are foreign is a silent wrong install. Only the second is
# dangerous, and it is the one the stamp cannot see.
#
# The objects can answer for themselves: the build passes -g, so every .o
# carries a DWARF directory table naming the server headers it was compiled
# against. Compare that against `pg_config --includedir-server` -- an exact
# match, with no major number parsed out of a path. The two prefix layouts
# differ (/usr/local/pgNN/include/postgresql/server against
# /usr/include/postgresql/NN/server) and a pattern written for one returns EMPTY
# for the other, which reads exactly like "not derivable".

check "premise: the object-provenance decision is exposed to be judged" \
	"$(type -t pgc_objects_built_for)" "function"

# PREMISE FOR EVERY ARM BELOW. These objects are what the suite just built, so
# they belong to the major under test. With no objects the arms compare nothing
# and "no" is indistinguishable from a correct refusal.
_obj_n="$(find "$PGC_SRCDIR/src" -name '*.o' 2>/dev/null | wc -l)"
check_num "premise: the tree under test holds objects to judge" \
	"$(if [ "$_obj_n" -ge 1 ]; then echo 1; else echo 0; fi)" "1"

# WHAT THIS BUILD CAN ANSWER AT ALL. A server built without -g produces objects
# with no .debug_ sections and there is nothing to compare; /usr/local/pg18_nc
# on this host is such a build, and the arm below would demand "yes" from a
# tree that cannot say. Measure which case this run is in rather than assuming
# every major carries debug info.
_dbg_obj="$(find "$PGC_SRCDIR/src" -name '*.o' 2>/dev/null | head -1)"
_has_dwarf=no
[ -n "$_dbg_obj" ] && [ "$(readelf -S "$_dbg_obj" 2>/dev/null | grep -c 'debug_')" -ge 1 ] &&
	_has_dwarf=yes
echo "-- objects carry debug info: $_has_dwarf ($(basename "${_dbg_obj:-none}"))"

# BOTH NAMES ARE RECORDED ON EVERY RUN, one of them declined. An if/else that
# picks a different check NAME per build kind makes the suite's name set shrink
# with the environment, which is #1185's defect exactly: the accounting
# reconciles and the missing arm is invisible. A build without -g cannot answer
# the first question and cannot fail the second, so each declines where it does
# not apply.
if [ "$_has_dwarf" = yes ]; then
	check "objects built by this very run match the pg_config that built them" \
		"$(pgc_objects_built_for "$PGC_SRCDIR" "$PGC_PG_CONFIG")" "yes"
	check_unrunnable "objects with no debug info report UNKNOWN, so the stamp still decides" \
		"UNMET_PRECONDITION" "this build carries debug info, so provenance is readable"
else
	check_unrunnable "objects built by this very run match the pg_config that built them" \
		"UNMET_PRECONDITION" "this build carries no debug info, so provenance is unreadable"
	check "objects with no debug info report UNKNOWN, so the stamp still decides" \
		"$(pgc_objects_built_for "$PGC_SRCDIR" "$PGC_PG_CONFIG")" "unknown"
fi

# THE LOAD-BEARING ARM, and it needs no second server on the host.
#
# The first version searched /usr/local/pg15|pg16|pg17|pg19 for a different
# major to compare against. NONE OF THOSE EXIST on pgcolumnar-audit, whose
# prefixes carry an `a` suffix, so the arm declined there -- and would have
# declined SILENTLY AND GREENLY but for a malformed reason code
# (@OffgridwithJD). A hardcoded list of host paths, inside a change about not
# trusting hand-maintained records.
#
# The claim is only "an includedir that does not match reports no". A stub
# pg_config that prints a path nothing was built against proves exactly that,
# on every host, with no discovery and no second install.
_stub_dir="$(mktemp -d)"
printf '#!/bin/sh\necho /nonexistent/include/postgresql/server\n' > "$_stub_dir/pg_config"
chmod +x "$_stub_dir/pg_config"

check "premise: the stub answers, so the comparison has a right-hand side" \
	"$("$_stub_dir/pg_config" --includedir-server)" "/nonexistent/include/postgresql/server"

if [ "$_has_dwarf" = yes ]; then
	check "and are reported FOREIGN to an includedir they were not built against" \
		"$(pgc_objects_built_for "$PGC_SRCDIR" "$_stub_dir/pg_config")" "no"
else
	check_unrunnable "and are reported FOREIGN to an includedir they were not built against" \
		"UNMET_PRECONDITION" "this build carries no debug info, so provenance is unreadable"
fi
rm -rf "$_stub_dir"

# Every way of failing to read the objects must land on the safe side: report
# foreign, so the caller cleans. An unnecessary clean costs a rebuild; the other
# direction installs one major's objects into another's prefix.
check "an unreadable pg_config fails CLOSED rather than assuming a match" \
	"$(pgc_objects_built_for "$PGC_SRCDIR" /nonexistent/bin/pg_config)" "no"

_empty_dir="$(mktemp -d)"
mkdir -p "$_empty_dir/src"
check "a tree with no objects reports unknown, not a false match" \
	"$(pgc_objects_built_for "$_empty_dir" "$PGC_PG_CONFIG")" "unknown"
rm -rf "$_empty_dir"

# THE WIRING, NOT ONLY THE TOOL. A removal proof of the function alone would
# pass while the four lines that call it did nothing -- which is how a guard
# ships that is never consulted. Read the caller's own text and require that it
# reaches this decision before it cleans.
# COMMENTS STRIPPED FIRST, because a grep aimed at a mechanism matches every
# comment that DISCUSSES the mechanism. Driven rather than reasoned: replacing
# the call with `# the call to pgc_objects_built_for used to be here` left both
# arms below PASSING on a caller that no longer consults anything. The same trap
# caught @OffgridwithJD twice in one derivation -- `make .*install` matched two
# suites that only mention it in prose, and `pgc_setup` matched three whose
# comments explain they do NOT call it.
_wire="$(sed -n '/^pgc_build_and_install()/,/^}/p' "$PGC_TESTDIR/lib.sh" |
	sed 's/#.*//')"
check_num "pgc_build_and_install consults the objects, not only the stamp" \
	"$(printf '%s\n' "$_wire" | grep -c 'pgc_objects_built_for')" "1"
check_num "and it still consults the stamp, which answers when the objects cannot" \
	"$(printf '%s\n' "$_wire" | grep -c 'pgc_build_needs_clean')" "1"
check_num "premise: the caller's text was actually found, so the counts mean something" \
	"$(if [ "$(printf '%s\n' "$_wire" | wc -l)" -ge 10 ]; then echo 1; else echo 0; fi)" "1"

# THE ARMS ABOVE MUST NOT PASS ON PROSE. Build the text that defeated the first
# version -- the name present, the call gone -- and require the same counting to
# report zero.
_wire_prose="$(printf '%s\n' \
	'pgc_build_and_install() {' \
	'	# the call to pgc_objects_built_for used to be here' \
	'	_pgc_bi_foreign=unknown' \
	'}' | sed 's/#.*//')"
check_num "a caller that only MENTIONS the helper does not count as consulting it" \
	"$(printf '%s\n' "$_wire_prose" | grep -c 'pgc_objects_built_for')" "0"
