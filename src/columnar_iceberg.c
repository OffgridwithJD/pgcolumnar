/*-------------------------------------------------------------------------
 *
 * columnar_iceberg.c
 *		A read-only, filesystem-backed Apache Iceberg catalog reader
 *		(#388 phase 3). This first piece resolves the metadata pointer: given
 *		a table's metadata.json, it reports the current snapshot the table
 *		declares -- its id, sequence number, operation, and the manifest-list
 *		file that snapshot points at. No Avro, no network; pure JSON parsed
 *		through the server's jsonb reader, the same way columnar_avro.c reads
 *		the schema embedded in a manifest.
 *
 * Written fresh for pgColumnar from the public Apache Iceberg table spec.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "catalog/pg_authid_d.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "storage/fd.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/numeric.h"
#include "utils/tuplestore.h"

/*
 * A table metadata.json is small (schemas, snapshot log, partition specs). Cap
 * the read so a mis-pointed path cannot slurp an arbitrary large server file.
 */
#define ICE_MAX_METADATA ((int64) 64 * 1024 * 1024)

/* the current_snapshot result, kept in one place so the C and SQL agree */
#define ICE_SNAP_NCOLS 7

/*
 * slurp a whole (small) local text file into a palloc'd, NUL-terminated string
 * so jsonb_in can parse it. Mirrors columnar_avro.c's av_slurp_file; when
 * phase 3b adds more catalog SRFs this and the SRF preamble below are the
 * pieces to promote into one shared file-reading helper.
 */
static char *
ice_slurp_text(const char *path)
{
	FILE	   *f = AllocateFile(path, PG_BINARY_R);
	int64		flen;
	char	   *buf;

	if (f == NULL)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\" for reading: %m", path)));
	if (fseeko(f, 0, SEEK_END) != 0)
		ereport(ERROR, (errcode_for_file_access(),
						errmsg("could not seek \"%s\": %m", path)));
	flen = (int64) ftello(f);
	if (flen < 0 || flen > ICE_MAX_METADATA)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("columnar: Iceberg metadata \"%s\" is too large", path)));
	if (fseeko(f, 0, SEEK_SET) != 0)
		ereport(ERROR, (errcode_for_file_access(),
						errmsg("could not seek \"%s\": %m", path)));
	buf = (char *) palloc(flen + 1);
	if (flen > 0 && fread(buf, 1, flen, f) != (size_t) flen)
		ereport(ERROR, (errcode_for_file_access(),
						errmsg("could not read \"%s\": %m", path)));
	buf[flen] = '\0';
	FreeFile(f);
	return buf;
}

/*
 * the SRF preamble: privilege gate, result-set checks, tupdesc, and the
 * per-query-context tuplestore (created in the per-query, not per-call,
 * context; the per-call context frees before the executor drains the store).
 */
static Tuplestorestate *
ice_srf_begin(FunctionCallInfo fcinfo, TupleDesc *tupdesc)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	Tuplestorestate *tupstore;
	MemoryContext oldcxt;

	if (!has_privs_of_role(GetUserId(), ROLE_PG_READ_SERVER_FILES))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser or a member of the pg_read_server_files role to read a server file")));
	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo) ||
		(rsinfo->allowedModes & SFRM_Materialize) == 0)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in a context that cannot accept a set")));
	if (get_call_result_type(fcinfo, NULL, tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in a context that cannot accept it")));

	oldcxt = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);
	tupstore = tuplestore_begin_heap(false, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = CreateTupleDescCopy(*tupdesc);
	MemoryContextSwitchTo(oldcxt);
	return tupstore;
}

/* a JSON object field by key, or NULL when the container is not an object or
 * has no such key */
static JsonbValue *
ice_field(JsonbContainer *c, const char *key)
{
	if (c == NULL || !JsonContainerIsObject(c))
		return NULL;
	return getKeyJsonValueFromContainer(c, key, (int) strlen(key),
										palloc(sizeof(JsonbValue)));
}

/* interpret a JSON number as an int64; false if v is not a (non-null) number */
static bool
ice_num_int64(JsonbValue *v, int64 *out)
{
	if (v == NULL || v->type != jbvNumeric)
		return false;
	*out = DatumGetInt64(DirectFunctionCall1(numeric_int8,
											 NumericGetDatum(v->val.numeric)));
	return true;
}

/* a JSON string field as a palloc'd text Datum, or set the null flag */
static Datum
ice_str_field(JsonbContainer *c, const char *key, bool *isnull)
{
	JsonbValue *v = ice_field(c, key);

	if (v == NULL || v->type != jbvString)
	{
		*isnull = true;
		return (Datum) 0;
	}
	*isnull = false;
	return PointerGetDatum(cstring_to_text_with_len(v->val.string.val,
													v->val.string.len));
}

PG_FUNCTION_INFO_V1(pgcolumnar_iceberg_current_snapshot);

/*
 * pgcolumnar.iceberg_current_snapshot(metadata_path text)
 *
 * Parse an Iceberg table metadata.json and return the current snapshot it
 * declares: the snapshot whose "snapshot-id" equals "current-snapshot-id".
 * Zero rows when the table has no current snapshot (the field is absent, JSON
 * null, or -1). Raises when the file is not Iceberg table metadata, or when
 * the declared current snapshot is not present in the snapshots array.
 */
Datum
pgcolumnar_iceberg_current_snapshot(PG_FUNCTION_ARGS)
{
	char	   *path = text_to_cstring(PG_GETARG_TEXT_PP(0));
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	char	   *json;
	Jsonb	   *jb;
	JsonbContainer *root;
	JsonbValue *csid;
	JsonbValue *snaps;
	JsonbContainer *arr;
	int64		cur;
	uint32		i,
				n;
	bool		found = false;

	tupstore = ice_srf_begin(fcinfo, &tupdesc);

	json = ice_slurp_text(path);
	/* jsonb_in raises a clean 22P02 on malformed JSON */
	jb = DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(json)));
	root = &jb->root;

	if (!JsonContainerIsObject(root))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("iceberg: metadata \"%s\" is not a JSON object", path)));
	/* a minimal is-this-Iceberg gate so a random JSON file is rejected, not
	 * silently read as an empty table */
	if (ice_field(root, "format-version") == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("iceberg: \"%s\" has no format-version; not a table metadata file",
						path)));

	csid = ice_field(root, "current-snapshot-id");
	/* absent, JSON null, or -1: a table with no current snapshot -> zero rows */
	if (csid == NULL || csid->type == jbvNull ||
		!ice_num_int64(csid, &cur) || cur < 0)
		return (Datum) 0;

	snaps = ice_field(root, "snapshots");
	if (snaps == NULL || snaps->type != jbvBinary ||
		!JsonContainerIsArray(snaps->val.binary.data))
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: \"%s\" declares a current snapshot but has no snapshots array",
						path)));

	arr = snaps->val.binary.data;
	n = JsonContainerSize(arr);
	for (i = 0; i < n; i++)
	{
		JsonbValue *s = getIthJsonbValueFromContainer(arr, i);
		JsonbContainer *sc;
		JsonbValue *v;
		int64		sid;
		int64		num;
		Datum		values[ICE_SNAP_NCOLS];
		bool		nulls[ICE_SNAP_NCOLS];

		if (s == NULL || s->type != jbvBinary)
			continue;
		sc = s->val.binary.data;
		v = ice_field(sc, "snapshot-id");
		/* the resolution: only the snapshot the table names as current */
		if (!ice_num_int64(v, &sid) || sid != cur)
			continue;

		memset(nulls, false, sizeof(nulls));

		values[0] = Int64GetDatum(sid);						/* snapshot_id */

		v = ice_field(sc, "parent-snapshot-id");			/* optional */
		if (v != NULL && v->type != jbvNull && ice_num_int64(v, &num))
			values[1] = Int64GetDatum(num);
		else
			nulls[1] = true;

		v = ice_field(sc, "sequence-number");				/* 0 for v1 */
		values[2] = Int64GetDatum(ice_num_int64(v, &num) ? num : 0);

		v = ice_field(sc, "timestamp-ms");
		if (ice_num_int64(v, &num))
			values[3] = Int64GetDatum(num);
		else
			nulls[3] = true;

		/* operation lives under the summary object */
		v = ice_field(sc, "summary");
		if (v != NULL && v->type == jbvBinary)
			values[4] = ice_str_field(v->val.binary.data, "operation", &nulls[4]);
		else
			nulls[4] = true;

		values[5] = ice_str_field(sc, "manifest-list", &nulls[5]);

		v = ice_field(sc, "schema-id");						/* optional */
		if (ice_num_int64(v, &num))
			values[6] = Int32GetDatum((int32) num);
		else
			nulls[6] = true;

		tuplestore_putvalues(tupstore, tupdesc, values, nulls);
		found = true;
		break;
	}

	/* the table named a current snapshot that its own snapshots list omits */
	if (!found)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: current-snapshot-id " INT64_FORMAT " in \"%s\" is not present in the snapshots array",
						cur, path)));

	return (Datum) 0;
}
