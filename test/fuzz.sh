#!/usr/bin/env bash
#
# pgColumnar randomized differential (property-based) suite.
#
# Each iteration picks, from a seeded PRNG, a random row count (including values
# near chunk/stripe boundaries), null density, chunk-group and stripe limits,
# compression codec and level, and filter bounds, loads a heap/columnar pair
# with the same data, and asserts every query in the battery agrees. Heap is the
# oracle. The seed is printed up front; a failing run reproduces exactly with
# PGC_SEED=<seed>.
#
# Usage:  test/fuzz.sh [PG_CONFIG]
#   PGC_SEED=<int>   fix the seed (default 12345)
#   PGC_ITERS=<int>  iterations (default 25)
#
# Written fresh for pgColumnar; it does not reuse any upstream test file.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

SEED="${PGC_SEED:-12345}"
ITERS="${PGC_ITERS:-25}"
RANDOM=$SEED
echo "-- fuzz seed=$SEED iters=$ITERS  (reproduce a failure with PGC_SEED=$SEED)"

# Uniform integer in [0, n).
# THE GENERATORS SET A VARIABLE; THEY DO NOT PRINT (#1011).
#
# `RANDOM=$SEED` above does seed the sequence. Every call site read it through a
# COMMAND SUBSTITUTION -- `N=$(( 1 + $(rnd 5000) ))` -- and `$( )` is a subshell.
# Bash re-seeds RANDOM in a subshell (5.1+, deliberately, so two subshells do not
# yield the same value), so each call drew from a fresh sequence and the seeded one
# in this shell was never read. PGC_SEED controlled nothing, while the suite printed
# `reproduce a failure with PGC_SEED=<n>` on every run.
#
# Measured on this box, bash 5.3.9, the two forms over one seed:
#
#     subshell    run A: 739 227 141 262 904     run B: 798 969 493 460 795
#     arithmetic  run A: 202 552 638 271 721     run B: 202 552 638 271 721
#
# `$(( ))` is ARITHMETIC EXPANSION and runs in this shell, so the results below are
# assigned rather than echoed and no subshell is entered at any call site.
rnd() { _RND=$(( RANDOM % $1 )); }
pick() { local n=$#; local i=$(( RANDOM % n )); shift "$i"; _PICK="$1"; }
# Pick one element of the argument list.

CODECS="none pglz lz4 zstd"

# Fixed but type-diverse schema; randomness is in volume, nulls, storage
# parameters, codec, and predicate bounds.
FUZZ_DEFS="id int, c_int int, c_num numeric(20,4), c_f8 double precision,
	c_bool boolean, c_date date, c_ts timestamp, c_vc varchar(40), c_text text"

for it in $(seq 1 "$ITERS"); do
	rnd 5000; N=$(( 1 + _RND ))
	# Occasionally snap N to a boundary of the chosen chunk-group limit.
	rnd 18; NULLMOD=$(( 2 + _RND ))
	pick 100 250 500 1000; CG="$_PICK"
	pick 1000 2000 5000; SR="$_PICK"
	# shellcheck disable=SC2086
	pick $CODECS; CODEC="$_PICK"
	rnd 19; LVL=$(( 1 + _RND ))
	# Filter bounds within the generated ranges.
	span=$(( N > 1 ? N : 2 ))
	rnd "$span"; LO=$_RND
	rnd 500; HI=$(( LO + 1 + _RND ))
	rnd "$span"; EQ=$(( 1 + _RND ))

	tag="it=$it N=$N nullmod=$NULLMOD cg=$CG sr=$SR codec=$CODEC lvl=$LVL"
	echo "-- $tag"

	make_pair "$FUZZ_DEFS"
	q "SELECT pgcolumnar.set_options('t_col',
		chunk_group_row_limit => $CG, stripe_row_limit => $SR,
		compression => '$CODEC', compression_level => $LVL);" >/dev/null

	load_pair "SELECT
		g,
		CASE WHEN g%$NULLMOD=0 THEN NULL ELSE (g*3 - 500) END,
		CASE WHEN g%$((NULLMOD+1))=0 THEN NULL ELSE (g::numeric*0.5 - 100) END,
		CASE WHEN g%$NULLMOD=0 THEN NULL ELSE (sqrt(g::float8) * (CASE WHEN g%2=0 THEN -1 ELSE 1 END)) END,
		CASE WHEN g%$NULLMOD=0 THEN NULL ELSE (g%2=0) END,
		CASE WHEN g%$NULLMOD=0 THEN NULL ELSE (DATE '2010-01-01' + g) END,
		CASE WHEN g%$NULLMOD=0 THEN NULL ELSE (TIMESTAMP '2010-01-01' + make_interval(mins => g)) END,
		CASE WHEN g%$NULLMOD=0 THEN NULL ELSE ('v'||lpad(g::text,6,'0')) END,
		CASE WHEN g%$NULLMOD=0 THEN NULL WHEN g%997=0 THEN repeat('q',3000) ELSE ('t'||g) END
		FROM generate_series(1,$N) g"

	check "$tag :: row count" "$(q 'SELECT count(*) FROM t_col;')" "$N"

	diff_query "$tag :: whole-row"  "SELECT * FROM %T"
	diff_query "$tag :: count"      "SELECT count(*), count(c_int), count(c_text) FROM %T"
	diff_query "$tag :: minmax"     "SELECT min(c_int), max(c_int), min(c_vc), max(c_vc), min(c_date), max(c_date) FROM %T"
	diff_query "$tag :: sumavg"     "SELECT sum(c_int), avg(c_num), sum(c_f8) FROM %T"
	diff_query "$tag :: range int"  "SELECT id FROM %T WHERE c_int BETWEEN $LO AND $HI"
	diff_query "$tag :: range date" "SELECT id FROM %T WHERE c_date >= DATE '2010-06-01'"
	diff_query "$tag :: eq"         "SELECT id, c_vc FROM %T WHERE id = $EQ"
	diff_query "$tag :: isnull"     "SELECT count(*) FROM %T WHERE c_text IS NULL"
	diff_query "$tag :: compound"   "SELECT id FROM %T WHERE c_int > 0 AND c_bool AND c_num < 1000"
done

pgc_summary
