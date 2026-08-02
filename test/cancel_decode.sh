#!/usr/bin/env bash
#
# pgColumnar interrupt correctness on the decode path (#254).
#
# The question this answers is which query a missing CHECK_FOR_INTERRUPTS in the
# columnar decode path actually breaks. For most queries the answer is none: the
# executor checks interrupts on its own loops, so an ordinary scan stays
# cancellable even with every interrupt check removed from this extension. That
# is why native_cancel.sh cannot detect such a regression, and why removing its
# skip would not have helped.
#
# The shape that does depend on the extension's own checks is one large row
# group. Loading and decoding a row group happens inside a single call into the
# access method, so no executor loop runs for its duration. The uninterruptible
# window is therefore the decode time of one group, and stripe_row_limit is a
# user-settable option, so that window is as long as a user makes it.
#
# Measured on PostgreSQL 17, cancel latency against a 50 ms statement_timeout:
#
#            row group           checks present   all checks removed
#            4M rows, 3 cols           62 ms            179 ms
#            12M rows, 3 cols          64 ms            526 ms
#            4M rows, 8 cols           66 ms            584 ms
#
# With the checks, latency is flat in the size of the group. Without them it
# tracks the group's decode time. That flatness is what this suite asserts.
#
# The assertion is a ratio between two cancel latencies measured back to back on
# the same machine in the same run, not a ratio against a data-volume baseline.
# Both readings move together under load, which is what makes it safe on shared
# hardware where the wall-clock ratio suites are not. It carries no PGC_SKIP_TIMING
# guard for that reason.
#
# Usage:  test/cancel_decode.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# Wide rows, so one group takes long enough to decode that the window is
# unmistakable, without needing a row count that is slow to load.
DDL="a int, b int, c text, d text, e text, f text, h text, i text"
SEL="g, g %% 1000, 'r'||g, 'r'||g, 'r'||g, 'r'||g, 'r'||g, 'r'||g"
ROWS=4000000

raw() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$1" 2>&1
}

build() {			# build(table, stripe_row_limit)
	raw "CREATE TABLE $1 ($DDL) USING pgcolumnar;" >/dev/null
	raw "SELECT pgcolumnar.set_options('$1', stripe_row_limit => $2, chunk_group_row_limit => 10000);" >/dev/null
	raw "INSERT INTO $1 SELECT $(printf "$SEL") FROM generate_series(1, $ROWS) g;" >/dev/null
}

# The predicate matches nothing and is not pushed down, so the scan decodes the
# whole relation and hands no tuple to the executor while doing it.
#
# Every column is named on purpose. The reader decodes only the columns a query
# references (#338), so a predicate over one column would leave the other seven
# unread and the scan would finish before there was anything to cancel -- the
# premise check below would then fail, correctly, because nothing was being
# tested. Each conjunct is an expression rather than a comparison to a constant
# so that none of them is pushed down to the zone maps and used to skip groups.
QUERY() { echo "SELECT count(*) FROM $1 WHERE (a %% 7) = 999 AND (b %% 7) = 999 AND length(c) < 0 AND length(d) < 0 AND length(e) < 0 AND length(f) < 0 AND length(h) < 0 AND length(i) < 0"; }

# Cancel latency: milliseconds from issuing the statement to the error coming
# back. Echoes "FAILED" when the statement was not cancelled at all.
#
# The best of three readings, not the average. Scheduling noise on a shared
# runner only ever adds latency, so the minimum is the reading least polluted by
# it, and a missing interrupt check raises the floor rather than the spread. An
# average would let one descheduled run widen the ratio on its own.
cancel_ms() {
	local t="$1" c d out best= ms i
	for i in 1 2 3; do
		c=$(date +%s%N)
		out="$(raw "SET statement_timeout = 100; $(printf "$(QUERY "$t")")")"
		d=$(date +%s%N)
		echo "$out" | grep -qi "canceling statement" || { echo FAILED; return; }
		ms=$(( (d - c) / 1000000 ))
		[ -z "$best" ] || [ "$ms" -lt "$best" ] && best="$ms"
	done
	echo "$best"
}

groups() { raw "SELECT count(*) FROM pgcolumnar.stats('$1');"; }

build many 20000            # many small groups
build one   40000000        # a single group holding everything

check "the many-group table has many groups" \
	"$( [ "$(groups many)" -gt 50 ] && echo yes || echo no )" "yes"
check "the one-group table has exactly one group" "$(groups one)" "1"

# The scan must outlast the timeout, or nothing is being tested. Measured
# uncancelled, with no timeout set.
t0=$(date +%s%N); raw "$(printf "$(QUERY one)");" >/dev/null; t1=$(date +%s%N)
FULL=$(( (t1 - t0) / 1000000 ))
check "the scan outlasts the timeout, so a cancel is possible" \
	"$( [ "$FULL" -gt 300 ] && echo yes || echo no )" "yes"

MANY_MS="$(cancel_ms many)"
ONE_MS="$(cancel_ms one)"

echo "      uncancelled scan ${FULL} ms; cancel latency: many groups ${MANY_MS} ms, one group ${ONE_MS} ms"

check "a scan of many small groups is cancelled" \
	"$( [ "$MANY_MS" != FAILED ] && echo yes || echo no )" "yes"
check "a scan of one large group is cancelled" \
	"$( [ "$ONE_MS" != FAILED ] && echo yes || echo no )" "yes"

# The property. Decoding one large group must not make a statement wait longer
# for its cancel than decoding many small ones. Three times, measured back to
# back on the same machine, is loose enough to absorb scheduling noise and far
# below the factor a missing check produces.
check "cancel latency does not grow with row group size" \
	"$( [ "$ONE_MS" != FAILED ] && [ "$MANY_MS" != FAILED ] \
		&& [ "$ONE_MS" -le $((MANY_MS * 3 + 50)) ] && echo yes || echo no )" "yes"

# An absolute ceiling as well, so the ratio cannot be satisfied by both readings
# drifting upward together.
check "the cancel arrives within a generous absolute bound" \
	"$( [ "$ONE_MS" != FAILED ] && [ "$ONE_MS" -lt 2000 ] && echo yes || echo no )" "yes"

# The backend survived the cancel and the session still works, so what was
# interrupted was the statement and not the connection.
check "the session is usable after the cancel" "$(raw "SELECT 1;")" "1"
check "the table still reads correctly after the cancel" \
	"$(raw "SELECT count(*) FROM one;")" "$ROWS"
check "the cancelled predicate returns its true answer when allowed to finish" \
	"$(raw "$(printf "$(QUERY one)");")" "0"

pgc_summary
