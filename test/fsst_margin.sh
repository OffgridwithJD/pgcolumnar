#!/usr/bin/env bash
#
# The FSST keep/drop cost margin (#155, #271).
#
# ColumnarFsstHelpsCompressed used to keep FSST on any compressed win at all,
# however small, and the per-vector FSST encode is a dominant cost of a text or
# varlena load. pgcolumnar.fsst_min_gain_percent requires the win to clear a
# margin before FSST is kept.
#
# The knob changes how bytes are encoded, so the check that matters is not that
# it saves time -- that is a benchmark, and benchmarks belong elsewhere -- but
# that it never changes what comes back out. A future change to the FSST path
# could otherwise alter content under a non-default margin with nothing to catch
# it.
#
# It asserts:
#   1. the margin actually decides -- a corpus whose FSST win is marginal keeps
#      FSST below the margin and drops it above, observed from the encoding
#      descriptor rather than inferred from size;
#   2. margin 0 is the original "any win keeps it", so the documented equivalence
#      is pinned rather than argued from the arithmetic;
#   3. the rows read back byte-identical at every margin, including against a
#      heap mirror. This is the invariant; 1 and 2 exist to prove 3 is not
#      vacuous.
#
# Usage:  test/fsst_margin.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS="${PGC_FSST_MARGIN_ROWS:-20000}"

# How many vectors of the text column chose FSST (encoding type 8).
#
# The descriptor is a 6-byte header -- version, a reserved byte, then the vector
# count as uint32 -- followed by that many 13-byte entries. Same decode as
# write_fsst_compressed.sh, and for the same reason: reading past the entries
# would score the chunk's symbol table as encoding types.
fsst_vectors() {  # table -> count
	q "SELECT coalesce(sum(n), 0) FROM (
		SELECT (SELECT count(*)
				FROM generate_series(0,
					get_byte(c.encoding_descriptor, 2)
					+ get_byte(c.encoding_descriptor, 3) * 256
					+ get_byte(c.encoding_descriptor, 4) * 65536
					+ get_byte(c.encoding_descriptor, 5) * 16777216 - 1) i
				WHERE get_byte(c.encoding_descriptor, 6 + i * 13) = 8) AS n
		FROM pgcolumnar.column_chunk c
		JOIN pgcolumnar.storage s ON s.storage_id = c.storage_id
		WHERE s.relation_oid = '$1'::regclass
		  AND c.column_index = 1) t;" | tail -1
}

# High-entropy hex: FSST builds a symbol table that barely pays, which is exactly
# the marginal case the margin exists to decline. Nulls and short values are mixed
# in because the decision applies to a whole chunk and those are the values whose
# handling differs between encodings.
# The decision corpus. Plain, because mixing NULLs and short values into it
# changes which encoding wins outright and the margin then never gets a say --
# which is what the first version of this suite did, and it reported "margin 0
# does not keep FSST" as though that were a finding about the margin.
decide_corpus="md5(g::text) || md5((g * 7)::text)"

# The content corpus. Deliberately the nastiest one: NULLs, empty strings and
# values below the FSST minimum, because the decision applies to a whole chunk
# at once and those are the values whose handling differs between encodings.
content_corpus="CASE g % 13
			WHEN 0 THEN NULL
			WHEN 1 THEN ''
			WHEN 2 THEN 'ab'
			ELSE md5(g::text) || md5((g * 7)::text)
		END"

# margin "" means: do not SET it at all, i.e. whatever the build ships.
load() {  # table margin corpus
	local setguc=""
	[ -n "$2" ] && setguc="SET pgcolumnar.fsst_min_gain_percent = $2;"
	psql_run "DROP TABLE IF EXISTS $1;
		$setguc
		CREATE TABLE $1 (id int, v text) USING pgcolumnar;
		INSERT INTO $1 SELECT g, $3 FROM generate_series(1, $ROWS) g;" >/dev/null 2>&1
}

# The heap mirror the columnar copies must all match.
psql_run "DROP TABLE IF EXISTS fm_h;
	CREATE TABLE fm_h (id int, v text);
	INSERT INTO fm_h SELECT g, $content_corpus FROM generate_series(1, $ROWS) g;" >/dev/null 2>&1
heap_hash="$(q "SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM fm_h t;")"
check "the heap mirror has content to compare against" \
	"$([ -n "$heap_hash" ] && echo yes || echo no)" "yes"

# --- 1. the margin decides ---------------------------------------------------

load fm_keep 0 "$decide_corpus"
kept="$(fsst_vectors fm_keep)"
check "at margin 0 this corpus keeps FSST" \
	"$([ "$kept" -gt 0 ] && echo yes || echo no)" "yes"

load fm_drop 90 "$decide_corpus"
dropped="$(fsst_vectors fm_drop)"
check "at margin 90 the same corpus drops FSST" "$dropped" "0"

# Without this the pair above could both be true of a corpus FSST never helped:
# the drop is only meaningful because the keep is real.
check "so the margin is what changed the decision, not the corpus" \
	"$([ "$kept" -gt "$dropped" ] && echo yes || echo no)" "yes"

# --- 2. margin 0 is the original behaviour -----------------------------------
#
# The arithmetic is exact -- total*100 < plain*100 is total < plain -- but the
# claim that the default did not silently change what gets encoded is worth
# pinning rather than deriving.
load fm_default "" "$decide_corpus"   # no SET at all: whatever the build ships
default_v="$(fsst_vectors fm_default)"
check "the shipped default drops FSST on a marginal corpus" "$default_v" "0"
check "and 0 still keeps it, so the default is a decision and not a rewrite" \
	"$([ "$kept" -gt 0 ] && echo yes || echo no)" "yes"

# --- 3. the invariant: content never changes ---------------------------------

load fm_c0  0   "$content_corpus"
load fm_c90 90  "$content_corpus"
load fm_cd  ""  "$content_corpus"

for t in fm_c0 fm_c90 fm_cd; do
	check "$t reads back exactly what the heap holds" \
		"$(q "SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM $t t;")" "$heap_hash"
done

# Nulls and empty strings survive the encoding switch, which is where a
# whole-chunk encoding change is most likely to go wrong.
for t in fm_c0 fm_c90; do
	check "$t preserves NULLs" \
		"$(q "SELECT count(*) FROM $t WHERE v IS NULL;")" \
		"$(q "SELECT count(*) FROM fm_h WHERE v IS NULL;")"
	check "$t preserves empty strings" \
		"$(q "SELECT count(*) FROM $t WHERE v = '';")" \
		"$(q "SELECT count(*) FROM fm_h WHERE v = '';")"
done

pgc_summary
