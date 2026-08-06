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
# Slice 1 asserts one thing: null_frac comes from the zone maps and is EXACT,
# where core's is sampled and is not.
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
	CREATE TABLE af_c (k int, pad1 text, pad2 text, pad3 text) USING pgcolumnar;
	INSERT INTO af_c SELECT
		CASE WHEN g % 10 = 0 THEN NULL ELSE g % 45001 END,
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

# --- check 2: it must not destroy the statistics it does not compute -----------
#
# pg_restore_attribute_stats is a RESTORE api: it is designed to reinstate a whole
# attribute's statistics from a dump, so kinds not named in the call may be
# cleared rather than left alone. That matters here, because this slice collects
# null_frac and nothing else. An accelerator that yields an exact null_frac while
# discarding n_distinct and the MCV list makes plans worse, not better -- and it
# would do so silently, since nothing errors.
#
# So: n_distinct must survive the call. If this fails, the minimal implementation
# is a regression and slice 1 is not done, whatever the check above says.

core_ndistinct="$(q "SELECT n_distinct FROM pg_stats WHERE tablename = 'af_c' AND attname = 'k'")"
echo "-- n_distinct after our call = ${core_ndistinct:-<none>}"

check "pgcolumnar.analyze() leaves the statistics it does not compute in place" \
	"$(if pgc_is_number "$core_ndistinct" \
		&& [ "$(awk -v v="$core_ndistinct" 'BEGIN { print (v + 0 == 0) ? "zero" : "nonzero" }')" = nonzero ]; then
			echo yes
		else
			echo "no (n_distinct is now [${core_ndistinct:-<null>}])"
		fi)" \
	"yes"

pgc_summary
