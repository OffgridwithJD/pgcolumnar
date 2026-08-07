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
#
# A version gate, NOT pgc_skip. pgc_skip is for a missing DEPENDENCY, which is an
# environment defect and fails by default so somebody installs the thing. A major
# that does not ship pg_restore_attribute_stats is not a defect to fix: 15 to 17
# genuinely lack it, the same way 15 lacks WITHOUT OVERLAPS. Using pgc_skip here
# turned every PG17 CI run red the moment this suite was registered, which is a
# red nobody can act on.
#
# So it reports SKIP and runs no checks, which pgc_summary turns into exit 2 and
# the matrix records as SKIP rather than as a pass (#447).
#
# The major is asserted first. An unreadable version must not be mistaken for an
# old one, or a broken environment would report SKIP and look supported.
if ! pgc_is_number "${PGC_MAJOR:-}"; then
	echo "FAIL  could not read the server major, so the gate below cannot be trusted: got [${PGC_MAJOR:-<none>}]"
	PGC_CHECKS=$((PGC_CHECKS + 1))
	PGC_FAIL=1
	pgc_summary
fi
if [ "$PGC_MAJOR" -lt 18 ]; then
	echo "SKIP  pgcolumnar.analyze() needs pg_restore_attribute_stats (PG18+); this server is $PGC_MAJOR"
	pgc_summary
fi

# --- fixture ------------------------------------------------------------------
#
# k is NULL for exactly one row in ten. 500,000 rows against core's 30,000-row
# sample is what makes the sampled estimate inexact, which slice 1 depends on.

psql_run "DROP TABLE IF EXISTS af_c;
	CREATE TABLE af_c (k int, skew int, cat int, pad1 text, pad2 text, pad3 text) USING pgcolumnar;
	INSERT INTO af_c SELECT
		CASE WHEN g % 10 = 0 THEN NULL ELSE g % 45001 END,
		CASE WHEN g = 1 THEN 1000000 ELSE g % 100000 END,
		CASE WHEN g % 10 = 0  THEN NULL
			 WHEN g <= 100000 THEN 7
			 WHEN g <= 160000 THEN 42
			 WHEN g <= 190000 THEN 99
			 ELSE 1000 + g END,
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
#
# The bottom is the smallest value that is NOT most-common, which is not the same
# as the column minimum and stopped being the same in slice 3b. `skew` is
# g % 100000, so 0 occurs five times, which makes it a most-common value and
# excludes it from the histogram (analyze.c:2744). This check read
# `SELECT min(skew)` while nothing was ever excluded and began failing with
# got [1] want [0] the moment the exclusion landed -- correctly, because 1 occurs
# four times rather than five and so misses the list that 0 makes.
#
# The expected value is derived from the written MCV list rather than hardcoded,
# so it stays right if the fixture or the bucket count moves.
check_num "and the smallest non-most-common value at the bottom" \
	"$(q "SELECT (histogram_bounds::text::int[])[1]
		FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew'")" \
	"$(q "WITH m AS (SELECT most_common_vals::text::int[] AS v FROM pg_stats
			WHERE tablename = 'af_c' AND attname = 'skew')
		SELECT min(a.skew) FROM af_c a, m WHERE a.skew <> ALL (m.v)")"

# The exclusion holds for skew too, not only for the column built to show it.
check_num "and no most-common value is inside skew's histogram either" \
	"$(q "SELECT count(*) FROM pg_stats s, unnest(s.histogram_bounds::text::int[]) b
		WHERE s.tablename = 'af_c' AND s.attname = 'skew'
		  AND b = ANY (s.most_common_vals::text::int[])")" "0"

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

# ---- slice 3b: most_common_vals and most_common_freqs ------------------------
#
# The selection rule is core's, and it is not the sampled one. analyze_mcv_list()
# opens by refusing to filter at all when the whole table was read:
#
#     /*
#      * If the entire table was sampled, keep the whole list.  This also
#      * protects us against division by zero in the code below.
#      */
#     if (samplerows == totalrows || totalrows <= 1.0)
#         return num_mcv;                             -- analyze.c:2995
#
# The machinery that guard skips -- a continuity-corrected Wald interval over a
# hypergeometric variance -- exists to decide whether a SAMPLE frequency is
# trustworthy enough to store. We read the entire column, so that question does
# not arise and core's own answer is "keep them". What is left is mechanical:
#
#   only values with count > 1 are eligible          analyze.c:2549
#   top default_statistics_target by count            analyze.c:2552-2564
#   frequency is count / total rows INCLUDING nulls   analyze.c:2720
#
# `cat` is built so that the third of those is observable, because it is the one
# that fails silently. Three values repeat and nothing else does:
#
#   NULL   50,000   one row in ten
#   7      90,000   freq 0.18   -- 0.2   if divided by the non-null count
#   42     54,000   freq 0.108  -- 0.12  if divided by the non-null count
#   99     27,000   freq 0.054  -- 0.06  if divided by the non-null count
#   tail  279,000 distinct values, each appearing exactly once
#
# Dividing by the 450,000 non-null rows rather than the 500,000 total inflates
# every frequency by 1/(1-null_frac) and produces 0.2/0.12/0.06: three numbers
# that are individually plausible, sum to less than one, and are wrong. No error
# is raised on that path, so the fixture has to be the thing that catches it.
# That is why the null fraction is not zero here.
#
# Exactly three values repeat, so the list is fully determined rather than a
# top-N cut of a longer one, and the check can name it outright.

cat_total="$(q "SELECT count(*) FROM af_c")"
check_num "premise: the MCV fixture has the row count the frequencies divide by" \
	"$cat_total" "$ROWS"

check_num "premise: value 7 appears exactly 90,000 times" \
	"$(q "SELECT count(*) FROM af_c WHERE cat = 7")" "90000"
check_num "premise: value 42 appears exactly 54,000 times" \
	"$(q "SELECT count(*) FROM af_c WHERE cat = 42")" "54000"
check_num "premise: value 99 appears exactly 27,000 times" \
	"$(q "SELECT count(*) FROM af_c WHERE cat = 99")" "27000"

# The rule at analyze.c:2549 is "count > 1", so this premise is what makes the
# expected list exactly three long. If the tail ever stopped being unique, the
# list would fill to default_statistics_target with tied values and the check
# below would fail for a reason that is not a defect.
check_num "premise: and nothing else in the column repeats, so the list is exactly three" \
	"$(q "SELECT count(*) FROM (SELECT cat FROM af_c WHERE cat IS NOT NULL
		GROUP BY cat HAVING count(*) > 1) t")" "3"

# Core's sampled frequencies, captured before our call overwrites them.
psql_run "ANALYZE af_c;" >/dev/null
core_mcv_before="$(q "SELECT most_common_vals::text FROM pg_stats
	WHERE tablename = 'af_c' AND attname = 'cat'")"
core_freq_7="$(q "SELECT (most_common_freqs)[array_position(most_common_vals::text::int[], 7)]
	FROM pg_stats WHERE tablename = 'af_c' AND attname = 'cat'")"
echo "-- core sampled MCVs = ${core_mcv_before:-<none>}, its freq for 7 = ${core_freq_7:-<none>}"

# Reported, not gated. Core's sample finding 7 at exactly 0.18 is unlikely but it
# is a sample, and a check that depends on core being unlucky is the shape slice 3
# already had to retract. Exactness below is asserted against independent counts,
# so it does not need core to be wrong.
if pgc_is_number "$core_freq_7" && [ "$core_freq_7" != "0.18" ]; then
	echo "-- core's sampled frequency is inexact, which is the gap this slice closes"
fi

# The statistics are CLEARED before our call, and this is not tidiness.
#
# Written without it, every check below read core's leftover MCV list and none of
# them could tell "our function wrote this" from "core wrote it and our function
# left it alone". Two passed that way on the first run: most_common_vals matched
# because core had already put {7,42,99} there, and 99's frequency matched because
# core's sample happened to round to 0.054 at six places. A function that writes
# no MCVs at all scored three of four.
#
# Clearing first makes attribution structural rather than lucky: after this call
# the column has no MCV list, so anything the checks below find is ours.
psql_run "SELECT pg_catalog.pg_clear_attribute_stats('public', 'af_c', 'cat', false);" >/dev/null
# A scalar subquery, because clearing removes the whole pg_statistic row rather
# than nulling a column: read as `SELECT ... FROM pg_stats WHERE ...` this returns
# NO ROWS, q() yields the empty string, and coalesce never runs. The premise then
# fails for its own reason rather than reporting the state it was asked about.
check "premise: the MCV list really is gone before we write, so what follows is ours" \
	"$(q "SELECT coalesce((SELECT most_common_vals::text FROM pg_stats
		WHERE tablename = 'af_c' AND attname = 'cat'), '<cleared>')")" \
	"<cleared>"

mcv_out="$(psql_run "SELECT pgcolumnar.analyze('af_c'::regclass, ARRAY['cat']);" 2>&1)"
check_num "pgcolumnar.analyze() ran without raising for the MCV column" \
	"$(grep -c 'ERROR' <<<"$mcv_out")" "0"

# A WARNING here is the silent-wrong-write this slice was told to guard against.
# pg_restore_attribute_stats takes VARIADIC "any": most_common_vals must be text
# and most_common_freqs must be real[] (attribute_stats.c:70-71). A float8[] is
# not an error, it is a WARNING and a dropped argument, and the call then reports
# success having stored nothing.
check_num "and without a WARNING, which is how a mistyped argument is dropped" \
	"$(grep -c 'WARNING' <<<"$mcv_out")" "0"

check "pgcolumnar.analyze() writes the three repeated values as most_common_vals" \
	"$(q "SELECT most_common_vals::text FROM pg_stats
		WHERE tablename = 'af_c' AND attname = 'cat'")" \
	"{7,42,99}"

# Each frequency against its own independently counted truth, not against a
# recomputation of what the function did.
check_num "and 7's frequency exactly, over total rows rather than non-null rows" \
	"$(q "SELECT round((most_common_freqs)[1]::numeric, 6) FROM pg_stats
		WHERE tablename = 'af_c' AND attname = 'cat'")" \
	"$(q "SELECT round(90000::numeric / $ROWS, 6)")"

check_num "and 42's" \
	"$(q "SELECT round((most_common_freqs)[2]::numeric, 6) FROM pg_stats
		WHERE tablename = 'af_c' AND attname = 'cat'")" \
	"$(q "SELECT round(54000::numeric / $ROWS, 6)")"

check_num "and 99's" \
	"$(q "SELECT round((most_common_freqs)[3]::numeric, 6) FROM pg_stats
		WHERE tablename = 'af_c' AND attname = 'cat'")" \
	"$(q "SELECT round(27000::numeric / $ROWS, 6)")"

# ---- the exclusion, which is why 3b could not be a line added to slice 3 ------
#
# Core builds the histogram from the values left AFTER the most-common ones are
# removed (analyze.c:2744 num_hist = ndistinct - num_mcv, and the collapse loop at
# :2768-2799). Writing both lists without that exclusion counts those values
# twice in selectivity: eqsel finds the value in the MCV list and takes its
# frequency, and the range estimators count it again inside whichever bucket
# holds it. Nothing errors; the estimates are just wrong, and wrong in the
# direction that says a heavily-repeated value is more common than it is.
#
# This is the check that has to fail before the exclusion exists. `cat`'s three
# most-common values are 7, 42 and 99 -- the three SMALLEST values in the column,
# so an unexcluded histogram puts 7 at the bottom bound and the check below finds
# it immediately.

# Asserted first, because the exclusion check is vacuously true when there is no
# histogram at all. "No MCV appears in histogram_bounds" passes trivially against
# NULL, so a change that silently stopped emitting histograms would read as a fix.
check "premise: a histogram exists for cat, so the exclusion below is not vacuous" \
	"$(q "SELECT CASE WHEN coalesce(array_length(histogram_bounds::text::int[], 1), 0) >= 2
			THEN 'yes' ELSE 'no' END
		FROM pg_stats WHERE tablename = 'af_c' AND attname = 'cat'")" "yes"

check_num "no most-common value appears in histogram_bounds, which would double-count it" \
	"$(q "SELECT count(*) FROM pg_stats s, unnest(s.histogram_bounds::text::int[]) b
		WHERE s.tablename = 'af_c' AND s.attname = 'cat'
		  AND b = ANY (s.most_common_vals::text::int[])")" "0"

# The same fact from the other side, and the one that shows the histogram is over
# the remaining population rather than merely filtered at the ends: the lowest
# bound must be the smallest value that is NOT most-common, not the column's
# minimum. Truth comes from an independent query, not from the function.
check_num "so the bottom bound is the smallest non-most-common value, not the column minimum" \
	"$(q "SELECT (histogram_bounds::text::int[])[1] FROM pg_stats
		WHERE tablename = 'af_c' AND attname = 'cat'")" \
	"$(q "SELECT min(cat) FROM af_c WHERE cat NOT IN (7, 42, 99)")"

# ---- the per-column statistics target, which core reads and we did not --------
#
# Core sizes both lists from the COLUMN's attstattarget, not from the global
# default_statistics_target:
#
#     attstattarget = isnull ? -1 : DatumGetInt16(dat);   -- analyze.c:1065
#     if (attstattarget == 0) return NULL;                -- :1070, skip entirely
#     if (stats->attstattarget < 0)                       -- :1897
#         stats->attstattarget = default_statistics_target;
#
# So NULL means "use the default", a positive value overrides it, and zero means
# do not collect statistics for this column at all. This function read the global
# setting for every column, which silently ignored ALTER TABLE ... SET STATISTICS.
# This suite has been setting it on `skew` since slice 3 while asserting nothing
# about it, so the divergence was already present here and invisible.
#
# skew is at SET STATISTICS 10, set above for core's benefit. Ten buckets means
# eleven bounds: percentile_disc is asked for target+1 fractions, which is the
# shape core caps at num_bins+1 (analyze.c:2746).

check_num "premise: skew really is at a non-default statistics target" \
	"$(q "SELECT attstattarget FROM pg_attribute
		WHERE attrelid = 'af_c'::regclass AND attname = 'skew'")" "10"

check_num "premise: and the global default differs from it, so the two are distinguishable" \
	"$(q "SHOW default_statistics_target")" "100"

# Cleared and re-run, which this check needs and did not originally have. The MCV
# section above calls plain ANALYZE to capture core's sampled list for `cat`, and
# that analyses EVERY column of af_c, skew included. Reading skew's histogram
# after it therefore reads CORE's -- and core honours attstattarget, so the check
# passed at eleven bounds while the function under test was still producing a
# hundred and one. Measured directly on an isolated table to find it.
psql_run "SELECT pg_catalog.pg_clear_attribute_stats('public', 'af_c', 'skew', false);" >/dev/null
psql_run "SELECT pgcolumnar.analyze('af_c'::regclass, ARRAY['skew']);" >/dev/null

check_num "the histogram honours the column's statistics target, not the global default" \
	"$(q "SELECT array_length(histogram_bounds::text::int[], 1) FROM pg_stats
		WHERE tablename = 'af_c' AND attname = 'skew'")" "11"

# The most-common list is sized by the same target, and by the same rule
# (analyze.c:2552 tracks at most attstattarget entries).
check "and so does the most-common list, which is capped by the same target" \
	"$(if [ "$(q "SELECT array_length(most_common_vals::text::int[], 1) FROM pg_stats
			WHERE tablename = 'af_c' AND attname = 'skew'")" -le 10 ] 2>/dev/null; then echo yes
		else echo "no (length [$(q "SELECT array_length(most_common_vals::text::int[], 1) FROM pg_stats WHERE tablename = 'af_c' AND attname = 'skew'")])"; fi)" \
	"yes"

# Zero is not "a small target", it is "do not collect". A column set to zero that
# comes back with statistics has had the DBA's instruction overridden, and the
# planner is then using numbers somebody deliberately turned off.
psql_run "ALTER TABLE af_c ALTER COLUMN pad1 SET STATISTICS 0;" >/dev/null
psql_run "SELECT pg_catalog.pg_clear_attribute_stats('public', 'af_c', 'pad1', false);" >/dev/null

pad_out="$(psql_run "SELECT pgcolumnar.analyze('af_c'::regclass, ARRAY['pad1']);" 2>&1)"
check_num "pgcolumnar.analyze() ran for the zero-target column without raising" \
	"$(grep -c 'ERROR' <<<"$pad_out")" "0"

check "a column at SET STATISTICS 0 is left alone, because that is what zero means" \
	"$(q "SELECT coalesce((SELECT 'wrote-' || attname FROM pg_stats
		WHERE tablename = 'af_c' AND attname = 'pad1'), '<nothing>')")" \
	"<nothing>"

pgc_summary
