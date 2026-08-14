/*-------------------------------------------------------------------------
 *
 * columnar_iceberg.c
 *		A read-only, filesystem-backed Apache Iceberg catalog reader
 *		(#388 phase 3). Two entry points:
 *
 *		iceberg_current_snapshot	resolves the metadata pointer: given a
 *									table's metadata.json, reports the current
 *									snapshot the table declares (phase 3a).
 *
 *		iceberg_data_files			chains that snapshot through its manifest
 *									list and manifests to the live data files at
 *									the current snapshot, rebasing the recorded
 *									absolute paths onto the table's actual
 *									location and refusing loudly if the snapshot
 *									carries any delete files (phase 3b).
 *
 *		Metadata is pure JSON, parsed through the server's jsonb reader (the
 *		same way columnar_avro.c reads the schema embedded in a manifest); the
 *		manifest list and manifests are Avro, decoded by columnar_avro.c.
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

#include "columnar_avro.h"

/*
 * A table metadata.json is small (schemas, snapshot log, partition specs). Cap
 * the read so a mis-pointed path cannot slurp an arbitrary large server file.
 */
#define ICE_MAX_METADATA ((int64) 64 * 1024 * 1024)

/* the current_snapshot result, kept in one place so the C and SQL agree */
#define ICE_SNAP_NCOLS 7
/* the data_files result columns */
#define ICE_FILE_NCOLS 4

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

/* slurp a whole local binary file (a manifest list or manifest) into a palloc'd
 * buffer, for the Avro decoders in columnar_avro.c. */
static uint8 *
ice_slurp_bin(const char *path, int64 *outlen)
{
	FILE	   *f = AllocateFile(path, PG_BINARY_R);
	int64		flen;
	uint8	   *buf;

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
				 errmsg("columnar: Iceberg manifest \"%s\" is too large", path)));
	if (fseeko(f, 0, SEEK_SET) != 0)
		ereport(ERROR, (errcode_for_file_access(),
						errmsg("could not seek \"%s\": %m", path)));
	buf = (uint8 *) palloc(Max(flen, 1));
	if (flen > 0 && fread(buf, 1, flen, f) != (size_t) flen)
		ereport(ERROR, (errcode_for_file_access(),
						errmsg("could not read \"%s\": %m", path)));
	FreeFile(f);
	*outlen = flen;
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

/* a required JSON string field as a palloc'd cstring; raises if absent */
static char *
ice_str_required(JsonbContainer *c, const char *key, const char *path)
{
	JsonbValue *v = ice_field(c, key);

	if (v == NULL || v->type != jbvString)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: \"%s\" is missing the required \"%s\" field",
						path, key)));
	return pnstrdup(v->val.string.val, v->val.string.len);
}

/*
 * Resolve the current snapshot object from a parsed metadata.json root. Returns
 * the snapshot's container, or NULL when the table declares no current snapshot
 * (a legal, empty table). Raises when the file is not Iceberg table metadata, or
 * when the declared current snapshot is absent from the snapshots array. On a
 * non-NULL return *cur holds the current-snapshot-id. Shared by both entry
 * points so they resolve identically.
 */
static JsonbContainer *
ice_current_snapshot(JsonbContainer *root, const char *path, int64 *cur)
{
	JsonbValue *csid;
	JsonbValue *snaps;
	JsonbContainer *arr;
	uint32		i,
				n;

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
	/* absent, JSON null, or -1: a table with no current snapshot */
	if (csid == NULL || csid->type == jbvNull ||
		!ice_num_int64(csid, cur) || *cur < 0)
		return NULL;

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

		/* cheap hygiene for a scan over an untrusted (if capped) snapshot list */
		CHECK_FOR_INTERRUPTS();

		if (s == NULL || s->type != jbvBinary)
			continue;
		sc = s->val.binary.data;
		v = ice_field(sc, "snapshot-id");
		/* the resolution: only the snapshot the table names as current */
		if (ice_num_int64(v, &sid) && sid == *cur)
			return sc;
	}

	/* the table named a current snapshot that its own snapshots list omits */
	ereport(ERROR,
			(errcode(ERRCODE_DATA_CORRUPTED),
			 errmsg("iceberg: current-snapshot-id " INT64_FORMAT " in \"%s\" is not present in the snapshots array",
					*cur, path)));
	return NULL;				/* unreachable */
}

/* the directory portion of a path (everything before the last '/'), palloc'd */
static char *
ice_dirname(const char *path)
{
	const char *slash = strrchr(path, '/');

	if (slash == NULL)
		return pstrdup(".");
	if (slash == path)			/* the root "/" */
		return pstrdup("/");
	return pnstrdup(path, slash - path);
}

/*
 * The table's actual location on disk, derived from where its metadata.json
 * sits: Iceberg's filesystem layout puts metadata at <location>/metadata/<file>,
 * so the location is the parent of the directory holding metadata_path.
 */
static char *
ice_actual_location(const char *metadata_path)
{
	char	   *metadir = ice_dirname(metadata_path);

	return ice_dirname(metadir);
}

/* strip a leading "file://" scheme from a recorded root, in place-ish */
static const char *
ice_strip_scheme(const char *path)
{
	if (strncmp(path, "file://", 7) == 0)
		return path + 7;
	return path;
}

/*
 * Rebase a path recorded in the table onto the table's actual location, and
 * refuse anything that would escape that location. This is the arbitrary-file
 * -read boundary: `recorded_path` comes from an untrusted metadata.json, so a
 * byte-prefix match is not enough -- `<location>/../../etc/passwd` shares the
 * prefix, and `<location>EVIL/x` shares the bytes but is a sibling. So:
 *
 *   1. require the recorded path to sit under `recorded_root` on a PATH
 *      boundary (the next byte is '/' or end), which rejects the sibling;
 *   2. re-root onto `actual_root`, then canonicalize the result and re-check
 *      containment, which collapses any ".." and rejects a traversal escape.
 *
 * `actual_root` is passed already canonicalized so the containment test compares
 * like with like.
 */
static char *
ice_rebase(const char *recorded_root, const char *actual_root,
		   const char *recorded_path, const char *what, const char *mdpath)
{
	const char *p = ice_strip_scheme(recorded_path);
	size_t		rlen = strlen(recorded_root);
	size_t		alen;
	char	   *cand;

	/* tolerate a trailing slash on the recorded location */
	while (rlen > 1 && recorded_root[rlen - 1] == '/')
		rlen--;

	if (strncmp(p, recorded_root, rlen) != 0 ||
		(p[rlen] != '\0' && p[rlen] != '/'))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("iceberg: %s path \"%s\" from \"%s\" is not under the table location \"%s\"",
						what, recorded_path, mdpath, recorded_root)));

	cand = psprintf("%s%s", actual_root, p + rlen);
	canonicalize_path(cand);	/* collapse any ".." / "." / "//" segments */

	alen = strlen(actual_root);
	if (strncmp(cand, actual_root, alen) != 0 ||
		(cand[alen] != '\0' && cand[alen] != '/'))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("iceberg: %s path \"%s\" from \"%s\" escapes the table location \"%s\"",
						what, recorded_path, mdpath, actual_root)));
	return cand;
}

/*
 * The rebase to use for a path we are about to OPEN. ice_rebase's lexical
 * canonicalization collapses ".." but is symlink-blind: a symlink placed under
 * the location by whoever wrote the (untrusted) table would pass the lexical
 * containment check and then be followed out of the location on open. So resolve
 * the rebased path with realpath() -- which collapses symlinks as well as ".."
 * -- and re-check containment against the (also realpath'd) actual root before
 * handing it to the file reader. A legitimately relocated table never symlinks
 * out of its own directory, so honest tables resolve under the actual root and
 * are unaffected. `actual_root_real` must already be realpath'd by the caller.
 */
static char *
ice_open_path(const char *recorded_root, const char *actual_root_real,
			  const char *recorded_path, const char *what, const char *mdpath)
{
	char	   *cand = ice_rebase(recorded_root, actual_root_real,
								  recorded_path, what, mdpath);
	char	   *real = realpath(cand, NULL);
	size_t		alen;
	char	   *out;

	if (real == NULL)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("iceberg: could not resolve %s \"%s\" from \"%s\": %m",
						what, recorded_path, mdpath)));

	alen = strlen(actual_root_real);
	if (strncmp(real, actual_root_real, alen) != 0 ||
		(real[alen] != '\0' && real[alen] != '/'))
	{
		char	   *escaped = pstrdup(real);

		free(real);
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("iceberg: %s path \"%s\" from \"%s\" resolves outside the table location \"%s\"",
						what, recorded_path, mdpath, actual_root_real),
				 errdetail("Resolved to \"%s\".", escaped)));
	}
	out = pstrdup(real);
	free(real);
	return out;
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
	JsonbContainer *sc;
	JsonbValue *v;
	int64		cur;
	int64		num;
	Datum		values[ICE_SNAP_NCOLS];
	bool		nulls[ICE_SNAP_NCOLS];

	tupstore = ice_srf_begin(fcinfo, &tupdesc);

	json = ice_slurp_text(path);
	/* jsonb_in raises a clean 22P02 on malformed JSON */
	jb = DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(json)));

	sc = ice_current_snapshot(&jb->root, path, &cur);
	if (sc == NULL)
		return (Datum) 0;		/* no current snapshot -> zero rows */

	memset(nulls, false, sizeof(nulls));

	values[0] = Int64GetDatum(cur);							/* snapshot_id */

	v = ice_field(sc, "parent-snapshot-id");				/* optional */
	if (v != NULL && v->type != jbvNull && ice_num_int64(v, &num))
		values[1] = Int64GetDatum(num);
	else
		nulls[1] = true;

	v = ice_field(sc, "sequence-number");					/* 0 for v1 */
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

	v = ice_field(sc, "schema-id");							/* optional */
	if (ice_num_int64(v, &num))
		values[6] = Int32GetDatum((int32) num);
	else
		nulls[6] = true;

	tuplestore_putvalues(tupstore, tupdesc, values, nulls);
	return (Datum) 0;
}

PG_FUNCTION_INFO_V1(pgcolumnar_iceberg_data_files);

/*
 * pgcolumnar.iceberg_data_files(metadata_path text)
 *
 * List the live data files of the current snapshot: resolve the snapshot, read
 * its manifest list, then each manifest, and emit one row per data-file entry
 * (path, format, record count, partition). The recorded absolute paths are
 * rebased onto the table's actual location, so a relocated table reads. Zero
 * rows for a table with no current snapshot.
 *
 * Deletes are refused, not ignored: a snapshot that carries any delete manifest
 * (manifest_file.content != 0) or any delete/removed entry (data_file.content
 * != 0, or a DELETED status) raises feature_not_supported (0A000). A reader that
 * silently dropped deletes would return rows the table says are gone.
 */
Datum
pgcolumnar_iceberg_data_files(PG_FUNCTION_ARGS)
{
	char	   *path = text_to_cstring(PG_GETARG_TEXT_PP(0));
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	char	   *json;
	Jsonb	   *jb;
	JsonbContainer *sc;
	int64		cur;
	const char *recorded_root;
	char	   *actual_root;
	char	   *ml_recorded;
	char	   *ml_path;
	uint8	   *mlbuf;
	int64		mllen;
	PgColumnarAvroManifestFile *mfs;
	int			nmf;
	int			mi;

	tupstore = ice_srf_begin(fcinfo, &tupdesc);

	json = ice_slurp_text(path);
	jb = DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(json)));

	sc = ice_current_snapshot(&jb->root, path, &cur);
	if (sc == NULL)
		return (Datum) 0;		/* no current snapshot -> no data files */

	/* the recorded table root, and where the table actually sits now. The
	 * actual root is resolved with realpath once here so the files we open can
	 * be re-checked for containment against a symlink-resolved form. */
	recorded_root = ice_strip_scheme(ice_str_required(&jb->root, "location", path));
	{
		char	   *raw = ice_actual_location(path);
		char	   *real = realpath(raw, NULL);

		if (real == NULL)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("iceberg: could not resolve the table location of \"%s\": %m",
							path)));
		actual_root = pstrdup(real);
		free(real);
	}

	ml_recorded = ice_str_required(sc, "manifest-list", path);
	ml_path = ice_open_path(recorded_root, actual_root, ml_recorded,
							"manifest-list", path);
	mlbuf = ice_slurp_bin(ml_path, &mllen);
	mfs = PgColumnarAvroReadManifestList(mlbuf, mllen, &nmf);

	for (mi = 0; mi < nmf; mi++)
	{
		char	   *m_path;
		uint8	   *mbuf;
		int64		mlen;
		PgColumnarAvroManifestEntry *entries;
		int			ne;
		int			ei;

		CHECK_FOR_INTERRUPTS();

		/* a delete manifest: refuse the whole snapshot, do not open it */
		if (mfs[mi].content != 0)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("iceberg: snapshot " INT64_FORMAT " has delete files; reading tables with deletes is not supported",
							cur),
					 errdetail("Manifest \"%s\" has content %d (a delete manifest).",
							   mfs[mi].manifest_path, mfs[mi].content)));

		m_path = ice_open_path(recorded_root, actual_root, mfs[mi].manifest_path,
							   "manifest", path);
		mbuf = ice_slurp_bin(m_path, &mlen);
		entries = PgColumnarAvroReadManifest(mbuf, mlen, &ne);

		for (ei = 0; ei < ne; ei++)
		{
			PgColumnarAvroManifestEntry *e = &entries[ei];
			Datum		values[ICE_FILE_NCOLS];
			bool		nulls[ICE_FILE_NCOLS];

			CHECK_FOR_INTERRUPTS();

			/* a delete file, or an entry the snapshot marks removed (status 2
			 * DELETED): refuse rather than silently drop it */
			if (e->content != 0 || e->status == 2)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("iceberg: snapshot " INT64_FORMAT " has delete files; reading tables with deletes is not supported",
								cur),
						 errdetail("Entry \"%s\" has content %d, status %d.",
								   e->file_path, e->content, e->status)));

			memset(nulls, false, sizeof(nulls));
			values[0] = PointerGetDatum(cstring_to_text(
										ice_rebase(recorded_root, actual_root,
												   e->file_path, "data-file", path)));
			if (e->file_format != NULL)
				values[1] = PointerGetDatum(cstring_to_text(e->file_format));
			else
				nulls[1] = true;
			values[2] = Int64GetDatum(e->record_count);
			if (e->partition != NULL)
				values[3] = PointerGetDatum(cstring_to_text(e->partition));
			else
				nulls[3] = true;

			tuplestore_putvalues(tupstore, tupdesc, values, nulls);
		}

		pfree(mbuf);
	}

	pfree(mlbuf);
	return (Datum) 0;
}
