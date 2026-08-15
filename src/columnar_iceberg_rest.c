/*-------------------------------------------------------------------------
 * columnar_iceberg_rest.c
 *		Read-only Apache Iceberg REST Catalog client (#388 phase 7).
 *
 * Resolves a table NAMED by a catalog (catalog URI + namespace + table) into
 * its current metadata location, which the reader (already remote-capable since
 * phase 6) then reads. This file owns only the REST protocol and its security
 * envelope; the HTTP(S) transport, TLS verification, the endpoint allow-list,
 * and the link-local/instance-metadata refusal all live in the object-store
 * module, reached through the ABI v5 http_request entry -- so no second TLS
 * stack enters the preloaded postmaster.
 *
 * Authentication is a static bearer token read from the SERVER PROCESS
 * ENVIRONMENT (PGCOLUMNAR_ICEBERG_REST_TOKEN), never a SQL argument: a token in
 * a function argument would land in pg_stat_activity and the statement log. The
 * per-catalog FOREIGN SERVER + USER MAPPING credential model, vended storage
 * credentials, and OAuth2 token exchange are tracked as #656.
 *
 * See design/ISSUE_388_PHASE7_REST_CATALOG.md.
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "catalog/pg_authid_d.h"
#include "catalog/pg_type_d.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/tuplestore.h"

#include "funcapi.h"
#include "columnar_iceberg.h"
#include "columnar_objstore.h"
#include "columnar_iceberg_rest.h"

/*
 * Set up a materialize-mode SRF returning a single text column, and return its
 * tuplestore. Used by the listing functions, which return SETOF text (a scalar
 * return type InitMaterializedSRF does not build a tupdesc for).
 */
static Tuplestorestate *
rest_text_srf_setup(ReturnSetInfo *rsinfo, TupleDesc *tdout)
{
	Tuplestorestate *ts;
	TupleDesc	td;
	MemoryContext oldcxt;

	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo) ||
		(rsinfo->allowedModes & SFRM_Materialize) == 0)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in a context that cannot accept a set")));

	oldcxt = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);
	td = CreateTemplateTupleDesc(1);
	TupleDescInitEntry(td, 1, "name", TEXTOID, -1, 0);
	ts = tuplestore_begin_heap(false, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = ts;
	rsinfo->setDesc = td;
	MemoryContextSwitchTo(oldcxt);
	*tdout = td;
	return ts;
}

/*
 * A catalog reply is small (a metadata-location plus, for now, an ignored inline
 * metadata document). 64 MiB matches the metadata-slurp cap and refuses a
 * hostile or runaway catalog before it can exhaust backend memory.
 */
#define REST_MAX_RESPONSE	((int64) 64 * 1024 * 1024)

/* The environment variable holding the static bearer token, or none. */
#define REST_TOKEN_ENV		"PGCOLUMNAR_ICEBERG_REST_TOKEN"

/* Resolve the object-store module, or raise: the REST client needs its HTTP. */
static const PgColumnarObjStoreApi *
rest_objstore(void)
{
	const PgColumnarObjStoreApi *api = PgColumnarObjStoreGet();

	if (api == NULL || api->http_request == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("iceberg: the object-store module is required for a REST catalog"),
				 errhint("Install the pgcolumnar_objstore module.")));
	return api;
}

/* Append `s` percent-encoded (RFC 3986 unreserved kept), for one path segment. */
static void
rest_pct_encode(StringInfo out, const char *s)
{
	static const char hex[] = "0123456789ABCDEF";
	const unsigned char *p;

	for (p = (const unsigned char *) s; *p != '\0'; p++)
	{
		unsigned char c = *p;

		if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') ||
			c == '-' || c == '.' || c == '_' || c == '~')
			appendStringInfoChar(out, (char) c);
		else
		{
			appendStringInfoChar(out, '%');
			appendStringInfoChar(out, hex[c >> 4]);
			appendStringInfoChar(out, hex[c & 0x0f]);
		}
	}
}

/*
 * Append a namespace to a resource path. The REST wire form joins multi-level
 * namespace parts with the unit separator 0x1F ("%1F" encoded); a caller passes
 * the levels dot-separated. Each level is percent-encoded, so a level bearing
 * '/', '.', or a control byte cannot alter the request path.
 */
static void
rest_append_namespace(StringInfo out, const char *ns)
{
	const char *start = ns;
	const char *p;

	for (p = ns;; p++)
	{
		if (*p == '.' || *p == '\0')
		{
			char	   *level = pnstrdup(start, p - start);

			rest_pct_encode(out, level);
			pfree(level);
			if (*p == '\0')
				break;
			appendStringInfoString(out, "%1F");
			start = p + 1;
		}
	}
}

/* Get a required string field from a jsonb object, or raise. */
static char *
rest_json_string(JsonbContainer *c, const char *key, const char *what)
{
	JsonbValue	vbuf;
	JsonbValue *v;

	if (c == NULL || !JsonContainerIsObject(c))
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the REST catalog %s is not a JSON object", what)));
	v = getKeyJsonValueFromContainer(c, key, (int) strlen(key), &vbuf);
	if (v == NULL || v->type != jbvString)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the REST catalog %s is missing the \"%s\" field",
						what, key)));
	return pnstrdup(v->val.string.val, v->val.string.len);
}

/* Optional string field: NULL when absent, raises only on a wrong type. */
static char *
rest_json_string_opt(JsonbContainer *c, const char *key)
{
	JsonbValue	vbuf;
	JsonbValue *v;

	if (c == NULL || !JsonContainerIsObject(c))
		return NULL;
	v = getKeyJsonValueFromContainer(c, key, (int) strlen(key), &vbuf);
	if (v == NULL || v->type != jbvString)
		return NULL;
	return pnstrdup(v->val.string.val, v->val.string.len);
}

/*
 * GET catalog_uri + resource_path, sending the bearer token when set. Maps the
 * transport-level statuses the catalog can return to clean SQLSTATEs; returns
 * the parsed JSON body of a 200 as a Jsonb, or raises. `what` labels errors.
 */
static Jsonb *
rest_get_json(const char *catalog_uri, const char *resource_path,
			  const char *what)
{
	const PgColumnarObjStoreApi *api = rest_objstore();
	const char *token = getenv(REST_TOKEN_ENV);
	StringInfoData url;
	const char *headers[2];
	int			nheaders = 0;
	char	   *authhdr = NULL;
	PgColumnarHttpResult r;
	Datum		jd;

	initStringInfo(&url);
	appendStringInfoString(&url, catalog_uri);
	/* one '/' between the base and the resource path */
	while (url.len > 0 && url.data[url.len - 1] == '/')
		url.data[--url.len] = '\0';
	appendStringInfoString(&url, resource_path);

	headers[nheaders++] = "Accept: application/json";
	if (token != NULL && token[0] != '\0')
	{
		authhdr = psprintf("Authorization: Bearer %s", token);
		headers[nheaders++] = authhdr;
	}

	r = api->http_request(url.data, "GET", headers, nheaders,
						  NULL, 0, REST_MAX_RESPONSE);
	if (authhdr != NULL)
		pfree(authhdr);

	if (r.status == 401 || r.status == 403)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_AUTHORIZATION_SPECIFICATION),
				 errmsg("iceberg: the REST catalog refused the request (HTTP %d)",
						r.status),
				 errhint("Set %s in the server environment, or check its value.",
						 REST_TOKEN_ENV)));
	if (r.status == 404)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_TABLE),
				 errmsg("iceberg: the REST catalog has no such %s (HTTP 404)", what)));
	if (r.status != 200)
		ereport(ERROR,
				(errcode(ERRCODE_PROTOCOL_VIOLATION),
				 errmsg("iceberg: the REST catalog returned HTTP %d for the %s",
						r.status, what)));
	if (r.body == NULL || r.body_len == 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the REST catalog returned an empty %s", what)));

	jd = DirectFunctionCall1(jsonb_in, CStringGetDatum(r.body));
	return DatumGetJsonbP(jd);
}

/*
 * Resolve the current metadata-location of catalog_uri's ns.table. Calls
 * GET /v1/config to learn any path prefix, then loadTable.
 */
char *
PgColumnarIcebergRestLoadTableLocation(const char *catalog_uri,
									   const char *ns, const char *table)
{
	Jsonb	   *cfg;
	char	   *prefix;
	Jsonb	   *lt;
	StringInfoData rp;
	char	   *loc;

	if (pg_strncasecmp(catalog_uri, "http://", 7) != 0 &&
		pg_strncasecmp(catalog_uri, "https://", 8) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("iceberg: a REST catalog URI must be http:// or https://")));

	/* config: {overrides, defaults}; a prefix, if any, is spliced after /v1/ */
	cfg = rest_get_json(catalog_uri, "/v1/config", "config");
	/*
	 * The config body is untrusted (a compromised or hostile allow-listed
	 * catalog). getKeyJsonValueFromContainer Asserts object-ness before its
	 * count<=0 early-out and then walks children as key/value pairs, so a
	 * non-object root ([], a scalar) is an assert crash on a debug build and an
	 * out-of-bounds read otherwise. Refuse it before any key lookup.
	 */
	if (!JsonContainerIsObject(&cfg->root))
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the REST catalog config response is not a JSON object")));
	prefix = rest_json_string_opt(&cfg->root, "prefix");
	if (prefix == NULL)
	{
		JsonbValue	vbuf;
		JsonbValue *ov = getKeyJsonValueFromContainer(&cfg->root, "overrides", 9,
													  &vbuf);

		if (ov != NULL && ov->type == jbvBinary)
			prefix = rest_json_string_opt(ov->val.binary.data, "prefix");
	}

	initStringInfo(&rp);
	appendStringInfoString(&rp, "/v1/");
	if (prefix != NULL && prefix[0] != '\0')
	{
		rest_pct_encode(&rp, prefix);
		appendStringInfoChar(&rp, '/');
	}
	appendStringInfoString(&rp, "namespaces/");
	rest_append_namespace(&rp, ns);
	appendStringInfoString(&rp, "/tables/");
	rest_pct_encode(&rp, table);

	lt = rest_get_json(catalog_uri, rp.data, "table");
	loc = rest_json_string(&lt->root, "metadata-location", "loadTable response");
	return loc;
}

PG_FUNCTION_INFO_V1(pgcolumnar_iceberg_rest_table_location);

/*
 * SQL: iceberg_rest_table_location(catalog_uri text, namespace text,
 * table_name text) RETURNS text. Superuser / pg_read_server_files, like every
 * other external read in this extension.
 */
Datum
pgcolumnar_iceberg_rest_table_location(PG_FUNCTION_ARGS)
{
	char	   *catalog_uri = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *ns = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char	   *table = text_to_cstring(PG_GETARG_TEXT_PP(2));
	char	   *loc;

	if (!has_privs_of_role(GetUserId(), ROLE_PG_READ_SERVER_FILES))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser or a member of the pg_read_server_files role to read a REST catalog")));

	loc = PgColumnarIcebergRestLoadTableLocation(catalog_uri, ns, table);
	PG_RETURN_TEXT_P(cstring_to_text(loc));
}

PG_FUNCTION_INFO_V1(pgcolumnar_iceberg_rest_scan);

/*
 * SQL: iceberg_rest_scan(catalog_uri, namespace, table_name) RETURNS SETOF
 * record. Resolve the table's current metadata-location through the catalog,
 * then read it through the very same path as iceberg_scan (a resolved remote
 * location reads because the reader is remote-capable). Superuser /
 * pg_read_server_files, materialize-mode SRF, column definition list required.
 */
Datum
pgcolumnar_iceberg_rest_scan(PG_FUNCTION_ARGS)
{
	char	   *catalog_uri = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *ns = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char	   *table = text_to_cstring(PG_GETARG_TEXT_PP(2));
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	tupdesc;
	char	   *loc;

	if (!has_privs_of_role(GetUserId(), ROLE_PG_READ_SERVER_FILES))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser or a member of the pg_read_server_files role to read a REST catalog")));
	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo) ||
		(rsinfo->allowedModes & SFRM_Materialize) == 0)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in a context that cannot accept a set")));
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("pgcolumnar.iceberg_rest_scan requires a column definition list"),
				 errhint("Call it as SELECT * FROM pgcolumnar.iceberg_rest_scan(uri, ns, tbl) AS t(col1 type1, ...).")));

	loc = PgColumnarIcebergRestLoadTableLocation(catalog_uri, ns, table);
	/*
	 * A metadata-location is a URI. The reader's remote path handles s3:// and
	 * http(s)://; a file:// location is a local path, and the local read path
	 * opens a bare filename, so strip the scheme here.
	 */
	if (pg_strncasecmp(loc, "file://", 7) == 0)
		loc += 7;
	PgColumnarIcebergScanInto(loc, tupdesc, rsinfo);
	return (Datum) 0;
}

PG_FUNCTION_INFO_V1(pgcolumnar_iceberg_rest_namespaces);

/*
 * SQL: iceberg_rest_namespaces(catalog_uri) RETURNS SETOF text. One row per
 * namespace; a multi-level namespace is dot-joined.
 */
Datum
pgcolumnar_iceberg_rest_namespaces(PG_FUNCTION_ARGS)
{
	char	   *catalog_uri = text_to_cstring(PG_GETARG_TEXT_PP(0));
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	Tuplestorestate *ts;
	TupleDesc	td;
	Jsonb	   *doc;
	JsonbValue	vbuf;
	JsonbValue *nsv;
	uint32		n;
	uint32		i;

	if (!has_privs_of_role(GetUserId(), ROLE_PG_READ_SERVER_FILES))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser or a member of the pg_read_server_files role to read a REST catalog")));
	ts = rest_text_srf_setup(rsinfo, &td);

	doc = rest_get_json(catalog_uri, "/v1/namespaces", "namespaces");
	if (!JsonContainerIsObject(&doc->root))
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the REST catalog namespaces response is not a JSON object")));
	nsv = getKeyJsonValueFromContainer(&doc->root, "namespaces", 10, &vbuf);
	if (nsv == NULL || nsv->type != jbvBinary ||
		!JsonContainerIsArray(nsv->val.binary.data))
		return (Datum) 0;		/* no namespaces */

	/* each element is itself an array of level strings; dot-join them */
	n = JsonContainerSize(nsv->val.binary.data);
	for (i = 0; i < n; i++)
	{
		JsonbValue *lv = getIthJsonbValueFromContainer(nsv->val.binary.data, i);
		StringInfoData name;
		uint32		nlev;
		uint32		j;
		Datum		values[1];
		bool		nulls[1] = {false};

		if (lv == NULL || lv->type != jbvBinary ||
			!JsonContainerIsArray(lv->val.binary.data))
			continue;
		initStringInfo(&name);
		nlev = JsonContainerSize(lv->val.binary.data);
		for (j = 0; j < nlev; j++)
		{
			JsonbValue *pv = getIthJsonbValueFromContainer(lv->val.binary.data, j);

			if (pv == NULL || pv->type != jbvString)
				continue;
			if (name.len > 0)
				appendStringInfoChar(&name, '.');
			appendBinaryStringInfo(&name, pv->val.string.val, pv->val.string.len);
		}
		values[0] = PointerGetDatum(cstring_to_text_with_len(name.data, name.len));
		tuplestore_putvalues(ts, td, values, nulls);
		pfree(name.data);
	}
	return (Datum) 0;
}

PG_FUNCTION_INFO_V1(pgcolumnar_iceberg_rest_tables);

/*
 * SQL: iceberg_rest_tables(catalog_uri, namespace) RETURNS SETOF text. One row
 * per table name in the namespace.
 */
Datum
pgcolumnar_iceberg_rest_tables(PG_FUNCTION_ARGS)
{
	char	   *catalog_uri = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *ns = text_to_cstring(PG_GETARG_TEXT_PP(1));
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	Tuplestorestate *ts;
	TupleDesc	td;
	StringInfoData rp;
	Jsonb	   *doc;
	JsonbValue	vbuf;
	JsonbValue *idv;
	uint32		n;
	uint32		i;

	if (!has_privs_of_role(GetUserId(), ROLE_PG_READ_SERVER_FILES))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser or a member of the pg_read_server_files role to read a REST catalog")));
	ts = rest_text_srf_setup(rsinfo, &td);

	initStringInfo(&rp);
	appendStringInfoString(&rp, "/v1/namespaces/");
	rest_append_namespace(&rp, ns);
	appendStringInfoString(&rp, "/tables");
	doc = rest_get_json(catalog_uri, rp.data, "table list");
	if (!JsonContainerIsObject(&doc->root))
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the REST catalog table-list response is not a JSON object")));
	idv = getKeyJsonValueFromContainer(&doc->root, "identifiers", 11, &vbuf);
	if (idv == NULL || idv->type != jbvBinary ||
		!JsonContainerIsArray(idv->val.binary.data))
		return (Datum) 0;		/* no tables */

	n = JsonContainerSize(idv->val.binary.data);
	for (i = 0; i < n; i++)
	{
		JsonbValue *e = getIthJsonbValueFromContainer(idv->val.binary.data, i);
		JsonbValue	nbuf;
		JsonbValue *nm;
		Datum		values[1];
		bool		nulls[1] = {false};

		if (e == NULL || e->type != jbvBinary ||
			!JsonContainerIsObject(e->val.binary.data))
			continue;
		nm = getKeyJsonValueFromContainer(e->val.binary.data, "name", 4, &nbuf);
		if (nm == NULL || nm->type != jbvString)
			continue;
		values[0] = PointerGetDatum(cstring_to_text_with_len(nm->val.string.val,
															 nm->val.string.len));
		tuplestore_putvalues(ts, td, values, nulls);
	}
	return (Datum) 0;
}
