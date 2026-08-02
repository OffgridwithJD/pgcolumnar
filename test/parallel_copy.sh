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

# Atomic parallel_copy prepares one transaction per worker and runs a coordinator
# bgworker plus N loader bgworkers, so the cluster needs 2PC capacity and enough
# worker slots. max_prepared_transactions is PGC_POSTMASTER, so it must be set
# before the cluster starts (pgc_setup reads PGC_EXTRA_CONF into postgresql.conf).
export PGC_EXTRA_CONF=$'max_prepared_transactions=8\nmax_worker_processes=16'

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

# ---- coordinator: pgcolumnar.parallel_copy (partition-parallel, atomic 2PC) ---
# Each worker loads a DISTINCT partition (distinct storage id -> parallel AND
# 2PC-atomic, no deadlock). The N-worker load of F must produce exactly the rows a
# single COPY does; t_heap already holds F (id 1..5000, sorted by id) and is the
# oracle. F is sorted by id, so we range-partition the target by id.
err_of() {	# runs a query, echoes stderr+stdout (for error-path assertions)
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -Atc "$1" 2>&1 || true
}
mkpart() {	# name nparts  -> range-partitioned columnar table over id in [1,5000]
	local name="$1" n="$2" i lo hi step ddl
	step=$(( (5000 + n) / n ))
	ddl="DROP TABLE IF EXISTS $name CASCADE; CREATE TABLE $name (id int, txt text) PARTITION BY RANGE (id);"
	for i in $(seq 0 $((n - 1))); do
		if [ "$i" = 0 ]; then lo=MINVALUE; else lo=$((i * step)); fi
		if [ "$i" = $((n - 1)) ]; then hi=MAXVALUE; else hi=$(((i + 1) * step)); fi
		ddl="$ddl CREATE TABLE ${name}_p$i PARTITION OF $name FOR VALUES FROM ($lo) TO ($hi) USING pgcolumnar;"
	done
	psql_run "$ddl" >/dev/null
}

for W in 1 2 4; do
	mkpart t_pcp 4
	check "parallel_copy(partitioned, $W workers): rows returned = 5000" \
		"$(q "SELECT pgcolumnar.parallel_copy('t_pcp'::regclass, '$F', $W)")" 5000
	check "parallel_copy(partitioned, $W workers): result == single-COPY oracle" \
		"$(pgc_set_hash "SELECT * FROM t_pcp")" "$(pgc_set_hash "SELECT * FROM t_heap")"
	check "parallel_copy(partitioned, $W workers): no prepared-transaction leak" \
		"$(q "SELECT count(*) FROM pg_prepared_xacts")" 0
done

# ---- signed keys straddling 0 with an unbounded first partition --------------
# Regression for the bucket miscompare that ignored MINVALUE/MAXVALUE bound kinds:
# a [MINVALUE,100) partition holds keys on BOTH sides of 0, and a signed key
# compared against the (undefined) MINVALUE datum-read-as-0 would split that one
# partition across workers -> wrong result or the write-lock deadlock. Must load
# correctly. (Positive-only keys hid this; hence an explicit negative fixture.)
F_SIGNED="$DATADIR/signed.txt"
psql_run "COPY (SELECT g AS id, 'h'||g AS txt FROM generate_series(-100, 399) g)
          TO '$F_SIGNED' WITH (FORMAT text);" >/dev/null
[ "$(id -u)" = "0" ] && chown postgres "$F_SIGNED"
psql_run "DROP TABLE IF EXISTS t_heap_s; CREATE TABLE t_heap_s (id int, txt text);" >/dev/null
psql_run "\copy t_heap_s FROM '$F_SIGNED' WITH (FORMAT text)" >/dev/null
psql_run "DROP TABLE IF EXISTS t_signed CASCADE;
          CREATE TABLE t_signed (id int, txt text) PARTITION BY RANGE (id);
          CREATE TABLE t_signed_a PARTITION OF t_signed FOR VALUES FROM (MINVALUE) TO (100) USING pgcolumnar;
          CREATE TABLE t_signed_b PARTITION OF t_signed FOR VALUES FROM (100) TO (300) USING pgcolumnar;
          CREATE TABLE t_signed_c PARTITION OF t_signed FOR VALUES FROM (300) TO (MAXVALUE) USING pgcolumnar;" >/dev/null
check "signed keys straddling 0: rows returned = 500" \
	"$(q "SELECT pgcolumnar.parallel_copy('t_signed'::regclass, '$F_SIGNED', 3)")" 500
check "signed keys straddling 0: result == oracle (no misbucketing/deadlock)" \
	"$(pgc_set_hash "SELECT * FROM t_signed")" "$(pgc_set_hash "SELECT * FROM t_heap_s")"
check "signed keys straddling 0: no prepared-transaction leak" \
	"$(q "SELECT count(*) FROM pg_prepared_xacts")" 0

# ---- a text partition key (with MINVALUE/MAXVALUE bounds) is rejected, not crash --
# jdatcmd's crash repro: a by-reference key + an unbounded bound would deref an
# undefined datum. Now the numeric/temporal-key restriction rejects it cleanly, and
# the kind-dispatch means even a would-be compare never touches the datum.
psql_run "DROP TABLE IF EXISTS t_txtkey CASCADE;
          CREATE TABLE t_txtkey (k text, v int) PARTITION BY RANGE (k);
          CREATE TABLE t_txtkey_a PARTITION OF t_txtkey FOR VALUES FROM (MINVALUE) TO ('m') USING pgcolumnar;
          CREATE TABLE t_txtkey_b PARTITION OF t_txtkey FOR VALUES FROM ('m') TO (MAXVALUE) USING pgcolumnar;" >/dev/null
tk_err="$(err_of "SELECT pgcolumnar.parallel_copy('t_txtkey'::regclass, '$F', 2)")"
check "text partition key is rejected (not a crash)" \
	"$(printf '%s' "$tk_err" | grep -qi "numeric or date/time" && echo ok || echo no)" ok
check "text partition key: server still up (no crash)" "$(q "SELECT 1")" 1

# ---- key NOT in column 1, with a generated column before it -------------------
# COPY's default column list skips generated columns, so the splitter's key-field
# index must skip them too; otherwise every row buckets wrong.
F_GEN="$DATADIR/genkey.txt"
psql_run "COPY (SELECT 'lbl'||g AS label, g AS id FROM generate_series(1,3000) g)
          TO '$F_GEN' WITH (FORMAT text);" >/dev/null
[ "$(id -u)" = "0" ] && chown postgres "$F_GEN"
GENSCHEMA="label text, gcol int GENERATED ALWAYS AS (id*2) STORED, id int"
psql_run "DROP TABLE IF EXISTS t_heap_g; CREATE TABLE t_heap_g ($GENSCHEMA);" >/dev/null
psql_run "\copy t_heap_g (label, id) FROM '$F_GEN' WITH (FORMAT text)" >/dev/null
psql_run "DROP TABLE IF EXISTS t_gen CASCADE;
          CREATE TABLE t_gen ($GENSCHEMA) PARTITION BY RANGE (id);
          CREATE TABLE t_gen_a PARTITION OF t_gen FOR VALUES FROM (MINVALUE) TO (1000) USING pgcolumnar;
          CREATE TABLE t_gen_b PARTITION OF t_gen FOR VALUES FROM (1000) TO (2000) USING pgcolumnar;
          CREATE TABLE t_gen_c PARTITION OF t_gen FOR VALUES FROM (2000) TO (MAXVALUE) USING pgcolumnar;" >/dev/null
check "key not in column 1 (generated col before it): rows = 3000" \
	"$(q "SELECT pgcolumnar.parallel_copy('t_gen'::regclass, '$F_GEN', 3)")" 3000
check "key not in column 1: result == oracle" \
	"$(pgc_set_hash "SELECT * FROM t_gen")" "$(pgc_set_hash "SELECT * FROM t_heap_g")"

# ---- atomicity 1: a bad partition-key value is rejected by the splitter -------
# The splitter parses the key of every row; a non-integer id fails there, before
# any worker/2PC -- nothing is loaded, no prepared transaction is created.
F_BADKEY="$DATADIR/badkey.txt"
{ for i in $(seq 1 400); do printf '%s\thost_%s\n' "$i" "$i"; done
  printf '%s\t%s\n' "notanint" "boom"
  for i in $(seq 401 800); do printf '%s\thost_%s\n' "$i" "$i"; done; } > "$F_BADKEY"
[ "$(id -u)" = "0" ] && chown postgres "$F_BADKEY"
mkpart t_pcp 4
bk_err="$(err_of "SELECT pgcolumnar.parallel_copy('t_pcp'::regclass, '$F_BADKEY', 4)")"
check "atomic: a bad partition-key value is rejected" \
	"$(printf '%s' "$bk_err" | grep -qi 'invalid input syntax' && echo ok || echo no)" ok
check "atomic: bad-key load leaves the target empty" "$(q "SELECT count(*) FROM t_pcp")" 0
check "atomic: no prepared-transaction leak after bad-key" "$(q "SELECT count(*) FROM pg_prepared_xacts")" 0

# ---- atomicity 2: a loader failure rolls back the PREPARED siblings -----------
# A gapped partitioned target (ids 2000..2999 belong to NO partition, no default):
# workers whose ranges route rows into the gap fail with "no partition of relation",
# so the coordinator must ROLLBACK PREPARED every worker that already prepared ->
# the target is left empty, with no orphaned prepared transaction.
psql_run "DROP TABLE IF EXISTS t_gap CASCADE;
          CREATE TABLE t_gap (id int, txt text) PARTITION BY RANGE (id);
          CREATE TABLE t_gap_a PARTITION OF t_gap FOR VALUES FROM (MINVALUE) TO (2000) USING pgcolumnar;
          CREATE TABLE t_gap_b PARTITION OF t_gap FOR VALUES FROM (3000) TO (MAXVALUE) USING pgcolumnar;" >/dev/null
gap_err="$(err_of "SELECT pgcolumnar.parallel_copy('t_gap'::regclass, '$F', 4)")"
check "atomic: a loader failure fails the whole load" \
	"$(printf '%s' "$gap_err" | grep -qiE 'no partition of relation|failed' && echo ok || echo no)" ok
check "atomic: loader-failure leaves the target empty (siblings rolled back)" \
	"$(q "SELECT count(*) FROM t_gap")" 0
check "atomic: no prepared-transaction leak after loader failure" \
	"$(q "SELECT count(*) FROM pg_prepared_xacts")" 0
check "atomic: server still up after a failed load" "$(q "SELECT 1")" 1

# ---- input must be sorted by the partition key -------------------------------
F_SHUF="$DATADIR/shuf.txt"
shuf "$F" > "$F_SHUF"; [ "$(id -u)" = "0" ] && chown postgres "$F_SHUF"
mkpart t_pcp 4
shuf_err="$(err_of "SELECT pgcolumnar.parallel_copy('t_pcp'::regclass, '$F_SHUF', 4)")"
check "unsorted input is rejected" \
	"$(printf '%s' "$shuf_err" | grep -qi "not sorted" && echo ok || echo no)" ok
check "unsorted rejection loads nothing" "$(q "SELECT count(*) FROM t_pcp")" 0

# ---- a DEFAULT partition is rejected (it could catch any worker's rows) -------
psql_run "DROP TABLE IF EXISTS t_def CASCADE;
          CREATE TABLE t_def (id int, txt text) PARTITION BY RANGE (id);
          CREATE TABLE t_def_a PARTITION OF t_def FOR VALUES FROM (MINVALUE) TO (2500) USING pgcolumnar;
          CREATE TABLE t_def_d PARTITION OF t_def DEFAULT USING pgcolumnar;" >/dev/null
def_err="$(err_of "SELECT pgcolumnar.parallel_copy('t_def'::regclass, '$F', 4)")"
check "DEFAULT partition target is rejected" \
	"$(printf '%s' "$def_err" | grep -qi "DEFAULT partition" && echo ok || echo no)" ok

# ---- the max_prepared_transactions guard fires up front ----------------------
# max_prepared_transactions is 8 (set above); a target with more partitions than
# that, loaded with that many workers, must error before spawning, naming the GUC.
mkpart t_pcp10 10
guard_err="$(err_of "SELECT pgcolumnar.parallel_copy('t_pcp10'::regclass, '$F', 10)")"
check "max_prepared_transactions guard fires" \
	"$(printf '%s' "$guard_err" | grep -qi "max_prepared_transactions" && echo ok || echo no)" ok
check "guard rejects before loading anything" "$(q "SELECT count(*) FROM t_pcp10")" 0

# ---- a missing file errors cleanly -------------------------------------------
mkpart t_pcp 4
mf_err="$(err_of "SELECT pgcolumnar.parallel_copy('t_pcp'::regclass, '$DATADIR/nope.txt', 2)")"
check "missing file: errors, not crashes" \
	"$(printf '%s' "$mf_err" | grep -qiE "could not (open|stat)|no such file|not a regular file" && echo ok || echo no)" ok
check "missing file: server still up (no worker crash)" "$(q "SELECT 1")" 1
check "missing file: nothing loaded" "$(q "SELECT count(*) FROM t_pcp")" 0

# ---- a non-columnar (heap) target is rejected --------------------------------
psql_run "DROP TABLE IF EXISTS t_heaptgt; CREATE TABLE t_heaptgt (id int, txt text);" >/dev/null
nc_err="$(err_of "SELECT pgcolumnar.parallel_copy('t_heaptgt'::regclass, '$F', 2)")"
check "non-columnar target is rejected" \
	"$(printf '%s' "$nc_err" | grep -qi "not a pgcolumnar table" && echo ok || echo no)" ok

# ---- single columnar table: workers write ONE storage concurrently -----------
# The storage-row creation lock is skipped by the loaders (the coordinator
# pre-creates the row committed), so N loaders write the one storage in parallel and
# 2PC-atomically. The result must equal a single COPY -- a concurrency race on the
# shared storage would diverge from the oracle. The GUC that gates the engine's
# skip must default off, so an ordinary write never takes that path.
check "bulk_parallel_writer GUC defaults off (core write path unchanged)" \
	"$(q "SHOW pgcolumnar.bulk_parallel_writer")" off
for W in 1 2 4; do
	psql_run "DROP TABLE IF EXISTS t_single; CREATE TABLE t_single (id int, txt text) USING pgcolumnar;" >/dev/null
	check "parallel_copy(single table, $W workers): rows returned = 5000" \
		"$(q "SELECT pgcolumnar.parallel_copy('t_single'::regclass, '$F', $W)")" 5000
	check "parallel_copy(single table, $W workers): result == single-COPY oracle" \
		"$(pgc_set_hash "SELECT * FROM t_single")" "$(pgc_set_hash "SELECT * FROM t_heap")"
	check "parallel_copy(single table, $W workers): no prepared-transaction leak" \
		"$(q "SELECT count(*) FROM pg_prepared_xacts")" 0
done

# single-table atomicity: a bad row rolls back the whole load, no leak
psql_run "DROP TABLE IF EXISTS t_single; CREATE TABLE t_single (id int, txt text) USING pgcolumnar;" >/dev/null
st_bad="$(err_of "SELECT pgcolumnar.parallel_copy('t_single'::regclass, '$F_BADKEY', 4)")"
check "single table: a bad row fails the whole load" \
	"$(printf '%s' "$st_bad" | grep -qiE 'invalid input syntax|failed' && echo ok || echo no)" ok
check "single table: failed load leaves the target empty" "$(q "SELECT count(*) FROM t_single")" 0
check "single table: no prepared-transaction leak after failure" "$(q "SELECT count(*) FROM pg_prepared_xacts")" 0

pgc_summary
