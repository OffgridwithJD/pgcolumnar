#!/usr/bin/env bash
#
# pgColumnar multi-version build-and-test matrix.
#
# For each pg_config given, this builds the extension fresh in a per-major build
# directory (so nothing leaks between majors) and runs every suite
# (smoke + phase2..phase6 + audit + concurrency + unique_conc + differential +
# recovery + fuzz) against it. It prints a
# per-version PASS/FAIL line and
# a final summary table, and exits non-zero if any version fails to build or any
# suite fails.
#
# Usage:
#   test/run_all_versions.sh [PG_CONFIG ...]
#
# With no arguments it uses a default list covering PostgreSQL 15 through 19.
# PostgreSQL 13 (end of life) and 14 are no longer in the default matrix.
# Each PG_CONFIG must point at an assert-enabled build to exercise the asserts.
# Run as a user that may "runuser -u postgres" (e.g. root); the suites start
# throwaway clusters as the postgres OS user.
#
# Written fresh for pgColumnar. It reuses no upstream test harness.

set -uo pipefail

# ---------------------------------------------------------------------------
# Run from a private copy of this script, and refuse to run twice at once.
#
# Both guards exist because both failures happened, and neither announced
# itself as what it was.
#
# bash reads a script incrementally as it executes it, so editing this file
# while a run is in progress corrupts the run in place. A gate died at
# "line 139: `done'" with the file on disk perfectly valid, because the bytes
# had moved under the interpreter between one read and the next. Re-executing
# from a copy makes an in-flight run immune to whatever happens to the original.
#
# And two runs at once quietly ruin each other: they contend for clusters and
# ports, and the symptom is a suite failing with no named check -- a wall of
# ERROR: database "regress" already exists and a red result that looks exactly
# like a real one. Three false reds in one day were traced to this. A run now
# leaves a lock naming its pid, so the second one says so and stops instead of
# producing a result nobody can trust.
# ---------------------------------------------------------------------------

PGC_RUN_LOCK="${PGC_RUN_LOCK:-/tmp/pgcolumnar-run_all_versions.lock}"

if [ -z "${PGC_RUN_REEXEC:-}" ]; then
	# Take the lock before copying, so two starts cannot both decide they are first.
	if [ -e "$PGC_RUN_LOCK" ]; then
		_holder="$(sed -n 1p "$PGC_RUN_LOCK" 2>/dev/null)"
		if [ -n "$_holder" ] && kill -0 "$_holder" 2>/dev/null; then
			echo "FATAL: a matrix run is already in progress (pid $_holder)" >&2
			sed -n '2,$p' "$PGC_RUN_LOCK" >&2 2>/dev/null
			echo "       wait for it, or kill $_holder, or set PGC_RUN_LOCK to run" >&2
			echo "       against a separate tree on a different port." >&2
			exit 1
		fi
		echo "note: taking over a stale lock from pid ${_holder:-unknown}" >&2
		rm -f "$PGC_RUN_LOCK"
	fi

	{
		echo "$$"
		echo "       started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
		echo "       tree:    $(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
		echo "       args:    ${*:-<default matrix>}"
	} > "$PGC_RUN_LOCK"

	# The lock is removed only by the process that took it, so a stale-lock
	# takeover cannot have its lock deleted by the run it replaced.
	trap 'if [ "$(sed -n 1p "$PGC_RUN_LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$PGC_RUN_LOCK"; fi' EXIT

	_self="$(mktemp "/tmp/pgcolumnar-run_all_versions.$$.XXXXXX.sh")"
	cp "${BASH_SOURCE[0]}" "$_self"
	chmod +x "$_self"
	PGC_RUN_REEXEC=1 \
	PGC_RUN_SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" \
	PGC_RUN_LOCK="$PGC_RUN_LOCK" \
	PGC_RUN_OWNER="$$" \
		bash "$_self" "$@"
	_rc=$?
	rm -f "$_self"
	exit $_rc
fi

# Re-executed from the copy: the lock belongs to the parent, which removes it,
# and the tree to test is the original one rather than wherever the copy landed.
trap - EXIT

SRCDIR="${PGC_RUN_SRCDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SUITES=(harness_selftest smoke phase2 phase3 phase4 phase5 phase6 audit concurrency unique_conc \
	differential recovery fuzz hardening concurrent_diff parallel sorted_projection \
	arrow_export parquet_export read_stream corruption \
	generated_columns temporal arrow_import index_only projections arrow_nested parquet_import parquet_nested arrow_nested_import parquet_nested_import native_writer native_roundtrip native_encoding native_zonemap write_minmax_fastpath write_fsst_compressed encode_effort native_skip pushdown_report native_agg native_agg_deletes native_agg_addcolumn native_bloom bloom_setting native_vecskip native_index native_fetch_position native_dml alter_column_type native_ios native_projection native_cluster native_compact native_recluster native_reclaim native_ownership drop_cleanup native_reclaim_cycles native_reclaim_frag native_reclaim_reconcile native_gap native_truncate native_rewrite native_rewrite_conc rewrite_group_scan native_parquet_schema native_read_parquet native_parquet_fdw native_parquet_pushdown native_parquet_hardening native_parquet_stack native_parquet_units native_parquet_flba native_parquet_codecs native_parquet_projection native_parquet_multifile native_parquet_streaming native_parquet_partition native_cancel wal_envelope decode_interrupts import_exclusion import_deferred fk_referencing row_triggers native_lazy_slot native_fetch_cache native_fetch_interrupt analyze_stats analyze_reltuples native_fetch_projection isolation)

# Default matrix: one assert-enabled pg_config per major, 15 through 19.
DEFAULT_CONFIGS=(
	/usr/local/pg15/bin/pg_config
	/usr/local/pg16/bin/pg_config
	/usr/local/pg17/bin/pg_config
	/usr/local/pgsql/bin/pg_config
	/usr/local/pg19/bin/pg_config
)

if [ "$#" -gt 0 ]; then
	CONFIGS=("$@")
else
	CONFIGS=("${DEFAULT_CONFIGS[@]}")
fi

# A private base port per run, bumped per suite, to avoid clashes.
#
# Derived from the run's own pid rather than fixed, because a fixed default is
# not private: two runs on one box then start at the same port and fight over
# every cluster. The lock above makes that refuse rather than happen, but the
# suites are also run individually, and they should not collide either.
BASE_PORT="${PGC_BASE_PORT:-$(( 40000 + (${PGC_RUN_OWNER:-$$} % 20000) ))}"

overall=0
declare -a SUMMARY

# Suites whose checks compare wall-clock times, and which therefore cannot be run
# beside five others.
#
# The rest of the matrix runs PGC_JOBS suites at once, each with its own cluster,
# so every ratio in those suites is measured under six-way contention. That is
# not a fixture problem and no threshold survives it: the same check on the same
# build measures 1.11 alone and 2.11 inside the matrix, against a bound of 2.0.
# Three suites produced red gates that way in one session, each costing a re-run
# to disprove, which is how a matrix teaches its readers to discount red.
#
# Tuning the fixtures was tried first and does not work. On the group-doubling
# check, raising the fetch count to dilute the shared decode makes the ratio
# worse rather than better -- 1.08 at 6,000 fetches, 1.23 at 20,000, 1.29 at
# 40,000 -- because per-fetch cost is itself a function of group size, so more
# fetches amplify the difference instead of averaging it away. The comment in
# native_fetch_position.sh that recommended exactly that has been corrected.
#
# Not every wall-clock ratio belongs here, and the distinction is measurable
# rather than a matter of taste. native_fetch_cache asserts one on the same
# index-driven fetch with the same stopwatch, and is deliberately absent: it
# compares one big group against ten small ones, and the cache equalises
# per-fetch cost across both sides, so contention is common-mode and cancels in
# the ratio. Measured, six-way: absolute times roughly doubled and the ratio
# stayed near 1 against a bound of 3, worst case 1.15.
#
# The three below measure quantities whose per-fetch or per-query cost is itself
# a function of the thing being varied, so contention is differential and does
# not cancel. That is the test for membership: does the load move both sides of
# the ratio together?
#
# So they run alone. It costs a few minutes per major and it buys a timing
# result that means something.
is_timing_suite() {
	case "$1" in
		native_fetch_position|native_cancel|native_agg_deletes) return 0 ;;
		*) return 1 ;;
	esac
}

for pgc in "${CONFIGS[@]}"; do
	if [ ! -x "$pgc" ]; then
		echo "SKIP  $pgc (not executable)"
		SUMMARY+=("SKIP   $pgc")
		continue
	fi

	ver="$("$pgc" --version)"
	major="$(echo "$ver" | sed -E 's/^[^0-9]*([0-9]+).*/\1/')"
	builddir="$(mktemp -d "/tmp/pgcolumnar-matrix-${major}.XXXXXX")"

	echo "==================================================================="
	echo "== $ver"
	echo "== pg_config=$pgc"
	echo "== builddir=$builddir"
	echo "==================================================================="

	# Fresh copy of the tree so each major builds in isolation.
	cp -a "$SRCDIR/." "$builddir/"
	make -C "$builddir" clean PG_CONFIG="$pgc" >/dev/null 2>&1 || true

	if ! make -C "$builddir" PG_CONFIG="$pgc" >/dev/null 2>"$builddir/build.err"; then
		echo "BUILD FAILED"
		sed 's/^/    /' "$builddir/build.err"
		SUMMARY+=("FAIL   PG$major  (build)")
		overall=1
		continue
	fi
	# Any compiler warning is a failure for this matrix.
	if grep -q "warning:" "$builddir/build.err"; then
		echo "BUILD WARNINGS"
		grep "warning:" "$builddir/build.err" | sed 's/^/    /'
		SUMMARY+=("FAIL   PG$major  (warnings)")
		overall=1
		continue
	fi

	# Install the extension once for this version; the suites then skip their own
	# build/install (PGC_SKIP_BUILD) and run in parallel, each in its own throwaway
	# cluster on its own port. This keeps per-suite cluster isolation (crash and
	# recovery suites need it) while removing the redundant per-suite rebuild and
	# the serial initdb/start bottleneck. PGC_JOBS controls the degree.
	if ! make -C "$builddir" install PG_CONFIG="$pgc" >/dev/null 2>>"$builddir/build.err"; then
		echo "INSTALL FAILED"
		sed 's/^/    /' "$builddir/build.err"
		SUMMARY+=("FAIL   PG$major  (install)")
		overall=1
		continue
	fi

	verfail=0
	results=""
	maxjobs="${PGC_JOBS:-6}"
	for s in "${SUITES[@]}"; do
		if is_timing_suite "$s"; then
			continue
		fi
		# throttle to maxjobs concurrent suites
		while [ "$(jobs -rp | wc -l)" -ge "$maxjobs" ]; do wait -n; done
		port=$((BASE_PORT++))
		(
			PGC_SKIP_BUILD=1 PGC_PORT="$port" \
				bash "$builddir/test/${s}.sh" "$pgc" >"$builddir/${s}.log" 2>&1
			echo $? >"$builddir/${s}.rc"
		) &
	done
	wait

	# Then the timing-sensitive suites, one at a time, with nothing else running.
	for s in "${SUITES[@]}"; do
		if ! is_timing_suite "$s"; then
			continue
		fi
		port=$((BASE_PORT++))
		PGC_SKIP_BUILD=1 PGC_PORT="$port" \
			bash "$builddir/test/${s}.sh" "$pgc" >"$builddir/${s}.log" 2>&1
		echo $? >"$builddir/${s}.rc"
	done

	# collect results in suite order for a stable, readable summary
	for s in "${SUITES[@]}"; do
		if [ "$(cat "$builddir/${s}.rc" 2>/dev/null)" = 0 ]; then
			echo "  PASS  $s"
			results+="$s=PASS "
		else
			echo "  FAIL  $s"
			tail -20 "$builddir/${s}.log" | sed 's/^/      /'
			results+="$s=FAIL "
			verfail=1
		fi
	done

	if [ "$verfail" = 0 ]; then
		SUMMARY+=("PASS   PG$major  ${results}")
	else
		SUMMARY+=("FAIL   PG$major  ${results}")
		overall=1
	fi
	rm -rf "$builddir"
done

echo
echo "===================== MATRIX SUMMARY ============================"
for line in "${SUMMARY[@]}"; do
	echo "  $line"
done
echo "================================================================"
if [ "$overall" = 0 ]; then
	echo "ALL VERSIONS PASSED"
else
	echo "SOME VERSIONS FAILED"
fi
exit "$overall"
