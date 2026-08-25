# ---- a suite connecting by unix socket must SAY where the socket is ---------
#
# Where a server puts its unix socket is a property of how PostgreSQL was BUILT,
# not of the suite connecting to it. A source build defaults to /tmp; the Debian
# and PGDG packages compile in /var/run/postgresql. So a suite that runs
# `psql -h /tmp` without setting unix_socket_directories works on one kind of
# build and fails on the other, with `connection to server on socket
# "/tmp/.s.PGSQL.NNNN" failed`.
#
# That is not hypothetical and it is not cosmetic. extension_upgrade.sh did
# exactly this, and the failure arrives dressed as a product failure: every psql
# returns an error string, the row count is not 1000, and the suite reports
# "old install did not store rows". Developers never saw it because they run
# against source builds, and CI never saw it because #741 is the issue that CI
# had never run this suite at all. The first CI run after wiring it up failed
# here.
#
# Most suites are immune for a different reason: lib.sh connects over TCP
# (-h 127.0.0.1, with listen_addresses set to match), so the socket location
# never arises. This check is about the ones that carry their own harness.
#
# The discriminator matches a -h argument that is a PATH or a VARIABLE, quoted or
# not, on a non-comment line. Every part of that earns its place:
#
#   -h /tmp          extension_upgrade
#   -h '$WORKDIR'    concurrency, unique_conc, update_conc  (single quotes)
#   -h 127.0.0.1     NOT a socket user, and must stay out
#
# The first version asked only for `-h /` and found ONE suite. It missed three,
# because the spelling that actually dominates the tree is the quoted variable.
# A population of one that looks complete is the thing the premise below cannot
# see, so the population is printed beside the claim (#741 review).
#
# Comment lines are excluded deliberately, not incidentally: fuzz_parquet carries
# `-h "$PGC_WORKDIR"` in a comment describing what an EARLIER version did, and it
# connects over TCP. Matching it would put a TCP suite in the population and
# report a defect that does not exist -- the too-loose direction, which costs an
# afternoon chasing nothing.

_sock_users=""
_sock_missing=""
for _f in "$TESTDIR"/*.sh; do
	grep -qE "^[^#]*-h ['\"]?[/\$]" "$_f" || continue
	_b="$(basename "$_f" .sh)"
	_sock_users="$_sock_users $_b"
	grep -q 'unix_socket_directories' "$_f" || _sock_missing="$_sock_missing $_b"
done

echo "-- suites connecting by socket path:$(printf '%s' "${_sock_users:- none}")"

# Without this the loop below can pass by finding nothing to check, which is the
# same as not running. See the population rule in CONTEXT.md.
check "premise: at least one suite connects by a socket path, so this is not vacuous" \
	"$([ -n "$_sock_users" ] && echo yes || echo no)" "yes"

# And the discriminator must not simply match everything: the TCP suites must NOT
# be in the population, or "they all set it" would be meaningless.
# Three named TCP users, not one: lib.sh (every ordinary suite), fuzz_parquet
# (whose comment names the old socket spelling) and isolation (PGHOST=127.0.0.1).
# If any of them enters the population the discriminator has gone too loose.
_sock_tcp=""
for _t in lib fuzz_parquet isolation; do
	grep -qE "^[^#]*-h ['\"]?[/\$]" "$TESTDIR/$_t.sh" 2>/dev/null && _sock_tcp="$_sock_tcp $_t"
done
check "premise: no TCP suite is counted as a socket user" \
	"$(printf '%s' "$_sock_tcp" | sed 's/^ //')" ""

check "every suite that connects by socket path sets unix_socket_directories" \
	"$(printf '%s' "$_sock_missing" | sed 's/^ //')" ""
