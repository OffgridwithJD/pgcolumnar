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
 * the field widths by a StaticAssert (columnar_encdesc.c), so a field change is
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

/* header: version u8, reserved u8, vectorCount u32 (COLUMNAR_NATIVE_ENCDESC_HEADER_LEN) */
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

/* append the descriptor header (version + reserved + vectorCount) */
static inline void
PgColumnarEncdescPutHeader(StringInfo desc, uint32 vectorCount)
{
	uint8		version = COLUMNAR_NATIVE_ENCDESC_VERSION;
	uint8		reserved = 0;

	appendBinaryStringInfo(desc, (char *) &version, 1);
	appendBinaryStringInfo(desc, (char *) &reserved, 1);
	appendBinaryStringInfo(desc, (char *) &vectorCount, sizeof(uint32));
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
