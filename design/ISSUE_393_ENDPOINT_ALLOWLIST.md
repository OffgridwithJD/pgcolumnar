# Issue #393: the endpoint allow-list, empty by default

Owner-decided 2026-08-13 (recorded on the issue): remote object-storage access
is gated by `pgcolumnar.objstore_allowed_endpoints`, empty by default, with
link-local ranges refused unconditionally. This document pins the enforcement
semantics; the decision itself is not reopened.

## The GUC

- `pgcolumnar.objstore_allowed_endpoints`, string, default `''`, **PGC_SUSET**.
  Superuser-only is load-bearing, not convention: a USERSET list would let any
  role widen its own allow-list mid-session, which is the exact privilege the
  list exists to withhold. Defined by the preloaded library (the module cannot
  define it: `MarkGUCPrefixReserved` refuses placeholder GUCs, and the module
  loads after configuration parsing); the module reads it with
  `GetConfigOption`, so no cross-library symbol exists.
- Format: comma-separated `host` or `host:port` entries. An entry without a
  port matches any port on that host; matching is a case-insensitive string
  comparison against the endpoint host the connection will use (the URL
  authority, or the resolved `AWS_ENDPOINT_URL`/server-option endpoint for
  s3://). Entries are what the operator wrote, compared before DNS: the list
  authorizes names, and pinning games with resolution are handled by the
  link-local check below, which runs after resolution.

## Enforcement, in the module, on every scheme

1. **Allow-list check before any resolution or connection.** The endpoint
   host:port not matching any entry is SQLSTATE 42501 naming the GUC. Empty
   list, empty match: all remote refused. Local paths never consult it.
2. **Link-local refusal after resolution, unconditional.** If ANY address
   getaddrinfo returns for the endpoint is in 169.254.0.0/16 or fe80::/10
   (including v4-mapped forms), the connection is refused 42501 with a message
   naming the range, whether or not the list contains the entry. Refusing the
   whole connection, rather than skipping the offending address, prevents a
   resolver that returns a mixed set from steering the choice. This is the
   cloud-metadata (IMDS) credential-theft path; it has no legitimate
   object-storage use. Loopback stays allowed: a trusted-network MinIO on
   127.0.0.1 is a documented legitimate configuration and every suite uses it.

Order relative to existing errors: credential and endpoint resolution (28000)
precede the connection, so those messages are unchanged; the allow-list is the
last gate before the socket.

## Suite: `test/objstore_allowlist.sh`

- RED lead: with the default empty list, http://, https://, and s3:// reads
  all refuse 42501 naming the GUC (today they succeed).
- Allowed: `127.0.0.1` entry admits the fixture; a `127.0.0.2` entry does
  not; `127.0.0.1:<port>` admits only that port, the wrong port refuses.
- SUSET: a non-superuser SET fails (core's 42501), premise-guarded by the
  role's own session.
- Link-local: with `169.254.169.254` explicitly IN the list, a read against
  it still refuses 42501 before any connection exists (asserted by SQLSTATE:
  a connect attempt would be 08006 or a timeout).
- Existing objstore suites gain the conf line
  (`pgcolumnar.objstore_allowed_endpoints='127.0.0.1'` via PGC_EXTRA_CONF),
  which doubles as the documented configuration example;
  objstore_module's remote-error grep accepts the new refusal.

Removal proofs: delete the allow-list check and the deny-by-default arms red;
delete the link-local check and the IMDS arm reds (whatever a real connect
attempt produces, it is not 42501-before-connection).
