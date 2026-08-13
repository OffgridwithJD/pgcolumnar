/*-------------------------------------------------------------------------
 * columnar_objstore.h
 *		The ABI between pgColumnar and its object-store module (#393).
 *
 * Object-store support lives in a SEPARATE, non-preloaded shared library. The
 * reason is measured rather than stylistic: pgColumnar loads through
 * shared_preload_libraries, so anything it links is mapped into the postmaster
 * and inherited by every backend through fork, whether or not any query ever
 * reads a remote file. libcurl alone resolves to 30 shared objects against this
 * extension's 4, including two TLS implementations, and an OpenSSL-linked client
 * brings a TLS stack into a postmaster that may have none.
 *
 * PostgreSQL made the same call for its own libcurl dependency: configure
 * default off, a separate shared library, runtime dlopen behind a frozen ABI,
 * and a separate distribution package. This follows that shape.
 *
 * The module is loaded with load_external_function on the first read of a remote
 * path and never before. A build or an install without it is fully functional for
 * local files.
 *
 * A missing module reports the remote path as unsupported. That needs a PG_TRY in
 * the loader and not just signalNotFound = false, because signalNotFound
 * suppresses a missing SYMBOL while a missing LIBRARY is raised earlier, by
 * internal_load_library, before the symbol lookup happens.
 *
 * VERSIONING. Bump PGCOLUMNAR_OBJSTORE_ABI whenever the meaning or the order of
 * anything below changes. The loader refuses a mismatch, because the failure it
 * prevents is a wrong function called through a stale pointer.
 *-------------------------------------------------------------------------
 */
#ifndef COLUMNAR_OBJSTORE_H
#define COLUMNAR_OBJSTORE_H

#include "postgres.h"

#define PGCOLUMNAR_OBJSTORE_ABI 2

/* An open remote object. The module owns everything behind this. */
typedef struct PgColumnarObjHandle PgColumnarObjHandle;

/*
 * Connection configuration resolved from the FDW catalogs (#393 M4). NULL
 * means "no catalog config": endpoint/region/credentials come from the
 * ambient environment, allowed - the function-API paths, which are gated by
 * pg_read_server_files and have no server object to hang a mapping on. A
 * non-NULL config with allow_ambient=false and no credential triple makes the
 * module refuse (SQLSTATE 28000) rather than fall back to the postmaster's
 * identity: ambient is a privilege, not a default.
 */
typedef struct PgColumnarObjStoreConfig
{
	const char *endpoint;		/* NULL: AWS_ENDPOINT_URL */
	const char *region;			/* NULL: AWS_REGION / AWS_DEFAULT_REGION */
	const char *akid;			/* credential triple; akid+secret together */
	const char *secret;
	const char *token;			/* optional session token */
	bool		allow_ambient;	/* may fall back to the environment */
} PgColumnarObjStoreConfig;

typedef struct PgColumnarObjStoreApi
{
	int			abi_version;	/* must equal PGCOLUMNAR_OBJSTORE_ABI */

	/*
	 * Does this module handle `url`? Called before open so the reader can report
	 * an unsupported scheme without a connection attempt.
	 */
	bool		(*handles_url) (const char *url);

	/*
	 * Open `url` and report its size. Raises on failure, like every other read
	 * path in this extension. `len` is required: the Parquet footer is located
	 * from the end of the object, so a source that cannot report a length cannot
	 * be read. `cfg` may be NULL (see PgColumnarObjStoreConfig).
	 */
	PgColumnarObjHandle *(*open) (const char *url,
								  const PgColumnarObjStoreConfig *cfg,
								  int64 *len);

	/*
	 * Read exactly `n` bytes at `off`. The caller has already bounded the range
	 * against the length reported by open. A short read is an error, not a
	 * partial success, because the reader has no way to make progress from one.
	 */
	void		(*read) (PgColumnarObjHandle *h, int64 off, void *buf, size_t n);

	void		(*close) (PgColumnarObjHandle *h);
} PgColumnarObjStoreApi;

/*
 * The module's single exported entry point. Returns a pointer to a static API
 * struct owned by the module.
 */
typedef const PgColumnarObjStoreApi *(*PgColumnarObjStoreInitFn) (void);

/*
 * Resolve the module, or return NULL when it is not installed. Cached after the
 * first call, including the negative result: a missing module is a property of
 * the installation and will not appear mid-session.
 */
extern const PgColumnarObjStoreApi *PgColumnarObjStoreGet(void);

/* Does `path` look like a remote URL at all? Cheap, no module load. */
extern bool PgColumnarPathIsRemote(const char *path);

#endif							/* COLUMNAR_OBJSTORE_H */
