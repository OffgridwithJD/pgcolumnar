# Issue #403 items 3 to 7: plan

Issue #403 recorded seven opportunities read out of the ClickHouse VLDB 2024
paper. Items 1 and 2 were broken out and shipped (#739 preimage rewriting, #744
zone-map read session). Items 3 to 7 were left recorded, on the issue's own
instruction, "until something makes one of them urgent".

This plan covers all five. Written 2026-08-28.

## Goal

Implement items 3, 4, 6 and 7, and the part of item 5 that fits inside the
storage model we have. Produce a design document, not an implementation, for the
part of item 5 that does not.

## Non-goals

- Items 1 and 2. Both shipped.
- Changing WAL semantics. The extension may use core WAL mechanisms and existing
  record types only. This bounds item 5 and is the reason item 5 splits in two.
- A new benchmark suite. #401 and #402 own the join and benchmark gap.

## Current state, established by reading the tree

Every claim below was checked against the code on `main` at `35846a1`, not
recalled.

| Item | What exists now | Evidence |
| --- | --- | --- |
| 3 set index | bloom filters and min/max zone maps, nothing between them | `src/columnar_bloom.c` (`PgColumnarBloomBuild`, `PgColumnarBloomProbe`); catalog tables `pgcolumnar.bloom`, `pgcolumnar.zone_map` |
| 4 filter order | predicates evaluated in ScanKey order, first exclusion wins | `columnar_reader.c:1399` and `:1745`, both `for (p = 0; p < rs->numPredicates; p++)` with an early break |
| 5 merge-time work | nothing. No TTL, retention or tiering notion anywhere | `grep -riE '\bttl\b|retention|tier' src/ docs/` returns two unrelated comments |
| 6 hash sizing | our own open-addressing table, grown on demand from capacity 0 | `columnar_vector.c:4459` `state->capacity = 0`, grow at 70% load `:4820`, `pgcolumnar_groupagg_grow` `:4753` |
| 7 idempotent insert | nothing. No dedup or content hash on the write path | `grep -rniE 'idempot|dedup' src/` finds only unrelated uses |

Two structural facts that shape the ordering:

- **A new skip-index kind needs a new catalog table**, and a new catalog table
  needs an `ALTER EXTENSION` upgrade script. That script does not exist. #761 is
  already parked waiting for the same script, and the owner's answer on
  2026-08-27 was to clear the board before opening the alpha3 cycle.
- **Native row-group bytes live in the relation's main fork**, reached through
  one function each way: `PgColumnarReadLogicalData` (5 call sites) and
  `PgColumnarWriteLogicalData` (2 call sites), over `smgr` and the buffer
  manager. That is a real seam for tiering. It is also the reason tiering is not
  a small change: bytes outside the storage manager are outside crash recovery.

## Outcome, 2026-08-28

The plan is kept as written above, and this section records where each item
actually landed. Two changed shape once measured, which is what the phases were
ordered to find out early.

| Item | Outcome |
| --- | --- |
| 6, hash table sizing | Merged, #810. Corrected on review: sizing at Begin allocated 131,072 entries for 47 real groups, so it now happens on the first grow and a grow is bounded by 64x the live count. |
| 4, filter ordering | Merged, #811. The defect was worse than the issue described: the order was ATTRIBUTE order, and writing the selective predicate first in the query did not change it. 200 zone-map probes to 102. |
| 3, set skipping index | **Not built. Measured and not justified.** On the shape #403 names, `os` and `arch` hold every distinct value in every row group, so a set index stores the whole domain and prunes nothing; the clumped columns are contiguous in sort order, where min/max is already exact. The `<>` pushdown proposed in its place was withdrawn after measurement too: the ceiling is freq(v), and sorting already achieves 90% of that bound. |
| 7, idempotent inserts | PR #814. Whole-load fingerprint, not part hashes, because 2PC makes the load atomic. Opt-in, as decided. |
| 5a, TTL | PR #815. `pgcolumnar.expire`, explicit rather than folded into a rewrite. |
| 5b, tiering | **Rejected, not deferred.** design/OBJECT_STORAGE_TIERING.md. It removes columnar tables from physical replication, which is their only supported replication path, and keeping replication would need a new WAL record type the extension may not add. |

Phase 3, the alpha3 cycle, was opened and merged as #812, carrying #761.

## Phases, in dependency order

### Phase 1: item 6, size the group hash table from runtime statistics

The grouped aggregate builds its own table and grows it on demand from nothing.
The paper's point is that the resizes are avoidable when something already knows
the answer.

We have three candidate sources, in increasing order of trust: the plan-time
`estimate_num_groups` value (`columnar_vector.c:1796`, already bounded by #369),
the zone map's per-chunk `value_count` and `null_count`, and the bloom filter's
`bloom_distinct_estimate`, which is a distinct-count estimate we already compute
and then throw away.

- **Verification.** An instrumented build counting calls to
  `pgcolumnar_groupagg_grow` per query. RED first: a fixture whose group count is
  known, showing N resizes today. Then the same fixture showing the target count,
  with a removal proof that reverting the sizing restores N.
- **The trap to avoid.** A saving must be measured as work removed, not as a
  number derived from the estimate that drives it. Count the resizes, not the
  predicted capacity.

### Phase 2: item 4, evaluate filters in descending selectivity order

Predicates are tried in ScanKey order, and the loop breaks on the first
exclusion. Which predicate comes first therefore decides how many zone maps get
read, because each predicate's first use fetches that column's zone map from the
catalog.

The paper's own caveat is part of the item: apply the ordering only when at least
one predicate is highly selective, or latency gets worse than evaluating all of
them.

- **Verification.** Zone-map catalog reads per scan, and chunk groups examined,
  on a fixture with one selective and one unselective predicate in the unhelpful
  order. Both numbers must fall, and the answer must not change. The
  answer-invariance arm matters more than the saving: this reorders evaluation of
  a conjunction, so a bug here is a wrong answer, not a slow one.
- **Note.** The planner prices the same predicates through
  `pgcolumnar_make_predicates` (#461). If ordering changes what is pruned, the
  planner and the executor must still agree, or a plan is priced for a saving it
  does not take.

### Phase 3: open the alpha3 extension cycle

A dependency, not a feature. Phases 4 and 5 both add catalog objects, and neither
can ship without an upgrade script.

- Carries #761 (`sort_status` cannot report `sorted_kind`), which is parked on
  exactly this and needs `DROP FUNCTION` plus `CREATE FUNCTION` for the signature
  change.
- **Verification.** The release playbook already covers this: generate the
  upgrade script from a catalog delta, and gate on definition, ACL and comment
  convergence between a fresh install and an upgraded one.

### Phase 4: item 3, set skipping indices

An exact set of the distinct values in a chunk group, for low-cardinality clumped
columns. It sits between the zone map and the bloom filter: exact rather than
probabilistic, and able to answer negative and `IN` predicates that a bloom
filter cannot.

- Follows the bloom filter's shape exactly: a build in the write path, a probe in
  `pgcolumnar_native_group_can_match`, a catalog table beside `pgcolumnar.bloom`,
  and a planner-side selectivity contribution.
- Needs a bound on when to keep the set: above some distinct count it is larger
  than the data it describes and must be dropped rather than stored.
- **Verification.** Groups skipped, for a negative and an `IN` predicate that
  the bloom filter cannot answer today, with the removal proof that dropping the
  set index restores the unskipped count. Correctness against the heap oracle.

### Phase 5: item 7, idempotent inserts

The paper's server keeps hashes of the last N inserted parts and ignores
re-inserts of a known hash, so a retried bulk load is deduplicated by the server.

This one carries a semantic risk the others do not: silently discarding rows a
client asked to insert is not SQL `INSERT` behaviour. It must be opt-in, it must
say what it did, and it must be scoped to a load operation rather than to
ordinary DML.

- Scoped to `pgcolumnar.parallel_copy` (`columnar_parallel_copy.c:1284`) and the
  row-group flush, where a "part" has a natural definition: the content of one
  flushed row group.
- **Verification.** A load, an interrupted load, and a retry, with the row count
  asserted after each. A removal proof that the second load does insert twice
  with the feature off.

### Phase 6: item 5a, merge-time transformation inside our storage

Our `compact`, `recluster` and `vacuum` already rewrite. The tractable half of
item 5 is doing more than compaction during that rewrite: dropping row groups
whose retention has expired, rather than reading and rewriting them.

- **Verification.** Row groups dropped by a TTL rewrite, against the same fixture
  with no TTL declared. Storage size before and after. Correctness against the
  heap oracle for the rows that remain.

### Phase 7: item 5b, tiering to object storage, design document only

Item 5's TTL example ages cold data to an object-storage volume. Its stated
prerequisites, #393 and #394, are both closed, which is what makes this item
live at all. Its unstated prerequisite is not met.

Native bytes are in the main fork, behind the buffer manager and the storage
manager, and are recovered by PostgreSQL's crash recovery. Bytes in an S3 bucket
are not. A tier therefore has to answer: what makes a remote row group durable,
what happens when a rewrite that moved it aborts, and how a reader that faults on
a missing object fails safely. None of those is a code question.

- **Deliverable.** A design document naming the invariants and the failure modes,
  and a recommendation. Not an implementation.
- The seam is `PgColumnarReadLogicalData` and `PgColumnarWriteLogicalData`, which
  is a genuinely small interface for the job. That is an argument about
  feasibility, not about safety.

## Decisions taken 2026-08-28

1. **The alpha3 cycle is open.** Phase 3 proceeds and carries #761 alongside the
   catalog objects items 3 and 7 need.
2. **Item 7 is an opt-in argument to `pgcolumnar.parallel_copy`.** Off unless
   asked for, scoped to the bulk-load path, and it reports how many row groups it
   skipped. Ordinary `INSERT` is never affected.
3. **Item 5b terminates at a design document.** Name the invariants, the failure
   modes and a recommendation. Do not build.

## The questions those answered

1. **Does this authorize opening the alpha3 cycle?** The answer on 2026-08-27 was
   to clear the board first. Items 3 and 7 both need the upgrade script, and
   #761 is waiting on it. Phases 1 and 2 do not.
2. **Item 7's semantics.** Opt-in per call, or a table option? A rejected
   duplicate should be reported, not silent. This needs a decision because it is
   the one item that can lose data a client believes it wrote.
3. **Item 5b's scope.** Design document and stop, or design document and then
   build a read-only tier? The WAL constraint says a design needing new WAL
   semantics is rejected rather than deferred, so this may terminate at the
   document.

## Assumed rather than decided

- That item 6's runtime source should be the zone map and bloom estimates rather
  than the plan-time estimate. The plan-time estimate is what #369 already
  bounded; the paper's point is specifically that runtime is better. Phase 1
  measures both rather than assuming.
- That item 3's set index is worth its storage on the benchmark table's clumped
  low-cardinality columns (`region`, `datacenter`, `rack`, `os`, `arch`, `team`,
  `service`). #403 asserts this shape is common. Phase 4 measures the skip rate
  before the write path is finished, not after.
