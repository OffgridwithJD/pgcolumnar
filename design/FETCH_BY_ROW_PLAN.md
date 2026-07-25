# Fetch by row number: plan for issue #143

`ColumnarReadRowByNumber` reads and decodes a whole row group to return one row,
so fetching N rows from one group costs N times the group. Measured on PG17
non-assert, `UPDATE t SET v = v + 1`: 878 ms at 5,000 rows, 4,452 ms at 10,000,
19,211 ms at 20,000, all in one row group. Splitting the same 20,000 rows across
ten groups drops it to 1,403 ms. Full numbers are in the issue.

This is a plan, not a patch. The path is on the read side, every index scan and
every `UPDATE` reached by index goes through it, and one of the options has a
correctness hazard that has to be settled before code.

## Where the time goes

Per call, at `src/columnar_reader.c:1271`:

1. `ColumnarReadRowGroupList` reads the row-group catalog (a heap scan, and it
   must stay one: see the trap recorded for #136).
2. `groupBuffer = palloc(rg->byteLength)` and `ColumnarReadLogicalData` copy the
   entire group out of shared buffers.
3. `columnar_native_decode_chunk` decodes each column's chunk in full.
4. A `for (i = 0; i < rowInGrp; i++)` walk steps to the row's position.

Steps 2 and 3 are the quadratic term. Step 4 is linear in the row's offset within
its group, which is a second, smaller quadratic term over a scan.
`pgcolumnar.enable_column_cache` does not help (15,846 ms against 14,693 ms),
because it caches decompressed streams and the cost here is the decode and the
copy, not decompression.

## Option A, rejected: extend the existing backend-level cache

`columnar_cache.c` keys on `(storageId, absOffset)`. Caching decoded chunks under
the same key looks natural and is wrong without more thought, because physical
reclaim can hand the same file offset to different content later. The existing
cache is safe because it stores a decompressed copy of a stream whose identity is
checked against `rawLen` and `compressionType` on hit, and because a stale hit
there is still the bytes that were at that offset. For decoded values that
argument does not hold.

It is also off by default, so fixing #143 through it would mean turning a cache on
by default, which is a separate decision about memory.

## Option B, proposed: a statement-scoped decoded-group cache

Keep the decoded columns of the most recently fetched row group, keyed by
`(storageId, groupNumber)`, in a context that is reset at statement end.

Why statement scope settles the correctness question. Within one statement no
other statement's vacuum, compaction, or reclaim can rewrite the offsets this
statement is reading, so the cached decode cannot go stale under it. Across
statements it is thrown away, so a later reclaim that reuses an offset cannot be
served old bytes. That is the whole invalidation argument, and it needs no
generation counter.

Visibility is unaffected. A fetch checks the row mask and the delete-vector
buffers per call, and neither is part of what would be cached; only decoded column
values are. A row deleted between two fetches inside the same statement is still
seen as deleted, because that check does not consult the cache.

Writes inside the statement do not invalidate it either: an insert appends to a
new group or extends the open write buffer, and neither rewrites the bytes of an
already-flushed group.

Bounding memory is the part to get right. A decoded group can be
`stripe_row_limit` rows wide across every column, so caching unconditionally is
not acceptable. Proposal: cache only when the decoded size is under a cap, and
hold exactly one group, replaced on a miss. One entry is enough for the
measured cases, because both index scans and `UPDATE` walk rows in row-number
order and therefore stay inside one group at a time. A cap of a few megabytes
keeps the worst case bounded; the exact number wants measuring, not guessing.

## Option C, independent: remove the linear walk

Step 4 is separable and can land on its own. Fixed-width columns can index
directly from the row offset. Variable-width columns need an offset array, which
the decoder can produce as it walks, at the cost of one array per decoded chunk.
Worth doing after B, since B changes how often step 4 runs.

## Also worth doing: fetch only the columns the caller needs

The uniqueness check needs the key columns; the fetch decodes all of them. A
needed-columns bitmap through `ColumnarReadRowByNumber` would cut the constant
factor for the check without touching the caching question. Smallest of the three
changes and fully independent.

## Proving it

Correctness first: the existing suites cover the fetch path heavily
(`native_index`, `native_dml`, `native_ios`, `differential`, `unique_conc`), and
any change here must pass them unchanged on the full matrix, not only PG18 and 19.

For the performance property, a fixed millisecond threshold is not portable. Use a
ratio the way #128's cancellation test does: with the same table shape, time the
update at N rows and at 2N rows in a single row group, and assert the ratio is
under 3. Today it is 4.3 to 5, and linear behaviour puts it near 2. Record the
measured numbers in the commit message.

To prove the cache is actually used rather than the timing having moved for
another reason, count reads: a scan of `pgcolumnar.stats` before and after is not
enough, so add a debug counter or assert on the ratio at two different group
sizes, where the wrong implementation cannot produce both.

## Order

1. Needed-columns bitmap (independent, small, no caching questions).
2. Statement-scoped decoded-group cache (option B), with the memory cap measured.
3. Positional indexing to remove the walk (option C).

Each is its own PR with its own gate.

## Not this

`ColumnarDeleteVectorBufferedDeleted`, which the audit record lists as left
unfixed, is not the cause: the quadratic behaviour reproduces without a unique
index, and that function is only reached under the uniqueness check. Its nested
scan is real and small. Fix it when touching that file, not as a response to #143.
