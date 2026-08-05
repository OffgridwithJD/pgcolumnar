#!/usr/bin/env bash
#
# REPACK on a columnar table (issue #399). PostgreSQL 19 and later only.
#
# REPACK replaces CLUSTER and VACUUM FULL in 19. It is not a new table-AM
# callback: it reuses the CLUSTER machinery, which dispatches a rewrite through
# relation_copy_for_cluster. design/PG18_19_OPPORTUNITIES.md concluded from that
# dispatch that REPACK "should work" on a columnar table, because pgColumnar
# registers that callback.
#
# It does not work. The callback is registered and is a stub that raises, so the
# reasoning was true of the symbol and false of the behaviour. That is the gap a
# suite closes and a grep does not, and it is why this file exists.
#
# What is asserted here is therefore the ACTUAL behaviour, not the hoped-for one:
# every spelling of the command errors, it errors naming the command the user
# typed, the table is unharmed afterwards, and the supported alternative works.
# If someone later implements relation_copy_for_cluster, these checks fail and
# should be rewritten to assert success. That is the intended signal.
#
# The heap control is not decoration. Without it, "REPACK fails here" cannot be
# told apart from "REPACK does not work on this build at all", which matters for
# REPACK (CONCURRENTLY), whose failure is not columnar-specific.
#
# Usage:  test/native_repack.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg19/bin/pg_config}"

# Version gate, and it must be VISIBLE. A suite that silently passes on 15 to 18
# is the failure mode this project keeps finding.
srv="$(q 'SHOW server_version_num')"
if [ "${srv:-0}" -lt 190000 ]; then
	echo "SKIP  REPACK requires PostgreSQL 19 (server_version_num=$srv)"
	echo "native_repack.sh: SKIPPED"
	exit 0
fi

ROWS=${PGC_REPACK_ROWS:-20000}

psql_run "CREATE TABLE rp (id int, v text) USING pgcolumnar;
	SELECT pgcolumnar.set_options('rp', stripe_row_limit => 5000, compression => 'zstd');
	INSERT INTO rp SELECT g, 'x'||g FROM generate_series(1,$ROWS) g;
	DELETE FROM rp WHERE id % 3 = 0;
	CREATE INDEX rp_id ON rp (id);
	CREATE TABLE rp_heap (id int, v text);
	INSERT INTO rp_heap SELECT g, 'x'||g FROM generate_series(1,$ROWS) g;
	CREATE INDEX rp_heap_id ON rp_heap (id);"

live=$(q "SELECT count(*) FROM rp")
hash_before=$(q "SELECT md5(string_agg(id::text||':'||v, ',' ORDER BY id)) FROM rp")
opts_before=$(q "SELECT stripe_row_limit || '/' || compression FROM pgcolumnar.options o
	JOIN pg_class c ON c.oid = o.regclass WHERE c.relname = 'rp'")

err_of() { psql_run "$1" 2>&1 | grep -oE 'ERROR:.*' | head -1; }

# ---- every spelling errors, and the message names the command ----------------
e="$(err_of 'REPACK rp;')"
check "REPACK on a columnar table errors (#399)" \
	"$(case "$e" in *ERROR*) echo yes ;; *) echo "no (succeeded)" ;; esac)" "yes"
check "and the error names REPACK, which is what the user typed (#399)" \
	"$(case "$e" in *REPACK*) echo yes ;; *) echo "no ($e)" ;; esac)" "yes"

check "REPACK ... USING INDEX errors the same way" \
	"$(case "$(err_of 'REPACK rp USING INDEX rp_id;')" in *"not supported"*) echo yes ;; *) echo no ;; esac)" "yes"
check "REPACK (VERBOSE) errors the same way" \
	"$(case "$(err_of 'REPACK (VERBOSE) rp;')" in *"not supported"*) echo yes ;; *) echo no ;; esac)" "yes"
check "CLUSTER errors the same way" \
	"$(case "$(err_of 'CLUSTER rp USING rp_id;')" in *"not supported"*) echo yes ;; *) echo no ;; esac)" "yes"
check "VACUUM FULL errors the same way" \
	"$(case "$(err_of 'VACUUM FULL rp;')" in *"not supported"*) echo yes ;; *) echo no ;; esac)" "yes"

# REPACK (CONCURRENTLY) fails on heap too on this build, so it is recorded rather
# than attributed to us. "REPACK CONCURRENTLY" without parentheses is not syntax.
c_col="$(err_of 'REPACK (CONCURRENTLY) rp;')"
c_heap="$(err_of 'REPACK (CONCURRENTLY) rp_heap;')"
check "REPACK (CONCURRENTLY) fails on columnar and on heap alike, so it is not ours" \
	"$( [ -n "$c_col" ] && [ -n "$c_heap" ] && echo yes || echo "no (col=[$c_col] heap=[$c_heap])")" \
	"yes"

# ---- the control: the same command works on heap -----------------------------
check "control: REPACK works on a heap table on this build" \
	"$(psql_run 'REPACK rp_heap;' 2>&1 | grep -c ERROR || true)" "0"

# ---- a failed rewrite must leave the table untouched -------------------------
check "the columnar table is unharmed: row count" "$(q 'SELECT count(*) FROM rp')" "$live"
check "the columnar table is unharmed: content hash" \
	"$(q "SELECT md5(string_agg(id::text||':'||v, ',' ORDER BY id)) FROM rp")" "$hash_before"
check "the columnar table is unharmed: storage options" \
	"$(q "SELECT stripe_row_limit || '/' || compression FROM pgcolumnar.options o
	      JOIN pg_class c ON c.oid = o.regclass WHERE c.relname = 'rp'")" "$opts_before"
check "the columnar table is unharmed: access method" \
	"$(q "SELECT amname FROM pg_am a JOIN pg_class c ON c.relam = a.oid WHERE c.relname = 'rp'")" \
	"pgcolumnar"

# ---- and the supported route does work ---------------------------------------
check "pgcolumnar.vacuum is the supported alternative and succeeds" \
	"$(psql_run "SELECT pgcolumnar.vacuum('rp');" 2>&1 | grep -c ERROR || true)" "0"
check "and it kept every live row" "$(q 'SELECT count(*) FROM rp')" "$live"
check "and the content is still identical" \
	"$(q "SELECT md5(string_agg(id::text||':'||v, ',' ORDER BY id)) FROM rp")" "$hash_before"

pgc_summary
