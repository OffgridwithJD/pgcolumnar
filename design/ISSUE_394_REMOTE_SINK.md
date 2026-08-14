# Issue #394 steps 3-4: the remote sink

Design before code. Step 1 (the local `PqSink` seam, checked writes,
temp-and-rename, #612) is merged, and #393's close delivered everything this
was sequenced behind: transport, SigV4, TLS, catalog credentials, and the
endpoint allow-list, all built once in the objstore module. This document
covers the remote implementation of the sink: single-object first (step 3),
parallel per-worker objects after (step 4).

## The ABI (bumps to 3)

Write-side operations join `PgColumnarObjStoreApi`; the module has shipped in
no release, so no compatibility shim is owed, and the loader's version check
refuses a mismatch as always:

    PgColumnarObjSink *(*sink_create)(const char *url,
                                      const PgColumnarObjStoreConfig *cfg);
    void (*sink_write)(PgColumnarObjSink *s, const void *buf, size_t n);
    void (*sink_finish)(PgColumnarObjSink *s);
    void (*sink_abort)(PgColumnarObjSink *s);     /* never raises */
    void (*delete_object)(const char *url,
                          const PgColumnarObjStoreConfig *cfg);

`PgColumnarSinkOpenLocal` grows into `PgColumnarSinkOpen(path)`: local paths
keep step 1's temp-and-rename exactly; remote paths route through the ABI.
The export functions have no server object, so remote exports run under the
M4 function-API rule: ambient credentials behind `pg_write_server_files`, the
allow-list enforced in the module on every scheme, unconditional link-local
refusal included — a remote write is off-box exfiltration, which is exactly
what the empty-by-default list exists to gate.

## S3 mechanics (single object, step 3)

- **Small objects** (buffered total under one part size): one `PUT`, no
  multipart protocol at all. This is also the whole story for most fixture
  and metadata-sized exports.
- **Large objects**: `CreateMultipartUpload` (POST `?uploads`, the UploadId
  extracted with the same bounded tag scan the 403 body uses — a tag scan,
  not a fourth parser); `UploadPart` (PUT `?partNumber=N&uploadId=...`,
  staging 8 MiB parts, ETag taken from the response HEADER, not XML);
  `CompleteMultipartUpload` (POST with the part list as XML we WRITE);
  `AbortMultipartUpload` (DELETE `?uploadId=...`).
- **The invariant is step 1's, verbatim**: nothing is ever visible at the
  final name before finish() returns. S3 gives it natively — parts are
  invisible until Complete — so local and remote expose identical semantics.
- **Signing grows two things M2 did not need**: a canonical QUERY string
  (sorted, UriEncode'd with the query variant that encodes `/`, since
  UploadIds carry base64-ish bytes), and a real payload hash per request
  (`x-amz-content-sha256` of the part body, computed with the same
  pg_cryptohash the key derivation uses; no UNSIGNED-PAYLOAD).
- **Abort discipline**: `sink_abort` runs from the exporter's PG_CATCH and
  from the module's resource-release callback, so an ERROR-level unwind
  always aborts the upload. A backend crash between part uploads cannot be
  cleaned by us: the documentation states the standard mitigation (a bucket
  lifecycle rule for incomplete multipart uploads), as the design already
  promised.

## Parallel export (step 4)

One object per worker — `part-NNNN.parquet` keys under the destination
prefix — exactly the local shape, so no shared upload id exists across
backends. Worker failure aborts its own upload through its own sink; the
dispatcher's cleanup deletes completed objects **by their known keys**
through `delete_object` (the remote `pexport_remove_outputs`), so the #619
ListObjectsV2 deferral holds. A worker the dispatcher terminates dies FATAL
without PG_CATCH — locally that orphans a temp the dispatcher unlinks; the
remote analogue is an incomplete upload, which the dispatcher cannot abort
without the worker's UploadId, so the lifecycle-rule documentation covers it
and the dispatcher deletes whatever keys DID complete.

## The fixture and the suite (`objstore_sink_write.sh`)

The fixture server grows PUT, POST, DELETE, and a faithful multipart
emulation (uploads tracked in memory: create returns an id, parts accumulate,
complete concatenates in part order, abort discards), all under the same
SigV4 stdlib verifier — so every write arm is also a cross-implementation
signature check, now including payload hashes and canonical query strings.
Request-logged like everything else.

Arms:

- **Round trip through the module both ways**: `export_parquet('t',
  's3://bucket/key')` then read back via the s3:// read path, hash-equal to
  the source; a small (single PUT) and a large (multipart) fixture, the
  multipart premise pinned by the request log showing create/parts/complete.
- **Injection**: `pgcolumnar.sink_fail_after` mid-part; the export errors
  53100, the fixture shows AbortMultipartUpload logged, the key does not
  exist, and no parts remain server-side.
- **Parallel**: `parallel_export_parquet` to an s3:// prefix; per-worker
  objects; the read path unions them hash-equal to the source; the cancel
  arm (the step-1 idiom, triggered on the fixture's first part upload)
  leaves zero completed keys, with the dispatcher's delete_object calls in
  the log.
- **Taxonomy**: allow-list refusal (42501) before any write; 403 on a wrong
  secret (28000) with zero server-side effects.
- **Garage, opt-in** (`PGC_S3_INTEGRATION_*`): the same round trip and the
  same mid-part abort against a real S3 implementation, asserting no
  incomplete upload survives (Garage lists them via its admin API).

Removal proofs: disable the abort call — the injection arm's no-parts-remain
check reds; disable the multipart threshold — the large fixture's
create/parts/complete premise reds (everything single-PUTs); disable the
dispatcher's delete_object — the parallel cancel arm's zero-keys check reds.

## Out of scope

Anything requiring LIST (#619); GCS/Azure writes (#621); retry policies
beyond the read path's single reconnect; parallelizing part uploads within
one object (workers already parallelize across objects); resumable uploads.

## Order of work (TDD)

1. Fixture multipart emulation + suite, RED on main ("writing to object
   storage is not supported" — today's sink refuses remote paths).
2. ABI v3 + module PUT/multipart + query-string canonicalization + payload
   hashes; `PgColumnarSinkOpen` dispatch. Step-3 arms green.
3. Parallel wiring (worker sinks already route through the choke point;
   dispatcher gains remote key cleanup). Step-4 arms green.
4. Removal proofs; Garage integration run; gates (PG17 lane, PG18/19, ASAN
   over the objstore + export suites; -Wshadow -Werror).
