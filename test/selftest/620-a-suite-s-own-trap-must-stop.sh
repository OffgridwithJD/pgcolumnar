# ---- a suite's own EXIT trap must still stop its cluster ---------------------
#
# pgc_setup arms `trap pgc_on_exit EXIT`, and pgc_on_exit is what stops the
# server and removes the workdir (pgc_teardown) and gives a suite that died its
# accounting (#1233). Bash keeps ONE EXIT trap, so a suite that arms its own
# after pgc_setup replaces all of that unless its handler calls back into it.
# objstore_module.sh found this first and chains; native_upgrade_converge.sh did
# not: its `trap cleanup EXIT` restored the staged fixtures and nothing else, so
# every run left a PostgreSQL server listening and its workdir in /tmp. Measured
# on PG17: each of five converge runs left exactly one server, started within a
# second of the run's last log line.
#
# READ FROM THE SUITES' OWN TEXT, the one place the rule can be checked for all
# of them at once; driving each suite to see whether its server outlives it would
# take every suite's full run. The detector is driven below on suites written for
# it, so a detector that flags nothing cannot pass the population arm. Captured
# text reaches grep and awk as here-strings, never through a pipe (part 080).

_te_offenders() {
	local f code h fn
	for f in "$@"; do
		code="$(sed 's/#.*//' "$f")"
		grep -qE '^[[:space:]]*pgc_setup( |$)' <<<"$code" || continue
		while IFS= read -r h; do
			case "$h" in *pgc_on_exit*|*pgc_teardown*) continue ;; esac
			# The handler's own body: one line for a one-line function, else up to
			# its closing brace -- never on into the next function's.
			fn="$(awk -v h="$h" '
				!on && index($0, h "()") == 1 && $0 ~ /\{.*\}[[:space:]]*$/ { print; exit }
				!on && index($0, h "()") == 1 { on = 1 }
				on { print }
				on && /^}/ { exit }' <<<"$code")"
			grep -qE 'pgc_on_exit|pgc_teardown' <<<"$fn" && continue
			basename "$f"
			break
		done < <(sed -nE "s/^[[:space:]]*trap[[:space:]]+(['\"]([^'\"]*)['\"]|([A-Za-z_][A-Za-z_0-9]*))[[:space:]]+(.*[[:space:]])?EXIT([[:space:]].*)?$/\2\3/p" <<<"$code")
	done
}

check_num "premise: pgc_setup still arms the trap this part protects" \
	"$(sed -n '/^pgc_setup()/,/^}/p' "$PGC_TESTDIR/lib.sh" | sed 's/#.*//' | grep -c 'trap pgc_on_exit EXIT')" "1"

_te_tmp="$(mktemp -d)"
_te_mk() { printf '%b\n' "$2" > "$_te_tmp/$1.sh"; }
_te_mk replaces 'pgc_setup x\ncleanup() {\n\trm -f y\n}\ntrap cleanup EXIT'
_te_mk replaces_on_signals 'pgc_setup x\ncleanup() {\n\trm -f y\n}\ntrap cleanup EXIT INT TERM'
_te_mk names_it_in_a_comment 'pgc_setup x\ncleanup() {\n\trm -f y # then pgc_teardown\n}\ntrap cleanup EXIT'
_te_mk next_function_has_it 'pgc_setup x\nt() { a; }\nother() {\n\tpgc_teardown\n}\ntrap t EXIT'
_te_mk chains_the_wrapper 'pgc_setup x\ncleanup() {\n\tpgc_on_exit\n\trm -f y\n}\ntrap cleanup EXIT'
_te_mk chains_the_teardown 'pgc_setup x\nt() { a; pgc_teardown; }\ntrap t EXIT INT TERM'
_te_mk chains_in_quotes "pgc_setup x\ntrap 'restore; pgc_on_exit' EXIT"
_te_mk no_setup 'cleanup() {\n\trm -f y\n}\ntrap cleanup EXIT'

check_text "the detector flags a handler that reaches neither pgc_on_exit nor pgc_teardown" \
	"$(_te_offenders "$_te_tmp/replaces.sh" "$_te_tmp/replaces_on_signals.sh")" \
	"$(printf 'replaces.sh\nreplaces_on_signals.sh')"
check_text "and is not satisfied by the name in a comment or in the next function" \
	"$(_te_offenders "$_te_tmp/names_it_in_a_comment.sh" "$_te_tmp/next_function_has_it.sh")" \
	"$(printf 'names_it_in_a_comment.sh\nnext_function_has_it.sh')"
check_text "and passes a handler that chains either, and a suite without pgc_setup" \
	"[$(_te_offenders "$_te_tmp/chains_the_wrapper.sh" "$_te_tmp/chains_the_teardown.sh" \
		"$_te_tmp/chains_in_quotes.sh" "$_te_tmp/no_setup.sh")]" "[]"
rm -rf "$_te_tmp"

check_text "no suite's own EXIT trap leaves its cluster running" \
	"[$(_te_offenders "$PGC_TESTDIR"/*.sh | tr '\n' ' ')]" "[]"

unset -f _te_offenders _te_mk
