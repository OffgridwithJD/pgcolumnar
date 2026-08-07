#!/usr/bin/env bash
#
# PostgreSQL 19 parallel autovacuum, on a columnar table (issue #398).
#
# 19 adds parallel autovacuum: a server variable autovacuum_max_parallel_workers
# and a per-table storage parameter autovacuum_parallel_workers. pgColumnar
# implements its own relation_vacuum callback, so the question was whether a table
# access method participates in that at all.
#
# Measured answer: the storage parameter is ACCEPTED on a columnar table and lands
# in pg_class.reloptions exactly as it does on heap, and it has NO EFFECT, because
# pgcolumnar_relation_vacuum marks the visibility map and retires fully-deleted
# row groups and does no parallel work of any kind. A parameter a user can set and
# that silently does nothing is worth pinning, so it is recorded here and in
# docs/limitations.md rather than left to be discovered.
#
# It cannot simply be rejected. Storage-parameter validation is core's, driven by
# relkind rather than by the access method, and pgColumnar has no reloptions hook
# to refuse it from. Documenting it is the available honest option.
#
# The heap arm is a control rather than decoration: without it, "the parameter does
# nothing here" cannot be told apart from "parallel autovacuum does nothing on this
# cluster", and autovacuum_max_parallel_workers defaults to 0 on 19beta2, which
# would make the second reading true for everyone.
#
# Usage:  test/pg19_vacuum_options.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg19/bin/pg_config}"

srv="$(q 'SHOW server_version_num')"
# An empty answer is a cluster that stopped talking, not PostgreSQL 18. ${srv:-0}
# made those identical, so a dead postmaster reported SKIPPED and the major passed.
#
# The failure is raised only when it happens, rather than as a check that always
# runs: a passing check would put PGC_CHECKS at 1, and this suite's whole verdict
# on an older major depends on it being 0. Asserting the premise must not destroy
# the skip it guards.
if ! pgc_is_number "$srv"; then
	PGC_CHECKS=$((PGC_CHECKS + 1))
	PGC_FAIL=1
	echo "FAIL  the server did not answer 'SHOW server_version_num': got [$srv]"
	pgc_summary
fi
if [ "$srv" -lt 190000 ]; then
	echo "SKIP  parallel autovacuum requires PostgreSQL 19 (server_version_num=$srv)"
	pgc_summary
fi

ROWS=${PGC_AV_ROWS:-100000}

psql_run "CREATE TABLE av_c (id int, v text) USING pgcolumnar;
	CREATE TABLE av_h (id int, v text);
	INSERT INTO av_c SELECT g,'x'||g FROM generate_series(1,$ROWS) g;
	INSERT INTO av_h SELECT g,'x'||g FROM generate_series(1,$ROWS) g;
	DELETE FROM av_c WHERE id % 4 = 0;
	DELETE FROM av_h WHERE id % 4 = 0;"

# ---- the setting exists, and is off by default -------------------------------
check "autovacuum_max_parallel_workers exists on this server" \
	"$(q 'SHOW autovacuum_max_parallel_workers' >/dev/null 2>&1 && echo yes || echo no)" "yes"

# ---- the storage parameter is accepted on BOTH access methods ----------------
# This is the answer to the issue: a table AM does not get to refuse it.
for t in av_c av_h; do
	out="$(psql_run "ALTER TABLE $t SET (autovacuum_parallel_workers = 3);" 2>&1)"
	check "autovacuum_parallel_workers is accepted on $t" \
		"$(case "$out" in *ERROR*) grep -oE 'ERROR:.*' <<<"$out" | head -1 ;; *) echo accepted ;; esac)" \
		"accepted"
	check "and it is recorded in reloptions for $t" \
		"$(q "SELECT array_to_string(reloptions,',') FROM pg_class WHERE relname='$t'")" \
		"autovacuum_parallel_workers=3"
done

# ---- and it changes nothing about what our vacuum does -----------------------
# Same live rows before and after, with the parameter set. The point is not that
# vacuum works; it is that setting the parameter neither helps nor breaks it.
live_before="$(q 'SELECT count(*) FROM av_c')"
hash_before="$(q "SELECT md5(string_agg(id::text||':'||v, ',' ORDER BY id)) FROM av_c")"

check "VACUUM on a columnar table with the parameter set succeeds" \
	"$(psql_run 'VACUUM av_c;' 2>&1 | grep -c 'ERROR' || true)" "0"
check "VACUUM (PARALLEL 2) on a columnar table succeeds" \
	"$(psql_run 'VACUUM (PARALLEL 2) av_c;' 2>&1 | grep -c 'ERROR' || true)" "0"
check "pgcolumnar.vacuum with the parameter set succeeds" \
	"$(psql_run "SELECT pgcolumnar.vacuum('av_c');" 2>&1 | grep -c 'ERROR' || true)" "0"

check "the rows are unchanged by any of it" "$(q 'SELECT count(*) FROM av_c')" "$live_before"
check "and the content is unchanged" \
	"$(q "SELECT md5(string_agg(id::text||':'||v, ',' ORDER BY id)) FROM av_c")" "$hash_before"

# ---- the control: heap reports parallel vacuum activity, columnar does not ----
# If a future release makes table AMs participate, this check flips and should be
# rewritten to assert that our vacuum reports workers too.
vh="$(psql_run 'VACUUM (VERBOSE) av_h;' 2>&1)"
vc="$(psql_run 'VACUUM (VERBOSE) av_c;' 2>&1)"
check "control: VACUUM VERBOSE reports on the heap table" \
	"$(grep -qi 'finished vacuuming' <<<"$vh" && echo yes || echo no)" "yes"
check "columnar VACUUM VERBOSE reports nothing, because the AM path is ours" \
	"$(grep -qi 'finished vacuuming .*av_c' <<<"$vc" && echo "reports" || echo "silent")" "silent"

pgc_summary
