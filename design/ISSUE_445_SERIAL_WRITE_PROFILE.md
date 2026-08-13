# Issue #445: profile of the serial write path, and a scoped reduction plan

pgColumnar serial `COPY` runs about 2.37x slower than Citus columnar on the
#445 benchmark, on the same file through the same core parser. This document
records a measured profile of the write path, and scopes the reductions that
survive adversarial verification. It ranks them by bounded saving times safety
and names the one change to take first.

## 1. What was measured

Two synthetic ingest profiles were taken, one per column family, with `perf`
(`cpu-clock`, DWARF unwind) on a non-assert PostgreSQL 17 build. Each captured
about 12000 samples of a real `INSERT INTO ... SELECT` whose source rows were
materialised outside the timed statement. The two shapes isolate two distinct
cost regimes.

**Text ingest is encode-bound.** The fixture was `(id bigint, t text)` with
32-character values. Self time concentrates in the FSST and zstd encode path:

| symbol | self time | object |
| --- | ---: | --- |
| `libzstd` (two frames) | 13.72% | libzstd |
| `encode_fsst_shared` | 10.60% | pgcolumnar |
| `PgColumnarFsstBuildChunkTable` | 4.65% | pgcolumnar |
| `detoast_attr` | 4.23% | postgres |
| `__memmove` / `__memcmp` | ~4.7% | libc |

**Numeric ingest is infrastructure-bound.** The fixture was ten integer columns.
Self time concentrates in catalog access, resource-owner churn, and allocation,
not in encoding:

| symbol | self time | object |
| --- | ---: | --- |
| `ResourceOwnerForget` | 8.99% | postgres |
| `palloc0` | 7.06% | postgres |
| `hash_search_with_hash_value` | 4.74% | postgres |
| `SearchCatCacheInternal` | 4.68% | postgres |
| `TupleDescInitEntry` | 3.30% | postgres |
| `LockAcquireExtended` | 2.28% | postgres |
| `llseek` | 2.54% | libc |

The two profiles are the endpoints. The 105-column ClickBench mix is neither in
isolation: its text columns pay the encode path and its numeric columns pay the
metadata-infrastructure path, so both regimes apply per stripe. The blend sits
between the endpoints and is not yet measured.

Provenance: the percentages above are from these two real profiles. The
adversarial verifiers in the scoping run did not have the profile file, so they
treated every figure as an unverified ceiling and corrected several savings
downward. That conservatism is kept below. No saving here is a promise until it
is measured on a build.

## 2. Where the time goes

### Numeric: a catalog open and lock cycle per metadata row

This is verified against the code, not inferred. Each metadata row is inserted
by an independent `PgColumnarInsert*Row`. Each such call runs
`open_columnar_table`, which is `get_namespace_oid` plus `get_relname_relid`
(two catcache probes) plus `table_open` (a relcache hash search, a lock, and a
resource-owner remember), then `CatalogTupleInsert`, then `table_close`.

The per-vector zone map is the row-count multiplier. A flush emits
`(stripe_row_limit / chunk_group_row_limit) + 1` zone rows per column, which is
16 for the default limits. One stripe flush of a four-column table therefore
opens and closes a metadata relation on the order of 70 times, where four opens
would do.

Code sites confirmed:

- `src/columnar_metadata.c:137` `open_columnar_table` (the per-call open)
- `src/columnar_metadata.c` the four inserters `PgColumnarInsertRowGroupRow`,
  `PgColumnarInsertColumnChunkRow`, `PgColumnarInsertZoneMapRow`,
  `PgColumnarInsertBloomRow`, each opening and closing on its own
- `src/columnar_write_state.c:2772-2794` the per-row insert loops in the flush

### Text: repeated FSST setup and per-byte re-reads

`encode_fsst_shared` rebuilds an `FsstLookup` on every vector of a chunk, plus
the decide pass. The symbol table is constant across the chunk, so most builds
repeat identical work. `fsst_verdict_cache` (#472) caches the keep-or-drop
decision, not the symbol table, so it does not remove this. `fsst_longest_match`
does one small `memcpy` per candidate length at every input byte.
`PgColumnarEncodeValue` forces every varlena to a full four-byte header even when
the `COPY` input arrived with a short header.

## 3. Candidate reductions, ranked

Ranked by bounded saving times safety. Every entry is measure-first: none is a
certain win until profiled on a build. Byte-neutral means no on-disk or metadata
bytes change, so no opt-in GUC is needed.

### 3.1 Batch metadata catalog inserts per flush (open once, insert all, close once)

The headline candidate, and the recommended first step.

- Mechanism. Open each metadata relation once per flush, insert all its rows,
  close once. This collapses about 70 relation-open cycles per stripe to about
  four.
- Code site. `src/columnar_write_state.c:2772-2794` and the four inserters.
- Byte-identity. Unconditional. Same catalog rows, same values, same order.
- Guarding test. A work-done counter of metadata relation opens per flush, plus
  `native_zonemap`, `native_bloom`, `native_writer`, and `differential` as byte
  and content pins.
- Measured result (implemented and benchmarked). The batching lands the open
  count where the estimate said: a flush now opens each metadata table once
  (`opens=4`), independent of the column count, where an unbatched 20-column
  flush opened 141 relations and a 100-column flush more. But the wall-clock
  saving is smaller than the self-time share suggested. A 5,000,000-row
  ten-column load was 2471 ms batched against 2493 ms unbatched, about one
  percent and inside the run scatter. A 1,000,000-row 100-column load, where the
  open count is highest, was 4991 ms against 5085 ms, about two percent and
  outside the scatter. The lesson is that the open cycle was frequent but cheap:
  a warm catcache probe and a fast-path lock cost little each, and the per-row
  `heap_insert` and index insert that stay are the real weight. The estimate of 3
  to 5 percent was optimistic; the measured figure is 1 to 2 percent, larger on
  wider tables. Byte-identity held (`native_zonemap`, `native_bloom`,
  `native_writer`, `differential` all pass), and the change is clean under
  address and undefined-behaviour sanitizers.
- Verdict. Correct, byte-neutral, low risk, and a real but modest win. Worth
  taking as a down payment, but it does not on its own close a meaningful part of
  the gap. The larger lever is the text encode path.

### 3.2 Batch the per-vector zone rows with heap_multi_insert

Stacks on 3.1. Once the relation is open once, insert its zone rows with
`heap_multi_insert` and one index pass. Residual saving after 3.1 is only the
`heap_insert`-per-tuple amortisation, plausibly sub-one-percent. Byte-neutral to
SQL readers, but it switches to `XLOG_HEAP2_MULTI_INSERT`, an existing core
record. Do not sum its saving with 3.1.

### 3.3 Skip the storage existence scan after the first flush

A `bool` on the write state, set after the first ensure, skips the redundant
`PgColumnarInsertNativeStorageRow` existence scan on later flushes of the same
write state. Zero saving on single-flush loads, about 1 to 3 percent on
many-flush loads only. Byte-neutral. Direct precedent: the existing `projInited`
field.

### 3.4 Hoist the FSST lookup to once per chunk

Build one `FsstLookup` per chunk and hold it across the vector loop. Byte-neutral.
Bounded by the non-inner-loop share of `encode_fsst_shared`, realistically
sub-one-percent for bulk text. Carries a double-free risk on the abort path that
asserts will not catch, so it earns the `pg18_san` ASAN gate.

### 3.5 One 8-byte load and mask in fsst_longest_match

Replace the per-length `memcpy` with a single unaligned little-endian load.
Byte-identical on little-endian; keep the copy path on big-endian. Honest upper
bound about 1 to 2 percent, because the `fsst_lookup_find` hash probes, not the
copy, dominate the inner cost. Watch the `1ULL << 64` undefined-behaviour edge.

### 3.6 Reuse a persistent ZSTD_CCtx

Hold a per-process `ZSTD_CCtx` and call `ZSTD_compressCCtx`. Byte-neutral only
with `compressCCtx`, not the `compress2` variant. Under two percent as a ceiling,
likely far less, because context setup amortises to near zero over a large block
compression. Being byte-neutral, only a benchmark can prove it, not a red test.

### 3.7 Store packed varlena headers (needs an opt-in GUC and a format bump)

Keep short one-byte varlena headers instead of expanding to four. Saves a palloc
and a copy per short value and shrinks stored files by three bytes per value.
This changes on-disk bytes, including stored min and max, so it is admissible
only behind an opt-in GUC and a format-version stamp, with a full audit of the
27 raw `VARSIZE`/`VARDATA` sites. Format work, not a drop-in.

### Rejected

- Caching the metadata OIDs on their own. The probes are warm catcache hits
  below the profiler floor, and 3.1 removes them anyway by not re-opening.
- Raising `chunk_group_row_limit` to cut zone rows. Already available as a
  `PGC_USERSET` GUC. Tuning and documentation, not a code candidate.
- Packing zone maps into the descriptor region. A coordinated read and write
  format change with wrong-skip risk. Defer behind a format version.

## 4. The recommended first step, and its removal proof

Take 3.1. It is the highest-leverage byte-neutral change, it needs no GUC, and
it targets the numeric-infrastructure regime that ClickBench's numeric columns
hit.

Because it is byte-neutral, no data test can go red, so per the house rule
"measure the work, never the intent" the removal proof is a work-done counter,
not a data assertion. Instrument a per-flush count of metadata relation opens.
Assert that one stripe flush of a four-column fixture opens each metadata
relation once. The counter reads about 70 today and about four after the change;
reverting the change restores the ~70 count and the test goes red again. The
byte pins run alongside to prove the catalog content and on-disk bytes did not
move. Only then is the real saving measured with `perf` on the #445 bench.

## 5. Honest limits

- The profiles are two synthetic single-family ingests. The 105-column
  ClickBench blend is not yet measured, and it decides whether the encode regime
  or the infrastructure regime deserves the larger effort.
- Every saving except 3.1 is a bound narrowed by reasoning, not a measured
  result. Several were corrected downward during verification. Treat none as a
  certain win until measured on a build. 3.1 was measured and came in at 1 to 2
  percent, below its own 3 to 5 percent estimate, which is the caution made
  concrete: a large self-time share is not the same as a large recoverable cost.
- The byte-changing candidates (3.7, and the deferred zone-map packing) carry an
  opt-in GUC, a format-version bump, a read-site audit, and re-baselined byte
  pins. They are not comparable in effort to the byte-neutral set and should not
  be scheduled until that set is measured.
