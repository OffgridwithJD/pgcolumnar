/*
 * pgcolumnar--1.0-alpha4--1.0-alpha5.sql
 *
 * Upgrade from 1.0-alpha4 to 1.0-alpha5.
 *
 * 1.0-alpha4 is a PUBLISHED pre-release (tag v1.0-alpha4), so
 * pgcolumnar--1.0-alpha3--1.0-alpha4.sql is a shipped artifact and must not
 * change. Anything alpha5 adds to the catalog belongs here, or an existing
 * alpha4 install would never run it and a fresh install would silently get a
 * different catalog from an upgraded one.
 *
 * EMPTY ON PURPOSE, AND THAT IS WHY IT EXISTS. This change opens the cycle and
 * nothing else. The file is here so that the work already pointed at alpha5 --
 * the zone-map summary that overlap and containment pruning needs (#1144), and
 * cascading step 2 (#1139) -- appends to a script that already exists rather
 * than racing to create it, and so that the version bump is reviewable on its
 * own rather than inside a feature diff.
 *
 * PostgreSQL requires the file to exist and to be readable; an upgrade script
 * that adds nothing is a valid one. `ALTER EXTENSION pgcolumnar UPDATE` from
 * alpha4 reaches alpha5 through this file and changes no catalog object, which
 * is what test/extension_upgrade.sh asserts by comparing the upgraded catalog
 * against a fresh install of the new version.
 */

-- The greatest upper bound of a RANGE column's values in a zone map unit
-- (#1144). Overlap and containment cannot use minimum/maximum: those are
-- recorded under the range type's btree ordering, which sorts by lower bound
-- and then upper bound, and the lexicographically largest range is not the one
-- reaching furthest right. A chunk holding [1,2) and [3,100) has the same
-- maximum as one holding [1,2) and [3,4).
--
-- THREE STATES, and the third is why this is a bytea rather than the element
-- type. NULL means no summary, and a reader must not prune from above -- which
-- is what every row written before this column existed carries. A ZERO-LENGTH
-- value means the unit holds a range that is unbounded above: also do not prune,
-- but a different fact, and the field is PRESENT and understated rather than
-- absent, which a two-state design cannot express. Any other length is the
-- bound, encoded with the range's ELEMENT type.
--
-- Only range columns populate it; every other column leaves it NULL. The column
-- is in pgcolumnar--1.0-alpha5.sql too, so a FRESH install and an UPGRADED one
-- converge; native_upgrade_converge.sh is what asserts that.
ALTER TABLE pgcolumnar.zone_map ADD COLUMN IF NOT EXISTS max_upper bytea;
