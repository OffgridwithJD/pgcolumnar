# Adaptive cascade encoding selection

Plan written 2026-07-24, before any code. Covers the roadmap's "adaptive,
sample-based cascade encoding selection" item, sourced to BtrBlocks (SIGMOD 2023,
https://dl.acm.org/doi/10.1145/3589263). The roadmap calls it high value, low to
medium effort. This plan disagrees with the second half of that estimate and says
why, then structures the work so the cheap half can land without the expensive
half.

## What exists

`ColumnarEncodeChunk` (`src/columnar_encoding.c`) takes one chunk's raw value
stream and picks an encoding by **running every applicable encoder in full** and
keeping the smallest output. The candidate set already spans the axes: RLE,
frame-of-reference, delta, delta-of-delta, dictionary, Gorilla, ALP, and FSST.
Each encoder bails cheaply when it cannot help.

So pgColumnar already has adaptive per-chunk selection. What it does not have is
either of BtrBlocks' two actual ideas:

1. **Sampling.** Choose the encoding from a small sample instead of encoding the
   whole chunk with every candidate.
2. **Cascading.** Encode the *output* of one scheme with another, recursively:
   dictionary codes are integers and compress further with FOR plus bitpacking;
   RLE run lengths likewise.

These are independent. Cascading is where the size win is. Sampling is a
write-throughput optimization whose value depends entirely on what selection
currently costs, which nobody here has measured.

## Step 1: measure, and let the measurement decide

Do not write a sampling selector before knowing what it saves. The measurement:

- Instrument `ColumnarEncodeChunk` (a temporary build, not committed) to
  accumulate time spent per candidate encoder and total time in selection.
- Load the 6M-row benchmark (`bench/run_bench.sh`, per the standing rule that the
  full-scale bench is what catches scale bugs) and record: selection time as a
  fraction of total write time, and the same per column type, since a wide varlena
  column and a packable int column will differ.
- Report the number honestly, including if it is small. If selection is a few
  percent of write time, sampling is not worth its complexity and this step ends
  the sampling half of the work. That is a legitimate outcome, and cheaper to
  reach now than after building it.

Only if selection is a material fraction does the sampling selector get built:
estimate each candidate's size from a bounded sample (proposal: a strided sample
of about 1024 values, strided rather than prefix so a sorted or clustered column
is not misjudged), keep the top one or two candidates, and encode only those in
full. Correctness is unaffected either way, since the chosen encoding is recorded
per chunk; a worse choice costs size, never correctness. That asymmetry is what
makes sampling safe to tune later.

## Step 2: cascading, which is the actual win

Cascading changes the on-disk format, and that is the part the roadmap's "low to
medium effort" understates.

Today an encoding is one byte, one scheme. A cascade needs the chunk header to
express a *chain*: for example dictionary, then FOR, then bitpack. Options:

- **New codes for fixed useful chains.** For example one code meaning
  "dictionary codes, FOR-encoded". Simple, no format grammar change, but it does
  not compose and each new pairing needs another code.
- **A chain descriptor.** A small count plus a list of scheme bytes, so any chain
  is expressible and the decoder unwinds in reverse. More format work, and it is
  the shape that actually matches the paper.

Proposal: the chain descriptor, bounded to depth 3, with the depth bound enforced
on read as a corrupt-file guard rather than trusted. A file-declared chain length
is exactly the class of field that has produced three crafted-file bugs in the
Parquet reader; it gets a range check before it drives a loop, and a test that
fails without that check.

Format and compatibility, to be settled before code:

- PGCN v1 is the current format line and the reader must reject a chain it cannot
  decode with a clean error, not a wrong value.
- A new build reading old files is unaffected: no chains exist in them.
- An **old build reading new files is not possible**. That is a real
  compatibility break for anyone who has written data with an intermediate build,
  and it needs an explicit decision: either bump the format version so the failure
  is clear, or gate cascading behind a per-table option that defaults off until a
  version bump. Recommend the version bump, because a silent "your old binary
  cannot read this table" is worse than a loud one.
- Candidate chains worth measuring first: dictionary then FOR, dictionary then
  bitpack, RLE run-lengths then bitpack, delta then RLE. Each is a claim about
  data shape and each should be justified by a measured size win on the benchmark
  data before it ships, not by the paper's numbers on their data.

## What this does not include

Morsel-driven parallelism, data-centric JIT, and FastLanes-style vectorized
expression encoding are separate roadmap items. FastLanes in particular is a
format generation, not an increment on this one.

## Gating

Per PR: PostgreSQL 18 and 19. The differential, fuzz, and recovery suites are the
regression net that matters here, because this changes the on-disk value stream:
they compare against a heap oracle and will catch a cascade that decodes to the
wrong values. A full 15 through 19 matrix before the format change merges, and the
6M-row benchmark re-run with before and after numbers in the PR, since the whole
justification is size and speed.

## Step 1 result (measured 2026-07-25)

Measured on PostgreSQL 18.4, non-assert, 6,000,000 rows through a five-column
table chosen to exercise different encoders: a sequential bigint (delta family),
a low-cardinality int (RLE, dictionary), a scattered int (nothing helps), a float
(Gorilla, ALP), and repetitive text (FSST). One load per build, timed end to end.

Four builds, the last three produced by patching a throwaway copy rather than
instrumenting the shipped code:

| build | load | stored size |
| --- | --- | --- |
| baseline: try every candidate, keep the winner | 20.8 s | 8.59 MB |
| encode only the winner each column actually gets | 11.8 s | 8.59 MB |
| try every candidate, discard it, store raw | 21.2 s | 29.2 MB |
| skip selection entirely, store raw | 5.2 s | 29.2 MB |

The winners were read from `pgcolumnar.column_chunk` after a baseline load, then
pinned: bigint to delta-of-delta, both ints to frame-of-reference, float to
dictionary, text to FSST. The pinned build produces a byte-identical 8,585,216,
which is what confirms the pins really are the winners rather than a lucky guess.

Subtracting:

- **The winner's own encode: 6.6 s** (pinned minus no-selection).
- **Trials that lose and are thrown away: 9.0 s** (baseline minus pinned).
- Encoding buys 3.4x on this data (8.59 MB against 29.2 MB).

So the ceiling for a sampling selector is the 9.0 s of discarded trials, about
**43% of load time, a 1.76x speedup**, not the 4x that comparing against the
no-selection build would suggest. The winner still has to be encoded in full
whatever chooses it. Sampling also is not free: estimating from a sample costs
something, and a selector that guesses wrong pays a worse ratio.

Candidates tried per column, which is what sets that ceiling and is the number to
re-derive if the candidate set changes:

| column type | candidates | which |
| --- | --- | --- |
| packable int (int2/int4/int8) | 5 | RLE, FOR, delta, delta-of-delta, dictionary |
| float4/float8 | 4 | RLE, Gorilla, ALP, dictionary |
| other fixed-width | 2 | RLE, dictionary |
| varlena | 2 | dictionary, FSST |

**Decision: build the sampling selector.** A 1.76x ceiling on write throughput is
worth having, the mechanism is contained, and correctness is not at stake: the
chosen encoding is recorded per chunk, so a worse choice costs size rather than
correctness. Size is not free either, since a larger chunk is more bytes to read
and decompress on every scan that touches it, so a selector that trades ratio for
load speed has to be judged on both, not just on the load number.

Caveats kept with the numbers: one run per build, so the 2% gap between baseline
and try-then-discard is noise rather than a measurement; the ratios that drive
the decision are far outside it. Data shape drives everything here, and a table
of incompressible columns would spend less time in candidates that bail early.

Cascading (step 2) is unaffected by this result. It remains the size lever, and
it remains a format change, though a smaller one than the plan assumed: the
encoding descriptor is already versioned (`COLUMNAR_NATIVE_ENCDESC_VERSION`, now
2) with a fixed-size entry per vector, and `columnar_reader.c` rejects an
unrecognized version with a clean error. A version 3 entry carrying a chain can
therefore coexist with 2, and an older build meets a clear error rather than a
wrong value. The open decision is still whether new tables write version 3 by
default or only under a per-table option.
