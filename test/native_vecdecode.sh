#!/usr/bin/env bash
#
# pgColumnar: decode honours the skip vector (#452 phase 1b-i).
#
# "Columnar Vectors Skipped" has never meant what its name suggests. Decode runs
# BEFORE the skip vector exists -- pgcolumnar_native_decode_chunk at
# columnar_reader.c:1598, pgcolumnar_native_build_skipvec at :1615 -- so a vector
# the zone maps ruled out is decoded in full and the skip only stops it being
# turned into Datums. The counter says "not emitted", never "not decoded", and no
# existing counter can tell those apart.
#
# So this suite needs its own observable, "Columnar Vectors Decoded", and the
# central check is not that it moves but that it moves by EXACTLY the skipped
# count. "Decodes fewer" would pass on decoding one vector less out of thirty,
# which is the shape of a fix that does not work.
#
# Usage:  test/native_vecdecode.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# One row group of 32 vectors x 1024 rows. The stripe limit is above the row
# count so nothing is pruned at the row-group level and every difference below
# is per-vector. id is monotonic, so each vector's zone map is tight and
# non-overlapping, which is what lets a narrow range rule most of them out.
ROWS=32768
GEN="SELECT g AS id, (g % 97) AS v FROM generate_series(1, $ROWS) g"

psql_run "CREATE TABLE h (id int, v int);"
psql_run "CREATE TABLE n (id int, v int) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('n', stripe_row_limit => 65536, chunk_group_row_limit => 1024);"
psql_run "INSERT INTO h $GEN;"
psql_run "INSERT INTO n $GEN;"

explain_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) $1" 2>/dev/null
}

# A counter's value, or empty when the line is absent. Read from the plan text
# rather than from a second EXPLAIN, so every counter in one check comes from
# one run of one query.
counter_in() {  # counter_in <plan text> <label>
	grep -F "$2" <<<"$1" | grep -oE '[0-9]+' | head -1
}

has_line() { grep -qF "$2" <<<"$1" && echo yes || echo no; }

# The narrow range lives inside a single vector; the wide one spans them all.
NARROW="SELECT id, v FROM n WHERE id BETWEEN 2000 AND 2050"
WIDE="SELECT id, v FROM n WHERE id BETWEEN 1 AND $ROWS"

PLAN_NARROW="$(explain_of "$NARROW")"
PLAN_WIDE="$(explain_of "$WIDE")"

# ---- premises -------------------------------------------------------------
#
# Every number below is read out of these two plans. If the planner stops
# choosing the columnar custom scan, or the group splits, the comparisons start
# reporting a decode regression that is really a plan or a layout change. Assert
# the ground first so a failure names its own cause.

check "premise: the narrow plan is a columnar custom scan" \
	"$(has_line "$PLAN_NARROW" 'Columnar Projected Columns')" "yes"
check "premise: the wide plan is a columnar custom scan" \
	"$(has_line "$PLAN_WIDE" 'Columnar Projected Columns')" "yes"
check "premise: one row group, so every difference is per-vector" \
	"$(q "SELECT count(*) FROM pgcolumnar.row_group WHERE storage_id = pgcolumnar.get_storage_id('n');")" \
	"1"
check "premise: no whole group is pruned on the narrow query" \
	"$(counter_in "$PLAN_NARROW" 'Columnar Chunk Groups Removed by Filter')" "0"

# The two arms must differ in what the zone maps rule out, or the central check
# compares a number with itself and passes against any implementation.
SKIP_NARROW="$(counter_in "$PLAN_NARROW" 'Columnar Vectors Skipped')"
SKIP_WIDE="$(counter_in "$PLAN_WIDE" 'Columnar Vectors Skipped')"
check "premise: the narrow range skips vectors" \
	"$([ "${SKIP_NARROW:-0}" -gt 0 ] && echo yes || echo no)" "yes"
check "premise: the wide range skips none, so the arms really differ" \
	"$SKIP_WIDE" "0"

# ---- the observable -------------------------------------------------------

check "EXPLAIN reports Columnar Vectors Decoded" \
	"$(has_line "$PLAN_WIDE" 'Columnar Vectors Decoded')" "yes"

DEC_WIDE="$(counter_in "$PLAN_WIDE" 'Columnar Vectors Decoded')"
check "and it is not stuck at zero when a full scan decodes everything" \
	"$([ "${DEC_WIDE:-0}" -gt 0 ] && echo yes || echo no)" "yes"

# ---- the fix itself -------------------------------------------------------

DEC_NARROW="$(counter_in "$PLAN_NARROW" 'Columnar Vectors Decoded')"

check "a ruled-out vector is not decoded" \
	"$([ "${DEC_NARROW:-0}" -lt "${DEC_WIDE:-0}" ] && echo yes || echo no)" "yes"

# The check that has teeth. "Decodes fewer" is satisfied by decoding one vector
# less out of thirty-two, which is what a half-working mask does. Every vector
# the zone maps ruled out must go undecoded, so the two counters must account
# for the whole group between them.
check "and EVERY ruled-out vector is: decoded plus skipped is the group's vectors" \
	"$(( ${DEC_NARROW:-0} + ${SKIP_NARROW:-0} ))" "${DEC_WIDE:-0}"

# ---- correctness, which is the risk this change carries -------------------
#
# Not decoding a vector leaves a hole in the chunk's raw buffer. The row
# producer steps its cursors past it, but the vectorized fold reads that buffer
# directly and re-checks every value, so a hole would be re-checked as
# uninitialized memory -- a wrong aggregate, silently, and only on data whose
# zone maps rule something out. #512 and #523 are that hazard; these are the
# checks that would catch it coming back.

check "narrow range parity with heap" \
	"$(pgc_set_hash "$NARROW")" \
	"$(pgc_set_hash 'SELECT id, v FROM h WHERE id BETWEEN 2000 AND 2050')"
check "cross-vector range parity" \
	"$(pgc_set_hash 'SELECT id, v FROM n WHERE id BETWEEN 3000 AND 9000')" \
	"$(pgc_set_hash 'SELECT id, v FROM h WHERE id BETWEEN 3000 AND 9000')"
check "boundary range parity, a range starting exactly on a vector edge" \
	"$(pgc_set_hash 'SELECT id, v FROM n WHERE id BETWEEN 1025 AND 2048')" \
	"$(pgc_set_hash 'SELECT id, v FROM h WHERE id BETWEEN 1025 AND 2048')"

# The aggregate path is the one that reads the raw buffer directly.
check "aggregate over a skipping range matches heap" \
	"$(q 'SELECT count(*), sum(v) FROM n WHERE id BETWEEN 2000 AND 2050;')" \
	"$(q 'SELECT count(*), sum(v) FROM h WHERE id BETWEEN 2000 AND 2050;')"
check "aggregate over a range spanning many skipped vectors matches heap" \
	"$(q 'SELECT count(*), sum(v), min(v), max(v) FROM n WHERE id BETWEEN 5000 AND 5200;')" \
	"$(q 'SELECT count(*), sum(v), min(v), max(v) FROM h WHERE id BETWEEN 5000 AND 5200;')"
check "a range matching no row at all is still correct" \
	"$(q 'SELECT count(*) FROM n WHERE id BETWEEN 100000 AND 200000;')" "0"

pgc_summary
