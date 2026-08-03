/* pgColumnar 1.0 - native (PGCN v1) metadata catalog and access method
 * registration.
 *
 * The catalog matches section 11 of
 * design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md. Column order and index
 * definitions are part of the on-disk format.
 *
 * The catalog holds the native storage, row_group, column_chunk, zone_map,
 * and bloom tables, the shared delete_vector and options tables, the storageid_seq
 * sequence, the columnar_handler function, and the columnar access method.
 */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgcolumnar" to load this file. \quit

/* ---------------------------------------------------------------------------
 * Sequences (spec 7.6)
 * ------------------------------------------------------------------------- */

CREATE SEQUENCE pgcolumnar.storageid_seq
	MINVALUE 10000000000
	NO CYCLE;

/* ---------------------------------------------------------------------------
 * pgcolumnar.delete_vector (spec 7.5)
 *
 * Tracks deleted rows for updates and deletes without rewriting stripes. One
 * row per chunk group, keyed by group_number; a set bit in "bitmap" marks a
 * deleted row (bit i is the group's i-th row, row_group.first_row_number + i,
 * LSB-first in byte i/8). deleted_count is the number of set bits.
 * ------------------------------------------------------------------------- */

CREATE TABLE pgcolumnar.delete_vector (
	storage_id bigint NOT NULL,
	group_number bigint NOT NULL,
	bitmap bytea,
	deleted_count integer NOT NULL
);

CREATE UNIQUE INDEX delete_vector_pkey
	ON pgcolumnar.delete_vector USING btree (storage_id, group_number);

/* ---------------------------------------------------------------------------
 * pgcolumnar.options (spec 7.4)
 *
 * Per-table overrides of the instance-wide compression, compression level,
 * chunk-group row limit, and stripe row limit. A NULL column means the table
 * uses the instance default (the GUC) for that option. Keyed by regclass.
 * ------------------------------------------------------------------------- */

CREATE TABLE pgcolumnar.options (
	regclass regclass NOT NULL,
	chunk_group_row_limit integer,
	stripe_row_limit integer,
	compression_level integer,
	compression name,
	encode_effort name,
	sort_by name[]                     -- declared physical sort key (#288)
);

/*
 * sort_by holds COLUMN NAMES, not attnums, on purpose. pgcolumnar.options is
 * the one catalog carried through pg_dump (pg_extension_config_dump below); a
 * plain (non-binary-upgrade) pg_dump does not re-emit dropped columns, so live
 * attnums renumber densely on restore while names do not. The governing rule:
 * store NAMES in the dumped catalog (regclass, sort_by); store ATTNUMS only in
 * the storage_id-keyed catalogs that are NOT dumped (projection.sort_key,
 * row_group.sort_key), which are regenerated on restore anyway. See the
 * regclass rationale below. NULL means no declared sort key; the apply path
 * (vacuum_sorted with no explicit columns) resolves the names to attnums each
 * time and re-validates them, so a later DROP/RENAME of a named column is
 * caught then rather than corrupting anything.
 */

CREATE UNIQUE INDEX options_pkey
	ON pgcolumnar.options USING btree (regclass);

/*
 * Carry the per-table options through pg_dump (#248).
 *
 * Rows in an extension's own tables are not dumped unless the extension says so.
 * Without this, pg_dump emitted the table definition and its data but never the
 * options row, so a restored columnar table silently reverted to default
 * stripe/chunk limits, compression and encode_effort. Silent, because nothing
 * fails: the data is all there and only the settings are gone.
 *
 * This table and ONLY this table. Every other pgcolumnar catalog table is keyed
 * by storage_id, which is assigned when the relation is created, so a restore
 * generates new ones -- dumping those rows would restore metadata pointing at
 * storage that no longer exists, which is worse than losing it. options is keyed
 * by regclass, a name that survives dump and restore, and it holds user intent
 * rather than physical layout, which is the same reason it is the only one worth
 * carrying.
 *
 * Projections are user intent too and are still lost across a dump, for the
 * storage_id reason above; re-emitting pgcolumnar.add_projection() calls is a
 * different mechanism and its own problem.
 */
SELECT pg_catalog.pg_extension_config_dump('pgcolumnar.options', '');

/*
 * The declared intent behind each projection, as opposed to pgcolumnar.projection
 * which records the materialized result (#266).
 *
 * pgcolumnar.projection is keyed by storage_id and stores attnums, so pg_dump
 * cannot carry it: a restore assigns new storage ids, and rows pointing at
 * storage that does not exist would be worse than losing them. This table is
 * keyed by regclass and stores column NAMES, for the same reason
 * pgcolumnar.options is keyed by regclass and the sort_by key stores names: a
 * name survives a dump and a restore, and a restore renumbers an attnum.
 *
 * So a dump carries the declaration and not the data. After a restore the
 * declarations are present and the projection storage is not, and
 * pgcolumnar.rebuild_projections() materializes them. Readers never consult this
 * table. They read pgcolumnar.projection, where a row appears only after its
 * storage exists.
 */
CREATE TABLE pgcolumnar.projection_declaration (
	rel regclass NOT NULL,
	name name NOT NULL,
	columns text[] NOT NULL,
	sort_key text[] NOT NULL
);

CREATE UNIQUE INDEX projection_declaration_pkey
	ON pgcolumnar.projection_declaration USING btree (rel, name);

SELECT pg_catalog.pg_extension_config_dump('pgcolumnar.projection_declaration', '');

/* ---------------------------------------------------------------------------
 * pgcolumnar.projection (gap 26)
 *
 * Multiple physical projections per table (C-Store). Each projection is a named,
 * ordered subset of the table's columns stored as its own columnar storage
 * (proj_storage_id) sorted on sort_key, sharing the row-number identity space.
 * projection_id 0 is the implicit base projection (all columns, insert order);
 * a table with no rows here has a single implicit base projection, so a table
 * with no declared projections behaves as one with only its base.
 * ------------------------------------------------------------------------- */

CREATE TABLE pgcolumnar.projection (
	storage_id bigint NOT NULL,       -- the table's base storage id
	projection_id integer NOT NULL,   -- 0 = base, 1..N additional
	name name NOT NULL,
	proj_storage_id bigint NOT NULL,  -- this projection's own storage id
	sort_key smallint[] NOT NULL,     -- attnums in sort order ({} = insert order)
	columns smallint[] NOT NULL       -- attnums stored (base = all live columns)
);

CREATE UNIQUE INDEX projection_pkey
	ON pgcolumnar.projection USING btree (storage_id, projection_id);

CREATE UNIQUE INDEX projection_name_idx
	ON pgcolumnar.projection USING btree (storage_id, name);

CREATE UNIQUE INDEX projection_storage_idx
	ON pgcolumnar.projection USING btree (proj_storage_id);

/* ---------------------------------------------------------------------------
 * Native format catalog (format PGCN v1).
 *
 * The native on-disk format (design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md
 * section 11). Dropped with the extension; per-table row cleanup is wired
 * into ColumnarDeleteMetadata.
 * ------------------------------------------------------------------------- */

CREATE TABLE pgcolumnar.storage (
	storage_id bigint NOT NULL,       -- native relation storage id
	relation_oid oid NOT NULL,
	format_version integer NOT NULL,  -- native format major version (1)
	vector_length integer NOT NULL,   -- values per vector (1024)
	row_group_limit integer NOT NULL, -- max rows per row group
	-- The row group number the last ordering rewrite ended at (#301). NULL means
	-- the storage was never ordered.
	--
	-- pgcolumnar.vacuum_sorted, pgcolumnar.cluster and pgcolumnar.recluster order
	-- every live row, so every group up to and including this number is part of
	-- one ordered run. Groups numbered above it were written later, in insert
	-- order, and are the unsorted tail. That is what makes a sorted layout decay,
	-- and pgcolumnar.sort_status reports the size of each part.
	--
	-- It is a boundary rather than a count because the online maintenance paths
	-- retire groups and write replacements with fresh, higher numbers. A count
	-- would silently re-point at those replacements as the run shrank; a boundary
	-- leaves them above the mark, where they belong.
	--
	-- It lives here rather than in pgcolumnar.options because a storage row has
	-- exactly the right lifetime. Any rewrite creates a new storage id, so an
	-- unsorted vacuum leaves this NULL and correctly reports the table as
	-- unsorted, with no invalidation step. A value in an options row, which is
	-- keyed by relation, would outlive the layout it describes.
	sorted_through bigint,
	-- Lower end of the ordered run (#342). The run is [sorted_from,
	-- sorted_through]; a bare upper bound cannot exclude a concurrently written
	-- group whose id was drawn below the rewrite's own first id, which is how a
	-- foreign group came to be counted as ordered.
	sorted_from bigint
);
CREATE UNIQUE INDEX storage_pkey
	ON pgcolumnar.storage USING btree (storage_id);

CREATE TABLE pgcolumnar.row_group (
	storage_id bigint NOT NULL,
	group_number bigint NOT NULL,     -- 0-based row group ordinal
	file_offset bigint NOT NULL,      -- logical byte offset of the group
	row_count bigint NOT NULL,
	byte_length bigint NOT NULL,
	first_row_number bigint NOT NULL, -- row number of the group's first row
	sort_key smallint[] NOT NULL DEFAULT '{}'  -- attnums the group is sorted on
);
CREATE UNIQUE INDEX row_group_pkey
	ON pgcolumnar.row_group USING btree (storage_id, group_number);

CREATE TABLE pgcolumnar.column_chunk (
	storage_id bigint NOT NULL,
	group_number bigint NOT NULL,
	column_index smallint NOT NULL,   -- 0-based attribute position
	value_count bigint NOT NULL,
	encoding_descriptor bytea NOT NULL, -- the chosen cascade (Phase D4)
	block_codec smallint NOT NULL,    -- optional final block codec (0 = none)
	page_offset bigint NOT NULL,      -- logical byte offset of the chunk's page
	page_length bigint NOT NULL
);
CREATE UNIQUE INDEX column_chunk_pkey
	ON pgcolumnar.column_chunk USING btree (storage_id, group_number, column_index);

CREATE TABLE pgcolumnar.zone_map (
	storage_id bigint NOT NULL,
	group_number bigint NOT NULL,
	column_index smallint NOT NULL,
	vector_index integer NOT NULL,    -- -1 for the whole-chunk aggregate
	minimum bytea,                    -- encoded per the column type
	maximum bytea,
	sum numeric,                      -- NULL when the type has no sum
	value_count bigint NOT NULL,
	null_count bigint NOT NULL
);
CREATE UNIQUE INDEX zone_map_pkey
	ON pgcolumnar.zone_map USING btree (storage_id, group_number, column_index, vector_index);

-- Per-column-chunk bloom filter for equality skipping on hashable columns
-- (native spec 7.2). One row per (storage_id, group_number, column_index).
CREATE TABLE pgcolumnar.bloom (
	storage_id bigint NOT NULL,
	group_number bigint NOT NULL,
	column_index smallint NOT NULL,
	filter bytea NOT NULL
);
CREATE UNIQUE INDEX bloom_pkey
	ON pgcolumnar.bloom USING btree (storage_id, group_number, column_index);

/* ---------------------------------------------------------------------------
 * pgcolumnar.free_space (Phase F physical reclaim)
 *
 * Freed logical byte ranges from retired row groups, available for reuse by a
 * later stripe reservation once no snapshot can still read them. file_offset is
 * page-aligned; freed_xid is the retiring transaction's id, and the range is
 * reusable only once the oldest-xmin horizon has passed it. Reuse makes online
 * compaction space-neutral instead of forever advancing the file highwater.
 * ------------------------------------------------------------------------- */

CREATE TABLE pgcolumnar.free_space (
	storage_id bigint NOT NULL,
	file_offset bigint NOT NULL,
	byte_length bigint NOT NULL,
	freed_xid bigint NOT NULL
);
CREATE UNIQUE INDEX free_space_pkey
	ON pgcolumnar.free_space USING btree (storage_id, file_offset);
CREATE INDEX free_space_fit
	ON pgcolumnar.free_space USING btree (storage_id, byte_length);

/* ---------------------------------------------------------------------------
 * Access method (spec 8.1)
 * ------------------------------------------------------------------------- */

CREATE FUNCTION pgcolumnar.columnar_handler(internal)
	RETURNS table_am_handler
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_handler';

CREATE ACCESS METHOD pgcolumnar
	TYPE TABLE
	HANDLER pgcolumnar.columnar_handler;

COMMENT ON ACCESS METHOD pgcolumnar IS 'pgColumnar column-oriented storage';

/* ---------------------------------------------------------------------------
 * Conversion between heap and columnar (spec 8.2)
 *
 * alter_table_set_access_method converts a table between heap and columnar by
 * driving PostgreSQL's own ALTER TABLE ... SET ACCESS METHOD, which rewrites
 * the table through the target access method (columnar's insert path when
 * converting to columnar, its scan path when converting away). Row counts and
 * values round-trip. "t" is a table name (optionally schema-qualified);
 * "method" is "pgcolumnar" or "heap" (or any other table access method).
 * ------------------------------------------------------------------------- */

CREATE FUNCTION pgcolumnar.alter_table_set_access_method(t text, method text)
	RETURNS void
	LANGUAGE plpgsql
	AS $alter_table_set_access_method$
DECLARE
	rel regclass := t::regclass;
	nsp text;
	tbl text;
	tmp text;
BEGIN
	/*
	 * PostgreSQL 15 introduced ALTER TABLE ... SET ACCESS METHOD, which
	 * rewrites the table in place through the target access method and
	 * preserves the relation's identity and dependents. Use it when available.
	 */
	IF current_setting('server_version_num')::int >= 150000 THEN
		EXECUTE format('ALTER TABLE %s SET ACCESS METHOD %I', rel::text, method);
		RETURN;
	END IF;

	/*
	 * PostgreSQL 13 and 14 have no ALTER TABLE ... SET ACCESS METHOD. Convert
	 * by building a sibling table that uses the target access method, copying
	 * every row through it, and swapping names. Column definitions, defaults,
	 * NOT NULL and CHECK constraints, and indexes are carried over
	 * (LIKE ... INCLUDING ALL). This does not preserve the original table's OID
	 * or objects that depend on it (views, foreign keys); on those majors that
	 * is a documented limitation of the conversion helper.
	 */
	SELECT n.nspname, c.relname INTO nsp, tbl
	  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
	 WHERE c.oid = rel;
	tmp := tbl || '_pgcolumnar_conv';

	EXECUTE format('CREATE TABLE %I.%I (LIKE %I.%I INCLUDING ALL) USING %I',
				   nsp, tmp, nsp, tbl, method);
	EXECUTE format('INSERT INTO %I.%I SELECT * FROM %I.%I',
				   nsp, tmp, nsp, tbl);
	EXECUTE format('DROP TABLE %I.%I', nsp, tbl);
	EXECUTE format('ALTER TABLE %I.%I RENAME TO %I', nsp, tmp, tbl);
END;
$alter_table_set_access_method$;

COMMENT ON FUNCTION pgcolumnar.alter_table_set_access_method(text, text)
	IS 'convert a table between heap and columnar storage';

/* ---------------------------------------------------------------------------
 * Per-table option set and reset (spec 8.2)
 *
 * set_options stores per-table option overrides; a NULL argument
 * leaves that option unchanged. reset_options clears an option
 * back to the instance default when its boolean argument is true. Options take
 * effect for writes that begin after they are set.
 * ------------------------------------------------------------------------- */

CREATE FUNCTION pgcolumnar.set_options(
	table_name regclass,
	chunk_group_row_limit int DEFAULT NULL,
	stripe_row_limit int DEFAULT NULL,
	compression name DEFAULT NULL,
	compression_level int DEFAULT NULL,
	encode_effort name DEFAULT NULL,
	sort_by name[] DEFAULT NULL)
	RETURNS void
	LANGUAGE plpgsql
	AS $set_options$
DECLARE
	col name;
BEGIN
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
		 compression, compression_level, encode_effort, sort_by)
	VALUES (table_name, chunk_group_row_limit, stripe_row_limit,
			compression, compression_level, encode_effort, sort_by)
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
			COALESCE(EXCLUDED.sort_by, o.sort_by);
END;
$set_options$;

COMMENT ON FUNCTION pgcolumnar.set_options(regclass, int, int, name, int, name, name[])
	IS 'set per-table columnar options; NULL leaves a value unchanged. sort_by declares the physical sort key applied by vacuum_sorted() with no explicit columns (#288); it is NOT auto-maintained -- rows inserted after a sort append in insert order, so re-run vacuum_sorted() to re-establish it, like PostgreSQL CLUSTER';

CREATE FUNCTION pgcolumnar.reset_options(
	table_name regclass,
	chunk_group_row_limit bool DEFAULT false,
	stripe_row_limit bool DEFAULT false,
	compression bool DEFAULT false,
	compression_level bool DEFAULT false,
	encode_effort bool DEFAULT false,
	sort_by bool DEFAULT false)
	RETURNS void
	LANGUAGE plpgsql
	AS $reset_options$
BEGIN
	UPDATE pgcolumnar.options o SET
		chunk_group_row_limit = CASE
			WHEN reset_options.chunk_group_row_limit
			THEN NULL ELSE o.chunk_group_row_limit END,
		stripe_row_limit = CASE
			WHEN reset_options.stripe_row_limit
			THEN NULL ELSE o.stripe_row_limit END,
		compression = CASE
			WHEN reset_options.compression
			THEN NULL ELSE o.compression END,
		compression_level = CASE
			WHEN reset_options.compression_level
			THEN NULL ELSE o.compression_level END,
		encode_effort = CASE
			WHEN reset_options.encode_effort
			THEN NULL ELSE o.encode_effort END,
		sort_by = CASE
			WHEN reset_options.sort_by
			THEN NULL ELSE o.sort_by END
	WHERE o.regclass = table_name;
END;
$reset_options$;

COMMENT ON FUNCTION pgcolumnar.reset_options(regclass, bool, bool, bool, bool, bool, bool)
	IS 'reset per-table columnar options to the instance defaults';

/* ---------------------------------------------------------------------------
 * Storage-id lookup, statistics, and vacuum (spec 8.2)
 * ------------------------------------------------------------------------- */

CREATE FUNCTION pgcolumnar.get_storage_id(rel regclass)
	RETURNS bigint
	LANGUAGE C STABLE STRICT
	AS 'MODULE_PATHNAME', 'columnar_relation_storageid';

COMMENT ON FUNCTION pgcolumnar.get_storage_id(regclass)
	IS 'storage id linking a columnar table to its metadata rows';

CREATE FUNCTION pgcolumnar.add_projection(
	rel regclass,
	name text,
	columns text[],
	sort_key text[] DEFAULT '{}')
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_add_projection';

COMMENT ON FUNCTION pgcolumnar.add_projection(regclass, text, text[], text[])
	IS 'declare a physical projection: a named column subset sorted on sort_key (gap 26)';

CREATE FUNCTION pgcolumnar.drop_projection(rel regclass, name text)
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_drop_projection';

COMMENT ON FUNCTION pgcolumnar.drop_projection(regclass, text)
	IS 'drop a declared projection and free its storage (gap 26)';

/*
 * Materialize every declaration that has no projection behind it (#266).
 *
 * The case this exists for is a logical restore. pg_dump carries
 * pgcolumnar.projection_declaration and cannot carry the projection storage, so
 * a restored table has the declarations and none of the projections. This builds
 * them, and returns the number that it built.
 *
 * You can run it at any time. It does not act on a declaration that is already
 * materialized, so a second run builds nothing.
 */
CREATE FUNCTION pgcolumnar.rebuild_projections(rel regclass DEFAULT NULL)
	RETURNS integer
	LANGUAGE plpgsql
	AS $$
DECLARE
	d          record;
	rebuilt    integer := 0;
BEGIN
	/*
	 * Forget a declaration whose relation is gone (#304). The drop hook removes
	 * these, so a current build does not make them. A database created by a
	 * build that did not clean up on drop still holds them, and one such row
	 * used to abort this function for every other table in the database: the
	 * guard below resolves pd.rel, and resolving a dropped relation raises.
	 * Deleting them here makes an affected database repair itself.
	 */
	DELETE FROM pgcolumnar.projection_declaration pd
	 WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid = pd.rel);

	FOR d IN
		SELECT pd.rel, pd.name, pd.columns, pd.sort_key
		  FROM pgcolumnar.projection_declaration pd
		 WHERE (rebuild_projections.rel IS NULL OR pd.rel = rebuild_projections.rel)
		   AND NOT EXISTS (
			   SELECT 1
				 FROM pgcolumnar.projection p
				WHERE p.storage_id = pgcolumnar.get_storage_id(pd.rel)
				  AND p.name = pd.name
				  AND p.projection_id > 0)
		 ORDER BY pd.rel::text, pd.name
	LOOP
		PERFORM pgcolumnar.add_projection(d.rel, d.name::text, d.columns, d.sort_key);
		rebuilt := rebuilt + 1;
	END LOOP;
	RETURN rebuilt;
END;
$$;

COMMENT ON FUNCTION pgcolumnar.rebuild_projections(regclass)
	IS 'materialize declared projections that have no storage, after a logical restore (#266)';

CREATE FUNCTION pgcolumnar.read_projection(rel regclass, name text)
	RETURNS SETOF text
	LANGUAGE C STABLE
	AS 'MODULE_PATHNAME', 'columnar_read_projection';

COMMENT ON FUNCTION pgcolumnar.read_projection(regclass, text)
	IS 'read a projection''s stored columns (live rows), joined by | -- verification/debug (gap 26)';

CREATE FUNCTION pgcolumnar.reconstruct_via_projection(rel regclass, name text)
	RETURNS SETOF text
	LANGUAGE C STABLE
	AS 'MODULE_PATHNAME', 'columnar_reconstruct_via_projection';

COMMENT ON FUNCTION pgcolumnar.reconstruct_via_projection(regclass, text)
	IS 'read all live rows via a projection, reconstructing non-covered columns from the base by row number (gap 26)';

CREATE FUNCTION pgcolumnar.stats(
	rel regclass,
	OUT stripeid bigint,
	OUT fileoffset bigint,
	OUT rowcount bigint,
	OUT deletedrows bigint,
	OUT chunkcount integer,
	OUT datalength bigint)
	RETURNS SETOF record
	LANGUAGE sql STABLE
	AS $stats$
	-- Native (PGCN v1) tables report one row per row group from the native
	-- catalog.
	SELECT rg.group_number,
		   rg.file_offset,
		   rg.row_count,
		   COALESCE((SELECT sum(rm.deleted_count)::bigint
					 FROM pgcolumnar.delete_vector rm
					 WHERE rm.storage_id = rg.storage_id
					   AND rm.group_number = rg.group_number), 0::bigint),
		   (SELECT count(DISTINCT zm.vector_index)::int
			FROM pgcolumnar.zone_map zm
			WHERE zm.storage_id = rg.storage_id
			  AND zm.group_number = rg.group_number
			  AND zm.vector_index >= 0),
		   rg.byte_length
	FROM pgcolumnar.row_group rg
	WHERE rg.storage_id = pgcolumnar.get_storage_id(rel)
	ORDER BY 1;
$stats$;

COMMENT ON FUNCTION pgcolumnar.stats(regclass)
	IS 'per-row-group statistics for a columnar table';

/*
 * How much of an ordered layout is still ordered (#301).
 *
 * pgcolumnar.vacuum_sorted and pgcolumnar.cluster order the whole relation once.
 * They do not keep it ordered: rows inserted later append in insert order, so
 * the ordered run stays at the front and an unsorted tail grows behind it. This
 * reports the size of each part, so a DBA can decide when a re-sort is worth its
 * cost instead of guessing.
 *
 * The ordered run is every row group numbered within the range the rewrite left
 * in pgcolumnar.storage: from sorted_from to sorted_through inclusive. Groups
 * above it were written later. Groups below it belong to a writer that started
 * before the rewrite did and so were never ordered by it (#342); recording only
 * an upper bound counted those as ordered.
 *
 * The row counts are stored rows. Rows deleted but not yet reclaimed are still
 * stored, so they are still counted. pgcolumnar.stats reports the deleted count
 * per group for callers that need to subtract it.
 *
 * Limits to read before acting on the numbers:
 *
 * 1. The online pgcolumnar.recluster sets the mark only for the part of its
 *    output it can prove is one contiguous ordered run. It reorders under a lock
 *    that permits concurrent inserts, and a boundary can only mean "everything
 *    at or below this is ordered" if no other session's group is numbered below
 *    it. With no concurrent writer it records the whole relation. With one, it
 *    records the run up to the point the other session interrupted, which can be
 *    a small part of what it ordered, and reports the rest as decay. It errs
 *    toward reporting too much decay, never too little.
 *
 * 2. The mark says where an ordered run ended, not that the rows in it are still
 *    in that order. Nothing in the design can move a stored row, so the run
 *    holds its order; but an UPDATE writes the new row version at the end, which
 *    counts as appended, and the old version stays in the run until it is
 *    reclaimed.
 *
 * A relation that was never ordered reports no sorted groups, because a rewrite
 * always creates a new storage row and only an ordering rewrite sets the mark on
 * it. A relation with nothing written reports zeros.
 */
CREATE FUNCTION pgcolumnar.sort_status(
	rel regclass,
	OUT sort_key name[],
	OUT total_groups bigint,
	OUT sorted_groups bigint,
	OUT appended_groups bigint,
	OUT sorted_rows bigint,
	OUT appended_rows bigint)
	RETURNS record
	LANGUAGE sql STABLE
	AS $sort_status$
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
	SELECT (SELECT o.sort_by FROM pgcolumnar.options o WHERE o.regclass = rel),
		   (SELECT count(*)::bigint FROM g),
		   (SELECT count(*)::bigint FROM g WHERE g.in_run),
		   (SELECT count(*)::bigint FROM g WHERE NOT g.in_run),
		   COALESCE((SELECT sum(g.row_count)::bigint FROM g WHERE g.in_run), 0::bigint),
		   COALESCE((SELECT sum(g.row_count)::bigint FROM g WHERE NOT g.in_run), 0::bigint);
$sort_status$;

COMMENT ON FUNCTION pgcolumnar.sort_status(regclass)
	IS 'how much of an ordered columnar table is still in its ordered run (#301)';

CREATE FUNCTION pgcolumnar.vacuum(tablename regclass, stripe_count int DEFAULT 0)
	RETURNS void
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'columnar_vacuum';

COMMENT ON FUNCTION pgcolumnar.vacuum(regclass, int)
	IS 'compact a columnar table by combining stripes and reclaiming deleted rows';

CREATE FUNCTION pgcolumnar.vacuum_sorted(
	tablename regclass,
	VARIADIC sort_columns name[])
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_vacuum_sorted';

COMMENT ON FUNCTION pgcolumnar.vacuum_sorted(regclass, name[])
	IS 'compact a columnar table, storing rows sorted ascending (NULLS LAST) on the given columns. With no columns, applies the table''s declared sort_by key from set_options (#288), like a bare CLUSTER re-applying a remembered index; errors if none is declared. Supports any btree-orderable column including text (unlike the numeric-only Z-order cluster()). One-shot: not auto-maintained.';

/*
 * One-argument form: apply the declared sort_by key (#288). A VARIADIC function
 * cannot be called cleanly with zero variadic arguments from an unknown literal
 * (vacuum_sorted('t') would not resolve), so this explicit overload gives a
 * clean bare-table call. It shares the C entry point, which uses PG_NARGS() to
 * detect the missing column list and fall back to the persisted key.
 */
CREATE FUNCTION pgcolumnar.vacuum_sorted(tablename regclass)
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_vacuum_sorted';

COMMENT ON FUNCTION pgcolumnar.vacuum_sorted(regclass)
	IS 'apply the table''s declared sort_by key from set_options (#288); errors if none is declared. Equivalent to a bare CLUSTER re-applying a remembered index.';

CREATE FUNCTION pgcolumnar.cluster(
	tablename regclass,
	VARIADIC columns name[])
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_cluster';

COMMENT ON FUNCTION pgcolumnar.cluster(regclass, name[])
	IS 'eager reorg: rewrite a columnar table with rows ordered by the Z-order space-filling curve over the given columns. Holds AccessExclusiveLock like CLUSTER/VACUUM FULL; the online incremental path is Phase F3';

CREATE FUNCTION pgcolumnar.compact(tablename regclass)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_compact';

COMMENT ON FUNCTION pgcolumnar.compact(regclass)
	IS 'lazy online compaction: retire row groups that are fully deleted, dropping their metadata so scans skip them. Holds only ShareUpdateExclusiveLock (concurrent reads and writes). Returns the number of groups retired (Phase F3a)';

CREATE FUNCTION pgcolumnar.truncate(tablename regclass)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_truncate';

COMMENT ON FUNCTION pgcolumnar.truncate(regclass)
	IS 'physical end-truncation: return trailing reclaimed blocks to the OS. Best-effort -- takes AccessExclusiveLock conditionally for the brief physical step and returns 0 without waiting if the table is busy. Only removes space freed before the oldest-xmin horizon. Gated by pgcolumnar.enable_end_truncation. Returns the number of blocks truncated (Phase F)';

CREATE FUNCTION pgcolumnar.compact_rewrite(
	tablename regclass,
	min_deleted_fraction float8 DEFAULT 0.2,
	max_groups int DEFAULT 0)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_compact_rewrite';

COMMENT ON FUNCTION pgcolumnar.compact_rewrite(regclass, float8, int)
	IS 'lazy online space reclaim: rewrite partially-deleted row groups (deleted fraction >= min_deleted_fraction) to drop their dead rows, under ShareUpdateExclusiveLock (concurrent reads and writes). Returns the number of groups rewritten (Phase F3b)';

CREATE FUNCTION pgcolumnar.recluster(
	tablename regclass,
	VARIADIC columns name[])
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_recluster';

COMMENT ON FUNCTION pgcolumnar.recluster(regclass, name[])
	IS 'lazy online reclustering: re-establish global Z-order clustering over the given columns under ShareUpdateExclusiveLock (concurrent reads and writes), unlike the eager cluster() which holds AccessExclusiveLock. Returns the number of groups reclustered (Phase F3c)';

CREATE FUNCTION pgcolumnar.export_arrow(rel regclass, path text)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_export_arrow';

COMMENT ON FUNCTION pgcolumnar.export_arrow(regclass, text)
	IS 'export a columnar table to an Arrow IPC stream file; returns rows written';

CREATE FUNCTION pgcolumnar.export_parquet(rel regclass, path text)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_export_parquet';

COMMENT ON FUNCTION pgcolumnar.export_parquet(regclass, text)
	IS 'export a columnar table to a Parquet file; returns rows written';

CREATE FUNCTION pgcolumnar.parallel_export_parquet(target regclass, path text,
												   workers int DEFAULT NULL)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_parallel_export_parquet';

COMMENT ON FUNCTION pgcolumnar.parallel_export_parquet(regclass, text, int)
	IS 'parallel Parquet export using read-only background workers into a directory readable by pgcolumnar.read_parquet: a single columnar table split by row-group ranges, or a partitioned columnar table one file per partition; returns rows written (#300)';

CREATE FUNCTION pgcolumnar.import_arrow(rel regclass, path text)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_import_arrow';

COMMENT ON FUNCTION pgcolumnar.import_arrow(regclass, text)
	IS 'insert rows from an Arrow IPC stream file into a columnar table; returns rows inserted';

CREATE FUNCTION pgcolumnar.import_parquet(rel regclass, path text)
	RETURNS bigint
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'columnar_import_parquet';

COMMENT ON FUNCTION pgcolumnar.import_parquet(regclass, text)
	IS 'insert rows from a Parquet file, directory, or glob into a table; returns rows inserted (gap 27)';

CREATE FUNCTION pgcolumnar.parquet_schema(path text)
	RETURNS TABLE(column_name text, data_type text, nullable boolean)
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'columnar_parquet_schema';

COMMENT ON FUNCTION pgcolumnar.parquet_schema(text)
	IS 'report the leaf columns of a Parquet file and the PostgreSQL type each maps to; for a directory or glob, of its first file (Phase G scan core)';

CREATE FUNCTION pgcolumnar.read_parquet(path text)
	RETURNS SETOF record
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'columnar_read_parquet';

COMMENT ON FUNCTION pgcolumnar.read_parquet(text)
	IS 'read a Parquet file, directory, or glob in place as a set of rows; requires a column definition list covering every leaf column, e.g. SELECT * FROM pgcolumnar.read_parquet(path) AS t(id int, name text) (Phase G)';

/* ---------------------------------------------------------------------------
 * Parquet foreign-data wrapper (Phase G)
 *
 * A foreign table over a Parquet file, a directory of *.parquet files, or a glob
 * pattern, read as one relation; its column definitions are bound against every
 * file by position, like read_parquet's column list. Usage:
 *   CREATE SERVER pq FOREIGN DATA WRAPPER pgcolumnar_parquet;
 *   CREATE FOREIGN TABLE ft (id int, name text) SERVER pq
 *       OPTIONS (path '/data/f.parquet');
 * ------------------------------------------------------------------------- */

CREATE FUNCTION pgcolumnar.parquet_fdw_handler()
	RETURNS fdw_handler
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_parquet_fdw_handler';

CREATE FUNCTION pgcolumnar.parquet_fdw_validator(text[], oid)
	RETURNS void
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'pgcolumnar_parquet_fdw_validator';

CREATE FOREIGN DATA WRAPPER pgcolumnar_parquet
	HANDLER pgcolumnar.parquet_fdw_handler
	VALIDATOR pgcolumnar.parquet_fdw_validator;

COMMENT ON FOREIGN DATA WRAPPER pgcolumnar_parquet
	IS 'read a Parquet file, directory, or glob as a foreign table; table option: path (Phase G)';

CREATE FUNCTION pgcolumnar.vm_selftest(rel regclass, blk int)
	RETURNS boolean
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_vm_selftest';

COMMENT ON FUNCTION pgcolumnar.vm_selftest(regclass, int)
	IS 'gap 28 phase-1 self-test: set a VM-fork all-visible bit and read it back';

CREATE FUNCTION pgcolumnar.vm_is_visible(rel regclass, blk int)
	RETURNS boolean
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_vm_is_visible';

COMMENT ON FUNCTION pgcolumnar.vm_is_visible(regclass, int)
	IS 'gap 28: is the synthetic block marked all-visible in the VM fork?';

CREATE FUNCTION pgcolumnar.vacuum_full(
	schema name DEFAULT 'public',
	sleep_time real DEFAULT 0.0,
	stripe_count int DEFAULT 0)
	RETURNS void
	LANGUAGE plpgsql
	AS $vacuum_full$
DECLARE
	r record;
BEGIN
	FOR r IN
		SELECT c.oid AS reloid
		FROM pg_class c
		JOIN pg_am a ON a.oid = c.relam
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE a.amname = 'pgcolumnar'
		  AND c.relkind = 'r'
		  AND n.nspname = vacuum_full.schema
	LOOP
		PERFORM pgcolumnar.vacuum(r.reloid::regclass, stripe_count);
		IF sleep_time > 0 THEN
			PERFORM pg_sleep(sleep_time);
		END IF;
	END LOOP;
END;
$vacuum_full$;

COMMENT ON FUNCTION pgcolumnar.vacuum_full(name, real, int)
	IS 'compact every columnar table in a schema';

-- ---------------------------------------------------------------------------
-- Parallel bulk ingest (#300). Phase 1: the file range splitter. Given a
-- server-side file and a worker count, return workers+1 ascending byte offsets
-- that partition the file into that many line-aligned ranges, so a parallel load
-- can hand range [off[i], off[i+1]) to worker i. The ranges are record-aligned
-- for COPY *text* format only (a raw newline always ends a text record); they are
-- NOT safe for CSV, whose quoted fields may contain literal newlines. `workers` is
-- capped internally so a huge value cannot allocate unbounded memory.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pgcolumnar.file_split_offsets(path text, workers int)
	RETURNS bigint[]
	LANGUAGE C STRICT
	AS 'MODULE_PATHNAME', 'columnar_file_split_offsets';

COMMENT ON FUNCTION pgcolumnar.file_split_offsets(text, int)
	IS 'byte offsets that split a COPY text-format file into N record-aligned ranges (#300)';

-- Parallel bulk ingest: atomically load a server-side COPY text-format file into a
-- RANGE-partitioned columnar table across N background workers. Each worker loads a
-- DISTINCT set of partitions (distinct storage), the only shape pgColumnar allows a
-- parallel AND atomic bulk load: concurrent writers to one non-partitioned table
-- serialize on the per-storage write lock and, under two-phase commit, deadlock
-- (single-table parallel load is a planned columnar-core enhancement). Loaders
-- PREPARE; a coordinator background worker COMMIT PREPAREDs them all, or ROLLBACK
-- PREPAREDs on any failure. Returns rows loaded. The target is either a single
-- columnar table (workers write its one storage concurrently) or a RANGE-partitioned
-- table (each worker loads a distinct partition; requires a single-column
-- numeric/date-time key, no DEFAULT partition, and the file sorted ascending by that
-- key). COPY text format, and max_prepared_transactions >= workers. workers => NULL
-- derives a default from max_parallel_workers.
--
-- Two behaviors to know: (1) the load commits in background workers, INDEPENDENTLY
-- of the calling transaction, so its rows survive a subsequent ROLLBACK of the
-- caller -- treat the call like a COMMIT. (2) Do not call it while the calling
-- transaction holds a lock on the target (e.g. after LOCK TABLE or a write to it):
-- the loaders would block on that lock and the wait is invisible to the deadlock
-- detector. See design/PARALLEL_COPY_PLAN.md.
CREATE FUNCTION pgcolumnar.parallel_copy(target regclass, filename text,
										 workers int DEFAULT NULL)
	RETURNS bigint
	LANGUAGE C
	AS 'MODULE_PATHNAME', 'columnar_parallel_copy';

COMMENT ON FUNCTION pgcolumnar.parallel_copy(regclass, text, int)
	IS 'atomic parallel bulk load of a COPY text file into a columnar table using background workers: a single columnar table (any row order), or a RANGE-partitioned columnar table sorted by the partition key with one distinct partition set per worker (#300)';
