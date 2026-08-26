/* pgcolumnar 1.0-alpha --> 1.0-alpha2 upgrade
 * Generated from the catalog delta between a fresh 1.0-alpha and 1.0-alpha2
 * install and verified by test/native_upgrade_converge.sh. The 1.0-alpha2 cycle
 * namespaced the extension's C symbols (see below), added read-only Iceberg
 * support, object storage, and a maintenance daemon, and revoked PUBLIC execute
 * on the internal projection and visibility-map functions.
 *
 * The C-symbol rename is why this upgrade is mandatory: each installed function
 * recorded a symbol name when it was created, and without replacing those
 * catalog rows an existing columnar table fails to read.
 */
\echo Use "ALTER EXTENSION pgcolumnar UPDATE" to load this file. \quit

-- storage catalog columns added in 1.0-alpha2
ALTER TABLE pgcolumnar.storage ADD COLUMN IF NOT EXISTS sorted_by name[];
ALTER TABLE pgcolumnar.storage ADD COLUMN IF NOT EXISTS sorted_kind text;

DROP FUNCTION IF EXISTS pgcolumnar.parquet_schema(text);
DROP FUNCTION IF EXISTS pgcolumnar.sort_status(regclass);
DROP FUNCTION IF EXISTS pgcolumnar.stats(regclass);


-- new and changed function definitions
CREATE OR REPLACE FUNCTION pgcolumnar."analyze"(rel regclass, columns text[] DEFAULT NULL::text[])
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
	sid        bigint;
	att        record;
	nullfrac   double precision;
	ndistinct  bigint;
	totalrows  bigint;
	ndstat     double precision;
	hist       text;
	mcvvals    text;
	mcvfreqs   real[];
	orderable  boolean;
	nmcv       integer;
	nremaining bigint;
	nullcount  bigint;	/* live rows with no value, from the same read */
	nonnull    bigint;	/* rows with a value, from the aggregation below */
	mcvrows    bigint;	/* of those, the rows the MCV list holds */
	nv         bigint;	/* the population the histogram is placed over */
	nfrac      integer;
	-- The per-column target, resolved inside the loop. attstattarget is NULL when
	-- the column has never been given one, and core reads that as "use the global
	-- default" (analyze.c:1065 with :1897). A zero means do not collect at all.
	deftarget  integer := current_setting('default_statistics_target')::integer;
	nbuckets   integer;
	seen       integer := 0;
	disabled   integer := 0;
	unknown    text;
	schname    text;
	relnm      text;
BEGIN
	/*
	 * Writing statistics uses pg_restore_attribute_stats, which core added in
	 * 18. On 15 to 17 this would mean writing pg_statistic directly, and the
	 * risk there is in the values rather than the insert: stavalues is anyarray
	 * and must carry the column's element type, typmod and collation; staop must
	 * be the right operator for the stakind; stadistinct has a sign convention
	 * that is easy to invert. Each of those produces plausible wrong estimates
	 * rather than an error. Refuse clearly instead of failing obscurely inside
	 * the call below.
	 */
	IF current_setting('server_version_num')::int < 180000 THEN
		RAISE EXCEPTION 'pgcolumnar.analyze() requires PostgreSQL 18 or later'
			USING DETAIL = 'it writes statistics through pg_restore_attribute_stats, which older majors do not have',
				  HINT = 'use ANALYZE on this server';
	END IF;

	/*
	 * pg_restore_attribute_stats identifies the column by schema and relation
	 * NAME, not by regclass, and rejects a null schemaname. Resolve both from the
	 * oid once rather than per column.
	 */
	SELECT n.nspname, c.relname INTO schname, relnm
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.oid = rel;

	SELECT s.storage_id INTO sid
		FROM pgcolumnar.storage s
		WHERE s.relation_oid = rel;

	IF sid IS NULL THEN
		RAISE EXCEPTION 'pgcolumnar.analyze(): % has no columnar storage', rel::text
			USING HINT = 'this function only applies to pgcolumnar tables that have been written to';
	END IF;

	/*
	 * A named column that does not exist is a caller error, not a no-op. Silently
	 * collecting nothing is the failure mode that looks exactly like success.
	 */
	IF columns IS NOT NULL THEN
		SELECT c INTO unknown
			FROM unnest(columns) AS c
			WHERE NOT EXISTS (
				SELECT 1 FROM pg_attribute a
					WHERE a.attrelid = rel AND a.attname = c
					  AND a.attnum > 0 AND NOT a.attisdropped)
			LIMIT 1;
		IF unknown IS NOT NULL THEN
			RAISE EXCEPTION 'pgcolumnar.analyze(): column "%" does not exist in %',
				unknown, rel::text;
		END IF;
	END IF;

	FOR att IN
		SELECT a.attname, a.attnum, a.atttypid, a.attstattarget
			FROM pg_attribute a
			WHERE a.attrelid = rel AND a.attnum > 0 AND NOT a.attisdropped
			  AND (columns IS NULL OR a.attname = ANY (columns))
			ORDER BY a.attnum
	LOOP
		/*
		 * The per-column statistics target, which is core's rule and not the
		 * global setting:
		 *
		 *     attstattarget = isnull ? -1 : DatumGetInt16(dat);   analyze.c:1065
		 *     if (attstattarget == 0) return NULL;                        :1070
		 *     if (stats->attstattarget < 0)                               :1897
		 *         stats->attstattarget = default_statistics_target;
		 *
		 * Zero means the DBA turned this column off, and honouring it is not
		 * optional: writing statistics for such a column overrides an explicit
		 * instruction and hands the planner numbers somebody disabled. Reading
		 * the global default for every column, as this function did, ignored
		 * ALTER TABLE ... SET STATISTICS entirely.
		 */
		IF att.attstattarget = 0 THEN
			disabled := disabled + 1;
			CONTINUE;
		END IF;
		nbuckets := coalesce(att.attstattarget, deftarget);
		/*
		 * Has this column been written yet? The zone maps answer that and
		 * nothing else here.
		 *
		 * They used to answer null_frac as well --
		 * sum(null_count) / sum(value_count + null_count) -- and that was wrong
		 * after a DELETE. Those counts describe what was WRITTEN; deleting a row
		 * marks it dead without rewriting them, so the denominator keeps counting
		 * rows the table no longer holds. On 1,000 rows with 100 nulls, deleting
		 * the 301 rows holding one value leaves a true null_frac of 0.1431 and a
		 * zone-map null_frac of 0.1000, a 30% understatement that VACUUM does not
		 * heal. Worse than the size of the error: null_frac came from the zone
		 * maps while the most-common-value frequencies came from count(*), so the
		 * two were normalised against different populations and
		 * null_frac + sum(mcv_freqs) + rest = 1 -- the identity the planner's
		 * selectivity arithmetic rests on -- silently stopped holding.
		 *
		 * So the fraction is taken from the same read as everything else below,
		 * and the zone maps keep only the job they can still do exactly: telling
		 * us whether there are any row groups at all.
		 *
		 * column_index is the 0-based attribute position. attnum is stable
		 * across a dropped column, so attnum - 1 keeps pointing at the same
		 * column after a DROP COLUMN.
		 */
		PERFORM 1
			FROM pgcolumnar.zone_map z
			WHERE z.storage_id = sid
			  AND z.column_index = att.attnum - 1
			  AND z.vector_index = -1;

		CONTINUE WHEN NOT FOUND;	/* no zone map rows: nothing exact to say */

		/*
		 * n_distinct, the row count and the null count, by reading this column
		 * and nothing else. This is the whole point of the function: on the
		 * 3M x 20 fixture a projected single-column read costs 268 ms where
		 * core's whole-table sample costs 6,302 ms, because core's fixed
		 * 30,000-row sample lands in every row group and so decodes every column
		 * of the table.
		 *
		 * count(DISTINCT) ignores NULLs, which is what n_distinct means. The
		 * null count comes from the same scan so that it cannot disagree with the
		 * denominator the frequencies below are divided by.
		 */
		EXECUTE format('SELECT count(DISTINCT %I)::bigint, count(*)::bigint,'
					   '       count(*) FILTER (WHERE %I IS NULL)::bigint'
					   '  FROM %I.%I',
					   att.attname, att.attname, schname, relnm)
			INTO ndistinct, totalrows, nullcount;

		nullfrac := CASE WHEN totalrows > 0
						 THEN nullcount::double precision / totalrows::double precision
						 ELSE 0 END;

		/*
		 * Core's own convention, and the sign is load-bearing: positive is an
		 * absolute count, negative is the negated fraction of rows. analyze.c
		 * switches to the fraction once the distinct count passes 10% of the
		 * rows, on the grounds that such a column's cardinality tracks the table
		 * size rather than sitting at a fixed value. Mirror it rather than always
		 * writing the absolute count, or a column that is unique today reads as
		 * having a fixed cardinality once the table grows.
		 *
		 * Getting this backwards does not raise -- it produces plausible wrong
		 * estimates -- so it is asserted in test/analyze_function.sh against a
		 * fixture pinned to the absolute-count side of the rule.
		 */
		IF totalrows > 0 THEN
			IF ndistinct::double precision > 0.1 * totalrows::double precision THEN
				ndstat := -(ndistinct::double precision / totalrows::double precision);
			ELSE
				ndstat := ndistinct::double precision;
			END IF;
		ELSE
			ndstat := 0;
		END IF;

		/*
		 * Whether this type can be ordered at all. Hoisted out of the histogram
		 * test below because the most-common-value list needs the same answer:
		 * both order by the column, and a type with no btree opclass has no
		 * histogram in core either.
		 */
		orderable := EXISTS (SELECT 1 FROM pg_catalog.pg_type t
							 JOIN pg_catalog.pg_opclass oc ON oc.opcintype = t.oid
							 JOIN pg_catalog.pg_am am ON am.oid = oc.opcmethod
							 WHERE t.oid = att.atttypid AND am.amname = 'btree');

		/*
		 * most_common_vals and most_common_freqs (#414 slice 3b).
		 *
		 * The selection rule is core's, and reading a complete column removes
		 * most of it. analyze_mcv_list() opens with
		 *
		 *     if (samplerows == totalrows || totalrows <= 1.0)
		 *         return num_mcv;                        -- analyze.c:2995
		 *
		 * so the entire significance filter -- a continuity-corrected Wald
		 * interval over a hypergeometric variance -- is skipped when the whole
		 * table was read. That machinery exists to judge whether a SAMPLE
		 * frequency can be trusted; we do not sample, so the question does not
		 * arise and core's own answer is to keep the list. What remains:
		 *
		 *   only values appearing more than once are eligible  analyze.c:2549
		 *   the top default_statistics_target of those, by count analyze.c:2552
		 *   frequency = count / TOTAL rows, nulls included     analyze.c:2720
		 *
		 * That last one is the one that fails quietly. Dividing by the non-null
		 * count instead scales every frequency by 1/(1-null_frac): still ordered,
		 * still summing to less than one, still plausible, and wrong everywhere
		 * the column has nulls. test/analyze_function.sh pins it with a fixture
		 * that is one-tenth null, so the two denominators cannot agree.
		 *
		 * HAVING count(*) > 1 also reproduces core's unique-column case without a
		 * branch: when nothing repeats the aggregate is empty, array_agg returns
		 * NULL, and no MCV list is written -- which is what core does at
		 * analyze.c:2588 when nmultiple is zero.
		 *
		 * array_agg(...)::text rather than string_agg builds the array literal
		 * through the type's own output function, so quoting, embedded commas and
		 * braces are correct for text columns instead of being hand-assembled.
		 */
		mcvvals := NULL;
		mcvfreqs := NULL;
		nonnull  := 0;
		mcvrows  := 0;
		IF orderable THEN
			/*
			 * The same aggregation, split into the full group and the most-common
			 * slice of it, so it can also report how many ROWS each covers. The
			 * histogram below is built over the non-null rows the MCV list does
			 * NOT hold, and it has to know how many those are to place a bound at
			 * a position rather than at a fraction.
			 *
			 * Both counts come from this one aggregation rather than from the zone
			 * maps or a second scan, so the population the histogram is placed
			 * over is by construction the population the MCV list was taken from.
			 */
			EXECUTE format(
				'WITH g AS MATERIALIZED ('
				'       SELECT %I AS v, count(*)::bigint AS c'
				'         FROM %I.%I WHERE %I IS NOT NULL GROUP BY 1),'
				'     m AS MATERIALIZED ('
				'       SELECT v, c FROM g WHERE c > 1 ORDER BY c DESC, v LIMIT %s)'
				'SELECT (SELECT array_agg(v ORDER BY c DESC, v)::text FROM m),'
				'       (SELECT array_agg((c::double precision / %s::double precision)::real'
				'                         ORDER BY c DESC, v) FROM m),'
				'       (SELECT coalesce(sum(c), 0)::bigint FROM g),'
				'       (SELECT coalesce(sum(c), 0)::bigint FROM m)',
				att.attname, schname, relnm, att.attname, nbuckets, totalrows)
				INTO mcvvals, mcvfreqs, nonnull, mcvrows;
		END IF;

		/*
		 * histogram_bounds, whose ends are exact because the read is complete
		 * (#414 slice 3).
		 *
		 * percentile_disc over an array of fractions returns ACTUAL column
		 * values, one per fraction, in a single ordered pass. Fraction 1.0 is
		 * therefore the true maximum and 0.0 the true minimum, which is the
		 * whole gain: core samples, so a value held by one row in 500,000 is
		 * missed and every range estimate above the sampled maximum collapses.
		 * percentile_cont would interpolate and invent values the column does
		 * not contain, which is wrong for a histogram of stored data and wrong
		 * for any non-numeric type.
		 *
		 * Only for types that can be ordered. A column with no btree ordering
		 * has no histogram in core either, and ORDER BY would simply fail.
		 *
		 * The most-common values are EXCLUDED, which core does at analyze.c:2744
		 * and :2768-2799 by collapsing them out of the sorted array before
		 * building buckets. Keeping them in counts them twice in selectivity:
		 * eqsel takes the value's frequency from the MCV list, and the range
		 * estimators count it again inside whichever bucket holds it. Nothing
		 * raises -- the estimates are simply inflated for the values a skewed
		 * column repeats most, which is where estimates matter.
		 *
		 * The population and the bucket count therefore both shrink, and both
		 * have to. Core sizes the histogram from what is LEFT:
		 *
		 *     num_hist = ndistinct - num_mcv;
		 *     if (num_hist > num_bins) num_hist = num_bins + 1;
		 *     if (num_hist >= 2) { ... }              -- analyze.c:2744-2747
		 *
		 * so it emits between 2 and num_bins+1 bounds and none at all below two.
		 * Asking percentile_disc for a fixed default_statistics_target+1
		 * fractions regardless would repeat values once the remaining population
		 * is smaller than that -- a 150-distinct column with 100 most-common
		 * values has 50 left and would get 101 bounds, most of them duplicates.
		 * A histogram with repeated bounds describes buckets holding no rows,
		 * which is a shape core never emits.
		 */
		nmcv := coalesce(array_length(mcvfreqs, 1), 0);
		nremaining := ndistinct - nmcv;

		nv := nonnull - mcvrows;

		hist := NULL;
		IF att.attnum > 0
		   AND orderable
		   AND nremaining >= 2
		   AND nv > 1
		THEN
			/*
			 * least(nbuckets, nremaining - 1) fractions, so the bound count is
			 * least(nbuckets + 1, nremaining): core's cap, reached from below.
			 */
			nfrac := least(nbuckets, nremaining - 1);

			/*
			 * A bound is a POSITION, not a quantile, and the difference is not
			 * academic. core's compute_scalar_stats places bound i at
			 *
			 *     values[floor(i * (nvals - 1) / (num_hist - 1))]
			 *
			 * among the rows left after the most-common values are removed.
			 * percentile_disc resolves fraction p to index ceil(p * nv) - 1, which
			 * is a different index whenever frac(i*nv/nfrac) is small, and a
			 * different VALUE whenever that shift crosses a value boundary. On a
			 * column with many rows per distinct value the two agree and the
			 * distinction is invisible; on eleven distinct rows at a statistics
			 * target of 3 they disagree at the third bound, 8 against 7.
			 *
			 * So ask percentile_disc for the fractions that resolve to core's
			 * positions instead of for evenly spaced quantiles:
			 *
			 *     p_i = (floor(i * (nv - 1) / nfrac) + 0.5) / nv
			 *
			 * The half is load-bearing rather than decorative. The exact boundary
			 * (T + 1)/nv is a double, and nv up to a few million leaves roughly
			 * 1e-9 of slack in p*nv; landing a hair above T+1 makes ceil() return
			 * T+2 and takes the NEXT value. Half a row of margin cannot be crossed
			 * by that error, and any p in (T/nv, (T+1)/nv] resolves to T.
			 *
			 * nv is the count from the aggregation above, not a derived figure:
			 * deriving it as totalrows minus a null_frac read off the zone maps
			 * would put a rounded float in a position index.
			 */

			/*
			 * The exclusion is a literal list rather than a re-aggregation. The
			 * alternative -- recomputing the most-common set in a subquery -- is
			 * a third full pass over a column this function exists to read once,
			 * and it can disagree with the list actually written if the tie-break
			 * ever differs. format_type gives the element type without a typmod,
			 * which is what the array literal must be parsed against.
			 */
			EXECUTE format(
				'SELECT percentile_disc(
						 (SELECT array_agg(((floor(i::numeric * (%s - 1) / %s) + 0.5)
											/ %s)::double precision ORDER BY i)
							FROM generate_series(0, %s) i))
					   WITHIN GROUP (ORDER BY %I)::text
				   FROM %I.%I WHERE %I IS NOT NULL %s',
				nv, nfrac, nv, nfrac, att.attname, schname, relnm, att.attname,
				CASE WHEN mcvvals IS NULL THEN ''
					 ELSE format('AND %I <> ALL (%L::%s[])', att.attname, mcvvals,
								 format_type(att.atttypid, NULL))
				END)
				INTO hist;
		END IF;

		/*
		 * The casts are load-bearing. pg_restore_attribute_stats takes VARIADIC
		 * "any", so a mistyped argument is a WARNING and the value is dropped,
		 * not an error: attname must be text (attname is `name`) and null_frac
		 * must be real (the division yields double precision). Without these the
		 * call "succeeds" having stored nothing.
		 *
		 * histogram_bounds and most_common_vals are passed as text, which is what
		 * the function takes (attribute_stats.c:70,72): it parses each array
		 * literal against the column's own type. most_common_freqs is real[]
		 * (:71) -- a float8[] there is dropped with a WARNING, not an error.
		 *
		 * One call with typed NULLs rather than a branch per combination. A NULL
		 * argument is not written: each statistic is gated on PG_ARGISNULL
		 * (:162-163 for the MCV pair), so a typed NULL and an omitted argument
		 * mean the same thing. Four optional statistics would otherwise be
		 * sixteen call sites. The NULLs must still be TYPED -- an untyped NULL
		 * reaches VARIADIC "any" as `unknown` and is the mistyped-argument case
		 * these casts exist to avoid.
		 *
		 * most_common_vals and most_common_freqs are a pair: supplying one
		 * without the other is a WARNING and drops both (stats_check_arg_pair,
		 * :265). They are computed together above, so they are null together.
		 */
		PERFORM pg_catalog.pg_restore_attribute_stats(
			'schemaname', schname,
			'relname', relnm,
			'attname', att.attname::text,
			'inherited', false,
			'null_frac', nullfrac::real,
			'n_distinct', ndstat::real,
			'most_common_vals', mcvvals::text,
			'most_common_freqs', mcvfreqs::real[],
			'histogram_bounds', hist::text);

		seen := seen + 1;
	END LOOP;

	/*
	 * Collecting nothing is an error only when nothing ASKED us not to. A column
	 * at SET STATISTICS 0 is an instruction, and core does not raise for
	 * `ANALYZE t (col)` when col is disabled -- it collects nothing and returns.
	 * Without the second term this guard turned that instruction into an error
	 * whose hint blamed missing row groups, which is a different fault entirely
	 * and would send somebody looking at the storage.
	 */
	IF seen = 0 AND disabled = 0 THEN
		RAISE EXCEPTION 'pgcolumnar.analyze(): collected statistics for no columns of %', rel::text
			USING HINT = 'the table may have no written row groups yet';
	END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.iceberg_catalog_fdw_validator(text[], oid)
 RETURNS void
 LANGUAGE c
AS '$libdir/pgcolumnar', $function$pgcolumnar_iceberg_catalog_validator$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.iceberg_current_snapshot(metadata_path text)
 RETURNS TABLE(snapshot_id bigint, parent_snapshot_id bigint, sequence_number bigint, timestamp_ms bigint, operation text, manifest_list text, schema_id integer)
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_iceberg_current_snapshot$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.iceberg_data_files(metadata_path text)
 RETURNS TABLE(file_path text, file_format text, record_count bigint, partition text)
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_iceberg_data_files$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.iceberg_fdw_handler()
 RETURNS fdw_handler
 LANGUAGE c
AS '$libdir/pgcolumnar', $function$pgcolumnar_iceberg_fdw_handler$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.iceberg_fdw_validator(text[], oid)
 RETURNS void
 LANGUAGE c
AS '$libdir/pgcolumnar', $function$pgcolumnar_iceberg_fdw_validator$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.iceberg_rest_namespaces(catalog_uri text)
 RETURNS SETOF text
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_iceberg_rest_namespaces$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.iceberg_rest_scan(catalog_uri text, namespace text, table_name text)
 RETURNS SETOF record
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_iceberg_rest_scan$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.iceberg_rest_table_location(catalog_uri text, namespace text, table_name text)
 RETURNS text
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_iceberg_rest_table_location$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.iceberg_rest_tables(catalog_uri text, namespace text)
 RETURNS SETOF text
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_iceberg_rest_tables$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.iceberg_scan(metadata_path text)
 RETURNS SETOF record
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_iceberg_scan$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.maintenance_due(rel regclass, compact_due_fraction double precision DEFAULT 0.2, recluster_due_fraction double precision DEFAULT 0.05, OUT total_rows bigint, OUT deleted_rows bigint, OUT deleted_fraction double precision, OUT sort_key name[], OUT appended_groups bigint, OUT appended_rows bigint, OUT appended_fraction double precision, OUT compact_rewrite_due boolean, OUT recluster_due boolean, OUT recommendation text)
 RETURNS record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
	st_rows bigint;
	st_del  bigint;
	ss      record;
BEGIN
	-- stats() enforces require_caller_select(rel) before it returns a row, so a
	-- caller without SELECT on rel is refused here rather than reported to.
	SELECT COALESCE(sum(s.rowcount), 0), COALESCE(sum(s.deletedrows), 0)
	  INTO st_rows, st_del
	  FROM pgcolumnar.stats(rel) s;

	SELECT * INTO ss FROM pgcolumnar.sort_status(rel);

	total_rows   := st_rows;
	deleted_rows := st_del;
	deleted_fraction := CASE WHEN st_rows > 0
							 THEN st_del::float8 / st_rows ELSE 0 END;

	sort_key        := ss.sort_key;
	appended_groups := ss.appended_groups;
	appended_rows   := ss.appended_rows;
	appended_fraction := CASE WHEN (ss.sorted_rows + ss.appended_rows) > 0
							  THEN ss.appended_rows::float8
								   / (ss.sorted_rows + ss.appended_rows)
							  ELSE 0 END;

	compact_rewrite_due := (deleted_fraction >= compact_due_fraction);
	-- A sorted RUN must exist for recluster to mean anything. sort_status()
	-- reports a never-ordered table as entirely appended (no run), and
	-- vacuum_sorted() establishes a run without setting options.sort_by, so the
	-- run -- sorted_groups > 0 -- is the signal, not the sort_by label (sort_key
	-- is reported for information and may be NULL on an ordered table).
	recluster_due := (ss.sorted_groups > 0
					  AND ss.appended_groups > 0
					  AND appended_fraction >= recluster_due_fraction);

	recommendation := NULLIF(
		concat_ws(', ',
			CASE WHEN compact_rewrite_due THEN 'compact_rewrite' END,
			CASE WHEN recluster_due THEN 'recluster' END),
		'');
	RETURN;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.parquet_schema(path text)
 RETURNS TABLE(column_name text, data_type text, nullable boolean, field_id integer)
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_parquet_schema$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.read_avro_manifest(path text)
 RETURNS TABLE(status integer, content integer, file_path text, file_format text, record_count bigint, file_size_in_bytes bigint, partition text, sequence_number bigint)
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_read_avro_manifest$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.read_manifest_list(path text)
 RETURNS TABLE(manifest_path text, manifest_length bigint, content integer, partition_spec_id integer, added_files_count integer, existing_files_count integer, deleted_files_count integer, added_rows_count bigint, existing_rows_count bigint, deleted_rows_count bigint, sequence_number bigint, min_sequence_number bigint, added_snapshot_id bigint)
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_read_manifest_list$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.read_parquet(path text, field_ids integer[])
 RETURNS SETOF record
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_read_parquet$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.require_caller_select(rel regclass)
 RETURNS void
 LANGUAGE c
 STRICT
AS '$libdir/pgcolumnar', $function$pgcolumnar_require_caller_select$function$
;

-- set_options gained a guard in 1.0-alpha2: it now rejects a relation that
-- does not use the pgcolumnar access method, rather than recording a row in
-- pgcolumnar.options that nothing can read and that the drop hook (columnar
-- relations only) would leave behind as a dangling oid.
CREATE OR REPLACE FUNCTION pgcolumnar.set_options(
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
			USING HINT = 'Per-table options are read by the columnar writer and '
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

CREATE OR REPLACE FUNCTION pgcolumnar.sort_status(rel regclass, OUT sort_key name[], OUT total_groups bigint, OUT sorted_groups bigint, OUT appended_groups bigint, OUT sorted_rows bigint, OUT appended_rows bigint)
 RETURNS record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION pgcolumnar.stats(rel regclass, OUT stripeid bigint, OUT fileoffset bigint, OUT rowcount bigint, OUT deletedrows bigint, OUT chunkcount integer, OUT datalength bigint)
 RETURNS SETOF record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
BEGIN
	PERFORM pgcolumnar.require_caller_select(rel);
	RETURN QUERY
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
END;
$function$
;


-- foreign data wrappers added in 1.0-alpha2
CREATE FOREIGN DATA WRAPPER pgcolumnar_iceberg HANDLER pgcolumnar.iceberg_fdw_handler VALIDATOR pgcolumnar.iceberg_fdw_validator;
CREATE FOREIGN DATA WRAPPER pgcolumnar_iceberg_catalog VALIDATOR pgcolumnar.iceberg_catalog_fdw_validator;


-- restrict internal functions (PUBLIC execute revoked in 1.0-alpha2)
REVOKE ALL ON FUNCTION pgcolumnar.read_projection(regclass,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgcolumnar.reconstruct_via_projection(regclass,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgcolumnar.require_caller_select(regclass) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgcolumnar.vm_is_visible(regclass,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgcolumnar.vm_selftest(regclass,integer) FROM PUBLIC;


-- function comments (pg_get_functiondef does not carry them, so the new and
-- DROP-recreated functions above have none until set here; applied for every
-- pgcolumnar function so the upgraded catalog's comments match a fresh install)
COMMENT ON FUNCTION pgcolumnar."analyze"(regclass,text[]) IS 'collect per-column statistics by reading one column at a time rather than sampling every column (#414); null_frac, n_distinct and the most-common frequencies all come from that read, so they describe one population (#485); core ANALYZE remains the correctness path and nothing schedules this, see #415';
COMMENT ON FUNCTION pgcolumnar.add_projection(regclass,text,text[],text[]) IS 'declare a physical projection: a named column subset sorted on sort_key (gap 26)';
COMMENT ON FUNCTION pgcolumnar.alter_table_set_access_method(text,text) IS 'convert a table between heap and columnar storage';
COMMENT ON FUNCTION pgcolumnar.cluster(regclass,name[]) IS 'eager reorg: rewrite a columnar table with rows ordered by the Z-order space-filling curve over the given columns. Holds AccessExclusiveLock like CLUSTER/VACUUM FULL; the online incremental path is Phase F3';
COMMENT ON FUNCTION pgcolumnar.compact(regclass) IS 'lazy online compaction: retire row groups that are fully deleted, dropping their metadata so scans skip them. Holds only ShareUpdateExclusiveLock (concurrent reads and writes). Returns the number of groups retired (Phase F3a)';
COMMENT ON FUNCTION pgcolumnar.compact_rewrite(regclass,double precision,integer) IS 'lazy online space reclaim: rewrite partially-deleted row groups (deleted fraction >= min_deleted_fraction) to drop their dead rows, under ShareUpdateExclusiveLock (concurrent reads and writes). Returns the number of groups rewritten (Phase F3b)';
COMMENT ON FUNCTION pgcolumnar.drop_projection(regclass,text) IS 'drop a declared projection and free its storage (gap 26)';
COMMENT ON FUNCTION pgcolumnar.export_arrow(regclass,text) IS 'export a columnar table to an Arrow IPC stream file; returns rows written';
COMMENT ON FUNCTION pgcolumnar.export_parquet(regclass,text) IS 'export a columnar table to a Parquet file; returns rows written';
COMMENT ON FUNCTION pgcolumnar.file_split_offsets(text,integer) IS 'byte offsets that split a COPY text-format file into N record-aligned ranges (#300)';
COMMENT ON FUNCTION pgcolumnar.get_storage_id(regclass) IS 'storage id linking a columnar table to its metadata rows';
COMMENT ON FUNCTION pgcolumnar.iceberg_current_snapshot(text) IS 'read an Apache Iceberg table metadata.json and report its current snapshot (#388)';
COMMENT ON FUNCTION pgcolumnar.iceberg_data_files(text) IS 'list the live data files of an Apache Iceberg table current snapshot; refuses tables with delete files (#388)';
COMMENT ON FUNCTION pgcolumnar.iceberg_rest_namespaces(text) IS 'list the namespaces of an Iceberg REST catalog, one per row, multi-level namespaces dot-joined (#388)';
COMMENT ON FUNCTION pgcolumnar.iceberg_rest_scan(text,text,text) IS 'read a table named by an Iceberg REST catalog at its current snapshot; supply a column definition list, as for iceberg_scan; the metadata location is resolved through the catalog and read like any other Iceberg table (#388)';
COMMENT ON FUNCTION pgcolumnar.iceberg_rest_table_location(text,text,text) IS 'resolve the current metadata-location of a table named by an Iceberg REST catalog (catalog URI + namespace + table); the bearer token is read from the server environment variable PGCOLUMNAR_ICEBERG_REST_TOKEN, never a SQL argument (#388)';
COMMENT ON FUNCTION pgcolumnar.iceberg_rest_tables(text,text) IS 'list the table names in a namespace of an Iceberg REST catalog, one per row (#388)';
COMMENT ON FUNCTION pgcolumnar.iceberg_scan(text) IS 'read an Apache Iceberg table at its current snapshot; supply a column definition list, whose names resolve to the table schema field ids, e.g. SELECT * FROM pgcolumnar.iceberg_scan(path) AS t(id bigint, region text); applies position, equality, and deletion-vector deletes (#388)';
COMMENT ON FUNCTION pgcolumnar.import_arrow(regclass,text) IS 'insert rows from an Arrow IPC stream file into a columnar table; returns rows inserted';
COMMENT ON FUNCTION pgcolumnar.import_parquet(regclass,text) IS 'insert rows from a Parquet file, directory, or glob into a table; returns rows inserted (gap 27)';
COMMENT ON FUNCTION pgcolumnar.maintenance_due(regclass,double precision,double precision) IS 'report whether an online maintenance verb (compact_rewrite, recluster) is worth running, from table statistics alone; thresholds are parameters with defaults measured on #415; pure report, takes no lock and rewrites nothing (#415)';
COMMENT ON FUNCTION pgcolumnar.parallel_copy(regclass,text,integer) IS 'atomic parallel bulk load of a COPY text file into a columnar table using background workers: a single columnar table (any row order), or a RANGE-partitioned columnar table sorted by the partition key with one distinct partition set per worker (#300)';
COMMENT ON FUNCTION pgcolumnar.parallel_export_parquet(regclass,text,integer) IS 'parallel Parquet export using read-only background workers into a directory readable by pgcolumnar.read_parquet: a single columnar table split by row-group ranges, or a partitioned columnar table one file per partition; returns rows written (#300)';
COMMENT ON FUNCTION pgcolumnar.parquet_schema(text) IS 'report the leaf columns of a Parquet file and the PostgreSQL type each maps to; for a directory or glob, of its first file; field_id is the SchemaElement field id Iceberg projects by, NULL when the writer emitted none (Phase G scan core, #388)';
COMMENT ON FUNCTION pgcolumnar.read_avro_manifest(text) IS 'decode an Apache Iceberg Avro manifest file and report its data-file entries; the first step of Iceberg read support (#388)';
COMMENT ON FUNCTION pgcolumnar.read_manifest_list(text) IS 'decode an Apache Iceberg snapshot manifest-list Avro file and report the manifest files it points at (#388)';
COMMENT ON FUNCTION pgcolumnar.read_parquet(text) IS 'read a Parquet file, directory, or glob in place as a set of rows; requires a column definition list covering every leaf column, e.g. SELECT * FROM pgcolumnar.read_parquet(path) AS t(id int, name text) (Phase G)';
COMMENT ON FUNCTION pgcolumnar.read_parquet(text,integer[]) IS 'read a Parquet file by field id: output column i is bound to the file column whose Parquet field id equals field_ids[i], reading only those columns in that order, e.g. SELECT * FROM pgcolumnar.read_parquet(path, ARRAY[12,7]) AS t(c int, a int) (#388)';
COMMENT ON FUNCTION pgcolumnar.read_projection(regclass,text) IS 'read a projection''s stored columns (live rows), joined by | -- verification/debug (gap 26)';
COMMENT ON FUNCTION pgcolumnar.rebuild_projections(regclass) IS 'materialize declared projections that have no storage, after a logical restore (#266)';
COMMENT ON FUNCTION pgcolumnar.recluster(regclass,name[]) IS 'lazy online reclustering: re-establish global Z-order clustering over the given columns under ShareUpdateExclusiveLock (concurrent reads and writes), unlike the eager cluster() which holds AccessExclusiveLock. Returns the number of groups reclustered (Phase F3c)';
COMMENT ON FUNCTION pgcolumnar.reconstruct_via_projection(regclass,text) IS 'read all live rows via a projection, reconstructing non-covered columns from the base by row number (gap 26)';
COMMENT ON FUNCTION pgcolumnar.require_caller_select(regclass) IS 'raise unless the calling role may SELECT the relation; for SECURITY DEFINER callers (#560)';
COMMENT ON FUNCTION pgcolumnar.reset_options(regclass,boolean,boolean,boolean,boolean,boolean,boolean) IS 'reset per-table columnar options to the instance defaults';
COMMENT ON FUNCTION pgcolumnar.set_options(regclass,integer,integer,name,integer,name,name[]) IS 'set per-table columnar options; NULL leaves a value unchanged. sort_by declares the physical sort key applied by vacuum_sorted() with no explicit columns (#288); it is NOT auto-maintained -- rows inserted after a sort append in insert order, so re-run vacuum_sorted() to re-establish it, like PostgreSQL CLUSTER';
COMMENT ON FUNCTION pgcolumnar.sort_status(regclass) IS 'how much of an ordered columnar table is still in its ordered run (#301)';
COMMENT ON FUNCTION pgcolumnar.stats(regclass) IS 'per-row-group statistics for a columnar table';
COMMENT ON FUNCTION pgcolumnar.truncate(regclass) IS 'physical end-truncation: return trailing reclaimed blocks to the OS. Best-effort -- takes AccessExclusiveLock conditionally for the brief physical step and returns 0 without waiting if the table is busy. Only removes space freed before the oldest-xmin horizon. Gated by pgcolumnar.enable_end_truncation. Returns the number of blocks truncated (Phase F)';
COMMENT ON FUNCTION pgcolumnar.vacuum(regclass,integer) IS 'compact a columnar table by combining stripes and reclaiming deleted rows';
COMMENT ON FUNCTION pgcolumnar.vacuum_full(name,real,integer) IS 'compact every columnar table in a schema';
COMMENT ON FUNCTION pgcolumnar.vacuum_sorted(regclass) IS 'apply the table''s declared sort_by key from set_options (#288); errors if none is declared. Equivalent to a bare CLUSTER re-applying a remembered index.';
COMMENT ON FUNCTION pgcolumnar.vacuum_sorted(regclass,name[]) IS 'compact a columnar table, storing rows sorted ascending (NULLS LAST) on the given columns. With no columns, applies the table''s declared sort_by key from set_options (#288), like a bare CLUSTER re-applying a remembered index; errors if none is declared. Supports any btree-orderable column including text (unlike the numeric-only Z-order cluster()). One-shot: not auto-maintained.';
COMMENT ON FUNCTION pgcolumnar.vm_is_visible(regclass,integer) IS 'gap 28: is the synthetic block marked all-visible in the VM fork?';
COMMENT ON FUNCTION pgcolumnar.vm_selftest(regclass,integer) IS 'gap 28 phase-1 self-test: set a VM-fork all-visible bit and read it back';
