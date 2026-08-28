/* pgcolumnar 1.0-alpha2 --> 1.0-alpha3 upgrade
 * Generated from the catalog delta between a fresh 1.0-alpha2 and 1.0-alpha3
 * install and verified by test/native_upgrade_converge.sh, which asserts that an
 * upgraded catalog matches a fresh one in definition, ACL and comment for every
 * object.
 *
 * The 1.0-alpha3 cycle so far changes one function signature. Everything else in
 * [Unreleased] is shared-library only and needs no catalog change.
 */
\echo Use "ALTER EXTENSION pgcolumnar UPDATE" to load this file. \quit

-- New catalog for pgcolumnar.parallel_copy's opt-in load dedup (#403 item 7).
-- Loads pgcolumnar.parallel_copy has already performed, for its opt-in dedup
-- (#403 item 7). One row per (table, file fingerprint) that committed.
--
-- The fingerprint is the SHA-256 of the loaded file's bytes, so a file that
-- changed at the same path is a different load. Path, size and mtime would all
-- call that the same file.
--
-- The row is written AFTER the data commits, never before. A crash between the
-- two leaves data with no fingerprint, so a retry loads again, which is the
-- behaviour without this feature and is the safe direction. The reverse order
-- would leave a fingerprint with no data and refuse rows that were never stored.
CREATE TABLE pgcolumnar.load_fingerprint (
	relation_oid oid NOT NULL,
	fingerprint bytea NOT NULL,       -- SHA-256 of the file's bytes
	rows bigint NOT NULL,
	loaded_at timestamptz NOT NULL DEFAULT now()
);
-- NOT unique, deliberately. The lookup is an existence test, and a unique
-- index would turn the one case that can produce a second row into an ERROR
-- raised AFTER the data committed: two concurrent loads of the same file both
-- check before either records, both commit, and the loser's record insert would
-- fail, reporting failure for a load that succeeded. A duplicate record is
-- harmless; a false failure is not.
CREATE INDEX load_fingerprint_pkey
	ON pgcolumnar.load_fingerprint USING btree (relation_oid, fingerprint);

-- Declared retention for pgcolumnar.expire (#403 item 5a). Nothing drops rows on
-- its own; expire is called by name.
ALTER TABLE pgcolumnar.options ADD COLUMN IF NOT EXISTS ttl_column name;
ALTER TABLE pgcolumnar.options ADD COLUMN IF NOT EXISTS ttl_interval interval;

-- Three functions gain parameters, which changes their signatures, so none can
-- be a CREATE OR REPLACE: sort_status (#761), parallel_copy (#403 item 7) and
-- set_options (#403 item 5a).
DROP FUNCTION IF EXISTS pgcolumnar.sort_status(regclass);
DROP FUNCTION IF EXISTS pgcolumnar.parallel_copy(regclass, text, int);
DROP FUNCTION IF EXISTS pgcolumnar.set_options(regclass, int, int, name, int, name, name[]);

CREATE FUNCTION pgcolumnar.set_options(
	table_name regclass,
	chunk_group_row_limit int DEFAULT NULL,
	stripe_row_limit int DEFAULT NULL,
	compression name DEFAULT NULL,
	compression_level int DEFAULT NULL,
	encode_effort name DEFAULT NULL,
	sort_by name[] DEFAULT NULL,
	ttl_column name DEFAULT NULL,
	ttl_interval interval DEFAULT NULL)
	RETURNS void
	LANGUAGE plpgsql
	AS $set_options$
DECLARE
	col name;
BEGIN
	/*
	 * The options are per-relation and are read by the columnar writer, so a row
	 * recorded for a relation that is not columnar can never be used. Storing one
	 * is not merely useless: the drop hook that clears pgcolumnar.options fires
	 * only for columnar relations, so the row outlives the table and is left
	 * keyed to a dangling oid that a later relation reusing that oid inherits.
	 * Measured before this guard, on the same cluster: set_options on a heap
	 * table stored a row, DROP TABLE left it behind, and regclass then rendered
	 * as the bare oid; the identical sequence on a columnar table cleaned up.
	 *
	 * Rejecting is safe for the one workflow that could want the other order:
	 * ALTER TABLE ... SET ACCESS METHOD pgcolumnar keeps the relation's oid
	 * (measured), so options set after the conversion apply to the same relation
	 * a caller would have been trying to name before it.
	 *
	 * The ERRCODE is explicit. plpgsql's RAISE EXCEPTION defaults to P0001, and
	 * the C paths raise this same sentence with ERRCODE_WRONG_OBJECT_TYPE
	 * (42809). Without it the identical message carried two different SQLSTATEs
	 * depending on which path refused the caller, in a tree whose own privilege
	 * suites deliberately assert SQLSTATE rather than message text.
	 *
	 * relkind is part of the test, and it is what makes the guard match the
	 * cleanup rather than merely look strict. The drop hook returns before it
	 * examines the access method for anything that is not an ordinary table
	 * (columnar_tableam.c: `if (get_rel_relkind(objectId) != RELKIND_RELATION)
	 * return;`), so 'r' is exactly the set of relations whose options row can
	 * ever be cleaned up. From PG17 a PARTITIONED table may carry an access
	 * method, so `relam = pgcolumnar` alone admits a parent that has no storage,
	 * that the writer never writes, and whose row the hook will never clear.
	 * Measured on 17.6 with the amname-only test: accepted, one row recorded,
	 * and the row still there after DROP TABLE keyed to the dropped oid, while
	 * an ordinary columnar table in the same run cleaned up. PG16 and earlier
	 * cannot reach it -- they refuse `PARTITION BY ... USING pgcolumnar`
	 * outright, checked on 16.14 -- so this is PG17, 18 and 19.
	 */
	IF NOT EXISTS (SELECT 1 FROM pg_class c
					 JOIN pg_am a ON a.oid = c.relam
					WHERE c.oid = table_name
					  AND a.amname = 'pgcolumnar'
					  AND c.relkind = 'r') THEN
		RAISE EXCEPTION 'relation "%" is not a columnar table', table_name
			USING ERRCODE = 'wrong_object_type',
				HINT = 'Per-table options are read by the columnar writer and '
				'apply only to an ordinary table using the pgcolumnar access '
				'method. A partitioned table has no storage of its own: set the '
				'options on each partition. Otherwise convert the table first '
				'with ALTER TABLE ... SET ACCESS METHOD pgcolumnar, then set '
				'the options.';
	END IF;

	IF encode_effort IS NOT NULL AND
	   encode_effort NOT IN ('full', 'fast') THEN
		RAISE EXCEPTION 'unknown columnar encode_effort "%"', encode_effort
			USING HINT = 'Valid values are "full" and "fast".';
	END IF;

	IF compression IS NOT NULL AND
	   compression NOT IN ('none', 'pglz', 'lz4', 'zstd') THEN
		RAISE EXCEPTION 'unknown columnar compression "%"', compression;
	END IF;

	/*
	 * Bound the integer limits to the same valid ranges as the instance-wide
	 * GUCs (pgcolumnar.chunk_group_row_limit, pgcolumnar.stripe_row_limit,
	 * pgcolumnar.compression_level). A per-table value outside these ranges is
	 * rejected here rather than stored: a limit of zero or below would produce
	 * a stripe whose recorded chunk_row_count is zero and make the row-number
	 * arithmetic (chunk id = offset / chunk_row_count) divide by zero on
	 * delete, update, and index fetch.
	 */
	IF chunk_group_row_limit IS NOT NULL AND chunk_group_row_limit < 100 THEN
		RAISE EXCEPTION 'chunk_group_row_limit must be at least 100';
	END IF;
	IF stripe_row_limit IS NOT NULL AND stripe_row_limit < 1000 THEN
		RAISE EXCEPTION 'stripe_row_limit must be at least 1000';
	END IF;
	IF compression_level IS NOT NULL AND
	   (compression_level < 1 OR compression_level > 22) THEN
		RAISE EXCEPTION 'compression_level must be between 1 and 22';
	END IF;

	/*
	 * sort_by declares the physical sort key applied by vacuum_sorted() with no
	 * explicit columns (#288). This is a cheap early check only: each named
	 * column must exist, not be dropped, and not be a VIRTUAL generated column
	 * (its value is not stored, so it cannot be sorted on). Orderability
	 * (a default btree ordering operator) is NOT checked here -- the C apply
	 * path is authoritative and re-resolves and re-validates the names every
	 * run, because a column can be dropped or altered after it is declared.
	 * attgenerated is '' or 's' before PG18; 'v' only exists from PG18, so the
	 * "<> 'v'" test is correct and inert on older majors.
	 */
	IF sort_by IS NOT NULL THEN
		FOREACH col IN ARRAY sort_by LOOP
			IF NOT EXISTS (SELECT 1 FROM pg_attribute a
						   WHERE a.attrelid = table_name
							 AND a.attname = col
							 AND a.attnum > 0
							 AND NOT a.attisdropped
							 AND a.attgenerated <> 'v') THEN
				RAISE EXCEPTION 'column "%" cannot be used in sort_by for table %',
					col, table_name
					USING HINT = 'The column must exist, must not be dropped, '
						'and must not be a VIRTUAL generated column.';
			END IF;
		END LOOP;
	END IF;

	INSERT INTO pgcolumnar.options AS o
		(regclass, chunk_group_row_limit, stripe_row_limit,
		 compression, compression_level, encode_effort, sort_by,
		 ttl_column, ttl_interval)
	VALUES (table_name, chunk_group_row_limit, stripe_row_limit,
			compression, compression_level, encode_effort, sort_by,
			ttl_column, ttl_interval)
	ON CONFLICT (regclass) DO UPDATE SET
		chunk_group_row_limit =
			COALESCE(EXCLUDED.chunk_group_row_limit, o.chunk_group_row_limit),
		stripe_row_limit =
			COALESCE(EXCLUDED.stripe_row_limit, o.stripe_row_limit),
		compression =
			COALESCE(EXCLUDED.compression, o.compression),
		compression_level =
			COALESCE(EXCLUDED.compression_level, o.compression_level),
		encode_effort =
			COALESCE(EXCLUDED.encode_effort, o.encode_effort),
		sort_by =
			COALESCE(EXCLUDED.sort_by, o.sort_by),
		ttl_column =
			COALESCE(EXCLUDED.ttl_column, o.ttl_column),
		ttl_interval =
			COALESCE(EXCLUDED.ttl_interval, o.ttl_interval);
END;
$set_options$;

COMMENT ON FUNCTION pgcolumnar.set_options(regclass, int, int, name, int, name, name[], name, interval)
	IS 'set per-table columnar options; NULL leaves a value unchanged. sort_by declares the physical sort key applied by vacuum_sorted() with no explicit columns (#288); it is NOT auto-maintained -- rows inserted after a sort append in insert order, so re-run vacuum_sorted() to re-establish it, like PostgreSQL CLUSTER';

CREATE FUNCTION pgcolumnar.expire(tablename regclass)
	RETURNS bigint
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'pgcolumnar_expire';

COMMENT ON FUNCTION pgcolumnar.expire(regclass)
	IS 'drop row groups whose rows are all older than the retention declared by set_options(ttl_column, ttl_interval), without reading or rewriting them (#403)';

CREATE FUNCTION pgcolumnar.parallel_copy(target regclass, filename text,
										 workers int DEFAULT NULL,
										 dedup boolean DEFAULT false)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_parallel_copy';

COMMENT ON FUNCTION pgcolumnar.parallel_copy(regclass, text, int, boolean)
	IS 'atomic parallel bulk load of a COPY text file into a columnar table using background workers: a single columnar table (any row order), or a RANGE-partitioned columnar table sorted by the partition key with one distinct partition set per worker (#300). With dedup, a file already loaded into this table is refused rather than loaded twice (#403)';

CREATE FUNCTION pgcolumnar.sort_status(
	rel regclass,
	OUT sort_key name[],
	OUT sorted_kind text,
	OUT total_groups bigint,
	OUT sorted_groups bigint,
	OUT appended_groups bigint,
	OUT sorted_rows bigint,
	OUT appended_rows bigint)
	RETURNS record
	-- SECURITY DEFINER, like stats() (#560): the body reads pgcolumnar's internal
	-- catalogs (storage, row_group, options), which carry no GRANT, so an
	-- invoker-rights function false-denied a table's own owner on their own table
	-- (#608). require_caller_select gates the REAL caller via GetOuterUserId(), so
	-- definer rights do not widen who may read a table's sort status. search_path
	-- is pinned as a definer function must.
	LANGUAGE plpgsql STABLE SECURITY DEFINER
	SET search_path = pg_catalog, pg_temp
	AS $sort_status$
BEGIN
	PERFORM pgcolumnar.require_caller_select(rel);
	WITH s AS (
		SELECT st.storage_id, st.sorted_through, st.sorted_from
		FROM pgcolumnar.storage st
		WHERE st.storage_id = pgcolumnar.get_storage_id(rel)
	),
	g AS (
		-- A NULL mark means the storage was never ordered, so no group is in the
		-- run. Comparing against NULL would make every count NULL instead.
		--
		-- The run is a range, not everything below a boundary (#342). A group
		-- numbered below sorted_from was not written by the rewrite that set the
		-- mark: its stripe id was drawn before the rewrite's first, so it is a
		-- concurrent writer's group and is not ordered. sorted_from is NULL only
		-- for a mark written before this column existed, where the old
		-- everything-below reading is kept.
		SELECT rg.row_count,
			   (s.sorted_through IS NOT NULL
				AND rg.group_number <= s.sorted_through
				AND (s.sorted_from IS NULL
					 OR rg.group_number >= s.sorted_from)) AS in_run
		FROM pgcolumnar.row_group rg
		JOIN s ON rg.storage_id = s.storage_id
	)
	-- sort_key reports the ACTUAL clustering recorded by the last recluster
	-- (#415, storage.sorted_by), falling back to the declared options.sort_by
	-- when nothing has been reclustered yet. Before #415 this read only the
	-- declared key, so it was NULL on a table clustered but never declared.
	SELECT COALESCE(
			(SELECT st.sorted_by FROM pgcolumnar.storage st
			 WHERE st.storage_id = pgcolumnar.get_storage_id(rel)),
			(SELECT o.sort_by FROM pgcolumnar.options o WHERE o.regclass = rel)),
		   -- HOW that key is applied (#761). sort_key names the columns and says
		   -- nothing about whether they are sorted or laid on a Z-order curve,
		   -- and a Z-order over two or more columns is not a sort on any one of
		   -- them. The catalog has carried this since #758; pgcolumnar.storage
		   -- has no GRANT and is superuser-only, so a table's own owner could
		   -- read it nowhere. NULL when the storage was never ordered, or was
		   -- ordered before the column existed.
		   (SELECT st.sorted_kind FROM pgcolumnar.storage st
			WHERE st.storage_id = pgcolumnar.get_storage_id(rel)),
		   (SELECT count(*)::bigint FROM g),
		   (SELECT count(*)::bigint FROM g WHERE g.in_run),
		   (SELECT count(*)::bigint FROM g WHERE NOT g.in_run),
		   COALESCE((SELECT sum(g.row_count)::bigint FROM g WHERE g.in_run), 0::bigint),
		   COALESCE((SELECT sum(g.row_count)::bigint FROM g WHERE NOT g.in_run), 0::bigint)
	INTO sort_key, sorted_kind, total_groups, sorted_groups, appended_groups,
		 sorted_rows, appended_rows;
END;
$sort_status$;

COMMENT ON FUNCTION pgcolumnar.sort_status(regclass)
	IS 'how much of an ordered columnar table is still in its ordered run, and by what kind of ordering (#301, #761)';
