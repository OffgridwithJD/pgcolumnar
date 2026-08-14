# Issue #623: parallel_export_parquet to a remote (s3://) prefix

Design before code. Step 4 of #394, on merged step 3 (#622: the remote sink and
the `delete_object` ABI). The worker writers already route through
`PgColumnarWriteParquetFile` -> `PgColumnarSinkOpen`, so a remote prefix's
per-worker objects fall out for free. Only the dispatcher does filesystem-only
work that a remote prefix has no analogue for.

## What already works (verified, main @ #627)

`slots[i].filepath` is built as `"%s/part-%04d.parquet"` from `dir`
(`columnar_parallel_export.c:606`); the partitioned worker names files the same
way from `hdr->dirpath` (`:384`). For `dir = "s3://bucket/prefix"` this yields
`s3://bucket/prefix/part-0000.parquet`, which the sink dispatches remotely
(`PgColumnarSinkOpen`). So the workers already write per-worker remote objects,
and the read-back path (the FDW / `read_parquet` unioning a prefix) is #619's
job, not this one; this issue's suite reads each object by its exact key.

## The two dispatcher seams

Both are keyed off `PgColumnarPathIsRemote(dir)`, computed once at entry.

### 1. `pexport_prepare_dir` (`:550`)

Local: create the directory, require it empty (`:187-227`), because the FDW
unions every `*.parquet` under it and a stale file from a larger prior export
would be folded into a read-back.

Remote: there is no directory to create. Require-empty cannot be checked
without a bucket listing, which is #619 and deliberately deferred. So the
remote branch is a **documented skip**: the dispatcher does not verify the
prefix is empty. The user-facing rule (docs + the function's own errhint) is
that a remote prefix must be new or empty, and a stale higher-numbered
`part-NNNN.parquet` from a larger previous run into the same prefix would be
unioned by a later read. This is the same hazard the local guard prevents; the
honest statement is that the remote path cannot detect it until #619 lands a
listing. It is NOT silently ignored: the skip is a named branch with a comment
citing #619.

### 2. `pexport_remove_outputs` (`:283` cleanup, `:689` error path)

Local: scan the directory, unlink every `*.parquet` and `*.parquet.tmp.*`
(`:244-270`). This is the failed/cancelled-run cleanup and the FATAL-orphan
cleanup from #612.

Remote: the dispatcher knows its own key set exactly, so no listing is needed.
The keys are `dir/part-0000.parquet` through `dir/part-(count-1).parquet`, where
`count = workers` (single-table) or `npart` (partitioned). The remote branch
calls the module's `delete_object` (ABI v3, `PgColumnarObjStoreApi.delete_object`,
`objstore_delete_object`) over each of those keys, best-effort like the local
unlink. `pexport_remove_outputs` therefore needs the count; it is threaded
through the `PexportSpawn` struct (which already carries `dirpath`) and set from
`workers`/`npart` at spawn time.

The FATAL-orphan case is bounded the same way #622 documented it: a worker the
dispatcher TERMINATES dies without `PG_CATCH`, so its in-flight multipart upload
is not aborted by us (the dispatcher lacks the worker's UploadId). The
dispatcher deletes whatever completed objects exist by key; the incomplete
upload is covered by the bucket lifecycle rule the export docs already
recommend.

## Delete of a completed-but-should-be-removed object

`delete_object(url, cfg)` issues a signed `DELETE /bucket/key`. The cfg for the
export path is NULL (ambient credentials, the function-API rule from M4), the
same cfg the worker sinks use. The allow-list and link-local refusal apply at
connect, as for every module connection.

## The suite (`objstore_sink_write.sh`, step-4 arms)

Drafted in the step-3 branch and removed with a pointer here. Against the
Garage-emulating fixture and, opt-in, live Garage:

- **Per-worker objects**: `parallel_export_parquet('t', 's3://bucket/prefix', 4)`
  writes `part-0000.parquet` .. and each reads back by its exact key
  hash-equal to its row slice; the union of the four equals the source
  (read each key, not the prefix, since prefix-union is #619).
- **The multipart path exercised**: with a small `objstore_part_size`, at least
  one worker's object is multipart (create/parts/complete in the fixture log).
- **Cancel makes the dispatcher clean up its keys**: cancel the dispatcher
  mid-run (the step-1 idiom, triggered on the first part upload in the log),
  then assert the fixture log shows the dispatcher's `DELETE` calls over the
  known keys and no `part-NNNN.parquet` object remains at the prefix. Removal
  proof: neuter the remote branch of `pexport_remove_outputs` and the
  "dispatcher issued DELETE over the known keys" arm reds. That is the
  load-bearing signal, not the object count: a mid-multipart cancel completes
  no object (the in-flight multiparts are the documented lifecycle residue),
  so "zero objects remain" is a true post-condition but stays green under the
  mutation. The primitive that a `DELETE` removes a real completed object is
  already proven by #622's single-object remote-cleanup arm; #623 only proves
  the dispatcher issues those deletes over the correct key set.
- **Partitioned**: a partitioned columnar table to an `s3://` prefix writes one
  object per partition, each read back by key.

## Order of work (TDD)

1. Suite step-4 arms, RED on main (`parallel_export_parquet` to `s3://` today
   fails in `pexport_prepare_dir`'s `MakePGDirectory` on a URL).
2. `PgColumnarPathIsRemote` branch in `pexport_prepare_dir` (skip) and
   `pexport_remove_outputs` (delete known keys via `delete_object`); thread the
   count through `PexportSpawn`.
3. Green; removal proof; Garage integration arm; gates (PG17 lane, PG18/19,
   ASAN over the objstore + export suites; -Wshadow -Werror).
4. Docs: the object-storage section notes `parallel_export_parquet` to a prefix
   and the "prefix must be new or empty, not verified remotely until listing"
   caveat.
