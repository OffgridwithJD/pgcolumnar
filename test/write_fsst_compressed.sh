#!/usr/bin/env bash
#
# pgColumnar FSST selection against the block compressor.
#
# FSST is picked per vector by comparing its code stream to the raw length, but
# the bytes that reach disk are that stream after the configured codec has run.
# Those are different objectives and for some shapes they disagree: FSST turns
# highly repetitive text into high-entropy codes, which are smaller than the
# text and far less compressible than it was. Scored uncompressed FSST wins;
# stored compressed it loses. The guard that gates the attempt -- try FSST only
# when no other encoding shrank the vector -- selects for exactly that case,
# because a vector nothing could encode is usually one zstd handles well.
#
# Measured on main before the fix, 300,000 rows at the default zstd:3:
#
#     'sN'              352 kB written,  611 ms   against 184 kB, 370 ms without
#     md5 repeated 8x  6864 kB written, 4629 ms   against 6528 kB, 804 ms
#
# so 1.9x the space on one shape, and 5.8x the write time to produce a file 5%
# larger on the other. The fix runs both candidates through the codec over a
# bounded run of the chunk and keeps FSST only when it is genuinely smaller.
#
# Three things are asserted.
#
# 1. Values round-trip. Dropping the table changes which encoding every vector
#    of that chunk uses, so this is where the change can go wrong quietly, and
#    it is checked differentially against a heap mirror rather than against
#    expected constants.
#
# 2. The choice itself, read out of the chunk descriptor. This is the mechanism,
#    and it is what makes the file portable: sizes in kB depend on the zstd
#    build, but "which encoding did it pick" does not.
#
# 3. Nothing changes when there is no codec to compete with. With compression
#    off the encoded length IS the stored length, the original per-vector test
#    is already measuring the right thing, and the fix must not disturb it.
#
# Usage:  test/write_fsst_compressed.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

ROWS=${PGC_FSST_ROWS:-300000}

# The shapes that separate the two objectives. "short" is the one FSST enlarged
# most; "email" is the control -- FSST genuinely wins there after compression,
# so a fix that simply disabled FSST would fail on it and the check below is
# what stops this file passing against that.
short_expr="'s' || g"
email_expr="'user' || g || '@' || (g % 997) || '.example.com'"
hient_expr="repeat(md5(g::text), 8)"

# Everything here runs at the stock stripe and row-group sizes, because those
# are the sizes the behaviour was measured at and the decision moves with how
# much data it sees.
build() {  # table, expression, compression
	psql_run "DROP TABLE IF EXISTS $1;
		SET pgcolumnar.compression = $3;
		CREATE TABLE $1 (id int, v text) USING pgcolumnar;
		INSERT INTO $1 SELECT g, $2 FROM generate_series(1, $ROWS) g;" >/dev/null 2>&1
}

# How many vectors of the text column chose FSST.
#
# The descriptor is a 6-byte header -- version, a reserved byte, then the vector
# count as uint32 -- followed by that many 13-byte entries, followed by the
# chunk-shared symbol table. So entry i's type byte is at 6 + i*13, and the
# count comes from the header rather than from the length: the trailing table's
# size is not recoverable from the length alone, and reading past the entries
# would score the table's own bytes as encoding types. An earlier version of
# this file assumed a 13-byte stride from offset 0 and reported Gorilla and
# delta-of-delta on a text column, which is how the header was found.
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

# --- 1. values round-trip through both outcomes --------------------------------

# nulls, empty strings and values below the FSST minimum are mixed in, because
# the fix changes the encoding of every vector in a chunk at once and those are
# the values whose handling differs between encodings.
psql_run "DROP TABLE IF EXISTS fc_c; DROP TABLE IF EXISTS fc_h;
	CREATE TABLE fc_c (id int, v text) USING pgcolumnar;
	INSERT INTO fc_c SELECT g,
		CASE g % 11
			WHEN 0 THEN NULL
			WHEN 1 THEN ''
			WHEN 2 THEN 'x'
			ELSE 's' || g
		END
		FROM generate_series(1, $ROWS) g;
	CREATE TABLE fc_h (LIKE fc_c);
	INSERT INTO fc_h SELECT * FROM fc_c;" >/dev/null 2>&1

check "every value round-trips on a shape where FSST is dropped" \
	"$(q "SELECT count(*) FROM fc_c c JOIN fc_h h USING (id)
		WHERE c.v IS DISTINCT FROM h.v;" | tail -1)" "0"

check "the null and empty values survive" \
	"$(q "SELECT count(*) FILTER (WHERE v IS NULL) || '/' || count(*) FILTER (WHERE v = '')
		FROM fc_c;" | tail -1)" \
	"$(q "SELECT count(*) FILTER (WHERE v IS NULL) || '/' || count(*) FILTER (WHERE v = '')
		FROM fc_h;" | tail -1)"

build fc_e "$email_expr" zstd
psql_run "DROP TABLE IF EXISTS fc_eh; CREATE TABLE fc_eh (LIKE fc_e);
	INSERT INTO fc_eh SELECT * FROM fc_e;" >/dev/null 2>&1

check "every value round-trips on a shape where FSST is kept" \
	"$(q "SELECT count(*) FROM fc_e c JOIN fc_eh h USING (id)
		WHERE c.v IS DISTINCT FROM h.v;" | tail -1)" "0"

# --- 2. the choice goes the right way on each shape ----------------------------

# This is the check that fails against main. Both directions are asserted,
# because a fix that switched FSST off wholesale would pass the first half.
build fc_s "$short_expr" zstd
check "FSST is not chosen for text the codec compresses better alone" \
	"$(fsst_vectors fc_s)" "0"

build fc_hi "$hient_expr" zstd
check "FSST is not chosen where it cost 5.8x the write time for a larger file" \
	"$(fsst_vectors fc_hi)" "0"

# The control. FSST beats zstd-alone on this shape by 23% and must be kept, so
# this is what separates the fix from simply removing FSST.
check "FSST is still chosen where it genuinely wins after compression" \
	"$(awk -v n="$(fsst_vectors fc_e)" 'BEGIN { print (n > 0) ? "yes" : "no" }')" "yes"

# --- 3. no codec, no change ----------------------------------------------------

# With compression off the per-vector test already compares the stored length,
# so the decision must be left exactly as it was: FSST wins all three shapes
# uncompressed, including the two it loses under zstd.
for shape in short hient; do
	eval "expr=\$${shape}_expr"
	build "fc_n_$shape" "$expr" none
	check "with compression off FSST is still chosen for $shape" \
		"$(awk -v n="$(fsst_vectors "fc_n_$shape")" 'BEGIN { print (n > 0) ? "yes" : "no" }')" \
		"yes"
done

check "values round-trip with compression off" \
	"$(q "SELECT count(*) FROM fc_n_short a JOIN fc_s b USING (id)
		WHERE a.v IS DISTINCT FROM b.v;" | tail -1)" "0"

pgc_summary
