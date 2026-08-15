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
#include "catalog/pg_collation_d.h"
#include "catalog/pg_type_d.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "storage/fd.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "executor/tuptable.h"
#include "utils/datum.h"
#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/numeric.h"
#include "utils/tuplestore.h"
#include "utils/typcache.h"

#include "columnar_avro.h"
#include "columnar_parquet_reader.h"

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

/*
 * Callback invoked once per live entry of the current snapshot, with the entry
 * and the roots needed to rebase its recorded path. The entry's `content`
 * distinguishes data (0) from position-delete (1) files, and its
 * `sequence_number` has been resolved (inheriting the manifest's when the entry
 * left it null). Shared by iceberg_data_files (lists data files) and iceberg_scan
 * (reads them and applies deletes).
 */
typedef void (*IceDataFileCb) (void *ctx, PgColumnarAvroManifestEntry *e,
							   const PgColumnarAvroManifestFile *mf,
							   const char *recorded_root, const char *actual_root,
							   const char *mdpath, int64 snapshot_id);

/*
 * Walk the current snapshot's live entries and hand each to `cb`. Resolves the
 * snapshot from an already-parsed metadata.json `root` (so the file is read and
 * parsed once per call), reads its manifest list and each manifest (opening both
 * through ice_open_path's path boundary).
 *
 * When `collect_deletes` is false (the lister), any delete file or removed entry
 * is refused loudly (0A000). When true (the scan), position-delete (content 1)
 * and equality-delete (content 2) entries are passed to `cb` alongside data
 * entries (content 0), and removed entries (status 2) are skipped. Does nothing
 * when there is no current snapshot.
 */
static void
ice_walk_data_files(const char *path, JsonbContainer *root,
					bool collect_deletes, IceDataFileCb cb, void *ctx)
{
	JsonbContainer *sc;
	int64		cur;
	const char *recorded_root;
	char	   *actual_root;
	char	   *ml_path;
	uint8	   *mlbuf;
	int64		mllen;
	PgColumnarAvroManifestFile *mfs;
	int			nmf;
	int			mi;

	sc = ice_current_snapshot(root, path, &cur);
	if (sc == NULL)
		return;					/* no current snapshot -> no data files */

	/* the recorded table root, and where the table actually sits now. The
	 * actual root is resolved with realpath once here so the files we open can
	 * be re-checked for containment against a symlink-resolved form. */
	recorded_root = ice_strip_scheme(ice_str_required(root, "location", path));
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

	ml_path = ice_open_path(recorded_root, actual_root,
							ice_str_required(sc, "manifest-list", path),
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

		/* the lister refuses a delete manifest without even opening it */
		if (mfs[mi].content != 0 && !collect_deletes)
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

			CHECK_FOR_INTERRUPTS();

			if (!collect_deletes)
			{
				/* the lister refuses any delete file or removed entry */
				if (e->content != 0 || e->status == 2)
					ereport(ERROR,
							(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							 errmsg("iceberg: snapshot " INT64_FORMAT " has delete files; reading tables with deletes is not supported",
									cur),
							 errdetail("Entry \"%s\" has content %d, status %d.",
									   e->file_path, e->content, e->status)));
			}
			else
			{
				/* the scan skips removed entries; both delete kinds are
				 * collected and applied by the caller */
				if (e->status == 2)
					continue;
			}

			/* a manifest entry with no data-file path is corrupt metadata; refuse
			 * it here so neither consumer dereferences a NULL file_path (the scan
			 * pstrdup's it, the lister rebases it, the error path below prints it) */
			if (e->file_path == NULL)
				ereport(ERROR,
						(errcode(ERRCODE_DATA_CORRUPTED),
						 errmsg("iceberg: a manifest entry in snapshot " INT64_FORMAT " has no data file path",
								cur)));

			/* resolve the data sequence number. A manifest whose entry schema
			 * has no sequence-number column at all is v1-shaped: the spec
			 * defaults every file's sequence number to 0, for every status.
			 * In a v2 manifest (the column exists) a null is inherited from
			 * the manifest ONLY for ADDED (status 1) entries; an EXISTING (0)
			 * or DELETED (2) entry must carry it explicitly, so a null there
			 * is corrupt metadata, not an inheritance -- inheriting the
			 * current (too-new) manifest number could wrongly keep a row a
			 * delete should have removed. */
			if (!e->has_sequence_number)
			{
				if (!e->has_sequence_field)
				{
					e->sequence_number = 0;
					e->has_sequence_number = true;
				}
				else if (e->status != 1)
					ereport(ERROR,
							(errcode(ERRCODE_DATA_CORRUPTED),
							 errmsg("iceberg: a status-%d manifest entry for \"%s\" has no sequence number",
									e->status, e->file_path)));
				else
				{
					e->sequence_number = mfs[mi].sequence_number;
					e->has_sequence_number = true;
				}
			}

			cb(ctx, e, &mfs[mi], recorded_root, actual_root, path, cur);
		}

		pfree(mbuf);
	}

	pfree(mlbuf);
}

/* iceberg_data_files callback: emit one row (path, format, record count,
 * partition) per data-file entry. The path is lexically rebased (the row is
 * reported, not opened here). */
typedef struct IceListCtx
{
	Tuplestorestate *tupstore;
	TupleDesc	tupdesc;
}			IceListCtx;

static void
ice_list_cb(void *ctx, PgColumnarAvroManifestEntry *e,
			const PgColumnarAvroManifestFile *mf,
			const char *recorded_root, const char *actual_root,
			const char *mdpath, int64 snapshot_id)
{
	IceListCtx *c = (IceListCtx *) ctx;
	Datum		values[ICE_FILE_NCOLS];
	bool		nulls[ICE_FILE_NCOLS];

	(void) mf;
	(void) snapshot_id;
	memset(nulls, false, sizeof(nulls));
	values[0] = PointerGetDatum(cstring_to_text(
								ice_rebase(recorded_root, actual_root,
										   e->file_path, "data-file", mdpath)));
	if (e->file_format != NULL)
		values[1] = PointerGetDatum(cstring_to_text(e->file_format));
	else
		nulls[1] = true;
	values[2] = Int64GetDatum(e->record_count);
	if (e->partition != NULL)
		values[3] = PointerGetDatum(cstring_to_text(e->partition));
	else
		nulls[3] = true;

	tuplestore_putvalues(c->tupstore, c->tupdesc, values, nulls);
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
	IceListCtx	ctx;
	Jsonb	   *jb;

	ctx.tupstore = ice_srf_begin(fcinfo, &ctx.tupdesc);
	jb = DatumGetJsonbP(DirectFunctionCall1(jsonb_in,
											CStringGetDatum(ice_slurp_text(path))));
	ice_walk_data_files(path, &jb->root, false, ice_list_cb, &ctx);
	return (Datum) 0;
}

/*
 * Locate the "fields" array of the table's current schema in a parsed
 * metadata.json: the entry of "schemas" whose "schema-id" equals
 * "current-schema-id", or the v1 single top-level "schema" object.
 */
static JsonbContainer *
ice_current_schema_fields(JsonbContainer *root, const char *path)
{
	JsonbValue *schemas = ice_field(root, "schemas");
	JsonbValue *curid = ice_field(root, "current-schema-id");
	JsonbValue *fields = NULL;
	int64		want;

	if (schemas != NULL && schemas->type == jbvBinary &&
		JsonContainerIsArray(schemas->val.binary.data) &&
		ice_num_int64(curid, &want))
	{
		JsonbContainer *arr = schemas->val.binary.data;
		uint32		ns = JsonContainerSize(arr);
		uint32		k;

		for (k = 0; k < ns; k++)
		{
			JsonbValue *s = getIthJsonbValueFromContainer(arr, k);
			int64		sid;

			if (s == NULL || s->type != jbvBinary)
				continue;
			if (ice_num_int64(ice_field(s->val.binary.data, "schema-id"), &sid) &&
				sid == want)
			{
				fields = ice_field(s->val.binary.data, "fields");
				break;
			}
		}
	}
	if (fields == NULL)			/* v1: a single top-level "schema" object */
	{
		JsonbValue *sch = ice_field(root, "schema");

		if (sch != NULL && sch->type == jbvBinary)
			fields = ice_field(sch->val.binary.data, "fields");
	}
	if (fields == NULL || fields->type != jbvBinary ||
		!JsonContainerIsArray(fields->val.binary.data))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("iceberg: \"%s\" has no current schema fields", path)));
	return fields->val.binary.data;
}

/*
 * Build the field id to bind each output column to, by matching the output
 * column name to a field in the table's current schema. Returns a palloc'd array
 * of one id per non-dropped attribute, in attribute order; *nout is its length.
 * A column name absent from the schema is an error. Name matching is exact and
 * case-sensitive against the schema (quote a mixed-case name in the column
 * definition list to preserve its case).
 */
static int *
ice_field_ids_for_columns(JsonbContainer *root, TupleDesc tupdesc,
						  const char *path, int *nout)
{
	JsonbContainer *fieldsc = ice_current_schema_fields(root, path);
	uint32		nf = JsonContainerSize(fieldsc);
	int			natts = tupdesc->natts;
	int		   *ids;
	int			outn = 0;
	int			i;

	for (i = 0; i < natts; i++)
		if (!TupleDescAttr(tupdesc, i)->attisdropped)
			outn++;
	ids = (int *) palloc(sizeof(int) * Max(outn, 1));
	*nout = 0;

	for (i = 0; i < natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(tupdesc, i);
		const char *nm;
		int			found = -1;
		uint32		j;

		if (att->attisdropped)
			continue;
		nm = NameStr(att->attname);
		for (j = 0; j < nf; j++)
		{
			JsonbValue *f = getIthJsonbValueFromContainer(fieldsc, j);
			JsonbValue *fn;
			int64		fid;

			if (f == NULL || f->type != jbvBinary)
				continue;
			fn = ice_field(f->val.binary.data, "name");
			if (fn == NULL || fn->type != jbvString)
				continue;
			if ((int) strlen(nm) == fn->val.string.len &&
				strncmp(nm, fn->val.string.val, fn->val.string.len) == 0)
			{
				if (ice_num_int64(ice_field(f->val.binary.data, "id"), &fid))
					found = (int) fid;
				break;
			}
		}
		if (found < 0)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_COLUMN),
					 errmsg("iceberg: output column \"%s\" is not a field in the table's current schema",
							nm)));
		ids[(*nout)++] = found;
	}
	return ids;
}

/* the reserved Iceberg field ids of a position-delete file's two columns */
#define ICE_POSDEL_PATH_ID 2147483546
#define ICE_POSDEL_POS_ID  2147483545

/* one collected manifest entry: a data file or a delete file of either kind */
typedef struct IceEntry
{
	char	   *file_path;		/* the path as recorded (rebased at read time) */
	char	   *file_format;	/* for the "only PARQUET" check on data files */
	int64		seq;			/* resolved data sequence number */
	int32	   *eq_ids;			/* content 2: the field ids defining equality */
	int			neq_ids;
	int32		spec_id;		/* the enclosing manifest's partition spec id */
	bool		has_spec_id;	/* false when the manifest list omitted it */
}			IceEntry;

/* one position-delete row: drop row `pos` of data file `dpath`, if this delete's
 * sequence number is greater than that data file's */
typedef struct IcePosDel
{
	char	   *dpath;
	int64		pos;
	int64		seq;
}			IcePosDel;

/* iceberg_scan collects the current snapshot's entries first (data and
 * position-delete files), then reads the data files applying the deletes. */
typedef struct IceScanCtx
{
	Tuplestorestate *tupstore;
	TupleDesc	tupdesc;
	TupleTableSlot *slot;
	const int  *field_ids;
	int			nfield;
	MemoryContext filectx;
	char	   *recorded_root;
	char	   *actual_root;
	char	   *mdpath;
	List	   *data;			/* IceEntry* content 0 */
	List	   *posdel;			/* IceEntry* content 1 */
	List	   *eqdel;			/* IceEntry* content 2 */
}			IceScanCtx;

static void
ice_scan_cb(void *ctx, PgColumnarAvroManifestEntry *e,
			const PgColumnarAvroManifestFile *mf,
			const char *recorded_root, const char *actual_root,
			const char *mdpath, int64 snapshot_id)
{
	IceScanCtx *c = (IceScanCtx *) ctx;
	IceEntry   *ie = (IceEntry *) palloc0(sizeof(IceEntry));

	(void) snapshot_id;
	if (c->recorded_root == NULL)
	{
		c->recorded_root = pstrdup(recorded_root);
		c->actual_root = pstrdup(actual_root);
		c->mdpath = pstrdup(mdpath);
	}
	ie->file_path = pstrdup(e->file_path);
	ie->file_format = e->file_format ? pstrdup(e->file_format) : NULL;
	ie->seq = e->sequence_number;
	ie->spec_id = mf->partition_spec_id;
	ie->has_spec_id = mf->has_partition_spec_id;
	if (e->nequality_ids > 0)
	{
		ie->eq_ids = (int32 *) palloc(e->nequality_ids * sizeof(int32));
		memcpy(ie->eq_ids, e->equality_ids, e->nequality_ids * sizeof(int32));
		ie->neq_ids = e->nequality_ids;
	}
	if (e->content == 0)
		c->data = lappend(c->data, ie);
	else if (e->content == 1)
		c->posdel = lappend(c->posdel, ie);
	else
		c->eqdel = lappend(c->eqdel, ie);
}

/*
 * Read every collected position-delete file into a flat list of (dpath, pos,
 * seq). Each file is opened through the path boundary and read by the reserved
 * field ids, so column names/order in the file do not matter.
 */
static List *
ice_read_pos_deletes(IceScanCtx *c)
{
	List	   *out = NIL;
	ListCell   *lc;
	TupleDesc	dtd;
	TupleTableSlot *wslot;
	TupleTableSlot *rslot;
	MemoryContext filectx;
	int			fids[2];

	if (c->posdel == NIL)
		return NIL;

	dtd = CreateTemplateTupleDesc(2);
	TupleDescInitEntry(dtd, 1, "file_path", TEXTOID, -1, 0);
	TupleDescInitEntry(dtd, 2, "pos", INT8OID, -1, 0);
#if PG_VERSION_NUM >= 190000
	/* PG19 asserts firstNonCachedOffsetAttr >= 0 on a manually built tupdesc;
	 * BlessTupleDesc does not compute it, TupleDescFinalize does */
	TupleDescFinalize(dtd);
#endif
	dtd = BlessTupleDesc(dtd);
	wslot = MakeSingleTupleTableSlot(dtd, &TTSOpsVirtual);
	rslot = MakeSingleTupleTableSlot(dtd, &TTSOpsMinimalTuple);
	fids[0] = ICE_POSDEL_PATH_ID;
	fids[1] = ICE_POSDEL_POS_ID;

	/* each delete file's Parquet footer + metadata (which pq_read_file_into
	 * leaves for its caller to reclaim) live in this scratch context, reset per
	 * file so an upsert-heavy table's many delete files do not accumulate
	 * O(files) footers. The (dpath, pos, seq) rows we keep are allocated in the
	 * outer context so they survive the reset. */
	filectx = AllocSetContextCreate(CurrentMemoryContext,
									"pgcolumnar iceberg_scan posdel",
									ALLOCSET_DEFAULT_SIZES);

	foreach(lc, c->posdel)
	{
		IceEntry   *pd = (IceEntry *) lfirst(lc);
		char	   *safe;
		Tuplestorestate *ts;
		MemoryContext old;

		/* v2 position deletes are Parquet; a Puffin/other delete file is a later
		 * step, refused here with a clear cause rather than a parse error */
		if (pd->file_format != NULL && strcmp(pd->file_format, "PARQUET") != 0)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("iceberg: position-delete file \"%s\" has format %s; only PARQUET position deletes are supported",
							pd->file_path, pd->file_format)));

		old = MemoryContextSwitchTo(filectx);
		safe = ice_open_path(c->recorded_root, c->actual_root,
							 pd->file_path, "position-delete", c->mdpath);
		ts = tuplestore_begin_heap(false, false, work_mem);
		(void) PgColumnarReadParquetByFieldId(safe, dtd, fids, 2, ts, wslot, NULL, 0);
		while (tuplestore_gettupleslot(ts, true, false, rslot))
		{
			bool		n1,
						n2;
			Datum		d1 = slot_getattr(rslot, 1, &n1);
			Datum		d2 = slot_getattr(rslot, 2, &n2);

			if (!n1 && !n2)
			{
				IcePosDel  *r;

				/* keep the row in the outer context, not the per-file scratch */
				MemoryContextSwitchTo(old);
				r = (IcePosDel *) palloc(sizeof(IcePosDel));
				r->dpath = text_to_cstring(DatumGetTextPP(d1));
				r->pos = DatumGetInt64(d2);
				r->seq = pd->seq;
				out = lappend(out, r);
				MemoryContextSwitchTo(filectx);
			}
		}
		tuplestore_end(ts);
		MemoryContextSwitchTo(old);
		MemoryContextReset(filectx);
	}
	MemoryContextDelete(filectx);
	ExecDropSingleTupleTableSlot(wslot);
	ExecDropSingleTupleTableSlot(rslot);
	return out;
}

/*
 * Is partition spec `spec_id` a partitioned spec? Resolved against the
 * metadata's "partition-specs"; a spec id the metadata does not define leaves
 * an equality delete's scope undecidable, which is corrupt metadata (XX001).
 */
static bool
ice_spec_is_partitioned(JsonbContainer *root, int32 spec_id, const char *path)
{
	JsonbValue *specs = ice_field(root, "partition-specs");

	if (specs != NULL && specs->type == jbvBinary &&
		JsonContainerIsArray(specs->val.binary.data))
	{
		JsonbContainer *arr = specs->val.binary.data;
		uint32		ns = JsonContainerSize(arr);
		uint32		k;

		for (k = 0; k < ns; k++)
		{
			JsonbValue *sp = getIthJsonbValueFromContainer(arr, k);
			int64		sid;
			JsonbValue *fields;

			if (sp == NULL || sp->type != jbvBinary)
				continue;
			if (!ice_num_int64(ice_field(sp->val.binary.data, "spec-id"), &sid) ||
				sid != spec_id)
				continue;
			/* a matched spec whose required "fields" is missing or mistyped
			 * cannot prove the spec unpartitioned; defaulting to unpartitioned
			 * would silently globalize a possibly partition-scoped delete */
			fields = ice_field(sp->val.binary.data, "fields");
			if (fields == NULL || fields->type != jbvBinary ||
				!JsonContainerIsArray(fields->val.binary.data))
				ereport(ERROR,
						(errcode(ERRCODE_DATA_CORRUPTED),
						 errmsg("iceberg: partition spec %d in \"%s\" has no fields array",
								spec_id, path)));
			return JsonContainerSize(fields->val.binary.data) > 0;
		}
	}
	ereport(ERROR,
			(errcode(ERRCODE_DATA_CORRUPTED),
			 errmsg("iceberg: \"%s\" does not define partition spec %d, which an equality delete's scope depends on",
					path, spec_id)));
	return false;				/* unreachable */
}

/*
 * Resolve an equality-delete column: find field id `fid` in the table's current
 * schema and map its Iceberg type to the Postgres type it is read and compared
 * as. The supported primitives cover the types the Parquet reader can project;
 * anything else is refused loudly (0A000) BEFORE any file is opened -- never
 * silently unapplied. *fname gets the schema field name (for the tupdesc and
 * error messages).
 */
static Oid
ice_eq_col_type(JsonbContainer *root, int32 fid, const char *path,
				const char **fname)
{
	JsonbContainer *fieldsc = ice_current_schema_fields(root, path);
	uint32		nf = JsonContainerSize(fieldsc);
	uint32		j;

	for (j = 0; j < nf; j++)
	{
		JsonbValue *f = getIthJsonbValueFromContainer(fieldsc, j);
		int64		id;
		JsonbValue *fn;
		JsonbValue *ft;
		char	   *tname;

		if (f == NULL || f->type != jbvBinary)
			continue;
		if (!ice_num_int64(ice_field(f->val.binary.data, "id"), &id) ||
			id != fid)
			continue;

		fn = ice_field(f->val.binary.data, "name");
		*fname = (fn != NULL && fn->type == jbvString)
			? pnstrdup(fn->val.string.val, fn->val.string.len)
			: psprintf("field_%d", fid);
		ft = ice_field(f->val.binary.data, "type");
		if (ft == NULL || ft->type != jbvString)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("iceberg: equality delete on field \"%s\" of a non-primitive type is not supported",
							*fname)));
		tname = pnstrdup(ft->val.string.val, ft->val.string.len);
		if (strcmp(tname, "int") == 0)
			return INT4OID;
		if (strcmp(tname, "long") == 0)
			return INT8OID;
		if (strcmp(tname, "string") == 0)
			return TEXTOID;
		if (strcmp(tname, "boolean") == 0)
			return BOOLOID;
		if (strcmp(tname, "date") == 0)
			return DATEOID;
		/* float/double are forbidden as equality-delete columns by the spec;
		 * everything else simply has no mapping yet */
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("iceberg: equality delete on field \"%s\" of type \"%s\" is not supported",
						*fname, tname)));
	}
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("iceberg: equality delete field id %d is not a top-level field of the table's current schema; equality deletes on dropped or nested columns are not supported",
					fid)));
	return InvalidOid;			/* unreachable */
}

/* one equality-delete row: the delete-column values, in the file's id order */
typedef struct IceEqRow
{
	Datum	   *vals;
	bool	   *nulls;
}			IceEqRow;

/* one equality-delete file, read into memory: its sequence number, the columns
 * that define the match, and every delete row */
typedef struct IceEqDel
{
	int64		seq;
	int			nids;
	int32	   *ids;
	Oid		   *types;
	int16	   *typlen;
	bool	   *typbyval;
	List	   *rows;			/* IceEqRow* */
}			IceEqDel;

/*
 * Read every applicable equality-delete file into memory. A delete whose
 * sequence number exceeds no data file's (seq <= min_data_seq) can never apply
 * -- the strict-< rule -- and is skipped entirely, unread and unvalidated, per
 * the spec (it has no effect on the scan). Each applicable entry is validated
 * (equality_ids present, PARQUET, a present partition_spec_id resolving to an
 * unpartitioned spec -- a partition-scoped equality delete applied globally
 * would over-delete, so it is refused), each equality column is mapped to a
 * Postgres type via the current schema, and the file is read projected to
 * exactly those columns by field id. Rows are kept as Datum arrays in the
 * calling context; the per-file Parquet footer/metadata live in a scratch
 * context reset per file (the 4a memory rule).
 */
static List *
ice_read_eq_deletes(IceScanCtx *c, JsonbContainer *root, const char *path,
					int64 min_data_seq)
{
	List	   *out = NIL;
	ListCell   *lc;
	MemoryContext filectx;

	if (c->eqdel == NIL)
		return NIL;

	filectx = AllocSetContextCreate(CurrentMemoryContext,
									"pgcolumnar iceberg_scan eqdel",
									ALLOCSET_DEFAULT_SIZES);

	foreach(lc, c->eqdel)
	{
		IceEntry   *ed = (IceEntry *) lfirst(lc);
		IceEqDel   *E;
		TupleDesc	dtd;
		TupleTableSlot *wslot;
		TupleTableSlot *rslot;
		Tuplestorestate *ts;
		char	   *safe;
		MemoryContext old;
		int			i;

		/* never applicable: no data file is strictly older than this delete */
		if (ed->seq <= min_data_seq)
			continue;

		/* the spec requires equality_ids when content = 2 */
		if (ed->neq_ids == 0)
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("iceberg: equality delete file \"%s\" has no equality_ids",
							ed->file_path)));
		if (ed->file_format != NULL && strcmp(ed->file_format, "PARQUET") != 0)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("iceberg: equality-delete file \"%s\" has format %s; only PARQUET equality deletes are supported",
							ed->file_path, ed->file_format)));
		/* the manifest list must say which partition spec the delete was
		 * written under; without it the scope is undecidable, and defaulting
		 * to "unpartitioned" would silently globalize a scoped delete */
		if (!ed->has_spec_id)
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("iceberg: the manifest list carries no partition_spec_id for equality delete file \"%s\"",
							ed->file_path)));
		if (ice_spec_is_partitioned(root, ed->spec_id, path))
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("iceberg: equality delete file \"%s\" is partition-scoped (spec %d), which is not supported",
							ed->file_path, ed->spec_id),
					 errdetail("Applying a partition-scoped equality delete globally would delete rows in other partitions.")));

		E = (IceEqDel *) palloc0(sizeof(IceEqDel));
		E->seq = ed->seq;
		E->nids = ed->neq_ids;
		E->ids = (int32 *) palloc(E->nids * sizeof(int32));
		memcpy(E->ids, ed->eq_ids, E->nids * sizeof(int32));
		E->types = (Oid *) palloc(E->nids * sizeof(Oid));
		E->typlen = (int16 *) palloc(E->nids * sizeof(int16));
		E->typbyval = (bool *) palloc(E->nids * sizeof(bool));
		E->rows = NIL;

		old = MemoryContextSwitchTo(filectx);
		dtd = CreateTemplateTupleDesc(E->nids);
		for (i = 0; i < E->nids; i++)
		{
			const char *fname = NULL;

			E->types[i] = ice_eq_col_type(root, E->ids[i], path, &fname);
			get_typlenbyval(E->types[i], &E->typlen[i], &E->typbyval[i]);
			TupleDescInitEntry(dtd, i + 1, fname, E->types[i], -1, 0);
		}
#if PG_VERSION_NUM >= 190000
		/* PG19 asserts firstNonCachedOffsetAttr >= 0 on a manually built
		 * tupdesc; BlessTupleDesc does not compute it, TupleDescFinalize does */
		TupleDescFinalize(dtd);
#endif
		dtd = BlessTupleDesc(dtd);
		wslot = MakeSingleTupleTableSlot(dtd, &TTSOpsVirtual);
		rslot = MakeSingleTupleTableSlot(dtd, &TTSOpsMinimalTuple);

		safe = ice_open_path(c->recorded_root, c->actual_root,
							 ed->file_path, "equality-delete", c->mdpath);
		ts = tuplestore_begin_heap(false, false, work_mem);
		(void) PgColumnarReadParquetByFieldId(safe, dtd, (const int *) E->ids,
											  E->nids, ts, wslot, NULL, 0);
		while (tuplestore_gettupleslot(ts, true, false, rslot))
		{
			IceEqRow   *row;

			/* keep the row in the outer context, not the per-file scratch */
			MemoryContextSwitchTo(old);
			row = (IceEqRow *) palloc(sizeof(IceEqRow));
			row->vals = (Datum *) palloc0(E->nids * sizeof(Datum));
			row->nulls = (bool *) palloc(E->nids * sizeof(bool));
			for (i = 0; i < E->nids; i++)
			{
				Datum		d = slot_getattr(rslot, i + 1, &row->nulls[i]);

				if (!row->nulls[i])
					row->vals[i] = datumCopy(d, E->typbyval[i], E->typlen[i]);
			}
			E->rows = lappend(E->rows, row);
			MemoryContextSwitchTo(filectx);
		}
		tuplestore_end(ts);
		ExecDropSingleTupleTableSlot(wslot);
		ExecDropSingleTupleTableSlot(rslot);
		MemoryContextSwitchTo(old);
		MemoryContextReset(filectx);
		out = lappend(out, E);
	}
	MemoryContextDelete(filectx);
	return out;
}

/* ascending qsort comparator over uint64 file ordinals */
static int
ice_cmp_u64(const void *a, const void *b)
{
	uint64		x = *(const uint64 *) a;
	uint64		y = *(const uint64 *) b;

	return (x < y) ? -1 : (x > y) ? 1 : 0;
}

/*
 * Does a data row (dv/dn, indexed by union column position) match ANY row of
 * equality-delete file E? A delete row matches when ALL of E's equality columns
 * are equal; a null delete value matches a null data value (IS NULL semantics,
 * per the spec), and only a null. mape maps E's column index to the union
 * position the probe read that column into.
 */
static bool
ice_eq_file_matches(IceEqDel *E, const int *mape, const Datum *dv,
					const bool *dn, TypeCacheEntry **utc)
{
	ListCell   *lc;

	foreach(lc, E->rows)
	{
		IceEqRow   *row = (IceEqRow *) lfirst(lc);
		bool		all = true;
		int			i;

		for (i = 0; i < E->nids; i++)
		{
			int			k = mape[i];

			if (dn[k] != row->nulls[i])
			{
				all = false;
				break;
			}
			if (!dn[k] &&
				!DatumGetBool(FunctionCall2Coll(&utc[k]->eq_opr_finfo,
												DEFAULT_COLLATION_OID,
												dv[k], row->vals[i])))
			{
				all = false;
				break;
			}
		}
		if (all)
			return true;
	}
	return false;
}

/*
 * The equality-delete PROBE pass over one data file: read only the union of the
 * eligible delete files' equality columns (projected by field id, so this is a
 * whole-file subset read whose tuplestore row index IS the file ordinal), test
 * each row against each eligible delete file, and append matching ordinals to
 * the caller's skip set (skip/nskip/cap, grown in the caller's memory
 * context). Returns the file's total row count, which the caller cross-checks
 * against the second (full) read. Scratch allocations live in c->filectx,
 * reset before returning.
 */
static int64
ice_eq_probe(IceScanCtx *c, IceEntry *d, List *elig,
			 uint64 **skip, int *nskip, int *cap)
{
	int			ne = list_length(elig);
	int			tot = 0;
	int			nuni = 0;
	int		   *uids;
	Oid		   *utypes;
	int		  **map;
	TypeCacheEntry **utc;
	TupleDesc	ptd;
	TupleTableSlot *wslot;
	TupleTableSlot *rslot;
	Tuplestorestate *ts;
	Datum	   *dv;
	bool	   *dn;
	char	   *safe;
	MemoryContext old;
	ListCell   *lc;
	int			e;
	int			k;
	uint64		ord = 0;

	/* everything below except the skip-set growth is per-data-file scratch,
	 * reclaimed by the reset at the end */
	old = MemoryContextSwitchTo(c->filectx);

	/* the union of the eligible files' equality columns, deduplicated, with a
	 * per-file map from its column index to the union position */
	foreach(lc, elig)
		tot += ((IceEqDel *) lfirst(lc))->nids;
	uids = (int *) palloc(tot * sizeof(int));
	utypes = (Oid *) palloc(tot * sizeof(Oid));
	map = (int **) palloc(ne * sizeof(int *));
	e = 0;
	foreach(lc, elig)
	{
		IceEqDel   *E = (IceEqDel *) lfirst(lc);
		int			i;

		map[e] = (int *) palloc(E->nids * sizeof(int));
		for (i = 0; i < E->nids; i++)
		{
			for (k = 0; k < nuni; k++)
				if (uids[k] == E->ids[i])
					break;
			if (k == nuni)
			{
				uids[nuni] = E->ids[i];
				utypes[nuni] = E->types[i];
				nuni++;
			}
			/* both resolved via the same current-schema lookup */
			Assert(utypes[k] == E->types[i]);
			map[e][i] = k;
		}
		e++;
	}
	utc = (TypeCacheEntry **) palloc(nuni * sizeof(TypeCacheEntry *));
	for (k = 0; k < nuni; k++)
	{
		utc[k] = lookup_type_cache(utypes[k], TYPECACHE_EQ_OPR_FINFO);
		if (!OidIsValid(utc[k]->eq_opr_finfo.fn_oid))
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("iceberg: equality delete column with field id %d has no equality operator",
							uids[k])));
	}

	ptd = CreateTemplateTupleDesc(nuni);
	for (k = 0; k < nuni; k++)
		TupleDescInitEntry(ptd, k + 1, psprintf("eq%d", uids[k]),
						   utypes[k], -1, 0);
#if PG_VERSION_NUM >= 190000
	TupleDescFinalize(ptd);
#endif
	ptd = BlessTupleDesc(ptd);
	wslot = MakeSingleTupleTableSlot(ptd, &TTSOpsVirtual);
	rslot = MakeSingleTupleTableSlot(ptd, &TTSOpsMinimalTuple);
	safe = ice_open_path(c->recorded_root, c->actual_root, d->file_path,
						 "data-file", c->mdpath);
	ts = tuplestore_begin_heap(false, false, work_mem);
	(void) PgColumnarReadParquetByFieldId(safe, ptd, uids, nuni, ts, wslot,
										  NULL, 0);
	dv = (Datum *) palloc(nuni * sizeof(Datum));
	dn = (bool *) palloc(nuni * sizeof(bool));
	while (tuplestore_gettupleslot(ts, true, false, rslot))
	{
		bool		matched = false;

		CHECK_FOR_INTERRUPTS();
		for (k = 0; k < nuni; k++)
			dv[k] = slot_getattr(rslot, k + 1, &dn[k]);
		e = 0;
		foreach(lc, elig)
		{
			if (ice_eq_file_matches((IceEqDel *) lfirst(lc), map[e], dv, dn, utc))
			{
				matched = true;
				break;
			}
			e++;
		}
		if (matched)
		{
			/* grow the skip set in the caller's context, not the scratch */
			MemoryContextSwitchTo(old);
			if (*nskip == *cap)
			{
				*cap = *cap ? *cap * 2 : 16;
				*skip = (*skip == NULL)
					? (uint64 *) palloc(*cap * sizeof(uint64))
					: (uint64 *) repalloc(*skip, *cap * sizeof(uint64));
			}
			(*skip)[(*nskip)++] = ord;
			MemoryContextSwitchTo(c->filectx);
		}
		ord++;
	}
	tuplestore_end(ts);
	ExecDropSingleTupleTableSlot(wslot);
	ExecDropSingleTupleTableSlot(rslot);
	MemoryContextSwitchTo(old);
	MemoryContextReset(c->filectx);
	return (int64) ord;
}

PG_FUNCTION_INFO_V1(pgcolumnar_iceberg_scan);

/*
 * pgcolumnar.iceberg_scan(metadata_path text) returns setof record
 *
 * Read an Apache Iceberg table at its current snapshot. The caller supplies a
 * column definition list; each output column name is resolved to a field id via
 * the table's current schema, and every live data file is read projected by
 * those ids -- so a data file written before a column rename still reads, since
 * Iceberg selects columns by id, not name or position.
 *
 * Row-level deletes are applied, each kind under its own spec rule:
 *
 * - Position deletes drop the listed row ordinals of the data file they name,
 *   when the data file's data sequence number is less than OR EQUAL TO the
 *   delete's (a position delete applies to data written in the same commit or
 *   earlier, so the same-sequence upsert case counts).
 * - Equality deletes drop every data row whose equality_ids column values match
 *   a delete row (all columns equal; null matches null), when the data file's
 *   sequence number is STRICTLY LESS THAN the delete's (an equality delete
 *   never touches same-commit data). Only global (unpartitioned-spec) equality
 *   deletes are applied; partition-scoped ones are refused (0A000) until
 *   partition handling lands (phase 5), since applying them globally would
 *   delete rows in other partitions.
 *
 * Only PARQUET files are read. Superuser / pg_read_server_files;
 * materialize-mode SRF.
 */
Datum
pgcolumnar_iceberg_scan(PG_FUNCTION_ARGS)
{
	char	   *path = text_to_cstring(PG_GETARG_TEXT_PP(0));
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	tupdesc;
	MemoryContext oldcxt;
	IceScanCtx	ctx;
	char	   *json;
	Jsonb	   *jb;
	int		   *field_ids;
	int			nfield;
	List	   *posdels;
	List	   *eqdels;
	ListCell   *lc;

	if (!has_privs_of_role(GetUserId(), ROLE_PG_READ_SERVER_FILES))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser or a member of the pg_read_server_files role to read a server file")));
	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo) ||
		(rsinfo->allowedModes & SFRM_Materialize) == 0)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in a context that cannot accept a set")));
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("pgcolumnar.iceberg_scan requires a column definition list"),
				 errhint("Call it as SELECT * FROM pgcolumnar.iceberg_scan(path) AS t(col1 type1, ...).")));

	/* map output column names -> field ids via the table's current schema */
	json = ice_slurp_text(path);
	jb = DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum(json)));
	field_ids = ice_field_ids_for_columns(&jb->root, tupdesc, path, &nfield);

	oldcxt = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);
	tupdesc = CreateTupleDescCopy(tupdesc);
	ctx.tupstore = tuplestore_begin_heap(true, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = ctx.tupstore;
	rsinfo->setDesc = tupdesc;
	MemoryContextSwitchTo(oldcxt);

	ctx.tupdesc = tupdesc;
	ctx.slot = MakeSingleTupleTableSlot(tupdesc, &TTSOpsVirtual);
	ctx.field_ids = field_ids;
	ctx.nfield = nfield;
	ctx.filectx = AllocSetContextCreate(CurrentMemoryContext,
										"pgcolumnar iceberg_scan file",
										ALLOCSET_DEFAULT_SIZES);
	ctx.recorded_root = NULL;
	ctx.actual_root = NULL;
	ctx.mdpath = NULL;
	ctx.data = NIL;
	ctx.posdel = NIL;
	ctx.eqdel = NIL;

	/* pass 1: collect the snapshot's data and delete entries (reuse the
	 * metadata already parsed for the schema, so the file is read once) */
	ice_walk_data_files(path, &jb->root, true, ice_scan_cb, &ctx);

	/* read the position-delete files once into (dpath, pos, seq) rows, and the
	 * applicable equality-delete files once into per-file delete-row sets
	 * (both kinds are snapshot-global; equality deletes are validated against
	 * the metadata -- equality_ids present, a present partition_spec_id naming
	 * an unpartitioned spec, mappable column types -- while a delete no data
	 * file is strictly older than is skipped as having no effect) */
	posdels = ice_read_pos_deletes(&ctx);
	{
		int64		min_data_seq = PG_INT64_MAX;

		foreach(lc, ctx.data)
			min_data_seq = Min(min_data_seq, ((IceEntry *) lfirst(lc))->seq);
		eqdels = ice_read_eq_deletes(&ctx, &jb->root, path, min_data_seq);
	}

	/* pass 2: read each data file, skipping the positions its deletes drop */
	foreach(lc, ctx.data)
	{
		IceEntry   *d = (IceEntry *) lfirst(lc);
		const char *dp = ice_strip_scheme(d->file_path);
		uint64	   *skip = NULL;
		int			nskip = 0;
		int			cap = 0;
		List	   *elig = NIL;
		int64		probe_rows = -1;
		int64		returned;
		char	   *safe;
		MemoryContext old;
		ListCell   *lc2;

		if (d->file_format != NULL && strcmp(d->file_format, "PARQUET") != 0)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("iceberg: data file \"%s\" has format %s; only PARQUET is supported",
							d->file_path, d->file_format)));

		/* gather the ordinals to drop: position deletes that target this file
		 * and whose data sequence number is >= the data file's. The spec rule is
		 * data_seq <= delete_seq (a position delete applies to data written in the
		 * same commit or earlier), so the comparison is >=, not > -- an equal
		 * sequence number (a single-commit upsert) still applies. Equality deletes,
		 * when added, use strict < instead. */
		foreach(lc2, posdels)
		{
			IcePosDel  *pd = (IcePosDel *) lfirst(lc2);

			if (pd->seq >= d->seq &&
				strcmp(ice_strip_scheme(pd->dpath), dp) == 0)
			{
				if (nskip == cap)
				{
					cap = cap ? cap * 2 : 16;
					skip = (skip == NULL)
						? (uint64 *) palloc(cap * sizeof(uint64))
						: (uint64 *) repalloc(skip, cap * sizeof(uint64));
				}
				skip[nskip++] = (uint64) pd->pos;
			}
		}

		/* equality deletes: STRICTLY newer than the data file only (spec rule
		 * data_seq < delete_seq -- the opposite boundary from position deletes;
		 * an equality delete never touches data from its own commit). Eligible
		 * files drive a probe pass over this data file's equality columns that
		 * appends the matching ordinals to the same skip set. */
		foreach(lc2, eqdels)
		{
			IceEqDel   *E = (IceEqDel *) lfirst(lc2);

			if (E->seq > d->seq)
				elig = lappend(elig, E);
		}
		if (elig != NIL)
			probe_rows = ice_eq_probe(&ctx, d, elig, &skip, &nskip, &cap);

		if (nskip > 1)			/* the reader wants the set sorted and unique */
		{
			int			w = 1;
			int			k;

			qsort(skip, nskip, sizeof(uint64), ice_cmp_u64);
			for (k = 1; k < nskip; k++)
				if (skip[k] != skip[w - 1])
					skip[w++] = skip[k];
			nskip = w;
		}

		/* resolve and read inside the per-file context so the opened path string
		 * and the reader's footer/metadata are reclaimed by the reset, not left
		 * to accumulate one-per-data-file across the scan */
		old = MemoryContextSwitchTo(ctx.filectx);
		safe = ice_open_path(ctx.recorded_root, ctx.actual_root, d->file_path,
							 "data-file", ctx.mdpath);
		returned = PgColumnarReadParquetByFieldId(safe, ctx.tupdesc, ctx.field_ids,
												  ctx.nfield, ctx.tupstore, ctx.slot,
												  skip, nskip);
		MemoryContextSwitchTo(old);
		MemoryContextReset(ctx.filectx);

		/* the probe and the full read walked the same file: the full read must
		 * return exactly the probe's row count minus the in-range skips, or the
		 * two passes disagreed on ordinals */
		if (probe_rows >= 0)
		{
			int64		expect = probe_rows;
			int			k;

			for (k = 0; k < nskip; k++)
				if (skip[k] < (uint64) probe_rows)
					expect--;
			if (returned != expect)
				ereport(ERROR,
						(errcode(ERRCODE_DATA_CORRUPTED),
						 errmsg("iceberg: data file \"%s\" returned " INT64_FORMAT " rows where " INT64_FORMAT " were expected after deletes",
								d->file_path, returned, expect)));
		}
		if (skip != NULL)
			pfree(skip);
		list_free(elig);
	}

	MemoryContextDelete(ctx.filectx);
	ExecDropSingleTupleTableSlot(ctx.slot);
	return (Datum) 0;
}
