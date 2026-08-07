/*-------------------------------------------------------------------------
 * columnar_objstore_module.c
 *		Object-store byte source for pgColumnar (#393).
 *
 * Loaded on demand by PgColumnarObjStoreGet, never preloaded. See
 * src/columnar_objstore.h for why it is a separate library and for the ABI.
 *
 * This commit establishes the module, its build, and the ABI. The protocol
 * itself arrives next: a range GET over HTTP/1.1 driven from a WaitEventSet, then
 * SigV4 signing, then TLS. Until then every scheme reports unsupported, which is
 * a better failure than the reader silently treating an s3:// URL as a filename.
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "fmgr.h"
#include "columnar_objstore.h"

PG_MODULE_MAGIC;

PGDLLEXPORT const PgColumnarObjStoreApi *pgcolumnar_objstore_init(void);

static bool
objstore_handles_url(const char *url)
{
	/*
	 * Nothing is handled yet. Deliberately not returning true for s3:// before
	 * the protocol exists: the reader asks this question so it can report an
	 * unsupported scheme without attempting a connection, and answering yes here
	 * would turn a clear error into a failure inside open().
	 */
	(void) url;
	return false;
}

static PgColumnarObjHandle *
objstore_open(const char *url, int64 *len)
{
	(void) len;
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("columnar: object storage is not implemented yet"),
			 errdetail("The object-store module is installed but carries no "
					   "protocol implementation for \"%s\".", url)));
	return NULL;				/* unreachable */
}

static void
objstore_read(PgColumnarObjHandle *h, int64 off, void *buf, size_t n)
{
	(void) h; (void) off; (void) buf; (void) n;
	elog(ERROR, "columnar: object-store read reached an unopened handle");
}

static void
objstore_close(PgColumnarObjHandle *h)
{
	(void) h;
}

static const PgColumnarObjStoreApi objstore_api = {
	.abi_version = PGCOLUMNAR_OBJSTORE_ABI,
	.handles_url = objstore_handles_url,
	.open = objstore_open,
	.read = objstore_read,
	.close = objstore_close,
};

const PgColumnarObjStoreApi *
pgcolumnar_objstore_init(void)
{
	return &objstore_api;
}
