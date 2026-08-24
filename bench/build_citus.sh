#!/usr/bin/env bash
#
# Build the benchmark's Citus arm from source, pinned to the version that
# produced the numbers in docs/benchmarks.md. Citus v14.1.0 is the first
# release line that supports PostgreSQL 18. Comparison target only — no Citus
# source enters pgColumnar (see PROVENANCE.md).
#
# Recovered from the benchmark machine's loose tooling before it was
# decommissioned (issue #702); Citus uses plain autoconf + PGXS, so unlike
# TimescaleDB there is no cmake cache to mirror — the pin is the tag and the
# one configure flag.
#
# Usage:
#   bench/build_citus.sh [PG_CONFIG] [TAG]
#     defaults: /usr/local/pg18n/bin/pg_config  v14.1.0
#
# The default pg_config is the benchmark convention (a NON-assert PostgreSQL;
# see docs/benchmarks.md). Set CITUS_SRC to reuse a source checkout.
# Requires a C toolchain, git, and sudo for `make install`.
set -euo pipefail

PG_CONFIG="${1:-/usr/local/pg18n/bin/pg_config}"
TAG="${2:-v14.1.0}"
SRC="${CITUS_SRC:-/tmp/citus-$TAG}"

command -v "$PG_CONFIG" >/dev/null || { echo "no pg_config at $PG_CONFIG" >&2; exit 1; }
echo "== building Citus $TAG against $("$PG_CONFIG" --version) ($PG_CONFIG)"

# Benchmark arms must run on a non-assert PostgreSQL. An assert build's numbers
# are invalid, so refuse one the way the rest of the bench tooling does.
if "$PG_CONFIG" --configure | grep -q -- '--enable-cassert'; then
	echo "REFUSING: $PG_CONFIG is an assert build; benchmark numbers from it are invalid" >&2
	exit 1
fi

[ -d "$SRC" ] || git clone --depth 1 --branch "$TAG" \
	https://github.com/citusdata/citus.git "$SRC"
cd "$SRC"

# --without-libcurl: the bench arm needs the columnar AM, not telemetry.
PATH="$("$PG_CONFIG" --bindir):$PATH" ./configure \
	--with-pg-config="$PG_CONFIG" --without-libcurl
make -s -j"$(nproc)"
sudo make -s install

# Verify the artifact, not the exit status.
PKGLIB="$("$PG_CONFIG" --pkglibdir)"
ls -1 "$PKGLIB"/citus*.so || { echo "FAILED: no citus .so in $PKGLIB" >&2; exit 1; }
echo "== installed:"
ls -1 "$PKGLIB"/citus*.so
echo
echo "Citus must be preloaded to be used:"
echo "  shared_preload_libraries = 'citus'   (or 'pgcolumnar,citus')"
echo "  then: CREATE EXTENSION citus;"
echo "        SELECT extversion FROM pg_extension WHERE extname = 'citus';"
