#!/usr/bin/env bash
#
# pgColumnar #1296: the time-series recipes in docs/how-to.md answer what they
# claim, on a columnar table. Gap filling, last observation carried forward
# (LOCF) and linear interpolation need no feature: core SQL expresses them, and
# phase 0 on #1296 measured the gap fill at 0.69 s on 8.75M columnar rows with
# the vectorized grouped node still under the LEFT JOIN. So the deliverable is
# the recipe, and this suite holds the recipe to a reference.
#
# THE RECIPES ARE READ FROM THE DOCUMENT, not copied here: each is the first
# ```sql block after its heading in docs/how-to.md, run as written against a
# table named as the document names it. A recipe edited in the docs is the
# recipe tested; one deleted from the docs fails its premise.
#
# THE REFERENCE IS COMPUTED ANOTHER WAY: a plpgsql loop over the 24 hours that
# reads the raw rows of each hour and walks back and forward for neighbours. It
# shares no window function and no LEFT JOIN with the recipes.
#
# The fixture's 24 hours are built to hold every case a recipe can get wrong:
#   hour 0          empty, first          nothing to carry; nothing to interpolate from
#   hours 1, 2      data
#   hours 3..5      empty, a run          carried from 2; interpolated 2 -> 6
#   hour 6          data with some NULLs  avg ignores the NULLs
#   hour 7          rows, all v NULL      a bucket with rows but no value: missing
#   hours 8..21     data
#   hour 22, 23     empty, last           carried from 21; nothing to interpolate to
#
# Usage:  test/timeseries_recipes.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

DOC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs/how-to.md"
# These three are arms, not premises: they read the document, so editing it
# reddens them (#1236; OffgridwithJD's review of #1311).
# recipe <heading text>: the first ```sql block after that heading, its ';' removed.
recipe() {
	awk -v h="$1" '$0 == h {f=1; next} f && /^```sql/ {g=1; next} g && /^```/ {exit} g {print}' "$DOC" 2>/dev/null |
		sed -e 's/;[[:space:]]*$//'
}
FILL="$(recipe '### Fill empty buckets')"
LOCF="$(recipe '### Carry the last value forward')"
INTERP="$(recipe '### Interpolate between known values')"
check "the how-to gives the gap-fill recipe" "$(printf '%s' "$FILL" | grep -c 'generate_series')" "1"
check "the how-to gives the LOCF recipe" "$(printf '%s' "$LOCF" | grep -c 'readings')" "1"
check "the how-to gives the interpolation recipe" "$(printf '%s' "$INTERP" | grep -c 'readings')" "1"

# The table the document names. Values grow as the square of the hour, so a
# straight line through the wrong neighbours lands on the wrong value; they are
# multiples of 1/4, so every average and interpolation below is exact in float8.
psql_run "CREATE TABLE readings (ts timestamptz, v float8) USING pgcolumnar;"
psql_run "SET TimeZone = 'UTC';
	INSERT INTO readings
	SELECT timestamptz '2026-10-01 00:00+00' + h * interval '1 hour' + m * interval '1 minute',
	       CASE WHEN h = 7 THEN NULL
	            WHEN h = 6 AND m % 3 = 0 THEN NULL
	            ELSE (h * h * 4 + m % 4) / 4.0 END
	  FROM generate_series(0, 23) h, generate_series(0, 59, 5) m
	 WHERE h NOT IN (0, 3, 4, 5, 22, 23);"
check "premise: the readings table is columnar" \
	"$(q "SELECT a.amname FROM pg_class c JOIN pg_am a ON a.oid = c.relam WHERE c.oid = 'readings'::regclass;")" "pgcolumnar"

# The reference: bucket | value | carried | interpolated, one line per hour.
psql_run "CREATE FUNCTION ref_series() RETURNS TABLE (bucket timestamptz, val float8, locf float8, interp float8)
LANGUAGE plpgsql AS \$\$
DECLARE
	t0 timestamptz := timestamptz '2026-10-01 00:00+00';
	vals float8[] := array_fill(NULL::float8, ARRAY[24]);
	i int; j int; p int; n int; a float8;
BEGIN
	FOR i IN 0..23 LOOP
		SELECT avg(r.v) INTO a FROM readings r
		 WHERE r.ts >= t0 + i * interval '1 hour' AND r.ts < t0 + (i + 1) * interval '1 hour';
		vals[i + 1] := a;
	END LOOP;
	FOR i IN 0..23 LOOP
		bucket := t0 + i * interval '1 hour';
		val := vals[i + 1];
		p := NULL; n := NULL;
		FOR j IN REVERSE i..0 LOOP IF vals[j + 1] IS NOT NULL THEN p := j; EXIT; END IF; END LOOP;
		FOR j IN i..23 LOOP IF vals[j + 1] IS NOT NULL THEN n := j; EXIT; END IF; END LOOP;
		locf := CASE WHEN p IS NULL THEN NULL ELSE vals[p + 1] END;
		interp := CASE WHEN val IS NOT NULL THEN val
		               WHEN p IS NULL OR n IS NULL THEN NULL
		               ELSE vals[p + 1] + (vals[n + 1] - vals[p + 1]) * (i - p)::float8 / (n - p) END;
		RETURN NEXT;
	END LOOP;
END \$\$;"

# Rows as text, rounded to 9 places, NULL spelled out, so a mismatch prints.
asrows() { q "SELECT string_agg(to_char(bucket AT TIME ZONE 'UTC', 'HH24') || '=' || COALESCE(round(x::numeric, 9)::text, 'NULL'), ' ' ORDER BY bucket) FROM ($1) s(bucket, x);"; }

check "premise: the reference has 24 hours, 6 of them empty and one all-NULL" \
	"$(q "SELECT count(*) || '/' || count(*) FILTER (WHERE val IS NULL) FROM ref_series();")" "24/7"

check "the gap-fill recipe returns every bucket, empty ones as NULL" \
	"$(asrows "SELECT * FROM ($FILL) r")" "$(asrows "SELECT bucket, val FROM ref_series()")"
check "the LOCF recipe carries the last value forward, and leaves a leading gap NULL" \
	"$(asrows "SELECT bucket, avg_v_locf FROM ($LOCF) r")" "$(asrows "SELECT bucket, locf FROM ref_series()")"
check "the interpolation recipe fills a gap linearly, and leaves both ends NULL" \
	"$(asrows "SELECT bucket, avg_v_interp FROM ($INTERP) r")" "$(asrows "SELECT bucket, interp FROM ref_series()")"

# date_trunc truncates in the session's zone, so in a zone with a half-hour
# offset its buckets start at :30 UTC and match no bucket of the series. The
# recipe uses date_bin with the series start as origin, which has no zone in it.
check "the gap-fill recipe gives the same buckets in a session at a half-hour offset" \
	"$(PGTZ=Asia/Kolkata asrows "SELECT * FROM ($FILL) r")" "$(asrows "SELECT bucket, val FROM ref_series()")"

# On a columnar table the recipes are not just correct but take the fast path:
# the aggregate under the LEFT JOIN runs as the vectorized grouped node.
check "the gap-fill recipe's aggregate runs as the vectorized grouped node when it is on" \
	"$(q "SET pgcolumnar.enable_group_vectorization = on; EXPLAIN (COSTS OFF) $FILL" | grep -c 'Columnar Vectorized Group Keys')" "1"

pgc_summary
