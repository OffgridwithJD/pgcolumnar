#!/usr/bin/env bash
#
# pgColumnar objstore: userinfo in a URL is refused on EVERY entry point (#706).
#
# The read path (os_open) and the ABI http_request refused `user@host` in an
# http(s) authority from the start: userinfo smuggles bytes into the host part,
# the classic SSRF-parser-confusion shape. The write path (os_write_handle:
# export sink, delete, list) parsed the same authority WITHOUT the guard, so a
# userinfo URL sailed past the parse with the '@' embedded in the host field.
# It still failed closed -- the allow-list match at connect cannot match a host
# with an embedded '@' -- but as the wrong error (42501, an allow-list refusal)
# with the userinfo bytes carried through the handle, and fail-closed-by-
# accident is one endpoint-matching refactor away from not failing at all.
#
# These arms need no object-store server: both the guard (22023) and the
# allow-list refusal (42501) fire before any network I/O. The SQLSTATE is the
# discriminator -- 22023 comes only from the parse guards, 42501 only from the
# allow-list -- and the message arm pins WHICH 22023 guard fired.
#
# Removal proof: revert the os_write_handle guard and the write arms read
# 42501 again while the read arms stay 22023.
#
# Usage:  test/objstore_userinfo.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export PGC_EXTRA_CONF="pgcolumnar.objstore_allowed_endpoints='127.0.0.1'"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

q "CREATE EXTENSION IF NOT EXISTS pgcolumnar;" >/dev/null
q "CREATE TABLE ex (id int, v text) USING pgcolumnar;
   INSERT INTO ex SELECT g, 'v'||g FROM generate_series(1,100) g;" >/dev/null

sqlstate_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA 2>&1 <<SQLEOF | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' | head -1
\\set VERBOSITY sqlstate
$1;
SQLEOF
}

msg_of() {
	env PATH="$PGC_BINDIR:$PATH" psql -h 127.0.0.1 -p "$PGC_PORT" -U postgres \
		-d "$PGC_DB" -qtA -c "$1" 2>&1 | grep -c 'userinfo'
}

URL="http://u:p@127.0.0.1:1/x.parquet"

# --- premise: the read path refuses userinfo with the parse guard ------------
check "read_parquet refuses userinfo (22023, the parse guard)" \
	"$(sqlstate_of "SELECT * FROM pgcolumnar.read_parquet('$URL') AS t(v int)")" "22023"
check "and its message names userinfo" \
	"$(msg_of "SELECT * FROM pgcolumnar.read_parquet('$URL') AS t(v int)")" "1"

# --- the gap: the write path must refuse with the SAME guard -----------------
# Pre-fix these read 42501: the parse admits the URL and the '@'-carrying host
# then fails the allow-list at connect -- fail closed, wrong reason.
check "export_parquet refuses userinfo (22023, not an allow-list 42501)" \
	"$(sqlstate_of "SELECT pgcolumnar.export_parquet('ex', '$URL')")" "22023"
check "and its message names userinfo" \
	"$(msg_of "SELECT pgcolumnar.export_parquet('ex', '$URL')")" "1"
check "export_arrow refuses userinfo through the same handle (22023)" \
	"$(sqlstate_of "SELECT pgcolumnar.export_arrow('ex', 'http://u@127.0.0.1:1/x.arrow')")" "22023"

# --- the allow-list still does its own job on a clean URL --------------------
# The guard must not have swallowed the 42501 class: a userinfo-free URL to a
# non-allowed endpoint is still the allow-list's refusal.
check "a clean URL to a non-allowed endpoint is still the allow-list's 42501" \
	"$(sqlstate_of "SELECT pgcolumnar.export_parquet('ex', 'http://127.0.0.2:1/x.parquet')")" "42501"

check "backend alive" "$(q 'SELECT 1;')" "1"

pgc_summary
