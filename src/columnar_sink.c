/*-------------------------------------------------------------------------
 * columnar_sink.c
 *		Local byte sink for the export writers (#394 step 1).
 *
 * Fixes the two defects the write-path mapping found (PR #604): all 17 fwrite
 * sites ignored their return values (a disk-full mid-export was detected only
 * if the final flush failed), and serial exports wrote directly to the final
 * path, leaving a partial file there on error. Every write is checked here,
 * at the call; the bytes go to <path>.tmp.<pid>; and the final name appears
 * only through finish()'s durable rename, so a reader never sees a partial
 * file under the name it trusts - the same appears-whole-or-not-at-all
 * property the future remote sink gets from multipart completion.
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <unistd.h>

#include "miscadmin.h"
#include "storage/fd.h"

#include "columnar_objstore.h"
#include "columnar_sink.h"

int			pgcolumnar_sink_fail_after = -1;	/* dev injection; see header */

struct PqSink
{
	/* local */
	FILE	   *f;
	char	   *finalPath;
	char	   *tmpPath;
	int64		written;
	/* remote (#394): NULL api => local sink */
	const PgColumnarObjStoreApi *api;
	PgColumnarObjSink *rsink;
};

PqSink *
PgColumnarSinkOpenLocal(const char *path)
{
	PqSink	   *snk = (PqSink *) palloc0(sizeof(PqSink));

	snk->finalPath = pstrdup(path);
	snk->tmpPath = psprintf("%s.tmp.%d", path, MyProcPid);
	snk->f = AllocateFile(snk->tmpPath, PG_BINARY_W);
	if (snk->f == NULL)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\" for writing: %m",
						snk->tmpPath)));
	return snk;
}

/*
 * The seam the exporters call (#394): a local path keeps step 1's
 * temp-and-rename exactly; a remote URL routes through the object-store
 * module, which is loaded on first use and gives the SAME
 * nothing-visible-before-finish property from multipart completion.
 */
PqSink *
PgColumnarSinkOpen(const char *path)
{
	if (PgColumnarPathIsRemote(path))
	{
		const PgColumnarObjStoreApi *api = PgColumnarObjStoreGet();
		PqSink	   *snk;

		if (api == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("columnar: writing \"%s\" requires the object-store module",
							path),
					 errdetail("Object storage support is a separate library, "
							   "pgcolumnar_objstore, which is not installed.")));
		if (!api->handles_url(path))
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("columnar: writing \"%s\" is not supported", path),
					 errdetail("The installed object-store module handles no "
							   "such URL scheme.")));
		snk = (PqSink *) palloc0(sizeof(PqSink));
		snk->finalPath = pstrdup(path);
		snk->api = api;
		snk->rsink = api->sink_create(path, NULL);
		return snk;
	}
	return PgColumnarSinkOpenLocal(path);
}

void
PgColumnarSinkWrite(PqSink *snk, const void *buf, size_t n)
{
	size_t		wrote;

	if (n == 0)
		return;

	/*
	 * Fault injection (dev) is shared: it fails the SAME way for both sinks,
	 * so the remote abort path is exercised by the same GUC the local one is.
	 */
	if (pgcolumnar_sink_fail_after >= 0 &&
		snk->written + (int64) n > (int64) pgcolumnar_sink_fail_after)
		ereport(ERROR,
				(errcode(ERRCODE_DISK_FULL),
				 errmsg("columnar: export write failed (injected fault)"),
				 errdetail("The export had written %lld bytes.",
						   (long long) snk->written)));

	if (snk->api != NULL)
		snk->api->sink_write(snk->rsink, buf, n);
	else
	{
		wrote = fwrite(buf, 1, n, snk->f);
		if (wrote != n)
		{
			/*
			 * A short fwrite leaves the real cause in errno via the stream
			 * error; a clean short count with no error is still a failed
			 * write, reported as the device-full condition it usually is.
			 */
			if (errno == 0)
				errno = ENOSPC;
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not write to \"%s\": %m", snk->tmpPath),
					 errdetail("The export had written %lld bytes.",
							   (long long) snk->written)));
		}
	}
	snk->written += (int64) n;
}

void
PgColumnarSinkFinish(PqSink *snk)
{
	FILE	   *f;

	if (snk->api != NULL)
	{
		snk->api->sink_finish(snk->rsink);
		snk->rsink = NULL;
		return;
	}
	f = snk->f;
	snk->f = NULL;
	if (fflush(f) != 0 || pg_fsync(fileno(f)) != 0)
	{
		int			save_errno = errno;

		FreeFile(f);
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not flush \"%s\": %m", snk->tmpPath)));
	}
	if (FreeFile(f) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not write file \"%s\": %m", snk->tmpPath)));

	/* fsyncs the new name and its directory; raises on failure */
	durable_rename(snk->tmpPath, snk->finalPath, ERROR);
}

void
PgColumnarSinkAbort(PqSink *snk)
{
	if (snk == NULL)
		return;
	if (snk->api != NULL)
	{
		if (snk->rsink != NULL)
		{
			snk->api->sink_abort(snk->rsink);
			snk->rsink = NULL;
		}
		return;
	}
	if (snk->f != NULL)
	{
		FreeFile(snk->f);
		snk->f = NULL;
	}
	(void) unlink(snk->tmpPath);
}
