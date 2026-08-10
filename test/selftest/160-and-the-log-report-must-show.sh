# ---- and the log report must show the cause, not just that there was one ----
check "premise: the log report is a function that can be fed a fixture" \
	"$(type -t pgc_start_log_report)" "function"

_lf="$(mktemp /tmp/pgc-537.XXXXXX)"; chmod 644 "$_lf"
{
	echo 'LOG:  starting PostgreSQL 19beta2'
	echo 'FATAL:  could not load library "/usr/local/pg19/lib/pgcolumnar.so": undefined symbol: get_relation_info_hook'
	echo 'LOG:  database system is shut down'
} > "$_lf"
_rep="$(pgc_start_log_report "$_lf" 2>&1)"
# At least once, not exactly once: the line legitimately appears twice, in the
# first-fatal block and again in the tail, and pinning it to one would fail on
# correct output.
check "the report names the symbol that was actually missing" \
	"$([ "$(grep -c 'undefined symbol: get_relation_info_hook' <<<"$_rep")" -ge 1 ] && echo yes || echo no)" \
	"yes"
check "and a log with no fatal line still reports rather than staying silent" \
	"$([ -n "$(printf 'LOG:  all fine\n' > "$_lf"; pgc_start_log_report "$_lf" 2>&1)" ] && echo yes || echo no)" \
	"yes"
rm -f "$_lf"

