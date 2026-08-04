/*-------------------------------------------------------------------------
 *
 * pgcolumnar_flatbuffers.h
 *		A minimal FlatBuffers builder.
 *
 * FlatBuffers is the serialization format Arrow uses for its IPC metadata, and
 * nothing in this module knows about Arrow or about pgColumnar: it prepends
 * scalars, vectors, tables and vtables into a buffer. It is separated for that reason, so both
 * directions sit together and can be read against the format description rather
 * than against an Arrow file.
 *
 * The buffer is built back to front: data occupies buf[cap - tail .. cap), and
 * an object's identity is its "tail" value, the number of bytes from the end,
 * captured right after the object is written.
 *
 * The short fb_ names are this module's namespace and are kept deliberately,
 * unlike the PgColumnarThrift* naming next door: the call sites are dense
 * (pgc_fb_add_i32(b, 0, bits, 0) appears in runs of a dozen), and lengthening them
 * would cost more in readability there than the consistency buys.
 *
 * What stays with Arrow, and why:
 *
 *   pgc_fb_arrow_type   maps a column type onto Arrow's Type union. That is Arrow
 *                   semantics expressed through this builder, not part of it.
 *   fbr_*           the read-side scalar accessors raise Arrow's own
 *                   "malformed Arrow IPC file" on a short buffer. Moving them
 *                   would either leak that message into a format-neutral module
 *                   or change it. They are 43 lines and stay where their error
 *                   belongs.
 *
 * Written fresh for pgColumnar from the public FlatBuffers format description.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PGCOLUMNAR_FLATBUFFERS_H
#define PGCOLUMNAR_FLATBUFFERS_H

#include "postgres.h"

/* ---- builder ---- */

typedef struct FBB
{
	uint8	   *buf;
	uint32		cap;
	uint32		tail;
	uint32		minalign;
	/* current table under construction */
	int			nslots;
	uint32		objectEnd;
	uint32		vslot[16];
}			FBB;

extern void pgc_fb_init(FBB *b);
extern void pgc_fb_grow(FBB *b, uint32 need);
extern void pgc_fb_place(FBB *b, const void *src, uint32 n);
extern void pgc_fb_pad(FBB *b, uint32 n);
extern uint32 pgc_fb_offset(FBB *b);
extern void pgc_fb_prep(FBB *b, uint32 size, uint32 additional);
extern void pgc_fb_push_u8(FBB *b, uint8 v);
extern void pgc_fb_push_i16(FBB *b, int16 v);
extern void pgc_fb_push_i32(FBB *b, int32 v);
extern void pgc_fb_push_i64(FBB *b, int64 v);
extern void pgc_fb_push_uoffset(FBB *b, uint32 off);
extern void pgc_fb_start_vector(FBB *b, uint32 elemSize, uint32 count, uint32 align);
extern uint32 pgc_fb_end_vector(FBB *b, uint32 count);
extern void pgc_fb_start(FBB *b, int nslots);
extern void pgc_fb_slot(FBB *b, int i);
extern void pgc_fb_add_i16(FBB *b, int i, int16 val, int16 def);
extern void pgc_fb_add_i32(FBB *b, int i, int32 val, int32 def);
extern void pgc_fb_add_i64(FBB *b, int i, int64 val, int64 def);
extern void pgc_fb_add_bool(FBB *b, int i, bool val, bool def);
extern void pgc_fb_add_u8(FBB *b, int i, uint8 val, uint8 def);
extern void pgc_fb_add_offset(FBB *b, int i, uint32 off);
extern uint32 pgc_fb_end(FBB *b);
extern void pgc_fb_finish(FBB *b, uint32 root);
extern uint32 pgc_fb_create_string(FBB *b, const char *s);

#endif							/* PGCOLUMNAR_FLATBUFFERS_H */
