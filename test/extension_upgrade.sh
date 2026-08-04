#!/usr/bin/env bash
#
# pgColumnar extension-upgrade gate (#382).
#
# The failure this exists to catch is invisible to a build and to CI. Every SQL-callable
# function records its C link name in pg_proc.prosrc at CREATE EXTENSION time. Rename a
# link name in C and the old rows point at a symbol the new library no longer exports.
# Replacing only the shared library, which is exactly what a package upgrade does, then
# leaves the extension inert rather than degraded: reading an existing columnar table
# fails with "could not find function columnar_handler", and so does creating one.
#
# It compiles, it links, every suite passes on a fresh install, and every existing
# install is broken. That combination is why this needs its own gate.
#
# Not in run_all_versions.sh, for the same reason pg_upgrade.sh is not: the matrix builds
# one tree per invocation and this needs two builds of the extension at once. It is a
# second gate beside the matrix, run explicitly.
#
# Usage:
#   test/extension_upgrade.sh [PG_CONFIG] [OLD_REF]
#
# OLD_REF defaults to the previous release, and may be any ref that still has the old
# link names. The old build is made in a throwaway clone, so the working tree is never
# checked out from under the caller.
set -uo pipefail

PG_CONFIG=${1:-pg_config}
OLD_REF=${2:-v1.0-alpha}
SRCDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The cluster binds a port, so it must come from the band portlib.sh carves BELOW the
# kernel's ephemeral range, probed rather than assumed free. Picking out of the
# ephemeral range means the kernel can hand the same port to something else between
# the choice and the bind. harness_selftest enforces this, and caught it here.
. "$(dirname "${BASH_SOURCE[0]}")/portlib.sh"

command -v "$PG_CONFIG" >/dev/null 2>&1 || { echo "FATAL: $PG_CONFIG not found"; exit 1; }
BINDIR=$($PG_CONFIG --bindir)
SHAREDIR=$($PG_CONFIG --sharedir)
PGMAJ=$($PG_CONFIG --version | grep -oE '[0-9]+' | head -1)

TMP=$(mktemp -d /tmp/pgc-extupg.XXXXXX)
DATA=$TMP/data
PORT=$(pgc_pick_free_port "$PGC_AUX_PORT_LO" "$PGC_AUX_PORT_HI" "$$")
LOG=$TMP/server.log
fail=0

cleanup () {
	runuser -u postgres -- "$BINDIR/pg_ctl" -D "$DATA" -w stop >/dev/null 2>&1
	rm -rf "$TMP"
}
trap cleanup EXIT

runpg () { runuser -u postgres -- "$@"; }
q () { runpg "$BINDIR/psql" -h /tmp -p "$PORT" -d extupg -X -Atc "$1" 2>&1; }

echo "== extension_upgrade: PG$PGMAJ, old ref $OLD_REF"

# ---- 1. build and install the old extension, from a throwaway clone ------------------
# A missing ref must fail, not skip. This gate is invoked deliberately, and a skip that
# exits 0 would let it go inert the moment someone clones without tags. That is the same
# shape as the bug it exists to catch: everything green, nothing checked.
if ! git -C "$SRCDIR" rev-parse --verify -q "$OLD_REF^{commit}" >/dev/null 2>&1; then
	echo "  FAIL  $OLD_REF is not present. Fetch tags, or pass an explicit ref:"
	echo "        git fetch --tags && test/extension_upgrade.sh $PG_CONFIG <ref>"
	exit 1
fi
git clone -q --shared "$SRCDIR" "$TMP/old" || { echo "FATAL: clone failed"; exit 1; }
git -C "$TMP/old" checkout -q --detach "$OLD_REF" || { echo "FATAL: checkout $OLD_REF failed"; exit 1; }
make -C "$TMP/old" PG_CONFIG="$PG_CONFIG" clean >/dev/null 2>&1
make -C "$TMP/old" PG_CONFIG="$PG_CONFIG" -j"$(nproc)" >"$TMP/build_old.log" 2>&1 \
	|| { echo "FAIL  old build"; tail -20 "$TMP/build_old.log"; exit 1; }
make -C "$TMP/old" PG_CONFIG="$PG_CONFIG" install >/dev/null 2>&1 \
	|| { echo "FAIL  old install"; exit 1; }

chown -R postgres "$TMP" 2>/dev/null
runpg "$BINDIR/initdb" -D "$DATA" --locale=C -U postgres >/dev/null 2>&1 \
	|| { echo "FAIL  initdb"; exit 1; }
{
	echo "shared_preload_libraries='pgcolumnar'"
	echo "port=$PORT"
} >> "$DATA/postgresql.conf"
runpg "$BINDIR/pg_ctl" -D "$DATA" -l "$LOG" -w start >/dev/null 2>&1 \
	|| { echo "FAIL  start"; tail -10 "$LOG"; exit 1; }
runpg "$BINDIR/createdb" -h /tmp -p "$PORT" extupg >/dev/null 2>&1

q "CREATE EXTENSION pgcolumnar" >/dev/null
q "CREATE TABLE t (id int, v text) USING pgcolumnar" >/dev/null
q "INSERT INTO t SELECT g, 'v'||g FROM generate_series(1,1000) g" >/dev/null
before_rows=$(q "SELECT count(*) FROM t")
old_ver=$(q "SELECT extversion FROM pg_extension WHERE extname='pgcolumnar'")
echo "  old install: $before_rows rows, extversion $old_ver"
[ "$before_rows" = "1000" ] || { echo "FAIL  old install did not store rows"; exit 1; }

# ---- 2. install the tree under test over it, library and scripts ---------------------
# Clean first. This tree may have last been built against another major, and make
# would happily relink those objects into a .so this server cannot load. That is how
# this gate first failed: a pg19 build silently relinked for pg18, the postmaster
# refused to start, and every check below reported a connection error instead.
make -C "$SRCDIR" PG_CONFIG="$PG_CONFIG" clean >/dev/null 2>&1
make -C "$SRCDIR" PG_CONFIG="$PG_CONFIG" -j"$(nproc)" >"$TMP/build_new.log" 2>&1 \
	|| { echo "FAIL  new build"; tail -20 "$TMP/build_new.log"; exit 1; }
make -C "$SRCDIR" PG_CONFIG="$PG_CONFIG" install >/dev/null 2>&1 \
	|| { echo "FAIL  new install"; exit 1; }
if ! runpg "$BINDIR/pg_ctl" -D "$DATA" -l "$LOG" -w restart >/dev/null 2>&1; then
	echo "  FAIL  server did not come back after installing the new build"
	tail -15 "$LOG"
	exit 1
fi

# ---- 3. upgrade, and require that it be available at all ----------------------------
# If the link names did not move, nothing is broken here and the upgrade is a no-op. If
# they did move, ALTER EXTENSION UPDATE is the only route back that keeps user tables,
# so its absence is itself the failure.
new_default=$(grep -oE "default_version = '[^']+'" "$SRCDIR/pgcolumnar.control" | sed "s/.*'\(.*\)'/\1/")
if [ "$new_default" != "$old_ver" ] && \
   [ ! -f "$SHAREDIR/extension/pgcolumnar--$old_ver--$new_default.sql" ]; then
	echo "  FAIL  default_version moved $old_ver -> $new_default with no"
	echo "        pgcolumnar--$old_ver--$new_default.sql, so an existing install cannot upgrade"
	fail=1
fi

upd=$(q "ALTER EXTENSION pgcolumnar UPDATE")
case "$upd" in
	*ERROR*) echo "  FAIL  ALTER EXTENSION UPDATE: $upd"; fail=1 ;;
	*)       echo "  ok    ALTER EXTENSION UPDATE -> $(q "SELECT extversion FROM pg_extension WHERE extname='pgcolumnar'")" ;;
esac

# ---- 4. the extension must work on the upgraded install -----------------------------
chk () {
	local label=$1 want=$2 got
	got=$(q "$3")
	if [ "$got" = "$want" ]; then
		echo "  PASS  $label: $got"
	else
		echo "  FAIL  $label: got [$got] want [$want]"
		fail=1
	fi
}
chk "existing rows still readable" "1000" "SELECT count(*) FROM t"
q "INSERT INTO t VALUES (0,'x')" >/dev/null
chk "insert into an existing table" "1001" "SELECT count(*) FROM t"
q "CREATE TABLE t2 (a int) USING pgcolumnar" >/dev/null
q "INSERT INTO t2 SELECT generate_series(1,3)" >/dev/null
chk "new columnar table creatable" "3" "SELECT count(*) FROM t2"
chk "access method still bound" "pgcolumnar" "SELECT amname FROM pg_am WHERE amname='pgcolumnar'"
chk "maintenance function callable" "" "SELECT pgcolumnar.vacuum('t')"

# Every C function's recorded link name must resolve in the library we just installed.
# This is the general form of the bug, so it catches the next rename as well as this one.
missing=$(q "SELECT string_agg(p.proname||' -> '||p.prosrc, ', ')
             FROM pg_proc p
             JOIN pg_depend d ON d.objid = p.oid AND d.deptype = 'e'
             JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'pgcolumnar'
             WHERE p.prolang = (SELECT oid FROM pg_language WHERE lanname='c')
               AND p.prosrc !~ '^pgcolumnar'")
if [ -n "$missing" ]; then
	echo "  FAIL  link names left outside the pgcolumnar namespace: $missing"
	fail=1
else
	echo "  PASS  every C function's link name is namespaced"
fi

echo "== extension_upgrade: $([ $fail -eq 0 ] && echo PASS || echo FAIL)"
exit $fail
