# Issue #620: the Parquet FDW streams instead of materializing a tuplestore

Design before code. Today `pqfdwBeginForeignScan` opens every resolved file,
decodes it whole, and drains all rows into one `randomAccess` tuplestore before
it returns; `Iterate` just drains the tuplestore and `ReScan` is a free
`tuplestore_rescan`. The whole file (really, every file the path resolves to)
sits in `work_mem`-backed storage, spilling to disk past `work_mem`, and a
`LIMIT k` still decodes every row group of every file. This issue makes the scan
pull one row group at a time and stop when the executor stops asking.

All line citations are `src/columnar_parquet_reader.c` at HEAD (`main`, post-#445).

## The unit of streaming is one row group

`pq_read_rows` (2941) is a push loop with two nested loops: an outer loop over
row groups that decodes a whole group's needed leaves into `groupCtx` (the
`decode_leaf_entries` block), and an inner loop that assembles each of the
group's `n` rows and calls `sink(slot, arg)` per row. The natural resumable
granularity is the row group: decode one group, hand out its `n` rows across
successive `Iterate` calls, and reset `groupCtx` only when advancing to the next
non-skipped group. `rowCtx` already resets per row.

Memory drops from "every file" to "one row group's decoded columns". `LIMIT`
stops after the groups whose rows it consumed. Correctness of row assembly is
unchanged because the assembly code moves verbatim.

## Shape: a resumable cursor, assembly code moved not rewritten

Refactor `pq_read_rows`'s body into two reused pieces, called by both the eager
SRF path (unchanged behaviour) and the new streaming FDW cursor:

- `pq_decode_group(pf, src, leaves, ..., rg, groupCtx)` runs the existing
  per-group decode (the `decode_leaf_entries` block) for group `rg` into
  `groupCtx` and returns the group's row count `n` and the decoded per-leaf
  entry state. This is lifted verbatim from the outer-loop body.
- `pq_assemble_row(state, r, slot)` runs the existing per-row assembly (scalar,
  list, struct, const/partition stamping, `ExecStoreVirtualTuple`) for row `r`
  into `slot`. Lifted verbatim from the inner-loop body.

`pq_read_rows` is then re-expressed as: `for each rg { n = pq_decode_group(...);
for r in 0..n { pq_assemble_row(...); sink(...); MemoryContextReset(rowCtx); } }`
so the SRF and import paths keep their exact current behaviour and stay eager.
This keeps the refactor mechanical and lets the existing row-content suites prove
the move introduced no assembly change.

### The FDW cursor state (on `PqFdwScanState`)

Replace `tupstore`/`readslot` with a cursor:

- the resolved `files` list and a current-file index;
- the current open `PqSource` (or a flag that none is open) and its `PqFile`
  footer;
- the projection/skip plan for the current file (`needLeaf`/`needTop`,
  `skipGroup[]`), computed once per file as Begin does today;
- the current row-group index `rg`, the decoded group's `n`, and the current row
  index `r` within it;
- `groupCtx` and `rowCtx` living in the scan's own long-lived context, not the
  transient context Begin runs in (see winCtx note below);
- the six EXPLAIN counters, plus one new counter (below).

`Iterate`: if a group is loaded and `r < n`, assemble row `r`, `r++`, return the
slot. Else advance `rg` to the next non-skipped group of the current file,
`pq_decode_group` it, set `r = 0`, and retry. When the current file's groups are
exhausted, `pq_source_close` it, advance the file index, open the next file,
recompute its plan, and retry. When files are exhausted, return an empty slot.

`Begin` no longer decodes: it resolves the file list and prunes (the
`Files Pruned` path), sets `filesRead`, and leaves the cursor before the first
file. The first `Iterate` opens the first file. (Open the first file in Begin if
a suite needs open errors surfaced at Begin; decide by what the FDW suites
expect. Default: lazy open in Iterate, which is the streaming point.)

`ReScan`: close any open source, reset the file index and `rg`/`r` to the start,
and stream again from the top. This re-opens and re-decodes; it is
correctness-preserving. Today's free rescan is the eager model's benefit and is
the deliberate trade. No existing suite asserts rescan *cost*, only *content*.

`End`: close any open source (order-sensitive with dropping the slot, as today),
delete the cursor contexts.

## The remote-handle lifetime invariant

The object-store module closes every open handle on abort through
`os_resource_release` over `os_open_handles`
(`objstore/columnar_objstore_module.c`). The stated invariant is "no handle
survives its statement (every reader materializes and closes before returning)".
A streamed scan holds one remote handle open across `Iterate` calls, so the
"before returning" phrasing stops being literally true. The invariant that makes
close-all-on-abort correct is still true: the handle belongs to the running
statement, and the release callback walks the list regardless of who holds the
pointer, so an error between `Iterate` calls is cleaned up. Action items:

- Update the module header comment to state the invariant as "no handle survives
  its *statement*", not "before returning".
- `pq_source`'s prefetch window `winCtx` is captured at open as
  `CurrentMemoryContext` (open runs inside Begin today, which is why it is safe).
  Under streaming, open runs inside an `Iterate` call whose context is transient;
  the window must live in the scan's long-lived context. Open the source with the
  scan context current, or set `winCtx` explicitly to the scan context.
- One remote handle and its ExternalFD reservation are held for the span of a
  file's rows, not released immediately as in the eager model. This is a real
  resource-occupancy change, bounded to one file at a time (single open handle),
  and is the intended cost of streaming.

## Out of scope: the SRF (`read_parquet`) stays eager

`pgcolumnar_read_parquet` returns in `SFRM_Materialize` mode with a whole-set
tuplestore. Streaming it means `SFRM_ValuePerCall`, a larger and separate change.
This issue is the FDW. The SRF keeps calling `pq_read_rows` (now built on the two
extracted helpers) and stays eager, byte-for-byte in behaviour.

## TDD instrument: a groups-decoded counter (there is none today)

The six EXPLAIN counters are all decode-*decision* counts. None reports rows
produced or groups actually decoded, and `pq_read_rows`'s local `total` is
`(void)`-discarded at the FDW call site. So today a suite cannot tell an eager
`LIMIT 3` (decodes every group) from a streamed one (decodes one), because the
counters read identically.

Add `int groupsDecoded;` to `PqFdwScanState`, incremented once per
`pq_decode_group` call in the cursor, and print it from
`pqfdwExplainForeignScan` as `Row Groups Decoded`. This is the work-done
instrument (per the discipline: measure the work, not the intent; assert the
execution path on both arms).

### RED / GREEN / removal proof

- **RED**: on `main`, `EXPLAIN (ANALYZE)` of `SELECT * FROM ft LIMIT` over a
  multi-row-group local file has no `Row Groups Decoded` line, and no counter
  distinguishes `LIMIT 1` from a full scan. The new-counter assertion fails to
  find the line; the streaming assertion (LIMIT-1 decodes 1 group of N) cannot
  even be written against the eager code.
- **GREEN**: with streaming, `Row Groups Decoded` appears, a full scan of an
  `N`-group file reports `N`, and `LIMIT k` with `k` inside the first group
  reports `1`. Row *content* for full scans is identical to `main` across every
  existing FDW suite.
- **Removal proof**: force the cursor to decode all groups up front (defeat the
  lazy advance) and the `LIMIT 1 -> 1 group` arm reds (reports `N`). Separately,
  neuter the `groupsDecoded++` and the counter line assertion reds. Each proves
  a distinct claim: the streaming happened, and the instrument measures it.

The `native_parquet_pushdown.sh` EXPLAIN-scraping arms are the template
(`Row Groups Skipped` / `Row Groups:` via grep). Use a local file with several
row groups (small `stripe_row_limit` on the source columnar table, exported to
Parquet) so `LIMIT` inside the first group decodes 1 of N.

## Regression surface (all local-file, no network)

Must stay green with identical row content: `native_parquet_fdw.sh`,
`native_parquet_pushdown.sh` (Row Groups Skipped counters), `native_parquet_projection.sh`
(Columns Read/Total), `native_parquet_partition.sh` (Files Pruned + partition
stamping), `native_parquet_multifile.sh` (multi-file drain + ReScan), the
row-content suites (`native_parquet_stack.sh`, `_hardening.sh`, `_codecs.sh`,
`_flba.sh`, `native_read_parquet.sh`), and the remote suite
`objstore_s3_read.sh`. `native_parquet_streaming.sh` (today only footer
streaming) is the home for the new LIMIT-reduces-work arm.

ReScan is the specific risk: `native_parquet_multifile.sh` and any nested-loop
plan re-scan the foreign table. Streaming ReScan re-decodes; content stays
identical, which is what those suites assert.

## Gates

PG17 lane first (`-Wshadow -Werror`). Then PG18/19 over the FDW + objstore read
suites. ASAN (pg18_san) over the FDW read path and `objstore_s3_read`: this is a
per-scan memory-lifecycle change (group/row contexts now outlive a single call,
a remote handle and its prefetch window now span Iterate calls), exactly the
class the ASAN gate exists for. Both a local multi-group scan and a remote scan
with a `LIMIT` (source closed early mid-file) must run clean.

## Order of work

1. Extract `pq_decode_group` / `pq_assemble_row`; re-express `pq_read_rows` on
   them; prove every existing suite green (pure refactor, no behaviour change).
2. Add `groupsDecoded` + `Row Groups Decoded` EXPLAIN line. Write the streaming
   arm in `native_parquet_streaming.sh`; it is RED (counter absent).
3. Convert the FDW Begin/Iterate/ReScan/End to the cursor. Green the streaming
   arm; removal proofs; keep all regression suites green.
4. Fix `winCtx`/scan-context lifetime; update the module invariant comment.
5. Gates: PG17/18/19 + ASAN. Docs.
6. Docs: note that the FDW streams row groups (bounded memory, early-exit on
   LIMIT) while `read_parquet` materializes; `Row Groups Decoded` in the EXPLAIN
   counter list.
