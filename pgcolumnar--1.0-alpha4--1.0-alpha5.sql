/* pgcolumnar 1.0-alpha4 -> 1.0-alpha5 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pgcolumnar UPDATE TO '1.0-alpha5'" to load this file. \quit

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
-- Only range columns populate it; every other column leaves it NULL.
ALTER TABLE pgcolumnar.zone_map ADD COLUMN IF NOT EXISTS max_upper bytea;
