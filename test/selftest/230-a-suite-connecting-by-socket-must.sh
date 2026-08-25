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

_sock_users=""
_sock_missing=""
for _f in "$TESTDIR"/*.sh; do
	# A filesystem path, not 127.0.0.1. `-h /` is the discriminator.
	grep -qE '\-h /' "$_f" || continue
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
check "premise: a TCP suite is not counted as a socket user" \
	"$(grep -qE '\-h /' "$TESTDIR/lib.sh" && echo counted || echo not-counted)" "not-counted"

check "every suite that connects by socket path sets unix_socket_directories" \
	"$(printf '%s' "$_sock_missing" | sed 's/^ //')" ""
