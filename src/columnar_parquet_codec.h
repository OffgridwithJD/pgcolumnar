/*-------------------------------------------------------------------------
 *
 * columnar_parquet_codec.h
 *		Parquet data-page decompression.
 *
 * One entry point that turns a compressed page into bytes, dispatching on the
 * file's CompressionCodec. Snappy is decoded here from the format itself; gzip,
 * zstd and lz4_raw go to the system libraries when the build has them and are
 * refused cleanly when it does not.
 *
 * Separated from the import module because it is a property of the file format
 * and not of how rows are assembled: it can be read against the codec
 * specifications alone.
 *
 * Written fresh for pgColumnar from the public Apache Parquet specification and
 * the public Snappy format description.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PGCOLUMNAR_PARQUET_CODEC_H
#define PGCOLUMNAR_PARQUET_CODEC_H

#include "postgres.h"

#include "lib/stringinfo.h"

/*
 * Decompress one page. On success *out points at usize bytes, either into src
 * (uncompressed) or into scratch, and the caller must not free either. Returns
 * false on malformed input, on a codec this build cannot decode, and on any
 * length that disagrees with the page header.
 */
extern bool ColumnarParquetDecompress(int codec, const uint8 *src, size_t srclen,
									  size_t usize, StringInfo scratch,
									  const uint8 **out, size_t *outlen);

#endif							/* PGCOLUMNAR_PARQUET_CODEC_H */
