#!/usr/bin/env bash
#
# pgColumnar pg_upgrade across majors (#239).
#
# pg_upgrade is the cross-major data-preservation path, and it is the profile
# where an access-method extension with its own catalog is most likely to break:
# relation forks carry the data, pgcolumnar.* heap tables carry the metadata, and
# both have to survive the transfer with the extension present on the new side.
# Nothing tested it. A user who upgrades and finds columnar tables unreadable has
# lost data with no warning.
#
# Not in run_all_versions.sh, for the same reason run_san.sh is not: the matrix
# runs one pg_config per invocation and this needs two majors at once. It is a
# second gate beside the matrix, run explicitly.
#
# Usage:
#   test/pg_upgrade.sh OLD_PG_CONFIG NEW_PG_CONFIG [copy|link]
#
# e.g. test/pg_upgrade.sh /usr/local/pg17/bin/pg_config \
#                         /usr/local/pgsql/bin/pg_config link
#
# Written fresh for pgColumnar.

set -uo pipefail
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OLD_PGC="${1:-}"
NEW_PGC="${2:-}"
MODE="${3:-copy}"

fail=0
checks=0
check() {
	local name="$1" got="$2" want="$3"
	checks=$((checks + 1))
	if [ "$got" = "$want" ]; then
		echo "PASS  $name"
	else
		echo "FAIL  $name: got [$got] want [$want]"
		fail=1
	fi
}

if [ ! -x "$OLD_PGC" ] || [ ! -x "$NEW_PGC" ]; then
	echo "usage: test/pg_upgrade.sh OLD_PG_CONFIG NEW_PG_CONFIG [copy|link]" >&2
	exit 2
fi

OLD_BIN="$("$OLD_PGC" --bindir)"
NEW_BIN="$("$NEW_PGC" --bindir)"
OLD_VER="$("$OLD_PGC" --version)"
NEW_VER="$("$NEW_PGC" --version)"
OLD_MAJ="$(echo "$OLD_VER" | sed -E 's/^[^0-9]*([0-9]+).*/\1/')"
NEW_MAJ="$(echo "$NEW_VER" | sed -E 's/^[^0-9]*([0-9]+).*/\1/')"

echo "== pgColumnar pg_upgrade: PG$OLD_MAJ -> PG$NEW_MAJ ($MODE mode) =="
echo "old: $OLD_VER"
echo "new: $NEW_VER"

# Upgrading to the same or an older major is not an upgrade, and every assertion
# below would still pass, so refuse rather than report a meaningless green.
if [ "$NEW_MAJ" -le "$OLD_MAJ" ]; then
	echo "FATAL: new major ($NEW_MAJ) must be greater than old ($OLD_MAJ)" >&2
	exit 2
fi

WORK="$(mktemp -d /tmp/pgcolumnar-upgrade.XXXXXX)"
chmod 777 "$WORK"
OLD_DATA="$WORK/old"
NEW_DATA="$WORK/new"
OLD_PORT=$(( 41000 + ($$ % 2000) ))
NEW_PORT=$(( OLD_PORT + 1 ))

RUNPG=(env)
if [ "$(id -u)" = "0" ]; then
	RUNPG=(runuser -u postgres --)
	chown -R postgres "$WORK"
fi
pg() { "${RUNPG[@]}" bash -lc "$1"; }

cleanup() {
	pg "$OLD_BIN/pg_ctl -D '$OLD_DATA' stop -m immediate -w" >/dev/null 2>&1 || true
	pg "$NEW_BIN/pg_ctl -D '$NEW_DATA' stop -m immediate -w" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

oq() { env PATH="$OLD_BIN:$PATH" psql -h 127.0.0.1 -p "$OLD_PORT" -U postgres -d postgres -At -c "$1" 2>/dev/null || true; }
nq() { env PATH="$NEW_BIN:$PATH" psql -h 127.0.0.1 -p "$NEW_PORT" -U postgres -d postgres -At -c "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Install the extension against BOTH majors. pg_upgrade requires the extension
# to exist on the new side before the upgrade, not after; without it the upgrade
# aborts on a missing library rather than producing a broken cluster.
# ---------------------------------------------------------------------------
# Build from a writable copy, never from SRCDIR.
#
# In the dev container the tree is a READ-ONLY bind mount, so building in place
# fails with "can't create src/columnar_tableam.o: Read-only file system" -- which
# is what the first run of this script did. Copying also keeps two majors' object
# files from colliding, which is the other way this goes wrong: object reuse
# across majors links an ABI-incompatible .so and produces failures that look
# like the extension rather than the build.
BUILD="$WORK/src"
mkdir -p "$BUILD"
(cd "$SRCDIR" && tar cf - --exclude=.git .) | (cd "$BUILD" && tar xf -)

echo "-- building against both majors"
for pgc in "$OLD_PGC" "$NEW_PGC"; do
	make -C "$BUILD" clean PG_CONFIG="$pgc" >/dev/null 2>&1
	if ! make -C "$BUILD" PG_CONFIG="$pgc" >"$WORK/build.log" 2>&1; then
		echo "FAIL build $pgc"; tail -10 "$WORK/build.log"; exit 1
	fi
	if ! make -C "$BUILD" install PG_CONFIG="$pgc" >"$WORK/install.log" 2>&1; then
		echo "FAIL install $pgc"; tail -10 "$WORK/install.log"; exit 1
	fi
done

# ---------------------------------------------------------------------------
# Old cluster: data to preserve
# ---------------------------------------------------------------------------
echo "-- old cluster"
# -k on both: PostgreSQL 18 changed the initdb default to enable data checksums,
# and pg_upgrade refuses a pair that disagrees ("old cluster does not use data
# checksums but the new one does"). Relying on defaults makes the test fail on the
# 17 -> 18 pair for a reason that has nothing to do with this extension. Setting
# it explicitly on both sides is also what a real operator has to do.
pg "$OLD_BIN/initdb -k -D '$OLD_DATA' -A trust" >/dev/null 2>&1
{
	echo "port=$OLD_PORT"
	echo "listen_addresses='127.0.0.1'"
	echo "shared_preload_libraries='pgcolumnar'"
} | pg "cat >> '$OLD_DATA/postgresql.conf'"
pg "$OLD_BIN/pg_ctl -D '$OLD_DATA' -l '$WORK/old.log' start -w" >/dev/null 2>&1

oq "CREATE EXTENSION pgcolumnar" >/dev/null
oq "CREATE TABLE c (id int, v text, n numeric) USING pgcolumnar" >/dev/null
# Non-default options, so the test covers the pgcolumnar.options catalog row
# surviving and not merely the data pages.
oq "SELECT pgcolumnar.set_options('c', stripe_row_limit => 4000,
	chunk_group_row_limit => 800, compression => 'zstd')" >/dev/null
oq "INSERT INTO c SELECT g, md5(g::text), (g::numeric)/7 FROM generate_series(1,50000) g" >/dev/null
oq "DELETE FROM c WHERE id % 13 = 0" >/dev/null
oq "CREATE INDEX c_id ON c (id)" >/dev/null

old_hash="$(oq "SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM c t")"
old_count="$(oq 'SELECT count(*) FROM c')"
old_range="$(oq "SET enable_seqscan=off; SELECT count(*) FROM c WHERE id BETWEEN 100 AND 200" | tail -1)"
old_opts="$(oq "SELECT stripe_row_limit || '/' || chunk_group_row_limit || '/' || compression
	FROM pgcolumnar.options WHERE regclass = 'c'::regclass")"

check "old cluster has rows to preserve" "$([ -n "$old_count" ] && [ "$old_count" -gt 0 ] && echo yes || echo no)" "yes"
check "old cluster recorded non-default options" "$old_opts" "4000/800/zstd"

pg "$OLD_BIN/pg_ctl -D '$OLD_DATA' stop -m fast -w" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# New cluster, empty
# ---------------------------------------------------------------------------
echo "-- new cluster"
pg "$NEW_BIN/initdb -k -D '$NEW_DATA' -A trust" >/dev/null 2>&1
{
	echo "port=$NEW_PORT"
	echo "listen_addresses='127.0.0.1'"
	echo "shared_preload_libraries='pgcolumnar'"
} | pg "cat >> '$NEW_DATA/postgresql.conf'"

# Control: the new cluster must be genuinely empty of our data before the
# upgrade. Without this, a pass could come from having created the table here.
pg "$NEW_BIN/pg_ctl -D '$NEW_DATA' -l '$WORK/new-pre.log' start -w" >/dev/null 2>&1
check "the new cluster does NOT have the table before the upgrade" \
	"$(nq "SELECT count(*) FROM pg_class WHERE relname = 'c'")" "0"
check "and is genuinely the new major" \
	"$(nq 'SHOW server_version_num' | cut -c1-2)" "$NEW_MAJ"
pg "$NEW_BIN/pg_ctl -D '$NEW_DATA' stop -m fast -w" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# The upgrade
# ---------------------------------------------------------------------------
echo "-- pg_upgrade ($MODE)"
link_flag=""
[ "$MODE" = link ] && link_flag="--link"
pg "cd '$WORK' && $NEW_BIN/pg_upgrade -b '$OLD_BIN' -B '$NEW_BIN' \
	-d '$OLD_DATA' -D '$NEW_DATA' -p $OLD_PORT -P $NEW_PORT $link_flag" \
	>"$WORK/upgrade.log" 2>&1
up_rc=$?
check "pg_upgrade exited cleanly" "$up_rc" "0"
if [ "$up_rc" != 0 ]; then
	echo "---- pg_upgrade output ----"
	tail -40 "$WORK/upgrade.log"
fi

pg "$NEW_BIN/pg_ctl -D '$NEW_DATA' -l '$WORK/new.log' start -w" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# What survived
# ---------------------------------------------------------------------------
check "the new cluster starts after the upgrade" "$(nq 'SELECT 1')" "1"
check "we are on the new major" "$(nq 'SHOW server_version_num' | cut -c1-2)" "$NEW_MAJ"
check "the extension is present" \
	"$(nq "SELECT count(*) FROM pg_extension WHERE extname = 'pgcolumnar'")" "1"
check "the table is still a columnar table" \
	"$(nq "SELECT a.amname FROM pg_class c JOIN pg_am a ON a.oid = c.relam WHERE c.relname = 'c'")" \
	"pgcolumnar"
check "row count preserved" "$(nq 'SELECT count(*) FROM c')" "$old_count"
check "content preserved byte for byte" \
	"$(nq "SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM c t")" "$old_hash"
check "per-table options preserved" \
	"$(nq "SELECT stripe_row_limit || '/' || chunk_group_row_limit || '/' || compression
		FROM pgcolumnar.options WHERE regclass = 'c'::regclass")" \
	"$old_opts"
# Compared against the value captured on the OLD cluster, not against another
# query on the new one -- the first version of this line compared the new answer
# with itself and would have passed whatever the index did.
check "the index still answers the same range" \
	"$(nq "SET enable_seqscan=off; SELECT count(*) FROM c WHERE id BETWEEN 100 AND 200" | tail -1)" \
	"$old_range"

# The upgraded relation must still be writable, not merely readable: a table that
# reads back correctly but cannot take another row is still a broken upgrade.
nq "INSERT INTO c SELECT g, 'post', 1 FROM generate_series(900001,900100) g" >/dev/null
check "the upgraded table still accepts writes" \
	"$(nq "SELECT count(*) FROM c WHERE v = 'post'")" "100"
check "and reads back the new rows with the old ones" \
	"$(nq 'SELECT count(*) FROM c')" "$((old_count + 100))"

echo
echo "checks run: $checks"
if [ "$fail" = 0 ]; then
	echo "PG_UPGRADE ($OLD_MAJ -> $NEW_MAJ, $MODE) PASSED"
else
	echo "PG_UPGRADE ($OLD_MAJ -> $NEW_MAJ, $MODE) FAILED"
fi
exit "$fail"
