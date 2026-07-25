# Cascaded encodings: format specification and the decision it needs

Written 2026-07-25, after step 1 of `CASCADE_ENCODING_PLAN.md` landed (sample
selection, #124). This specifies the format change cascading needs and states the
one decision that is the owner's rather than mine. No code has been written.

## What cascading is, in one paragraph

Encode the output of one scheme with another. Dictionary codes are small integers,
so frame-of-reference plus bit-packing shrinks them further; run-length produces a
value stream and a count stream, and the counts bit-pack well; delta output is
often run-heavy. The paper this comes from reports most of its ratio win from
exactly these pairings rather than from any single scheme. pgColumnar already has
every primitive; what it lacks is a way to say "these two, in this order" on disk.

## What the format looks like today

The per-chunk `encoding_descriptor` in `pgcolumnar.column_chunk` is:

```
[uint8  version]        currently COLUMNAR_NATIVE_ENCDESC_VERSION = 2
[uint8  reserved]
[uint32 vectorCount]
[vectorCount entries of 13 bytes]
    [uint8  encodingType]   one COLUMNAR_ENCODING_* code
    [uint32 rawLen]
    [uint32 encLen]
    [uint32 valueCount]
[uint32 sharedTableLen]     optional, FSST's chunk-shared symbol table
[sharedTableLen bytes]
```

Two facts make this cheaper to extend than the plan assumed:

- The descriptor **is already versioned**, and `columnar_reader.c` rejects an
  unrecognized version with a clean error rather than misreading it. A version 3
  can therefore coexist with version 2 in the same table.
- The entry is fixed-size, so a version 3 entry can be a different fixed size and
  the reader can still index entries without parsing forward.

## Proposed version 3 entry

```
[uint8  chainLen]        1..PGCN_MAX_CHAIN (proposed 3)
[uint8  encodingType[3]] applied in order; unused slots are COLUMNAR_ENCODING_NONE
[uint32 rawLen]
[uint32 encLen]
[uint32 valueCount]
```

16 bytes rather than 13. Decoding runs the chain in reverse. `chainLen == 1`
expresses exactly what version 2 expresses, so version 3 is a superset and there
is no shape that only the old format can describe.

### Guards, each needing a test that fails without it

The reader must not trust any of this. The Parquet reader's three crafted-file
bugs were all a file-declared value used without a range check, and this is the
same class:

- `chainLen` outside 1..`PGCN_MAX_CHAIN` is a corrupt descriptor, checked before
  it drives the decode loop.
- Each `encodingType` in the chain must be a known code, checked before dispatch.
- A chain must not repeat a scheme that is not idempotent, and must not contain
  `NONE` before its end. Both are cheap structural checks and both prevent a
  decode loop that does not terminate in the shape the writer intended.
- The intermediate length after each stage must be consistent with the next
  stage's input, so a truncated or spliced descriptor fails rather than decoding
  garbage.

### Candidate chains worth measuring first

Each is a claim about data shape, and each should be justified by a measured win
on the 6M-row benchmark before it ships, not by the paper's numbers on their data:

- dictionary then frame-of-reference (low-cardinality columns)
- dictionary then bit-packing (same, narrower codes)
- run-length then bit-packing (the count stream)
- delta then run-length (smooth-then-repetitive columns)

Selection reuses the sampling selector from #124: estimate the chain on the same
windowed sample, apply only the best.

## The decision that is not mine

**When does a table start writing version 3 descriptors?**

- **Option A, version bump on write.** New chunks write version 3 as soon as the
  build supports it. Simple, and every table benefits without action. The cost is
  that an older binary reading a newer table gets a clean error rather than data,
  which is a real operational break for anyone who downgrades or runs mixed
  binaries against the same data directory.
- **Option B, per-table option, default off.** `cascade_encodings = on` per table,
  or a GUC. Nothing changes until asked for, so a downgrade stays safe until
  someone opts in. The cost is that the win sits behind a switch most people will
  never find, and the option becomes permanent surface area.

My recommendation is **A with a documented floor**: write version 3 only when a
chain is actually chosen, so a table whose columns never benefit stays readable by
older builds, and document the downgrade break plainly in the CHANGELOG and
`limitations.md`. That keeps the common case compatible and makes the
incompatibility something a user opts into by having data that benefits, rather
than by flipping a switch they have to learn about.

That recommendation is a judgement about your users' upgrade discipline, which is
why it is written here for a decision rather than implemented.

## Sequencing once the decision is made

1. Version 3 descriptor read path plus the guards and their crafted-descriptor
   tests. Reading before writing, so a bad writer cannot produce unreadable data.
2. Chain application in `ColumnarEncodeChunk`, one pairing at a time, each with
   its measured win.
3. Selection through the existing windowed sample.
4. Benchmark before and after on the 6M-row load: size and load time together,
   since a chain costs write time to save space.
5. Full 15 through 19 matrix, with `differential` and `fuzz` as the real net:
   they compare against a heap oracle and will catch a chain that decodes wrong.
