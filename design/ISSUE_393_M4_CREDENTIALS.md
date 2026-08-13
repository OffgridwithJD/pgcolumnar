# Issue #393 M4: the validator split and catalog credentials

Design before code. The last #393 milestone: M1-M3 (merged) read over HTTP,
sign with SigV4, and verify TLS, with every credential ambient in the
postmaster environment. M4 gives credentials a catalog home with the placement
policy the decision memo fixed, so a secret can never land world-readable and
a non-superuser can be granted remote reads without owning the postmaster's
identity.

## The placement policy (memo 3.4, enforced at DDL time)

| catalog | options | visibility |
|---|---|---|
| foreign table | `path`, `partition_columns` (unchanged) | world-readable, no secrets by construction |
| server | `endpoint`, `region` | world-readable, deliberately non-secret |
| user mapping | `access_key_id`, `secret_access_key`, `session_token`, `credentials_required` | protected (`pg_user_mapping` is not PUBLIC-readable) |

The validator rejects every option on any other catalog with
`ERRCODE_FDW_INVALID_OPTION_NAME`, so the world-readable outcome the issue
opened with is foreclosed at CREATE/ALTER time, not by documentation.

## Resolution order at scan time (FDW path)

1. The scanning user's mapping for the server, else the PUBLIC mapping,
   probed without erroring (a mapping is optional here, unlike postgres_fdw).
2. Mapping credentials present: use them. Endpoint and region come from the
   server options, else the environment (`AWS_ENDPOINT_URL`, `AWS_REGION`),
   so one server definition serves both styles.
3. No mapping credentials: **ambient is a privilege, not a default.** The
   postmaster's environment identity is used only when the caller is a
   superuser, or the applicable mapping carries `credentials_required
   'false'`. That option follows `password_required`'s shape exactly: only a
   superuser may set it to false (enforced in the validator), because it
   hands the mapped role the instance's ambient identity.
4. Otherwise: SQLSTATE 28000 naming what is missing ("no credentials in any
   user mapping for this server"), before any connection exists.

This tightens M2/M3 behaviour for non-superusers on the FDW path, which is
the point of the milestone; the merged suites all run as superuser and are
unaffected.

## The function API (`read_parquet`, `import_parquet`, `parquet_schema`)

No server object exists in those signatures, so no mapping can apply. They
keep the M2 ambient-environment behaviour behind the existing
`pg_read_server_files` gate, which the memo assessed as granting no new
capability (that role already reads any file as the postgres user). The
memo's stricter alternative (functions refuse remote schemes outright) was
not adopted: M1-M3 shipped function-path remote reads behind that role and
the suites pin them. Recorded here so the divergence from memo 3.5(a) is a
decision, not a drift.

## The ABI change

The module currently reads only the environment. Catalog config has to reach
it, so `PGCOLUMNAR_OBJSTORE_ABI` bumps to 2 and `open` gains a config struct:

    typedef struct PgColumnarObjStoreConfig {
        const char *endpoint;   /* NULL: environment */
        const char *region;     /* NULL: environment */
        const char *akid;       /* credential triple: all-or-nothing */
        const char *secret;
        const char *token;      /* optional */
        bool        allow_ambient;  /* may fall back to the environment */
    } PgColumnarObjStoreConfig;

The loader already refuses an ABI mismatch, and both sides ship in one PR.
`cfg == NULL` behaves as `{allow_ambient = true}` (the function paths).
Credential resolution inside the module stays where the 28000 messages
already live; the FDW layer only gathers catalog strings and never sees a
wire operation.

## What never happens

- No secret in any error, log line, or EXPLAIN output: messages name the
  option or variable, never its value; the suite greps the verbose error and
  EXPLAIN output for the literal secret and asserts zero.
- No secret accepted at server or table level, ever, including through
  ALTER.
- No endpoint allow-list GUC in this milestone: the memo recommends one,
  empty by default, which is a default-deny posture change that needs its
  own owner decision the way FUSE and the module split got one. Recorded on
  the issue as the follow-on question rather than smuggled in here.

## The suite: `test/objstore_credentials.sh`

Fixture: the M2 SigV4-verifying server (stdlib verifier). Postmaster started
WITHOUT any AWS_* environment for the catalog arms, so nothing ambient can
make them pass vacuously.

- **Placement arms**: each secret option on server or table errors
  `HV00D`; `endpoint` on the mapping errors; the documented placements
  succeed. `credentials_required 'false'` by a non-superuser errors; by a
  superuser succeeds.
- **Catalog-resolved credentials**: server(endpoint,region) + superuser
  mapping(key,secret,token) reads the differential oracle green with no
  environment at all - proof the catalog path reaches the wire, not env.
- **Per-user resolution**: role alice's mapping carries the good secret,
  role bob's carries a wrong one; alice reads, bob gets 28000 (the fixture
  refuses his signature), same table, same server. Both roles hold
  pg_read_server_files and SELECT, so the only variable is the mapping.
- **Ambient as privilege**: role carol (no mapping) gets 28000; after a
  superuser creates her mapping with only `credentials_required 'false'`
  and the postmaster restarts WITH the environment, carol reads. The
  superuser reads ambient with no mapping throughout.
- **No leak**: the verbose error from bob's failed read and EXPLAIN VERBOSE
  output contain zero occurrences of any secret literal.

Removal proofs: drop the superuser check on `credentials_required` in the
validator and the non-superuser-sets-false arm reds; drop the mapping lookup
and the alice/bob arms collapse to the same result (the per-user arm reds);
revert the ABI plumbing and the no-environment catalog arm reds.

## Order of work (TDD)

1. Suite, RED on main: placement arms fail (options rejected today),
   catalog-credential arms fail (no plumbing).
2. ABI v2 + module credential resolution; validator; FDW-side gathering.
3. Green; removal proofs; gates (PG17 lane, PG18/19, ASAN on objstore
   suites, -Wshadow -Werror); M1-M3 suites unregressed.
