/*-------------------------------------------------------------------------
 *
 * columnar_parallel_export.c
 *		pgcolumnar.parallel_export_parquet: parallel Parquet export.
 *
 * N read-only background workers each write a disjoint slice of the source to
 * its own part-NNNN.parquet file under one output directory. Export is
 * read-only, so unlike parallel_copy there is no coordinator and no two-phase
 * commit -- the SQL function is itself the dispatcher. Every worker restores the
 * SAME serialized MVCC snapshot, so the exported directory is a consistent
 * point-in-time image. The directory is directly consumable by
 * pgcolumnar.read_parquet and the pgcolumnar_parquet foreign-data wrapper.
 *
 * Two target kinds mirror parallel_copy:
 *	 - a partitioned table with columnar partitions: one file per leaf partition;
 *	   each worker owns a contiguous slice of the oid-sorted leaf list;
 *	 - a single columnar table: split by row-group index ranges; each worker
 *	   writes the groups in its slice via ColumnarReadRestrictToGroups.
 *
 * Cleanroom: public PostgreSQL APIs and this project's own code only.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include "columnar.h"

#include "access/relation.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/pg_authid_d.h"
#include "catalog/pg_class.h"
#include "catalog/pg_inherits.h"
#include "fmgr.h"
#include "libpq/pqsignal.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/dsm.h"
#include "storage/fd.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/shm_toc.h"
#include "tcop/tcopprot.h"
#if PG_VERSION_NUM >= 160000
#include "utils/wait_event.h"	/* PG_WAIT_EXTENSION */
#else
#include "pgstat.h"
#endif
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

#define PEXPORT_MAGIC		0x50455850	/* 'PEXP' */
#define PEXPORT_KEY_HEADER	0
#define PEXPORT_KEY_SLOTS	1
#define PEXPORT_KEY_SNAPSHOT 2
#define PEXPORT_MAX_WORKERS 32

typedef enum PexportState
{
	PEXPORT_PENDING = 0,		/* not finished (also: worker crashed) */
	PEXPORT_DONE,				/* slice written; rows is valid */
	PEXPORT_FAILED				/* worker caught an error; see errmsg */
} PexportState;

typedef struct PexportWorkerSlot
{
	int32		startIdx;		/* [startIdx, endIdx): row-group indices for a */
	int32		endIdx;			/*   single table, or leaf-partition indices    */
	pg_atomic_uint32 state;		/* PexportState */
	int64		rows;			/* rows written (valid when state == PEXPORT_DONE) */
	int			sqlerrcode;
	char		errmsg[512];
	char		filepath[MAXPGPATH];	/* single-table: the one output file */
} PexportWorkerSlot;

typedef struct PexportHeader
{
	Oid			dbid;
	Oid			roleid;
	Oid			relid;			/* single columnar table, or partitioned parent */
	uint64		storageId;		/* single-table storage id (0 when partitioned) */
	int			nworkers;
	bool		single_table;
	char		dirpath[MAXPGPATH];		/* output directory */
} PexportHeader;

PGDLLEXPORT void pgcolumnar_parallel_export_worker(Datum main_arg);

/* ------------------------------------------------------------------------- */

static int
pexport_oid_cmp(const void *a, const void *b)
{
	Oid			oa = *(const Oid *) a;
	Oid			ob = *(const Oid *) b;

	if (oa < ob)
		return -1;
	if (oa > ob)
		return 1;
	return 0;
}

/*
 * pexport_leaf_partitions
 *		The oid-sorted leaf partitions of `parent`, palloc'd into *out; returns
 *		the count. The sort makes the order deterministic across processes, so a
 *		worker re-derives the identical list and slices it by index.
 */
static int
pexport_leaf_partitions(Oid parent, Oid **out)
{
	List	   *inh = find_all_inheritors(parent, AccessShareLock, NULL);
	ListCell   *lc;
	Oid		   *arr = palloc(sizeof(Oid) * Max(list_length(inh), 1));
	int			n = 0;

	foreach(lc, inh)
	{
		Oid			oid = lfirst_oid(lc);

		if (oid == parent)
			continue;
		if (get_rel_relkind(oid) == RELKIND_PARTITIONED_TABLE)
			continue;			/* intermediate partitioned table, not a leaf */
		arr[n++] = oid;
	}
	list_free(inh);
	if (n > 1)
		qsort(arr, n, sizeof(Oid), pexport_oid_cmp);
	*out = arr;
	return n;
}

/*
 * pexport_auto_workers
 *		Worker count when the caller passes none: half the admin's
 *		max_parallel_workers budget, at least one, capped at PEXPORT_MAX_WORKERS.
 *		Mirrors parallel_copy so the two features share one mental model.
 */
static int
pexport_auto_workers(void)
{
	const char *s = GetConfigOption("max_parallel_workers", true, false);
	int			budget = (s != NULL) ? atoi(s) : 8;
	int			n = budget / 2;

	if (n < 1)
		n = 1;
	if (n > PEXPORT_MAX_WORKERS)
		n = PEXPORT_MAX_WORKERS;
	return n;
}

/*
 * pexport_prepare_dir
 *		Create the output directory if absent; require it empty if it exists.
 *		read_parquet and the FDW union every *.parquet in the directory, so a
 *		stale file from an earlier, larger export would be silently folded into a
 *		read-back. Only absent-then-created, or already-empty, is allowed.
 */
static void
pexport_prepare_dir(const char *dir)
{
	struct stat st;
	DIR		   *d;
	struct dirent *de;

	if (stat(dir, &st) != 0)
	{
		if (errno != ENOENT)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not stat \"%s\": %m", dir)));
		if (MakePGDirectory(dir) != 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not create directory \"%s\": %m", dir)));
		return;
	}
	if (!S_ISDIR(st.st_mode))
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("\"%s\" exists and is not a directory", dir)));

	d = AllocateDir(dir);
	if (d == NULL)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open directory \"%s\": %m", dir)));
	while ((de = ReadDir(d, dir)) != NULL)
	{
		if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
			continue;
		FreeDir(d);
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("output directory \"%s\" is not empty", dir),
				 errhint("pgcolumnar.parallel_export_parquet writes into a new or empty directory.")));
	}
	FreeDir(d);
}

/*
 * pgcolumnar_parallel_export_worker
 *		Background-worker entry: attach the DSM, connect, restore the shared
 *		snapshot, and write this worker's slice to its Parquet file(s). Read-only,
 *		so there is nothing to commit and no 2PC. Reports rows + DONE (or FAILED)
 *		through the shared slot before exit.
 */
PGDLLEXPORT void
pgcolumnar_parallel_export_worker(Datum main_arg)
{
	dsm_segment *seg;
	shm_toc    *toc;
	PexportHeader *hdr;
	PexportWorkerSlot *slots;
	PexportWorkerSlot *me;
	char	   *snapbytes;
	int			widx;
	uint32		conn_flags = BGWORKER_BYPASS_ALLOWCONN;
	Snapshot	snap;

	memcpy(&widx, MyBgworkerEntry->bgw_extra, sizeof(int));

	pqsignal(SIGTERM, die);
	BackgroundWorkerUnblockSignals();

	seg = dsm_attach(DatumGetUInt32(main_arg));
	if (seg == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("pgcolumnar parallel_export worker could not attach to the shared segment")));
	toc = shm_toc_attach(PEXPORT_MAGIC, dsm_segment_address(seg));
	if (toc == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("pgcolumnar parallel_export worker found a bad shared segment")));
	hdr = (PexportHeader *) shm_toc_lookup(toc, PEXPORT_KEY_HEADER, false);
	slots = (PexportWorkerSlot *) shm_toc_lookup(toc, PEXPORT_KEY_SLOTS, false);
	snapbytes = (char *) shm_toc_lookup(toc, PEXPORT_KEY_SNAPSHOT, false);
	me = &slots[widx];

#if PG_VERSION_NUM >= 170000
	conn_flags |= BGWORKER_BYPASS_ROLELOGINCHECK;
#endif
	BackgroundWorkerInitializeConnectionByOid(hdr->dbid, hdr->roleid, conn_flags);

	StartTransactionCommand();
	snap = RestoreSnapshot(snapbytes);
	PushActiveSnapshot(snap);

	PG_TRY();
	{
		int64		rows = 0;

		if (hdr->single_table)
		{
			Relation	rel = table_open(hdr->relid, AccessShareLock);
			List	   *groups = ColumnarReadRowGroupList(hdr->storageId,
														  ColumnarCatalogSnapshot(snap));
			int			ntake = me->endIdx - me->startIdx;
			uint64	   *gnos = (ntake > 0) ? palloc(sizeof(uint64) * ntake) : NULL;
			int			k = 0;
			int			idx = 0;
			ListCell   *lc;

			foreach(lc, groups)
			{
				if (idx >= me->startIdx && idx < me->endIdx)
				{
					NativeRowGroupMetadata *rg = (NativeRowGroupMetadata *) lfirst(lc);

					gnos[k++] = rg->groupNumber;
				}
				idx++;
			}
			/* k == 0 only for an empty table (ntasks 0, one worker); a NULL
			 * restrict then writes the whole empty table, i.e. zero rows. */
			rows = ColumnarWriteParquetFile(rel, snap, me->filepath, gnos, k);
			table_close(rel, AccessShareLock);
		}
		else
		{
			Oid		   *parts;
			int			npart = pexport_leaf_partitions(hdr->relid, &parts);
			int			i;

			for (i = me->startIdx; i < me->endIdx && i < npart; i++)
			{
				Relation	part = table_open(parts[i], AccessShareLock);
				char		fp[MAXPGPATH];

				snprintf(fp, sizeof(fp), "%s/part-%04d.parquet", hdr->dirpath, i);
				rows += ColumnarWriteParquetFile(part, snap, fp, NULL, 0);
				table_close(part, AccessShareLock);
			}
		}

		me->rows = rows;
		PopActiveSnapshot();
		CommitTransactionCommand();
		pg_atomic_write_u32(&me->state, PEXPORT_DONE);
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		MemoryContextSwitchTo(TopMemoryContext);
		edata = CopyErrorData();
		me->sqlerrcode = edata->sqlerrcode;
		strlcpy(me->errmsg,
				edata->message ? edata->message : "parallel_export worker failed",
				sizeof(me->errmsg));
		FlushErrorState();
		FreeErrorData(edata);
		AbortOutOfAnyTransaction();
		pg_atomic_write_u32(&me->state, PEXPORT_FAILED);
	}
	PG_END_TRY();

	dsm_detach(seg);
	proc_exit(0);
}

/*
 * columnar_parallel_export_parquet
 *		SQL: pgcolumnar.parallel_export_parquet(target regclass, path text,
 *											    workers int DEFAULT NULL) -> bigint.
 */
PG_FUNCTION_INFO_V1(columnar_parallel_export_parquet);
Datum
columnar_parallel_export_parquet(PG_FUNCTION_ARGS)
{
	Oid			relid;
	char	   *dir;
	int			workers;
	Relation	rel;
	bool		single_table = false;
	int			ntasks = 0;		/* row-group count, or leaf-partition count */
	uint64		storageId = 0;
	Snapshot	snap;
	Size		snaplen;
	shm_toc_estimator est;
	Size		segsize;
	dsm_segment *seg;
	shm_toc    *toc;
	PexportHeader *hdr;
	PexportWorkerSlot *slots;
	char	   *snapchunk;
	uint32		dsmh;
	BackgroundWorker bw;
	BackgroundWorkerHandle **handles;
	int			i;
	int			per,
				rem,
				cur;
	int64		total = 0;
	int			failed = -1;

	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("target and path must not be null")));
	relid = PG_GETARG_OID(0);
	dir = text_to_cstring(PG_GETARG_TEXT_PP(1));
	workers = PG_ARGISNULL(2) ? pexport_auto_workers() : PG_GETARG_INT32(2);
	if (workers < 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("workers must be at least 1")));
	if (workers > PEXPORT_MAX_WORKERS)
		workers = PEXPORT_MAX_WORKERS;

	/*
	 * The workers read a server-side file path and read the table. Require the
	 * write-server-files role (the write-side analog of parallel_copy's
	 * read-server-files check) plus SELECT on the target -- the workers do not
	 * run the executor permission check, so enforce it here before spawning.
	 */
	if (!has_privs_of_role(GetUserId(), ROLE_PG_WRITE_SERVER_FILES))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser or a member of the pg_write_server_files role to export to server files")));
	{
		AclResult	ac = pg_class_aclcheck(relid, GetUserId(), ACL_SELECT);

		if (ac != ACLCHECK_OK)
			aclcheck_error(ac, OBJECT_TABLE, get_rel_name(relid));
	}

	rel = table_open(relid, AccessShareLock);

	/* one shared MVCC snapshot for the whole export -> consistent image */
	snap = (ActiveSnapshotSet() && IsMVCCSnapshot(GetActiveSnapshot()))
		? GetActiveSnapshot() : GetTransactionSnapshot();
	snap = RegisterSnapshot(snap);

	if (rel->rd_rel->relkind == RELKIND_PARTITIONED_TABLE)
	{
		Oid		   *parts;
		int			npart = pexport_leaf_partitions(relid, &parts);

		if (npart == 0)
		{
			UnregisterSnapshot(snap);
			table_close(rel, AccessShareLock);
			ereport(ERROR,
					(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
					 errmsg("partitioned table \"%s\" has no partitions to export",
							RelationGetRelationName(rel))));
		}
		for (i = 0; i < npart; i++)
		{
			if (!ColumnarIsColumnarRelation(parts[i]))
			{
				char		nm[NAMEDATALEN];

				strlcpy(nm, get_rel_name(parts[i]) ? get_rel_name(parts[i]) : "?",
						NAMEDATALEN);
				UnregisterSnapshot(snap);
				table_close(rel, AccessShareLock);
				ereport(ERROR,
						(errcode(ERRCODE_WRONG_OBJECT_TYPE),
						 errmsg("partition \"%s\" is not a columnar table", nm)));
			}
		}
		ColumnarParquetCheckExportable(rel);	/* leaves share the parent tupdesc */
		single_table = false;
		ntasks = npart;
		if (workers > npart)
			workers = npart;
	}
	else if (ColumnarIsColumnarRelation(relid))
	{
		List	   *groups;

		ColumnarParquetCheckExportable(rel);
		storageId = ColumnarStorageId(rel);
		groups = ColumnarReadRowGroupList(storageId, ColumnarCatalogSnapshot(snap));
		ntasks = list_length(groups);
		single_table = true;
		if (workers > Max(ntasks, 1))
			workers = Max(ntasks, 1);
	}
	else
	{
		UnregisterSnapshot(snap);
		table_close(rel, AccessShareLock);
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("relation \"%s\" is not a columnar table or a partitioned table with columnar partitions",
						RelationGetRelationName(rel))));
	}

	pexport_prepare_dir(dir);

	/* lay out one DSM segment: header + slots + the serialized snapshot */
	snaplen = EstimateSnapshotSpace(snap);
	shm_toc_initialize_estimator(&est);
	shm_toc_estimate_chunk(&est, sizeof(PexportHeader));
	shm_toc_estimate_chunk(&est, mul_size(sizeof(PexportWorkerSlot), workers));
	shm_toc_estimate_chunk(&est, snaplen);
	shm_toc_estimate_keys(&est, 3);
	segsize = shm_toc_estimate(&est);

	seg = dsm_create(segsize, 0);
	toc = shm_toc_create(PEXPORT_MAGIC, dsm_segment_address(seg), segsize);
	hdr = (PexportHeader *) shm_toc_allocate(toc, sizeof(PexportHeader));
	shm_toc_insert(toc, PEXPORT_KEY_HEADER, hdr);
	slots = (PexportWorkerSlot *) shm_toc_allocate(toc,
												   mul_size(sizeof(PexportWorkerSlot), workers));
	shm_toc_insert(toc, PEXPORT_KEY_SLOTS, slots);
	snapchunk = (char *) shm_toc_allocate(toc, snaplen);
	SerializeSnapshot(snap, snapchunk);
	shm_toc_insert(toc, PEXPORT_KEY_SNAPSHOT, snapchunk);
	dsmh = dsm_segment_handle(seg);

	hdr->dbid = MyDatabaseId;
	hdr->roleid = GetUserId();
	hdr->relid = relid;
	hdr->storageId = storageId;
	hdr->nworkers = workers;
	hdr->single_table = single_table;
	strlcpy(hdr->dirpath, dir, sizeof(hdr->dirpath));

	/* even-ish contiguous [startIdx, endIdx) task ranges */
	per = ntasks / workers;
	rem = ntasks % workers;
	cur = 0;
	for (i = 0; i < workers; i++)
	{
		int			take = per + (i < rem ? 1 : 0);

		slots[i].startIdx = cur;
		slots[i].endIdx = cur + take;
		cur += take;
		slots[i].rows = 0;
		slots[i].sqlerrcode = 0;
		slots[i].errmsg[0] = '\0';
		pg_atomic_init_u32(&slots[i].state, PEXPORT_PENDING);
		if (single_table)
			snprintf(slots[i].filepath, sizeof(slots[i].filepath),
					 "%s/part-%04d.parquet", dir, i);
		else
			slots[i].filepath[0] = '\0';	/* worker names files per partition */
	}

	handles = (BackgroundWorkerHandle **)
		palloc0(sizeof(BackgroundWorkerHandle *) * workers);

	memset(&bw, 0, sizeof(bw));
	bw.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	bw.bgw_start_time = BgWorkerStart_RecoveryFinished;
	bw.bgw_restart_time = BGW_NEVER_RESTART;
	strlcpy(bw.bgw_library_name, "pgcolumnar", BGW_MAXLEN);
	strlcpy(bw.bgw_function_name, "pgcolumnar_parallel_export_worker", BGW_MAXLEN);
	snprintf(bw.bgw_name, BGW_MAXLEN, "pgcolumnar parallel_export worker");
	snprintf(bw.bgw_type, BGW_MAXLEN, "pgcolumnar parallel_export worker");
	bw.bgw_main_arg = UInt32GetDatum(dsmh);
	bw.bgw_notify_pid = MyProcPid;

	PG_TRY();
	{
		for (i = 0; i < workers; i++)
		{
			memcpy(bw.bgw_extra, &i, sizeof(int));
			if (!RegisterDynamicBackgroundWorker(&bw, &handles[i]))
				ereport(ERROR,
						(errcode(ERRCODE_INSUFFICIENT_RESOURCES),
						 errmsg("could not register pgcolumnar parallel_export worker %d of %d",
								i + 1, workers),
						 errhint("Increase max_worker_processes; parallel_export_parquet needs %d worker slots.",
								 workers)));
		}

		/* wait for all workers, staying responsive to cancellation */
		for (;;)
		{
			int			running = 0;

			CHECK_FOR_INTERRUPTS();
			for (i = 0; i < workers; i++)
			{
				pid_t		pid;

				if (handles[i] != NULL &&
					GetBackgroundWorkerPid(handles[i], &pid) != BGWH_STOPPED)
					running++;
			}
			if (running == 0)
				break;
			(void) WaitLatch(MyLatch, WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
							 1000L, PG_WAIT_EXTENSION);
			ResetLatch(MyLatch);
		}
	}
	PG_CATCH();
	{
		for (i = 0; i < workers; i++)
			if (handles[i] != NULL)
				TerminateBackgroundWorker(handles[i]);
		for (i = 0; i < workers; i++)
			if (handles[i] != NULL)
				WaitForBackgroundWorkerShutdown(handles[i]);
		UnregisterSnapshot(snap);
		dsm_detach(seg);
		table_close(rel, AccessShareLock);
		PG_RE_THROW();
	}
	PG_END_TRY();

	for (i = 0; i < workers; i++)
	{
		if (pg_atomic_read_u32(&slots[i].state) == PEXPORT_DONE)
			total += slots[i].rows;
		else if (failed < 0)
			failed = i;
	}

	if (failed >= 0)
	{
		int			code = slots[failed].sqlerrcode;
		char		msg[512];

		strlcpy(msg, slots[failed].errmsg[0] ? slots[failed].errmsg
				: "worker exited without reporting a result", sizeof(msg));
		UnregisterSnapshot(snap);
		dsm_detach(seg);
		table_close(rel, AccessShareLock);
		ereport(ERROR,
				(errcode(code ? code : ERRCODE_INTERNAL_ERROR),
				 errmsg("pgcolumnar.parallel_export_parquet worker %d failed: %s",
						failed, msg)));
	}

	UnregisterSnapshot(snap);
	dsm_detach(seg);
	table_close(rel, AccessShareLock);
	PG_RETURN_INT64(total);
}
