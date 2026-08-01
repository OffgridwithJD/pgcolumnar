#!/usr/bin/env bash
#
# pgColumnar online recluster ordered extent (#311).
#
# pgcolumnar.recluster reorders a relation under ShareUpdateExclusiveLock, so
# another session can insert while it works. Its output groups and the concurrent
# inserter's groups both take numbers above the ones it retires, and afterwards
# nothing about a group says which wrote it. That is why the rewrite reports the
# stripe ids it reserved, and why the run stops at the first live group it did
# not write.
#
# Two cheaper designs were rejected and this suite is what would catch either of
# them being adopted:
#
#   - marking through the highest live group number: counts the concurrent
#     inserter's group as ordered;
#   - marking by the row-number range the rewrite wrote: reservations interleave,
#     so a concurrent reservation lands strictly inside that range.
#
# Both over-claim, and over-claiming is the unsafe direction: it leaves a decayed
# table looking ordered, which costs every query against it.
#
# Usage:  test/recluster_extent.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

raw() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$1" 2>&1
}

ss() { raw "SELECT $1 FROM pgcolumnar.sort_status('t');"; }

# Large enough that the rewrite takes long enough for an insert to land inside
# it. Small groups so there are many of them to reorder.
BASE=1500000
raw "CREATE TABLE t (id int, k int, v text) USING pgcolumnar;" >/dev/null
raw "SELECT pgcolumnar.set_options('t', stripe_row_limit => 20000, chunk_group_row_limit => 2048);" >/dev/null
raw "INSERT INTO t SELECT g, ((g::bigint * 7919) % 100000)::int, 'v' || g FROM generate_series(1, $BASE) g;" >/dev/null

check "the table loaded" "$(raw 'SELECT count(*) FROM t;')" "$BASE"

# ------------------------------------------------------- the concurrent case

# Start the online rewrite, then insert from a second session while it runs.
raw "SELECT pgcolumnar.recluster('t', 'id', 'k');" >/tmp/pgc_recluster_out.$$ 2>&1 &
RECL_PID=$!

# Give the rewrite time to take its group locks and begin, then insert. The
# insert is small so it commits quickly and lands inside the rewrite's window.
sleep 2
INS_START=$(date +%s%N)
raw "INSERT INTO t SELECT g, ((g::bigint * 7919) % 100000)::int, 'v' || g FROM generate_series($((BASE + 1)), $((BASE + 50000))) g;" >/dev/null
INS_DONE=$(date +%s%N)

wait $RECL_PID
RECL_DONE=$(date +%s%N)

# The premise. If the insert committed after the rewrite had already finished,
# nothing concurrent happened and the rest of this suite proves nothing.
check "the insert committed while the rewrite was still running" \
	"$( [ "$INS_DONE" -lt "$RECL_DONE" ] && echo yes || echo no )" "yes"
check "the rewrite reported groups reclustered" \
	"$( [ "$(cat /tmp/pgc_recluster_out.$$)" -gt 0 ] 2>/dev/null && echo yes || echo no )" "yes"
rm -f /tmp/pgc_recluster_out.$$

check "every row is present afterwards" "$(raw 'SELECT count(*) FROM t;')" "$((BASE + 50000))"

SORTED="$(ss sorted_rows)"
APPENDED="$(ss appended_rows)"
echo "      base $BASE rows, 50000 inserted during the rewrite; sorted $SORTED, appended $APPENDED"

# The property. The rewrite reordered the rows that existed when it started. It
# cannot have ordered the ones inserted while it ran, so the run must not claim
# more rows than it began with. A mark taken from the highest live group number
# would claim them.
check "the run does not claim rows written during the rewrite" \
	"$( [ "$SORTED" -le "$BASE" ] && echo yes || echo no )" "yes"

# And the concurrent rows must be visible as decay rather than silently dropped
# from both counts.
check "the counts still cover every stored row" \
	"$(raw "SELECT (sorted_rows + appended_rows = (SELECT sum(rowcount) FROM pgcolumnar.stats('t')))::text
			FROM pgcolumnar.sort_status('t');")" "true"
check "the concurrent rows are reported as appended" \
	"$( [ "$APPENDED" -gt 0 ] && echo yes || echo no )" "yes"

# ---------------------------------------------------- the uncontended case

# With no concurrent writer the rewrite orders everything, so the run covers the
# whole relation. This is the control: without it, a mark that always came back
# empty would satisfy every assertion above.
raw "SELECT pgcolumnar.recluster('t', 'id', 'k');" >/dev/null
check "an uncontended rewrite claims the whole relation" \
	"$(ss appended_rows)" "0"
check "an uncontended rewrite counts every row as sorted" \
	"$(ss sorted_rows)" "$((BASE + 50000))"

pgc_summary
