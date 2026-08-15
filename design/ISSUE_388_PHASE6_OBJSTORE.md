# #388 phase 6 - object storage

Phase 6 of the #388 plan is "object storage + REST catalog". This increment
delivers **object storage reads**: `iceberg_scan` (and the introspection SRFs)
read an Iceberg table whose metadata, manifests, data files, and delete files
live in object storage (`s3://`, `http(s)://`), not only the local filesystem.
The **REST catalog** is deferred to a later increment (phase 7): it is a
separate networked subsystem (a second HTTP client, OAuth2, config/prefix
negotiation, its own endpoint allow-list) and a loaded table's data still lives
in the object store, so the storage leg must be solid first regardless.

## What already works, and the two things that block it

The investigation found the Parquet **data-file** read path is already
remote-capable end to end: `PgColumnarReadParquetByFieldId`/`...NM` funnel
through `pq_source_open_cfg`, which dispatches local vs remote by URL scheme via
the `pgcolumnar_objstore` module (the #393/#394 ABI: `open`/`read`/`close`,
byte-range GETs, an endpoint allow-list). So an `s3://` data/position/equality
file is already readable once iceberg hands the reader an `s3://` string.

Iceberg is blocked in exactly two local-only spots:

1. **The metadata/manifest/manifest-list/Puffin slurps** (`ice_slurp_text`,
   `ice_slurp_bin`) use `AllocateFile`/`fread`, local only. These read the
   metadata.json, the Avro manifest list and manifests, and the Puffin
   deletion-vector files.
2. **The path boundary** `ice_open_path` is a local-filesystem construct:
   `realpath()` + symlink resolution + prefix containment. For an `s3://` path
   `realpath` returns NULL and the scan aborts before any reader runs; and the
   table's actual location is itself computed as `realpath(...)`.

## Architecture (least-invasive)

- **A scheme-dispatching slurp.** A helper reads a whole object into a palloc'd
  buffer: for a remote URL it calls the objstore ABI (`open(url, cfg, &len)` ->
  `read(h, 0, buf, len)` -> `close`), for a local path it keeps the existing
  `AllocateFile`/`fread`. `ice_slurp_text` and `ice_slurp_bin` route through it;
  the metadata cap (`ICE_MAX_METADATA`, 64 MB) still bounds the object. cfg is
  NULL (ambient environment credentials), matching the `read_parquet` function
  API contract, which is gated by `pg_read_server_files`.
- **A remote-aware boundary.** For a remote metadata path the table's actual
  location is derived from the URL lexically (`ice_actual_location`, dirname
  twice), NOT `realpath`'d. `ice_open_path` keeps its lexical `ice_rebase`
  containment (the rebased key must stay under the table location -- the same
  arbitrary-read guard that stops `<loc>EVIL/x` and `../` escapes) but skips the
  `realpath` step, which has no meaning in object storage (there are no
  symlinks). The endpoint itself is gated by the existing
  `objstore_allowed_endpoints` allow-list (superuser-only, refuses link-local /
  instance-metadata addresses), enforced inside the objstore module on `open` --
  so remote reads add no new SSRF surface.
- **Rebasing carries the rest.** The reader already re-roots each recorded path
  from the metadata's `location` onto the table's actual location (the
  relocation feature). For object storage the actual root is the `s3://`
  location the caller named; recorded paths rebase onto it, cross-scheme
  included (a table whose metadata records `file://` paths, read through an
  `s3://` mirror, resolves -- exactly the relocation case with a remote actual
  root). Real cloud tables record `s3://` paths and rebase as an identity check.
- **No change to the decode.** Manifests, snapshots, and all three delete kinds
  decode from the slurped buffers exactly as on the filesystem -- object storage
  does not alter Iceberg semantics, so every result is identical to the local
  read. The delete-file and data-file reads ride the same slurp/boundary changes
  and the already-remote Parquet reader.

## Fixtures and oracle (reuse everything; the layer must not change results)

The cleanest test exploits the rebasing: serve the committed `warehouse_del`
bytes over an S3 endpoint and point `iceberg_scan` at
`s3://bucket/.../metadata/<tag>.metadata.json`. The recorded `file://` paths
rebase onto the `s3://` actual root, so **the committed fixture bytes need no
edit**, and the expected survivors are the **same `expected_deletes.json`
oracle** the filesystem suite already uses -- the object-storage layer is proven
correct precisely by returning the identical rows. A new suite
`test/iceberg_objstore.sh` stands up the local `objstore_http_server.py` (the
hermetic endpoint the existing `objstore_s3_read.sh` uses, SigV4, driven by
`AWS_*` postmaster env and `objstore_allowed_endpoints='127.0.0.1'`), uploads
(copies) the warehouse under a bucket prefix, and runs representative arms --
a position-delete apply, an equality-delete apply, a deletion-vector apply, a
name-mapping read -- asserting the same oracles as the filesystem suites, plus
the object-storage refusals (an endpoint not on the allow-list; a key escaping
the table prefix). The garage-26-04 container is the integration target for the
host-run cross-engine oracles (DuckDB with httpfs, pyiceberg with s3fs), which
speak full S3; the in-tree suite uses the local server so it runs in CI.

Refusals kept (never a silent wrong read): a remote endpoint absent from
`objstore_allowed_endpoints` is refused by the module (the existing guard); a
recorded key that escapes the table's bucket/prefix is refused by the lexical
`ice_rebase` containment; a non-remote-capable build (the objstore module
absent) surfaces the module's clean load error, not a crash.

## Adversarial audit (3 lenses; security clean, 1 minor fixed)

The audit (security-boundary / memory / spec, each finding verified) put the
weight on the security lens, since this extends the arbitrary-read boundary to
remote. That lens found NOTHING: no SSRF (the endpoint allow-list is enforced by
the module on `open` even with cfg NULL), no containment escape (bucket-switch,
cross-scheme, trailing-slash, and `..` vectors all refused), and the local-vs-
remote decision is not bypassable. The scheme-matching concern was refuted (the
existing strcmp-over-scheme-stripped matching is correct for both schemes).

One confirmed minor finding, fixed: **`ice_slurp_remote` leaked the object-store
handle if `api->read` raised** (a short read or transport error) between `open`
and `close`. The module does not free the handle on transaction abort (it uses
explicit caller cleanup, like its sink API), so a mid-read failure leaked one fd
per failed query. Fixed with a `PG_TRY`/`PG_CATCH` that closes the handle on any
raise between open and the normal close, then re-throws. (The audit noted the
already-merged Parquet remote read path -- `pq_source` -- has the identical
leak-on-raise pattern; that is a pre-existing follow-up in a different subsystem,
not this increment.)
