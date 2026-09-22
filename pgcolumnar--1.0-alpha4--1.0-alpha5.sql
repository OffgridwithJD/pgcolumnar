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

-- Nothing yet. Append here; do not edit an alpha4 script.
