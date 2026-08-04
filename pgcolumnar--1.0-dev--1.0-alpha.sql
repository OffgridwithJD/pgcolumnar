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

