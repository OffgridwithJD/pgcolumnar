# ---- a header edit must rebuild, or every header mutation proof is vacuous ---
#
# PGXS emits header dependencies only when the SERVER was configured with
# --enable-depend, and `autodepend` is empty in the Makefile.global of every
# server this project builds against. Without them `make` sees src/*.o as newer
# than src/*.c and rebuilds NOTHING however the headers changed (#1158).
#
# That is not a slow build, it is a WRONG one, and it is silent. Measured on
# PG16 before the fix: edit PGCOLUMNAR_LOCKCLASS_UNIQUE_KEY in src/columnar.h,
# run `make`, and the build succeeds with pgcolumnar.so byte-identical at
# 2b8bfc2a6d75. Afterwards, in the same shape, the object moves from
# 74840637f16c to 7cfcb28e9fe3. (The two clean-build fingerprints differ because
# the .so md5 is a function of the BUILD DIR, so only the before/after pair
# within one directory is a comparison.)
#
# EVERY removal proof that mutates a constant, macro, struct or inline function
# in a header ran against a stale object and reported a clean pass, which reads
# as "the code is not load-bearing" -- the most expensive wrong answer a proof
# can give.
#
# THIS PART ASSERTS THE OUTCOME, NOT THE MAKEFILE TEXT. A grep for `-MMD` says
# the flag is written down; these arms say the build that just ran produced the
# dependency files and that they name the headers. The tree was built by
# pgc_setup before this suite ran, so the evidence is a real build's output.
_hd_src="${PGC_SRCDIR:-}"

check "premise: the selftest knows where the tree it builds is" \
	"$([ -n "$_hd_src" ] && [ -d "$_hd_src/src" ] && echo yes || echo "no (PGC_SRCDIR=[$_hd_src])")" \
	"yes"

# THE PREMISE THAT STOPS EVERY ARM BELOW PASSING OVER NOTHING. A tree with no
# objects has no .d files either, and "0 of 0" reconciles perfectly.
_hd_o="$(ls "$_hd_src"/src/*.o 2>/dev/null | wc -l | tr -d ' ')"
check "premise: this tree was compiled here, so there are objects to depend on" \
	"$([ "$_hd_o" -ge 1 ] && echo yes || echo "no ($_hd_o objects in $_hd_src/src)")" \
	"yes"

_hd_d="$(ls "$_hd_src"/src/*.d 2>/dev/null | wc -l | tr -d ' ')"
check "every object carries a dependency file beside it" \
	"$([ "$_hd_d" -eq "$_hd_o" ] && echo yes || echo "no ($_hd_d .d for $_hd_o .o)")" \
	"yes"

# A .d that lists only the .c would satisfy the count and record nothing useful,
# which is the shape that made the bug invisible in the first place.
_hd_withhdr="$(grep -l 'src/columnar\.h\|/columnar\.h' "$_hd_src"/src/*.d 2>/dev/null | wc -l | tr -d ' ')"
check "and the dependency files name the project headers, not just the .c" \
	"$([ "$_hd_withhdr" -ge 1 ] && echo yes || echo "no (0 of $_hd_d .d mention columnar.h)")" \
	"yes"
echo "      $_hd_withhdr of $_hd_d dependency files name columnar.h"

# The server's own setting, printed rather than asserted. A server configured
# with --enable-depend would make this redundant rather than wrong, and an arm
# that went red there would be refusing a correct configuration.
_hd_global="$("${PGC_PG_CONFIG:-pg_config}" --pgxs 2>/dev/null | sed 's|/makefiles/pgxs.mk|/Makefile.global|')"
echo "      server autodepend: [$(sed -n 's/^autodepend = //p' "$_hd_global" 2>/dev/null | head -1)] in $_hd_global"
