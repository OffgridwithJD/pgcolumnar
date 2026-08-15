/*-------------------------------------------------------------------------
 *
 * columnar_puffin.h
 *		A targeted Puffin reader for Iceberg v3 deletion vectors (#388 phase
 *		4c). Not a general Puffin implementation: it reads the one blob type
 *		the Iceberg read path needs, deletion-vector-v1 (a portable 64-bit
 *		roaring bitmap of deleted row ordinals).
 *
 * Written fresh for pgColumnar from the public Apache Puffin specification
 * and the RoaringFormatSpec.
 *
 *-------------------------------------------------------------------------
 */
#ifndef COLUMNAR_PUFFIN_H
#define COLUMNAR_PUFFIN_H

#include "postgres.h"

/*
 * Decode the deletion vector at (blob_offset, blob_size) of a slurped Puffin
 * file. The footer is parsed and the blob validated against it: the offsets
 * must match a deletion-vector-v1 blob exactly (the Iceberg spec's
 * manifest/footer cross-check), the blob's referenced-data-file property must
 * equal referenced_path, the blob must not declare a compression codec, and
 * the blob's length prefix, magic, and CRC-32 must check out. Returns the
 * deleted row ordinals ascending in a palloc'd array in the current memory
 * context; *npos is the count. `path` names the file in error messages.
 * Raises on any malformed input rather than returning a partial result.
 */
extern void PgColumnarPuffinReadDeletionVector(const uint8 *buf, int64 len,
											   int64 blob_offset,
											   int64 blob_size,
											   const char *referenced_path,
											   const char *path,
											   uint64 **positions,
											   int64 *npos);

#endif							/* COLUMNAR_PUFFIN_H */
