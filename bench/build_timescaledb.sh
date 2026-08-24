#!/usr/bin/env bash
#
# Build the benchmark's TimescaleDB arm from source, pinned to the exact
# version and cmake options that produced the numbers in docs/benchmarks.md.
#
# The flags below are not a guess: they were read back from the CMakeCache.txt
# of the original build tree on the benchmark machine before it was
# decommissioned (issue #702). TimescaleDB builds with cmake via its
# ./bootstrap wrapper, not PGXS. APACHE_ONLY=OFF selects the community (TSL)
# edition — that is why an install yields both timescaledb-<v>.so and
# timescaledb-tsl-<v>.so.
#
# Usage:
#   bench/build_timescaledb.sh [PG_CONFIG] [VERSION]
#     defaults: /usr/local/pg18n/bin/pg_config  2.29.0
#
# The default pg_config is the benchmark convention (a NON-assert PostgreSQL;
# see docs/benchmarks.md). Set TS_SRC to reuse a source checkout.
# Requires cmake, a C toolchain, git, and sudo for `make install`.
set -euo pipefail

PG_CONFIG="${1:-/usr/local/pg18n/bin/pg_config}"
VERSION="${2:-2.29.0}"
SRC="${TS_SRC:-/tmp/timescaledb-$VERSION}"

command -v "$PG_CONFIG" >/dev/null || { echo "no pg_config at $PG_CONFIG" >&2; exit 1; }
echo "== building TimescaleDB $VERSION against $("$PG_CONFIG" --version) ($PG_CONFIG)"

# Benchmark arms must run on a non-assert PostgreSQL. An assert build's numbers
# are invalid, so refuse one the way the rest of the bench tooling does.
if "$PG_CONFIG" --configure | grep -q -- '--enable-cassert'; then
	echo "REFUSING: $PG_CONFIG is an assert build; benchmark numbers from it are invalid" >&2
	exit 1
fi

[ -d "$SRC" ] || git clone --depth 1 --branch "$VERSION" \
	https://github.com/timescale/timescaledb.git "$SRC"
cd "$SRC"

# Exact options from the original build's CMakeCache.txt:
./bootstrap \
	-DPG_CONFIG="$PG_CONFIG" \
	-DCMAKE_BUILD_TYPE=Release \
	-DAPACHE_ONLY=OFF \
	-DUSE_OPENSSL=0 \
	-DREGRESS_CHECKS=OFF \
	-DWARNINGS_AS_ERRORS=OFF \
	-DTAP_CHECKS=OFF \
	-DLINTER=OFF
cd build
make -j"$(nproc)"
sudo make install

# Verify the artifact, not the exit status: a cmake picking up a stray prefix
# installs elsewhere and still returns 0.
PKGLIB="$("$PG_CONFIG" --pkglibdir)"
ls -1 "$PKGLIB"/timescaledb*.so || { echo "FAILED: no timescaledb .so in $PKGLIB" >&2; exit 1; }
echo "== installed:"
ls -1 "$PKGLIB"/timescaledb*.so
echo
echo "TimescaleDB must be preloaded to be used:"
echo "  shared_preload_libraries = 'timescaledb'   (or 'pgcolumnar,timescaledb')"
echo "  then: CREATE EXTENSION timescaledb;"
echo "        SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';"
