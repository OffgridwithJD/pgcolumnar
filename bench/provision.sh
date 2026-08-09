#!/usr/bin/env bash
#
# Stand up (or audit) a machine that can run bench/.
#
# Every bench harness assumes an environment that existed only because someone
# built it by hand, and the knowledge of how was spread across memories, a local
# HANDOFF.md that is deliberately not in the repository, and issue comments. A
# second machine, or this one after a rebuild, could not reproduce a number.
# That is #505.
#
# Usage:
#   bench/provision.sh check          audit only, changes nothing, safe anywhere
#   bench/provision.sh pg <variant>   build one PostgreSQL variant from source
#   bench/provision.sh contrib        install the contrib modules the suites need
#
# `check` is the important one and is deliberately the default-safe entry point:
# it is what tells you whether a box can reproduce a number, and it is what makes
# the rest of this script testable. A provisioning script nobody can verify is
# how the undocumented box happened in the first place.
#
# WHAT THIS DOES NOT DO, stated plainly rather than discovered later:
#   * It does not install Citus or TimescaleDB. Both must be built against one
#     exact PostgreSQL, and picking that version silently is how a comparison
#     ends up measuring the wrong engine. `check` reports whether they are
#     present; installing them is still manual and issue #505 says so.
#   * It does not download the ClickBench dataset (~70 GB unpacked). `check`
#     reports whether it is there.
#   * It does not install DuckDB. `check` reports whether `duckdb` is on PATH;
#     BENCH_DUCKDB=1 is what asks the harness to use it.
#
# Written fresh for pgColumnar.

set -uo pipefail

# A sanitizer build's own pg_config is instrumented and leaks on exit (it is a
# frontend tool; the leaks are in get_configdata, not in anything we ship). With
# leak detection on it prints a LeakSanitizer report and exits NON-ZERO, so every
# `$(pg_config --sharedir)` in this script comes back empty and the failure reads
# as "the extension is missing" rather than "I could not ask where it goes".
# That is how the first run of `provision.sh contrib` failed against pg18_san.
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
export LSAN_OPTIONS="${LSAN_OPTIONS:-detect_leaks=0}"

# ---------------------------------------------------------------------------
# The naming convention, which is load-bearing and was written down nowhere.
#
#   pgNNa      assert build     --enable-cassert. For the test matrix.
#   pgNNn      NON-assert       For BENCHMARKS. Every number in docs/benchmarks.md
#                               comes from one of these.
#   pgNN_san   sanitizer        clang + -fsanitize=address,undefined.
#
# Running a benchmark on an assert build is not a small error: #504 had to teach
# the profiler to REFUSE one, because asserts put verify_compact_attribute at
# 9.28% of an ingest profile. The suffix is the only thing that distinguishes
# them once installed, so it is part of the contract, not a nicety.
# ---------------------------------------------------------------------------
PREFIX_ROOT="${PGC_PREFIX_ROOT:-/usr/local}"
SRC_ROOT="${PGC_SRC_ROOT:-/root}"

# What bench/ needs. Kept here rather than in five harness headers.
WANT_PG_BENCH="pg18n"                        # the non-assert build benchmarks use
WANT_PG_MATRIX="pg15a pg16a pg17a pg18a pg19a"
WANT_PG_SAN="pg18_san"
WANT_CONTRIB="btree_gist"

ok=0; warn=0; miss=0
say_ok()   { printf '  ok      %s\n' "$1"; ok=$((ok+1)); }
say_warn() { printf '  WARN    %s\n' "$1"; warn=$((warn+1)); }
say_miss() { printf '  MISSING %s\n' "$1"; miss=$((miss+1)); }

pg_present() { [ -x "$PREFIX_ROOT/$1/bin/pg_config" ]; }

# Assert or not, read from the build itself rather than trusted from the name.
# The suffix is a claim; --configure is the fact. A pg18n that was accidentally
# built with cassert would produce benchmark numbers that are quietly wrong, and
# nothing else on the box would notice.
pg_is_assert() {
	"$PREFIX_ROOT/$1/bin/pg_config" --configure 2>/dev/null | grep -q -- '--enable-cassert'
}

check_pg() {
	local p="$1" want_assert="$2" label="$3"
	if ! pg_present "$p"; then
		say_miss "$p ($label)"
		return
	fi
	local ver
	ver="$("$PREFIX_ROOT/$p/bin/pg_config" --version 2>/dev/null)"
	if pg_is_assert "$p"; then
		if [ "$want_assert" = yes ]; then
			say_ok "$p  $ver  (assert, as required)"
		else
			say_warn "$p  $ver  is an ASSERT build but $label must not be -- benchmark numbers from it are invalid (see #504)"
		fi
	else
		if [ "$want_assert" = yes ]; then
			say_warn "$p  $ver  is NOT an assert build but $label should be -- the matrix will miss assertion failures"
		else
			say_ok "$p  $ver  (non-assert, as required)"
		fi
	fi
}

do_check() {
	echo "== PostgreSQL builds under $PREFIX_ROOT"
	check_pg "$WANT_PG_BENCH" no "the benchmark build"
	for p in $WANT_PG_MATRIX; do check_pg "$p" yes "a matrix build"; done
	for p in $WANT_PG_SAN; do
		if pg_present "$p"; then
			say_ok "$p  $("$PREFIX_ROOT/$p/bin/pg_config" --version)  (sanitizer)"
		else
			say_warn "$p (sanitizer build; test/run_san.sh needs it)"
		fi
	done

	echo "== contrib modules"
	# btree_gist is not optional: since #448 test/temporal.sh hard-FAILS without
	# it rather than skipping, because a box that cannot load it cannot gate the
	# feature. Missing it on one major is invisible until that major runs.
	# Every prefix, not just the ones that came to mind. The gap this script was
	# written to catch was two prefixes nobody enumerated; enumerating them here
	# from the same lists the rest of the script uses is the only way it does not
	# recur inside the auditor itself.
	for p in $WANT_PG_BENCH $WANT_PG_MATRIX $WANT_PG_SAN; do
		pg_present "$p" || continue
		local share
		share="$("$PREFIX_ROOT/$p/bin/pg_config" --sharedir 2>/dev/null)"
		if [ -f "$share/extension/$WANT_CONTRIB.control" ]; then
			say_ok "$WANT_CONTRIB in $p"
		else
			local ver; ver="$("$PREFIX_ROOT/$p/bin/pg_config" --version | awk '{print $2}')"
			if [ -n "$(contrib_src_for "$ver")" ]; then
				say_miss "$WANT_CONTRIB in $p  (test/temporal.sh hard-fails; 'provision.sh contrib' can fix it)"
			else
				# Reporting a problem without saying whether it is fixable here
				# is half an answer, and the half that sends someone looking.
				say_miss "$WANT_CONTRIB in $p  AND no contrib source for PostgreSQL $ver on this box"
			fi
		fi
	done

	echo "== comparison engines (this script does not install these)"
	local n18="$PREFIX_ROOT/$WANT_PG_BENCH/lib/postgresql"
	for m in citus timescaledb; do
		if ls "$n18"/${m}*.so >/dev/null 2>&1; then
			say_ok "$m present in $WANT_PG_BENCH"
		else
			say_warn "$m absent from $WANT_PG_BENCH (cross-engine comparison unavailable)"
		fi
	done
	if command -v duckdb >/dev/null 2>&1; then
		say_ok "duckdb on PATH ($(command -v duckdb)) -- BENCH_DUCKDB=1 enables it"
	else
		say_warn "duckdb not on PATH (BENCH_DUCKDB=1 will not work)"
	fi
	[ -d /srv/clickbench ] && say_ok "/srv/clickbench present" \
		|| say_warn "/srv/clickbench absent (bench/run_clickbench.sh has no dataset)"

	echo "== environment traps that have each cost a wasted run"
	# sudo/runuser do not carry LANG, so initdb aborts on an empty locale and
	# leaves a directory that is not a cluster -- which then reads as a start
	# failure several steps later.
	say_ok "initdb must be given --locale=C explicitly (sudo -u postgres drops LANG)"
	# The installing harnesses redirect make install to /dev/null, so run
	# unprivileged they fail QUIETLY and measure the previously installed .so.
	say_ok "run_bench.sh / _fsst / _readstream install: run as ROOT"
	say_ok "run_bench_join.sh / run_clickbench.sh do not install: run as the bench user"
	id -u >/dev/null
	if [ "$(id -u)" = 0 ]; then
		say_warn "you are root: bench/run_bench_join.sh and run_clickbench.sh must NOT be run this way"
	fi

	printf '\n%d ok, %d warn, %d missing\n' "$ok" "$warn" "$miss"
	[ "$miss" = 0 ]
}

# ---------------------------------------------------------------------------
# Building a PostgreSQL variant. The flags are the ones the bench box was
# actually built with, read off `pg_config --configure` there rather than
# reconstructed from memory.
# ---------------------------------------------------------------------------
build_pg() {
	local variant="$1"
	local ver="${2:-}"
	[ -n "$ver" ] || { echo "usage: provision.sh pg <variant> <version>   e.g. pg18n 18.4"; return 2; }
	local src="$SRC_ROOT/postgresql-$ver"
	[ -d "$src" ] || { echo "no source tree at $src"; return 1; }
	local prefix="$PREFIX_ROOT/$variant"
	if [ -x "$prefix/bin/pg_config" ]; then
		echo "-- $variant already present ($("$prefix/bin/pg_config" --version)); nothing to do"
		return 0
	fi
	local common="--prefix=$prefix --enable-debug --without-icu --without-readline --without-zlib"
	local extra=""
	case "$variant" in
		*_san) extra="--enable-cassert CC=clang CFLAGS=-fsanitize=address,undefined -fno-sanitize=function -O1 -g" ;;
		*a)    extra="--enable-cassert CFLAGS=-O2 -g" ;;
		*n)    extra="CFLAGS=-O2 -g" ;;
		*)     echo "unknown variant suffix in '$variant' (expected pgNNa, pgNNn or pgNN_san)"; return 2 ;;
	esac
	echo "-- building $variant from $src"
	( cd "$src" && make -s distclean >/dev/null 2>&1
	  # shellcheck disable=SC2086
	  ./configure $common $extra >/tmp/prov-$variant.conf 2>&1 &&
	  make -s -j"$(nproc)" >/tmp/prov-$variant.make 2>&1 &&
	  make -s install >/tmp/prov-$variant.inst 2>&1 ) || {
		echo "   FAILED; see /tmp/prov-$variant.{conf,make,inst}"; return 1; }
	echo "-- built $("$prefix/bin/pg_config" --version) into $prefix"
	# Verify the claim the suffix makes, rather than assuming the flags took.
	if pg_is_assert "$variant"; then
		case "$variant" in *n) echo "   WARNING: $variant is an assert build; benchmarks from it are invalid";; esac
	else
		case "$variant" in *a|*_san) echo "   WARNING: $variant is NOT an assert build";; esac
	fi
}

# Where to get contrib sources for a given version.
#
# A CONFIGURED source tree is not required and is the worse option: building a
# contrib directory inside one installs to that tree's own --prefix and ignores
# PG_CONFIG. Extracting a tarball to a scratch directory and building with
# USE_PGXS=1 uses the installed pgxs of the prefix being targeted, which sidesteps
# that trap by construction rather than guarding against it. jdatcmd did exactly
# this by hand on the bench, where no extracted tree existed at all.
#
# Prints a directory containing contrib/, or nothing.
contrib_src_for() {
	local ver="$1" d t
	for d in "$SRC_ROOT/postgresql-$ver" /usr/local/src/postgresql-$ver; do
		[ -d "$d/contrib/$WANT_CONTRIB" ] && { printf '%s' "$d"; return 0; }
	done
	# Already extracted by an earlier call in this run.
	d="/tmp/pgc-provision-src/postgresql-$ver"
	[ -d "$d/contrib/$WANT_CONTRIB" ] && { printf '%s' "$d"; return 0; }
	for t in "$SRC_ROOT/postgresql-$ver.tar.bz2" "$SRC_ROOT/postgresql-$ver.tar.gz" \
	         /home/*/postgresql-$ver.tar.bz2 /home/*/postgresql-$ver.tar.gz; do
		[ -f "$t" ] || continue
		mkdir -p /tmp/pgc-provision-src || return 1
		tar -xf "$t" -C /tmp/pgc-provision-src >/dev/null 2>&1 || return 1
		[ -d "$d/contrib/$WANT_CONTRIB" ] && { printf '%s' "$d"; return 0; }
	done
	return 1
}

install_contrib() {
	local rc=0
	for p in $WANT_PG_BENCH $WANT_PG_MATRIX $WANT_PG_SAN; do
		pg_present "$p" || continue
		local pc="$PREFIX_ROOT/$p/bin/pg_config"
		local share; share="$("$pc" --sharedir)"
		[ -f "$share/extension/$WANT_CONTRIB.control" ] && { echo "-- $WANT_CONTRIB already in $p"; continue; }
		local ver; ver="$("$pc" --version | awk '{print $2}')"
		local root; root="$(contrib_src_for "$ver")"
		[ -n "$root" ] || { echo "-- no contrib source for PostgreSQL $ver (need postgresql-$ver/ or postgresql-$ver.tar.*)"; rc=1; continue; }
		local src="$root/contrib/$WANT_CONTRIB"
		# USE_PGXS=1 is not optional here. A contrib directory INSIDE a
		# configured source tree builds in-tree and installs to that tree's own
		# ./configure --prefix, silently ignoring PG_CONFIG. Without it this
		# reported "installed into pg18n" while the files went to the prefix the
		# tree happened to be configured for last -- exit 0, empty log, nothing
		# where it was wanted.
		( cd "$src" && make -s install USE_PGXS=1 PG_CONFIG="$pc" >/tmp/prov-contrib-$p.log 2>&1 )
		# And verify the artifact rather than the exit status. A build system
		# that installs the right files into the wrong prefix returns 0.
		if [ -f "$share/extension/$WANT_CONTRIB.control" ]; then
			echo "-- installed $WANT_CONTRIB into $p"
		else
			echo "-- FAILED installing $WANT_CONTRIB into $p: $share/extension/$WANT_CONTRIB.control still absent (see /tmp/prov-contrib-$p.log)"
			rc=1
		fi
	done
	return $rc
}

case "${1:-check}" in
	check)   do_check ;;
	pg)      shift; build_pg "$@" ;;
	contrib) install_contrib ;;
	*)       sed -n '3,30p' "$0"; exit 2 ;;
esac
