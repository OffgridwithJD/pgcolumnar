/*-------------------------------------------------------------------------
 *
 * pgcolumnar_thrift.h
 *		Thrift compact-protocol reader and writer.
 *
 * The protocol is the container Parquet uses for its file metadata, and nothing
 * here knows anything about Parquet or about pgColumnar: it moves varints,
 * zigzag integers, field headers and list headers in and out of a buffer. It is
 * separated for that reason, so the two directions sit together and can be read
 * against the protocol specification rather than against a Parquet file.
 *
 * Written fresh for pgColumnar from the public Apache Thrift compact-protocol
 * specification.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PGCOLUMNAR_THRIFT_H
#define PGCOLUMNAR_THRIFT_H

#include "postgres.h"

#include "lib/stringinfo.h"

#include "columnar_parquet_format.h"

/* ---- reader: a cursor over an in-memory buffer ---- */

typedef struct TCReader
{
	const uint8 *buf;
	size_t		len;
	size_t		pos;
	bool		error;
} TCReader;

extern uint64 PgColumnarThriftVarint(TCReader *r);
extern int64 PgColumnarThriftZigzag(TCReader *r);
extern const uint8 *PgColumnarThriftBytes(TCReader *r, uint32 *outlen);
extern void PgColumnarThriftField(TCReader *r, int *ftype, int *fid, int *lastId);
extern void PgColumnarThriftSkip(TCReader *r, int ftype);
extern uint32 PgColumnarThriftListHeader(TCReader *r, int *etype);

/* ---- writer: appends into a StringInfo ---- */

extern void PgColumnarThriftPutVarint(StringInfo b, uint64 v);
extern void PgColumnarThriftPutZigzag32(StringInfo b, int32 v);
extern void PgColumnarThriftPutZigzag64(StringInfo b, int64 v);
extern void PgColumnarThriftPutField(StringInfo b, int16 *lastId, int16 id, int type);
extern void PgColumnarThriftPutI32Field(StringInfo b, int16 *lastId, int16 id, int32 v);
extern void PgColumnarThriftPutI64Field(StringInfo b, int16 *lastId, int16 id, int64 v);
extern void PgColumnarThriftPutStringField(StringInfo b, int16 *lastId, int16 id,
										 const char *s, int len);
extern void PgColumnarThriftPutListHeader(StringInfo b, int size, int elemType);
extern void PgColumnarThriftPutStop(StringInfo b);

#endif							/* PGCOLUMNAR_THRIFT_H */
