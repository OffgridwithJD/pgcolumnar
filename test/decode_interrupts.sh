#!/usr/bin/env bash
#
# pgColumnar decode-path interrupt discipline.
#
# A column chunk is decoded one vector at a time, and a vector is not the fixed
# 1024 that pgcolumnar.storage.vector_length suggests: the writer emits a single
# vector covering the whole chunk, so the value count reaching a decoder is
# bounded only by pgcolumnar.chunk_group_row_limit, which is user-settable and
# unbounded. Verified by reading the descriptor of a 100,000-row chunk: one
# vector, 100,000 values. So every per-value loop in a decoder is a stretch of
# work whose length the user chooses, and each one needs its own interrupt check.
#
# This is a source-shape test rather than a timing one, and the reason is worth
# stating, because the obvious test does not work.
#
# Cancellation cannot distinguish these checks at any scale the matrix can carry.
# decode_dict and decode_alp both call bitunpack over the same value count before
# their own loop, and bitunpack checks, so a statement_timeout always fires there
# first: measured on 8,000,000-value single-column tables, a cancel landed at
# 63 ms against a 193 ms load with the dictionary check present and at 63 ms
# against 186 ms with it removed. decode_rle has no bitunpack in its path, but it
# decodes 8,000,000 values in about 95 ms, which is shorter than the floor a 50 ms
# statement_timeout can resolve. Making the window big enough to measure needs
# hundreds of millions of rows in one chunk group.
#
# A test that passes with the guard removed proves nothing, so this asserts the
# shape instead, the way wal_envelope.sh does for WAL. It will need updating when
# the decoders legitimately change, which is the point: adding a decoder without
# an interrupt check should fail here rather than be absorbed silently.
#
# Usage:  test/decode_interrupts.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# No cluster needed; pgc_setup is skipped deliberately. Provide the counters the
# shared check() helper expects.
PGC_CHECKS=0
PGC_FAIL=0
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"
FN="$SRC/columnar_encoding.c"

echo "== pgColumnar decode-path interrupt discipline =="
echo "srcdir=$SRC"

check "the decode interrupt macro exists" \
	"$(grep -c '^#define COLUMNAR_DECODE_INTERRUPT(i)' "$FN")" "1"

# The macro must call the real thing, not a placeholder.
check "the macro calls CHECK_FOR_INTERRUPTS" \
	"$(awk '/^#define COLUMNAR_DECODE_INTERRUPT\(i\)/,/^$/' "$FN" | grep -c 'CHECK_FOR_INTERRUPTS')" "1"

# Line range of a static function: its definition line to the next one at column
# zero. Same approach as wal_envelope.sh.
range_of() {  # function-name -> "start end"
	local start end
	start="$(grep -n "^$1(" "$FN" | head -1 | cut -d: -f1)"
	[ -z "$start" ] && { echo "0 0"; return; }
	end="$(awk -v s="$start" 'NR > s && /^[A-Za-z_][A-Za-z0-9_]*\(/ {print NR; exit}' "$FN")"
	[ -z "$end" ] && end="$(wc -l < "$FN")"
	echo "$start $end"
}

checks_in() {  # function-name -> count of interrupt checks in its body
	local r; r="$(range_of "$1")"
	awk -v s="${r% *}" -v e="${r#* }" \
		'NR >= s && NR <= e && /COLUMNAR_DECODE_INTERRUPT\(/ {n++} END {print n+0}' "$FN"
}

# Every decoder that walks values one at a time. bitunpack is included because
# the bit-packed decoders reach their value count through it.
for f in bitunpack decode_rle decode_for decode_delta decode_gorilla decode_dod \
         decode_alp decode_dict; do
	check "$f was found" \
		"$([ "$(range_of "$f")" != "0 0" ] && echo yes || echo no)" "yes"
	check "$f checks for interrupts" \
		"$([ "$(checks_in "$f")" -ge 1 ] && echo yes || echo no)" "yes"
done

# decode_rle is the one where placement matters rather than presence. Its outer
# loop walks runs and its inner loop walks values, and a single run can cover the
# whole vector, so a check in the outer loop alone runs once and then copies every
# value uninterrupted. Testing the outer counter is also unsound on its own: it
# advances by run length rather than by one, so it can step over every multiple of
# the stride and never fire again after the first run.
rle_r="$(range_of decode_rle)"
rle_s="${rle_r% *}"; rle_e="${rle_r#* }"
inner="$(awk -v s="$rle_s" -v e="$rle_e" 'NR >= s && NR <= e && /while \(run-- > 0/ {print NR; exit}' "$FN")"
check "decode_rle's inner value loop was found" \
	"$([ -n "$inner" ] && echo yes || echo no)" "yes"
check "decode_rle checks inside its value loop, not only around it" \
	"$(awk -v s="$inner" -v e="$rle_e" \
		'NR > s && NR <= e && /COLUMNAR_DECODE_INTERRUPT\(/ {n++} END {print n+0}' "$FN" \
		| awk '{print ($1 >= 1) ? "yes" : "no"}')" "yes"

# The stride is what makes the check cheap enough to sit in a per-value loop. A
# non-power-of-two would make the test a modulo rather than a mask, and a huge
# one would put the cancellation latency back.
stride="$(grep -oE '^#define COLUMNAR_DECODE_INTERRUPT_STRIDE [0-9]+' "$FN" | awk '{print $3}')"
check "the stride is defined" "$([ -n "$stride" ] && echo yes || echo no)" "yes"
check "the stride is a power of two" \
	"$([ -n "$stride" ] && [ $(( stride & (stride - 1) )) -eq 0 ] && echo yes || echo no)" "yes"
check "the stride is not so large that a check never lands" \
	"$([ -n "$stride" ] && [ "$stride" -le 1048576 ] && echo yes || echo no)" "yes"

# The two checks in the reader are what make a scan cancellable between chunks and
# between rows. They are the coarse net under all of the above; losing them would
# leave a whole group load or a whole run of skipped rows uninterruptible.
RD="$SRC/columnar_reader.c"
check "the group load checks for interrupts per column chunk" \
	"$(awk '/^columnar_native_load_group\(/,/^}/' "$RD" | grep -c 'CHECK_FOR_INTERRUPTS')" "1"
check "the row loop checks for interrupts" \
	"$(awk '/^columnar_native_next_row\(/,/^}/' "$RD" | grep -c 'CHECK_FOR_INTERRUPTS')" "1"

pgc_summary
