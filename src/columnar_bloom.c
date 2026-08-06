/*-------------------------------------------------------------------------
 *
 * pgcolumnar_bloom.c
 *		Per-chunk bloom filters for equality chunk-group skipping (I7).
 *
 * min/max skip lists (spec 7.2) prune equality predicates only when the probed
 * value falls outside a chunk's range. For an unsorted column an equality probe
 * usually falls inside every chunk's range, so nothing is skipped and a point
 * lookup decodes every chunk group -- the documented point-lookup weakness. A
 * bloom filter per chunk lets an equality probe skip a chunk group when the
 * value is provably absent, with a small false-positive rate.
 *
 * The filter is stored as [uint32 nbits][uint8 k][ceil(nbits/8) bytes], nbits a
 * power of two so a bit index is hash & (nbits-1). k positions per value are
 * derived from one 32-bit hash by double hashing. Build and probe hash values
 * the same way (the type's hash opclass proc), so a set built over a chunk's
 * values answers membership for a probe of the same type.
 *
 * Written from the standard bloom-filter construction and the public PostgreSQL
 * hashing API only (clean-room; see PROVENANCE.md).
 *
 *-------------------------------------------------------------------------
 */
#include "columnar.h"

#include "access/htup_details.h"
#include "catalog/pg_collation.h"
#include "utils/syscache.h"

/*
 * PgColumnarCollationIsDeterministic
 *		Whether a bloom filter is safe for this collation: InvalidOid (a
 *		non-collatable type) and deterministic collations qualify; a
 *		nondeterministic collation does not, since equal values need not be
 *		byte-identical and would hash inconsistently.
 */
bool
PgColumnarCollationIsDeterministic(Oid collid)
{
	HeapTuple	tp;
	bool		result = true;

	if (!OidIsValid(collid))
		return true;

	tp = SearchSysCache1(COLLOID, ObjectIdGetDatum(collid));
	if (HeapTupleIsValid(tp))
	{
		result = ((Form_pg_collation) GETSTRUCT(tp))->collisdeterministic;
		ReleaseSysCache(tp);
	}
	return result;
}

/* target ~1% false positives: ~10 bits/value, 6 probes */
#define BLOOM_BITS_PER_VALUE 10
#define BLOOM_K 6
#define BLOOM_MIN_BITS 64
#define BLOOM_MAX_BITS (1u << 21)	/* 256 KB cap per chunk */

static uint32
next_pow2(uint32 x)
{
	uint32		p = BLOOM_MIN_BITS;

	while (p < x && p < BLOOM_MAX_BITS)
		p <<= 1;
	return p;
}

/*
 * How many DISTINCT hashes are in the array (#467).
 *
 * A filter used to be sized from the value count, which is the stripe's row
 * count, so every bloomable column of every stripe got the same
 * next_pow2(n * BLOOM_BITS_PER_VALUE) bits whatever its cardinality: a column
 * with five distinct values got the 256 KB filter a unique column got. Measured
 * on 2M ClickBench rows that was 19.3x over-provisioned, 361 MB of filters
 * against a 262 MB table, and 29 percent of load time.
 *
 * A bloom filter's membership set IS its distinct set, so sizing from the
 * distinct count is a size and time change and not a semantic one: a filter
 * built over distinct hashes answers every probe exactly as the old one did.
 *
 * Open addressing over a power-of-two table at load factor <= 0.5, which is what
 * keeps the probe sequence short; the table is transient and freed before this
 * returns. Hash 0 cannot be stored in a zeroed table because it is
 * indistinguishable from an empty slot, so it is counted separately rather than
 * given a sentinel -- one branch, and no value is excluded from the filter.
 */
static uint32
bloom_distinct_count(const uint32 *hashes, uint32 n)
{
	uint32	   *tab;
	uint32		cap;
	uint32		mask;
	uint32		distinct = 0;
	bool		sawZero = false;
	uint32		i;

	/* Two slots per value, rounded up, so the table stays half empty. */
	cap = 1;
	while ((uint64) cap < (uint64) n * 2 && cap < (1u << 30))
		cap <<= 1;
	mask = cap - 1;
	tab = (uint32 *) palloc0((Size) cap * sizeof(uint32));

	for (i = 0; i < n; i++)
	{
		uint32		h = hashes[i];
		uint32		slot;

		if (h == 0)
		{
			if (!sawZero)
			{
				sawZero = true;
				distinct++;
			}
			continue;
		}

		slot = h & mask;
		while (tab[slot] != 0)
		{
			if (tab[slot] == h)
				break;
			slot = (slot + 1) & mask;
		}
		if (tab[slot] == 0)
		{
			tab[slot] = h;
			distinct++;
		}
	}

	pfree(tab);
	return distinct;
}

/* two derived hashes for double hashing; h2 forced odd for full coverage */
static inline void
bloom_hashes(uint32 h, uint32 *h1, uint32 *h2)
{
	*h1 = h;
	*h2 = ((h >> 16) | (h << 16)) | 1u;
}

/*
 * PgColumnarBloomBuild
 *		Build a filter over n precomputed value hashes. Returns false (no filter)
 *		when n is too small for a filter to be worthwhile.
 */
bool
PgColumnarBloomBuild(const uint32 *hashes, uint32 n, char **out, uint32 *outLen)
{
	uint32		nbits;
	uint32		nbytes;
	uint32		total;
	char	   *buf;
	unsigned char *bits;
	uint8		k = BLOOM_K;
	uint32		i;
	uint32		d;				/* distinct hashes; what the filter is sized for */

	if (n < 64)
		return false;			/* min/max and per-group scan suffice */

	/*
	 * Sizing is from the DISTINCT count, not the value count (#467). See
	 * bloom_distinct_count above for why that is equivalent rather than a
	 * trade-off.
	 *
	 * The `n < 64` guard above deliberately stays on the VALUE count. It means
	 * "this chunk is too small to be worth a filter at all", which is a statement
	 * about the chunk and not about its cardinality. Moving it to the distinct
	 * count would drop the filter entirely from every low-cardinality column --
	 * 68 of 105 on the ClickBench fixture -- and those are exactly the columns
	 * where an equality probe skips best: if the value is not among the five
	 * present, the whole group goes. A 64-bit filter costs 8 bytes.
	 */
	d = bloom_distinct_count(hashes, n);

	/*
	 * Refuse to build a filter the cap cannot size properly. Once
	 * d * BLOOM_BITS_PER_VALUE exceeds BLOOM_MAX_BITS, next_pow2 clamps and the
	 * bits-per-value falls below the ~10 this k was chosen for. The filter then
	 * saturates: almost every bit is set, so the probe answers "may be present"
	 * for everything while still costing 256 KB per column per stripe to store
	 * and read. No filter is better than one that never skips, and the reader
	 * already treats an absent filter as "may match".
	 *
	 * This tests the DISTINCT count now. It used to test n, which refused a
	 * filter to a large stripe of low-cardinality data for a problem that data
	 * does not have: the saturation this guards against is a function of how many
	 * distinct values compete for the bits, not how many times they repeat.
	 *
	 * This also keeps the multiply below in range: past this point it would
	 * overflow uint32 for a large enough d.
	 */
	if ((uint64) d * BLOOM_BITS_PER_VALUE > BLOOM_MAX_BITS)
		return false;

	nbits = next_pow2(d * BLOOM_BITS_PER_VALUE);
	nbytes = nbits / 8;
	total = sizeof(uint32) + sizeof(uint8) + nbytes;

	buf = palloc0(total);
	memcpy(buf, &nbits, sizeof(uint32));
	buf[sizeof(uint32)] = (char) k;
	bits = (unsigned char *) buf + sizeof(uint32) + sizeof(uint8);

	for (i = 0; i < n; i++)
	{
		uint32		h1;
		uint32		h2;
		int			j;

		bloom_hashes(hashes[i], &h1, &h2);
		for (j = 0; j < k; j++)
		{
			uint32		pos = (h1 + (uint32) j * h2) & (nbits - 1);

			bits[pos >> 3] |= (unsigned char) (1u << (pos & 7));
		}
	}

	*out = buf;
	*outLen = total;
	return true;
}

/*
 * PgColumnarBloomProbe
 *		Return true when the hash may be present (all k bits set), false when it
 *		is definitely absent. A malformed/empty filter conservatively returns
 *		true (never skips wrongly).
 */
bool
PgColumnarBloomProbe(const char *bloom, uint32 bloomLen, uint32 hash)
{
	uint32		nbits;
	uint8		k;
	const unsigned char *bits;
	uint32		h1;
	uint32		h2;
	int			j;

	if (bloom == NULL || bloomLen < sizeof(uint32) + sizeof(uint8))
		return true;

	memcpy(&nbits, bloom, sizeof(uint32));
	k = (uint8) bloom[sizeof(uint32)];
	bits = (const unsigned char *) bloom + sizeof(uint32) + sizeof(uint8);
	if (nbits == 0 || (nbits & (nbits - 1)) != 0)
		return true;			/* not a power of two: treat as no filter */

	/* the persisted length must actually hold the bitset; a corrupt header with
	 * a large nbits over a short buffer must not be indexed out of bounds */
	if ((uint64) bloomLen < sizeof(uint32) + sizeof(uint8) + ((uint64) nbits + 7) / 8)
		return true;			/* malformed: treat as no filter */

	bloom_hashes(hash, &h1, &h2);
	for (j = 0; j < k; j++)
	{
		uint32		pos = (h1 + (uint32) j * h2) & (nbits - 1);

		if (((bits[pos >> 3] >> (pos & 7)) & 1) == 0)
			return false;		/* a required bit is unset: definitely absent */
	}
	return true;
}
