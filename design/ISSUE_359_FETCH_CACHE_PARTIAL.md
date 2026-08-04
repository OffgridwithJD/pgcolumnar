# #359: make fetch-cache overflow proportional instead of a cliff

Status: design, 2026-08-03. Successor to #353/#357. Coupled to #355 (merged as #360).

## The defect

`columnar_fetch_row` (`src/columnar_reader.c`) ends every fetch with:

```c
if (MemoryContextMemAllocated(entry->cx, true) > COLUMNAR_FETCH_CACHE_MAX_BYTES)
    columnar_fetch_entry_reset(entry);
```

That is all-or-nothing. An entry one byte over the 32 MB cap is not retained at
all, so the next fetch into the same group re-reads the group's bytes from disk
**and** re-decodes every column it touches. Measured on the 100M TSBS fixture,
holding rows and plan shape constant and varying only the number of aggregated
columns: 4 columns 2,833 ms, 5 columns 134,147 ms. A 47x step, flat either side.

#357 shrank entries ~3x by moving decode scratch out. That moved the threshold
from "any wide table" to "five or more aggregate columns". It did not change the
shape of the failure, and raising the cap would not either.

## What the entry already gets right

Decoding is **already per column and lazy**: `entry->rawBuf[c]` is filled only
when column `c` is actually touched, and a column outside the projection is
neither read nor decoded. The cache is therefore already column-granular on the
way *in*. It is only the eviction that is whole-entry.

That is the whole fix: make eviction as granular as admission already is.

## Design: stable per-column admission

Keep, always:

- `groupBuffer` — the group's raw bytes. This is the on-disk (encoded,
  compressed) form, and retaining it alone removes the per-fetch `ColumnarReadLogicalData`
  disk read even when no column stays resident.
- `rankPrefix[c]` and `valOffset[c]` — the position indexes from #143. These are
  small relative to the decoded stream (`rankPrefix` is 4 bytes per 64 rows;
  `valOffset` is 4 bytes per value against a value that is typically wider), and
  they remain **valid for a re-decode**, because decoding the same chunk bytes is
  deterministic and produces the same layout. Keeping them is what stops #143's
  quadratic from coming back through the overflow path.

Evict, per column:

- After a column is decoded *and its value has been extracted*, if the entry is
  over the cap, delete just that column's decoded stream and mark the column
  overflowed. From then on that column decodes into the per-fetch scratch
  context (`tmp`) and is freed with it.

Admission order is attribute order, which is deterministic, so the resident set
is **stable**: the same columns stay resident on every fetch into that group.

### Why the resident set must be stable, not LRU

This is the load-bearing decision. An LRU eviction *within* the entry is the
obvious design and it is wrong here. The access pattern is cyclic: each fetch
touches columns 0..n-1 in order. LRU against a cyclic access pattern whose
working set exceeds the cache evicts precisely the entry about to be needed —

- fetch 1 decodes 0,1,2,3,4; over cap, LRU evicts 0
- fetch 2 wants 0: miss, decode; over cap, LRU evicts 1
- fetch 2 wants 1: miss, decode; over cap, LRU evicts 2 ...

— giving a 100% miss rate, i.e. exactly today's behaviour with more bookkeeping.
A stable resident set of `k` of `n` columns re-decodes `n - k` per fetch. That is
the proportionality the issue asks for, and it is why "retain what fits" has to
mean *first-fit, then stop*, not *keep the hottest*.

### Memory bound — as designed, and as it actually turned out

**As designed.** The entry transiently exceeds the cap by one column's decoded
stream and is then trimmed back under it, so steady-state residency is <= cap per
entry, 4 entries. If `groupBuffer` *alone* exceeds the cap, every column overflows
and the entry would hold an unbounded raw buffer, so that case is guarded
explicitly by not caching the entry at all.

**Correction (issue #364).** That is not the bound this achieves, and the claim
"keeps the bound at 4 x cap" was wrong. The per-column release trims the decoded
*streams*. It cannot trim `rankPrefix` and `valOffset`, which stay in the entry
context deliberately so a released column keeps constant-time row reach.
`valOffset` is four bytes per value per varlena column, ~600 KB per column at the
default `stripe_row_limit`, so enough varlena columns put the retained indexes
alone over the cap — after which every newly decoded column is released
immediately and the entry stops shrinking.

Measured on 150,000 rows x 60 `text` columns, forced index scan over 200 rows:

```
columnar fetch column | n=2 | total=18 MB     <- the columns that stayed resident
columnar fetch group  | n=1 | total=44 MB     <- groupBuffer + retained indexes
ALL columnar fetch contexts total: 62 MB      <- against a 32 MB cap
```

The real bound is `4 x (cap + retained position indexes + groupBuffer)`. On that
shape the speedup is also only 1.14x (127,699 ms against 145,132 ms before this
design), because almost everything overflows.

Releasing `valOffset` alongside the stream was built and measured, and is a worse
trade: it holds the bound (62 MB -> 28 MB) at a cost of 47% in time
(127,699 ms -> 187,521 ms). Rebuilding offsets is a second O(values) walk on every
fetch, not a constant factor on a decode that was happening anyway. The retained
indexes are what make an overflowed column cheap on its next fetch.

The bound and the speed are in genuine tension on wide varlena tables: holding
offsets for 60 varlena columns at a 150,000-row group needs ~34 MB and does not fit
in a 32 MB cap. This design chooses the speed; #364 records the trade rather than
pretending the bound holds.

### Two details that will bite

1. **Baseline encoding aliases the group buffer.** When the encoding descriptor
   is `COLUMNAR_NATIVE_ENCDESC_BASELINE`, `rawBuf[c] = base + validityBytes` —
   a pointer *into* `groupBuffer`, not an allocation. It costs nothing to retain
   and must never be "evicted" (that would be a free of an interior pointer).
   Only a decoded stream is evictable.

2. **The value must be extracted before the eviction.** `ColumnarDecodeValue`
   copies into the caller's context for every case (by-value returns the datum;
   fixed-length and varlena both `MemoryContextAlloc(targetContext)` + `memcpy`),
   so freeing the column's stream after extraction is safe — but only after.

## Consistency with #355

`columnar_index_fetch_penalty` (`src/columnar_customscan.c:638`) currently has:

```c
/* #359 cliff: a group too wide to cache is re-decoded on every fetch */
if ((double) rel->reltarget->width * R > (double) COLUMNAR_FETCH_CACHE_MAX_BYTES)
    groups_decoded = groups_max;
```

That branch models the cliff this change removes. It must soften to the overflow
fraction: when the decoded group exceeds the cap, the share of the decode that
repeats per fetch is the share of the projection that does not fit, so the
penalty scales by that fraction rather than jumping to "every group re-decoded".

## Test

`test/native_fetch_cache.sh`'s #353 case measures `count(*), max(u)` — a
two-column projection — across two group sizes. That shape never crosses the
relocated cap, which is why it went green on the query family that still cliffs.
Both the issue author and the reviewer generalised from a single projection
width; the test has to vary the axis that was held constant.

Add a case that **varies projection width** at fixed group size, and assert the
absence of a step rather than an absolute time: crossing the cap must cost
proportionally more, not multiples more.

Per `prove-guards-by-removal`: the new check must be shown to fail with this
change reverted, on the same container, before it counts.
