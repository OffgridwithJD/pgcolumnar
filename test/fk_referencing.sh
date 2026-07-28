#!/usr/bin/env bash
#
# pgColumnar foreign keys that reference a columnar table.
#
# Referential integrity reads the referenced row with FOR KEY SHARE, to hold the
# parent key still until the referencing transaction ends. Row locking is not
# implemented for columnar tables, so that read raises.
#
# Before this was refused at DDL, the constraint was accepted and then every
# insert into the referencing table failed, including inserts that satisfied it:
#
#     CREATE TABLE parent (id int PRIMARY KEY) USING pgcolumnar;
#     INSERT INTO parent VALUES (1);
#     CREATE TABLE child (id int REFERENCES parent(id));   -- accepted
#     INSERT INTO child VALUES (1);                        -- parent row exists
#     ERROR:  columnar: row locking is not supported yet
#
# A table that can never be written to is worse than a constraint that is
# refused, and the refusal belongs where the configuration is chosen. Core does
# the same for an unlogged table under a foreign key: it fails at CREATE TABLE
# rather than at every INSERT.
#
# The direction matters and is the reason this file is not one check. Only the
# REFERENCED side is refused. Columnar on the REFERENCING side reads a heap
# parent and writes its own rows through the ordinary insert path, so it works
# and must keep working -- a fix that rejected both directions would take away
# something that does.
#
# Usage:  test/fk_referencing.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

# --- 1. the referenced side is refused, at DDL ---------------------------------

psql_run "DROP TABLE IF EXISTS fk_child; DROP TABLE IF EXISTS fk_parent;
	CREATE TABLE fk_parent (id int PRIMARY KEY) USING pgcolumnar;
	INSERT INTO fk_parent VALUES (1), (2);" >/dev/null

err="$(psql_run "CREATE TABLE fk_child (id int REFERENCES fk_parent(id));" 2>&1 || true)"

check "a foreign key referencing a columnar table is refused" \
	"$(case "$err" in *"cannot create a foreign key referencing columnar table"*) echo yes ;;
		*) echo "no ($err)" ;; esac)" \
	"yes"

# The message has to name the reason, because the person reading it chose a
# perfectly ordinary schema and needs to know which half to change.
check "and the error says why" \
	"$(case "$err" in *"row locking is not supported"*) echo yes ;; *) echo "no ($err)" ;; esac)" \
	"yes"

check "the refused table was not left behind" \
	"$(q "SELECT count(*) FROM pg_class WHERE relname = 'fk_child';")" "0"

# --- 2. ALTER TABLE ADD CONSTRAINT is refused too ------------------------------

# Same constraint by a different route. A check on CREATE TABLE alone would let
# this one through, and the trap would be identical.
psql_run "DROP TABLE IF EXISTS fk_child2;
	CREATE TABLE fk_child2 (id int);" >/dev/null

err2="$(psql_run "ALTER TABLE fk_child2 ADD CONSTRAINT fk_c2
	FOREIGN KEY (id) REFERENCES fk_parent(id);" 2>&1 || true)"

check "ALTER TABLE ADD CONSTRAINT is refused by the same rule" \
	"$(case "$err2" in *"cannot create a foreign key referencing columnar table"*) echo yes ;;
		*) echo "no ($err2)" ;; esac)" \
	"yes"

# --- 3. the other direction still works ----------------------------------------

# This is the check that fails if the fix is too broad, and it is the one worth
# keeping if either is ever dropped: a columnar table on the REFERENCING side
# reads a heap parent, which locks fine, and writes its own rows through the
# ordinary insert path. That combination worked before and must still.

psql_run "DROP TABLE IF EXISTS fk_c_child; DROP TABLE IF EXISTS fk_h_parent;
	CREATE TABLE fk_h_parent (id int PRIMARY KEY);
	INSERT INTO fk_h_parent VALUES (1), (2), (3);" >/dev/null

err3="$(psql_run "CREATE TABLE fk_c_child (id int REFERENCES fk_h_parent(id), v text)
	USING pgcolumnar;" 2>&1 || true)"

check "a columnar table may reference a heap table" \
	"$(case "$err3" in *ERROR*) echo "no ($err3)" ;; *) echo yes ;; esac)" \
	"yes"

psql_run "INSERT INTO fk_c_child VALUES (1, 'a'), (2, 'b');" >/dev/null 2>&1

check "and rows that satisfy it are accepted" \
	"$(q "SELECT count(*) FROM fk_c_child;")" "2"

# and the constraint is still enforced in that direction
bad="$(psql_run "INSERT INTO fk_c_child VALUES (99, 'nope');" 2>&1 || true)"
check "a row that violates it is still rejected" \
	"$(case "$bad" in *"violates foreign key constraint"*) echo yes ;; *) echo "no ($bad)" ;; esac)" \
	"yes"

# --- 4. constraints that do not need a row lock are unaffected -----------------

# The rule keys on the constraint being FOREIGN and on the referenced side being
# columnar. Everything else must be untouched, or this fix has taken away far
# more than the trap it removes.

psql_run "DROP TABLE IF EXISTS fk_other;" >/dev/null
err4="$(psql_run "CREATE TABLE fk_other (
		id int PRIMARY KEY,
		k  int UNIQUE,
		v  int CHECK (v > 0),
		w  int NOT NULL
	) USING pgcolumnar;" 2>&1 || true)"

check "primary key, unique, check and not-null on a columnar table are unaffected" \
	"$(case "$err4" in *ERROR*) echo "no ($err4)" ;; *) echo yes ;; esac)" \
	"yes"

psql_run "INSERT INTO fk_other VALUES (1, 10, 5, 7);" >/dev/null 2>&1
check "and they still work" "$(q "SELECT count(*) FROM fk_other;")" "1"

viol="$(psql_run "INSERT INTO fk_other VALUES (1, 11, 5, 7);" 2>&1 || true)"
check "the primary key is still enforced" \
	"$(case "$viol" in *"duplicate key"*) echo yes ;; *) echo "no ($viol)" ;; esac)" \
	"yes"

# a foreign key between two heap tables must be entirely unaffected
psql_run "DROP TABLE IF EXISTS fk_hh_child; DROP TABLE IF EXISTS fk_hh_parent;
	CREATE TABLE fk_hh_parent (id int PRIMARY KEY);" >/dev/null
err5="$(psql_run "CREATE TABLE fk_hh_child (id int REFERENCES fk_hh_parent(id));" 2>&1 || true)"

check "a foreign key between two heap tables is unaffected" \
	"$(case "$err5" in *ERROR*) echo "no ($err5)" ;; *) echo yes ;; esac)" \
	"yes"

pgc_summary
