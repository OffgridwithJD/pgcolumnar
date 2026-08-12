# Issue #426: pruning an infix LIKE with a per-vector substring filter

Plan, written before code, per the house rule. Read `CONTEXT.md` for the
vocabulary. Companion to `design/ISSUE_452_LATE_MATERIALIZATION.md` (phase 2,
merged in #584) and `design/ISSUE_452_PHASE2_DECODE_GATING.md`.

## DISPOSITION (2026-08-11): feasible, measured, NOT built

The design below is sound and the step-1 measurement was taken on real ClickBench
`hits` URLs (1,000,000 rows via duckdb; re-checked on the full 11.1M sample).
Result: reaching the ~91% prune ceiling (the initial 1M-row probe read ~93%, but
that is a prefix, and the `%google%` matches cluster, so the full sample is the
truer ~91% -- a prefix over-counts skippable vectors) costs **~8 bytes/row** on
the filtered string column (65536 bits per 1024-row
vector; real URLs carry ~7,251 distinct trigrams/vector, so a smaller filter
saturates and prunes nothing). On URL that is ~40% overhead on the column, ~6% of
the whole hits table, and it buys only q21/q22 (2.2x/1.8x) because q24 -- the big
5.87x loss -- is already won by phase 2 (#584). That is a worse storage trade than
the Route-B per-vector compression that was declined, for a narrower benefit. So
#426 was closed as resolved-what-matters; this doc is the record of why the
substring filter is not worth building at the current storage budget, kept so the
question is not re-opened a fourth time. Numbers below the design.

## What is already true, so this does not rediscover it

- **Equality and range on text push down and prune.** Not a type gap. The gap is
  the operator set `~~`, `!~~`, `<>`, which have no btree opfamily strategy
  (`columnar_customscan.c:479`). Measured by ChronicallyJD on hits_col.
- **Anchored `LIKE 'prefix%'` is a range and prunes** — shipped f493c61 / #510
  (`pgcolumnar_like_prefix_scankey`).
- **`<> ''` is a measured no.** Ceiling 0.00% on hits_col: it matches 99.93% of
  rows, so it leaves no vector empty of matches. Dropped from scope.
- **The wide-projection infix case (q24) is already won by phase 2 (#584).** An
  unprunable `LIKE '%x%'` yields `numPredicates == 0`, so phase 2 evaluates the
  executor qual per vector and skips the *payload* columns' decode for no-match
  vectors. Validated at scale: `SELECT *` under a 0.02%-selective LIKE ran 7.2x
  under the full-decode ceiling.

So the ONLY residue is the **narrow** infix shape: `count(*)`/one-column queries
filtered by `LIKE '%literal%'` — ClickBench q21 (`URL LIKE '%google%'`, 2.2x
slower) and q22 (1.8x). Phase 2 cannot help them: there is no payload to skip,
and the filter column itself must be examined. The whole cost is decoding `URL`
to match it.

## Why the issue's own idea (FSST compressed-needle search) is infeasible here

Established by reading the read path (`columnar_encoding.c`, `columnar_reader.c`),
not assumed. Three independent blockers:

1. **zstd wraps FSST.** A chunk's value stream is FSST-encoded *then*
   block-compressed. The block codec reverses the whole chunk before anything
   per-value applies, so the FSST code stream is not even visible without
   decompressing first. "Avoid decode" dies at layer one.
2. **FSST codes are not byte-searchable for an infix.** Variable-length greedy
   symbols mean a match can begin inside a stored symbol, so the needle
   compressed alone need not appear in the stored codes even on a true match.
3. **No value boundaries pre-decode.** Varlena length headers that delimit values
   exist only in the *decoded* stream, so a search of the compressed haystack
   cannot even say which value matched.

Conclusion: evaluating an infix against the stored *values* forces full per-vector
decode. Do not build that. The searchable structure has to live OUTSIDE the value
stream, in metadata read without touching it -- exactly where the equality bloom
filter already lives.

## The design: a per-vector substring n-gram filter in the zone-map metadata

At write time, for a string column, hash every **n-gram** (default n=3) of every
value in a vector into a small bloom filter, stored in that vector's zone-map
metadata beside min/max and the equality bloom. At read time, a
`col LIKE '%literal%'` with a literal of length >= n is prunable: if the filter
lacks ANY n-gram of `literal`, no value in the vector can contain it, so the
vector is ruled out -- its decode (and, through phase 2's machinery, the payload)
is skipped. This is the equality bloom (gap 25) generalised from whole values to
substrings.

Properties that decide the design:

- **It is checked without decompressing the value stream**, so it beats the zstd
  bound the compressed-needle idea could not: the filter is metadata, not values.
- **Conservative in the safe direction.** A missing n-gram proves absence; a
  present set only *fails to prove* absence (false positives from bloom collisions
  and from non-contiguous n-grams). So it can only rule a vector OUT, never IN --
  the executor still rechecks survivors. Missing a skip costs time; a wrong skip
  would drop rows, and this cannot take a wrong one.
- **It reaches q21/q22, which phase 2 cannot**, because it prunes the *filter*
  column's own decode, not just the payload.
- **Literals shorter than n are not prunable** (no full n-gram) and fall back to
  today's full scan. `%google%` (6 chars, 4 trigrams) is well covered.

## The ceiling, which must be measured before building (peer's rule, four times)

The realisable prune fraction is bounded above by the fraction of vectors that
contain no match, and below by nothing until we measure false positives. Step 1
is a measurement, no code in the reader:

- On hits_col-like data, decode `URL` per 1024-row vector, build the trigram set,
  and for `%google%` count vectors missing >= 1 of google's trigrams (safely
  prunable) vs vectors that pass the filter but do not contain `google` (false
  positives). Report both, and the same for a chosen filter *size* (bits/vector),
  because the false-positive rate is the whole question -- a filter too small
  prunes nothing after collisions, one too large costs storage on every string
  column whether or not anyone queries it.
- The prune ceiling is ~91% (the zero-match vector fraction ChronicallyJD
  measured for `%google%`); the deliverable is how close a bounded-size filter
  gets to it, and what it costs on disk.

## Owner decision this raises (storage, like Route B)

A substring filter is storage spent on every string column at write time against
a query pattern that may never run. `n`, the bits per vector, and whether it is
opt-in per column (a table option) or always-on are an owner call, exactly the
shape of the Route B storage decision. The measurement gives the cost side; the
value side is q21/q22 only (q24 is already phase 2's). **Not to be built until
the measured cost/benefit is on the issue and approved.**

## Order of work

1. **Measure** the trigram prune ceiling and false-positive-vs-size curve for
   `%google%` on real-ish data. Report on #426. Owner decides go/no-go and filter
   sizing. (This doc's immediate next step.)
2. Writer: build and serialise the per-vector substring filter (new zone-map
   field; a format-version bump). Confirm it rides the existing zone-map/bloom
   WAL path and needs no new WAL semantics (extension constraint).
3. Reader: recognise an unanchored `~~` in `pgcolumnar_clause_to_scankey`
   (`columnar_customscan.c:474`) and carry it as a new predicate kind; extend
   `refine_skipvec` to rule out a vector whose filter lacks a needle n-gram --
   the non-btree predicate the peer flagged, kept strictly conservative.
4. TDD throughout: a RED suite asserting a selective `%literal%` decodes far fewer
   vectors than the literal's absence would, with a removal proof, plus a
   correctness differential against heap and a matches-everything control.
