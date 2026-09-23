# ---- a hand rebuild must leave the harness able to verify freshness (#1230) --
#
# `rebuild.sh` is the script this repo tells a developer to run for a clean
# rebuild, and it is careful: it cleans with the right PG_CONFIG, deletes the
# installed artifacts first so a failed install cannot leave the old library
# loadable, and verifies every undefined symbol resolves against the target
# postgres. What it did not do was write the harness's stamps, because it never
# sourced lib.sh.
#
# SO THE FRESHNESS GATE ACCUSED A CORRECT BINARY. Driven on the container:
#
#   A. harness-built, build skipped   -- source: 9cea7e4a926b matches the binary
#   B. edit a .c, then rebuild.sh     rc=0, .so built from the edited source
#   C. the same suite, build skipped  FATAL: the binary under test was not built
#                                     from this source (refusing to report checks
#                                     about code that is not installed)
#
# Both halves of that refusal are false: the binary WAS built from that source one
# step earlier, and the code IS installed. The reader is sent to the compiler and
# to a list of 66 files when the answer is that a stamp did not move. It cost
# three runs the last time it happened, two of them spent deleting object files.
#
# A guard that refuses correct work gets switched off, and the rule goes with it.
#
# THE TOOL KEEPS ITS OWN BUILD. Routing it through `pgc_build_and_install` would
# lose the parallel `-j` build, the compiler-warning gate that mirrors the matrix,
# and the error extraction from the build log -- none of which the harness builder
# has. Only the RECORD was missing, so only the record is added.

# PREMISE: the tool installs, which is what makes a missing record dangerous.
_hr_installs="$(sed 's/#.*//' "$PGC_TESTDIR/rebuild.sh" 2>/dev/null |
	grep -cE 'make[^|;&]*install')"
check_num "premise: the hand rebuild tool installs, so a stale record is possible" \
	"$(if [ "$_hr_installs" -ge 1 ]; then echo 1; else echo 0; fi)" "1"

# AND that one place knows how to write the record, so the arm below is not
# asking for a second copy of the stamp format.
check_num "premise: lib.sh has one recorder for what was installed" \
	"$(sed 's/#.*//' "$PGC_TESTDIR/lib.sh" | grep -c '^pgc_record_source_stamp()')" "1"

# COMMENTS STRIPPED (#1222): a comment naming the recorder must not satisfy this.
_hr_records="$(sed 's/#.*//' "$PGC_TESTDIR/rebuild.sh" 2>/dev/null |
	grep -cE 'pgc_record_source_stamp|pgc_build_and_install')"
check_num "the hand rebuild tool records what it installed rather than only naming it" \
	"$(if [ "$_hr_records" -ge 1 ]; then echo 1; else echo 0; fi)" "1"

# THE RECORDER REFUSES RATHER THAN RECORDING SOMETHING PLAUSIBLE (#1232 review).
# Called with nothing it used to write `./.pgc_source_stamp.0.nolibd41` into the
# CURRENT DIRECTORY -- keyed by the md5 of an empty pkglibdir, `d41` being the
# front of d41d8cd98f00, the md5 of nothing -- holding a fingerprint of the
# current directory rather than of any source. A believable record in the wrong
# place is worse than no record, because the freshness gate reads it.
check_num "the recorder refuses when it is not told what was installed" \
	"$(pgc_record_source_stamp >/dev/null 2>&1; echo $?)" "1"

# AND WROTE NOTHING WHILE REFUSING, checked from a directory of its own so a
# stray file cannot be confused with one already there.
_hr_cwd="$(mktemp -d)"
check_num "and writes no stamp into the directory it was called from" \
	"$(cd "$_hr_cwd" && pgc_record_source_stamp >/dev/null 2>&1; ls -A "$_hr_cwd" | wc -l)" "0"
rm -rf "$_hr_cwd"

# ---- driven, against a pg_config shim so nothing reaches a real prefix -------
#
# The arm above is a spelling check and would pass on a call that writes the
# wrong thing. This runs the tool for real and then asks the FRESHNESS GATE, which
# is the thing that was refusing.
#
# NOTHING HERE TOUCHES SHARED STATE. The shim answers --pkglibdir and --sharedir
# with a temporary directory and passes every other question through, so the
# install lands in the temp prefix; the tree is a copy; and the stamp path is
# keyed by the md5 of pkglibdir, so it cannot collide with a real one. While a
# matrix holds a major, an install into its prefix is a write to shared state that
# `harness_selftest` itself reports as a stale .so -- this part must not be the
# thing that causes it.
_hr_tmp="$(mktemp -d)"
mkdir -p "$_hr_tmp/prefix/lib" "$_hr_tmp/prefix/share/extension" "$_hr_tmp/tree"
{
	echo '#!/bin/bash'
	echo 'for a in "$@"; do'
	echo '	case "$a" in'
	printf '\t\t--pkglibdir) echo "%s/prefix/lib"; exit 0 ;;\n' "$_hr_tmp"
	printf '\t\t--sharedir)  echo "%s/prefix/share"; exit 0 ;;\n' "$_hr_tmp"
	echo '	esac'
	echo 'done'
	printf 'exec %s "$@"\n' "$PGC_SELFTEST_PG_CONFIG"
} > "$_hr_tmp/pg_config"
chmod +x "$_hr_tmp/pg_config"
tar cf - --exclude=.git -C "$PGC_TESTDIR/.." . 2>/dev/null | tar xf - -C "$_hr_tmp/tree" 2>/dev/null

# THE SHIM MUST ACTUALLY REDIRECT, or the arm below measures the live prefix and
# passes for the wrong reason -- and would have installed over it to do so.
check_text "premise: the shim redirects the install away from the real prefix" \
	"$(if [ "$("$_hr_tmp/pg_config" --pkglibdir)" = "$_hr_tmp/prefix/lib" ] &&
		[ "$("$_hr_tmp/pg_config" --bindir)" = "$("$PGC_SELFTEST_PG_CONFIG" --bindir)" ];
	then echo redirected; else echo passthrough; fi)" "redirected"

# AND THAT NO STAMP EXISTS YET for this prefix, so what the arm reads afterwards
# was written by the run and not copied in with the tree.
# AND THE LIVE PREFIX IS WATCHED WHILE THE RUN HAPPENS (@jdatcmd, review). The
# day the shim stops redirecting is the day this arm installs over the real .so
# and the run still looks clean.
#
# MTIME, NOT DIGEST. The tree here is a copy of the tree under test and the build
# is byte-reproducible, so an install that DID land on the live prefix would write
# the same bytes and leave the digest identical: a control that cannot fail. The
# mtime moves whether or not the content does, and that is the whole signal.
_hr_live_so="$("$PGC_SELFTEST_PG_CONFIG" --pkglibdir)/pgcolumnar.so"
_hr_live_before="$(stat -c %Y "$_hr_live_so" 2>/dev/null)"

_hr_stamp="$(pgc_source_stamp_path "$_hr_tmp/tree" "$_hr_tmp/pg_config")"
check_text "premise: no stamp for this prefix before the rebuild" \
	"$(if [ -e "$_hr_stamp" ]; then echo present; else echo absent; fi)" "absent"

"$PGC_TESTDIR/rebuild.sh" "$_hr_tmp/pg_config" "$_hr_tmp/tree" >"$_hr_tmp/rebuild.log" 2>&1
_hr_rc=$?
check_num "premise: the hand rebuild itself succeeded" "$_hr_rc" "0"

check_text "and the freshness gate then reads the tree as built from this source" \
	"$(pgc_freshness_verdict \
		"$(head -1 "$_hr_stamp" 2>/dev/null)" \
		"$(pgc_source_fingerprint "$_hr_tmp/tree")")" "fresh"

# THE SAME READ AGAINST A FINGERPRINT THAT IS NOT THIS TREE'S, so the arm above
# is known to distinguish rather than to answer "fresh" whatever it is given.
check_text "and it reads a different source as stale rather than fresh" \
	"$(pgc_freshness_verdict "$(head -1 "$_hr_stamp" 2>/dev/null)" deadbeefdead)" "stale"

check_text "and the installed library of the running major was never touched" \
	"$(if [ "$(stat -c %Y "$_hr_live_so" 2>/dev/null)" = "$_hr_live_before" ];
	then echo untouched; else echo overwritten; fi)" "untouched"

rm -rf "$_hr_tmp"
