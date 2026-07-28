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

**Corrected after measurement (#160). Step 1 as written would have delivered
close to nothing, and that was worth finding before someone spent a month on
it.**

This plan reasoned that the waste is the per-row round trip, so a batching entry
point should come first and would "amortise the per-call overhead" even on its
own. If per-call overhead were the cost, a one-column load would show it as
clearly as a five-column one, since it is the same rows and the same number of
`table_tuple_insert` calls. Measured, 3,000,000 rows:

| shape | heap | columnar | |
| --- | --- | --- | --- |
| 1 int column | 1272.4 ms | **908.1 ms** | **0.71x, faster than heap** |
| 5 int columns | 1364.1 ms | 3697.0 ms | 2.7x |
| 1 text column | 1284.3 ms | 4680.1 ms | 3.6x |
| 5 mixed, one text | 1494.7 ms | 8604.8 ms | 5.8x |

At one integer column the columnar write path beats heap. There is no per-call
overhead to amortise. The cost is per value and roughly additive per column,
about 900 ms per numeric column and about 4,600 ms for a text column, so the 4.9x
this plan opens with is really "five columns, one of them text".

Two further results from the same measurement: compression is not a factor
(`none` is 2% faster than `zstd 3`, `lz4` indistinguishable), and ablation puts
zone min/max tracking at 15 to 17% of the remaining per-value cost with no other
single dominant term. #160 took that piece: comparing integer-family values
directly instead of through fmgr, and testing the maximum first so an ascending
load costs one comparison per value, for 5 to 7%.

So the revised order is:

1. **The varlena write path.** One text column costs more than five integer
   columns, and that is where the 4.9x lives. Measure before designing: the
   ablation above did not separate encoding selection from the value stream from
   the flush for text specifically.
2. **Column-at-a-time transfer** for the cases where the reader's representation
   and the writer's already agree, judged per column type rather than per
   nullability and width combination, since type is what the measurement says
   dominates.
3. **A batching entry point**, if anything above still wants one. It is not the
   place to start and may not be needed at all.

## Re-measured after #202, and what is left

Step 1 has since been half answered by `encode_effort` (#202), so the numbers
above no longer describe the tree. Re-measured on PostgreSQL 17.10 non-assert,
**6,000,000 rows**, ratios against a heap insert of the same rows (ratios rather
than millisecond counts, so common-mode load on the box cancels):

| shape | effort=full | effort=fast | what fast recovers |
| --- | --- | --- | --- |
| 1 text column, low cardinality (`'name-'||(g%1000)`) | 3.83x | **3.01x** | 21% |
| 1 text column, high entropy (`sha256`, 76 chars) | 6.48x | **1.94x** | 70% |
| 5-col mixed, low-cardinality text | 5.59x | 5.55x | nothing |
| 5-col mixed, high-entropy text | 8.83x | **4.13x** | 53% |

And the per-column cost, integers only, no encoding search in play:

| shape | heap | columnar | ratio |
| --- | --- | --- | --- |
| 1 column (bigint) | 2501 ms | **1671 ms** | **0.67x, faster than heap** |
| 2 columns | 2318 ms | 2636 ms | 1.14x |
| 4 columns | 2674 ms | 6744 ms | 2.52x |

Three things follow, and they redirect what is left of this issue.

**The knob solved the case it was built for, and only that case.** On high-entropy
text `encode_effort = fast` takes 6.48x to 1.94x, which is near parity with heap
for a format writing a fraction of the bytes. That is step 1 delivered for the
shape where the FSST search was the cost.

**It does not touch low-cardinality text, which is the more common shape.** Names,
regions, categories, statuses: 3.83x becomes 3.01x, a fifth of it. `fast` skips
the FSST search, so by elimination the remaining 3.01x is *not* FSST -- it is the
dictionary path, the value stream, zone maps and compression. Nothing has
attributed that yet, and the 5-column low-cardinality row shows why it matters:
5.59x with the knob doing nothing at all. **This is the first thing to measure,
and it should be an ablation, not a design.**

**The per-column numeric cost is real and additive.** One bigint column beats
heap; four integer columns cost 2.5x it. Heap is nearly flat across the same
range (2501 to 2674 ms) because row overhead dominates and narrow columns are
almost free to add. Columnar pays roughly 1 to 2 seconds per extra column per 6M
rows. That is the tax on wide tables, and it is independent of text entirely.

**A note on what column-at-a-time can and cannot buy.** Step 2 above applies only
to `import_arrow` / `import_parquet`, where a column store is genuinely on both
ends. `INSERT ... SELECT` has no columnar source -- the rows arrive from a heap
scan -- so the per-row shape is not removable there, and the per-column costs
above are what would remain. Since import already measures the same as an
ordinary insert, step 2's ceiling is the slot round trip alone, not the encoding
work underneath it. Worth stating before anyone budgets for it.

### Revised order

1. **Ablate the low-cardinality text path** at `encode_effort = fast`, separating
   dictionary build, value stream, zone maps and compression. 3.01x with the
   shipped knob already applied is the number to explain. No design until it is
   attributed.
2. **The per-column numeric tax.** ~1 to 2 s per column per 6M rows, additive,
   and it sets the floor for every wide table regardless of type.
3. **Column-at-a-time transfer** for the importers only, scoped by what step 1
   and 2 leave on the table rather than by the original 4.9x.

The headline number in this document should be read as shape-dependent, not as a
single figure: measured today it ranges from **0.67x** (one integer column,
faster than heap) to **8.83x** (five columns with long high-entropy text at full
effort). "Bulk load is 4.9x slower than heap" was one point on that curve.

## Not in scope

`COPY` into a columnar table goes through the same write path, so it benefits
from anything that makes per-value work cheaper, which after the measurement
above is where the win is. Making `COPY` itself fast is a separate piece of work
with its own interface questions.

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
