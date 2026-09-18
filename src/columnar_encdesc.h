/*-------------------------------------------------------------------------
 *
 * columnar_encdesc.h
 *		Wire codec for the native encoding descriptor (PGCN v1, descriptor
 *		version 2). The descriptor is the writer -> reader contract for a column
 *		chunk's per-vector encoding, and its byte layout was hand-packed in
 *		columnar_write_state.c and hand-parsed in three passes in
 *		columnar_reader.c. Add or reorder a field there and every one of those
 *		disjoint sites had to change in step, or a reader stride would land
 *		mid-field -- and because the version byte does not move on a field change,
 *		the version guard would pass and the mismatch would surface as
 *		DATA_CORRUPTED or wrong values in production.
 *
 * This puts the field offsets and widths in ONE place. The writer appends
 * through PgColumnarEncdescPut*, the readers advance through
 * PgColumnarEncdescReadEntry, and COLUMNAR_NATIVE_ENCDESC_ENTRY_LEN is tied to
 * the field widths by a StaticAssert (in columnar_write_state.c), so a field change is
 * one edit here that cannot silently desync the two sides.
 *
 * The on-disk bytes are unchanged from the hand-packed form: the Put helpers make
 * the identical appendBinaryStringInfo sequence, and the Read helpers read the
 * identical offsets. Proven byte-identical (native_encdesc_golden).
 *
 *-------------------------------------------------------------------------
 */
#ifndef COLUMNAR_ENCDESC_H
#define COLUMNAR_ENCDESC_H

#include "lib/stringinfo.h"

#include "columnar.h"			/* COLUMNAR_NATIVE_ENCDESC_* constants */

/* header: version u8, flags u8, vectorCount u32 (COLUMNAR_NATIVE_ENCDESC_HEADER_LEN) */
#define COLUMNAR_ENCDESC_HDR_OFF_VERSION 0
#define COLUMNAR_ENCDESC_HDR_OFF_FLAGS 1
#define COLUMNAR_ENCDESC_HDR_OFF_VECCOUNT 2

/* per-vector entry: type u8, valueCount u32, rawLen u32, encLen u32 (…ENTRY_LEN) */
#define COLUMNAR_ENCDESC_OFF_VALUECOUNT 1
#define COLUMNAR_ENCDESC_OFF_RAWLEN		(1 + (int) sizeof(uint32))
#define COLUMNAR_ENCDESC_OFF_ENCLEN		(1 + 2 * (int) sizeof(uint32))

/* one decoded per-vector entry */
typedef struct PgColumnarEncdescEntry
{
	uint8		type;
	uint32		valueCount;
	uint32		rawLen;
	uint32		encLen;
} PgColumnarEncdescEntry;

/*
 * Append the descriptor header: version + flags + vectorCount.
 *
 * FLAGS IS AN ARGUMENT WITH NO DEFAULT, deliberately. The convenience wrapper
 * that passed 0 was left behind by #1130 with no callers, and a zero flags byte
 * is no longer a neutral value: it asserts that this chunk DID store a validity
 * bitmap. A writer that wants that has to say so.
 */
static inline void
PgColumnarEncdescPutHeaderFlags(StringInfo desc, uint32 vectorCount, uint8 flags)
{
	uint8		version = COLUMNAR_NATIVE_ENCDESC_VERSION;

	appendBinaryStringInfo(desc, (char *) &version, 1);
	appendBinaryStringInfo(desc, (char *) &flags, 1);
	appendBinaryStringInfo(desc, (char *) &vectorCount, sizeof(uint32));
}

/*
 * Whether a reader understands this descriptor's version. Callers that have
 * already checked descLen may pass the header directly.
 */
static inline bool
PgColumnarEncdescVersionSupported(const char *desc)
{
	uint8		v = (uint8) desc[COLUMNAR_ENCDESC_HDR_OFF_VERSION];

	return v >= COLUMNAR_NATIVE_ENCDESC_MIN_READABLE &&
		v <= COLUMNAR_NATIVE_ENCDESC_VERSION;
}

/*
 * Whether this column chunk OMITTED its validity bitmap because it held no
 * nulls (#1130).
 *
 * A PROPERTY OF ONE CHUNK, not of the row group: one column can hold nulls
 * while its neighbour does not, so this cannot be decided once per group the
 * way ceil(rowCount / 8) was before v3. Callers already hold that group-wide
 * size and use it unchanged when this returns false, which is why this answers
 * the question rather than recomputing the length.
 *
 * A version-2 descriptor has a zero byte where the flags now are, so it answers
 * false without a version test of its own, and the D2b baseline descriptor is
 * one byte long and answers false on the length check.
 */
static inline bool
PgColumnarEncdescOmitsValidity(const char *desc, uint32 descLen)
{
	if (desc == NULL || descLen < COLUMNAR_NATIVE_ENCDESC_HEADER_LEN)
		return false;
	if ((uint8) desc[COLUMNAR_ENCDESC_HDR_OFF_VERSION] ==
		COLUMNAR_NATIVE_ENCDESC_BASELINE)
		return false;
	return ((uint8) desc[COLUMNAR_ENCDESC_HDR_OFF_FLAGS] &
			COLUMNAR_ENCDESC_FLAG_NO_VALIDITY) != 0;
}

/* append one per-vector entry */
static inline void
PgColumnarEncdescPutEntry(StringInfo desc, uint8 type, uint32 valueCount,
						  uint32 rawLen, uint32 encLen)
{
	appendBinaryStringInfo(desc, (char *) &type, 1);
	appendBinaryStringInfo(desc, (char *) &valueCount, sizeof(uint32));
	appendBinaryStringInfo(desc, (char *) &rawLen, sizeof(uint32));
	appendBinaryStringInfo(desc, (char *) &encLen, sizeof(uint32));
}

/* read vectorCount from a header; caller has already checked descLen and version */
static inline uint32
PgColumnarEncdescReadVectorCount(const char *desc)
{
	uint32		vectorCount;

	memcpy(&vectorCount, desc + COLUMNAR_ENCDESC_HDR_OFF_VECCOUNT, sizeof(uint32));
	return vectorCount;
}

/*
 * Total values the per-vector entries account for, or -1 if the descriptor is
 * too short to walk. Used to check a NO_VALIDITY claim against the row count:
 * a chunk that stored no bitmap is asserting that every row of the group is
 * present in it, and that assertion has to be checked against something the
 * writer also recorded, or a corrupt row_count turns into phantom rows the
 * reader believes are there.
 */
static inline int64
PgColumnarEncdescTotalValueCount(const char *desc, uint32 descLen)
{
	uint32		vectorCount;
	uint64		total = 0;
	uint64		entriesEnd;
	uint32		i;

	if (desc == NULL || descLen < COLUMNAR_NATIVE_ENCDESC_HEADER_LEN)
		return -1;
	vectorCount = PgColumnarEncdescReadVectorCount(desc);
	entriesEnd = (uint64) COLUMNAR_NATIVE_ENCDESC_HEADER_LEN +
		(uint64) vectorCount * COLUMNAR_NATIVE_ENCDESC_ENTRY_LEN;
	if (entriesEnd > (uint64) descLen)
		return -1;
	for (i = 0; i < vectorCount; i++)
	{
		uint32		vc;

		memcpy(&vc, desc + COLUMNAR_NATIVE_ENCDESC_HEADER_LEN +
			   (Size) i * COLUMNAR_NATIVE_ENCDESC_ENTRY_LEN +
			   COLUMNAR_ENCDESC_OFF_VALUECOUNT, sizeof(uint32));
		total += vc;
	}
	return (int64) total;
}

/* read one per-vector entry at dp into *e; returns the cursor past it */
static inline const char *
PgColumnarEncdescReadEntry(const char *dp, PgColumnarEncdescEntry *e)
{
	e->type = (uint8) dp[0];
	memcpy(&e->valueCount, dp + COLUMNAR_ENCDESC_OFF_VALUECOUNT, sizeof(uint32));
	memcpy(&e->rawLen, dp + COLUMNAR_ENCDESC_OFF_RAWLEN, sizeof(uint32));
	memcpy(&e->encLen, dp + COLUMNAR_ENCDESC_OFF_ENCLEN, sizeof(uint32));
	return dp + COLUMNAR_NATIVE_ENCDESC_ENTRY_LEN;
}

#endif							/* COLUMNAR_ENCDESC_H */
