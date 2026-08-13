# Issue #393 M1: the HTTP ranged byte source and the asserted request count

Design before code, per the house rule. This implements milestone M1 of the plan
of record decided on #393 (2026-08-06): plain-HTTP range GET in the separate
non-preloaded module, no TLS, no signing, exact object keys only. The M1/M2 test
spec posted on the issue (request count asserted, not reported) is the
verification contract; this doc turns it into arithmetic against the current
tree.

## What already exists on main (verified, 99c6a58)

The seam and the module scaffolding landed ahead of this work:

- `PqSourceOps` vtable, never NULL, every byte read through the dispatcher
  (`src/columnar_parquet_reader.c:1488-1560`). Byte reads outside
  `pq_source_read`: none.
- Scheme detection in `pq_source_open` (`:1597`) via `PgColumnarPathIsRemote`
  (`src/columnar_objstore.c:46-58`), glob refusal for remote paths in
  `pq_resolve_paths` (`:2655-2673`).
- The loader: `PgColumnarObjStoreGet()` dlopens `$libdir/pgcolumnar_objstore`
  via `load_external_function`, distinguishes missing from broken module,
  checks `abi_version` (`src/columnar_objstore.c:60-169`,
  `PGCOLUMNAR_OBJSTORE_ABI = 1`).
- The module skeleton: `objstore/columnar_objstore_module.c`, built as a second
  `MODULE_big` through the recursive-make hooks (`Makefile:122-145`), with
  `test/objstore_module.sh` pinning the separation.
- The remote branch of `pq_source_open` errors "object storage is not
  implemented yet" (`:1618-1620`). M1 replaces that error with a working
  source.

The ABI already carries what M1 needs: `PgColumnarObjStoreApi.open` returns the
object length through `int64 *len` (`src/columnar_objstore.h:57`), which fills
the one hole in `PqSource` (its `len` is established by `ftello` today, local
only, `:1629`).

## The request-count problem, measured against the tree

Today's read granularity is per page, two `pq_source_read` calls each: a 4 KB
header window (`pq_read_page_header`, `:1726`) and the page body (`:1827`),
plus 3 open-time reads (head magic, tail 8, footer). Mapped 1:1 onto HTTP this
is the 521-request shape the issue predicts. Two changes bound it:

1. **A prefetch window above the ABI.** `pq_source_prefetch(src, off, n)`:
   issues ONE `ops->read` for the range, stores it in `src->winbuf`;
   `pq_source_read` serves any request inside the window from memory and falls
   through to `ops->read` otherwise. Transport-agnostic, no ABI change, a no-op
   in effect for local files (the window is served by one fread instead of
   many, same bytes).
2. **Prefetch call sites.** `decode_leaf_entries` prefetches the whole column
   chunk extent (known from the footer: chunk offset and
   `total_compressed_size`) before walking its pages. `pq_source_open`
   prefetches nothing in M1: the three open reads stay individual requests, so
   the arithmetic below stays exact and simple. Coalescing the open (a
   speculative tail read) is a later, measured refinement.

### The arithmetic the suite asserts

For a fixture with G row groups and C needed leaf columns per group, all chunks
resident (no group skipping):

- **Buffered (default):** `K = 1 (HEAD for length) + 3 (magic, tail, footer) +
  G x C (one ranged GET per needed chunk)`.
- **Unbuffered (dev GUC off):** `>= 1 + 3 + G x C x 2 x P` where P is pages
  per chunk. The fixture sets a small pyarrow `data_page_size` so P makes the
  unbuffered arm at least 10x K.

The dev GUC is `pgcolumnar.objstore_buffered` (bool, default on), defined with
the other GUCs in `src/columnar_tableam.c`. It exists so the suite measures
both arms in one run, which is what makes K falsifiable rather than
implementation-defined. Removal proof: with buffering forced off, the buffered
arm's `check_num <= K` must go red.

## The module's HTTP client

Hand-written HTTP/1.1, GET and HEAD only, over a nonblocking TCP socket driven
from a `WaitEventSet`, per the plan of record. Rules that are constraints, not
preferences:

- **No blocking syscall on the socket, ever.** `SA_RESTART` makes the EINTR
  idiom unreachable (the tree already documents this failure shape at
  `src/columnar_parquet_reader.c:2368-2372` for FIFOs). Every wait is
  `WaitLatchOrSocket(MyLatch, WL_LATCH_SET | WL_SOCKET_READABLE | ...,
  timeout)` followed by `CHECK_FOR_INTERRUPTS()`. This is what makes assertion
  (c) below passable at all.
- **Both framings.** Content-Length and chunked transfer coding are both
  implemented from the start; S3-compatible servers answer XML errors chunked.
- **Range contract.** Requests send `Range: bytes=off-(off+n-1)` and require
  status 206 with the exact byte count. A 200 answer (server ignored Range) is
  an error naming the URL, never a silent whole-object read: arm C of the test
  spec, wrong answers are worse than failures.
- **Bounded header parse.** Response head capped (16 KB), parsed with explicit
  bounds; the fuzz-harness obligation for this parser is M1 scope creep and is
  deferred to the pre-release gate recorded on the issue (the parser fuzz
  harness ships before any release, in the `fuzz_parquet.sh` idiom).
- **One reconnect.** A cleanly closed idle connection is retried once;
  anything else is an error. Retries with backoff are M2+ scope per the issue.
- **Errors carry the URL and the HTTP status**, and never any header a future
  signed request would carry.

Connection state lives in `src->priv` (one struct per open source: fd, parsed
endpoint, keep-alive state). One connection per source, reused across ranged
GETs; `close` op shuts it down. `PG_TRY` is not needed inside the module; the
fd is registered with the resource owner (`ReserveExternalFD` shape) so an
`ereport` unwinding the scan cannot leak it.

## The suite: `test/objstore_http_read.sh`

Follows the current suite idiom (`lib.sh`, registered in the sorted `SUITES`
array, chained teardown trap per the objstore_module.sh precedent). Fixture
server: a python3 stdlib HTTP server (no new dependency; pyarrow is already
the oracle toolchain) that serves byte ranges and appends one line per request
(`method path range-header`) to a log file; a flagged URL prefix stalls
mid-body without closing, for the cancel arm.

Arms, per the test spec on the issue:

- **A, differential oracle:** a table over
  `http://127.0.0.1:PORT/x.parquet` returns the same rows as the byte-identical
  local file (`pgc_set_hash` comparison), for `count(*)`, a full projection,
  and a two-of-N projection.
- **B, request count:** premise: remote arm rows match local (A); premise: the
  server logged at least one request. `check_num` buffered requests `<= K`
  with K stated as the arithmetic above; `check_num` unbuffered `>= 10 * K`;
  `check_ratio` unbuffered/buffered `>= 10` (the #418 zero-refusal makes an
  empty log fail loudly).
- **C, failure taxonomy:** unreachable port, 404, and a Range-ignoring server
  each produce an error that names the URL; none produces rows. Asserted on
  SQLSTATE class, not message grep, where a distinct code exists.
- **D, cancel:** `statement_timeout` fires within bound while the server
  stalls mid-body (idiom of `test/cancel_decode.sh`). Removal proof: with the
  `WaitLatchOrSocket` timeout arm deleted, this check must hang or go red.

## Deliberately out of M1

TLS (M3), SigV4 (M2), credentials and the validator split (M4), redirects,
retries beyond one reconnect, ListObjectsV2 and globs (deferred by the plan of
record), FDW streaming (a follow-on the tree already documents at `:3348`),
and any change to the eager tuplestore shape. The Garage container
(`garage-26-04`, see #393 comment of 2026-08-13) becomes the integration
target at M2 when signing exists; M1's fixture is the local logging server
precisely so the request log is assertable.

## Order of work (TDD)

1. Suite skeleton with the fixture server, arms A and C against the LOCAL file
   path only, green, to prove the fixture and oracle.
2. RED: point arm A at `http://127.0.0.1` and watch it fail with today's
   "not implemented yet" error.
3. Module HTTP client + wire the remote branch of `pq_source_open` (len from
   `api->open`, reads through the ABI). Arm A and C green, B red (no
   buffering: the count blows K).
4. The prefetch window + GUC. B green. D green with the stall fixture.
5. `-Wshadow -Werror` clean, ASAN+UBSAN run of the suite (network parser =
   memory-lifecycle change, the #asan-gate rule applies), PG17 lane first,
   then PG18/19 per the cadence.
