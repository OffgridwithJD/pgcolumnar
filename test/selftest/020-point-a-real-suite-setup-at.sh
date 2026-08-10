# ---- point a real suite setup at exactly that port --------------------------
export PGC_PORT="$SQ_PORT"
. ""$PGC_TESTDIR"/lib.sh"
pgc_setup "$PGC_SELFTEST_PG_CONFIG"

# pgc_setup replaced our trap with its own (pgc_teardown); chain both back on.
trap 'pgc_teardown; squatter_down' EXIT

