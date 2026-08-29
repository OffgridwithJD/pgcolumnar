#!/usr/bin/env bash
#
# Every Natts_* constant must equal the width of the catalog it addresses.
#
# The constants in src/columnar_metadata.c size the stack arrays handed to
# heap_modify_tuple, which iterates tupdesc->natts. A constant smaller than its
# table is a stack buffer overflow, not a cosmetic drift: it reads
# (natts - Natts) slots past the end of three arrays at once.
#
# That is not hypothetical. pgcolumnar.options grew ttl_column and ttl_interval
# for retention (#403 item 5a) and the Anum_options_* constants were extended to
# 9, but Natts_options was left at 7. ALTER TABLE ... RENAME COLUMN on a table
# with a declared sort_by then overflowed three arrays in
# PgColumnarRenameDeclaredSortByColumn and aborted the backend, taking the
# cluster into crash recovery with it.
#
# Why the whole matrix never saw it: on an ordinary build the overflow lands in
# adjacent stack slots and is silent, so sorted_mark_rename passed on every
# major. Only the sanitizer build diagnoses it, and sorted_mark_rename was not in
# the sanitizer subset. So this suite checks the INVARIANT rather than waiting
# for the crash, which makes it a matrix check on every major rather than a
# sanitizer-only one.
#
# The widths come from the LIVE SERVER, not from the shipped .sql: the server is
# what heap_modify_tuple will actually iterate, and an upgrade script that adds a
# column changes the server without changing any CREATE TABLE text.
#
# Usage:  test/catalog_natts.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

META="$PGC_SRCDIR/src/columnar_metadata.c"
check "premise: the metadata source is where we think it is" \
	"$([ -f "$META" ] && echo found || echo missing)" "found"

# The constant name is not always the table name: Anum_native_storage_* address
# pgcolumnar.storage. Everything else is identity. Kept as an explicit map so a
# renamed catalog fails loudly here instead of silently skipping.
map_table() {
	case "$1" in
		native_storage) echo storage ;;
		*)              echo "$1" ;;
	esac
}

# --- premise: the constants exist and are actually LOAD-BEARING --------------
# A grep over source text is the weaker kind of check. Premise it on the call
# site, or this suite would approve a file that no longer sizes anything with
# these constants.
nconst=$(grep -cE '^#define Natts_[a-z_]+[[:space:]]+[0-9]+' "$META")
check "premise: the source defines Natts_* constants at all" \
	"$([ "$nconst" -gt 0 ] && echo yes || echo no)" "yes"

nuse=$(grep -cE '\[Natts_[a-z_]+\]' "$META")
check "premise: those constants SIZE arrays, so a wrong one is a real overflow" \
	"$([ "$nuse" -gt 0 ] && echo yes || echo no)" "yes"

nmod=$(grep -c 'heap_modify_tuple' "$META")
check "premise: heap_modify_tuple is still called here (the consumer of those arrays)" \
	"$([ "$nmod" -gt 0 ] && echo yes || echo no)" "yes"
echo "-- constants defined: $nconst   array declarations using them: $nuse   heap_modify_tuple calls: $nmod"

# --- the sweep --------------------------------------------------------------
checked=0
missing=0
while read -r name value; do
	tbl="$(map_table "$name")"
	# Ask the server, never the .sql file.
	width="$(q "SELECT count(*) FROM pg_attribute a
	            JOIN pg_class c ON c.oid = a.attrelid
	            JOIN pg_namespace n ON n.oid = c.relnamespace
	            WHERE n.nspname = 'pgcolumnar' AND c.relname = '$tbl'
	              AND a.attnum > 0 AND NOT a.attisdropped;")"
	if [ -z "$width" ] || [ "$width" = 0 ]; then
		missing=$((missing + 1))
		check "premise: pgcolumnar.$tbl exists on the server (for Natts_$name)" \
			"absent" "present"
		continue
	fi
	checked=$((checked + 1))
	check_num "Natts_$name matches the width of pgcolumnar.$tbl" "$value" "$width"
done < <(grep -oE '^#define Natts_[a-z_]+[[:space:]]+[0-9]+' "$META" \
         | sed -E 's/^#define Natts_//; s/[[:space:]]+/ /')

# inputs == sum(buckets), printed from the data rather than retyped.
echo "-- constants swept: $nconst = checked $checked + unmapped $missing"
check_num "premise: every constant found was swept" "$((checked + missing))" "$nconst"

# --- the other direction: a catalog with no constant ------------------------
# Not a failure on its own -- not every catalog is written through
# heap_modify_tuple -- but it is printed so a new catalog that needs a constant
# is visible rather than silently uncovered.
echo "-- pgcolumnar catalogs on the server, and whether a Natts_* names them:"
for t in $(q "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'pgcolumnar' AND c.relkind = 'r' ORDER BY c.relname;"); do
	cname="$t"
	[ "$t" = storage ] && cname=native_storage
	if grep -qE "^#define Natts_${cname}[[:space:]]" "$META"; then
		echo "     $t: Natts_$cname"
	else
		echo "     $t: (no Natts_ constant)"
	fi
done

pgc_summary
