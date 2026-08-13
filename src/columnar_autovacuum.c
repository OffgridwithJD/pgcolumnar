/*-------------------------------------------------------------------------
 * columnar_autovacuum.c
 *		A background worker that runs the maintenance autovacuum cannot reach
 *		(#415): the columnar space-reclaim and re-clustering that live in
 *		extension functions rather than table-AM callbacks.
 *
 * Shape mirrors core autovacuum: a launcher (registered from _PG_init, so it
 * needs shared_preload_libraries -- which pgColumnar already requires) wakes on
 * a naptime and starts one short-lived worker per database; each worker asks
 * pgcolumnar.maintenance_due(rel) which columnar tables want attention and runs
 * the recommended verb.
 *
 * TWO INVARIANTS make this safe to run unattended:
 *
 * 1. Only the ShareUpdateExclusiveLock verbs -- pgcolumnar.compact_rewrite and
 *    pgcolumnar.recluster (now self-gating, #415 part A) -- are ever called.
 *    Never vacuum()/vacuum_sorted()/cluster(), which take AccessExclusiveLock.
 *    SUEL does not block readers or ordinary writers, so the daemon cannot block
 *    production by construction.
 *
 * 2. Autovacuum's yield: the worker sets PROC_IS_AUTOVACUUM, so when a backend
 *    queues for a lock that conflicts with the worker's SUEL, core's lock
 *    manager cancels the worker -- the maintenance op takes a query-cancel,
 *    releases its lock, the user's statement proceeds, and the worker moves to
 *    the next table. Each op runs in its own transaction inside PG_TRY, so a
 *    cancel aborts only that op.
 *
 * Off by default (pgcolumnar.autovacuum = off): a new autonomous-maintenance
 * daemon earns its keep opt-in, and even on it only runs the non-blocking verbs.
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <unistd.h>

#include "access/genam.h"
#include "access/heapam.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/pg_database.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lmgr.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "tcop/tcopprot.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/snapmgr.h"

#include "columnar.h"

/* GUCs (defined in columnar_tableam.c _PG_init, declared in columnar.h) */
extern bool pgcolumnar_autovacuum;
extern int	pgcolumnar_autovacuum_naptime;
extern double pgcolumnar_autovacuum_compact_threshold;
extern double pgcolumnar_autovacuum_recluster_threshold;

PGDLLEXPORT void pgcolumnar_av_launcher_main(Datum arg);
PGDLLEXPORT void pgcolumnar_av_worker_main(Datum arg);

/*
 * Register the launcher. Called from _PG_init only when
 * process_shared_preload_libraries_in_progress -- a server run without preload
 * loses the daemon and nothing else.
 */
void
PgColumnarAutovacuumRegister(void)
{
	BackgroundWorker bw;

	memset(&bw, 0, sizeof(bw));
	bw.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	bw.bgw_start_time = BgWorkerStart_RecoveryFinished;
	/* a crashed launcher restarts after a minute, never in a tight loop */
	bw.bgw_restart_time = 60;
	strlcpy(bw.bgw_library_name, "pgcolumnar", BGW_MAXLEN);
	strlcpy(bw.bgw_function_name, "pgcolumnar_av_launcher_main", BGW_MAXLEN);
	strlcpy(bw.bgw_name, "pgcolumnar autovacuum launcher", BGW_MAXLEN);
	strlcpy(bw.bgw_type, "pgcolumnar autovacuum launcher", BGW_MAXLEN);
	bw.bgw_main_arg = (Datum) 0;
	bw.bgw_notify_pid = 0;
	RegisterBackgroundWorker(&bw);
}

/* Collect the OIDs of databases that accept connections and are not templates. */
static List *
av_database_list(void)
{
	List	   *dbs = NIL;
	Relation	rel;
	TableScanDesc scan;
	HeapTuple	tup;

	StartTransactionCommand();
	rel = table_open(DatabaseRelationId, AccessShareLock);
	scan = table_beginscan_catalog(rel, 0, NULL);
	while ((tup = heap_getnext(scan, ForwardScanDirection)) != NULL)
	{
		Form_pg_database db = (Form_pg_database) GETSTRUCT(tup);

		if (db->datallowconn && !db->datistemplate)
		{
			MemoryContext old = MemoryContextSwitchTo(TopMemoryContext);

#if PG_VERSION_NUM >= 120000
			dbs = lappend_oid(dbs, db->oid);
#else
			dbs = lappend_oid(dbs, HeapTupleGetOid(tup));
#endif
			MemoryContextSwitchTo(old);
		}
	}
	table_endscan(scan);
	table_close(rel, AccessShareLock);
	CommitTransactionCommand();
	return dbs;
}

/* Start one worker for `dbid` and wait for it to finish. */
static void
av_run_worker_for_db(Oid dbid)
{
	BackgroundWorker bw;
	BackgroundWorkerHandle *handle;
	BgwHandleStatus status;
	pid_t		pid;

	memset(&bw, 0, sizeof(bw));
	bw.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	bw.bgw_start_time = BgWorkerStart_RecoveryFinished;
	bw.bgw_restart_time = BGW_NEVER_RESTART;		/* one-shot per naptime */
	strlcpy(bw.bgw_library_name, "pgcolumnar", BGW_MAXLEN);
	strlcpy(bw.bgw_function_name, "pgcolumnar_av_worker_main", BGW_MAXLEN);
	strlcpy(bw.bgw_name, "pgcolumnar autovacuum worker", BGW_MAXLEN);
	strlcpy(bw.bgw_type, "pgcolumnar autovacuum worker", BGW_MAXLEN);
	bw.bgw_main_arg = (Datum) 0;
	memcpy(bw.bgw_extra, &dbid, sizeof(Oid));
	bw.bgw_notify_pid = MyProcPid;

	if (!RegisterDynamicBackgroundWorker(&bw, &handle))
	{
		/* worker slots exhausted this cycle; try again next naptime */
		elog(DEBUG1, "pgcolumnar autovacuum: no worker slot for database %u", dbid);
		return;
	}
	status = WaitForBackgroundWorkerStartup(handle, &pid);
	if (status != BGWH_STARTED)
		return;
	(void) WaitForBackgroundWorkerShutdown(handle);
}

/*
 * The launcher. Connects to no database (shared-catalog access only), and on
 * each naptime -- when enabled -- runs one worker per database in turn.
 */
void
pgcolumnar_av_launcher_main(Datum arg)
{
	pqsignal(SIGHUP, SignalHandlerForConfigReload);
	pqsignal(SIGTERM, die);
	BackgroundWorkerUnblockSignals();
	BackgroundWorkerInitializeConnection(NULL, NULL, 0);

	for (;;)
	{
		int			rc;

		rc = WaitLatch(MyLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
					   (long) pgcolumnar_autovacuum_naptime * 1000L,
					   PG_WAIT_EXTENSION);
		if (rc & WL_LATCH_SET)
			ResetLatch(MyLatch);
		CHECK_FOR_INTERRUPTS();		/* SIGTERM via die() exits here */

		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
		}

		if (!pgcolumnar_autovacuum)
			continue;

		{
			List	   *dbs = av_database_list();
			ListCell   *lc;

			foreach(lc, dbs)
			{
				CHECK_FOR_INTERRUPTS();
				if (!pgcolumnar_autovacuum)
					break;
				av_run_worker_for_db(lfirst_oid(lc));
			}
			list_free(dbs);
		}
	}
}

/* Mark this worker as autovacuum, so a lock waiter can cancel it (the yield). */
static void
av_mark_as_autovacuum(void)
{
#ifdef PROC_IS_AUTOVACUUM
	LWLockAcquire(ProcArrayLock, LW_EXCLUSIVE);
	MyProc->statusFlags |= PROC_IS_AUTOVACUUM;
	ProcGlobal->statusFlags[MyProc->pgxactoff] = MyProc->statusFlags;
	LWLockRelease(ProcArrayLock);
#endif
}

/*
 * Run one maintenance verb on one table, each in its own transaction inside
 * PG_TRY: a query-cancel (the lock yield) or any error aborts just this op and
 * the caller continues to the next table.
 */
static void
av_maintain_one(const char *qualname)
{
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());
	SetCurrentStatementStartTimestamp();

	PG_TRY();
	{
		bool		compactDue = false;
		bool		reclusterDue = false;
		char	   *sortKey = NULL;
		Oid			argtypes[3] = {REGCLASSOID, FLOAT8OID, FLOAT8OID};
		Datum		argvals[3];
		char		q[512];

		argvals[0] = DirectFunctionCall1(regclassin, CStringGetDatum(qualname));
		argvals[1] = Float8GetDatum(pgcolumnar_autovacuum_compact_threshold);
		argvals[2] = Float8GetDatum(pgcolumnar_autovacuum_recluster_threshold);

		if (SPI_connect() != SPI_OK_CONNECT)
			elog(ERROR, "pgcolumnar autovacuum: SPI_connect failed");

		if (SPI_execute_with_args(
				"SELECT compact_rewrite_due, recluster_due, "
				"       array_to_string(sort_key, ',') "
				"FROM pgcolumnar.maintenance_due($1, $2, $3)",
				3, argtypes, argvals, NULL, true, 1) == SPI_OK_SELECT &&
			SPI_processed == 1)
		{
			bool		isnull;
			Datum		d;

			d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
			compactDue = !isnull && DatumGetBool(d);
			d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &isnull);
			reclusterDue = !isnull && DatumGetBool(d);
			d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3, &isnull);
			if (!isnull)
				sortKey = pstrdup(TextDatumGetCString(d));
		}

		/* compact_rewrite: online space reclaim (SUEL) */
		if (compactDue)
		{
			snprintf(q, sizeof(q),
					 "SELECT pgcolumnar.compact_rewrite(%s, %g)",
					 quote_literal_cstr(qualname),
					 pgcolumnar_autovacuum_compact_threshold);
			(void) SPI_execute(q, false, 0);
			elog(LOG, "pgcolumnar autovacuum: compact_rewrite %s", qualname);
		}

		/*
		 * recluster: only when the table has a recorded/declared key (else the
		 * daemon cannot know the columns). The self-gating recluster (#415) is
		 * a no-op when nothing decayed, so calling it here is cheap when the
		 * gate was optimistic.
		 */
		if (reclusterDue && sortKey != NULL && sortKey[0] != '\0')
		{
			snprintf(q, sizeof(q),
					 "SELECT pgcolumnar.recluster(%s, VARIADIC string_to_array(%s, ',')::name[])",
					 quote_literal_cstr(qualname),
					 quote_literal_cstr(sortKey));
			(void) SPI_execute(q, false, 0);
			elog(LOG, "pgcolumnar autovacuum: recluster %s by (%s)", qualname, sortKey);
		}

		SPI_finish();
		PopActiveSnapshot();
		CommitTransactionCommand();
	}
	PG_CATCH();
	{
		/*
		 * A cancel (the lock yield) or any error: roll this op back and keep
		 * going. The where-it-failed line is what an administrator acts on.
		 */
		MemoryContext ecxt = MemoryContextSwitchTo(TopMemoryContext);
		ErrorData  *ed = CopyErrorData();

		elog(LOG, "pgcolumnar autovacuum: skipped %s: %s", qualname, ed->message);
		FreeErrorData(ed);
		MemoryContextSwitchTo(ecxt);

		FlushErrorState();
		AbortCurrentTransaction();
	}
	PG_END_TRY();
}

/*
 * The per-database worker. Connects, marks itself autovacuum, enumerates
 * columnar tables, and maintains each one.
 */
void
pgcolumnar_av_worker_main(Datum arg)
{
	Oid			dbid;
	uint32		conn_flags = 0;
	List	   *tables = NIL;
	ListCell   *lc;

	memcpy(&dbid, MyBgworkerEntry->bgw_extra, sizeof(Oid));

	pqsignal(SIGTERM, die);
	BackgroundWorkerUnblockSignals();

#if PG_VERSION_NUM >= 170000
	conn_flags |= BGWORKER_BYPASS_ROLELOGINCHECK;
#endif
	/* InvalidOid role: the bootstrap superuser, like a real autovacuum worker */
	BackgroundWorkerInitializeConnectionByOid(dbid, InvalidOid, conn_flags);

	av_mark_as_autovacuum();

	/* Snapshot the columnar-table list once, in its own transaction. */
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());
	if (SPI_connect() == SPI_OK_CONNECT)
	{
		int			ret = SPI_execute(
			"SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname) "
			"FROM pg_class c "
			"JOIN pg_am a ON a.oid = c.relam "
			"JOIN pg_namespace n ON n.oid = c.relnamespace "
			"WHERE a.amname = 'pgcolumnar' AND c.relkind = 'r'",
			true, 0);
		if (ret == SPI_OK_SELECT)
		{
			uint64		i;

			for (i = 0; i < SPI_processed; i++)
			{
				bool		isnull;
				Datum		d = SPI_getbinval(SPI_tuptable->vals[i],
											 SPI_tuptable->tupdesc, 1, &isnull);

				if (!isnull)
				{
					MemoryContext old = MemoryContextSwitchTo(TopMemoryContext);

					tables = lappend(tables, pstrdup(TextDatumGetCString(d)));
					MemoryContextSwitchTo(old);
				}
			}
		}
		SPI_finish();
	}
	PopActiveSnapshot();
	CommitTransactionCommand();

	foreach(lc, tables)
	{
		CHECK_FOR_INTERRUPTS();
		av_maintain_one((const char *) lfirst(lc));
	}
	/* worker exits; the launcher starts a fresh one next naptime */
}
