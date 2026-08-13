# Issue #393 M2: SigV4 signing and the s3:// scheme

Design before code. M1 (merged, #605) established the transport: HTTP/1.1
ranged GET/HEAD on a nonblocking socket, request count asserted. M2 adds AWS
Signature Version 4 on the same transport and turns the `s3://` scheme on. TLS
is M3; the validator split and catalog options are M4. This milestone stores
nothing in any catalog.

## Scope

- `s3://bucket/key` reads, exact keys only (standing v1 scope), path-style
  addressing, signed GET and HEAD.
- **Endpoint from the environment**: `AWS_ENDPOINT_URL`, the SDK-standard
  variable. M2 requires it to be an `http://` endpoint; an `https://` endpoint
  errors "TLS arrives in M3" rather than silently downgrading, and an absent
  endpoint errors with the variable named. Virtual-host addressing against
  AWS's default endpoints is deferred with TLS, which it requires anyway.
- **Ambient credentials only** (the decided default): `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, optional `AWS_SESSION_TOKEN`, region from
  `AWS_REGION` else `AWS_DEFAULT_REGION`. All read from the backend's
  (postmaster-inherited) environment at open time. Missing credentials or
  region error before any connection is attempted, SQLSTATE 28000, naming the
  variable. No `credential_process`, no `~/.aws` parsing, no IMDS: those are
  the sharp edges the memo scoped out of ambient v1.

## Signing (no new dependency)

The primitives are `pg_hmac_*` and `pg_cryptohash_*`, exported on all five
majors and proven working without OpenSSL on the issue (compiled, loaded, and
checked against RFC 4231 and the AWS empty-payload constant). pgBackRest's
complete implementation is 96 lines; ours is the same shape:

- Canonical request: method; the canonical URI (our own `UriEncode` per AWS's
  explicit recommendation, two encoders, path preserves `/`; the query string
  is empty in M2 because exact-key GET/HEAD carries none); canonical headers
  `host`, `range` (GET only), `x-amz-content-sha256`, `x-amz-date`, and
  `x-amz-security-token` when a session token is present (alphabetical
  already); the signed-headers list; the empty-payload hash constant
  (`e3b0c442...`, reads send no body).
- String-to-sign over the SHA-256 of the canonical request with scope
  `date/region/s3/aws4_request`; `x-amz-date` from `pg_gmtime` +
  `pg_strftime("%Y%m%dT%H%M%SZ")`.
- Signing key derived by the four chained HMACs, cached per (day, region) for
  the handle's lifetime so per-request cost is one HMAC, the pgBackRest shape.
- The `Range` header is signed. Signing it costs nothing here (we sign per
  request, not per cached signature, so the remote-signing cache concern from
  #388 does not apply) and leaves no unsigned header a proxy could rewrite.

## The oracle strategy: two independent implementations must agree

A signer tested only against itself proves consistency, not correctness. Two
independent oracles, both asserted:

1. **The fixture verifies.** The M1 fixture server grows a SigV4-verifying
   mode: python stdlib `hmac`/`hashlib` recomputes the signature for every
   request from the same credentials and refuses 403 on mismatch. Every green
   data check in the suite then proves the C signer and an independent
   implementation agree on every byte of the canonical request. A tamper arm
   flips the fixture's secret and asserts 403 surfaces as SQLSTATE 28000 and
   zero rows: a wrong signature must never yield data.
2. **Garage, opt-in.** When `PGC_S3_INTEGRATION_ENDPOINT` (plus key/secret
   variables) is set, the same differential arm runs against a real S3
   implementation (the `garage-26-04` container on this bench). Where the
   variables are absent the arm prints a note and the fixture arm carries the
   proof alone; it is not a skip, because the self-contained arms still ran.

## Failure taxonomy (SQLSTATE-asserted, as M1)

- Missing endpoint, credentials, or region: 28000 before any connection,
  message naming the variable.
- Server 403 (bad credentials, clock skew, tamper): 28000, message carrying
  the server's error code element when present, never the credential itself.
- Bucket or key absent (404): 58P01, as M1.
- `https://` endpoint: 0A000 naming M3.
- Transport failures: 08006, unchanged from M1.

Secrets never appear in any error, log line, or EXPLAIN output: messages name
the environment variable, not its value.

## What M2 does not do

No catalog options (M4), no TLS (M3), no ListObjectsV2 or globs (standing),
no virtual-host addressing, no multi-region redirect handling (the 301
wrong-region answer errors with the region named; redirect-following is not a
read-path requirement against an explicit endpoint), no SigV4A, no chunked
upload signing (write-side, #394), no credential refresh (ambient env is
static per backend).

## Order of work (TDD)

1. Fixture server: SigV4 verification mode (stdlib only), tamper switch,
   session-token check. Suite `objstore_s3_read.sh`: premises + arms written
   against the fixture, RED on main (s3:// reports unsupported scheme today).
2. Module: URL parse for s3://, endpoint/credential resolution, UriEncode,
   the signer, wire into the M1 request path (one added Authorization header
   plus the three x-amz headers). handles_url accepts s3://.
3. Suite green; tamper, taxonomy, and token arms green; removal proofs: break
   the canonical request (drop Range from the signed set) and the fixture arm
   must go red with 403; unset the endpoint variable and the 28000 arm must
   still pass while the data arms are skipped by their premise.
4. Garage integration arm run on this bench against `pgcolumnar-test`.
5. Gates as M1: PG17 lane + PG18/19, ASAN+UBSAN on the objstore suites,
   -Wshadow -Werror.
