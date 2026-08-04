#!/usr/bin/env bash
#
# Build an AddressSanitizer + UndefinedBehaviorSanitizer PostgreSQL for the
# sanitizer gate (issue #224). The ordinary matrix is five assert builds, none
# instrumented, so a memory-safety defect that does not happen to fault -- an
# unaligned load, an out-of-bounds read that lands inside the process -- is
# invisible to it. #225 found exactly that class (an unaligned varlena header on
# the plain write path) only because it was run against an instrumented build by
# hand. This makes that build reproducible and scriptable.
#
# The environment fights back in four specific ways, all handled here:
#
#   1. Build in-tree from a FRESH tarball, never VPATH against a configured tree.
#      /root/postgresql-18.4 already has a config.status; a VPATH build against it
#      fails to link. We extract a clean copy.
#   2. clang, not gcc. This looks like a free choice and is not. The defect this
#      gate exists to catch (#225) is a 4-byte varlena header read at an unaligned
#      address, and the read sits behind a 1-byte-header branch that tests the same
#      byte (PgColumnarVarSizeAnyUnaligned). gcc's -fsanitize=alignment silently
#      drops the check on that guarded load at -O1 -- verified: the load happens
#      45,000 times on a low-cardinality-text INSERT, gcc reports none, clang
#      reports it. A gcc build here would run clean and prove nothing, which is the
#      exact vacuous-green shape #224 was filed against. So: clang. Its
#      -fsanitize=function does flag dynahash's function-pointer casts, which is the
#      one piece of core noise, so -fno-sanitize=function drops it while keeping the
#      alignment and bounds checks. (gcc has no `function` check to drop.)
#   3. ASAN_OPTIONS=detect_leaks=0: the tools built here (pg_config, initdb) are
#      themselves instrumented and leak by design at exit, so LeakSanitizer would
#      fire on every invocation and poison the values PGXS reads and the initdb
#      this build needs.
#   4. ASAN_OPTIONS=detect_stack_use_after_return=0: without it initdb aborts.
#
# Usage:  test/build_san.sh [PREFIX]
#   PREFIX               install target (default /usr/local/pg18_san)
#   PGC_PG_TARBALL       source tarball (default /root/postgresql-18.4.tar.bz2)
#   PGC_SAN_SRC          scratch source dir (default /root/pg18_san_src)
#
set -euo pipefail

PREFIX="${1:-/usr/local/pg18_san}"
TARBALL="${PGC_PG_TARBALL:-/root/postgresql-18.4.tar.bz2}"
SRC="${PGC_SAN_SRC:-/root/pg18_san_src}"

# The tools invoked during the build are instrumented; keep their by-design exit
# leaks and stack-use-after-return from aborting the build (traps 3 and 4).
export ASAN_OPTIONS="detect_leaks=0:detect_stack_use_after_return=0:abort_on_error=1"

# Trap 1: fresh in-tree extraction.
echo "-- extracting $TARBALL -> $SRC"
rm -rf "$SRC"
mkdir -p "$SRC"
tar -xf "$TARBALL" -C "$SRC" --strip-components=1
cd "$SRC"

# clang + address,undefined, minus the dynahash function-cast noise.
SAN="-fsanitize=address,undefined -fno-sanitize=function -fno-omit-frame-pointer"
echo "-- configure"
./configure --prefix="$PREFIX" --enable-cassert --enable-debug \
	--without-icu --without-readline --without-zlib \
	CC=clang CFLAGS="$SAN -O1 -g" LDFLAGS="$SAN" >/tmp/san-configure.log 2>&1

echo "-- make (this takes a while under instrumentation)"
make -s -j"$(nproc)" >/tmp/san-make.log 2>&1
echo "-- make install"
make -s install >/tmp/san-install.log 2>&1

echo "-- built $PREFIX"
"$PREFIX/bin/pg_config" --configure
