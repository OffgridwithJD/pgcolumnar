#!/usr/bin/env bash
#
# pgColumnar #300: parallel bulk ingest.
#
# Phase 1 covers the file range splitter (pgcolumnar.file_split_offsets): given a
# text file and a worker count N, it returns N+1 byte offsets that partition the
# file into N record-aligned ranges. The parallel loader hands range
# [off[i], off[i+1]) to worker i, so the splitter is only correct if:
#
#   1. structure: off[0]=0, off[N]=filesize, offsets non-decreasing, and every
#      interior offset sits immediately after a newline (a real record boundary);
#   2. coverage + reconstruction: COPYing each range separately loads exactly the
#      same rows as one COPY of the whole file -- no record split, dropped, or
#      duplicated across ranges.
#
# The heap mirror is the oracle: the union of the per-range loads must equal a
# single COPY of the file. Covers many worker counts (including more workers than
# rows -> empty ranges), a file with no trailing newline, and a single row.
#
# Usage:  test/parallel_copy.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

DATADIR="$PGC_WORKDIR/pcopy"
mkdir -p "$DATADIR"; chmod 777 "$DATADIR"
if [ "$(id -u)" = "0" ]; then chown postgres "$DATADIR"; fi

# server-side path helper: write a file via COPY TO (owned by the server) so
# file_split_offsets can read it, then dd out byte ranges as needed.
make_file() {	# rows -> echoes the server path
	local rows="$1"
	local f="$DATADIR/data_${rows}.txt"
	psql_run "COPY (SELECT g AS id, 'host_'||(g%97)||'_x'||g AS txt
	                FROM generate_series(1, $rows) g)
	          TO '$f' WITH (FORMAT text);" >/dev/null
	printf '%s\n' "$f"
}

# offsets array text -> bash array via the caller
offsets_of() {	# path workers -> space-separated offsets
	q "SELECT array_to_string(pgcolumnar.file_split_offsets('$1', $2), ' ')"
}

# ---- structural checks: boundaries land after a newline, cover the file -------

check_structure() {	# path workers label
	local f="$1" w="$2" label="$3"
	local size off arr ok prev i b
	size=$(stat -c %s "$f")
	read -r -a arr <<<"$(offsets_of "$f" "$w")"
	ok=1
	if [ "${#arr[@]}" != "$((w + 1))" ]; then
		check "$label: offsets well-formed and newline-aligned" \
			"got ${#arr[@]} offsets" "want $((w + 1))"
		return
	fi
	[ "${arr[0]}" = "0" ] || ok=0
	[ "${arr[$w]}" = "$size" ] || ok=0
	prev=-1
	for i in $(seq 0 "$w"); do
		off=${arr[$i]:-}
		[ "$off" -ge "$prev" ] 2>/dev/null || ok=0
		prev=$off
		# interior offset must sit right after a newline
		if [ "$i" -gt 0 ] && [ "$i" -lt "$w" ] && [ "$off" -gt 0 ] && [ "$off" -lt "$size" ]; then
			b=$(dd if="$f" bs=1 skip=$((off - 1)) count=1 2>/dev/null | od -An -tx1 | tr -d ' ')
			[ "$b" = "0a" ] || ok=0
		fi
	done
	check "$label: offsets well-formed and newline-aligned" "$ok" 1
}

# ---- end-to-end: per-range loads reconstruct the whole file -------------------

check_reconstruct() {	# path workers label
	local f="$1" w="$2" label="$3"
	local arr i off len rf
	read -r -a arr <<<"$(offsets_of "$f" "$w")"
	psql_run "DROP TABLE IF EXISTS t_split;
	          CREATE TABLE t_split (id int, txt text) USING pgcolumnar;" >/dev/null
	for i in $(seq 0 $((w - 1))); do
		off=${arr[$i]:-0}; len=$(( ${arr[$((i + 1))]:-0} - off ))
		[ "$len" -gt 0 ] || continue
		rf="$DATADIR/range_${w}_${i}.txt"
		dd if="$f" iflag=skip_bytes,count_bytes skip="$off" count="$len" of="$rf" 2>/dev/null
		[ "$(id -u)" = "0" ] && chown postgres "$rf"
		psql_run "\copy t_split FROM '$rf' WITH (FORMAT text)" >/dev/null
	done
	# t_col holds the single-COPY load of the same file -> oracle for this file
	local h_whole h_split
	h_whole="$(pgc_set_hash "SELECT * FROM t_col")"
	h_split="$(pgc_set_hash "SELECT * FROM t_split")"
	check "$label: per-range loads reconstruct the whole file" "$h_split" "$h_whole"
}

# ---- the split must actually split -------------------------------------------
# check_structure and check_reconstruct both pass on a splitter degraded to a
# single range ({0, size, size, ..., size}): the offsets are ascending and
# newline-aligned, and one range covering the whole file reconstructs it. That is
# not hypothetical -- a bare-CR file and phase 5's "fall back to a single COPY"
# path both produce exactly that shape. So when the file has far more records than
# workers, assert every range is non-empty: the W-1 interior offsets must be
# strictly increasing and strictly inside (0, size). A degraded split fails here.
check_split_happened() {	# path workers label
	local f="$1" w="$2" label="$3"
	local size arr ok prev i off
	size=$(stat -c %s "$f")
	read -r -a arr <<<"$(offsets_of "$f" "$w")"
	ok=1
	prev=0
	for i in $(seq 1 $((w - 1))); do
		off=${arr[$i]:-}
		{ [ "$off" -gt "$prev" ] && [ "$off" -lt "$size" ]; } 2>/dev/null || ok=0
		prev=$off
	done
	check "$label: split is real (interior offsets distinct, ranges non-empty)" "$ok" 1
}

# ---- the main file: 5000 rows -----------------------------------------------

make_pair "id int, txt text"
F=$(make_file 5000)
psql_run "\copy t_heap FROM '$F' WITH (FORMAT text)" >/dev/null
psql_run "\copy t_col  FROM '$F' WITH (FORMAT text)" >/dev/null
check "single-COPY heap and columnar agree" \
	"$(pgc_set_hash "SELECT * FROM t_col")" "$(pgc_set_hash "SELECT * FROM t_heap")"

for W in 1 2 3 8 16; do
	check_structure "$F" "$W" "5000 rows / $W"
	check_reconstruct "$F" "$W" "5000 rows / $W"
	# 5000 rows >> W, so every range must be non-empty: catches a degraded split.
	[ "$W" -ge 2 ] && check_split_happened "$F" "$W" "5000 rows / $W"
done

# a line longer than the 64 kB scan chunk: the boundary for a mid-file split lands
# only after crossing a read-chunk boundary, exercising the multi-chunk read (the
# only part of the scan with carried-over state).
F_BIG="$DATADIR/biglines.txt"
psql_run "COPY (SELECT g AS id, 'h'||g||'_'||repeat('x', 70000) AS txt
                FROM generate_series(1, 20) g)
          TO '$F_BIG' WITH (FORMAT text);" >/dev/null
[ "$(id -u)" = "0" ] && chown postgres "$F_BIG"
psql_run "TRUNCATE t_col;" >/dev/null
psql_run "\copy t_col FROM '$F_BIG' WITH (FORMAT text)" >/dev/null
check_structure "$F_BIG" 4 "long lines >64kB / 4 workers"
check_reconstruct "$F_BIG" 4 "long lines >64kB / 4 workers"
check_split_happened "$F_BIG" 4 "long lines >64kB / 4 workers"

# more workers than rows: extra ranges must be empty, load still exact
F_TINY=$(make_file 5)
psql_run "TRUNCATE t_col;" >/dev/null
psql_run "\copy t_col FROM '$F_TINY' WITH (FORMAT text)" >/dev/null
check_structure "$F_TINY" 8 "5 rows / 8 workers"
check_reconstruct "$F_TINY" 8 "5 rows / 8 workers (empty ranges)"

# single row: an edge smoke test only. With one record and 4 workers the correct
# result is {0, size, size, size} -- the degenerate single-range shape -- so this
# case cannot distinguish a working splitter from a degraded one (that is what
# check_split_happened on the 5000-row file is for); it just confirms one record
# does not crash or drop.
F_ONE=$(make_file 1)
psql_run "TRUNCATE t_col;" >/dev/null
psql_run "\copy t_col FROM '$F_ONE' WITH (FORMAT text)" >/dev/null
check_structure "$F_ONE" 4 "1 row / 4 workers (edge smoke)"
check_reconstruct "$F_ONE" 4 "1 row / 4 workers (edge smoke)"

# file with no trailing newline: last range must still run to EOF
F_NONL="$DATADIR/nonl.txt"
psql_run "COPY (SELECT g, 'r'||g FROM generate_series(1,1000) g) TO '$F_NONL' WITH (FORMAT text);" >/dev/null
# strip the trailing newline
truncate -s -1 "$F_NONL"
[ "$(id -u)" = "0" ] && chown postgres "$F_NONL"
psql_run "TRUNCATE t_col;" >/dev/null
psql_run "\copy t_col FROM '$F_NONL' WITH (FORMAT text)" >/dev/null
check_structure "$F_NONL" 4 "no trailing newline / 4 workers"
check_reconstruct "$F_NONL" 4 "no trailing newline / 4 workers"

# workers < 1 is rejected (capture stderr into a var first: q() hides stderr, and
# a `psql | grep` pipeline would trip set -o pipefail on psql's error exit).
err_out="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
	-d "$PGC_DB" -Atc "SELECT pgcolumnar.file_split_offsets('$F', 0)" 2>&1 || true)"
check "workers < 1 is rejected" \
	"$(printf '%s' "$err_out" | grep -qi "at least 1" && echo ok || echo no)" ok

# a directory is rejected, not reported as an 8-exabyte splittable file (regression
# for the missing fstat/S_ISREG guard: lseek(SEEK_END) on a directory fd returns a
# huge value on Linux, so without the guard this returned {0, 9.2e18}).
dir_err="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
	-d "$PGC_DB" -Atc "SELECT pgcolumnar.file_split_offsets('$DATADIR', 1)" 2>&1 || true)"
check "file_split_offsets: a directory is rejected (not an 8-exabyte file)" \
	"$(printf '%s' "$dir_err" | grep -qi "not a regular file" && echo ok || echo no)" ok

# ---- coordinator: pgcolumnar.parallel_copy loads == a single COPY ----------
# The N-worker load of F must produce exactly the rows a single COPY does; t_heap
# already holds F via one COPY and is the oracle. (Worker counts kept <= 4 so the
# default max_worker_processes has slots.)
pcopy_run() {	# target workers -> echoes rows returned (empty on error)
	q "SELECT pgcolumnar.parallel_copy('$1'::regclass, '$F', $2)"
}

for W in 1 2 4; do
	psql_run "DROP TABLE IF EXISTS t_pc;
	          CREATE TABLE t_pc (id int, txt text) USING pgcolumnar;" >/dev/null
	check "parallel_copy($W workers): rows returned = 5000" "$(pcopy_run t_pc "$W")" 5000
	check "parallel_copy($W workers): result == single-COPY oracle" \
		"$(pgc_set_hash "SELECT * FROM t_pc")" "$(pgc_set_hash "SELECT * FROM t_heap")"
done

# a missing file errors cleanly -- no crash, no orphaned worker, nothing loaded
psql_run "DROP TABLE IF EXISTS t_pc;
          CREATE TABLE t_pc (id int, txt text) USING pgcolumnar;" >/dev/null
pc_err="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
	-d "$PGC_DB" -Atc "SELECT pgcolumnar.parallel_copy('t_pc'::regclass, '$DATADIR/nope.txt', 2)" 2>&1 || true)"
check "parallel_copy missing file: errors, not crashes" \
	"$(printf '%s' "$pc_err" | grep -qi "could not open" && echo ok || echo no)" ok
check "parallel_copy missing file: server still up (no worker crash)" "$(q "SELECT 1")" 1
check "parallel_copy missing file: nothing loaded" "$(q "SELECT count(*) FROM t_pc")" 0

# a non-columnar target is rejected before any worker is launched
psql_run "DROP TABLE IF EXISTS t_pc_heap; CREATE TABLE t_pc_heap (id int, txt text);" >/dev/null
nc_err="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
	-d "$PGC_DB" -Atc "SELECT pgcolumnar.parallel_copy('t_pc_heap'::regclass, '$F', 2)" 2>&1 || true)"
check "parallel_copy: non-columnar target rejected" \
	"$(printf '%s' "$nc_err" | grep -qi "not a pgcolumnar table" && echo ok || echo no)" ok

pgc_summary
