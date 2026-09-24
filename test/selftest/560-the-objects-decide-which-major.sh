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

_obj_n="$(find "$PGC_SRCDIR/src" -name '*.o' 2>/dev/null | wc -l)"
check_num "premise: the tree under test holds objects to judge" \
	"$(if [ "$_obj_n" -ge 1 ]; then echo 1; else echo 0; fi)" "1"

# BUILD BOTH OBJECT KINDS RATHER THAN HOPING THE HOST HAS THEM, so every arm
# below runs on every host and nothing declines.
#
# The first version branched on whether THIS build carried debug info and
# declined the arm that did not apply. That is #1185's rule applied correctly,
# and it produced a worse bug: check_unrunnable makes a run EXIT_INCOMPLETE by
# design, so an arm that is STRUCTURALLY inapplicable on most hosts makes the
# whole suite INCOMPLETE nearly everywhere. Measured by @OffgridwithJD and
# reproduced here once the tree had a .git to clear the unrelated noise:
#
#     main     rc=0   1094 passed + 0 unrunnable   PASSED
#     branch   rc=67  1105 passed + 1 unrunnable   INCOMPLETE
#
# A declined arm is right when applicability is a property of the RUN. It is
# wrong when applicability is a property of the HOST and the thing under test
# is a pure function of a file -- then build the file. Same move as replacing
# the host search with a stub, one layer down.
_probe_dir="$(mktemp -d)"
mkdir -p "$_probe_dir/nodbg/src" "$_probe_dir/withdbg/src"
printf 'int pgc_probe_symbol(void) { return 0; }\n' > "$_probe_dir/t.c"
cc -c    -o "$_probe_dir/nodbg/src/t.o"   "$_probe_dir/t.c" 2>/dev/null || true
cc -g -c -o "$_probe_dir/withdbg/src/t.o" "$_probe_dir/t.c" 2>/dev/null || true

_nodbg_n="$(readelf -S "$_probe_dir/nodbg/src/t.o" 2>/dev/null | grep -c 'debug_' || true)"
_withdbg_n="$(readelf -S "$_probe_dir/withdbg/src/t.o" 2>/dev/null | grep -c 'debug_' || true)"
case "$_nodbg_n" in '' | *[!0-9]*) _nodbg_n=0 ;; esac
case "$_withdbg_n" in '' | *[!0-9]*) _withdbg_n=0 ;; esac
echo "-- probe objects: nodbg debug sections=$_nodbg_n  withdbg=$_withdbg_n"

check_num "premise: an object compiled without -g carries no debug sections" \
	"$_nodbg_n" "0"
check_num "premise: and the same source with -g carries some, so cc obeyed both" \
	"$(if [ "$_withdbg_n" -ge 1 ]; then echo 1; else echo 0; fi)" "1"

# THE TREE'S OWN OBJECTS ARE NEVER CALLED FOREIGN TO THE pg_config THAT BUILT
# THEM. Asserted as "not no" rather than "yes" on purpose: a -g-less server
# yields `unknown` here and both answers are correct. What must never happen is
# this function calling its own build's objects foreign, which is the reading
# that would make every suite clean and rebuild forever.
check "the objects of this very run are never called foreign to their own pg_config" \
	"$(if [ "$(pgc_objects_built_for "$PGC_SRCDIR" "$PGC_PG_CONFIG")" = no ]; \
		then echo no; else echo not-no; fi)" "not-no"

check "an object with no debug info reports UNKNOWN, so the stamp still decides" \
	"$(pgc_objects_built_for "$_probe_dir/nodbg" "$PGC_PG_CONFIG")" "unknown"

# THE LOAD-BEARING ARM, and it needs neither a second server nor a particular
# host build kind.
#
# The first version searched /usr/local/pg15|pg16|pg17|pg19 for a different
# major. NONE of those exist on CI or on pgcolumnar-audit, so the arm declined
# there -- and would have declined SILENTLY AND GREENLY but for a malformed
# reason code (@OffgridwithJD). A hardcoded list of host paths, inside a change
# about not trusting hand-maintained records.
#
# The claim is only "an includedir that does not match reports no". The -g
# object above was compiled against no PostgreSQL headers at all, so this host's
# own pg_config is an includedir it was not built against -- a real mismatch
# rather than a synthetic one.
check "objects are reported FOREIGN to an includedir they were not built against" \
	"$(pgc_objects_built_for "$_probe_dir/withdbg" "$PGC_PG_CONFIG")" "no"

rm -rf "$_probe_dir"

# Every way of failing to read the objects must land on the safe side for the
# pg_config case: report foreign, so the caller cleans. An unnecessary clean
# costs a rebuild; the other direction installs one major's objects into
# another's prefix.
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
_odm_wire_lines="$(printf '%s\n' "$_wire" | wc -l | tr -d ' ')"
check_text "premise: the caller's text was actually found, so the counts mean something" \
	"$(if [ "$_odm_wire_lines" -ge 10 ]; then echo yes;
		else echo "no ($_odm_wire_lines lines, want >= 10)"; fi)" "yes"

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
