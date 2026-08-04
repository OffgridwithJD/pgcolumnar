#!/usr/bin/env bash
#
# pgColumnar fetch-path interrupt guard (#212).
#
# pgcolumnar_fetch_row is reached once per candidate item pointer by
# _bt_check_unique() during a unique INSERT, and each call reads the row-group
# list out of the catalog. Before #212 that path had no CHECK_FOR_INTERRUPTS --
# the three checks already in columnar_reader.c are all on the scan/decode path,
# which a unique liveness check never enters -- so a unique INSERT whose conflict
# check did a lot of fetch work could not be cancelled and never noticed
# postmaster death. A backend spun there at 100% CPU for three days, outliving
# its cluster. The fix is one CHECK_FOR_INTERRUPTS at the top of the function.
#
# This check is structural, and on purpose. The behavioural proof -- with the
# guard the fetch loop cancels under a small statement_timeout (57014), without
# it the SAME statement runs to completion ignoring the timeout -- is real and is
# in the PR, but it is not a stable CI assertion: the loop only overruns a small
# timeout when the per-fetch catalog scan is paid enough times, the fixture that
# arranges that is O(dups^2) to build (each set-up delete pays the same scan), and
# the loop's exact length still shifts with build flags and catalog state enough
# to cross a 10 ms line either way. Pinning the guard's presence and placement is
# stable and is the actual regression: if someone removes it, this fails.
#
# Usage:  test/native_fetch_interrupt.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"

# The body of pgcolumnar_fetch_row, from its definition to its closing brace.
body="$(awk '/^pgcolumnar_fetch_row\(/{p=1} p{print} p&&/^}/{exit}' "$SRC/columnar_reader.c")"

# The guard has to be in this function, not merely in the file. The interrupt
# checks elsewhere in columnar_reader.c are on the scan/decode path, which the
# unique liveness fetch never enters, so counting the file would pass vacuously.
check "pgcolumnar_fetch_row carries an interrupt check" \
	"$(printf '%s\n' "$body" | grep -c 'CHECK_FOR_INTERRUPTS' | awk '{print ($1>=1)?"yes":"no"}')" \
	"yes"

# And it has to run before the per-fetch catalog read it guards, or the fetch
# does its work before ever reaching a cancellation point -- which is the state
# #212 was in. Assert the check precedes the PgColumnarReadRowGroupList call.
cfi_line="$(printf '%s\n' "$body" | grep -n 'CHECK_FOR_INTERRUPTS' | head -1 | cut -d: -f1)"
rgl_line="$(printf '%s\n' "$body" | grep -n 'PgColumnarReadRowGroupList' | head -1 | cut -d: -f1)"
check "the interrupt check precedes the per-fetch catalog read" \
	"$( [ -n "$cfi_line" ] && [ -n "$rgl_line" ] && [ "$cfi_line" -lt "$rgl_line" ] && echo yes || echo no )" \
	"yes"

pgc_summary
