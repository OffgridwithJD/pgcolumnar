#!/usr/bin/env bash
#
# pgColumnar #405 step 2: fold-path payload deferral, with the work MEASURED.
#
# On the batch-fold path, non-key columns used to be fetch_att'd for every
# non-skipped row BEFORE the scan-key check; the corrected #405 record measured
# that cost flat in selectivity. The fold now defers payload materialization
# until a row passes its keys, gated adaptively per group: defer unless the
# survival observed so far exceeds half (the first group is optimistic), so
# high-survival shapes keep the eager single pass that is cheaper for them.
#
# The counter is the plan's stable post-key site: on a deferred group,
# Columnar Fold Payload Loads equals surviving rows x payload values fetched -
# never candidates - which is the work-done identity the original Step 2
# failed to have and the retraction was caught by. The gate is observable as
# Columnar Fold Deferred Groups: X of Y.
#
# Oracles: the row path (vector agg off) and a heap mirror; the fold node is
# pinned via the post-#602 ANALYZE line, which reports the fold that RAN.
#
# Usage:  test/native_fold_deferral.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

GUC="SET pgcolumnar.enable_ungrouped_vector_agg = on;"
NP=4							# payload columns
ROWS=120000

sq() {	# scalar under this suite's GUC; tail -1 drops the SET tag
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$GUC $1" 2>/dev/null | tail -1
}
explain_line() {	# explain_line <label> <query>
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -At -c "$GUC EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY OFF) $2" 2>/dev/null \
		| grep "$1" | head -1 | sed 's/^ *//'
}

psql_run "CREATE TABLE fd_t (q int4, p1 float8, p2 float8, p3 float8, p4 float8) USING pgcolumnar;"
psql_run "SELECT pgcolumnar.set_options('fd_t', stripe_row_limit => 20000);"
psql_run "INSERT INTO fd_t SELECT 1 + g % 100, g, g*2, g*3, g*4 FROM generate_series(1,$ROWS) g;"
psql_run "CREATE TABLE fd_heap AS SELECT * FROM fd_t;"

# plain aggregate tlist entries: an expression OVER aggregates disqualifies
# the vectorized path entirely (the #602 tlist trap) and would row-path this
QSEL="SELECT sum(p1), sum(p2), sum(p3), sum(p4) FROM fd_t WHERE q <= 1"
QHI="SELECT sum(p1), sum(p2), sum(p3), sum(p4) FROM fd_t WHERE q <= 99"

# ---- premises ---------------------------------------------------------------
check_text "premise: the selective query takes the fold (ANALYZE, post-#602)" \
	"$(explain_line 'Columnar Batch Fold' "$QSEL" | grep -oE 'yes|no')" "yes"
# NGROUPS, never GROUPS: bash's builtin GROUPS (the caller's group-id array)
# silently IGNORES assignments, so a suite variable of that name reads as the
# runner's primary gid forever -- which burned two hours and a wrongly filed
# issue (#616) before cat -A, stream separation, and a single-line rewrite all
# failed to explain a value no assignment could change.
NGROUPS="$(q "SELECT count(*) FROM pgcolumnar.stats('fd_t'::regclass)")"
SURV="$(q "SELECT count(*) FROM fd_t WHERE q <= 1")"
CAND="$(q "SELECT count(*) FROM fd_t")"
check "premise: the selective predicate is genuinely selective (<= 2%)" \
	"$([ $((SURV * 50)) -le "$CAND" ] && echo yes)" "yes"

# ---- correctness: three-way agreement --------------------------------------
FOLD_SEL="$(sq "$QSEL;")"
ROW_SEL="$(env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres -d "$PGC_DB" -At \
	-c "SET pgcolumnar.enable_ungrouped_vector_agg = off" -c "$QSEL" 2>/dev/null | tail -1)"
HEAP_SEL="$(q "SELECT sum(p1), sum(p2), sum(p3), sum(p4) FROM fd_heap WHERE q <= 1")"
check "deferred fold == row path (selective)" "$FOLD_SEL" "$ROW_SEL"
check "deferred fold == heap mirror (selective)" "$FOLD_SEL" "$HEAP_SEL"
FOLD_HI="$(sq "$QHI;")"
HEAP_HI="$(q "SELECT sum(p1), sum(p2), sum(p3), sum(p4) FROM fd_heap WHERE q <= 99")"
check "fold == heap mirror (high survival)" "$FOLD_HI" "$HEAP_HI"

# ---- the work-done identity -------------------------------------------------
LOADS_LINE="$(explain_line 'Columnar Fold Payload Loads' "$QSEL")"
DEFER_LINE="$(explain_line 'Columnar Fold Deferred Groups' "$QSEL")"
check "the loads counter exists under ANALYZE" \
	"$([ -n "$LOADS_LINE" ] && echo yes)" "yes"
LOADS="$(grep -oE '[0-9]+$' <<<"$LOADS_LINE")"
check "premise: the predicate has survivors (the identity is not 0 == 0)" \
	"$([ "${SURV:-0}" -gt 0 ] && echo yes)" "yes"
check_num "deferred: loads == survivors x payload width (the identity)" \
	"${LOADS:-0}" "$((SURV * NP))"
# cross-instrument premise: the EXPLAIN's own group total must agree with the
# stats() catalog count, and both must be plural -- whichever side misreports,
# this names it with the numbers in hand.
DEFER_Y="$(grep -oE 'of [0-9]+' <<<"$DEFER_LINE" | grep -oE '[0-9]+')"
check_num "premise: EXPLAIN group total == stats() group count" \
	"${DEFER_Y:-0}" "${NGROUPS:-0}"
check "premise: the fixture spans several groups" \
	"$([ "${DEFER_Y:-0}" -ge 3 ] 2>/dev/null && echo yes)" "yes"
check "deferred: every group deferred at 1% survival" \
	"$(grep -oE '[0-9]+ of [0-9]+' <<<"$DEFER_LINE")" "$DEFER_Y of $DEFER_Y"

# ---- the adaptive gate declines high survival -------------------------------
DEFER_HI_N="$(explain_line 'Columnar Fold Deferred Groups' "$QHI" | grep -oE '[0-9]+ of' | grep -oE '[0-9]+')"
check_num "adaptive: only the optimistic first group deferred at 99% survival" \
	"${DEFER_HI_N:-0}" "1"
LOADS_HI="$(grep -oE '[0-9]+$' <<<"$(explain_line 'Columnar Fold Payload Loads' "$QHI")")"
SURV_HI="$(q "SELECT count(*) FROM fd_t WHERE q <= 99")"
check "adaptive: eager groups load more than survivors alone (work measured, not assumed)" \
	"$([ "${LOADS_HI:-0}" -gt $((SURV_HI * NP * 99 / 100)) ] && echo yes)" "yes"

pgc_summary
