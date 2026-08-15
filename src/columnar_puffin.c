/*-------------------------------------------------------------------------
 *
 * columnar_puffin.c
 *		Iceberg v3 deletion vectors: a targeted Puffin container reader and a
 *		portable-roaring-bitmap decoder (#388 phase 4c).
 *
 * A Puffin file is `Magic Blob... Footer` with Footer = `Magic FooterPayload
 * FooterPayloadSize(4,LE) Flags(4) Magic`; the payload is JSON naming each
 * blob's type, offset, and length. A deletion-vector-v1 blob is `length(4,BE,
 * = 4 + vector bytes) | magic D1 D3 39 64 | portable 64-bit roaring bitmap |
 * CRC-32(4,BE, zlib polynomial, over magic+vector)`. The endianness split is
 * the spec's: the prefix and CRC are big-endian for Delta compatibility, the
 * roaring bitmap little-endian.
 *
 * The portable 64-bit roaring bitmap is `nbuckets(8,LE)` then, per bucket in
 * ascending key order, `key(4,LE)` + one full 32-bit roaring bitmap: cookie
 * 12346 (no run containers; container count follows) or 12347 (count in the
 * cookie's high 16 bits, then a run-marker bitset); a descriptive header of
 * (key, cardinality-1) pairs; an offset header (cookie 12346, or 12347 with
 * at least 4 containers) this decoder skips; then the containers in order:
 * array (sorted uint16s), bitset (8192 bytes), or run (count + (start,
 * length-1) pairs). Any other cookie aborts the decode.
 *
 * Everything is bounds-checked against the slurped buffer (the caller caps
 * the file size), and the emitted position count is capped so a hostile
 * bitmap of runs cannot balloon memory.
 *
 * Written fresh for pgColumnar from the public Apache Puffin specification
 * and the RoaringFormatSpec.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <zlib.h>

#include "catalog/pg_type_d.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"

#include "columnar_puffin.h"

#define PUFFIN_MAGIC "PFA1"
#define DV_MAGIC "\xD1\xD3\x39\x64"

#define ROARING_COOKIE_NO_RUN 12346
#define ROARING_COOKIE_RUN 12347

/* a deleted-ordinal set larger than this is refused, not ballooned: the
 * emitted array alone would be 8 bytes per position */
#define PUFFIN_MAX_POSITIONS ((int64) 16 * 1024 * 1024)

/* a bounded little-endian cursor over the vector bytes */
typedef struct PfCur
{
	const uint8 *p;
	const uint8 *end;
	const char *path;			/* for error messages */
}			PfCur;

static void
pf_need(PfCur *c, Size n)
{
	if ((Size) (c->end - c->p) < n)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: deletion vector in \"%s\" is truncated",
						c->path)));
}

static uint16
pf_u16(PfCur *c)
{
	uint16		v;

	pf_need(c, 2);
	v = (uint16) c->p[0] | ((uint16) c->p[1] << 8);
	c->p += 2;
	return v;
}

static uint32
pf_u32(PfCur *c)
{
	uint32		v;

	pf_need(c, 4);
	v = (uint32) c->p[0] | ((uint32) c->p[1] << 8) |
		((uint32) c->p[2] << 16) | ((uint32) c->p[3] << 24);
	c->p += 4;
	return v;
}

static uint64
pf_u64(PfCur *c)
{
	uint64		lo = pf_u32(c);
	uint64		hi = pf_u32(c);

	return lo | (hi << 32);
}

/* big-endian u32 at a raw pointer (the blob's prefix and CRC) */
static uint32
pf_be32(const uint8 *p)
{
	return ((uint32) p[0] << 24) | ((uint32) p[1] << 16) |
		((uint32) p[2] << 8) | (uint32) p[3];
}

/* the growable output set */
typedef struct PfOut
{
	uint64	   *pos;
	int64		n;
	int64		cap;
	const char *path;
}			PfOut;

static void
pf_emit(PfOut *o, uint64 v)
{
	if (o->n >= PUFFIN_MAX_POSITIONS)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("iceberg: deletion vector in \"%s\" names more than %lld positions",
						o->path, (long long) PUFFIN_MAX_POSITIONS)));
	if (o->n == o->cap)
	{
		o->cap = o->cap ? o->cap * 2 : 1024;
		o->pos = (o->pos == NULL)
			? (uint64 *) palloc(o->cap * sizeof(uint64))
			: (uint64 *) repalloc(o->pos, o->cap * sizeof(uint64));
	}
	o->pos[o->n++] = v;
}

/*
 * Decode one 32-bit roaring bitmap; emit each value OR'ed with `base` (the
 * bucket's high 32 bits already shifted).
 */
static void
pf_roaring32(PfCur *c, uint64 base, PfOut *out)
{
	uint32		cookie = pf_u32(c);
	uint32		size;
	const uint8 *runbits = NULL;
	uint16	   *keys;
	uint32	   *cards;
	uint32		i;

	if (cookie == ROARING_COOKIE_NO_RUN)
		size = pf_u32(c);
	else if ((cookie & 0xFFFF) == ROARING_COOKIE_RUN)
	{
		size = (cookie >> 16) + 1;
		pf_need(c, (size + 7) / 8);
		runbits = c->p;
		c->p += (size + 7) / 8;
	}
	else
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: deletion vector in \"%s\" has an unknown roaring cookie %u",
						c->path, cookie)));
	if (size > 65536)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: deletion vector in \"%s\" declares %u containers",
						c->path, size)));

	keys = (uint16 *) palloc(sizeof(uint16) * Max(size, 1));
	cards = (uint32 *) palloc(sizeof(uint32) * Max(size, 1));
	for (i = 0; i < size; i++)
	{
		keys[i] = pf_u16(c);
		cards[i] = (uint32) pf_u16(c) + 1;
	}
	/* the offset header exists in these two shapes; sequential reading makes
	 * it redundant, so it is skipped, not trusted */
	if (cookie == ROARING_COOKIE_NO_RUN ||
		((cookie & 0xFFFF) == ROARING_COOKIE_RUN && size >= 4))
	{
		pf_need(c, (Size) 4 * size);
		c->p += (Size) 4 * size;
	}

	for (i = 0; i < size; i++)
	{
		uint64		kbase = base | ((uint64) keys[i] << 16);
		bool		isrun = runbits != NULL && (runbits[i / 8] >> (i % 8) & 1);

		CHECK_FOR_INTERRUPTS();
		if (isrun)
		{
			uint16		nruns = pf_u16(c);
			uint16		r;

			for (r = 0; r < nruns; r++)
			{
				uint32		start = pf_u16(c);
				uint32		rlen = (uint32) pf_u16(c) + 1;
				uint32		v;

				/* a run lives inside one 16-bit container; start + length - 1
				 * must stay <= 0xFFFF, or the value would carry into the
				 * container-key bits and fabricate a position in another
				 * container -- refuse rather than corrupt ordinals */
				if (start + rlen > 0x10000)
					ereport(ERROR,
							(errcode(ERRCODE_DATA_CORRUPTED),
							 errmsg("iceberg: the deletion vector in \"%s\" has a run container that overflows its 16-bit range",
									c->path)));
				for (v = 0; v < rlen; v++)
					pf_emit(out, kbase | (start + v));
			}
		}
		else if (cards[i] <= 4096)
		{
			uint32		v;

			for (v = 0; v < cards[i]; v++)
				pf_emit(out, kbase | pf_u16(c));
		}
		else
		{
			uint32		w;

			pf_need(c, 8192);
			for (w = 0; w < 1024; w++)
			{
				/* pf_u64 reads lo then hi in ordered statements; an inline
				 * two-pf_u32 expression here would be unsequenced and could
				 * swap the halves under a right-first-evaluating compiler */
				uint64		word = pf_u64(c);
				int			b;

				if (word == 0)
					continue;
				for (b = 0; b < 64; b++)
					if (word >> b & 1)
						pf_emit(out, kbase | ((uint32) w * 64 + b));
			}
		}
	}
	pfree(keys);
	pfree(cards);
}

/* a JSON object field by key, or NULL (mirrors ice_field; small enough that
 * sharing it across files is not worth a new header) */
static JsonbValue *
pf_field(JsonbContainer *c, const char *key)
{
	if (c == NULL || !JsonContainerIsObject(c))
		return NULL;
	return getKeyJsonValueFromContainer(c, key, (int) strlen(key),
										palloc(sizeof(JsonbValue)));
}

static bool
pf_num_int64(JsonbValue *v, int64 *out)
{
	if (v == NULL || v->type != jbvNumeric)
		return false;
	*out = DatumGetInt64(DirectFunctionCall1(numeric_int8,
											 NumericGetDatum(v->val.numeric)));
	return true;
}

/* does a JSON string field equal a C string? */
static bool
pf_str_eq(JsonbValue *v, const char *want)
{
	return v != NULL && v->type == jbvString &&
		(int) strlen(want) == v->val.string.len &&
		strncmp(want, v->val.string.val, v->val.string.len) == 0;
}

void
PgColumnarPuffinReadDeletionVector(const uint8 *buf, int64 len,
								   int64 blob_offset, int64 blob_size,
								   const char *referenced_path,
								   const char *path,
								   uint64 **positions, int64 *npos)
{
	int32		paysize;
	uint32		flags;
	int64		paystart;
	char	   *payload;
	Jsonb	   *jb;
	JsonbValue *blobs;
	JsonbContainer *arr;
	uint32		nblobs;
	uint32		k;
	bool		found = false;
	const uint8 *bp;
	uint32		veclen;
	uint32		crc_want;
	uint32		crc_have;
	PfCur		cur;
	PfOut		out = {NULL, 0, 0, path};
	uint64		nbuckets;
	uint64		b;
	uint64		prevkey = 0;

	/* ---- container framing ---- */
	if (len < 20 ||
		memcmp(buf, PUFFIN_MAGIC, 4) != 0 ||
		memcmp(buf + len - 4, PUFFIN_MAGIC, 4) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: \"%s\" is not a Puffin file", path)));
	flags = (uint32) buf[len - 8] | ((uint32) buf[len - 7] << 8) |
		((uint32) buf[len - 6] << 16) | ((uint32) buf[len - 5] << 24);
	if (flags & 1)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("iceberg: \"%s\" has a compressed Puffin footer, which is not supported",
						path)));
	if (flags != 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: \"%s\" sets reserved Puffin flags 0x%x",
						path, flags)));
	paysize = (int32) ((uint32) buf[len - 12] |
					   ((uint32) buf[len - 11] << 8) |
					   ((uint32) buf[len - 10] << 16) |
					   ((uint32) buf[len - 9] << 24));	/* little-endian per spec */
	paystart = len - 12 - (int64) paysize;
	if (paysize < 2 || paystart < 8 ||
		memcmp(buf + paystart - 4, PUFFIN_MAGIC, 4) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: \"%s\" has a malformed Puffin footer", path)));

	/* ---- footer payload: find the blob the manifest points at ---- */
	payload = pnstrdup((const char *) buf + paystart, paysize);
	jb = DatumGetJsonbP(DirectFunctionCall1(jsonb_in,
											CStringGetDatum(payload)));
	blobs = pf_field(&jb->root, "blobs");
	if (blobs == NULL || blobs->type != jbvBinary ||
		!JsonContainerIsArray(blobs->val.binary.data))
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the Puffin footer of \"%s\" has no blobs array",
						path)));
	arr = blobs->val.binary.data;
	nblobs = JsonContainerSize(arr);
	for (k = 0; k < nblobs; k++)
	{
		JsonbValue *bl = getIthJsonbValueFromContainer(arr, k);
		JsonbContainer *bc;
		int64		off;
		int64		blen;
		JsonbValue *props;

		if (bl == NULL || bl->type != jbvBinary ||
			!JsonContainerIsObject(bl->val.binary.data))
			continue;
		bc = bl->val.binary.data;
		if (!pf_num_int64(pf_field(bc, "offset"), &off) ||
			!pf_num_int64(pf_field(bc, "length"), &blen) ||
			off != blob_offset || blen != blob_size)
			continue;
		/* this is the blob the manifest addresses; it must be a DV and agree
		 * with the manifest on every cross-checkable fact */
		if (!pf_str_eq(pf_field(bc, "type"), "deletion-vector-v1"))
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("iceberg: the blob at offset " INT64_FORMAT " of \"%s\" is not a deletion-vector-v1 blob",
							blob_offset, path)));
		if (pf_field(bc, "compression-codec") != NULL)
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("iceberg: the deletion vector in \"%s\" declares a compression codec; deletion-vector-v1 blobs are uncompressed",
							path)));
		props = pf_field(bc, "properties");
		if (props == NULL || props->type != jbvBinary ||
			!pf_str_eq(pf_field(props->val.binary.data, "referenced-data-file"),
					   referenced_path))
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("iceberg: the deletion vector in \"%s\" does not reference data file \"%s\"",
							path, referenced_path)));
		found = true;
		break;
	}
	if (!found)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the Puffin footer of \"%s\" has no blob matching the manifest's offset " INT64_FORMAT " and length " INT64_FORMAT,
						path, blob_offset, blob_size),
				 errdetail("The manifest's content_offset and content_size_in_bytes must exactly match the footer.")));

	/* ---- the blob itself ---- */
	/* the operands are attacker-controlled int64s; test each against the file
	 * bound WITHOUT adding them, so a huge offset+size cannot wrap past the
	 * check into a wild pointer (blob region ends before the footer's magic) */
	if (blob_offset < 4 || blob_size < 12 ||
		blob_size > paystart - 4 - 4 ||
		blob_offset > paystart - 4 - blob_size)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the deletion vector of \"%s\" lies outside the file's blob region",
						path)));
	bp = buf + blob_offset;
	veclen = pf_be32(bp);
	if ((int64) veclen != blob_size - 8)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the deletion vector of \"%s\" has an inconsistent length prefix",
						path)));
	if (memcmp(bp + 4, DV_MAGIC, 4) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the deletion vector of \"%s\" has a bad magic sequence",
						path)));
	crc_want = pf_be32(bp + 4 + veclen);
	crc_have = (uint32) crc32(0L, bp + 4, veclen);
	if (crc_want != crc_have)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the deletion vector of \"%s\" fails its CRC-32 check",
						path)));

	/* ---- the portable 64-bit roaring bitmap ---- */
	cur.p = bp + 8;
	cur.end = bp + 4 + veclen;
	cur.path = path;
	nbuckets = pf_u64(&cur);
	if (nbuckets > UINT32_MAX)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the deletion vector of \"%s\" declares " UINT64_FORMAT " buckets",
						path, nbuckets)));
	for (b = 0; b < nbuckets; b++)
	{
		uint32		key = pf_u32(&cur);

		CHECK_FOR_INTERRUPTS();
		if (b > 0 && key <= prevkey)
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("iceberg: the deletion vector of \"%s\" has out-of-order buckets",
							path)));
		prevkey = key;
		pf_roaring32(&cur, (uint64) key << 32, &out);
	}
	if (cur.p != cur.end)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("iceberg: the deletion vector of \"%s\" has trailing bytes",
						path)));

	*positions = out.pos;
	*npos = out.n;
}
