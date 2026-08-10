# ---- stand up a squatter on a port we will then hand to the suite -----------
SQ_DIR="$(mktemp -d /tmp/pgc-squatter.XXXXXX)"
# A port nothing is already listening on. Drawing blindly would let a collision
# turn into a silent SKIP, and since the self-test runs first in the matrix, a
# quiet skip means the guard stops being tested that run without anyone noticing.
_port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
SQ_PORT=0
for _try in $(seq 1 20); do
	# Inside the band portlib.sh carves below the ephemeral floor. The squatter
	# must hold its port for the whole test, which it cannot do reliably from
	# inside the range the kernel also allocates outbound connections from.
	_cand=$(( PGC_PORT_LO + RANDOM % (PGC_PORT_HI - PGC_PORT_LO) ))
	if _port_free "$_cand"; then
		SQ_PORT=$_cand
		break
	fi
done
if [ "$SQ_PORT" = 0 ]; then
	echo "SKIP  could not find a free port for the squatter cluster"
	rm -rf "$SQ_DIR"
	exit 0
fi
_runpg=(env)
if [ "$(id -u)" = "0" ]; then
	_runpg=(runuser -u postgres --)
	chown -R postgres "$SQ_DIR"
fi
chmod 711 "$SQ_DIR"

"${_runpg[@]}" env PATH="$_bindir:$PATH" \
	initdb -D "$SQ_DIR/data" -A trust >/dev/null 2>&1
echo "port=$SQ_PORT" >> "$SQ_DIR/data/postgresql.conf"
echo "listen_addresses='127.0.0.1'" >> "$SQ_DIR/data/postgresql.conf"
"${_runpg[@]}" env PATH="$_bindir:$PATH" \
	pg_ctl -D "$SQ_DIR/data" -l "$SQ_DIR/log" -w start >/dev/null 2>&1

squatter_down() {
	"${_runpg[@]}" env PATH="$_bindir:$PATH" \
		pg_ctl -D "$SQ_DIR/data" -m immediate -w stop >/dev/null 2>&1 || true
	rm -rf "$SQ_DIR"
}
# Arm cleanup immediately: pgc_setup can exit 1 on its own (that is the behaviour
# under test), and until it installs its trap this is the only thing that would
# stop the squatter.
trap squatter_down EXIT

sq_datadir() {
	env PATH="$_bindir:$PATH" psql -h 127.0.0.1 -p "$SQ_PORT" -U postgres \
		-d postgres -At -c 'SHOW data_directory' 2>/dev/null
}

if [ -z "$(sq_datadir)" ]; then
	echo "SKIP  could not stand up a squatter cluster to test against"
	squatter_down
	exit 0
fi
echo "-- squatter listening on $SQ_PORT ($(sq_datadir))"

