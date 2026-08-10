# ---- assertions -------------------------------------------------------------
check "suite did not settle on the squatter's port" \
	"$([ "$PGC_PORT" = "$SQ_PORT" ] && echo same || echo moved)" "moved"

check "suite's cluster is its own" \
	"$(pgc_norm_path "$(pgc_cluster_datadir)")" "$(pgc_norm_path "$PGC_PGDATA")"

check "squatter survived untouched" "$(pgc_norm_path "$(sq_datadir)")" \
	"$(pgc_norm_path "$SQ_DIR/data")"

# The point of the guard: objects this suite creates are visible to this suite.
psql_run "CREATE TABLE selftest_marker (id int);"
psql_run "INSERT INTO selftest_marker VALUES (42);"
check "suite's own objects are visible to it" \
	"$(q 'SELECT id FROM selftest_marker;')" "42"

# and are absent from the squatter, i.e. nothing leaked across
check "nothing leaked into the squatter" \
	"$(env PATH="$_bindir:$PATH" psql -h 127.0.0.1 -p "$SQ_PORT" -U postgres \
		-d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname = '$PGC_DB';" 2>/dev/null)" \
	"0"

# pgc_port_free must agree with reality on both a used and an unused port
check "pgc_port_free says the squatter's port is busy" \
	"$(pgc_port_free "$SQ_PORT" && echo free || echo busy)" "busy"

