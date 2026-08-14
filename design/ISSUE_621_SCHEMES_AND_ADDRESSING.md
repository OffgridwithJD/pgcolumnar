# Issue #621: the GCS gs:// scheme and S3 virtual-host addressing

Scope (owner decision, 2026-08-14): implement the `gs://` scheme and S3
virtual-host addressing. **Azure (`az://`) is out of scope** and stays an
unhandled scheme; it would need a SharedKey/SAS signer and new ABI credential
fields, a decision deferred.

Both features are additive to the existing S3 path and need no ABI change: GCS
reuses the SigV4 signer with a default endpoint, and the addressing style is a
GUC read inside the module, not a config-struct field.

## GCS via the interoperable XML API

`gs://` and `az://` were already recognized as remote by `PgColumnarPathIsRemote`
but rejected at the module's `objstore_handles_url`. GCS's XML API is S3-shaped
and accepts AWS Signature Version 4 with an HMAC key, so `gs://` folds onto the
existing S3 resolver:

- `objstore_handles_url` returns true for `gs://`.
- `objstore_open` / `os_write_handle` route `gs://` to `os_resolve_s3` (both
  schemes are five characters, so `url + 5` skips either).
- `os_resolve_s3` learns the scheme. When no endpoint is configured it defaults
  `gs://` to `https://storage.googleapis.com` (S3 has no single default, so it
  still requires one); when no region is configured it defaults `gs://` to
  `auto`. The signer, credentials, and request construction are unchanged: a GCS
  HMAC key is the `access_key_id` / `secret_access_key` pair, service name `s3`.

Verified against the S3 fixture (which is an independent SigV4 implementation)
and, opt-in, live Garage. Real-GCS acceptance of the `s3` service scope is the
one assumption not checkable here; it is the documented interop path.

## Virtual-host addressing

Path-style (`endpoint/bucket/key`) is the default and stays byte-identical.
Virtual-host (`bucket.endpoint/key`) is selected by the GUC
`pgcolumnar.objstore_s3_addressing = 'virtual'`, defined by the preloaded library
and read inside `os_resolve_s3` by name (the same mechanism as
`objstore_allowed_endpoints`), so no config-struct field and no ABI bump. Under
virtual-host:

- `h->host` becomes `bucket.authority` (the connect target, the Host header, and
  the TLS cert name, all of which key off `h->host` already, so cert
  verification and SNI need no change).
- the request path is the key alone, not `bucket/key`.
- `h->auth_host` carries the endpoint authority, and the endpoint allow-list
  matches `auth_host` when set: the operator authorizes the endpoint, and
  virtual-host must not force a per-bucket allow-list entry.

The allow-list, link-local refusal, and signing are otherwise unchanged.
Path-style leaves `auth_host` NULL, so the allow-list check falls back to
`h->host` exactly as before, and the existing S3 suites stay byte-identical.

## TDD

`objstore_addressing.sh`, against the SigV4 fixture:

- `gs://` reads and writes round-trip (scheme handled, HMAC creds reused, the
  signature verified by the independent implementation).
- `gs://` with no endpoint uses the storage.googleapis.com default (its error
  does not demand `AWS_ENDPOINT_URL`, the contrast that proves the default,
  where `s3://` still demands one).
- virtual-host reads the same object as path-style; the fixture log shows the
  key alone in the path under `virtual` and the bucket back in the path under
  `path` (the removal proof of the addressing switch).

Virtual-host is exercised with `/etc/hosts` names (`s3.local` and
`pgc-bucket.s3.local` both resolve to 127.0.0.1), so the client's connect, Host
header, and cert name are the real `bucket.endpoint` with no test-only code path.
The suite skips cleanly where those names do not resolve.

`objstore_module.sh`: the deliberate "unhandled scheme" probe migrates from
`gs://` (now handled) to `az://` (still unhandled).

## Gates

PG17/18/19 over the objstore suites under `-Wshadow -Werror` (the new GUC backing
variable needs an `extern` in columnar.h, which PG18/19's
`-Wmissing-variable-declarations` enforces and PG17 does not). ASAN (pg18_san)
over the gs:// read/write and virtual-host paths, which add handle-memory
allocations (`auth_host`, the virtual-host `psprintf`/`pnstrdup`): clean, zero
backend reports.

## Docs

The object-storage scheme table gains `gs://`; the addressing GUC is documented
in the configuration reference and the object-storage notes; the
`AWS_ENDPOINT_URL` row notes the GCS default.
