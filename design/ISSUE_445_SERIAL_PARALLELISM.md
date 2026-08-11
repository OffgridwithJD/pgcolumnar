# Issue #445: closing the serial-load gap with in-COPY parallelism

Design sketch, written before code, per the house rule. This one gates on an
owner decision before it becomes a full design, because a bulk path already
exists that gets the same win a different way.

## Where #445 actually stands (measured, mostly by ChronicallyJD)

The opening claim -- "Citus loads the same data 3x faster" -- was measured
honestly and has been decomposed to nearly nothing that is a defect:

- **Serial 2.40x / bulk 1.76x Citus.** Like-for-like bulk (both engines, 16
  workers) is 1.76x; our bulk `parallel_copy` loads 11.1M rows FASTER than heap's
  serial COPY (89 s vs 144 s) at the same table size.
- **The biggest cause is fixed:** #472 (FSST verdict cache) took FSST from ~70% to
  ~16% of ingest.
- **The concrete no-tradeoff defects are fixed:** #467 (bloom filters were 19.3x
  over-provisioned -> now sized by distinct count) and #466 (`encode_effort=fast`
  skips FSST).
- **detoast-once (#587, this session):** varlena values were detoasted up to 4x
  per row; now once. 11% on a large-text load, one item in the broad tail.
- **The remaining serial cost is compression** (zstd ~17%), which is real work
  that buys the 11% size advantage over Citus -- and it parallelises.

So the residue is not a hot spot. The peer's framing (2026-08-10): the gap is a
property of the SERIAL path, not columnar storage, because the format demonstrably
ingests faster than heap with more than one connection.

## The idea, and why it is an owner decision first

Direction: make a single `COPY` use the parallelism the format already has --
offload the per-row encode and the per-chunk compression from the COPY backend to
background workers, so one connection is not bottlenecked on the CPU-bound
discretionary work.

**The reason this is a decision and not just a design:** `pgcolumnar.parallel_copy`
already exists and already beats heap. A user who wants the bulk speed has it
today. In-COPY parallelism would help the user who runs a plain single-connection
`COPY` and does not know about `parallel_copy` -- convenience and default-path
performance, not a new capability. That value is real but it is not a defect being
fixed, and it is a large piece of work against a hot path, so it wants an explicit
"yes, the default serial path is worth parallelising" before design, not after.

## The offload point, mapped

`pgcolumnar_flush_row_group` (`columnar_write_state.c:938`) builds the stripe
**column-major**: a `for (c = 0; c < natts; c++)` loop (`:1012`-`:1183`) that, per
column chunk, builds the validity bitmap, encodes the values per vector (D4),
picks and applies the block codec, and emits the encoding descriptor. **Each
column chunk is independent** -- it reads only that column's buffered
`chunkGroups` and writes its own `encoded`/`desc` StringInfos. So the unit of
parallelism is a **column chunk at flush time**, and what parallelises is not just
the block codec (~17%) but the whole per-column term (encode + FSST + codec).

Only the backend touches disk and WAL: after the loop, the backend assembles the
column chunks into the stripe's `data` buffer and writes + catalogs them. Workers
produce bytes; the backend writes them. That is what keeps the WAL constraint
satisfied without a new record type.

## Shape of the work

**Structure: parallelise the per-column flush, keep I/O and WAL on the backend.**
At flush, the backend hands each column chunk's buffered input to a pool of
background workers via a dsm segment (reusing `columnar_parallel_export.c`'s dsm +
`shm_toc` + `BackgroundWorker` machinery), each worker runs the existing per-column
flush body and writes its `[encoded][descriptor][codec]` result back into the dsm,
and the backend collects them in column order and does the byte-identical write +
catalog insert it does today. This targets the dominant remaining term with the
row-buffering path untouched -- the change is confined to the flush.

The alternative (shard the incoming row stream across writers) is what
`parallel_copy` already does; a plain streaming `COPY` cannot be split by file
offset the way `parallel_copy` splits a file, so it is not the serial-path fix.

Incremental slices, each shippable and testable on its own:

1. **Refactor `pgcolumnar_flush_row_group`'s per-column loop body into a pure
   function** `flush_one_column(inputs) -> {encoded, descriptor, codec, zonemap}`
   that reads only its arguments (no `writeState` reach-through). No workers yet;
   pure refactor, output byte-identical, guarded by a differential + the existing
   write suites. This is the foundation and the whole correctness surface for the
   codec/encoder is settled here, serially.
2. **dsm plumbing:** move the per-column input into a dsm segment and the result
   back, still run serially in the backend (no workers). Proves the serialisation
   of inputs/outputs is byte-identical before any concurrency.
3. **The worker pool:** dispatch slice-1's function across `min(natts, N)` workers
   reading from the slice-2 dsm, backend collects in column order and writes.
   Degrade to the serial in-backend path when slots are unavailable.
4. **Gate + measure:** a GUC or table option to enable it; measure the serial-load
   speedup on ClickBench `hits` against the ~17% ceiling and confirm output is
   identical to the serial path (same `data` bytes, same catalog rows).

Constraints that bound the whole thing:

- **WAL is fixed.** Only existing WAL mechanisms and record types (extension
  constraint). A worker that produces a compressed chunk must hand it back for the
  COPY backend to write and WAL, or write through the same paths -- no new WAL
  semantics.
- **Worker slots.** `parallel_copy` already needs `max_worker_processes >= N+2`
  and fails toward loading zero rows when starved. In-COPY parallelism inherits
  that and must degrade to the serial path, not to a wrong row count, when slots
  are unavailable.
- **Ordering / row numbers.** Row numbers are reserved per stripe
  (`PgColumnarReserveRowNumbers`); parallel producers must keep a row's number
  and its data consistent, which `parallel_copy` already solves and this should
  reuse rather than re-derive.

## Recommendation

Measure-and-document is done; the serial residue is characterised. Before writing
this, the owner call is: **is parallelising the default single-connection COPY
worth a hot-path change, given `parallel_copy` already offers the bulk speed?** If
yes, structure (1) (pipeline the compression) is where I would start, because it
targets the dominant remaining term with the smallest blast radius. If no, #445's
actionable content is complete -- the 3x is disproven, the defects are fixed,
detoast-once is in flight, and the rest is a compression trade with a bulk escape
hatch that beats heap.
