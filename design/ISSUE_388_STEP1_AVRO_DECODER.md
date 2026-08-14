# Issue #388 step 1: the Avro manifest decoder, validated and specified

The #388 review (in the issue thread) recommends building the Avro manifest
decoder first, standalone, because it is "the only part of this we have never
done": if it lands cleanly the rest of Iceberg read support is work this team has
shown it can do, and if it does not we learn that for the price of one component
instead of a subsystem.

This document does the thing the review asked to do "before committing to any of
it": **prove the premises against manifests a real Iceberg writer produced**, and
turn the plan into a precise decoder spec. It ships the committed fixtures and the
independent oracle the implementation will test against. The decoder implementation
is the next PR; it is fully specified here and de-risked by real data rather than
by the spec alone.

Everything about Iceberg below is measured from real manifests generated with
pyiceberg, not read from the format document alone, and marked as such. The plan
is followed, not restated; corrections to it are called out.

## What was generated (committed fixtures)

`test/fixtures/iceberg/gen_iceberg_fixture.py` (committed for provenance and
regeneration) writes a **format-version 2** Iceberg table with pyiceberg 0.11.1:
a schema `(id long, region string, amount int)` partitioned by `region`
(identity), with rows in two partitions (`eu` x2, `us` x3). It copies the
snapshot's manifest-list and manifest Avro files out and records an oracle:

- `test/fixtures/iceberg/manifest-0.avro` (4852 bytes) - the data manifest.
- `test/fixtures/iceberg/manifest-list.avro` (1853 bytes) - the snapshot's list.
- `test/fixtures/iceberg/expected.json` - the independent oracle: two entries,
  `region=eu record_count=2 file_size=1265`, `region=us record_count=3
  file_size=1275`, with the data-file basenames.

pyiceberg is an independent reader, so `expected.json` is a real oracle, not our
own encoder agreeing with itself, which is the property the review required.

## Premises, checked against the real files

1. **Manifests are Avro.** Confirmed: `manifest-0.avro` begins with the Avro
   object-container magic `Obj\x01`. (`grep -ri avro src/` is still empty; this
   is genuinely the one new component.)
2. **The codec matters, and it is not `null`.** Measured: pyiceberg writes the
   manifest with `avro.codec = deflate`. So **deflate is required, not optional**
   (a correction to the plan's "codecs: null at minimum, plus whichever
   compressed codec our target writers emit" - for pyiceberg the compressed one
   is not optional). Deflate is raw DEFLATE (RFC 1951), which zlib inflates with
   `windowBits = -15`. **zlib and zstd are already linked** (Makefile
   `HAVE_LIBZSTD`, and zlib for the Parquet GZIP codec), so the plan's "costs us
   nothing beyond wiring" holds.
3. **Decode against the embedded schema, not a hardcoded struct.** Confirmed
   sound and necessary: the file's `avro.schema` metadata is the full
   `manifest_entry` record, and every field carries a `field-id`. Measured
   layout (the projection targets):

   ```
   manifest_entry (record)
     status (field-id 0, int)
     snapshot_id (field-id 1, union null|long)
     sequence_number (field-id 3, union)
     file_sequence_number (field-id 4, union)
     data_file (field-id 2, record)
       content (134, int)         file_path (100, string)
       file_format (101, string)  partition (102, record { region (1000, union null|string) })
       record_count (103, long)   file_size_in_bytes (104, long)
       column_sizes (108, union)  value_counts (109, union)  null_value_counts (110, union)
       nan_value_counts (137)     lower_bounds (125)  upper_bounds (128)
       key_metadata (131)         split_offsets (132) equality_ids (135)  sort_order_id (140)
   ```

   A decoder that reads this schema and projects the fields it wants by name and
   id reads a v3 manifest (which adds fields) structurally, rather than
   misreading it as garbage. This is the plan's central design decision, and the
   real file confirms it is the right one.
4. **The fixture must be committed.** Correction/finding: neither the build
   container (`pgcolumnar-dev`) nor the Garage container has `pip`, so pyiceberg
   cannot run at test time. The manifests are therefore committed as fixtures and
   the generator is committed beside them, so the oracle is regenerable on any
   host with pyiceberg and its provenance is in the tree.

## The decoder, specified

A standalone reader in `src/columnar_avro.c` (+ `.h`), no PostgreSQL surface
beyond a single introspection entry point for the harness. House style is
`src/columnar_thrift.c`: a `{buf, len, pos, error}` reader with overflow-safe
`n > len - pos` bounds (never `pos + n > len`), and `check_stack_depth()` in the
recursive record/union/array/map descent.

**Object-container framing.** magic `Obj\x01`; a metadata map (Avro map encoding)
carrying `avro.schema` (JSON) and `avro.codec`; a 16-byte sync marker. Then data
blocks, each: object count (long), block byte length (long), the block bytes
([de]compressed per codec), and the sync marker, verified equal to the header's.

**Binary encoding** (the subset Iceberg uses): zigzag varint for int and long;
boolean as one byte; float/double little-endian; bytes and string length-prefixed;
null as zero bytes; record as its fields in order; union as a zigzag branch index
then that branch's value; array and map as counted blocks (a negative count is
followed by a block byte size, then |count| items), terminated by a zero count;
enum as an index; fixed as N raw bytes. Every field is decoded (or skipped) in
schema order because Avro is positional, even the ones not projected.

**Codec.** `null` and `deflate` (zlib raw inflate) for the first PR, because the
fixture is deflate. `zstandard` is one more `ZSTD_decompress` call, added when a
fixture emits it; noted, not built blind.

**Schema.** Parse `avro.schema` with PostgreSQL's `jsonapi` (the in-tree JSON
parser), building a small schema tree; no new JSON parser. Project the manifest
fields by name and `field-id`.

**Introspection harness.** One SRF, `pgcolumnar.read_avro_manifest(path)`,
returning a row per manifest entry (status, file_path, file_format, content,
record_count, file_size_in_bytes, partition as text). It reads the file through
the existing byte source, so it works on a local path today and an `s3://` object
behind #393. This is the smallest surface that lets a shell suite compare the
decode against `expected.json`; it is also the first useful Iceberg introspection.

## Test plan (the next PR)

- **Oracle suite** `test/avro_manifest.sh`: decode the committed `manifest-0.avro`
  and assert the entry count, and per entry the `record_count`, `file_size`,
  `partition.region` and file basename against `expected.json`. RED on `main`
  (no decoder / no function). The independent writer (pyiceberg) is the oracle,
  the same shape as the pyarrow cross-check in the Parquet suites.
- **Fuzz** `test/fuzz_avro.sh` + a deterministic `(seed, int)` mutator over the
  real manifest: property "a malformed manifest raises an ERROR, never crashes,
  hangs, or trips a sanitizer". This is a decoder over bytes we did not write,
  the category that produced #210 and #228, so it earns the fuzzer and the
  `check_stack_depth` guard from day one.
- **Gates**: PG17/18/19 under `-Wshadow -Werror`; ASAN (pg18_san) over the decode
  and the fuzz corpus, which is the gate a hostile-input decoder must pass.

## Scope of the first implementation PR, and what follows

First PR (step 1 core): the object-container reader, the binary decoder, the
`null`/`deflate` codecs, `jsonapi` schema handling, schema-driven projection of
the **data manifest** (`manifest-0.avro`), the introspection SRF, the oracle
suite, the fuzzer, and the gates. It answers the review's question - can we read
the metadata layer of a real Iceberg table at all, without a network and without
a new language toolchain - with a yes backed by a real file.

Deferred, in order, each its own step behind this one:

- the **manifest-list** decode (same machinery, a different embedded schema); the
  fixture is already committed (`manifest-list.avro`).
- a **v3** fixture and its assertions, once a v3 writer is available; the
  schema-driven design means v3 is a fixture-and-test task, not a decoder rewrite.
- `zstandard` codec, when a fixture emits it.
- **field-id projection through the Parquet reader** (plan step 2), **filesystem
  catalog / current snapshot** (step 3), and **deletes** (step 4). Deletes are
  explicitly not shipped alongside a plain reader: a reader that silently drops
  deletes looks finished and is wrong, the failure this project keeps deciding
  not to ship.

## Plan validation: verdict

The plan is sound and its phase order holds. The Avro decoder is a bounded job of
a shape this codebase has done before (the Thrift decoder), the schema-driven
decision is confirmed necessary by the real file's `field-id`-bearing schema, and
the codecs it needs are already linked. Two corrections, both from the real data:
**deflate is required, not an optional add-on** (pyiceberg's default), and the
**fixtures must be committed** because the test hosts have no pyiceberg. Neither
changes the shape of the work; both are now handled in the tree.
