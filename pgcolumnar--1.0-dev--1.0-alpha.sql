/*
 * pgcolumnar 1.0-dev -> 1.0-alpha
 *
 * The C link names moved into the pgcolumnar namespace (#382), so a build from this
 * version no longer exports the symbols an existing pg_proc recorded. Without this
 * script, replacing the shared library leaves the extension inert: reading an existing
 * columnar table fails with "could not find function columnar_handler", and so does
 * creating a new one.
 *
 * CREATE OR REPLACE keeps each function's OID, so the CREATE ACCESS METHOD binding and
 * every dependency survive. Only prosrc changes. No signature, name, or permission
 * changes here, and no catalog or on-disk format change.
 */

\echo Use "ALTER EXTENSION pgcolumnar UPDATE" to load this file. \quit

CREATE OR REPLACE FUNCTION pgcolumnar.columnar_handler(internal)
	RETURNS table_am_handler
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_handler';


CREATE OR REPLACE FUNCTION pgcolumnar.get_storage_id(rel regclass)
	RETURNS bigint
	LANGUAGE C STABLE STRICT
	AS 'MODULE_PATHNAME', 'pgcolumnar_relation_storageid';


CREATE OR REPLACE FUNCTION pgcolumnar.add_projection(
	rel regclass,
	name text,
	columns text[],
	sort_key text[] DEFAULT '{}')
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_add_projection';


CREATE OR REPLACE FUNCTION pgcolumnar.drop_projection(rel regclass, name text)
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_drop_projection';


CREATE OR REPLACE FUNCTION pgcolumnar.read_projection(rel regclass, name text)
	RETURNS SETOF text
	LANGUAGE C STABLE
	AS 'MODULE_PATHNAME', 'pgcolumnar_read_projection';


CREATE OR REPLACE FUNCTION pgcolumnar.reconstruct_via_projection(rel regclass, name text)
	RETURNS SETOF text
	LANGUAGE C STABLE
	AS 'MODULE_PATHNAME', 'pgcolumnar_reconstruct_via_projection';


CREATE OR REPLACE FUNCTION pgcolumnar.vacuum(tablename regclass, stripe_count int DEFAULT 0)
	RETURNS void
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'pgcolumnar_vacuum';


CREATE OR REPLACE FUNCTION pgcolumnar.vacuum_sorted(
	tablename regclass,
	VARIADIC sort_columns name[])
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_vacuum_sorted';


CREATE OR REPLACE FUNCTION pgcolumnar.vacuum_sorted(tablename regclass)
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_vacuum_sorted';


CREATE OR REPLACE FUNCTION pgcolumnar.cluster(
	tablename regclass,
	VARIADIC columns name[])
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_cluster';


CREATE OR REPLACE FUNCTION pgcolumnar.compact(tablename regclass)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_compact';


CREATE OR REPLACE FUNCTION pgcolumnar.truncate(tablename regclass)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_truncate';


CREATE OR REPLACE FUNCTION pgcolumnar.compact_rewrite(
	tablename regclass,
	min_deleted_fraction float8 DEFAULT 0.2,
	max_groups int DEFAULT 0)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_compact_rewrite';


CREATE OR REPLACE FUNCTION pgcolumnar.recluster(
	tablename regclass,
	VARIADIC columns name[])
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_recluster';


CREATE OR REPLACE FUNCTION pgcolumnar.export_arrow(rel regclass, path text)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_export_arrow';


CREATE OR REPLACE FUNCTION pgcolumnar.export_parquet(rel regclass, path text)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_export_parquet';


CREATE OR REPLACE FUNCTION pgcolumnar.parallel_export_parquet(target regclass, path text,
												   workers int DEFAULT NULL)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_parallel_export_parquet';


CREATE OR REPLACE FUNCTION pgcolumnar.import_arrow(rel regclass, path text)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_import_arrow';


CREATE OR REPLACE FUNCTION pgcolumnar.import_parquet(rel regclass, path text)
	RETURNS bigint
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'pgcolumnar_import_parquet';


CREATE OR REPLACE FUNCTION pgcolumnar.parquet_schema(path text)
	RETURNS TABLE(column_name text, data_type text, nullable boolean)
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'pgcolumnar_parquet_schema';


CREATE OR REPLACE FUNCTION pgcolumnar.read_parquet(path text)
	RETURNS SETOF record
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'pgcolumnar_read_parquet';


CREATE OR REPLACE FUNCTION pgcolumnar.parquet_fdw_handler()
	RETURNS fdw_handler
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_parquet_fdw_handler';


CREATE OR REPLACE FUNCTION pgcolumnar.parquet_fdw_validator(text[], oid)
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_parquet_fdw_validator';


CREATE OR REPLACE FUNCTION pgcolumnar.vm_selftest(rel regclass, blk int)
	RETURNS boolean
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_vm_selftest';


CREATE OR REPLACE FUNCTION pgcolumnar.vm_is_visible(rel regclass, blk int)
	RETURNS boolean
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_vm_is_visible';


CREATE OR REPLACE FUNCTION pgcolumnar.file_split_offsets(path text, workers int)
	RETURNS bigint[]
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'pgcolumnar_file_split_offsets';


CREATE OR REPLACE FUNCTION pgcolumnar.parallel_copy(target regclass, filename text,
										 workers int DEFAULT NULL)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_parallel_copy';



-- #415: the online recluster records what key/kind the sorted run is clustered
-- by, so it can self-gate to a no-op instead of rewriting an unchanged table.
-- Idempotent so the one supported alpha upgrade path reaches full behavior; a
-- binary swap without these degrades safely (the reader treats absent columns
-- as unknown -> never no-ops, sort_key NULL).
ALTER TABLE pgcolumnar.storage ADD COLUMN IF NOT EXISTS sorted_by name[];
ALTER TABLE pgcolumnar.storage ADD COLUMN IF NOT EXISTS sorted_kind text;

-- #415: sort_status reports the run's recorded key (storage.sorted_by),
-- not just the declared options.sort_by. Replaced here so an upgrade reaches
-- full behavior; a binary swap without it keeps the old body (sort_key NULL
-- on a clustered-but-undeclared table), which is safe, just not complete.
CREATE OR REPLACE FUNCTION pgcolumnar.sort_status(
	rel regclass,
	OUT sort_key name[],
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
		   (SELECT count(*)::bigint FROM g),
		   (SELECT count(*)::bigint FROM g WHERE g.in_run),
		   (SELECT count(*)::bigint FROM g WHERE NOT g.in_run),
		   COALESCE((SELECT sum(g.row_count)::bigint FROM g WHERE g.in_run), 0::bigint),
		   COALESCE((SELECT sum(g.row_count)::bigint FROM g WHERE NOT g.in_run), 0::bigint)
	INTO sort_key, total_groups, sorted_groups, appended_groups, sorted_rows, appended_rows;
END;
$sort_status$;
