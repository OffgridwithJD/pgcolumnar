# Issue #394: object storage writes for the export functions

Design before code. Sequenced behind #393's module (the transport, signing and
credential decisions are built once, there), but the sink seam and the failure
semantics are decidable now, and two defects found while mapping the write path
should be fixed ahead of any remote sink.

## What the write path is today (verified, main 99c6a58)

- **Parquet has a single choke point**: `PgColumnarWriteParquetFile`
  (`src/columnar_parquet.c:944-1126`) writes all data bytes for both the serial
  and the parallel exporter, through five raw `fwrite` sites (magic `:1007`,
  page header + body `:1065-1066`, footer `:1113`, footer length `:1115`,
  tail magic `:1116`).
- **Arrow is separate**: `src/columnar_arrow.c:948-1158` with its own eight
  `fwrite` sites. No shared writer abstraction exists; a byte SINK seam is
  absent on both paths.
- **Both writers are strictly append-only.** Offsets are tracked by summing
  written lengths; there is no fseek on the write path. A pure append sink
  suffices; nothing needs random access.
- **Write granularity** ranges from 4 bytes (magics, footer length) to a few
  hundred KB (a 64K-row PLAIN page). Multipart parts have a 5 MiB minimum, so
  a remote sink must staging-buffer regardless of the writer's call pattern.
- **Parallel export** (`src/columnar_parallel_export.c`): dispatcher formats
  per-worker paths `part-%04d.parquet` into DSM slots (`:594-596`), workers
  write independent files, dispatcher waits for all, and on any failure
  removes every output (`pexport_remove_outputs`, `:237-259`) and re-raises;
  a dispatcher FATAL is covered by `PG_ENSURE_ERROR_CLEANUP` (`:624`).

## Two defects to fix first, locally, before any remote sink

Both were found mapping the path and both are wrong today without any object
storage involved:

1. **`fwrite` return values are unchecked at all 13 sites.** The only error
   detection is `FreeFile(f) != 0` at close (`columnar_parquet.c:1120`,
   `columnar_arrow.c:1148`). A disk-full mid-export is detected only if the
   final flush happens to fail. The sink seam fixes this structurally: the
   sink's `write` reports short writes as errors at the call, the way the read
   seam's `pq_source_read` already treats short reads as `DATA_CORRUPTED`.
2. **Serial exports leave a partial file at the final path on error.** There
   is no temp-and-rename and no unlink-on-error (the parallel path cleans up;
   the serial paths do not). The local sink gains: write to
   `<path>.tmp.<pid>`, durable rename on success, unlink in the error path.
   This also gives the local path the same appears-whole-or-not-at-all
   property the remote path gets from multipart completion, which makes the
   documented semantics uniform.

Removal proofs: a suite that fills a small filesystem quota (or injects a
failing write via the sink's test hook) must see an error AND no file at the
final path; deleting the unlink turns the second check red; deleting the
short-write check turns the first red.

## The sink seam

`PqSink`, mirroring `PqSource` (`columnar_parquet_reader.c:1488-1553`):

    typedef struct PqSinkOps {
        const char *name;                      /* "file", "s3" */
        void (*write)(PqSink *snk, const void *buf, size_t n);  /* append */
        void (*finish)(PqSink *snk);           /* commit: rename / complete */
        void (*abort)(PqSink *snk);            /* best-effort cleanup */
    } PqSinkOps;

- Behind the existing `path` argument of `export_parquet`, `export_arrow`,
  `parallel_export_parquet`; no signature changes (the property #394 already
  identified).
- `finish` is the commit point: local rename, remote CompleteMultipartUpload.
  `abort` runs from `PG_CATCH`/resource-owner callback: local unlink, remote
  AbortMultipartUpload. The invariant both implementations share: **nothing is
  ever visible at the final name before `finish` returns.**
- The remote implementation lives in the #393 module behind a write-side ABI
  extension (`create`, `write_part`, `complete`, `abort`), staging 8 MiB parts
  (comfortably above the 5 MiB minimum). The ABI version bumps; the module has
  never shipped, so no compatibility shim is owed.

## Failure semantics, decided

- **Single-object exports**: complete-or-abort. The only path that can orphan
  a multipart upload is a backend crash between part uploads and abort; the
  documentation tells operators to set a bucket lifecycle rule for incomplete
  multipart uploads (the standard mitigation), and the abort also runs from
  the resource-owner callback so ERROR-level unwinds always clean up.
- **`parallel_export_parquet`: one object per worker**, exactly the local
  shape (`part-%04d.parquet` keys under the destination prefix). This removes
  the shared-upload-id problem entirely, as the issue thread anticipated: no
  cross-backend upload state, each worker completes or aborts its own object.
  On any worker failure the dispatcher deletes the completed objects **by
  their known keys** (the remote analogue of `pexport_remove_outputs`); no
  LIST operation is needed, so the ListObjectsV2 deferral holds.
- **Not transactional, stated in docs on day one**: an export inside a
  transaction that rolls back has already written to the bucket. The remote
  case makes visible what is already true locally.

## Privilege

The existing gate stays necessary: `pg_write_server_files` at the three entry
points (`columnar_parquet.c:1146`, `columnar_arrow.c:980`,
`columnar_parallel_export.c:466`). Remote destinations additionally require
the endpoint allow-list GUC decided in the #393 memo (empty by default,
link-local ranges refused unconditionally), because a remote write is off-box
exfiltration in a way a local write is not. The allow-list is enforced in the
module, shared by source and sink.

## Order of work

1. **Local sink seam + the two defect fixes** (short-write errors,
   temp-and-rename with unlink-on-error), serial paths first, parallel
   dispatcher unchanged. Suites: byte-identical output via the existing
   parquet/arrow export oracles, plus the two removal-proof arms. This PR is
   useful standalone and blocks on nothing.
2. Arrow and parallel writers onto the seam (parallel workers open their own
   sinks; dispatcher cleanup unchanged).
3. Remote sink in the module, single-object first, behind #393 M2 (signing);
   integration-tested against the Garage container with an injected failure
   mid-upload asserting abort ran (the arm that "leaks money and never gets
   exercised by accident").
4. Parallel-to-remote, per-worker objects, dispatcher key-wise cleanup.
