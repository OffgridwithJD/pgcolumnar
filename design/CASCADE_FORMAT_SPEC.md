# Cascaded encodings: format specification and the decisions it needs

Written 2026-07-25 after sample selection landed (#124), revised after the review
of #125 found that the first version specified the wrong thing. No code has been
written. Two decisions in here are the owner's rather than mine, and one of them
determines whether the descriptor below is the right one at all.

## What cascading is meant to buy

Encode the output of one scheme with another. The pairings that motivate it:

- a dictionary's **codes** are small integers, so frame-of-reference plus
  bit-packing shrinks them further;
- run-length's **count stream** bit-packs well;
- delta output is often run-heavy.

Read those carefully, because they are the crux of the first decision: every one
of them names a *component* of a scheme's output, not the whole of it.

## The format today

The per-chunk `encoding_descriptor` in `pgcolumnar.column_chunk` is:

```
[uint8  version]        COLUMNAR_NATIVE_ENCDESC_VERSION = 3
[uint8  flags]          bit 0 NO_VALIDITY: this chunk stored no validity bitmap
[uint32 vectorCount]
[vectorCount entries of 13 bytes]
    [uint8  encodingType]
    [uint32 valueCount]
    [uint32 rawLen]
    [uint32 encLen]
[uint32 sharedTableLen]     optional, FSST's chunk-shared symbol table
[sharedTableLen bytes]
```

The entry's field ORDER above is `valueCount, rawLen, encLen`, which is what
`columnar_encdesc.h` writes and reads (offsets 1, 5, 9 within the entry). This
block previously named them in the wrong order; no code ever followed it.

Version 3 (#1130) spends the byte version 2 wrote as a zero reserved byte. A
version-2 descriptor is therefore a version-3 one whose flags are all clear:
every field keeps its offset, and a reader needs no second parse. Writers emit
`COLUMNAR_NATIVE_ENCDESC_VERSION`; readers accept anything from
`COLUMNAR_NATIVE_ENCDESC_MIN_READABLE` (2) upward, because tables written by an
older build must keep reading.

`NO_VALIDITY` says the chunk held no null and its validity bitmap was therefore
not written: the page is `[encoded]` rather than `[validity][encoded]`. It is a
property of ONE CHUNK -- one column can hold nulls while its neighbour does not
-- so every reader decides the bitmap's size per chunk rather than once per row
group from `ceil(rowCount / 8)`.

Verified: the descriptor is versioned, and `columnar_reader.c` rejects a version
it does not recognize with `ERRCODE_DATA_CORRUPTED` before reading anything
else, so version 2 and version 3 chunks coexist in one table.

## Decision 1: which feature is being built

These are different features and the earlier draft of this spec conflated them.

**Whole-output chaining.** Scheme B consumes A's entire output as an opaque
stream. The descriptor is simple, but the value is doubtful: A's output is not a
uniform vector of the column's type, so most of the interesting Bs (frame-of
reference, bit-packing, delta) have nothing to grip. This is the feature the
earlier draft specified, and none of the motivating pairings are actually this.

**Component cascading.** Scheme B encodes a *named component* of A's output: the
dictionary's codes, run-length's counts. This is what every candidate pairing
describes, and it is where the ratio win is. It is also the larger change: each
scheme has to expose its output as named components with their own lengths and
counts, and the descriptor has to say which component each stage encodes.

**Recommendation: component cascading, descoped to dictionary codes first.** The
dictionary case is the single highest-value pairing, it is the one whose component
is already a clean array of fixed-width codes, and it can ship with a descriptor
that only knows about one component per stage. Run-length counts come second, once
the shape has proven itself.

If the answer is whole-output chaining after all, this spec's descriptor is close
to right and the candidate list needs rewriting. If it is component cascading, the
descriptor below is the one to implement.

## THE VERSION NUMBER THIS DOCUMENT PROPOSES IS TAKEN (2026-09-18)

This spec was written when the next descriptor version was free. It is not:
**#1130 spent version 3** on the header's flags byte, so that a chunk holding no
null can say it stored no validity bitmap -- 16.8% of a real ClickBench table.
That change keeps every existing field at its offset and adds no per-vector
bytes, so it is compatible in shape with everything below; only the number
moves.

**Read every "version 3" below as "the next version", which is now 4.** The two
decisions the sections below record -- when a table starts writing it, and what
the entry looks like -- are unaffected. Decision 2's recommendation is now
partly settled by precedent rather than by argument: #1130 took the
unconditional break, so a second one costs an operator nothing new if it ships
in the same release, and rather more if it ships later.

## Decision 2: when a table starts writing the new version

- **Unconditionally, once the feature ships.** The break is deterministic and tied
  to the upgrade, so it is one CHANGELOG line: chunks written after this version
  are not readable by older builds.
- **Only when a chain is actually chosen.** More tables stay compatible, but the
  break becomes *data-triggered*: a table an old binary reads today stops being
  readable after a routine `INSERT` whose chunk happened to pick a chain. No
  version bump, no setting change, nothing in the operator's control, and not
  reproducible from the table definition.
- **Behind a per-table option, default off.** Nothing changes until asked for; the
  win sits behind a switch most people never find.

**Recommendation: unconditional**, with a small addition either way: a function
answering "does this table contain any version 3 chunks?", so a downgrade
checklist can test the thing it actually cares about instead of inferring it.

An earlier draft of this spec recommended the data-triggered variant. That was
wrong for the reason above: it trades a predictable break for an unpredictable
one, which is worse to operate even though it breaks fewer tables.

## Proposed entry for the NEXT version, 4 (component cascading, one component per stage)

```
[uint8  chainLen]          1..PGCN_MAX_CHAIN (proposed 3)
[uint8  encodingType[3]]   stage schemes, unused slots COLUMNAR_ENCODING_NONE
[uint8  component[3]]      which component of the previous stage each encodes
[uint8  reserved]
[uint32 valueCount]        the vector's logical value count
[uint32 rawLen]            decoded raw byte length
[uint32 encLen]            final encoded byte length
[uint32 stageLen[2]]       byte length of each intermediate stage's output
[uint32 stageCount[2]]     value count of each intermediate stage's output
```

36 bytes rather than 13.

The intermediate lengths are not optional bookkeeping, which the earlier draft
missed. The decoders do not self-describe: `decode_rle` and friends are *told*
their output shape, taking `rawLen` to size the allocation and `n` to terminate
the loop, both from the descriptor. Decoding a chain runs the last stage first,
and that stage needs the length and count of the intermediate it produces.
Without them the reader is guessing. The alternative, making every encoding's
output self-describing, changes every encoder's on-disk bytes and is a much larger
change than this one.

`chainLen == 1` expresses exactly what version 2 expresses, so the new version is
a superset -- of version 3 as well, whose flags byte sits in the header and is
untouched by anything here.

## Guards, each needing a test that fails without it

Same class of risk as the Parquet reader's three crafted-file bugs: a
file-declared value used without a range check.

- `chainLen` outside 1..`PGCN_MAX_CHAIN`, checked before it drives the loop.
- Each `encodingType` a known code, and each `component` valid for the scheme that
  produced it, checked before dispatch.
- Each `stageLen` and `stageCount` consistent with the neighbouring stages, so a
  truncated or spliced descriptor fails rather than decoding garbage. This is
  checkable only because the lengths are stored.
- `NONE` must not appear before the end of the chain.

Deliberately **not** a guard: rejecting a chain that repeats a scheme. That
encodes today's opinion about useful chains into the reader, so a future writer
that finds a repeated scheme worthwhile would produce data that older-but-still
version 3 readers reject. Length and count validation is what keeps the decode
loop bounded; repetition is a writer's business.

## Sequencing, once both decisions are made

Steps 1 and 2 cannot be sized until decision 1 is settled: if the answer is
component cascading, exposing components is step 0 and it is the bulk of the work.

0. (component cascading only) Give each participating scheme a component view:
   what its output is made of, each with a length and a count.
1. Version 3 read path plus the guards and their crafted-descriptor tests.
   Reading before writing, so a bad writer cannot produce unreadable data.
2. Chain application in `ColumnarEncodeChunk`, one pairing at a time, each landing
   with its measured win.
3. Selection through the windowed sample from #124.
4. Benchmark before and after on the 6M-row load: size and load time together,
   since a chain costs write time to save space.
5. Full 15 through 19 matrix, with `differential` and `fuzz` as the real net: they
   compare against a heap oracle and will catch a chain that decodes wrong.
