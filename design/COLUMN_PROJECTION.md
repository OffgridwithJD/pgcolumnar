# Column projection in the native reader (#338)

Independent MIT design. References only the public PostgreSQL API (bitmapsets,
`pull_varattnos`, the buffer manager). No core/TimescaleDB/Citus/DuckDB source
consulted.

## Problem

`columnar_native_load_group` reads each visited row group's bytes whole and
decodes every column chunk in it, regardless of which columns the query needs.
The projection is computed correctly by `columnar_projected_columns`
(`columnar_customscan.c`), threaded down through `ColumnarBeginRead`, copied into
the read state, and then never read.

Measured on a 12-column, 4M-row, 351 MB table (44,962 buffers): `sum(a)` touches
45,094 buffers, and so does a sum over all twelve. One column costs the same I/O
as twelve. The identical two-column query reads 100% of a 2-column table (7,620
buffers) and 100% of a 12-column one (45,097).

## Change

Confined to the reader. No on-disk format change, no catalog change.

1. **`colWanted`** — `ColumnarReadState` gains a `bool *` of length `natts`,
   precomputed once in `ColumnarBeginReadWithStorage` from `projectedColumns`. A
   NULL bitmap means every column is wanted, which is what every caller outside
   the custom scan and the vectorized aggregates passes today, so their behavior
   is unchanged by construction.

2. **Read only the needed byte ranges.** The chunk list is fetched *before* the
   data read rather than after it. When every column is wanted, the existing
   single whole-group read is kept verbatim. Otherwise the wanted chunks'
   `[pageOffset, pageOffset+pageLength)` ranges are read individually, with
   file-adjacent ranges coalesced into one read. The full-size group buffer is
   still allocated so the existing `base = nativeBuffer + (pageOffset -
   fileOffset)` arithmetic stays valid; untouched pages are never faulted in, so
   the unread regions cost no resident memory.

   Chunks are written column-major (`columnar_write_state.c:1377`), so a
   projected subset is a small number of contiguous runs, not `natts` scattered
   reads.

3. **Skip the decode** of unwanted chunks. This matters as much as the I/O: the
   decode loop previously ran `columnar_native_decode_chunk` over every column.

4. **Emit unwanted columns as explicit NULL.** The row-fill loop treats a NULL
   validity pointer as "column absent from this group, added by a later ADD
   COLUMN" and substitutes `missingValues[c]`. For a column that was merely *not
   projected* that would yield a plausible wrong value rather than an obvious
   failure. The unwanted case is therefore tested first and produces an explicit
   NULL, keeping the two reasons for an unset cursor distinct.

   This one is defensive, and the tests say so rather than implying otherwise:
   removing it leaves all 35 checks passing. It cannot be observed through SQL
   today, because nothing above the scan reads a column outside the projection.
   It is kept because the cost is one array test per column and the failure it
   forecloses -- a future narrowing of the projection silently returning ADD
   COLUMN defaults in place of stored data -- is silent and data-shaped.

5. **Validate that chunks tile the group.** Not part of the original plan; the
   corruption suite found it. `corruption.sh` inflates `row_group.byte_length`
   and requires a clean error. The whole-group read produced one incidentally,
   by reading a length that ran past the end of the relation. A projected read
   only touches chunk ranges, so the corrupt length would go unnoticed.

   Rather than weaken the corruption test to match the new path, the reader now
   checks the invariant directly: the chunks must exactly tile the group, with
   no gap at the start and none at the end. That was verified to hold across
   plain inserts, ADD COLUMN, stored generated columns, updates and deletes,
   `compact`, `vacuum_sorted`, block-compressed columns, and `VACUUM FULL`
   before being relied on. It is a more direct check than the old one: it names
   the inconsistency instead of surfacing as a short read.

   It is enforced only on the projected path, so
   `enable_column_projection=off` remains a way back if some layout this does
   not anticipate ever appears.

### Why per-vector skipping stays correct

`allDescriptor` gates per-vector zone-map skipping and is cleared by any
baseline-encoded chunk. Only wanted chunks are now considered, so a baseline
*unwanted* column no longer disables skipping. That is correct and strictly
better: the skip loop advances only cursors that are non-NULL with a non-NULL
`nativeVecRawLen`, which unwanted columns never have, and vector boundaries only
need to line up across the columns actually decoded.

## Correctness argument

`columnar_projected_columns` is conservative in exactly the ways this relies on:
it unions the targetlist and the qual, and returns NULL (meaning all columns) for
a whole-row Var, any system column, and for a reference to no column at all. So
a column that is skipped is one no operator above the scan can observe.

That argument is not self-proving, so the test asserts it empirically rather than
trusting it: every shape is run with projection honored and with it disabled, and
the result sets must be identical.

## Test (`test/column_projection.sh`)

- **Equivalence.** Identical results with projection on and off across: single
  and multi column targetlists, a qual on a column absent from the targetlist,
  `count(*)`, `SELECT *`, whole-row Var, a system column (`ctid`), NULLs, an
  all-NULL column, a column added by ALTER TABLE ADD COLUMN with a default
  (the `missingValues` interaction), varlena and by-reference types, and after
  deletes.
- **Buffers, not timing.** The regression assertion is a buffer count: a
  one-column aggregate over a wide table must touch materially less than the
  whole relation. Timing would be flaky; buffer counts are exact and fail loudly
  if projection silently stops applying.
- **Removal proof.** With `allColumnsWanted` forced true, the buffer assertion
  fails (`on: 2517, off: 2517`). Disabling the tiling check fails
  `corruption.sh`'s `byte_length` assertion. Removing the explicit-NULL guard
  fails nothing, which is why it is described above as defensive rather than
  proven.

  Flipping the GUC's *default* proves nothing and was discarded: the suite sets
  the GUC explicitly on both arms, so the default never reaches the code under
  test.

## Effect on other suites

`cancel_decode` measures how quickly a long decode responds to a cancel. Its
query filtered on one column of eight, and with projection that scan no longer
takes long enough to cancel -- its own premise check caught this and failed.
The query now names every column, so the scan again decodes the whole relation
as the test intends, and the suite keeps testing cancellation on the default
path rather than being pinned to the old behavior.
