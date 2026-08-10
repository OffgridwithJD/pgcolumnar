# ---- a cluster that will not start must report WHY (#537) -------------------
#
# The failure path printed eight identical retry lines and a verdict naming none
# of the eight causes, while pg_ctl -l had been writing the reason to server.log
# the whole time. The workdir is removed on exit, so the evidence was gone by the
# time anyone read the verdict.
#
# These are text decisions, so they are tested without standing anything up, for
# the same reason bench_guards exists (#465).

check "premise: the harness exposes its fatal pattern to be judged" \
	"$(type -t pgc_fatal_pattern)" "function"

_m() { grep -cE "$(pgc_fatal_pattern)" <<<"$1"; }

check "the fatal pattern matches a library that will not load" \
	"$(_m 'FATAL:  could not load library "/usr/local/pg19/lib/pgcolumnar.so": undefined symbol: get_relation_info_hook')" \
	"1"
check "and still matches an AddressSanitizer report" \
	"$(_m '==1==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x1')" "1"
check "and still matches a PANIC" \
	"$(_m 'PANIC:  could not write to file')" "1"
check "and still matches a signal death" \
	"$(_m 'server process was terminated by signal 11: Segmentation fault')" "1"
check "but not a routine statement error" \
	"$(_m 'ERROR:  division by zero')" "0"
check "nor an ordinary log line" \
	"$(_m 'LOG:  database system is ready to accept connections')" "0"

