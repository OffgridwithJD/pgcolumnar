# ---- a failing suite must surface the FIRST fatal event, not just the tail ---
#
# On failure pgc_summary tails 40 lines of the server log. That is the right
# thing to show when one statement failed, and the wrong thing after a crash:
# the first fatal event is at the TOP of the log and everything below it is
# aftermath, so the tail shows recovery messages and not the cause.
#
# Measured, on a deliberate heap overrun run through this harness under the
# pg18_san build: 67 AddressSanitizer reports in an 8,777-line log, the first at
# line 12. The tail showed lines 8738-8777 -- 8,765 lines of crash recovery below
# the answer -- and then pgc_teardown removed the file, so there was nowhere left
# to look. The suite reported 123 failures and not one word about why.
#
# This stands that up without needing a sanitizer build: a fatal-looking line,
# then enough filler to push it past the tail window, then a real failure.
_fatal_marker="AddressSanitizer: heap-buffer-overflow PGCSELFTEST"
_sub="$(mktemp /tmp/pgcolumnar-subsuite.XXXXXX.sh)"
cat > "$_sub" <<SUBEOF
#!/bin/bash
set -uo pipefail
. "$PGC_SRCDIR/test/lib.sh"
pgc_setup "\$1"
# RAISE LOG writes to the server log at a level the default log_min_messages
# keeps, which is how this gets a line into the log without a crash.
psql_run "DO \\\$\\\$ BEGIN RAISE LOG '$_fatal_marker'; END \\\$\\\$;"
psql_run "DO \\\$\\\$ BEGIN FOR i IN 1..60 LOOP RAISE LOG 'selftest filler %', i; END LOOP; END \\\$\\\$;"
check "deliberate failure so the summary runs" "got" "want"
pgc_summary
SUBEOF
chmod +x "$_sub"
# PGC_SKIP_BUILD: this sub-suite is testing the summary, not the build, and the
# .so was already verified above.
_subout="$(PGC_SKIP_BUILD=1 bash "$_sub" "$PGC_PG_CONFIG" 2>&1)"
rm -f "$_sub"

# The premise: the sub-suite must actually have failed, and its filler must
# actually have pushed the marker out of the tail window. Without both, the
# check below passes for the wrong reason.
check "premise: the sub-suite failed, so its summary ran" \
	"$(grep -cE ': FAILED$' <<<"$_subout")" "1"
check "premise: the 40-line tail is filler, not the marker" \
	"$(sed -n '/---- server log tail ----/,$p' <<<"$_subout" | grep -c "$_fatal_marker")" "0"

# Scoped to the new section rather than to the whole output, and asked as
# "is it there" rather than "how many times". PostgreSQL emits a STATEMENT: line
# beside the message, so the marker legitimately appears twice; an exact count
# would be asserting a detail of PostgreSQL's logging and would go red the day
# that changed, without anything being wrong.
check "a failing suite names the first fatal event in its log" \
	"$([ "$(sed -n '/---- first fatal events/,/---- server log tail ----/p' <<<"$_subout" \
		| grep -c "$_fatal_marker")" -ge 1 ] && echo yes || echo no)" \
	"yes"

