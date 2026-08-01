/*-------------------------------------------------------------------------
 *
 * columnar_parallel_copy.c
 *		Parallel bulk ingest for pgColumnar (#300).
 *
 * Splits a load across background workers, each running core COPY over a
 * line-aligned byte range of the input file, so parse semantics stay exactly
 * core COPY's. See design/PARALLEL_COPY_PLAN.md.
 *
 * Phase 1 (this commit): the file range splitter. Given a server-side file and a
 * worker count N, return N+1 byte offsets that partition the file into N ranges,
 * each ending exactly on a record boundary, without rewriting the file. The
 * coordinator hands range [off[i], off[i+1]) to worker i. Text format only for
 * now: a raw newline is always a record boundary because text format escapes any
 * embedded newline (CSV quote-aware splitting is a later phase; see the plan).
 *
 * Independent MIT implementation. References only the public PostgreSQL API
 * (server-file access in storage/fd.h, the role check used by COPY FROM file, and
 * array construction). No core/TimescaleDB/Citus/DuckDB source consulted.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <fcntl.h>
#include <unistd.h>

#include "catalog/pg_authid_d.h"
#include "catalog/pg_type.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "storage/fd.h"
#include "utils/acl.h"
#include "utils/array.h"
#include "utils/builtins.h"

/* how much we read at a time while scanning forward to the next newline */
#define COLUMNAR_SPLIT_SCAN_CHUNK 65536

PG_FUNCTION_INFO_V1(columnar_file_split_offsets);

/*
 * columnar_file_split_offsets(path text, workers int) -> bigint[]
 *
 * Returns workers+1 ascending byte offsets [0 .. filesize] that split the file
 * into `workers` line-aligned ranges. off[0] is always 0 and off[workers] is
 * always the file size; each interior boundary is placed at the first byte after
 * the newline that follows the even split point filesize*i/workers, so no record
 * is ever split across two ranges. Ranges may be empty (equal consecutive
 * offsets) when the file has fewer records than workers -- that worker then loads
 * nothing, which is harmless.
 */
Datum
columnar_file_split_offsets(PG_FUNCTION_ARGS)
{
	char	   *path;
	int32		workers;
	int			fd;
	off_t		size;
	int64	   *offs;
	Datum	   *elems;
	ArrayType  *result;
	char	   *buf;
	int			i;

	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("path and workers must not be null")));

	path = text_to_cstring(PG_GETARG_TEXT_PP(0));
	workers = PG_GETARG_INT32(1);

	if (workers < 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("workers must be at least 1")));

	/*
	 * Reading a server-side file is the same privilege COPY FROM file requires:
	 * membership in pg_read_server_files (which superusers hold). Enforce it here
	 * so the splitter cannot be used to probe arbitrary files without it.
	 */
	if (!has_privs_of_role(GetUserId(), ROLE_PG_READ_SERVER_FILES))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser or a member of the pg_read_server_files role to split a server file"),
				 errhint("Anyone can COPY from a file if they are a member of the "
						 "pg_read_server_files role.")));

	fd = OpenTransientFile(path, O_RDONLY | PG_BINARY);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\" for reading: %m", path)));

	size = lseek(fd, 0, SEEK_END);
	if (size < 0)
	{
		int			save_errno = errno;

		CloseTransientFile(fd);
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not seek in file \"%s\": %m", path)));
	}

	offs = (int64 *) palloc(sizeof(int64) * (workers + 1));
	offs[0] = 0;
	offs[workers] = (int64) size;
	buf = (char *) palloc(COLUMNAR_SPLIT_SCAN_CHUNK);

	for (i = 1; i < workers; i++)
	{
		int64		target = (int64) ((double) size * i / workers);
		int64		pos;
		bool		found = false;

		/* never place a boundary before the previous one */
		if (target < offs[i - 1])
			target = offs[i - 1];
		if (target >= size)
		{
			offs[i] = size;
			continue;
		}

		/* scan forward from the split point to the first byte after a newline */
		pos = target;
		while (pos < size && !found)
		{
			int			want = (int) Min((int64) COLUMNAR_SPLIT_SCAN_CHUNK,
										 size - pos);
			int			got;
			int			j;

			if (lseek(fd, (off_t) pos, SEEK_SET) < 0)
			{
				int			save_errno = errno;

				CloseTransientFile(fd);
				errno = save_errno;
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not seek in file \"%s\": %m", path)));
			}
			got = (int) read(fd, buf, want);
			if (got < 0)
			{
				int			save_errno = errno;

				CloseTransientFile(fd);
				errno = save_errno;
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not read file \"%s\": %m", path)));
			}
			if (got == 0)
				break;			/* EOF without a newline: range runs to EOF */

			for (j = 0; j < got; j++)
			{
				if (buf[j] == '\n')
				{
					offs[i] = pos + j + 1;	/* first byte of the next record */
					found = true;
					break;
				}
			}
			pos += got;
		}

		/* no newline between the split point and EOF: this range extends to EOF */
		if (!found)
			offs[i] = size;

		/* keep the sequence non-decreasing and bounded by the file size */
		if (offs[i] < offs[i - 1])
			offs[i] = offs[i - 1];
		if (offs[i] > size)
			offs[i] = size;
	}

	CloseTransientFile(fd);
	pfree(buf);

	elems = (Datum *) palloc(sizeof(Datum) * (workers + 1));
	for (i = 0; i <= workers; i++)
		elems[i] = Int64GetDatum(offs[i]);

	result = construct_array(elems, workers + 1, INT8OID,
							 sizeof(int64), FLOAT8PASSBYVAL, TYPALIGN_DOUBLE);

	PG_RETURN_ARRAYTYPE_P(result);
}
