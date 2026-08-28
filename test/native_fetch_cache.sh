#!/usr/bin/env bash
#
# pgColumnar fetch-by-row-number cache (issue #143).
#
# PgColumnarReadRowByNumber() used to read and decode a whole row group per row
# returned, so fetching N rows out of one group cost N times the group. A
# statement-scoped cache of the decoded group removes the repeat.
#
# Two things are asserted, because they need different kinds of evidence.
#
# 1. The cache is used. Timed as a ratio rather than a threshold: the same number
#    of index-driven fetches is run against the same rows laid out as one big row
#    group and as many small ones. Without the cache the per-fetch cost is
#    proportional to the group size, so the single-group case is many times
#    slower; with it, both are dominated by the fetches themselves and the ratio
#    collapses. A ratio is portable where a millisecond count is not.
#
# 2. The scoping that makes the cache correct is present. This part is a source
#    assertion, in the style of wal_envelope.sh and decode_interrupts.sh, and the
#    reason is worth recording: removing the command-id rejection on its own does
#    not fail any suite, because four other things independently prevent a stale
#    hit (the storage id is in the key, compaction retires group numbers rather
#    than rewriting them under the same number, the geometry check rejects a
#    mismatched entry, and the executor-end hook releases the cache between
#    statements). A behavioural test for that one guard would have to defeat the
#    other four, which is not a shape the suite should carry. Asserting the guards
#    exist is the honest cover for them.
#
# Usage:  test/native_fetch_cache.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=${PGC_FETCH_ROWS:-20000}
UPD=$((ROWS / 10))

# --- 1. the cache is used -----------------------------------------------------

build() {  # table, rows-per-group
	psql_run "DROP TABLE IF EXISTS $1;
		SET pgcolumnar.stripe_row_limit = $2;
		SET pgcolumnar.chunk_group_row_limit = $2;
		CREATE TABLE $1 (id int, v int, t text) USING pgcolumnar;
		INSERT INTO $1 SELECT g, g, 'row' || g FROM generate_series(1, $ROWS) g;
		CREATE INDEX ${1}_id ON $1 (id);"
}

# index-driven so every row goes through the fetch path rather than a scan
upd_ms() {
	local start end
	start=$(date +%s%N)
	psql_run "SET max_parallel_workers_per_gather = 0;
		SET enable_seqscan = off;
		SET enable_bitmapscan = off;
		UPDATE $1 SET v = id + 1 WHERE id <= $UPD;" >/dev/null 2>&1
	end=$(date +%s%N)
	echo $(( (end - start) / 1000000 ))
}

# Best of three readings, not one and not the average.
#
# Scheduling noise on a shared runner only ever ADDS latency, so the minimum is
# the reading least polluted by it, and a single descheduled run cannot widen the
# ratio on its own. test/cancel_decode.sh makes this argument for its own ratio
# and runs in CI on the strength of it; these three had the same-run half and not
# this half, which is why they were guarded instead (#792).
#
# Measured before the change, six busy cores on an eight-core box: the one/many
# ratio reached 2.39 against its bound of 3 on a single reading, where the best of
# three across the same runs was 0.89 -- which is where the idle readings sit.
#
# A REPEATED MEASUREMENT MUST BE IDEMPOTENT. upd_ms updated with "v = v + 1",
# which is fine once and wrong three times: the suite's own correctness arms below
# assert v = id + 1, and they caught it. It sets "v = id + 1" now, which is the
# same work per row and true after any number of runs.
# The three cost assertions below go through check_ratio rather than computing
# the comparison here and passing yes/no to check. They were hand-rolled while
# they used check_timing, which takes a scalar; now that they are ordinary checks
# (#792) the ratio helper is available and is strictly better:
#
#   * it refuses a zero on EITHER side -- "a side of the ratio is zero, so
#     nothing was measured". The hand-rolled form guarded only the denominator,
#     so a numerator timing at 0 ms, which means the measurement fell below timer
#     resolution, passed silently as a ratio of 0;
#   * it compares as a float instead of truncating integer division, and prints
#     the ratio with both sides in the verdict rather than a hand-built string.
#
# The bound moves by a hair and it is worth saying so: the old form failed at a
# ratio of exactly 3.0 (integer division, "< 3"), check_ratio fails above it
# ("<= 3"). Nothing observed here is near that boundary.

min3() {  # min3 FUNC ARG...
	local a b c
	a="$("$@")"; b="$("$@")"; c="$("$@")"
	printf '%s\n' "$a" "$b" "$c" | sort -n | head -1
}

build fc_one "$ROWS"          # every row in a single row group
build fc_many $((ROWS / 10))  # the same rows across ten

one="$(min3 upd_ms fc_one)"
many="$(min3 upd_ms fc_many)"
echo "-- $UPD fetches: one group of $ROWS took ${one} ms; ten groups took ${many} ms"

# Without the cache the single-group case decodes ten times as much per fetch and
# lands near 10x. With it, both are dominated by the fetches and sit near 1x.
check_ratio "fetching from one big group is not far dearer than from ten small ones" \
	"$one" "$many" "3"

# and the rows are still right
check "the updated rows are correct" \
	"$(q "SELECT count(*) FROM fc_one WHERE v = id + 1;")" "$UPD"
check "the untouched rows are unchanged" \
	"$(q "SELECT count(*) FROM fc_one WHERE v = id;")" "$((ROWS - UPD))"

# --- 2. the scoping guards are present ----------------------------------------

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"

check "the entry key includes the storage id" \
	"$(grep -c 'e->storageId == storageId && e->groupNumber == groupNumber' "$SRC/columnar_reader.c")" "1"

check "an entry from an earlier command is rejected" \
	"$(grep -c 'e->cid != cid' "$SRC/columnar_reader.c")" "1"

check "a hit re-checks the group geometry it was filled with" \
	"$(grep -cE 'entry->fileOffset != rg->fileOffset' "$SRC/columnar_reader.c")" "1"

check "the cache is released at executor end, not only at transaction end" \
	"$(grep -c 'PgColumnarDiscardFetchCache' "$SRC/columnar_tableam.c")" "2"

# --- #353: a wide group's decode scratch must not blow the fetch cap ----------
# The by-row-number decode allocated its intermediates -- the decompressed region
# and each vector's decoded buffer -- in the cached entry, ~3x the result. A wide
# group's projected prefix then exceeded the 32MB cap and was re-decoded on every
# fetch (measured ~200x). The scratch now lives in a transient context, so the
# entry keeps only the result. Test: a wide table at the default stripe (one big
# group, large decoded prefix) vs a small-stripe control; the wide case must not
# be far dearer per fetch, and must return the same answer.
wbuild() {  # table, stripe
	psql_run "DROP TABLE IF EXISTS $1;
		CREATE TABLE $1 (id int, h text, c1 int,c2 int,c3 int,c4 int,c5 int,c6 int,
		                 c7 int,c8 int,c9 int,c10 int, u float8,
		                 t1 text,t2 text,t3 text,t4 text,t5 text,t6 text,t7 text,t8 text)
		    USING pgcolumnar;
		SELECT pgcolumnar.set_options('$1', stripe_row_limit => $2);
		INSERT INTO $1 SELECT g, 'h' || (g % 500), g,g,g,g,g,g,g,g,g,g, (g % 100)::float8,
		    repeat('x',40),repeat('y',40),repeat('z',40),'a'||g,'b'||g,'c'||g,'d'||g,'e'||g
		    FROM generate_series(1, 300000) g;
		CREATE INDEX ${1}_h ON $1 (h);"
}
w_ms() {  # index-driven point query over one host: many fetches into few groups
	local start end
	start=$(date +%s%N)
	psql_run "SET max_parallel_workers_per_gather=0; SET enable_seqscan=off; SET enable_bitmapscan=off;
		SELECT count(*), max(u) FROM $1 WHERE h='h1';" >/dev/null 2>&1
	end=$(date +%s%N); echo $(( (end - start) / 1000000 ))
}
wbuild fc_wide 150000      # default stripe: one/two big groups, wide decoded prefix
wbuild fc_wnarrow 20000    # smaller groups that fit under the cap regardless
bigw="$(min3 w_ms fc_wide)"; smallw="$(min3 w_ms fc_wnarrow)"
echo "-- #353 wide point query: default-stripe ${bigw} ms, small-stripe ${smallw} ms"
check_ratio "a wide group's fetch is not far dearer than a small group's (#353)" \
	"$bigw" "$smallw" "5"
check "the wide-group point query is correct (#353)" \
	"$(q "SELECT count(*) || '|' || coalesce(max(u)::text,'z') FROM fc_wide WHERE h='h1'")" \
	"$(q "SELECT count(*) || '|' || coalesce(max(u)::text,'z') FROM fc_wnarrow WHERE h='h1'")"

# --- #359: crossing the cap must cost proportionally, not totally -------------
# The #353 case above measures a two-column projection across two group sizes. It
# therefore never crosses the relocated cap, and went green on exactly the query
# family that still cliffed. The axis it holds constant is the one that mattered:
# projection width at a fixed group size. This varies that instead.
#
# Each text column below decodes to ~154 bytes x 50,000 rows = ~7.7 MB, so the
# 32 MB cap falls between four and five projected columns. Going over it used to
# drop the entry whole, so the fifth column cost a re-read of the group and a
# re-decode of all five, on every fetch. The cache now keeps the columns that fit
# and re-decodes only the remainder.
#
# Measured here, PG18 assert, going from four to five columns. Both figures are
# from this suite rather than from a standalone probe, because the ~600 MB of
# fixtures built above leave the box in a different state than a cold one, and the
# ratio moves with it -- the same fixed build measures 2.2x standalone and 5.8x
# here. Comparing a suite number against a standalone number would be comparing
# two machines:
#   before   77 ms -> 1902 ms   (24.7x, flat either side -- the cliff)
#   after    64 ms ->  368 ms   (5.8x -- a ramp)
# Four runs of the fixed build in this suite gave 5.6x, 5.6x, 5.9x and 6.4x. The
# bound is 12x, roughly a factor of two clear of either build, so it discriminates
# the shape rather than encoding one box's timings.
psql_run "DROP TABLE IF EXISTS fc_w359;
	CREATE TABLE fc_w359 (id int, h text,
	    t1 text,t2 text,t3 text,t4 text,t5 text) USING pgcolumnar;
	SELECT pgcolumnar.set_options('fc_w359', stripe_row_limit => 50000);
	INSERT INTO fc_w359 SELECT g, 'h' || (g % 1000),
	    repeat('a',150),repeat('b',150),repeat('c',150),
	    repeat('d',150),repeat('e',150)
	FROM generate_series(1,100000) g;
	CREATE INDEX fc_w359_h ON fc_w359 (h);"

w359_ms() {  # number of projected text columns
	local n=$1 sel="count(*)" i start end
	for i in $(seq 1 "$n"); do sel="$sel, max(t$i)"; done
	# warm, so the comparison is decode cost rather than first-touch I/O
	psql_run "SET max_parallel_workers_per_gather=0; SET enable_seqscan=off;
		SET enable_bitmapscan=off;
		SELECT $sel FROM fc_w359 WHERE h='h7';" >/dev/null 2>&1
	start=$(date +%s%N)
	psql_run "SET max_parallel_workers_per_gather=0; SET enable_seqscan=off;
		SET enable_bitmapscan=off;
		SELECT $sel FROM fc_w359 WHERE h='h7';" >/dev/null 2>&1
	end=$(date +%s%N); echo $(( (end - start) / 1000000 ))
}

under="$(min3 w359_ms 4)"   # ~30 MB decoded: fits
over="$(min3 w359_ms 5)"    # ~38 MB decoded: does not
echo "-- #359 projection width: four columns ${under} ms, five columns ${over} ms"
check_ratio "crossing the fetch cache cap costs proportionally, not totally (#359)" \
	"$over" "$under" "12"

# The columns that overflow are re-decoded rather than skipped, so they must still
# read correctly -- a cache that quietly returned nulls for them would be fast and
# wrong, and the timing check alone would not notice.
check "the over-cap projection returns the same values as the under-cap one (#359)" \
	"$(q "SELECT max(t1) || '|' || max(t4) FROM fc_w359 WHERE h='h7'")" \
	"$(q "SELECT max(t1) || '|' || max(t4) FROM fc_w359 WHERE h='h7' AND t5 IS NOT NULL")"
check "every over-cap column reads back its written value (#359)" \
	"$(q "SELECT count(*) FROM fc_w359 WHERE h='h7'
	      AND t1 = repeat('a',150) AND t2 = repeat('b',150) AND t3 = repeat('c',150)
	      AND t4 = repeat('d',150) AND t5 = repeat('e',150)")" \
	"$(q "SELECT count(*) FROM fc_w359 WHERE h='h7'")"

pgc_summary
