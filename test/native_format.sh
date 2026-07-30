#!/usr/bin/env bash
#
# On-disk format stability (#240, Phase 0).
#
# Two layers carry a version. The native data format stamps a major version into
# pgcolumnar.storage.format_version (PGCN v1); the physical metapage stamps
# versionMajor/versionMinor into block 0. Only the metapage version is checked on
# read -- ColumnarReadMetapage rejects a version it does not understand -- so that
# guard is the thing standing between a future, incompatible layout and a silent
# misread of old bytes. This suite pins both stamps and proves the guard fires.
#
# It asserts three things:
#   1. the stamped format identifiers are the values this build writes, so an
#      accidental bump goes red here rather than shipping unnoticed;
#   2. a metapage version this build does not understand is REJECTED with a clean
#      error and a surviving backend -- not misread as valid data. A test-only
#      hook (columnar_debug_set_metapage_version, bound here rather than shipped,
#      like the gap suite's advance hook) plants the bad version;
#   3. within a version, a diverse-typed table round-trips byte-for-byte against a
#      heap mirror, so "same version" genuinely means "same data back".
#
# Usage:  test/native_format.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# Bind the internal test hook (deliberately not in the shipped catalog): it
# overwrites the metapage version so we can confirm the read-side guard.
psql_run "CREATE FUNCTION pgcolumnar.debug_set_metapage_version(regclass, int, int)
  RETURNS void AS 'pgcolumnar', 'columnar_debug_set_metapage_version'
  LANGUAGE C;"

# Error text (stderr) of a failing statement; empty when it succeeds. Used to
# assert the guard rejects rather than misreads. ON_ERROR_STOP so a failure is an
# error, not a warning; stdout discarded so only the diagnostic is captured.
err_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -v ON_ERROR_STOP=1 -Atq -c "$1" 2>&1 >/dev/null
}
contains() { case "$1" in *"$2"*) echo yes;; *) echo no;; esac; }

# --- 1 & 3: stamped identifiers + diverse-type round-trip -------------------
# A pair with one column of every storage class that matters to the format:
# fixed-width, varlena text, numeric, float, bool, timestamp, and raw bytea.
make_pair "id bigint, a int, b text, c numeric(12,4), d float8, e bool, f timestamptz, g bytea"
load_pair "SELECT s,
                  (s * 7) % 1000,
                  md5(s::text),
                  (s * 1.25)::numeric(12,4),
                  s::float8 / 3,
                  (s % 2 = 0),
                  '2020-01-01'::timestamptz + (s || ' minutes')::interval,
                  decode(md5(s::text), 'hex')
           FROM generate_series(1, 5000) s"

sid="$(storage_id_of t_col)"
check "native format_version is 1" \
	"$(q "SELECT format_version FROM pgcolumnar.storage WHERE storage_id = $sid;")" "1"
check "native vector_length is 1024" \
	"$(q "SELECT vector_length FROM pgcolumnar.storage WHERE storage_id = $sid;")" "1024"

# Within a version, columnar must return exactly what heap returns for every type.
diff_query "diverse-type round-trip matches heap" "SELECT * FROM %T ORDER BY id"

# --- 2: unsupported metapage version is rejected, not misread ----------------
psql_run "CREATE TABLE bad (id int, v text) USING pgcolumnar;"
psql_run "INSERT INTO bad SELECT s, md5(s::text) FROM generate_series(1, 2000) s;"
check "table reads at the version this build wrote" "$(q 'SELECT count(*) FROM bad;')" "2000"

# Plant a major version this build does not understand.
psql_run "SELECT pgcolumnar.debug_set_metapage_version('bad', 99, 0);"

emsg="$(err_of 'SELECT count(*) FROM bad;')"
check "a read of the bumped version fails (not silently misread)" \
	"$([ -n "$emsg" ] && echo yes || echo no)" "yes"
check "the failure is the format-version guard" \
	"$(contains "$emsg" 'unsupported columnar format version')" "yes"
check "the error names the offending version" \
	"$(contains "$emsg" '99.0')" "yes"
# The whole point of a clean rejection: the backend is still there afterwards.
check "backend survives the rejection" "$(q 'SELECT 1;')" "1"

pgc_summary
