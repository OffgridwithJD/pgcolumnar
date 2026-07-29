/*-------------------------------------------------------------------------
 *
 * columnar_thrift.c
 *		Thrift compact-protocol reader and writer.
 *
 * See columnar_thrift.h. Nothing here knows about Parquet or about pgColumnar.
 * The two directions were previously in separate files, the reader inside the
 * Parquet import module and the writer inside the export module, which put the
 * encode and decode of the same wire format a thousand lines apart.
 *
 * Written fresh for pgColumnar from the public Apache Thrift compact-protocol
 * specification.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "lib/stringinfo.h"
#include "miscadmin.h"

#include "columnar_thrift.h"

/* -------------------------------------------------------------------------
 * Thrift compact-protocol reader over an in-memory buffer.
 * ------------------------------------------------------------------------- */

uint64
ColumnarThriftVarint(TCReader *r)
{
	uint64		v = 0;
	int			shift = 0;

	while (r->pos < r->len)
	{
		uint8		b = r->buf[r->pos++];

		v |= (uint64) (b & 0x7f) << shift;
		if ((b & 0x80) == 0)
			return v;
		shift += 7;
		if (shift > 63)
			break;
	}
	r->error = true;
	return v;
}

int64
ColumnarThriftZigzag(TCReader *r)
{
	uint64		u = ColumnarThriftVarint(r);

	return (int64) (u >> 1) ^ -(int64) (u & 1);
}

/* read a binary/string field: returns pointer into the buffer and its length */
const uint8 *
ColumnarThriftBytes(TCReader *r, uint32 *outlen)
{
	uint64		n = ColumnarThriftVarint(r);
	const uint8 *p;

	/*
	 * Overflow-safe bounds check. n is a file-controlled 64-bit varint, so
	 * "r->pos + n > r->len" can wrap size_t: a crafted n near 2^64 wraps the
	 * sum back below r->len, passes the guard, and *outlen returns a truncated
	 * multi-gigabyte length against an in-bounds pointer. That length then flows
	 * to callers as a read bound (e.g. a column-chunk statistics min/max length
	 * used as the end sentinel in plain_value_to_datum), producing an
	 * out-of-bounds read and a backend crash on a hostile Parquet footer.
	 * r->pos <= r->len is an invariant here, so r->len - r->pos is the safe form.
	 */
	if (r->error || n > r->len - r->pos)
	{
		r->error = true;
		*outlen = 0;
		return NULL;
	}
	p = r->buf + r->pos;
	r->pos += n;
	*outlen = (uint32) n;
	return p;
}

/*
 * Read a struct field header. Returns the compact field type in *ftype (TC_STOP
 * at end of struct) and the absolute field id in *fid. lastId is updated for the
 * short-form delta encoding.
 */
void
ColumnarThriftField(TCReader *r, int *ftype, int *fid, int *lastId)
{
	uint8		b;

	if (r->pos >= r->len)
	{
		r->error = true;
		*ftype = TC_STOP;
		return;
	}
	b = r->buf[r->pos++];
	if (b == 0)
	{
		*ftype = TC_STOP;
		return;
	}
	*ftype = b & 0x0f;
	if ((b >> 4) != 0)
		*fid = *lastId + (b >> 4);	/* short-form delta */
	else
		*fid = (int) ColumnarThriftZigzag(r);	/* long form */
	*lastId = *fid;
}

/* skip a value of the given compact type (for fields we do not consume) */
void
ColumnarThriftSkip(TCReader *r, int ftype)
{
	/*
	 * A crafted footer can nest structs (or lists of structs) to any depth, and
	 * every unrecognised field in the metadata is skipped through here. Without
	 * this the recursion runs the C stack into its guard page and the backend
	 * SIGSEGVs, which the postmaster treats as a crash and restarts the whole
	 * cluster. check_stack_depth turns it into a caught ERROR.
	 */
	check_stack_depth();

	switch (ftype)
	{
		case TC_BOOL_TRUE:
		case TC_BOOL_FALSE:
			break;
		case TC_BYTE:
			r->pos += 1;
			break;
		case TC_I16:
		case TC_I32:
		case TC_I64:
			(void) ColumnarThriftZigzag(r);
			break;
		case TC_DOUBLE:
			r->pos += 8;
			break;
		case TC_BINARY:
			{
				uint32		n;

				(void) ColumnarThriftBytes(r, &n);
				break;
			}
		case TC_LIST:
		case TC_SET:
			{
				uint8		sizeType;
				uint32		size;
				int			et;
				uint32		i;

				if (r->pos >= r->len)
				{
					r->error = true;
					return;
				}
				sizeType = r->buf[r->pos++];
				size = (sizeType >> 4) & 0x0f;
				et = sizeType & 0x0f;
				if (size == 0x0f)
					size = (uint32) ColumnarThriftVarint(r);
				for (i = 0; i < size && !r->error; i++)
					ColumnarThriftSkip(r, et);
				break;
			}
		case TC_STRUCT:
			{
				int			lastId = 0;

				for (;;)
				{
					int			ft,
								fid;

					ColumnarThriftField(r, &ft, &fid, &lastId);
					if (ft == TC_STOP || r->error)
						break;
					ColumnarThriftSkip(r, ft);
				}
				break;
			}
		default:
			break;
	}
}

/* list header: returns element count and element compact type */
uint32
ColumnarThriftListHeader(TCReader *r, int *etype)
{
	uint8		b;
	uint32		size;

	if (r->pos >= r->len)
	{
		r->error = true;
		*etype = 0;
		return 0;
	}
	b = r->buf[r->pos++];
	size = (b >> 4) & 0x0f;
	*etype = b & 0x0f;
	if (size == 0x0f)
		size = (uint32) ColumnarThriftVarint(r);
	return size;
}

/* ---- Thrift compact-protocol writer (into a StringInfo) ---- */

void
ColumnarThriftPutVarint(StringInfo b, uint64 v)
{
	while (v >= 0x80)
	{
		appendStringInfoChar(b, (char) ((v & 0x7f) | 0x80));
		v >>= 7;
	}
	appendStringInfoChar(b, (char) v);
}

void
ColumnarThriftPutZigzag32(StringInfo b, int32 v)
{
	ColumnarThriftPutVarint(b, (uint32) ((v << 1) ^ (v >> 31)));
}

void
ColumnarThriftPutZigzag64(StringInfo b, int64 v)
{
	ColumnarThriftPutVarint(b, (uint64) ((v << 1) ^ (v >> 63)));
}

/* field header with delta-encoded id */
void
ColumnarThriftPutField(StringInfo b, int16 *lastId, int16 id, int type)
{
	int			delta = id - *lastId;

	if (delta > 0 && delta <= 15)
		appendStringInfoChar(b, (char) ((delta << 4) | type));
	else
	{
		appendStringInfoChar(b, (char) type);
		ColumnarThriftPutZigzag32(b, id);
	}
	*lastId = id;
}

void
ColumnarThriftPutI32Field(StringInfo b, int16 *lastId, int16 id, int32 v)
{
	ColumnarThriftPutField(b, lastId, id, TC_I32);
	ColumnarThriftPutZigzag32(b, v);
}

void
ColumnarThriftPutI64Field(StringInfo b, int16 *lastId, int16 id, int64 v)
{
	ColumnarThriftPutField(b, lastId, id, TC_I64);
	ColumnarThriftPutZigzag64(b, v);
}

void
ColumnarThriftPutStringField(StringInfo b, int16 *lastId, int16 id, const char *s, int len)
{
	ColumnarThriftPutField(b, lastId, id, TC_BINARY);
	ColumnarThriftPutVarint(b, (uint64) len);
	if (len > 0)
		appendBinaryStringInfo(b, s, len);
}

/* list header; caller then appends the elements */
void
ColumnarThriftPutListHeader(StringInfo b, int size, int elemType)
{
	if (size < 15)
		appendStringInfoChar(b, (char) ((size << 4) | elemType));
	else
	{
		appendStringInfoChar(b, (char) (0xF0 | elemType));
		ColumnarThriftPutVarint(b, (uint64) size);
	}
}

void
ColumnarThriftPutStop(StringInfo b)
{
	appendStringInfoChar(b, (char) TC_STOP);
}
