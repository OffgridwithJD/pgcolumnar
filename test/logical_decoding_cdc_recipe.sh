#!/usr/bin/env bash
#
# The documented CDC recipe actually works (#754).
#
# logical_decoding_source.sh proves the LIMITATION: a columnar table emits no
# decodable change. This suite proves the WORKAROUND that docs/user-guide.md
# offers in its place -- capture rows into a heap table with a row trigger and
# decode that. Together they are the whole of the project's answer to "can I run
# CDC against this", and only the negative half was tested.
#
# A documented recipe that nobody has run is a claim like any other, and this one
# makes four specific factual claims that nothing in the tree checked:
#
#   1. row triggers fire on a columnar table and see the same rows a heap table
#      would;
#   2. "An UPDATE arrives as one UPDATE ... it does not record the operation of
#      the storage". Internally a columnar update deletes the old row and inserts
#      a new one, so this is the claim most likely to be false, and it is the one
#      a CDC consumer would be broken by;
#   3. the capture is transactional -- a rolled-back transaction captures
#      nothing;
#   4. the capture table decodes, so a slot really does carry the changes.
#
# The recipe is transcribed from the guide rather than rewritten, so the suite
# fails if the guide drifts away from what works.
#
# Usage:  test/logical_decoding_cdc_recipe.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export PGC_EXTRA_CONF="wal_level=logical
max_replication_slots=8
max_wal_senders=8"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

if [ ! -f "$("$PGC_PG_CONFIG" --pkglibdir)/test_decoding.so" ]; then
	pgc_skip "test_decoding" "test_decoding.so is not in $("$PGC_PG_CONFIG" --pkglibdir); build contrib/test_decoding"
fi

check "premise: the server is running at wal_level=logical" \
	"$(q "SHOW wal_level;")" "logical"

# ---- the recipe, transcribed from docs/user-guide.md -------------------------
psql_run "CREATE TABLE events (id bigint primary key, kind text, amount int)
              USING pgcolumnar;"
psql_run "CREATE TABLE events_cdc (
              seq    bigserial primary key,
              op     text,
              id     bigint,
              kind   text,
              amount int
          );"
psql_run "CREATE FUNCTION events_capture() RETURNS trigger LANGUAGE plpgsql AS \$\$
          BEGIN
              IF TG_OP = 'DELETE' THEN
                  INSERT INTO events_cdc (op, id, kind, amount)
                      VALUES ('DELETE', OLD.id, OLD.kind, OLD.amount);
              ELSE
                  INSERT INTO events_cdc (op, id, kind, amount)
                      VALUES (TG_OP, NEW.id, NEW.kind, NEW.amount);
              END IF;
              RETURN NULL;
          END
          \$\$;"
psql_run "CREATE TRIGGER events_cdc_t AFTER INSERT OR UPDATE OR DELETE ON events
              FOR EACH ROW EXECUTE FUNCTION events_capture();"

# The recipe is worthless if the tables are not the access methods it assumes:
# a heap "events" would pass every arm below and prove nothing about columnar.
check "premise: events is a COLUMNAR table" \
	"$(q "SELECT am.amname FROM pg_class c JOIN pg_am am ON am.oid = c.relam WHERE c.relname = 'events';")" \
	"pgcolumnar"
check "premise: events_cdc is a HEAP table" \
	"$(q "SELECT am.amname FROM pg_class c JOIN pg_am am ON am.oid = c.relam WHERE c.relname = 'events_cdc';")" \
	"heap"

# The slot must exist before any write, or nothing below is in its window.
psql_run "SELECT pg_create_logical_replication_slot('pgc_cdc', 'test_decoding');"
check "premise: the slot exists and is logical" \
	"$(q "SELECT slot_type FROM pg_replication_slots WHERE slot_name = 'pgc_cdc';")" "logical"

# ---- 1. the trigger fires on a columnar table --------------------------------
psql_run "INSERT INTO events VALUES (1,'sale',100), (2,'refund',50), (3,'sale',75);"
check_num "a row trigger on a COLUMNAR table fires once per inserted row" \
	"$(q "SELECT count(*) FROM events_cdc WHERE op = 'INSERT';")" "3"
check "and it saw the same values the table holds" \
	"$(q "SELECT string_agg(id||':'||kind||':'||amount, ',' ORDER BY id) FROM events_cdc WHERE op='INSERT';")" \
	"$(q "SELECT string_agg(id||':'||kind||':'||amount, ',' ORDER BY id) FROM events;")"

# ---- 2. an UPDATE arrives as ONE UPDATE, not as the storage's delete+insert ---
# This is the load-bearing claim. A columnar update is internally a delete of the
# old row and an insert of a new one. If the trigger followed the storage rather
# than the statement, a consumer replaying this feed would see a spurious DELETE
# and a spurious INSERT, and would get the row's history wrong.
BEFORE_INS="$(q "SELECT count(*) FROM events_cdc WHERE op='INSERT';")"
BEFORE_DEL="$(q "SELECT count(*) FROM events_cdc WHERE op='DELETE';")"
psql_run "UPDATE events SET amount = 150 WHERE id = 1;"
check_num "an UPDATE captures exactly one row" \
	"$(q "SELECT count(*) FROM events_cdc WHERE op='UPDATE';")" "1"
check "and it is recorded as UPDATE with the NEW value" \
	"$(q "SELECT op||':'||id||':'||amount FROM events_cdc WHERE op='UPDATE';")" "UPDATE:1:150"
check_num "the update did NOT leak the storage's internal DELETE" \
	"$(q "SELECT count(*) FROM events_cdc WHERE op='DELETE';")" "$BEFORE_DEL"
check_num "nor the storage's internal INSERT" \
	"$(q "SELECT count(*) FROM events_cdc WHERE op='INSERT';")" "$BEFORE_INS"

# ---- a DELETE captures the OLD row -------------------------------------------
psql_run "DELETE FROM events WHERE id = 2;"
check "a DELETE captures the OLD values, which are gone from the table" \
	"$(q "SELECT op||':'||id||':'||kind||':'||amount FROM events_cdc WHERE op='DELETE';")" \
	"DELETE:2:refund:50"
check_num "and the row really is gone from the columnar table" \
	"$(q "SELECT count(*) FROM events WHERE id = 2;")" "0"

# ---- 3. the capture is transactional -----------------------------------------
CAP_BEFORE="$(q "SELECT count(*) FROM events_cdc;")"
psql_run "BEGIN;
          INSERT INTO events VALUES (99,'rolledback',1);
          ROLLBACK;"
check_num "a rolled-back transaction captures nothing" \
	"$(q "SELECT count(*) FROM events_cdc;")" "$CAP_BEFORE"
check_num "and leaves no row in the columnar table either" \
	"$(q "SELECT count(*) FROM events WHERE id = 99;")" "0"
# ...and the fixture is not vacuously green: the same insert COMMITTED does capture
psql_run "BEGIN;
          INSERT INTO events VALUES (98,'committed',1);
          COMMIT;"
check_num "premise: the identical insert COMMITTED does capture, so the arm above is real" \
	"$(q "SELECT count(*) FROM events_cdc;")" "$(( CAP_BEFORE + 1 ))"

# ---- 4. the capture table decodes, and the columnar table still does not ------
psql_run "CREATE TABLE decoded AS
          SELECT data FROM pg_logical_slot_get_changes('pgc_cdc', NULL, NULL);"
d() { q "SELECT count(*) FROM decoded WHERE data LIKE '%$1%';"; }
# test_decoding renders a text value as op[text]:'UPDATE', so any pattern for it
# contains single quotes and cannot be interpolated into a LIKE literal. Dollar
# quoting carries them; strpos avoids LIKE's wildcards entirely.
dq() { q "SELECT count(*) FROM decoded WHERE strpos(data, \$q\$$1\$q\$) > 0;"; }

check "premise: the slot decoded something at all" \
	"$([ "$(q 'SELECT count(*) FROM decoded;')" -gt 0 ] && echo yes || echo no)" "yes"
check_num "CONTROL: the columnar table itself still emits nothing" \
	"$(d 'table public.events:')" "0"
check "the capture table IS carried by the slot" \
	"$([ "$(d 'table public.events_cdc: INSERT')" -gt 0 ] && echo yes || echo no)" "yes"
check_num "one decoded capture row per captured change" \
	"$(d 'table public.events_cdc: INSERT')" "$(q 'SELECT count(*) FROM events_cdc;')"
check "and the rolled-back row is not in the stream" \
	"$(d "rolledback")" "0"

# The stream carries the operation, which is the whole point of the recipe.
check_num "the decoded stream carries the UPDATE as an UPDATE" \
	"$(dq "op[text]:'UPDATE'")" "1"
check_num "and the DELETE as a DELETE" \
	"$(dq "op[text]:'DELETE'")" "1"
# the matcher itself must be capable of finding something, or the two arms above
# are a pair of zeros agreeing with a pair of zeros
check "premise: the same matcher finds the INSERTs, so a 1 above is a real match" \
	"$([ "$(dq "op[text]:'INSERT'")" -gt 1 ] && echo yes || echo no)" "yes"

# ---- the guide's warning about the pgcolumnar schema is necessary -------------
# "Exclude the pgcolumnar schema from any publication." That is only advice worth
# printing if a publication would otherwise include it.
psql_run "CREATE PUBLICATION pgc_all FOR ALL TABLES;"
check "premise: FOR ALL TABLES really does include pgcolumnar's internal tables" \
	"$([ "$(q "SELECT count(*) FROM pg_publication_tables WHERE pubname='pgc_all' AND schemaname='pgcolumnar';")" -gt 0 ] && echo yes || echo no)" \
	"yes"
psql_run "DROP PUBLICATION pgc_all;"

# ---- the guide's cost claim: one heap row per changed row --------------------
# "A load of ten million rows also writes ten million heap rows." Measured at a
# size the suite can afford; the claim is a ratio, not a magnitude.
BULK_BEFORE="$(q "SELECT count(*) FROM events_cdc;")"
psql_run "INSERT INTO events SELECT g, 'bulk', g FROM generate_series(1000, 6000) g;"
check_num "a bulk load writes exactly one capture row per loaded row" \
	"$(( $(q "SELECT count(*) FROM events_cdc;") - BULK_BEFORE ))" "5001"

psql_run "SELECT pg_drop_replication_slot('pgc_cdc');"

pgc_summary
