#!/usr/bin/env bash
#
# pgColumnar WAL discipline check.
#
# pgColumnar is an extension, so it must never change WAL behaviour: replay has to
# stay entirely core's business. An extension that defines a custom resource
# manager or a new record type couples the WAL stream to its own version, which
# breaks a standby or a recovery that does not have the same build loaded and
# turns an extension bug into an unrecoverable cluster.
#
# Two things are asserted here, both by reading the source rather than by running
# a server, because what matters is the shape of the code that emits WAL:
#
#  1. The only WAL this extension emits is core's own: log_newpage and
#     log_newpage_buffer, plus exactly one direct XLogInsert that writes core's
#     existing XLOG_SMGR_TRUNCATE record. No custom rmgr, no new record types.
#
#  2. That one direct site keeps RelationTruncate's crash-safety envelope, in
#     order: checkpoint delay set, critical section entered, record inserted,
#     WAL flushed, physical truncate, delay cleared, critical section left. Each
#     step is load-bearing. Flushing after the truncate, or truncating outside
#     the critical section, leaves a window where a checkpoint plus a crash can
#     produce block state that replay cannot reproduce.
#
# This is a source-shape test, so it will need updating when the code around it
# legitimately changes. That is the point: a change here should be deliberate and
# reviewed against what core does, not absorbed silently during a port.
#
# Usage:  test/wal_envelope.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# No cluster needed; pgc_setup is skipped deliberately. Provide the counters the
# shared check() helper expects.
PGC_CHECKS=0
PGC_FAIL=0
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"

echo "== pgColumnar WAL discipline check =="
echo "srcdir=$SRC"

# ---- 1. only core mechanisms emit WAL --------------------------------------

check "no custom resource manager is registered" \
	"$(grep -rlE 'RegisterCustomRmgr|RmgrData[[:space:]]+[A-Za-z_]+[[:space:]]*=' "$SRC" | wc -l)" "0"

check "no rmgr id other than the smgr truncate is used" \
	"$(grep -rhoE 'XLogInsert\([[:space:]]*RM_[A-Z_]+' "$SRC" | sort -u | grep -cv 'RM_SMGR_ID')" "0"

check "exactly one direct XLogInsert in the tree" \
	"$(grep -rc 'XLogInsert(' "$SRC"/*.c | awk -F: '{n += $2} END {print n}')" "1"

check "every other WAL emitter is a core full-page-image helper" \
	"$(grep -rhoE '\b(log_newpage|log_newpage_buffer|XLogInsert|GenericXLogFinish|XLogRegisterBuffer)\b' "$SRC"/*.c \
		| sort -u | grep -cvE '^(log_newpage|log_newpage_buffer|XLogInsert)$')" "0"

# ---- 2. the envelope around the one direct record ---------------------------

FN="$SRC/columnar_storage.c"
# line range of PgColumnarTruncateMainFork: its header to the next top-level function
start="$(grep -n '^PgColumnarTruncateMainFork(' "$FN" | cut -d: -f1)"
end="$(awk -v s="$start" 'NR > s && /^[A-Za-z_][A-Za-z0-9_]*\(/ {print NR; exit}' "$FN")"
[ -z "$end" ] && end="$(wc -l < "$FN")"

check "PgColumnarTruncateMainFork was found" "$([ -n "$start" ] && echo yes || echo no)" "yes"

# Line number of the first line inside the function that CONTAINS the literal
# string, or empty.
#
# Deliberately a substring test rather than a regex match. Every pattern below is
# literal C text, and passing one through awk's -v made the backslashes a string
# escape before the regex ever saw them: awk turns "\(" into "(", so
# 'XLogInsert\(RM_SMGR_ID' reached the matcher as 'XLogInsert(RM_SMGR_ID' with an
# unterminated group, and never matched. Whether that happened at all depended on
# the awk build, so this suite passed locally and failed on a runner with a
# different mawk, reporting three steps of the envelope as missing when the code
# was fine. index() has no escaping question to get wrong.
at() {
	awk -v s="$start" -v e="$end" -v pat="$1" \
		'NR >= s && NR <= e && index($0, pat) { print NR; exit }' "$FN"
}

delay_set="$(at 'delayChkptFlags |= DELAY_CHKPT_COMPLETE')"
crit_in="$(at 'START_CRIT_SECTION()')"
insert="$(at 'XLogInsert(RM_SMGR_ID')"
flush="$(at 'XLogFlush(')"
trunc="$(at 'COLUMNAR_SMGRTRUNCATE(')"
delay_clear="$(at 'delayChkptFlags &= ~DELAY_CHKPT_COMPLETE')"
crit_out="$(at 'END_CRIT_SECTION()')"

for v in delay_set crit_in insert flush trunc delay_clear crit_out; do
	eval "val=\$$v"
	check "envelope step present: $v" "$([ -n "$val" ] && echo yes || echo no)" "yes"
done

ordered() {  # ordered NAME A B -> A must come before B
	check "$1" "$([ -n "$2" ] && [ -n "$3" ] && [ "$2" -lt "$3" ] && echo yes || echo no)" "yes"
}

ordered "checkpoint delay is set before the critical section" "$delay_set" "$crit_in"
ordered "the record is written inside the critical section" "$crit_in" "$insert"
ordered "the WAL record precedes the flush" "$insert" "$flush"
ordered "the WAL is flushed before the physical truncate" "$flush" "$trunc"
ordered "the delay is cleared after the truncate" "$trunc" "$delay_clear"
ordered "the critical section ends last" "$delay_clear" "$crit_out"

# The record must stay scoped to the main fork. The visibility-map fork is indexed
# by row-number-derived blocks, independent of data blocks, so truncating it here
# would discard visibility state for rows that still exist.
check "the truncate record covers the main fork only" \
	"$(awk -v s="$start" -v e="$end" 'NR >= s && NR <= e && /SMGR_TRUNCATE_HEAP/ {n++} END {print n+0}' "$FN")" "1"
check "no fork mask other than the heap fork is used here" \
	"$(awk -v s="$start" -v e="$end" 'NR >= s && NR <= e && /SMGR_TRUNCATE_(VM|FSM|ALL)/ {n++} END {print n+0}' "$FN")" "0"

pgc_summary
