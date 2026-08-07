#!/usr/bin/env bash
#
# pgColumnar pgcolumnar.analyze(): per-column statistics without reading the
# whole table (issue #414).
#
# Core ANALYZE decodes essentially the entire table. It samples 30,000 rows, and
# on a table of any size those rows are spread across every row group, so every
# group is decoded for every column. Measured on 3M rows x 20 columns (1237 MB,
# incompressible fixture, serial):
#
#   decode all 19 text columns (a full-table read)   7,680 ms
#   ANALYZE w (20 columns)                           6,302 ms
#   decode only k out of the 20-column table           268 ms
#   heap ANALYZE wh (k)                                186 ms
#
# So ANALYZE costs about what reading the whole table costs, and reading one
# column costs 23.5x less. That gap is what this function exists to collect.
#
# It cannot be fixed in the table-AM callbacks, and that is settled rather than
# assumed. acquire_sample_rows copies whole tuples (ExecCopySlotHeapTuple), so
# the AM cannot decline to produce columns core is about to copy -- ANALYZE w
# costs 6,302 ms against ANALYZE w (k) at 6,073 ms, a 6% saving for asking for
# one column out of twenty. Nor is there slack in which row groups the sample
# touches: rebuilding at a tenth the chunk_group_row_limit left the cost
# unchanged (6,466 ms against 6,771 ms), because a fixed-size sample simply
# touches proportionally more groups when they are smaller.
#
# This suite is about the function, not the AM sampler. test/analyze_stats.sh
# covers the sampler (#154) and stays the correctness path for plain ANALYZE.
#
# Slice 1 asserts null_frac comes from the zone maps and is EXACT where core's
# is sampled. Slice 2 asserts n_distinct is exact from reading ONE column, which
# is the claim the whole issue rests on.
#
# Usage:  test/analyze_function.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg18/bin/pg_config}"

ROWS=${PGC_ANALYZE_ROWS:-500000}

# Writing statistics uses pg_restore_attribute_stats, which core added in 18.
# On 15 to 17 this would mean writing pg_statistic directly, which is a real
# version-support decision and not a detail (stavalues anyarray typing, staop,
# stacoll, stadistinct's sign convention). Refuse rather than silently narrow:
# pgc_skip fails by default and must be waived deliberately.
if [ "$PGC_MAJOR" -lt 18 ]; then
	pgc_skip PG18_STATS_API \
		"pgcolumnar.analyze() needs pg_restore_attribute_stats (PG18+); this server is $PGC_MAJOR"
fi

# --- fixture ------------------------------------------------------------------
#
# k is NULL for exactly one row in ten. 500,000 rows against core's 30,000-row
# sample is what makes the sampled estimate inexact, which slice 1 depends on.

psql_run "DROP TABLE IF EXISTS af_c;
	CREATE TABLE af_c (k int, skew int, pad1 text, pad2 text, pad3 text) USING pgcolumnar;
	INSERT INTO af_c SELECT
		CASE WHEN g % 10 = 0 THEN NULL ELSE g % 45001 END,
		CASE WHEN g = 1 THEN 1000000 ELSE g % 100000 END,
		md5(g::text), md5((g * 7)::text), md5((g * 13)::text)
	FROM generate_series(1, $ROWS) g;" >/dev/null

# --- premise 1: the fixture really is one-in-ten NULL --------------------------
#
# Everything below compares against 0.1. If the fixture is not 10% NULL then a
# "PASS" means the function agreed with a number that was never true.

true_nullfrac="$(q "SELECT round(count(*) FILTER (WHERE k IS NULL)::numeric / count(*), 6)
	FROM af_c")"
check_num "premise: the fixture is exactly one-in-ten NULL" "$true_nullfrac" "0.100000"

# --- premise 2: core's sampled null_frac is NOT exact --------------------------
#
# This is the premise that makes the slice-1 check mean something. If core's
# sample happened to land on the truth, then "exact" and "sampled" are the same
# number here, and an implementation that merely called core ANALYZE would pass.
# The test would be vacuous in precisely the way a green suite hides.
#
# So assert the two differ BEFORE asserting ours is the exact one. If this fails,
# the fixture is not discriminating and the suite is reporting nothing -- rerun
# or raise PGC_ANALYZE_ROWS rather than trusting a pass below it.

psql_run "ANALYZE af_c;" >/dev/null
core_nullfrac="$(q "SELECT null_frac FROM pg_stats WHERE tablename = 'af_c' AND attname = 'k'")"
# Captured BEFORE our call, because our call overwrites them. Reading these
# afterwards would compare our own output against itself.
core_ndistinct_before="$(q "SELECT n_distinct FROM pg_stats WHERE tablename = 'af_c' AND attname = 'k'")"
core_correlation_before="$(q "SELECT correlation FROM pg_stats WHERE tablename = 'af_c' AND attname = 'k'")"

if ! pgc_is_number "$core_nullfrac"; then
	check_num "premise: core ANALYZE produced a null_frac to compare against" \
		"$core_nullfrac" "a number"
else
	check "premise: core's sampled null_frac differs from the truth, so this suite can discriminate" \
		"$(awk -v c="$core_nullfrac" -v t="$true_nullfrac" \
			'BEGIN { print (c == t) ? "no (sample landed exactly on truth; suite is vacuous)" : "yes" }')" \
		"yes"
	echo "-- core sampled null_frac = $core_nullfrac, truth = $true_nullfrac"
fi

# --- check 1: pgcolumnar.analyze() gives the EXACT null_frac -------------------
#
# The zone maps already hold null_count and value_count per chunk, so this is a
# metadata read: 11 ms on the 1237 MB fixture, against 6,302 ms for core ANALYZE.
# Exactness is a by-product of that, not the reason for it -- the reason is the
# 23.5x. But it is the cheapest thing to assert that a sampled implementation
# cannot fake.

psql_run "SELECT pgcolumnar.analyze('af_c'::regclass, ARRAY['k']);" >/dev/null
ours_nullfrac="$(q "SELECT null_frac FROM pg_stats WHERE tablename = 'af_c' AND attname = 'k'")"

check_num "pgcolumnar.analyze() reports null_frac exactly, from the zone maps" \
	"$ours_nullfrac" "0.1"

# --- check 2: n_distinct is exact, from reading one column --------------------
#
# This is the slice the whole issue rests on. null_frac above is metadata only;
# n_distinct requires actually reading the column, and the case for a function is
# that reading ONE column of a wide table is cheap where core's whole-table
# sample is not: 268 ms against 6,302 ms on the 3M x 20 fixture.
#
# Exactness is the observable that a sampled implementation cannot fake, which is
# why it is what gets asserted. Core's own convention is mirrored: an absolute
# count normally, a negated fraction once the distinct count passes 10% of the
# rows (analyze.c does exactly this, on the grounds that such a column's
# cardinality scales with the table rather than sitting at a fixed value).

true_ndistinct="$(q "SELECT count(DISTINCT k) FROM af_c")"
check_num "premise: the fixture has the cardinality this check compares against" \
	"$true_ndistinct" "45001"

# Under 10% of 500,000 rows, so core's rule keeps this a positive absolute count
# rather than a negated fraction. If ROWS is ever lowered past 450,010 this flips
# sign and the check below needs to expect the fraction instead.
check "premise: the fixture stays on the absolute-count side of core's 10% rule" \
	"$(awk -v d="$true_ndistinct" -v n="$ROWS" 'BEGIN { print (d > 0.1 * n) ? "no (fraction side)" : "yes" }')" \
	"yes"

check "premise: core's sampled n_distinct is not exact, so this check can discriminate" \
	"$(awk -v c="$core_ndistinct_before" -v t="$true_ndistinct" \
		'BEGIN { print (c == t) ? "no (sample landed exactly on truth; check is vacuous)" : "yes" }')" \
	"yes"
echo "-- core sampled n_distinct = $core_ndistinct_before, truth = $true_ndistinct"

ours_ndistinct="$(q "SELECT n_distinct FROM pg_stats WHERE tablename = 'af_c' AND attname = 'k'")"
check_num "pgcolumnar.analyze() reports n_distinct exactly, from one column" \
	"$ours_ndistinct" "$true_ndistinct"

# --- check 3: it must not destroy the statistics it does not compute -----------
#
# pg_restore_attribute_stats is a RESTORE api: it reinstates a whole attribute's
# statistics from a dump, so kinds not named in the call could be cleared rather
# than left alone. An accelerator that produces an exact null_frac and n_distinct
# while discarding everything else makes plans worse, not better, and does it
# silently because nothing errors.
#
# This watched n_distinct in slice 1. Slice 2 computes n_distinct, so it now
# watches correlation -- a statistic core collects and we still do not. Keeping it
# pointed at something we write would make it assert nothing.

ours_correlation="$(q "SELECT correlation FROM pg_stats WHERE tablename = 'af_c' AND attname = 'k'")"
echo "-- correlation before=${core_correlation_before:-<none>} after=${ours_correlation:-<none>}"

check "pgcolumnar.analyze() leaves the statistics it does not compute in place" \
	"$(if pgc_is_number "$ours_correlation" && pgc_is_number "$core_correlation_before"; then
			echo yes
		else
			echo "no (correlation was [${core_correlation_before:-<null>}], is now [${ours_correlation:-<null>}])"
		fi)" \
	"yes"

# ---- slice 3: histogram_bounds, whose top end is exact ------------------------
#
# `k` cannot test this. It is uniform over 0..45000, so core's 30,000-row sample
# almost certainly hits both extremes and its bounds are already near-exact. A
# check asserting "ours is exact where core's is not" would pass or fail on the
# luck of the sample, which is three samples rather than three behaviours.
#
# `skew` is built so the extreme is genuinely rare: ONE row in 500,000 holds
# 1,000,000 and every other row is under 100. Core's sample misses it with
# near-certainty; a full read cannot. Four orders of magnitude is not a coin flip.
#
# It is also the case that matters. A range predicate above the sampled maximum
# is exactly where the planner's estimate collapses.

# Two fixture decisions, both forced by what core actually does.
#
# The ordinary values span 100,000 distinct rather than 100. With only 100
# distinct values core stores every one as a most-common-value and emits NO
# histogram at all, so the first version of this check compared against an empty
# array and failed on its own premise rather than on the behaviour.
#
# And core's sample for this column is cut to 10 buckets (about 3,000 rows).
# At the default target it samples 30,000 of 500,000 rows, which finds a
# one-in-500,000 outlier about 6% of the time -- a check that fails one run in
# sixteen for no defect. At 10 it is about 0.6%. That is small and it is not
# zero: any discrimination against a SAMPLE is probabilistic, and pretending
# otherwise would be the flaky-by-construction shape this fixture exists to
# avoid. The premise below states the condition rather than assuming it.
psql_run "ALTER TABLE af_c ALTER COLUMN skew SET STATISTICS 10;" >/dev/null

true_skew_max="$(q "SELECT max(skew) FROM af_c")"
check_num "premise: the outlier really is in the table" "$true_skew_max" "1000000"
check_num "premise: and it really is one row in $ROWS" \
	"$(q "SELECT count(*) FROM af_c WHERE skew = 1000000")" "1"

psql_run "ANALYZE af_c;" >/dev/null
core_hist_max="$(q "SELECT (histogram_bounds::text::int[])[array_length(histogram_bounds::text::int[], 1)]
	FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew'")"
echo "-- core sampled histogram max = ${core_hist_max:-<none>}, truth = $true_skew_max"

# Reported, deliberately NOT asserted.
#
# "Core misses the outlier" cannot be a gate. It is probabilistic by definition,
# and it also depends on how our own access method hands rows to the sampler, so
# a red here would mean "the sample was lucky" and never "the code is wrong".
# Measured both ways while writing this: core's histogram max came back 99,999 on
# one run and 1,000,000 on the next, on identical data. Gating on that would have
# been the flaky-by-construction shape this fixture was built to avoid.
#
# What IS asserted below is exactness, and it does not need core to be wrong: the
# expected value comes from an independent SELECT max(), not from the code path
# under test, so the check fails whenever our bounds are not the true ones.
if pgc_is_number "$core_hist_max" && [ "$core_hist_max" -lt 200000 ]; then
	echo "-- core missed the outlier this run, which is the case that motivates #414"
else
	echo "-- core happened to sample the outlier this run; exactness is asserted regardless"
fi

# Captured, not discarded. While writing this slice the function raised
#
#     ERROR:  record "att" has no field "atttypid"
#
# and the redirect swallowed it, so the call did nothing, pg_stats still held
# core's numbers, and the failure presented as "our maximum is wrong" rather than
# "our function did not run". The assertion caught it, but the diagnosis needed
# the error, so the error is now a check of its own.
skew_out="$(psql_run "SELECT pgcolumnar.analyze('af_c'::regclass, ARRAY['skew']);" 2>&1)"
check_num "pgcolumnar.analyze() ran without raising, so the statistics below are its own" \
	"$(grep -c 'ERROR' <<<"$skew_out")" "0"
ours_hist="$(q "SELECT histogram_bounds::text::int[]
	FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew'")"
ours_hist_max="$(q "SELECT (histogram_bounds::text::int[])[array_length(histogram_bounds::text::int[], 1)]
	FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew'")"
echo "-- ours histogram max = ${ours_hist_max:-<none>}"

check_num "pgcolumnar.analyze() puts the true maximum at the top of histogram_bounds" \
	"${ours_hist_max:-<none>}" "$true_skew_max"

# Both ends, not just the interesting one. A histogram whose top is right and
# whose bottom is invented is still wrong, and percentile_disc returning real
# column values is what makes both exact.
check_num "and the true minimum at the bottom" \
	"$(q "SELECT (histogram_bounds::text::int[])[1]
		FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew'")" \
	"$(q "SELECT min(skew) FROM af_c")"

# percentile_disc returns values the column HOLDS. percentile_cont would
# interpolate and invent ones it does not, which is wrong for a histogram of
# stored data and impossible for a non-numeric type.
check_num "every bound is a value the column actually holds" \
	"$(q "SELECT count(*) FROM unnest((SELECT histogram_bounds::text::int[]
			FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew')) b
		WHERE NOT EXISTS (SELECT 1 FROM af_c WHERE skew = b)")" "0"

# A histogram is an ordered ladder, not a pair of extremes. Asserting only the
# last element would pass for an array of two values, which is not a histogram
# and would ruin every estimate between the ends.
check "and it is an ordered ladder rather than two extremes" \
	"$(if pgc_is_number "$(q "SELECT array_length(histogram_bounds::text::int[], 1)
			FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew'")" &&
		 [ "$(q "SELECT array_length(histogram_bounds::text::int[], 1)
			FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew'")" -ge 5 ]; then
			echo yes
		else
			echo "no (length [$(q "SELECT array_length(histogram_bounds::text::int[], 1) FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew'")])"
		fi)" "yes"

check "and it is sorted ascending, which a histogram must be to be usable" \
	"$(q "SELECT CASE WHEN histogram_bounds::text::int[] =
			(SELECT array_agg(x ORDER BY x) FROM unnest(histogram_bounds::text::int[]) x)
		THEN 'yes' ELSE 'no' END
		FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew'")" "yes"

pgc_summary
