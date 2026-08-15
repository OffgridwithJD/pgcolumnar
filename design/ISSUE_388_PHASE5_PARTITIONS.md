# #388 phase 5 - partitions

Phase 5 of the #388 plan is labelled "pruning + partition transforms". The
investigation (three parallel readers over the spec, the code, and the oracle
tooling) reshaped the scope, and this document records both the decision and
what is built.

## What is NOT built, and why (pruning is unreachable here)

`pgcolumnar.iceberg_scan` is a bare set-returning function
(`RETURNS SETOF record`, materialize mode). A query's `WHERE` clause never
reaches it: the executor materialises every row the function returns, then a
filter node applies the predicate afterward. There is no channel for a
predicate to enter the function, and there is no FDW/custom-scan node for
Iceberg (the custom scan is for native pgColumnar heap relations only).

So **partition pruning and min/max metrics pruning are impossible for this
surface** -- the function cannot know what the caller filters on, so it cannot
skip a file or row group. Building them would first require re-architecting the
read surface as a predicate-bearing scan node (a phase of its own), and only
then decoding the manifest `field_summaries` and data-file `lower_bounds`/
`upper_bounds` that the reader currently discards. Building the bucket[N]
Murmur3 transform library now would be building a hasher nothing can call with a
predicate. Pruning and the transform library are therefore deferred until, and
unless, Iceberg gets a predicate-bearing scan node.

## What IS built: partition-scoped equality deletes (a refusal becomes correct)

Phase 4b applies equality deletes written under an **unpartitioned** spec
(global) and **refuses** a partition-scoped equality delete with `0A000`,
because applying it globally would delete rows in other partitions. That leaves
a partitioned table carrying equality deletes **unreadable**. This phase applies
them correctly, scoped to their partition.

The spec rule (Scan Planning): an equality delete applies to a data file when
its data sequence number is strictly greater (4b's rule, unchanged) AND "the
data file's partition (both spec id and partition values) is equal to the
delete file's partition, OR the delete file's partition spec is unpartitioned."

The key realisation: **both** the data file's and the delete file's partition
tuples are stored in their manifests as already-**transformed** values (a
bucket field stores the int bucket, a day field stores the date, an identity
field stores the source value). Matching them is a direct comparison of the two
stored tuples -- **no transform computation, no Murmur3, no bucket math**. The
transform library pruning would need is not needed for scoping.

Neither available engine is a correct oracle for this case (verified live):
DuckDB's iceberg extension **over-deletes** -- it ignores the partition tuple
and applies a partition-scoped equality delete globally; pyiceberg refuses
equality deletes entirely. The oracle is therefore the spec, hand-derived, with
boundary fixtures and removal proofs carrying the weight the way 4b/4c did --
and the fact that the leading engine gets this wrong is the argument for doing
it, carefully.

### Architecture

- **Typed partition tuple decode.** `av_decode_partition` today renders the
  partition struct to a lossy display string (`name=value,...`, `?` for
  non-scalars, ambiguous nulls). A parallel typed decode captures each field as
  a cell: a null flag, and either an integer value (int/long/boolean/date/time/
  timestamp -- all compared as int64) or raw bytes (string/binary, Avro
  length-prefixed -- compared byte-for-byte). float/double, fixed/uuid, a
  decimal encoded as fixed rather than bytes, and any nested type make the tuple
  "incomparable". The display string is unchanged (`iceberg_data_files` uses it).
- **Carry the tuple** onto the manifest entry, then into `IceEntry`, for both
  data files and equality-delete entries.
- **Eligibility.** `ice_read_eq_deletes` stops refusing a partitioned-spec
  equality delete; it keeps the delete tagged with its spec id and partition
  tuple. In the pass-2 eligibility filter, a partitioned equality delete is
  eligible for a data file only when `E.spec_id == d.spec_id` and the two
  partition tuples are equal (element-wise, null-aware). An unpartitioned-spec
  delete stays global, exactly as 4b. The matched deletes feed the existing
  `ice_eq_probe` unchanged.
- **Conservative refusals (never silently over- or under-delete):** a
  partition-scoped delete whose spec id does not match a data file's is simply
  not eligible for that file (correct -- different partition). A delete or data
  partition tuple that is **incomparable** (a float/double cell, or a cell kind
  the decoder cannot compare) is refused `0A000` rather than guessed -- applying
  or skipping it could be wrong. A partitioned delete whose spec the metadata
  does not define stays the existing `XX001`.
- **Cross-spec-id (partition evolution).** A partitioned equality delete is
  matched only against data files of the **same** spec id, per the spec: a
  partitioned delete never crosses spec ids (partition equality requires spec id
  AND values equal). A delete whose spec id or values match no data file
  therefore applies to nothing -- a no-op, returning all rows, NOT an error.
  (The adversarial audit corrected an earlier over-strict design here: an
  intended cross-spec refusal made spec-legal tables unreadable, and the pass-2
  eligibility filter already yields the correct no-op, so the refusal was both
  redundant and wrong.) Within a snapshot where the delete's spec id matches
  some data
  other partitions. Full cross-spec partition-evolution matching is a later
  increment; refusing the unresolvable case keeps this one never silently
  wrong.

### Fixtures (hand-crafted, deterministic, additive; extend warehouse_del)

Data files under a partitioned spec (spec 1, identity(region)), each carrying a
partition tuple; equality-delete files tagged with a partition tuple. Arms:

Data: spec 1 identity(region); part-eu (ids 1,2, region eu) and part-us (ids
3,4,5, region us); grp=9 on every row so only the partition scoping, not the
value match, can distinguish partitions. The equality delete is on grp=9.

| arm | shape | expect |
|---|---|---|
| eqpart_apply | eq delete tagged region='eu' | eu rows (1,2) gone; us (3,4,5) survive |
| eqpart_nomatch | eq delete tagged region='zz', same spec | no-op, all 5 survive (no data in zz) |
| eqpart_crossspec | eq delete under spec 2, data all spec 1 | no-op, all 5 survive (never crosses spec) |
| eqpart_incomparable | a double partition cell | refused 0A000 |

The 4b `eqpart` arm (the blanket 0A000 refusal) is retired; its delete now
reaches the partitioned path and, carrying no comparable tuple, is refused for
that reason. Removal proofs: drop the partition-tuple equality check ->
eqpart_apply reds (the us rows wrongly lost, reproducing DuckDB's over-delete
bug); drop the incomparable refusal -> eqpart_incomparable reds. The value
oracle is hand-derived (no correct engine exists -- DuckDB over-deletes,
pyiceberg refuses equality deletes); the crafted partition tuples are
cross-checked structurally by decoding them back through fastavro.
