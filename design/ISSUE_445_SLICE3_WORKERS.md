# Issue #445 slice 3 — dispatch flush_one_column across a worker pool

Design before code (house rule). Builds on slice 1 (`flush_one_column`, #589) and
slice 2 (the dsm serialize/deserialize helpers, #590). Slice 3 runs the per-column
flush on background workers instead of serially in the backend, and **degrades to
the serial path whenever it cannot** — never producing a wrong row count.

## Invariants (the bar this slice is held to)

1. **Byte-identical** stripe `data` bytes and catalog rows vs the serial path, ON and OFF.
2. **OFF by default** — a new boolean GUC `pgcolumnar.parallel_flush` (default off) gates it,
   so the merged default behaviour is unchanged and the parallel path is opt-in for testing.
   (Slice 4 turns this into the measured, eventually-default control.)
3. **Slot starvation degrades to serial, never to a wrong row count.** If fewer than the
   needed workers register, or any worker fails, the backend completes every unfinished
   column itself, serially, in-process. The set of columns written is always exactly [0,natts).

## Why the FSST verdict cache must be threaded (byte-identity, subtle)

The #472 cache lives in `writeState->colDefs[c].fsstVerdict/fsstVerdictAge` and persists across
row-group flushes within one statement. The serial path seeds each `flush_one_column` from it
and writes the updated verdict back. A worker with a fresh (`UNKNOWN`) verdict would **re-decide**
every group; for a group whose corpus would flip the cached verdict, re-deciding yields DIFFERENT
stored bytes than the serial reuse. So the cache is not a pure perf detail here — to stay
byte-identical, slice 3 threads it:
- The input dsm carries a `{fsstVerdict, fsstVerdictAge}` array, one per column, seeded from
  `writeState->colDefs`.
- Each worker seeds its reconstructed `def` from that array before calling `flush_one_column`,
  and writes the updated `{verdict, age}` into its result.
- The backend applies the returned verdicts back into `writeState->colDefs` in column order,
  so the next flush sees exactly the state the serial path would have. Each column is owned by
  exactly one worker per flush, so there is no cross-worker cache race.

## dsm layout (one input segment, shm_toc keyed like the export path)

- KEY_HEADER: `{ dbid, roleid, relid, storageId, groupNumber, rowCount, validityBytes,
  encodeEffort, compressionType, compressionLevel, natts, nworkers, snapname[64] }`.
- KEY_INPUTS: all columns' `serialize_column_input` blobs concatenated.
- KEY_INOFFS: `uint64 offset[natts+1]` into KEY_INPUTS (offset[c]..offset[c+1] is column c).
- KEY_VERDICTS: `struct { int8 verdict; int32 age; } [natts]` seed values.
- KEY_SLOTS: `WorkerSlot[nworkers]` — `{ pg_atomic_uint32 state; dsm_handle outHandle;
  uint32 outLen; int sqlerrcode; char errmsg[512]; }`. Result bytes do NOT live here (variable
  size); each worker publishes its own OUTPUT dsm segment and stores the handle here.
- KEY_CLAIM: one `pg_atomic_uint32` next-column counter; workers claim columns with
  `pg_atomic_fetch_add_u32` until it reaches natts (self-balancing; no static partition).

## Worker (`pgcolumnar_parallel_flush_worker`, modelled on the export worker)

attach seg + shm_toc; read widx from `bgw_extra`; `BackgroundWorkerInitializeConnectionByOid`;
Start txn + `ImportSnapshot` + push snapshot (for catalog reads only — the value data is in the
dsm, not the table). `table_open(relid, AccessShareLock)` once for the tupdesc. Then loop:
`c = pg_atomic_fetch_add_u32(claim, 1); if (c >= natts) break;` deserialize column c's input
(`deserialize_column_input` on KEY_INPUTS+offset[c]); reconstruct `att` from the tupdesc and
`def` from the column type via the SAME logic the write-state setup uses (extract that into a
shared `build_column_def(att, &def)` helper so worker and backend agree exactly); seed
`def.fsstVerdict/Age` from KEY_VERDICTS[c]; `flush_one_column(...)`; `serialize_column_result`
into a per-worker StringInfo AND record `(c, updated verdict/age)`. After the loop, `dsm_create`
one OUTPUT segment holding `{ uint32 count; per column: uint32 c, int8 verdict, int32 age,
uint32 resultLen, result bytes }`, store its handle+len in the slot, mark DONE. PG_CATCH →
record error + mark FAILED. detach; `proc_exit(0)`.

## Backend (`pgcolumnar_flush_row_group`, parallel path)

If GUC off OR natts < 2 → slice-2/serial path unchanged. Else:
1. Build input dsm (serialize every column via `serialize_column_input`, offsets, verdict seeds).
   `ExportSnapshot(GetActiveSnapshot())`.
2. `nworkers = min(natts, auto_workers())`. Register workers; **if any registration fails, do
   NOT error** — remember how many started (`nstarted`); if `nstarted == 0`, run the whole flush
   serially (slice-2 path) and skip to catalog. Workers self-balance via the claim counter, so
   `nstarted < nworkers` still covers all columns.
3. Wait for all started workers (`WaitForBackgroundWorkerShutdown`).
4. Collect: a `done[natts]` bitmap. For each DONE worker, attach its output dsm, and for each
   column it produced: `deserialize_column_result`, stash by column index, mark done, apply the
   returned verdict to `writeState->colDefs[c]`. For any worker FAILED, leave its columns undone
   (its error is recorded; a failed worker is not fatal by itself as long as the column gets done).
5. **Serial completion of the remainder:** for every `c` still not done, run
   `flush_one_column` in the backend now (seeded from `colDefs[c]`), and apply its verdict. This
   is the degradation path and it also covers a worker that failed or a slot that never started.
   If a worker FAILED with a hard error (not just "didn't run"), re-raise it after completion —
   TBD in review whether a worker error should abort or just fall back; default to fall back +
   log, since the serial redo produces the correct bytes.
6. Assemble in column order + write + catalog, exactly as slices 1–2 (backend-only I/O).

## Verification plan

- **OFF path byte-identical:** all write suites + differential with GUC off (default).
- **ON path byte-identical:** same suites with `pgcolumnar.parallel_flush=on` — differential,
  native_zonemap, native_bloom, write_fsst_compressed (FSST verdict threading), native_dml.
- **Slot starvation:** set `max_worker_processes` below need; assert the load still completes
  with the exact row count and byte-identical output (degradation proven, not assumed —
  removal-proof style: with the fallback line deleted, a starved run must red/short-count).
- **Real parallelism:** confirm workers actually ran (a counter / log), so an ON run that
  silently fell back serially isn't mistaken for a passing parallel test.
- Two toolchains: forced ASAN+UBSAN and pg18a assert; -Wshadow/-Werror clean.

## Open questions for jdatcmd (his design)

- Worker-error policy (step 5): fall back + log, or abort the statement? Fallback keeps the
  write correct; aborting surfaces a real bug faster.
- Whether the worker should reuse `columnar_parallel_export.c`'s connection/snapshot scaffolding
  by extracting it, or carry its own copy (the two differ: export imports the snapshot for data
  reads; flush needs it only for catalog/tupdesc, so a plain fresh snapshot may suffice).
