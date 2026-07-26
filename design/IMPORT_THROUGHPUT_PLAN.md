# Plan: import and bulk-load throughput

`docs/benchmarks.md` records import at about 18x slower than export and calls it
the clearest optimisation target in the interop path, attributing it to "the full
insert path including encoding selection and index maintenance". Measuring it says
that description is wrong in two ways, and the real target is a different one.

## Measured, PostgreSQL 17.10 non-assert, 6,000,000 rows, 5 columns

| step | ms |
| --- | --- |
| heap `INSERT INTO ... SELECT` | 2,667.9 |
| columnar `INSERT INTO ... SELECT`, no file involved | 12,989.6 |
| `export_arrow` | 881.9 |
| `import_arrow` | 12,150.2 |
| `export_parquet` | 1,012.5 |
| full scan of the Parquet file through `read_parquet` | 1,415.0 |
| `import_parquet` | 12,956.6 |
| `read_parquet` feeding `INSERT INTO ... SELECT` | 13,629.9 |
| columnar `INSERT`, exhaustive encoding selection (`encoding_sample_rows = 0`) | 20,103.2 |

Three things follow.

**Import is not slower than an ordinary insert.** `import_arrow` at 12,150 ms
against `INSERT INTO ... SELECT` at 12,990 ms for the same rows. There is no
import-specific overhead to remove. The headline in the benchmark document, "import
is 18x slower than export", is really "the columnar write path is about 15x slower
than the read path", and import merely inherits it.

**The readers are not the bottleneck.** Scanning the whole Parquet file through
`read_parquet` costs 1,415 ms, 11% of the 12,957 ms import. The other 89% is the
write path.

**Encoding selection is a real cost but not the dominant one.** Turning sampling
off costs 55% more (20,103 against 12,990), so the selection that remains after
sampling is a minority of the write path rather than its bulk.

And for scale: the columnar write path is 4.9x slower than a heap insert of the
same rows, which is the wrong direction for a format that writes about a hundredth
of the bytes.

## The target

The write path, reached in a way that avoids its per-row shape.

Both readers decode a column-oriented file into per-row `Datum` arrays, hand each
row to `table_tuple_insert`, and the write path copies each value back into
per-column buffers. Arrow and PGCN are both columnar; the row is a costume worn
between two column stores for the length of one function call.

**The main proposal is a column-at-a-time import.** For a column whose Arrow or
Parquet representation matches what the writer wants, move the values from the
decoded column buffer into the writer's column buffer directly, once per chunk,
rather than per row through a slot. Fixed-width non-null columns are the easy and
common case and can be close to a memcpy. Nullable and varying-length columns need
the validity bitmap and offsets translated but still avoid the per-row round trip.

That is bounded below by the reader cost of 1,415 ms, so the plausible target is
somewhere between 3 and 5 seconds against today's 13, not the 1.4 the reader alone
suggests.

## Order

1. **A batching entry point.** Give the write path a way to accept many rows at
   once, as `table_multi_insert` does for COPY, and have both importers use it.
   This is worth doing first even without the column-wise work: it amortises the
   per-call overhead and it is what the column-wise path needs underneath.
2. **Column-wise transfer for the simple cases.** Fixed-width, no nulls, type
   matches exactly. Measure before extending: if this does not move the number,
   the model above is wrong and the rest should not be built on it.
3. **Nullable and varying-length columns**, if step 2 pays.
4. **Encoding selection reuse across chunks of the same column.** The selector
   re-decides per vector; a column whose first several chunks all chose the same
   encoding is unlikely to want a different one, and the sample cost could be
   skipped after a run of agreement. This is the smallest of the four and should
   be measured on its own, since it is easy to convince oneself it helps.

## Not in scope

`COPY` into a columnar table goes through the same write path and would benefit
from step 1, but making `COPY` fast is a separate piece of work with its own
interface questions. Worth noting so the batching entry point is not designed so
narrowly that only the importers can use it.

## What must not change

Index maintenance is being fixed separately in #153, and whichever resolution that
takes, this work must not quietly reintroduce the same gap: a batched or
column-wise path still has to produce index entries, or still has to refuse to run
on an indexed table. The differential import tests should run against an indexed
target once #153 adds one.

The importers must also keep raising on malformed input rather than writing
partial data, which the hardening suites already assert.

## Testing

Throughput work is easy to "prove" with a number that moved for another reason,
so:

- **Correctness is differential and unchanged**: the existing round-trip suites
  compare imported tables against their source, and they must pass untouched.
  Add a target with an index once #153 lands.
- **The claim is a ratio, not a millisecond count**: assert that importing N rows
  costs less than some multiple of scanning the same file through `read_parquet`,
  which is the floor. That is portable across machines in a way a fixed threshold
  is not, and it is the number the design is actually about.
- **Every step measured on its own**, against the step before it, on an idle
  machine, with the figures recorded in the commit. The table above is the
  baseline to beat.

## Effort

2 to 4 dev-months for two people. Step 1 is well understood; the risk is
concentrated in step 2, where the number of type and nullability combinations
decides how much of the win is reachable before the special cases stop being worth
it.
