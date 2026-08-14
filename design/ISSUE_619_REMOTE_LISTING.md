# Issue #619: ListObjectsV2, globs, and Hive discovery over remote paths

Design before code. Today `pq_resolve_paths` (src/columnar_parquet_reader.c)
refuses to expand a pattern or a directory over a remote URL: a remote path is an
exact key or nothing. The refusal comment names the reason precisely, "expanding
a pattern needs a LIST call, whose paged XML response is a third hand-rolled
parser over input an outside party controls, which is the shape that produced
#210 and #228." This issue adds that LIST, behind the frozen object-store ABI,
with the bounds discipline and the fuzz harness that class of parser requires.

All citations from the recon at HEAD; verify against the tree before coding.

## The parser is the whole risk

An S3 ListObjectsV2 response is XML from the endpoint. The endpoint is
allow-listed (#393, the operator authorized it), but an authorized endpoint can
still be compromised or hostile, and the response is attacker-influenceable
input. The reference for a hostile-input parser in this tree is
`src/columnar_thrift.c`: a `{buf, len, pos, error}` reader whose bound is the
overflow-safe `n > len - pos` (never `pos + n > len`, which wraps, the #210
class), which sets `error` rather than over-reading on every guard, and which
calls `check_stack_depth()` so crafted nesting is a caught ERROR, not a SIGSEGV.
The XML listing parser adopts the same discipline. It is a targeted extractor,
not a general XML parser: it pulls `<Key>`, `<IsTruncated>`, and
`<NextContinuationToken>` from a known response shape, bounds every scan, and
treats anything it does not understand as end-of-input, never as a read past the
buffer. The existing `os_reject_403` (module) already does the crudest version of
this (`strstr` for `<Code>`); the listing parser is the disciplined form.

## A new ABI op, not work above the module

Everything a LIST needs lives inside the module: the HTTP transport, SigV4
signing, TLS, the socket wait/cancel loop, the endpoint allow-list, the
link-local refusal, and credential resolution. The main library holds none of it
and cannot issue a LIST from `pq_resolve_paths`. So `list_objects` is a new op on
`PgColumnarObjStoreApi`, appended to the struct end, bumping
`PGCOLUMNAR_OBJSTORE_ABI` from 3 to 4 (the loader refuses any mismatch, so the
bump is load-bearing and both header and module move together). Shape, mirroring
the existing ops:

```
/* returns malloc/palloc'd array of nkeys cstrings, each a full s3://bucket/key
 * URL; raises on transport/parse failure; nkeys may be 0 (empty prefix). */
char **(*list_objects)(const char *url,      /* s3://bucket/prefix */
                       const PgColumnarObjStoreConfig *cfg,
                       int *nkeys);
```

Returning full `s3://bucket/key` URLs is deliberate: `pq_resolve_paths`'s remote
arm wraps them into the same `List *` of cstrings the four consumer loops
(import, read_parquet, parquet_schema, FDW Begin) already drain, and the Hive
`pqfdw_partition_values` root-prefix strip and `/`-tokenize logic transfers
unchanged. No consumer loop and no Hive code changes if the keys come back as
full URLs.

Memory: the ABI is a C boundary. The op returns `palloc`'d strings in the
caller's current context (the module already allocates handles in
TopMemoryContext and copies out; follow whichever the other ops use for
caller-owned returns). The count is explicit; the caller never scans for a NULL
terminator.

## The request and the paging loop (module-internal)

A ListObjectsV2 is `GET /{bucket}?list-type=2&prefix=<p>[&continuation-token=<t>]`.
Two module facts shape it:

1. The read signer `os_sign_request` hardcodes an empty canonical query and
   cannot sign `?list-type=2&...`. The write signer `os_sign_write` already
   folds a canonical query into the signature. So the LIST is a GET routed
   through the write-style request builder and signer, or `os_sign_request` is
   generalized to take a query. Prefer reusing `os_write_request`/`os_sign_write`
   with method GET and an empty payload: canonical-query support already exists
   and is already tested by the write path.

2. `os_resolve_s3` packs bucket+key into `h->abspath`. A LIST targets the bucket
   root (`/{bucket}`) with the prefix in the signed query, so the request target
   is the bucket, not a key. The `prefix` and the opaque `continuation-token`
   both pass through `os_uriencode_query` (where `/` is not exempt, the SigV4
   canonical-query rule), exactly as the multipart `uploadId` does.

The response body can exceed the write path's 1 MB capture cap for a large
bucket, so paging is mandatory: loop while `<IsTruncated>true</IsTruncated>`,
re-issuing with the returned `<NextContinuationToken>`, accumulating `<Key>`
values, until not truncated. Bound the loop (a max page count / max total keys)
so a hostile endpoint that always says truncated cannot make the backend spin
forever; exceeding the bound is an ERROR. `CHECK_FOR_INTERRUPTS` in the existing
wait loop already makes a single hung request cancellable; the page bound covers
the "infinite pages" shape.

## `pq_resolve_paths` remote arm

Today: remote + glob meta -> ERROR; remote plain -> exact key. New behaviour:

- Remote + a trailing-slash or glob prefix -> `list_objects(prefix)`, then filter
  the returned keys through the same `*.parquet`-extension and glob-match rules
  the local directory/glob arms use (`pq_has_parquet_ext`, and for a glob the
  pattern match), producing the sorted `List *`. A prefix that is a "directory"
  (ends in `/` or names no object) lists everything under it, at any depth, like
  the local recursive walk; a glob applies the pattern to the listed keys.
- Remote + exact key (no meta, names an object) -> unchanged, `list_make1`, no
  LIST call (the fast path stays free; a point read never lists).
- The module-absent and unsupported-scheme errors stay as they are.

Sorting: the local arms `list_sort` by string so runs are stable; the remote arm
sorts the listed keys the same way, so a directory read is deterministic across
runs regardless of the endpoint's page order.

## Hive over remote

`pqfdw_partition_values` strips the declared `root` prefix off each file path and
tokenizes the middle on `/` into `name=value` components. With the listing
yielding full `s3://bucket/prefix/dt=2026-01-01/region=eu/part-0.parquet` URLs and
the table's `path` option as the `s3://bucket/prefix` root, the strip-and-tokenize
transfers directly. Partition pruning still happens before a file is opened, so a
pruned remote file costs the LIST (already done) but no object GET. The only new
concern is that the listing must return keys with their full prefix so the root
strip matches; the op returns full URLs precisely for this.

## TDD

Against the Garage-emulating fixture (`objstore_http_server.py`), which must gain
a ListObjectsV2 handler (paged XML, continuation tokens), and opt-in live Garage.

- **RED**: on `main`, `read_parquet`/FDW over an `s3://bucket/prefix/` (directory)
  or `s3://bucket/*.parquet` (glob) raises "cannot expand a pattern" / reads
  nothing. The listing arms fail.
- **GREEN**: a prefix holding several `part-*.parquet` objects reads back as one
  relation, hash-equal to the union of the exact-key reads; a glob selects the
  matching subset; a Hive-partitioned prefix stamps the partition columns and
  prunes on a partition predicate (assert `Files Pruned` and `Files`).
- **Paging**: seed more objects than one page (fixture page size small), assert
  the full set comes back and the fixture log shows the continuation-token
  follow-up requests.
- **Removal proof**: disable the paging loop (stop after page 1) and the
  more-than-one-page arm reds (missing keys); disable the extension filter and a
  non-parquet object in the prefix reds a read.
- **The bounds fuzzer**: a new `test/fuzz_listing.sh` + corpus/mutator over valid
  ListObjectsV2 XML, deterministic `(seed, int)` mutation biased at length,
  `<Key>`, `<NextContinuationToken>`, and `<IsTruncated>` boundaries, feeding the
  parser with the property "malformed listing -> ERROR, never crash/hang/san",
  judged from the server log by byte offset, with the anti-false-green guard that
  the corpus reached the parser at all. Model: `test/fuzz_parquet.sh`.

## Gates

PG17 lane (`-Wshadow -Werror`), then PG18/19 over the objstore read + FDW suites.
ASAN (pg18_san) over the listing path and the fuzzer: a new hostile-input parser
is the exact case the ASAN gate exists for, and the fuzz corpus must run under it.
The ABI bump means the module and the main library must be built and installed
together; a stale half is a load-time WARNING and a NULL api (caught, but worth a
note in the gate).

## Order of work

1. Fixture ListObjectsV2 handler (paged), so a suite can exercise the client.
2. New ABI op in the header (bump to 4); loader unchanged except the constant.
3. Module: the bounds-disciplined XML extractor, the LIST request via the write
   signer, the paging loop, `objstore_list_objects`.
4. `pq_resolve_paths` remote arm: list + filter + sort.
5. Suite arms (RED first on main), removal proofs, the fuzzer.
6. Gates: PG17/18/19 + ASAN over the listing and the fuzzer.
7. Docs: object storage now expands a remote prefix and a remote glob, Hive works
   over a remote prefix, and the one caveat (a LIST is issued; a point read is
   still a single GET). Update the "only exact object keys work" line, which #623
   already qualified for writes, to note reads now list a prefix.
