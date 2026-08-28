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

-- Two functions gain a parameter, which changes their signatures, so neither can
-- be a CREATE OR REPLACE: sort_status (#761) and parallel_copy (#403 item 7).
DROP FUNCTION IF EXISTS pgcolumnar.sort_status(regclass);
DROP FUNCTION IF EXISTS pgcolumnar.parallel_copy(regclass, text, int);

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
