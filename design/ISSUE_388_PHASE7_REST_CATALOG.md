# Issue #388 phase 7 — Iceberg REST Catalog (read-only)

Status: DESIGN. Phases 1-6 merged (filesystem + object-storage reads, all three
delete kinds, name mapping, partition-scoped equality deletes). Phase 7 adds a
read-only Iceberg **REST Catalog** client: resolve a table by (catalog URI,
namespace, table name) over HTTP(S), obtain its current metadata location, and
read it through the existing scan path.

## What the read path already gives us (verified against current `main`)

Phase 6 already made the reader remote-capable, so the phase-7 surface is much
smaller than "an HTTP client plus a new reader". Confirmed in
`src/columnar_iceberg.c` on `main` @ e5f738f:

- `ice_slurp_text(path)` / `ice_slurp_bin(path)` dispatch to `ice_slurp_remote`
  when `PgColumnarPathIsRemote(path)` (127-175). A metadata.json at an `s3://`
  or `http(s)://` URI already slurps.
- `ice_walk_data_files(path, root, ...)` derives, for a **remote** `path`,
  `actual_root = ice_actual_location(path)` **lexically** (740-741, no
  `realpath`), and `recorded_root` from the metadata document's `location`
  (739). Recorded manifest/data/delete paths are rebased recorded_root ->
  actual_root and containment-checked in `ice_rebase` (513), including the
  percent-encoded `..` guard (`ice_has_encoded_dotdot`).
- The Parquet reader (`PgColumnarReadParquetByFieldId{,NM}`) already dispatches
  remote vs local internally.

**Therefore: handing the existing scan a remote metadata-location URI reads the
table end to end today.** For a table whose metadata-location is
`s3://bucket/wh/db/t/metadata/00003-*.metadata.json`, `ice_actual_location`
yields `s3://bucket/wh/db/t`, which equals the document's own `location`, so the
rebase is a no-op and every downstream stage (snapshot walk, deletes, projection,
name mapping, partition-scoped eq deletes) is unchanged.

Phase 7's genuinely new work is only: **(1)** an HTTP(S) client that speaks the
REST protocol subset and authenticates, reusing the objstore transport; **(2)**
parsing `loadTable` to extract the metadata-location; **(3)** new SQL entry
points that take (catalog, namespace, table) instead of a path; **(4)** the
security envelope (auth source, allow-list, SSRF, response caps).

## Architecture decision: reuse the objstore transport via an ABI v5 entry

A REST catalog is HTTP(S). Real catalogs are `https://`, which needs TLS. The
objstore module (`pgcolumnar_objstore`) exists precisely to keep OpenSSL and a
socket/TLS client **out of the preloaded postmaster** (see the header rationale).
Putting a second TLS client in the main library would defeat that. So the REST
client reuses the objstore module's transport.

The objstore ABI (v4) exposes only S3 object semantics (open-by-length + range
read, multipart sink, ListObjectsV2) and signs every request with SigV4. There
is **no** generic "GET/POST a URL with arbitrary headers, return the body" entry
and **no** bearer/`Authorization` concept. But the transport underneath
(`os_connect` -> `os_check_endpoint_allowed` + `os_addr_is_linklocal`,
`os_tls_handshake` -> strict peer/hostname verification, `os_send_all` /
`os_read_head` / `os_read_body`) is general HTTP and already hardened.

**Decision (decide-for-correctness):** extend the objstore ABI to v5 with one new
member — a generic, **unsigned** HTTP request that reuses the existing
connect/TLS/allow-list/SSRF path and lets the caller supply method, headers, and
body:

```c
/* columnar_objstore.h */
typedef struct PgColumnarHttpResult
{
    int    status;        /* HTTP status line code, or 0 if no response */
    char  *body;          /* palloc'd response body (may be NULL) */
    int64  body_len;
} PgColumnarHttpResult;

/* new ABI v5 member on PgColumnarObjStoreApi: */
PgColumnarHttpResult (*http_request)(const char *url,
                                     const char *method,     /* "GET"/"POST" */
                                     const char *const *header_lines,
                                     int nheaders,           /* full "Name: value" lines */
                                     const char *body, int64 body_len,
                                     int64 max_response);    /* hard cap; refuse past it */
```

- **No SigV4.** Auth is whatever the caller puts in `header_lines`
  (`Authorization: Bearer <token>`). SigV4 stays welded to the object entries;
  this entry is the general path.
- **Reuses the allow-list + link-local refusal for free**, because it goes
  through `os_connect`, which calls `os_check_endpoint_allowed` and
  `os_addr_is_linklocal` before any bytes move. Same SSRF boundary as data reads.
- **Reuses TLS verification** (`os_tls_handshake`); an `https` catalog on a
  non-OpenSSL build fails with the module's existing FEATURE_NOT_SUPPORTED, same
  as `https` object reads.
- **`max_response` cap** so a hostile/misbehaving catalog cannot stream an
  unbounded body into backend memory (the metadata-slurp path already caps at
  `ICE_MAX_METADATA`; this is the same discipline for the catalog reply).
- ABI bump is a mechanical additive change (new function pointer at the end,
  `PGCOLUMNAR_OBJSTORE_ABI` 4 -> 5); the loader already rejects a mismatch.

The three existing senders in the module are S3-shaped; the new entry factors the
common connect/send/receive out or adds a fourth sender that skips signing. It
must set `Host` and `Content-Length` itself, thread `CHECK_FOR_INTERRUPTS`
through the same `os_wait` path, and close the socket on any raise
(PG_TRY/PG_CATCH, mirroring the object path).

## The REST protocol subset (read-only)

Per the Apache Iceberg REST Catalog OpenAPI spec, the minimum for read:

1. `GET {base}/v1/config?warehouse={w}` — catalog configuration. Returns
   `{defaults, overrides}` and may carry a `prefix` that must be spliced into
   subsequent resource paths (`{base}/v1/{prefix}/namespaces/...`). Called once
   per catalog use. Honor `overrides` over caller values, `defaults` under them.
2. `GET {base}/v1/{prefix}/namespaces/{ns}/tables/{table}` — **loadTable**. The
   one call that matters. Response:
   `{ "metadata-location": "<uri>", "metadata": {<TableMetadata>}, "config": {...} }`.
   We take `metadata-location` (authoritative) and read from there. (We ignore
   the inline `metadata` document for now and re-slurp from metadata-location, so
   there is exactly one parse path shared with the filesystem reader; see Open
   questions for the alternative.)
3. `GET {base}/v1/{prefix}/namespaces` and
   `GET {base}/v1/{prefix}/namespaces/{ns}/tables` — listing, for the
   introspection functions.

`namespace` is dot-or-unit-separated; the REST wire form uses `%1F` (unit
separator) between multi-level namespace parts, and each path segment is
percent-encoded. Encoding the segments correctly is a correctness AND security
concern (a namespace/table containing `/` or `..` must not escape the path).

### Auth: static bearer first; OAuth2 token-exchange deferred

- **v7.0 (this increment):** a **static bearer token**, taken from the **server
  process environment** (`PGCOLUMNAR_ICEBERG_REST_TOKEN`) or a **superuser-only
  GUC**, never a SQL function argument. A token in a function argument lands in
  `pg_stat_activity`, `log_statement`, and `pg_stat_statements` in clear — the
  exact "secret in a world-readable place" failure the objstore credential model
  avoids. This mirrors the objstore **function** API (ambient env creds).
- **Deferred:** the OAuth2 client-credentials flow (`POST /v1/oauth/tokens`
  exchanging id/secret for a short-lived token) and per-catalog credentials via a
  `FOREIGN SERVER` + `USER MAPPING` (the objstore **FDW** credential model). Both
  are natural follow-ups; neither is needed to read a token-authenticated catalog.
- An **anonymous** (no-token) catalog is allowed: if no token is configured, send
  no `Authorization` header. The hermetic fixture tests both arms.

## Security model (the boundary — prove, don't trust)

1. **The catalog URI must be on `pgcolumnar.objstore_allowed_endpoints`.** Reused
   verbatim via the ABI v5 entry's `os_connect`. Empty allow-list (the default)
   refuses every catalog, same as it refuses every object endpoint.
2. **Link-local / instance-metadata refusal** applies to the catalog host too
   (reused). A catalog DNS name resolving to 169.254.x is refused across all
   returned addresses.
3. **The metadata-location and every data/manifest/delete URI the catalog hands
   back are themselves subject to the allow-list**, because reads go through the
   objstore `open()`, which runs the same checks. A catalog cannot use the
   metadata-location as an SSRF gadget to an internal host — the read refuses it.
   The containment/`..`/encoded-`..` guards from phase 6 still apply to recorded
   paths inside the manifests.
4. **The token is never logged and never a SQL argument.** It is read at request
   time from env/GUC and placed only in the outgoing header.
5. **Response size cap** on every catalog reply (`max_response`).
6. **Path-segment encoding**: namespace/table are percent-encoded per segment; a
   name containing `/`, `..`, or control characters cannot alter the request
   path. Removal-proof this with a hostile table name.
7. **TLS on by default for https**; a plain `http://` catalog is permitted only
   for the same reason object `http://` is (test/local endpoints on the
   allow-list); document that production catalogs should be `https`.

## SQL surface (proposed)

```sql
-- read a table named by the catalog (column deflist required, like iceberg_scan)
pgcolumnar.iceberg_rest_scan(catalog_uri text, namespace text, table_name text)
    RETURNS SETOF record;

-- resolve just the current metadata location (introspection / debugging)
pgcolumnar.iceberg_rest_table_location(catalog_uri text, namespace text, table_name text)
    RETURNS text;

-- listing
pgcolumnar.iceberg_rest_namespaces(catalog_uri text) RETURNS SETOF text;
pgcolumnar.iceberg_rest_tables(catalog_uri text, namespace text) RETURNS SETOF text;
```

Notes: the catalog URI is **not** a secret and is required to be allow-listed, so
it is a plain argument. The token is not an argument (see auth). `iceberg_rest_scan`
returns SETOF record and needs a column-definition list exactly like
`iceberg_scan`, and resolves each output column to a field id the same way.

## Reuse seam in `columnar_iceberg.c`

The scan body (parse -> field ids -> name mapping -> `ice_walk_data_files` pass 1
-> read deletes -> pass-2 data-file loop) is currently inlined in
`pgcolumnar_iceberg_scan` (1788-2022). Factor the portion from the `jsonb_in`
parse onward into a non-static internal:

```c
/* columnar_iceberg_internal.h (new, tiny) */
void PgColumnarIcebergScanInto(const char *metadata_uri, TupleDesc tupdesc,
                               Tuplestorestate *ts);
```

Both `pgcolumnar_iceberg_scan` (filesystem/object path) and the REST scan call
it; the filesystem SRF passes the user path, the REST SRF passes the resolved
metadata-location. The REST protocol/HTTP/JSON helpers live in a new
`src/columnar_iceberg_rest.c` exposing:

```c
char *PgColumnarIcebergRestLoadTableLocation(const char *catalog_uri,
                                             const char *ns, const char *table);
char **PgColumnarIcebergRestListNamespaces(const char *catalog_uri, int *n);
char **PgColumnarIcebergRestListTables(const char *catalog_uri, const char *ns, int *n);
```

The REST SRFs themselves live in `columnar_iceberg_rest.c` and call
`PgColumnarIcebergScanInto` for the read. JSON parsing reuses `jsonb_in` +
the existing `ice_str_required`-style accessors (factor those to non-static too,
or duplicate the couple that are needed).

## Proof plan (TDD, prove-don't-trust)

- **Hermetic REST fixture server** `test/iceberg_rest_server.py`, modeled on
  `test/objstore_http_server.py`: serves `GET /v1/config`, `/v1/namespaces`,
  `/v1/namespaces/{ns}/tables`, and `/v1/namespaces/{ns}/tables/{tbl}`
  (loadTable). loadTable returns a metadata-location pointing at the **committed
  warehouse fixtures** served over the existing S3 fixture (or `file://` for a
  first cut), and the response is generated from the fixture on disk. The server
  **verifies the `Authorization: Bearer` header** (a wrong/absent token -> 401),
  so a green read proves the C client and an independent server agree on the
  request, exactly as the SigV4 fixture proves the signer.
- **Same-oracle**: `iceberg_rest_scan` over the fixture must return the identical
  rows as `iceberg_scan` over the same warehouse's metadata.json (the filesystem
  suites' oracle). The REST layer is proven correct by returning identical rows.
- **Cross-engine oracle** (host): pyiceberg `RestCatalog` and/or DuckDB against a
  real REST catalog container (e.g. the `iceberg-rest-fixture` image) for the
  listing + loadTable responses. Integration target, not in CI.
- **Removal proofs**: (a) neuter the allow-list check reached by the ABI entry ->
  a not-allow-listed catalog must stop refusing; (b) neuter the bearer header ->
  the 401 arm goes green-wrong (proves the token is actually sent); (c) feed a
  hostile table name (`../../secret`) -> the path-encoding refuses/escapes-safely
  arm reds if encoding is removed; (d) a metadata-location pointing off the
  allow-list must be refused by the read (SSRF gadget arm); (e) response-cap arm.
- **Security arms** (SQLSTATE-asserted): catalog off allow-list -> 42501;
  link-local catalog -> 42501; missing/invalid token -> the catalog's 401 mapped
  to a clean error; token never appears in `log_statement='all'` output (grep the
  server log AND the PG log). Establish-the-secret discipline: prove the token
  is required (401 without it) before asserting it is sent correctly.
- **Gates**: PG17/18/19 + ASAN/UBSAN (a new HTTP/JSON parse path over untrusted
  input earns the sanitizer gate). Register the new suite(s) in
  `test/run_all_versions.sh` (one name per line).
- **Docs**: `docs/sql-reference.md` REST section + `CHANGELOG.md` entry; STE docs
  check must stay at 0.

## Sub-increments (one PR each)

- **7a — objstore ABI v5 generic HTTP entry + its first consumer.** Add
  `http_request` to the module, bump ABI 4->5, add the unsigned sender reusing
  connect/TLS/allow-list, response cap, PG_TRY close-on-raise. Pair it with the
  smallest real consumer that exercises the whole path from SQL:
  `iceberg_rest_table_location(catalog_uri, namespace, table_name) RETURNS text`
  (+ helper `PgColumnarIcebergRestLoadTableLocation`), which does `GET /v1/config`
  (optional) + `loadTable`, sends the env-var bearer, and returns the parsed
  `metadata-location`. Prove with a hermetic REST fixture: loadTable returns a
  location; wrong/absent token -> 401 surfaced cleanly; catalog off the
  allow-list -> 42501; link-local catalog -> 42501; response cap; no fd leak on
  mid-read raise; token absent from `log_statement='all'` and the fixture log
  when anonymous, present (as a header, never in PG logs) when set. The ABI change
  is the reviewable core; the one function makes it provable end to end.
- **7b — the read + listing.** `iceberg_rest_scan` (feeds the resolved
  metadata-location into the factored `PgColumnarIcebergScanInto`, same-oracle vs
  `iceberg_scan` over the same warehouse), `iceberg_rest_namespaces` /
  `iceberg_rest_tables` listing, cross-engine oracle (pyiceberg/DuckDB RestCatalog
  against a real REST container), full security arms, docs. Stacks on 7a.

Splitting keeps 7a's ABI change reviewable on its own; 7b focuses on the read
path and the cross-engine oracles.

## Non-goals (deferred, stated so they are not silently dropped)

- Writes / commits to a REST catalog (createTable, updateTable, transactions).
- OAuth2 token-exchange (`POST /v1/oauth/tokens`) and token refresh.
- Vended / temporary storage credentials from `loadTable.config`
  (`s3.access-key-id` etc.); phase 7 reads data with the ambient objstore creds
  and documents it. Vended creds are the natural next security increment.
- `FOREIGN SERVER` / `USER MAPPING` per-catalog credential storage.
- Anything requiring new WAL semantics (out of scope by extension constraint).
- Pruning / predicate pushdown (still needs a predicate-bearing scan node;
  `iceberg_rest_scan` is a bare SRF like `iceberg_scan`).

## Decisions (owner, phase-7 design review)

1. **Auth source: env var** `PGCOLUMNAR_ICEBERG_REST_TOKEN`, read at request time,
   never a SQL argument. The `FOREIGN SERVER` + `USER MAPPING` per-catalog
   credential model (and vended storage creds, and OAuth2 exchange) is **not**
   dropped — it is tracked as **#656** and must not be lost behind the env-var
   first cut.
2. **Metadata: re-slurp from metadata-location** — one trusted parse path shared
   with the filesystem reader. Inline-metadata optimization deferred.
3. **Staging: split 7a then 7b** — the objstore ABI v5 change is reviewed on its
   own; 7b (REST client + SQL) stacks on it.
