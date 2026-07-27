/*-------------------------------------------------------------------------
 *
 * columnar_parquet_format.h
 *		Parquet and Thrift compact-protocol constants, shared by the reader and
 *		the writer.
 *
 * These are values defined by the file format, not by this implementation, so
 * there is exactly one correct value for each and both directions must agree on
 * it. They were previously declared twice, once in columnar_parquet.c and once
 * in columnar_parquet_reader.c, with 21 names in common. The values did agree,
 * but nothing made them: a writer and a reader that disagree on a type code
 * produce a file that is silently wrong rather than one that fails to parse,
 * which is the worst shape a defect can take here.
 *
 * Only format constants belong in this file. A value this implementation chooses
 * for itself -- a buffer bound, a resolved-unit enum, a sentinel -- stays in the
 * module that chooses it, because it has no counterpart on the other side.
 *
 * Written fresh for pgColumnar from the public Apache Parquet and Apache Thrift
 * compact-protocol specifications.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PGCOLUMNAR_PARQUET_FORMAT_H
#define PGCOLUMNAR_PARQUET_FORMAT_H

/* Physical types (parquet.thrift Type) */
#define PQ_BOOLEAN				0
#define PQ_INT32				1
#define PQ_INT64				2
#define PQ_FLOAT				4
#define PQ_DOUBLE				5
#define PQ_BYTE_ARRAY			6
#define PQ_FIXED_LEN_BYTE_ARRAY 7

/* ConvertedType (parquet.thrift ConvertedType); -1 means none */
#define PQ_CT_UTF8				0
#define PQ_CT_ENUM				4
#define PQ_CT_DECIMAL			5
#define PQ_CT_DATE				6
#define PQ_CT_TIME_MILLIS		7
#define PQ_CT_TIME_MICROS		8
#define PQ_CT_TIMESTAMP_MILLIS	9
#define PQ_CT_TIMESTAMP_MICROS	10
#define PQ_CT_INT_8				15
#define PQ_CT_INT_16			16
#define PQ_CT_INT_32			17
#define PQ_CT_INT_64			18
#define PQ_CT_JSON				19

/* Encoding (parquet.thrift Encoding) */
#define PQ_ENC_PLAIN			0
#define PQ_ENC_RLE				3

/* LogicalType union field ids (parquet.thrift LogicalType) */
#define PQ_LT_TIME				7
#define PQ_LT_TIMESTAMP			8

/* TimeUnit union field ids (parquet.thrift TimeUnit) */
#define PQ_TUNIT_MILLIS			1
#define PQ_TUNIT_MICROS			2
#define PQ_TUNIT_NANOS			3

/* Page types (parquet.thrift PageType) */
#define PQ_PAGE_DATA			0
#define PQ_PAGE_DICTIONARY		2
#define PQ_PAGE_DATA_V2			3

/* Compression codecs (parquet.thrift CompressionCodec) */
#define PQC_UNCOMPRESSED		0
#define PQC_SNAPPY				1
#define PQC_GZIP				2
#define PQC_ZSTD				6
#define PQC_LZ4_RAW				7

/* Thrift compact-protocol field types */
#define TC_STOP					0
#define TC_BOOL_TRUE			1
#define TC_BOOL_FALSE			2
#define TC_BYTE					3
#define TC_I16					4
#define TC_I32					5
#define TC_I64					6
#define TC_DOUBLE				7
#define TC_BINARY				8
#define TC_LIST					9
#define TC_SET					10
#define TC_STRUCT				12

#endif							/* PGCOLUMNAR_PARQUET_FORMAT_H */
