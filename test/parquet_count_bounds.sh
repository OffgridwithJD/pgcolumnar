#!/usr/bin/env bash
#
# pgColumnar: file-declared Parquet counts are bounded before use (#570, #571).
#
# The Parquet reader takes two counts straight off the wire and uses them to size
# allocations and drive loops, with no bound of their own:
#
#   #570  A column chunk's num_values sizes the per-chunk decode arrays as
#         sizeof(T) * Max(num_values, 1). That product is size_t arithmetic, so a
#         num_values of 2^62 wraps to zero, the palloc succeeds, and the decoder
#         writes the page into a zero-size allocation. It also DEFEATS the
#         MaxAllocSize check that rejects a merely-large value: 10^9 errors
#         cleanly, 2^62 wraps to 0 and does not.
#
#   #571  A row group's num_rows drives the row-assembly loop, which reads
#         defs[]/vals[] sized to the chunk's num_values. A num_rows greater than
#         num_values walks those cursors past the decoded arrays: phantom rows
#         built from adjacent heap, or a crash into recovery.
#
# Both reach import_parquet, read_parquet and the Parquet FDW. On unfixed code
# the 2^62 and 5,000,000 cases crash the backend; the fix rejects all three at
# parse time with "malformed row group". The honest file must still import.
#
# The malformed files are crafted by patching the footer's Thrift-compact
# varints for num_values / num_rows and fixing the trailer length; the data pages
# are untouched, so this is a genuine "file lies about its counts" input rather
# than random corruption. The crafter self-checks that it located the right
# fields (both read 8 on the honest file) before it patches anything.
#
# Run on an assert build so an out-of-bounds access trips rather than passing.
#
# Usage:  test/parquet_count_bounds.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

if ! python3 -c 'import pyarrow.parquet' 2>/dev/null; then
	pgc_skip pyarrow "pyarrow not available; Parquet count-bounds suite needs it"
fi

W="$PGC_WORKDIR"
python3 "$(dirname "${BASH_SOURCE[0]}")/craft_parquet_counts.py" "$W"
psql_run "CREATE SERVER pq FOREIGN DATA WRAPPER pgcolumnar_parquet;"

# import_of FILE -> row count on success, or "ERR: <first error line>"
import_of() {
	local out
	out="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -At \
		-v ON_ERROR_STOP=0 \
		-c "DROP TABLE IF EXISTS pcb;" \
		-c "CREATE TABLE pcb (a int) USING pgcolumnar;" \
		-c "SELECT pgcolumnar.import_parquet('pcb','$W/$1');" \
		-c "SELECT count(*) FROM pcb;" 2>&1)"
	if grep -q '^ERROR:' <<<"$out"; then
		echo "ERR: $(grep -m1 '^ERROR:' <<<"$out")"
	else
		echo "$out" | tail -1
	fi
}

# detail_of FILE -> the full ERROR+DETAIL text of a failed import (for attribution)
detail_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -At \
		-v ON_ERROR_STOP=0 \
		-c "DROP TABLE IF EXISTS pcb;" \
		-c "CREATE TABLE pcb (a int) USING pgcolumnar;" \
		-c "SELECT pgcolumnar.import_parquet('pcb','$W/$1');" 2>&1
}

# The server must still be up between calls. If a malformed file crashed the
# backend, this probe fails and every arm below is meaningless, so it gates them.
alive() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -At \
		-c 'SELECT 1;' 2>&1 | head -1
}

# ---- premises ---------------------------------------------------------------
check "premise: the crafter produced the four files" \
	"$([ -s "$W/honest.parquet" ] && [ -s "$W/bignv.parquet" ] && [ -s "$W/bignr.parquet" ] && [ -s "$W/hugenr.parquet" ] && echo yes || echo no)" "yes"
check "premise: the server is up before any malformed file is read" "$(alive)" "1"

# ---- the honest file is unaffected -----------------------------------------
check_num "an honest file imports its rows" "$(import_of honest.parquet)" "8"
check "the server is still up after the honest import" "$(alive)" "1"

# ---- #570: num_values wrap --------------------------------------------------
r_bignv="$(import_of bignv.parquet)"
check "num_values 2^62 is rejected, not imported" \
	"$(grep -qi 'malformed row group' <<<"$r_bignv" && echo rejected || echo "$r_bignv")" "rejected"
check "and the backend is still up (it did not wrap-allocate and crash)" "$(alive)" "1"

# ---- #571: num_rows past the decoded values --------------------------------
r_bignr="$(import_of bignr.parquet)"
check "num_rows past the chunk's values is rejected, not emitted as phantom rows" \
	"$(grep -qi 'malformed row group' <<<"$r_bignr" && echo rejected || echo "$r_bignr")" "rejected"
# The phantom-row harm specifically: it must NOT return 40 rows for an 8-value file.
check "and it did not silently return more rows than the file holds" \
	"$([ "$r_bignr" = "40" ] && echo leaked || echo ok)" "ok"

r_hugenr="$(import_of hugenr.parquet)"
check "a huge num_rows is rejected rather than walking off the allocation" \
	"$(grep -qi 'malformed row group' <<<"$r_hugenr" && echo rejected || echo "$r_hugenr")" "rejected"
check "and the backend survived it" "$(alive)" "1"

# ---- the rejection is attributable, not a generic failure -------------------
check "the num_values rejection names num_values in its detail" \
	"$(detail_of bignv.parquet | grep -c 'num_values')" "1"
check "the num_rows rejection names num_rows in its detail" \
	"$(detail_of bignr.parquet | grep -c 'num_rows')" "1"

pgc_summary
