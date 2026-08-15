# Issue #656 (part 1) — Iceberg REST catalog vended storage credentials

Status: DESIGN. Extends #388 phase 7 (REST catalog read, merged #657/#658).
Tracked under #656 (the credential-model follow-up). This part delivers **vended
credentials**: reading a REST-cataloged table's data with the short-lived,
scoped storage credentials the catalog issues, instead of the ambient
server-environment credentials phase 7 falls back to.

## Why this is the next increment

Phase 7 reads a REST-cataloged table's data files with the **ambient** objstore
credentials (`AWS_*` in the server environment), documented as a deliberate
first-cut limitation. That works for a single-tenant server whose environment
holds credentials for the bucket, but it is exactly what a real REST catalog
exists to avoid: the catalog issues **per-table, short-lived, least-privilege**
credentials at `loadTable` time, so a reader never needs standing bucket
credentials in its environment. Without vended credentials, the REST catalog
support cannot read a table in a cloud account the server has no ambient
credentials for, which is the common deployment.

## The Iceberg REST vended-credential shapes

`loadTable` (and `loadCredentials`) responses can carry storage credentials two
ways (both in the OpenAPI spec):

1. **Flat `config` map** (Tabular/Polaris style), keys the client reads:
   - `s3.access-key-id`, `s3.secret-access-key`, `s3.session-token`
   - `s3.region` (or `client.region`), `s3.endpoint`
   These are the SigV4 credential triple plus endpoint/region. The client signs
   its own S3 requests with them (vended credentials do NOT remove SigV4; only
   the separate remote-signing mode does, which is out of scope).

2. **`storage-credentials` array** (newer spec): `[{ "prefix": "s3://bucket/db/t",
   "config": { "s3.access-key-id": ..., ... } }]` — per-prefix credentials, so a
   table spanning locations can carry more than one. The client picks the entry
   whose `prefix` is the longest match for the file being read.

Scope for this increment: support **both**, preferring `storage-credentials`
(longest-prefix match) and falling back to the flat `config` keys. A location
matched by neither, on a table that vended any credentials, is read with the
matched/flat vended set; a table that vended nothing keeps the phase-7 ambient
behavior.

## Credential model and security

- Build a `PgColumnarObjStoreConfig` from the vended keys:
  `endpoint = s3.endpoint`, `region = s3.region|client.region`,
  `akid = s3.access-key-id`, `secret = s3.secret-access-key`,
  `token = s3.session-token`, **`allow_ambient = false`**.
- `allow_ambient = false` is deliberate: once a catalog vends credentials, a
  data read must use them, never silently fall back to the server's ambient
  identity (that would broaden access beyond what the catalog scoped, and hide a
  misconfiguration). A table that vends **no** credentials passes `cfg = NULL`,
  which is the existing ambient path.
- The vended secret lives only in backend memory for the duration of the scan,
  is never logged (the objstore module already keeps `cfg->secret` out of every
  error message), and never crosses into the catalog request log. It arrives
  over the already-authenticated, allow-listed catalog connection.
- The **endpoint the vended creds point at is still subject to the allow-list**:
  the objstore `open()` runs `os_check_endpoint_allowed` + the link-local
  refusal regardless of `cfg`, so a catalog cannot vend credentials for an
  internal host and have the reader connect to it. Vended creds change *who* the
  request is signed as, never *whether the endpoint is allowed*.

## The threading problem (crux — finalize against the seam investigation)

Today `PgColumnarIcebergScanInto` and `ice_slurp_remote` reach the objstore
`open()` with `cfg = NULL`. Vended credentials require a caller-supplied
`const PgColumnarObjStoreConfig *` to flow from the REST scan down to every
objstore `open()` for that table's metadata, manifests, data, and delete files.

Seam investigation result: the objstore `open()`/`list_objects()` already take a
`cfg`; the two internal helpers `pq_source_open_cfg` and `pq_resolve_paths`
already thread it, and the FDW already passes a non-NULL `st->oscfg` through
them. But the **public parquet entries and the iceberg slurp helpers have no
`cfg` parameter at all** — every iceberg remote read is hardwired to NULL. So the
change is purely additive threading:

- Carry one `const PgColumnarObjStoreConfig *cfg` on **`IceScanCtx`**, set once in
  `PgColumnarIcebergScanInto`. It already reaches every delete/data reader via
  `ctx`/`c`, so only the leaf calls change.
- Add a trailing `cfg` param to: `PgColumnarReadParquetByFieldId` and
  `...NM` (down through `pq_read_file_into` to `pq_source_open_cfg`, replacing the
  hardwired-NULL `pq_source_open`); and to `ice_slurp_remote` / `ice_slurp_text` /
  `ice_slurp_bin` / `ice_walk_data_files` (down to `ice_slurp_remote`'s
  `api->open`).
- Add a trailing `cfg` param to `PgColumnarIcebergScanInto`.
- **Every existing caller passes `NULL`**: the filesystem `iceberg_scan`,
  `iceberg_current_snapshot`, `iceberg_data_files`, `read_parquet`, and any native
  reader — byte-identical ambient behavior, proven by the existing suites. The
  FDW is untouched (separate route). Only `iceberg_rest_scan` passes a real cfg.

Header note: `columnar_parquet_reader.h` includes `columnar_objstore.h` for the
`PgColumnarObjStoreConfig` type.

**Single table-wide cfg (this increment).** The cfg is resolved once from the
`loadTable` reply: prefer the `storage-credentials` entry whose `prefix` is the
longest match for the table's metadata-location, else the flat `config` keys.
Per-file multiple-credential resolution (a table whose files span locations with
different vended sets) is rare and deferred; the best-matching single set is used
table-wide and the limitation is documented.

## SQL surface

No new SQL functions. `iceberg_rest_scan` transparently uses vended credentials
when the catalog issues them; the behavior change is that a table the ambient
environment could not read now reads when the catalog vends credentials for it.

## Proof plan (TDD, prove-don't-trust)

- **Hermetic S3 + REST fixtures together**: the REST fixture's `loadTable`
  returns a metadata-location on the **S3 fixture** (`objstore_http_server.py`
  with SigV4 verification) AND a `config`/`storage-credentials` block naming the
  fixture's key id / secret / region. The postmaster environment holds **no**
  `AWS_*` credentials (or wrong ones), so a green read PROVES the data was
  signed with the **vended** credentials, not ambient — the SigV4 fixture
  verifies every signature against the vended secret.
- **Removal proof**: with the vended-cred threading neutered (pass `cfg = NULL`),
  the read must fail (the ambient environment has no/creds-wrong), reddening the
  arm — proving the vended path is load-bearing, not masked by ambient.
- **Negative arm**: a table that vends a WRONG secret -> the S3 fixture 403s ->
  a clean error (not a crash, not an ambient fallback). Establishes that a
  present-but-wrong vended credential is used and refused, not bypassed.
- **Ambient-still-works arm**: a table that vends nothing, with ambient creds in
  the environment, still reads (phase-7 behavior preserved, `cfg = NULL`).
- **`storage-credentials` longest-prefix** arm: two entries, the more specific
  one selected for the data file's prefix.
- **Allow-list still applies**: vended creds for an endpoint off
  `objstore_allowed_endpoints` -> 42501 (the boundary is independent of cfg).
- Gates: PG17/18/19 + `pg18_san` ASAN (new untrusted-JSON parse of the config +
  a credential-lifetime path). Docs: sql-reference note + CHANGELOG. STE clean.

## Non-goals (still deferred, tracked in #656)

- OAuth2 client-credentials token exchange (`POST /v1/oauth/tokens`) + refresh.
- Per-catalog `FOREIGN SERVER` + `USER MAPPING` credential storage (this
  increment keeps the env-var bearer for the *catalog* auth; it vends *storage*
  creds from the catalog reply).
- Remote request signing (`s3.remote-signing-enabled`) — the catalog signs each
  request; a distinct mechanism from vended creds.
- Refresh of an expired vended credential mid-scan (a scan is short; re-issue on
  the next call). Documented, not handled.
