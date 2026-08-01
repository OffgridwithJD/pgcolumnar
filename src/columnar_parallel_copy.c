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

#include "columnar.h"

#include "access/relation.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/pg_authid_d.h"
#include "catalog/pg_type.h"
#include "commands/copy.h"
#include "fmgr.h"
#include "funcapi.h"
#include "libpq/pqsignal.h"
#include "access/sysattr.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/value.h"
#include "parser/parse_node.h"
#include "parser/parse_relation.h"
#include "postmaster/bgworker.h"
#include "storage/dsm.h"
#include "storage/fd.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/shm_toc.h"
#include "storage/shmem.h"
#include "tcop/tcopprot.h"
#include "utils/acl.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/rel.h"

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

/* -------------------------------------------------------------------------
 * Parallel bulk ingest coordinator + background worker (#300, phase 2).
 *
 * The coordinator (the backend running pgcolumnar.parallel_copy) computes the
 * line-aligned byte ranges, lays out one DSM segment (a control header + a
 * per-worker slot array), launches N dynamic background workers, waits for them,
 * and reports the total rows. Each worker attaches the segment, connects, and
 * runs core COPY over its byte range via BeginCopyFrom with a bounded data
 * source, so parse and write semantics are exactly core COPY's. Workers report
 * success/failure through a shared status word (background-worker shutdown status
 * alone cannot tell success from crash).
 *
 * This slice loads each range in its own committed transaction; the all-or-nothing
 * (2PC) and staging modes follow, per design/PARALLEL_COPY_PLAN.md.
 * ------------------------------------------------------------------------- */

#define PCOPY_MAGIC			0x50434f50	/* 'PCOP' */
#define PCOPY_KEY_HEADER	0
#define PCOPY_KEY_WORKERS	1
#define PCOPY_DEFAULT_WORKERS	8
#define PCOPY_MAX_WORKERS	1024

typedef enum PcopyState
{
	PCOPY_PENDING = 0,			/* not yet finished (also: worker crashed) */
	PCOPY_DONE,					/* range loaded and committed */
	PCOPY_FAILED				/* worker caught an error; see errmsg */
} PcopyState;

typedef struct PcopyWorkerSlot
{
	int64		start_off;		/* byte range [start_off, end_off) for this worker */
	int64		end_off;
	pg_atomic_uint32 state;		/* PcopyState */
	int64		rows;			/* rows loaded (valid when state == PCOPY_DONE) */
	int			sqlerrcode;
	char		errmsg[512];
} PcopyWorkerSlot;

typedef struct PcopyHeader
{
	Oid			dbid;
	Oid			roleid;
	Oid			relid;			/* target relation */
	int			nworkers;
	char		filename[MAXPGPATH];
} PcopyHeader;

/*
 * The COPY data-source callback has no context argument, and a worker runs one
 * COPY at a time, so the bounded range lives in this per-process static. It hands
 * COPY only the bytes in the worker's range and reports EOF at the range end.
 */
typedef struct PcopyRangeSource
{
	int			fd;
	int64		remaining;
	const char *path;
} PcopyRangeSource;

static PcopyRangeSource pcopy_src = {-1, 0, NULL};

/* background-worker entry point, resolved via bgw_function_name */
PGDLLEXPORT void pgcolumnar_parallel_copy_worker(Datum main_arg);

static int
pcopy_range_read(void *outbuf, int minread, int maxread)
{
	int			total = 0;

	(void) minread;				/* we return up to maxread; COPY re-calls as needed */
	while (total < maxread && pcopy_src.remaining > 0)
	{
		int			want = (int) Min((int64) (maxread - total), pcopy_src.remaining);
		int			got = (int) read(pcopy_src.fd, (char *) outbuf + total, want);

		if (got < 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not read file \"%s\": %m",
							pcopy_src.path ? pcopy_src.path : "")));
		if (got == 0)
			break;				/* unexpected EOF inside the range */
		total += got;
		pcopy_src.remaining -= got;
	}
	return total;
}

/*
 * pcopy_compute_offsets
 *		Line-aligned byte offsets partitioning `path` into `workers` ranges, the
 *		same computation columnar_file_split_offsets exposes to SQL, for the
 *		coordinator's internal use. Returns a palloc'd int64[workers+1].
 */
static int64 *
pcopy_compute_offsets(const char *path, int workers)
{
	int			fd;
	off_t		size;
	int64	   *offs;
	char	   *buf;
	int			i;

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

		if (target < offs[i - 1])
			target = offs[i - 1];
		if (target >= size)
		{
			offs[i] = size;
			continue;
		}
		pos = target;
		while (pos < size && !found)
		{
			int			want = (int) Min((int64) COLUMNAR_SPLIT_SCAN_CHUNK, size - pos);
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
				break;
			for (j = 0; j < got; j++)
			{
				if (buf[j] == '\n')
				{
					offs[i] = pos + j + 1;
					found = true;
					break;
				}
			}
			pos += got;
		}
		if (!found)
			offs[i] = size;
		if (offs[i] < offs[i - 1])
			offs[i] = offs[i - 1];
		if (offs[i] > size)
			offs[i] = size;
	}

	CloseTransientFile(fd);
	pfree(buf);
	return offs;
}

/*
 * pgcolumnar_parallel_copy_worker
 *		Background-worker entry: attach the DSM, connect, and run core COPY over
 *		this worker's byte range into the target, committing that range. Success or
 *		failure is reported through the shared slot's state word before exit.
 */
PGDLLEXPORT void
pgcolumnar_parallel_copy_worker(Datum main_arg)
{
	dsm_segment *seg;
	shm_toc    *toc;
	PcopyHeader *hdr;
	PcopyWorkerSlot *slots;
	PcopyWorkerSlot *me;
	int			widx;
	uint32		conn_flags = BGWORKER_BYPASS_ALLOWCONN;

	memcpy(&widx, MyBgworkerEntry->bgw_extra, sizeof(int));

	pqsignal(SIGTERM, die);
	BackgroundWorkerUnblockSignals();

	seg = dsm_attach(DatumGetUInt32(main_arg));
	if (seg == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("pgcolumnar parallel_copy worker could not attach to the shared segment")));
	toc = shm_toc_attach(PCOPY_MAGIC, dsm_segment_address(seg));
	if (toc == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("pgcolumnar parallel_copy worker found a bad shared segment")));
	hdr = (PcopyHeader *) shm_toc_lookup(toc, PCOPY_KEY_HEADER, false);
	slots = (PcopyWorkerSlot *) shm_toc_lookup(toc, PCOPY_KEY_WORKERS, false);
	me = &slots[widx];

#if PG_VERSION_NUM >= 160000
	conn_flags |= BGWORKER_BYPASS_ROLELOGINCHECK;
#endif
	BackgroundWorkerInitializeConnectionByOid(hdr->dbid, hdr->roleid, conn_flags);

	PG_TRY();
	{
		Relation	rel;
		ParseState *pstate;
		List	   *options;
		CopyFromState cstate;
		uint64		processed;
		int			fd;

		StartTransactionCommand();

		fd = OpenTransientFile(hdr->filename, O_RDONLY | PG_BINARY);
		if (fd < 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not open file \"%s\" for reading: %m", hdr->filename)));
		if (lseek(fd, (off_t) me->start_off, SEEK_SET) < 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not seek in file \"%s\": %m", hdr->filename)));
		pcopy_src.fd = fd;
		pcopy_src.remaining = me->end_off - me->start_off;
		pcopy_src.path = hdr->filename;

		rel = table_open(hdr->relid, RowExclusiveLock);
		pstate = make_parsestate(NULL);
		pstate->p_sourcetext = "(pgcolumnar parallel_copy)";

		/*
		 * BeginCopyFrom/CopyFrom expect the target in the ParseState's range
		 * table (with INSERT permission recorded), exactly as core's DoCopy sets
		 * up before a COPY FROM. PG16 moved permission info out of RangeTblEntry
		 * into a separate RTEPermissionInfo, so guard that.
		 */
		{
			TupleDesc	td = RelationGetDescr(rel);
			int			an;
#if PG_VERSION_NUM >= 160000
			ParseNamespaceItem *nsitem =
				addRangeTableEntryForRelation(pstate, rel, RowExclusiveLock,
											  NULL, false, false);
			RTEPermissionInfo *perminfo = nsitem->p_perminfo;

			perminfo->requiredPerms = ACL_INSERT;
			for (an = 1; an <= td->natts; an++)
				if (!TupleDescAttr(td, an - 1)->attisdropped)
					perminfo->insertedCols =
						bms_add_member(perminfo->insertedCols,
									   an - FirstLowInvalidHeapAttributeNumber);
#else
			RangeTblEntry *rte =
				addRangeTableEntryForRelation(pstate, rel, RowExclusiveLock,
											  NULL, false, false);

			rte->requiredPerms = ACL_INSERT;
			for (an = 1; an <= td->natts; an++)
				if (!TupleDescAttr(td, an - 1)->attisdropped)
					rte->insertedCols =
						bms_add_member(rte->insertedCols,
									   an - FirstLowInvalidHeapAttributeNumber);
#endif
		}

		options = list_make1(makeDefElem("format",
										 (Node *) makeString("text"), -1));
		cstate = BeginCopyFrom(pstate, rel, NULL, NULL, false,
							   pcopy_range_read, NIL, options);
		processed = CopyFrom(cstate);
		EndCopyFrom(cstate);
		free_parsestate(pstate);
		table_close(rel, NoLock);
		CloseTransientFile(fd);
		pcopy_src.fd = -1;

		CommitTransactionCommand();

		me->rows = (int64) processed;
		pg_atomic_write_u32(&me->state, PCOPY_DONE);
	}
	PG_CATCH();
	{
		ErrorData  *edata;
		MemoryContext ecxt;

		ecxt = MemoryContextSwitchTo(TopMemoryContext);
		edata = CopyErrorData();
		me->sqlerrcode = edata->sqlerrcode;
		strlcpy(me->errmsg,
				edata->message ? edata->message : "unknown error",
				sizeof(me->errmsg));
		MemoryContextSwitchTo(ecxt);
		FlushErrorState();
		AbortOutOfAnyTransaction();
		if (pcopy_src.fd >= 0)
		{
			CloseTransientFile(pcopy_src.fd);
			pcopy_src.fd = -1;
		}
		pg_atomic_write_u32(&me->state, PCOPY_FAILED);
	}
	PG_END_TRY();

	dsm_detach(seg);
	proc_exit(0);
}

PG_FUNCTION_INFO_V1(columnar_parallel_copy);

/*
 * columnar_parallel_copy(target regclass, filename text, workers int)
 *		-> rows loaded.
 */
Datum
columnar_parallel_copy(PG_FUNCTION_ARGS)
{
	Oid			relid;
	char	   *path;
	int			workers;
	int64	   *offs;
	shm_toc_estimator est;
	Size		segsize;
	dsm_segment *seg;
	shm_toc    *toc;
	PcopyHeader *hdr;
	PcopyWorkerSlot *slots;
	BackgroundWorker bw;
	BackgroundWorkerHandle **handles;
	int64		total = 0;
	int			failed = -1;
	int			i;

	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("target and filename must not be null")));

	relid = PG_GETARG_OID(0);
	path = text_to_cstring(PG_GETARG_TEXT_PP(1));
	workers = PG_ARGISNULL(2) ? PCOPY_DEFAULT_WORKERS : PG_GETARG_INT32(2);

	if (!has_privs_of_role(GetUserId(), ROLE_PG_READ_SERVER_FILES))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser or a member of the pg_read_server_files role to run pgcolumnar.parallel_copy")));

	if (workers < 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("workers must be at least 1")));
	if (workers > PCOPY_MAX_WORKERS)
		workers = PCOPY_MAX_WORKERS;

	/* validate the target is a columnar relation before spawning anything */
	{
		Relation	rel = table_open(relid, AccessShareLock);

		if (!ColumnarIsColumnarRelation(relid))
		{
			table_close(rel, AccessShareLock);
			ereport(ERROR,
					(errcode(ERRCODE_WRONG_OBJECT_TYPE),
					 errmsg("\"%s\" is not a pgcolumnar table",
							RelationGetRelationName(rel))));
		}
		table_close(rel, AccessShareLock);
	}

	offs = pcopy_compute_offsets(path, workers);

	/* lay out one DSM segment: control header + per-worker slot array */
	shm_toc_initialize_estimator(&est);
	shm_toc_estimate_chunk(&est, sizeof(PcopyHeader));
	shm_toc_estimate_chunk(&est, mul_size(sizeof(PcopyWorkerSlot), workers));
	shm_toc_estimate_keys(&est, 2);
	segsize = shm_toc_estimate(&est);

	seg = dsm_create(segsize, 0);
	toc = shm_toc_create(PCOPY_MAGIC, dsm_segment_address(seg), segsize);
	hdr = (PcopyHeader *) shm_toc_allocate(toc, sizeof(PcopyHeader));
	shm_toc_insert(toc, PCOPY_KEY_HEADER, hdr);
	slots = (PcopyWorkerSlot *) shm_toc_allocate(toc,
												 mul_size(sizeof(PcopyWorkerSlot), workers));
	shm_toc_insert(toc, PCOPY_KEY_WORKERS, slots);

	hdr->dbid = MyDatabaseId;
	hdr->roleid = GetUserId();
	hdr->relid = relid;
	hdr->nworkers = workers;
	strlcpy(hdr->filename, path, sizeof(hdr->filename));

	for (i = 0; i < workers; i++)
	{
		slots[i].start_off = offs[i];
		slots[i].end_off = offs[i + 1];
		slots[i].rows = 0;
		slots[i].sqlerrcode = 0;
		slots[i].errmsg[0] = '\0';
		pg_atomic_init_u32(&slots[i].state, PCOPY_PENDING);
	}

	handles = (BackgroundWorkerHandle **)
		palloc0(sizeof(BackgroundWorkerHandle *) * workers);

	memset(&bw, 0, sizeof(bw));
	bw.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	bw.bgw_start_time = BgWorkerStart_RecoveryFinished;
	bw.bgw_restart_time = BGW_NEVER_RESTART;
	strlcpy(bw.bgw_library_name, "pgcolumnar", BGW_MAXLEN);
	strlcpy(bw.bgw_function_name, "pgcolumnar_parallel_copy_worker", BGW_MAXLEN);
	snprintf(bw.bgw_name, BGW_MAXLEN, "pgcolumnar parallel_copy");
	snprintf(bw.bgw_type, BGW_MAXLEN, "pgcolumnar parallel_copy");
	bw.bgw_main_arg = UInt32GetDatum(dsm_segment_handle(seg));
	bw.bgw_notify_pid = MyProcPid;

	/*
	 * Register and wait. On any error (a failed registration, or cancellation
	 * while waiting) terminate every worker we launched so none are orphaned.
	 */
	PG_TRY();
	{
		for (i = 0; i < workers; i++)
		{
			memcpy(bw.bgw_extra, &i, sizeof(int));
			if (!RegisterDynamicBackgroundWorker(&bw, &handles[i]))
				ereport(ERROR,
						(errcode(ERRCODE_INSUFFICIENT_RESOURCES),
						 errmsg("could not register pgcolumnar parallel_copy worker %d of %d",
								i + 1, workers),
						 errhint("Increase max_worker_processes.")));
		}
		for (i = 0; i < workers; i++)
			WaitForBackgroundWorkerShutdown(handles[i]);
	}
	PG_CATCH();
	{
		for (i = 0; i < workers; i++)
			if (handles[i] != NULL)
				TerminateBackgroundWorker(handles[i]);
		PG_RE_THROW();
	}
	PG_END_TRY();

	for (i = 0; i < workers; i++)
	{
		uint32		st = pg_atomic_read_u32(&slots[i].state);

		if (st == PCOPY_DONE)
			total += slots[i].rows;
		else if (failed < 0)
			failed = i;
	}

	if (failed >= 0)
	{
		char		msg[512];
		int			code = slots[failed].sqlerrcode;

		strlcpy(msg, slots[failed].errmsg[0] ? slots[failed].errmsg
				: "worker exited without reporting a result", sizeof(msg));
		dsm_detach(seg);
		ereport(ERROR,
				(errcode(code ? code : ERRCODE_INTERNAL_ERROR),
				 errmsg("pgcolumnar.parallel_copy worker %d failed: %s",
						failed, msg)));
	}

	dsm_detach(seg);
	PG_RETURN_INT64(total);
}
