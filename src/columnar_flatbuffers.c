/*-------------------------------------------------------------------------
 *
 * columnar_flatbuffers.c
 *		A minimal FlatBuffers builder. See columnar_flatbuffers.h.
 *
 * Written fresh for pgColumnar from the public FlatBuffers format description.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "utils/memutils.h"

#include "columnar_flatbuffers.h"

/* -------------------------------------------------------------------------
 * Minimal FlatBuffers builder (little-endian). The buffer is built back to
 * front: data occupies buf[cap - tail .. cap); an object's identity is its
 * "tail" value (bytes from the end) captured right after it is written.
 * ------------------------------------------------------------------------- */

void
fb_init(FBB *b)
{
	b->cap = 256;
	b->buf = palloc(b->cap);
	b->tail = 0;
	b->minalign = 1;
	b->nslots = 0;
	b->objectEnd = 0;
}

void
fb_grow(FBB *b, uint32 need)
{
	uint64		want;
	uint32		newcap;
	uint8	   *nb;

	if (b->cap - b->tail >= need)
		return;
	/* compute the new capacity in 64-bit to avoid a uint32 doubling overflow */
	want = (uint64) b->cap * 2;
	while (want < (uint64) b->tail + need)
		want *= 2;
	if (want > MaxAllocSize)
		elog(ERROR, "columnar: arrow metadata buffer too large");
	newcap = (uint32) want;
	nb = palloc(newcap);
	memcpy(nb + newcap - b->tail, b->buf + b->cap - b->tail, b->tail);
	pfree(b->buf);
	b->buf = nb;
	b->cap = newcap;
}

/* prepend n raw bytes (already in final order) */
void
fb_place(FBB *b, const void *src, uint32 n)
{
	fb_grow(b, n);
	b->tail += n;
	memcpy(b->buf + b->cap - b->tail, src, n);
}

void
fb_pad(FBB *b, uint32 n)
{
	if (n == 0)
		return;
	fb_grow(b, n);
	b->tail += n;
	memset(b->buf + b->cap - b->tail, 0, n);
}

uint32
fb_offset(FBB *b)
{
	return b->tail;
}

/* align so that, after `additional` more bytes plus a `size`-aligned scalar are
 * written, the scalar lands aligned (relative to the eventually-aligned end). */
void
fb_prep(FBB *b, uint32 size, uint32 additional)
{
	uint32		alignsize;

	if (size > b->minalign)
		b->minalign = size;
	alignsize = ((~(b->tail + additional)) + 1) & (size - 1);
	fb_pad(b, alignsize);
}

void
fb_push_u8(FBB *b, uint8 v)
{
	fb_prep(b, 1, 0);
	fb_place(b, &v, 1);
}
void
fb_push_i16(FBB *b, int16 v)
{
	fb_prep(b, 2, 0);
	fb_place(b, &v, 2);
}
void
fb_push_i32(FBB *b, int32 v)
{
	fb_prep(b, 4, 0);
	fb_place(b, &v, 4);
}
void
fb_push_i64(FBB *b, int64 v)
{
	fb_prep(b, 8, 0);
	fb_place(b, &v, 8);
}

/* prepend a uoffset that references object at `off` (bytes-from-end) */
void
fb_push_uoffset(FBB *b, uint32 off)
{
	uint32		v;

	fb_prep(b, 4, 0);
	v = (fb_offset(b) + 4) - off;
	fb_place(b, &v, 4);
}

/* ---- vectors ---- */
void
fb_start_vector(FBB *b, uint32 elemSize, uint32 count, uint32 align)
{
	fb_prep(b, 4, elemSize * count); /* length prefix */
	fb_prep(b, align, elemSize * count);	/* element alignment */
}

uint32
fb_end_vector(FBB *b, uint32 count)
{
	fb_prep(b, 4, 0);
	fb_place(b, &count, 4);		/* length prefix precedes the elements */
	return fb_offset(b);
}

/* ---- tables ---- */
void
fb_start(FBB *b, int nslots)
{
	int			i;

	Assert(nslots <= 16);
	b->nslots = nslots;
	for (i = 0; i < nslots; i++)
		b->vslot[i] = 0;
	b->objectEnd = fb_offset(b);
}

void
fb_slot(FBB *b, int i)
{
	b->vslot[i] = fb_offset(b);
}

void
fb_add_i16(FBB *b, int i, int16 val, int16 def)
{
	if (val == def)
		return;
	fb_push_i16(b, val);
	fb_slot(b, i);
}
void
fb_add_i32(FBB *b, int i, int32 val, int32 def)
{
	if (val == def)
		return;
	fb_push_i32(b, val);
	fb_slot(b, i);
}
void
fb_add_i64(FBB *b, int i, int64 val, int64 def)
{
	if (val == def)
		return;
	fb_push_i64(b, val);
	fb_slot(b, i);
}
void
fb_add_bool(FBB *b, int i, bool val, bool def)
{
	if (val == def)
		return;
	fb_push_u8(b, val ? 1 : 0);
	fb_slot(b, i);
}
void
fb_add_u8(FBB *b, int i, uint8 val, uint8 def)
{
	if (val == def)
		return;
	fb_push_u8(b, val);
	fb_slot(b, i);
}
void
fb_add_offset(FBB *b, int i, uint32 off)
{
	if (off == 0)
		return;
	fb_push_uoffset(b, off);
	fb_slot(b, i);
}

uint32
fb_end(FBB *b)
{
	uint32		objectOffset;
	uint32		vtOffset;
	int32		soff;
	int			i;
	int16		objsize;
	int16		vtsize;
	int32		zero = 0;

	/* soffset placeholder = table location */
	fb_prep(b, 4, 0);
	fb_place(b, &zero, 4);
	objectOffset = fb_offset(b);

	/* vtable: field voffsets (high slot first), then objsize, then vtsize */
	for (i = b->nslots - 1; i >= 0; i--)
	{
		int16		voff = b->vslot[i] ? (int16) (objectOffset - b->vslot[i]) : 0;

		fb_place(b, &voff, 2);
	}
	objsize = (int16) (objectOffset - b->objectEnd);
	fb_place(b, &objsize, 2);
	vtsize = (int16) ((b->nslots + 2) * 2);
	fb_place(b, &vtsize, 2);

	vtOffset = fb_offset(b);
	soff = (int32) (vtOffset - objectOffset);
	memcpy(b->buf + b->cap - objectOffset, &soff, 4);
	return objectOffset;
}

void
fb_finish(FBB *b, uint32 root)
{
	fb_prep(b, b->minalign, 4);
	fb_push_uoffset(b, root);
}

uint32
fb_create_string(FBB *b, const char *s)
{
	uint32		n = (uint32) strlen(s);
	uint8		zero = 0;

	fb_prep(b, 4, n + 1);
	fb_place(b, &zero, 1);		/* null terminator */
	fb_place(b, s, n);			/* characters (s[0] ends lowest) */
	{
		uint32		len = n;

		fb_place(b, &len, 4);	/* length prefix (already aligned) */
	}
	return fb_offset(b);
}

/* ---- bounds-checked little-endian FlatBuffers reader ---- */
