# Issue #656 (part 2) — Iceberg REST catalog per-catalog credentials + OAuth2

Status: DESIGN. Extends #388 phase 7 (REST catalog) and #656 part 1 (vended
storage credentials, merged #659). This part gives the REST catalog a
`FOREIGN SERVER` + `USER MAPPING` credential model, so a catalog's URI and a
per-role bearer token live in the catalog rather than a single server-wide
environment variable, and adds OAuth2 client-credentials token exchange.

## Why

Phase 7 authenticates with one static bearer token from the server environment
(`PGCOLUMNAR_ICEBERG_REST_TOKEN`) -- process-global, one token per server, no
per-role scoping. The idiomatic PostgreSQL model, which the objstore FDW already
uses for S3, is a `FOREIGN SERVER` per catalog (non-secret options) and a
`USER MAPPING` per role (the secret, stored in `pg_user_mapping`, visible only to
that role or a superuser). This brings that to the REST catalog and adds OAuth2
so a mapping can hold a client id/secret instead of a long-lived token.

## The credential template (objstore FDW, verbatim shape)

`pqfdw_objstore_config` (columnar_parquet_reader.c) is the pattern: get the
server, read non-secret options from `server->options`, probe the current role's
user mapping in the syscache (`SearchSysCache2(USERMAPPINGUSERSERVER, GetUserId(),
serverid)`, falling back to the `InvalidOid` PUBLIC mapping, without erroring when
absent), read the secret options from the mapping, enforce a credential-pairing
rule (half a credential is `28000`, never a silent fallback), and gate ambient
fallback on `superuser() || !credentials_required`. The REST bearer follows this
exactly.

## API: content-sniff, no new function names

The four REST functions keep their signatures. Their first `text` argument is
sniffed:

- Starts with `http://` or `https://` -> a catalog URI (the phase-7 form): token
  from `PGCOLUMNAR_ICEBERG_REST_TOKEN`.
- Otherwise -> a `FOREIGN SERVER` name: resolve `catalog_uri` (server option) and
  the current role's `token` (user-mapping option) from the catalog.

Two `(text, text, text)` overloads cannot coexist, so content-sniffing keeps one
function per operation and both forms working. A server name can never look like
`http(s)://` (server names are identifiers), so there is no ambiguity; a
non-URI that is not a server errors cleanly ("server does not exist").

## The FDW: `pgcolumnar_iceberg_catalog` (validator-only)

A new FDW distinct from `pgcolumnar_iceberg` (whose table holds `metadata_path`)
and `pgcolumnar_parquet`. It creates no foreign tables -- a catalog is a service
endpoint plus a per-role token -- so the wrapper needs only a `VALIDATOR`, no
`HANDLER`. `CREATE SERVER ... FOREIGN DATA WRAPPER pgcolumnar_iceberg_catalog`
gives the server OID the syscache lookup needs.

Validator arms (mirroring the parquet validator's security split):
- `ForeignServerRelationId`: accept only `catalog_uri` (srvoptions are
  world-readable, so nothing secret here).
- `UserMappingRelationId`: accept `token`, and (part 5c-2) `oauth_client_id`,
  `oauth_client_secret`, `oauth_scope`, `oauth_token_uri`, and
  `credentials_required`. Secrets live only here (`pg_user_mapping` is
  role-protected).
- Only a superuser may set `credentials_required 'false'`.

## Security invariants (unchanged from phase 7)

- The token and `oauth_client_secret` are USER MAPPING options, never SERVER
  options. The SQL call passes only a server NAME; the secret is fetched inside C
  and never becomes a SQL argument, so it does not reach `log_statement` or
  `pg_stat_activity`.
- No error message ever prints a token/secret value (the existing 401 errhint
  names the env variable, not its value; keep that).
- The OAuth2 `client_secret` goes in the POST body, never a URL query string.
- Pairing + ambient gate: `oauth_client_id` without `oauth_client_secret` (or a
  half credential) -> `28000`; ambient fallback to the env token only when
  `superuser() || !credentials_required`.
- The transport's allow-list, link-local refusal, and header CR/LF guard apply
  to every request, including the OAuth POST, unchanged.
- The `pg_read_server_files` function gate is kept for both forms in 5c-1 (every
  external read in this extension is gated on it); relaxing it for the
  server-name form (a role with its own mapping) is a documented later option,
  not silently dropped.

## OAuth2 exchange (5c-2)

Selected purely by which user-mapping options are present: if `oauth_client_id`
is set, the resolver mints a bearer via `POST {catalog}/v1/oauth/tokens` with a
form body `grant_type=client_credentials&client_id=...&client_secret=...&scope=...`
(each value percent-encoded via the existing `rest_pct_encode`), `Content-Type:
application/x-www-form-urlencoded`, parsing `{access_token, expires_in}`. This
reuses the ABI v5 `http_request` (POST + body + custom Content-Type already
supported -- no ABI bump) and `rest_json_string`. No new SQL surface. Optional:
cache the minted token per (server OID, role) honoring `expires_in`.

## Threading

`rest_get_json` and `rest_load_table_doc` gain a `const char *token` parameter
(NULL = no Authorization header) instead of reading `getenv` internally. Each SQL
function's C entry resolves `(uri, token)` up front -- from the env for the URI
form, or from `rest_resolve_server(name, &uri, &token, &allow_ambient)` for the
server form (mapping token, else OAuth mint, else gated ambient env) -- and
threads the token into the core. `rest_vended_cfg` and `PgColumnarIcebergScanInto`
are untouched (vended storage creds stay orthogonal).

## Increment split

- **5c-1** — SERVER/USER-MAPPING static bearer: the `pgcolumnar_iceberg_catalog`
  FDW (validator + wrapper), the C validator, `rest_resolve_server`, the
  content-sniff in the four functions, and the `token` parameter on
  `rest_get_json`/`rest_load_table_doc`. Static token in the mapping.
- **5c-2** — OAuth2 client-credentials exchange: validator acceptance of the
  `oauth_*` mapping options, `rest_post_form` + `rest_oauth_token`, and the
  resolver's mint branch. No new SQL.

## Proof plan

Hermetic REST fixture extended: it already verifies `Authorization: Bearer`.
5c-1: `CREATE SERVER` + `CREATE USER MAPPING` with the fixture's token; a
server-name `iceberg_rest_scan('srv', ns, tbl)` reads with the mapping token and
**no `PGCOLUMNAR_ICEBERG_REST_TOKEN` in the environment** -- proving the mapping
token, not ambient, authenticated. Arms: wrong mapping token -> 28000; a role
with no mapping and `credentials_required` -> 28000 (no ambient); the URI form
still works; the token never appears in the PG log. 5c-2: the fixture serves
`POST /v1/oauth/tokens` for a client id/secret, returns a bearer, and loadTable
then requires exactly that bearer; a wrong client secret -> 28000; the secret
never in the PG log nor the catalog request log. Removal proofs, PG17/18/19 +
ASAN, docs. STE clean.
