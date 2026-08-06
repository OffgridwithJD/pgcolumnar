/*-------------------------------------------------------------------------
 * columnar_objstore.c
 *		Loader for the object-store module (#393).
 *
 * The module is a separate, non-preloaded shared library. See
 * columnar_objstore.h for why. This file is the only thing in the main library
 * that knows it exists, and it never loads it until a remote path is read.
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "fmgr.h"
#include "utils/elog.h"

#include "columnar.h"
#include "columnar_objstore.h"

/*
 * Cached across the session, INCLUDING the negative result. Whether the module is
 * installed is a property of the installation, so a miss will not become a hit
 * mid-session, and retrying a dlopen per read would be a per-read cost for
 * something that cannot change.
 */
static const PgColumnarObjStoreApi *objstore_api = NULL;
static bool objstore_tried = false;

bool
PgColumnarPathIsRemote(const char *path)
{
	static const char *const schemes[] = {"s3://", "gs://", "az://", "https://",
	"http://", NULL};
	int			i;

	if (path == NULL)
		return false;
	for (i = 0; schemes[i] != NULL; i++)
		if (pg_strncasecmp(path, schemes[i], strlen(schemes[i])) == 0)
			return true;
	return false;
}

const PgColumnarObjStoreApi *
PgColumnarObjStoreGet(void)
{
	PgColumnarObjStoreInitFn init;
	const PgColumnarObjStoreApi *api;

	if (objstore_tried)
		return objstore_api;

	/*
	 * signalNotFound = false suppresses a missing SYMBOL. It does NOT suppress a
	 * missing LIBRARY: internal_load_library raises before the symbol lookup
	 * happens, so that argument never gets a say and the caller sees
	 * 'could not access file "pgcolumnar_objstore"'. An installation without the
	 * module is a supported configuration, not an error, so catch it.
	 *
	 * Only the load is inside the PG_TRY, so nothing else is swallowed.
	 *
	 * objstore_tried is set AFTER the attempt, not before. Setting it first looks
	 * equivalent and is not: the ereport unwinds past the assignment while the
	 * static keeps its new value, so the FIRST remote read of a session reported
	 * the raw load failure and every later one reported the documented message.
	 * Two identical queries in one session gave two different errors, and the
	 * second was the plausible-looking one.
	 */
	init = NULL;
	PG_TRY();
	{
		init = (PgColumnarObjStoreInitFn)
			load_external_function("$libdir/pgcolumnar_objstore",
								   "pgcolumnar_objstore_init", false, NULL);
	}
	PG_CATCH();
	{
		FlushErrorState();
		init = NULL;
	}
	PG_END_TRY();

	objstore_tried = true;
	if (init == NULL)
		return NULL;

	api = init();

	/*
	 * Refuse a mismatch rather than calling through it. A stale module and a new
	 * main library agree on the symbol name and disagree on the struct, and the
	 * failure that produces is a wrong function through a valid-looking pointer.
	 */
	if (api == NULL || api->abi_version != PGCOLUMNAR_OBJSTORE_ABI)
	{
		ereport(WARNING,
				(errmsg("columnar: ignoring object-store module with ABI version %d",
						api ? api->abi_version : -1),
				 errdetail("This build expects ABI version %d.",
						   PGCOLUMNAR_OBJSTORE_ABI),
				 errhint("Reinstall pgcolumnar_objstore from the same build as "
						 "pgcolumnar.")));
		return NULL;
	}

	objstore_api = api;
	return objstore_api;
}
