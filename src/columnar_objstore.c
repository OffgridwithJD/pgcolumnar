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
#include "miscadmin.h"
#include <sys/stat.h>

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

/*
 * Is the module file actually there? Resolves $libdir the way the server does,
 * because the SQLSTATE cannot distinguish a missing library from a broken one.
 */
static bool
objstore_module_present(void)
{
	char		libdir[MAXPGPATH];
	char		path[MAXPGPATH];
	struct stat st;

	get_pkglib_path(my_exec_path, libdir);
	snprintf(path, sizeof(path), "%s/pgcolumnar_objstore%s", libdir, DLSUFFIX);
	return stat(path, &st) == 0;
}

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
	MemoryContext loadcxt;

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
	loadcxt = CurrentMemoryContext;
	init = NULL;
	PG_TRY();
	{
		init = (PgColumnarObjStoreInitFn)
			load_external_function("$libdir/pgcolumnar_objstore",
								   "pgcolumnar_objstore_init", false, NULL);
	}
	PG_CATCH();
	{
		MemoryContext ecxt = MemoryContextSwitchTo(loadcxt);

		/*
		 * "Not installed" and "installed but broken" are different situations and
		 * only the first is supported. Swallowing both reports a truncated
		 * library or a permission problem as an unsupported scheme, which sends
		 * the operator looking in the wrong place for a fault that is theirs.
		 *
		 * The SQLSTATE cannot tell them apart, which is the trap here and the
		 * reason the first attempt at this was wrong. internal_load_library uses
		 * errcode_for_file_access() for BOTH the stat failure and the dlopen
		 * failure, so a missing file and "file too short" both arrive as
		 * ERRCODE_UNDEFINED_FILE (58P01). Measured, not assumed.
		 *
		 * So ask the filesystem instead. Absent means not installed; present
		 * means the load failed for a reason the operator needs to see, and the
		 * original error is re-raised with its own message intact.
		 */
		if (objstore_module_present())
		{
			MemoryContextSwitchTo(ecxt);
			PG_RE_THROW();
		}

		MemoryContextSwitchTo(ecxt);
		FlushErrorState();
		init = NULL;
	}
	PG_END_TRY();

	/*
	 * The flag is set on each return path below, never once up here, and nothing
	 * that can raise sits between an assignment and its return.
	 *
	 * This is the same trap as the one above, one step later. init() is a call
	 * into a separately built library: it can raise, and if the flag were already
	 * set the unwind would leave the verdict cached as "tried, nothing found", so
	 * the first remote read of a session would report init()'s error and every
	 * later one would report "requires the object-store module" — the same two
	 * identical queries, two different errors, the plausible one second. It is
	 * latent while init() only returns a pointer to a static struct. It stops
	 * being latent the moment the module has anything to set up, which is the
	 * commit after this one.
	 */
	if (init == NULL)
	{
		objstore_tried = true;
		return NULL;
	}

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
		objstore_tried = true;
		return NULL;
	}

	objstore_api = api;
	objstore_tried = true;
	return objstore_api;
}
