#!/usr/bin/env bash
#
# pgColumnar fetch-by-row-number cache (issue #143).
#
# ColumnarReadRowByNumber() used to read and decode a whole row group per row
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
		UPDATE $1 SET v = v + 1 WHERE id <= $UPD;" >/dev/null 2>&1
	end=$(date +%s%N)
	echo $(( (end - start) / 1000000 ))
}

build fc_one "$ROWS"          # every row in a single row group
build fc_many $((ROWS / 10))  # the same rows across ten

one="$(upd_ms fc_one)"
many="$(upd_ms fc_many)"
echo "-- $UPD fetches: one group of $ROWS took ${one} ms; ten groups took ${many} ms"

# Without the cache the single-group case decodes ten times as much per fetch and
# lands near 10x. With it, both are dominated by the fetches and sit near 1x.
check_timing "fetching from one big group is not far dearer than from ten small ones" \
	"$( [ "$many" -gt 0 ] && [ $(( one / (many > 0 ? many : 1) )) -lt 3 ] && echo yes ||
		echo "no (one=${one}ms ten=${many}ms)")" \
	"yes"

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
	"$(grep -c 'ColumnarDiscardFetchCache' "$SRC/columnar_tableam.c")" "2"

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
bigw="$(w_ms fc_wide)"; smallw="$(w_ms fc_wnarrow)"
echo "-- #353 wide point query: default-stripe ${bigw} ms, small-stripe ${smallw} ms"
check_timing "a wide group's fetch is not far dearer than a small group's (#353)" \
	"$( [ "$smallw" -gt 0 ] && [ $(( bigw / (smallw > 0 ? smallw : 1) )) -lt 5 ] && echo yes ||
		echo "no (wide=${bigw}ms small=${smallw}ms)")" \
	"yes"
check "the wide-group point query is correct (#353)" \
	"$(q "SELECT count(*) || '|' || coalesce(max(u)::text,'z') FROM fc_wide WHERE h='h1'")" \
	"$(q "SELECT count(*) || '|' || coalesce(max(u)::text,'z') FROM fc_wnarrow WHERE h='h1'")"

pgc_summary
