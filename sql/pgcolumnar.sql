-- pgColumnar installcheck smoke test.
--
-- This is the conventional entry point (make installcheck), not the project's
-- gate. The gate is test/run_all_versions.sh, which asserts properties with
-- explicit controls; see docs/testing.md. What this file exists for is that
-- REGRESS was empty, so make installcheck reported success while running
-- nothing, which is the one failure mode this project refuses everywhere else.
--
-- Constraints it is written under:
--   * idempotent. It drops what it creates, at the start as well as the end, so
--     running it twice against the same database produces the same output.
--   * deterministic across PostgreSQL 15 to 19. No plan output, no sizes, no
--     storage ids, no timings, and every result set is ordered. NOTICEs are
--     suppressed because DROP IF EXISTS emits one only when the object is
--     absent, which would differ between the first run and the second.
--
-- The server must have pgcolumnar in shared_preload_libraries. Without it the
-- CREATE EXTENSION below fails, which is the correct and legible outcome.

SET client_min_messages = warning;

DROP TABLE IF EXISTS pgc_smoke_c;
DROP TABLE IF EXISTS pgc_smoke_h;
CREATE EXTENSION IF NOT EXISTS pgcolumnar;

-- A columnar table and a heap mirror. Every assertion below compares the two
-- rather than a literal, so the test states "columnar agrees with heap" instead
-- of restating values that would have to be maintained by hand.
CREATE TABLE pgc_smoke_c (id int, v text, n numeric) USING pgcolumnar;
CREATE TABLE pgc_smoke_h (id int, v text, n numeric);

INSERT INTO pgc_smoke_c
    SELECT g, md5(g::text), (g * 1.5)::numeric FROM generate_series(1, 5000) g;
INSERT INTO pgc_smoke_h
    SELECT g, md5(g::text), (g * 1.5)::numeric FROM generate_series(1, 5000) g;

SELECT 'am' AS check,
       (SELECT a.amname FROM pg_class c JOIN pg_am a ON a.oid = c.relam
         WHERE c.relname = 'pgc_smoke_c') AS got;

SELECT 'count' AS check,
       (SELECT count(*) FROM pgc_smoke_c) = (SELECT count(*) FROM pgc_smoke_h) AS agrees;
SELECT 'aggregates' AS check,
       (SELECT (min(id), max(id), sum(n)) FROM pgc_smoke_c)
       = (SELECT (min(id), max(id), sum(n)) FROM pgc_smoke_h) AS agrees;
SELECT 'content' AS check,
       (SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM pgc_smoke_c t)
       = (SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM pgc_smoke_h t) AS agrees;

-- Qualified read, which is the chunk-group skipping path.
SELECT 'qualified' AS check,
       (SELECT count(*) FROM pgc_smoke_c WHERE id BETWEEN 100 AND 200)
       = (SELECT count(*) FROM pgc_smoke_h WHERE id BETWEEN 100 AND 200) AS agrees;

-- Mutation.
UPDATE pgc_smoke_c SET v = 'updated' WHERE id <= 10;
UPDATE pgc_smoke_h SET v = 'updated' WHERE id <= 10;
DELETE FROM pgc_smoke_c WHERE id > 4900;
DELETE FROM pgc_smoke_h WHERE id > 4900;

SELECT 'after dml' AS check,
       (SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM pgc_smoke_c t)
       = (SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM pgc_smoke_h t) AS agrees;

-- Index and index scan.
CREATE INDEX pgc_smoke_c_id ON pgc_smoke_c (id);
ANALYZE pgc_smoke_c;
SET enable_seqscan = off;
SELECT 'index scan' AS check,
       (SELECT v FROM pgc_smoke_c WHERE id = 4242)
       = (SELECT v FROM pgc_smoke_h WHERE id = 4242) AS agrees;
RESET enable_seqscan;

-- Per-table options round-trip.
SELECT pgcolumnar.set_options('pgc_smoke_c', compression => 'pglz');
SELECT 'options' AS check, compression AS got
  FROM pgcolumnar.options WHERE regclass = 'pgc_smoke_c'::regclass;
SELECT pgcolumnar.reset_options('pgc_smoke_c');

-- A projection reads what the base table holds.
SELECT pgcolumnar.add_projection('pgc_smoke_c', 'pgc_smoke_p',
                                 ARRAY['id','v'], ARRAY['id']) IS NOT NULL AS declared;
SELECT 'projection' AS check,
       (SELECT count(*) FROM pgcolumnar.read_projection('pgc_smoke_c', 'pgc_smoke_p'))
       = (SELECT count(*) FROM pgc_smoke_c) AS agrees;
SELECT pgcolumnar.drop_projection('pgc_smoke_c', 'pgc_smoke_p');

-- Maintenance runs and does not change what the table returns.
VACUUM pgc_smoke_c;
SELECT 'after vacuum' AS check,
       (SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM pgc_smoke_c t)
       = (SELECT md5(string_agg(t::text, '' ORDER BY t::text)) FROM pgc_smoke_h t) AS agrees;

DROP TABLE pgc_smoke_c;
DROP TABLE pgc_smoke_h;
