# ---- a test script must be runnable the way it is documented (#852) ---------
#
# Every document that tells a reader how to run a script spells it as a command:
# `test/temporal.sh /path/to/pg_config`, `PGC_RUN_UPGRADE=1
# test/run_all_versions.sh`, `test/pbt/run.sh [seed] [iterations]`. 103 of the
# 260 top-level scripts were mode 100644 when this was written, so 30 of those
# documented invocations died with `Permission denied` before running a single
# statement.
#
# THE MATRIX NEVER SAW IT, AND THAT IS THE POINT. ci.yml:485 and nightly.yml:188
# both call `bash test/run_all_versions.sh`, and the runner launches each suite
# as `bash "$builddir/test/${s}.sh"` (lines 712 and 749). An interpreter named on
# the command line does not consult the execute bit, so a suite's own mode is
# invisible to every green run in this project's history. Those runs are honest.
# The gap is between the documentation and a shell, and only a check that reads
# the MODE can stand in it.
#
# TWO SITUATIONS, NOT ONE. Exactly one 100755 -> 100644 transition exists in the
# whole history of test/ -- 56ae5f8eb, 2026-08-16, a perf commit that added a
# line to SUITES and stripped the bit on the way past. The other 102 files were
# born 100644. So one is a regression that a check like this one would have
# caught the day it happened, and the rest are a habit that nothing ever
# contradicted.
#
# WHY THE RULE IS ANCHORED ON THE SHEBANG. The alternative populations both
# fail. A documentation-derived list ("every script docs/testing.md names") makes
# the gate a hostage to prose: delete a line from a document and the check
# silently narrows, which is the same class of accident as the one being fixed.
# A hand-maintained allowlist of names drifts, and 102 files born wrong is what
# drift looks like. The file's own first line is the honest population: a script
# that opens `#!/usr/bin/env bash` has declared that it is meant to be run, and a
# mode that forbids running it contradicts what the file already says about
# itself. So the rule needs no name list, and the two shared libraries need no
# exemption -- lib.sh carries a shebang and the bit, and portlib.sh gets the bit
# here for the same reason every suite does.
#
# THE EXEMPTION IS TWO DIRECTORIES, NOT A LIST OF FILES. test/selftest/ (these
# parts) and test/fixtures/ are SOURCED or imported, never executed:
# harness_selftest.sh:53-56 sources every part, and a suite invokes a fixture
# generator as `python3 test/fixtures/.../gen_x.py`. Giving those the bit would
# advertise a way to run them that does not work, which is this defect pointing
# the other way. Every OTHER directory under test/ is swept, so a runnable entry
# point in a new subdirectory is covered the day it is added. test/pbt/run.sh is
# why that matters: it is a documented command (docs/testing.md:132) that lives
# one level down, it is already correct, and a top-level-only sweep would have
# left the one file most like the defect outside the guard.
#
# THE WAY OUT, IF A FUTURE SCRIPT MUST NOT BE EXECUTABLE, IS TO DROP ITS SHEBANG
# AND SAY WHY IN ITS HEADER -- not to leave a 100644 file whose first line still
# claims otherwise. The second check below is what makes that an explicit act: a
# file with neither is caught too, so "no shebang" cannot become the new silent
# default.

# ---- controls ---------------------------------------------------------------
#
# A mode sweep that has never fired is indistinguishable from a tree that is
# already clean, and this one is added to a tree where it fires 103 times. The
# fixtures pin all three verdicts, so the sweep below is known to separate them
# before it is believed about the real tree.

_tsm_has_shebang() {	# _tsm_has_shebang FILE
	head -1 "$1" 2>/dev/null | grep -q '^#!'
}

_tsm_verdict() {	# _tsm_verdict FILE -> ok | noexec | noshebang
	if ! _tsm_has_shebang "$1"; then echo noshebang
	elif [ ! -x "$1" ]; then echo noexec
	else echo ok
	fi
}

_tsm_fix="$PGC_WORKDIR/tsm_shebang_noexec.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_tsm_fix"; chmod 644 "$_tsm_fix"
check "control: a script that declares an interpreter without the bit is caught" \
	"$(_tsm_verdict "$_tsm_fix")" "noexec"

_tsm_ok="$PGC_WORKDIR/tsm_shebang_exec.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_tsm_ok"; chmod 755 "$_tsm_ok"
check "control: and the same script with the bit is not" \
	"$(_tsm_verdict "$_tsm_ok")" "ok"

_tsm_none="$PGC_WORKDIR/tsm_no_shebang.py"
printf 'import sys\n' > "$_tsm_none"; chmod 644 "$_tsm_none"
check "control: and a script with no interpreter line is caught separately" \
	"$(_tsm_verdict "$_tsm_none")" "noshebang"

# The bit has to survive the copy, or this check reads a mode the repository
# does not have. run_all_versions.sh:668 stages the tree with `cp -a`, and the
# matrix runs these parts out of that staged copy. Pinned as a property of the
# copy rather than trusted from the flag.
_tsm_cp_src="$PGC_WORKDIR/tsm_copy_src.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_tsm_cp_src"; chmod 755 "$_tsm_cp_src"
cp -a "$_tsm_cp_src" "$PGC_WORKDIR/tsm_copy_dst.sh"
check "control: cp -a preserves the execute bit, so a staged tree reads the same" \
	"$(_tsm_verdict "$PGC_WORKDIR/tsm_copy_dst.sh")" "ok"

# ---- the population ---------------------------------------------------------
#
# Every .sh and .py under test/, at any depth, MINUS the two sourced
# directories. Pruned with -path so a file is excluded by the directory it is
# in, not by matching its name against a list.

_tsm_scripts=()
while IFS= read -r _tsm_f; do
	_tsm_scripts+=("$_tsm_f")
done < <(find "$PGC_TESTDIR" \
	\( -path "$PGC_TESTDIR/selftest" -o -path "$PGC_TESTDIR/fixtures" \) -prune -o \
	-type f \( -name '*.sh' -o -name '*.py' \) -print | sort)

# ---- premises ---------------------------------------------------------------

# A sweep over an empty population passes vacuously, and a find that matched
# nothing looks exactly like a clean tree.
check "premise: the sweep reads a population of scripts, not an empty find" \
	"$([ "${#_tsm_scripts[@]}" -ge 200 ] && echo enough || echo "${#_tsm_scripts[@]}")" "enough"

# The prune must exclude those two directories and nothing else. Both halves
# matter: an over-broad prune would silently empty the sweep, and a prune that
# missed would redden every sourced part.
check "premise: the sourced parts and the fixtures are outside the population" \
	"$(printf '%s\n' "${_tsm_scripts[@]}" | grep -cE '/(selftest|fixtures)/')" "0"

# and the prune did not also swallow a subdirectory that IS swept
check "premise: a runnable script one level down is inside the population" \
	"$(printf '%s\n' "${_tsm_scripts[@]}" | grep -c '/pbt/run\.sh$')" "1"

# The two exempted directories are non-empty, so the exemption is a real
# decision about real files rather than a prune of nothing.
check "premise: the exempted directories actually hold scripts" \
	"$([ "$(find "$PGC_TESTDIR/selftest" "$PGC_TESTDIR/fixtures" -type f \
		\( -name '*.sh' -o -name '*.py' \) | wc -l)" -ge 40 ] && echo yes || echo no)" "yes"

# ---- the sweep --------------------------------------------------------------

_tsm_noexec=""; _tsm_noexec_n=0
_tsm_noshebang=""; _tsm_noshebang_n=0
for _tsm_f in "${_tsm_scripts[@]}"; do
	case "$(_tsm_verdict "$_tsm_f")" in
		noexec)
			_tsm_noexec_n=$((_tsm_noexec_n + 1))
			[ "$_tsm_noexec_n" -le 5 ] && _tsm_noexec="$_tsm_noexec ${_tsm_f#"$PGC_TESTDIR"/}"
			;;
		noshebang)
			_tsm_noshebang_n=$((_tsm_noshebang_n + 1))
			[ "$_tsm_noshebang_n" -le 5 ] && _tsm_noshebang="$_tsm_noshebang ${_tsm_f#"$PGC_TESTDIR"/}"
			;;
	esac
done

# The count leads the message and at most five names follow it: a real failure
# is one or two files and wants naming, while the 103 this was written against
# would otherwise print an unreadable line.
_tsm_fmt() {	# _tsm_fmt N NAMES
	[ "$1" -eq 0 ] && { echo "[]"; return; }
	echo "[$1:$2]"
}

check "every documented test script is executable" \
	"$(_tsm_fmt "$_tsm_noexec_n" "$_tsm_noexec")" "[]"

check "and every one of them declares its interpreter" \
	"$(_tsm_fmt "$_tsm_noshebang_n" "$_tsm_noshebang")" "[]"
