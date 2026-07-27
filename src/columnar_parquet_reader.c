/*-------------------------------------------------------------------------
 *
 * columnar_parquet_reader.c
 *		Parquet file import: columnar.import_parquet(rel regclass, path text).
 *
 * A self-contained Parquet reader with no libparquet/libarrow dependency. It
 * parses the Thrift compact-protocol file metadata, decompresses Snappy (and
 * handles uncompressed) data pages, and decodes PLAIN and dictionary
 * (RLE_DICTIONARY / PLAIN_DICTIONARY) encodings from both DATA_PAGE (v1) and
 * DATA_PAGE_V2 pages -- the combination pyarrow writes by default. Rows are
 * inserted into an existing target table (its tuple descriptor defines the
 * expected columns and types), mirroring columnar.import_arrow.
 *
 * Independent MIT implementation built from the Apache Parquet format and Thrift
 * compact-protocol specifications, the Snappy format description, and the public
 * PostgreSQL API only. See PROVENANCE.md. Little-endian hosts only.
 *
 *-------------------------------------------------------------------------
 */
#include "columnar.h"
#include "columnar_parquet_format.h"
#include "columnar_thrift.h"
#include "columnar_parquet_codec.h"

#include <math.h>
#include <sys/stat.h>
#include <dirent.h>
#include <glob.h>

#include "fmgr.h"
#include "funcapi.h"
#include "access/htup_details.h"
#include "common/int.h"
#include "access/relation.h"
#include "access/reloptions.h"
#include "access/stratnum.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/xact.h"
#include "catalog/pg_foreign_table.h"
#include "catalog/pg_type.h"
#include "commands/defrem.h"
#if PG_VERSION_NUM >= 180000
#include "commands/explain_format.h"
#include "commands/explain_state.h"
#else
#include "commands/explain.h"
#endif
#include "executor/tuptable.h"
#include "foreign/fdwapi.h"
#include "foreign/foreign.h"
#include "lib/stringinfo.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "optimizer/optimizer.h"
#include "optimizer/pathnode.h"
#include "optimizer/planmain.h"
#include "optimizer/restrictinfo.h"
#include "storage/fd.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/date.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"
#include "utils/varlena.h"
#include "utils/tuplestore.h"
#include "utils/typcache.h"
#include "utils/uuid.h"

#ifdef HAVE_LIBZ
#include <zlib.h>
#endif
#ifdef HAVE_LIBZSTD
#include <zstd.h>
#endif
#ifdef HAVE_LIBLZ4
#include <lz4.h>
#endif

PG_FUNCTION_INFO_V1(columnar_import_parquet);
PG_FUNCTION_INFO_V1(columnar_parquet_schema);
PG_FUNCTION_INFO_V1(columnar_read_parquet);
PG_FUNCTION_INFO_V1(pgcolumnar_parquet_fdw_handler);
PG_FUNCTION_INFO_V1(pgcolumnar_parquet_fdw_validator);

#define PG_TO_UNIX_DAYS		((int64) (POSTGRES_EPOCH_JDATE - UNIX_EPOCH_JDATE))
#define PG_TO_UNIX_USECS	(PG_TO_UNIX_DAYS * USECS_PER_DAY)

/*
 * Resolved time unit for a TIME/TIMESTAMP column. Parquet carries this two ways:
 * the deprecated ConvertedType (TIME_MILLIS ... TIMESTAMP_MICROS) and the current
 * LogicalType union, whose TimeType/TimestampType hold a TimeUnit union. Only the
 * latter can express NANOS. Writers commonly emit both, but neither alone is
 * guaranteed, so both are read and PQ_TU_NONE means the column is not temporal.
 */
/*
 * NONE is 0 deliberately: PqColPlan is palloc0'd, so a plan whose time_unit is
 * never assigned defaults to "no unit / passthrough" rather than to a scaling
 * factor. A future code path that binds a temporal plan and forgets to set the
 * unit then decodes the raw value, not a value silently multiplied by 1000 --
 * which is exactly this bug's failure mode. pq_scale_to_usecs treats NONE as
 * passthrough.
 */
#define PQ_TU_NONE		0
#define PQ_TU_MILLIS	1
#define PQ_TU_MICROS	2
#define PQ_TU_NANOS		3

/* Encodings (parquet.thrift Encoding) */
#define PQE_PLAIN		0
#define PQE_PLAIN_DICTIONARY 2
#define PQE_RLE			3
#define PQE_RLE_DICTIONARY 8


/* -------------------------------------------------------------------------
 * Parsed metadata (flat schema only).
 * ------------------------------------------------------------------------- */
typedef struct PqSchemaCol
{
	int			phys_type;		/* PQ_* physical type (-1 for a group) */
	int			repetition;		/* 0 required, 1 optional, 2 repeated */
	int			converted_type;	/* -1 if none */
	int			time_unit;		/* PQ_TU_* for a TIME/TIMESTAMP column */
	bool		is_timestamp;	/* the unit belongs to TIMESTAMP, not TIME */
	int			type_length;	/* FIXED_LEN_BYTE_ARRAY length */
	int			scale;			/* DECIMAL scale (0 if none) */
	int			precision;		/* DECIMAL precision (0 if none) */
	int			num_children;	/* >0 for a group */
	char	   *name;
} PqSchemaCol;

/* a leaf column (primitive) with its computed Dremel level bounds */
typedef struct PqLeafInfo
{
	PqSchemaCol *sc;
	int			max_def;
	int			max_rep;
} PqLeafInfo;

typedef struct PqChunk
{
	int			codec;
	int64		num_values;
	int64		data_page_offset;
	int64		dict_page_offset;	/* 0 if none */
	int64		total_compressed_size;
	/* Statistics (optional). min/max point into the metadata buffer, so they are
	 * valid as long as the file buffer lives (through a scan). */
	bool		has_min;
	bool		has_max;
	const uint8 *stat_min;
	const uint8 *stat_max;
	uint32		stat_min_len;
	uint32		stat_max_len;
} PqChunk;

typedef struct PqRowGroup
{
	int64		num_rows;
	PqChunk    *chunks;			/* [nchunks]; consumers index by ncols, so a value
								 * read path must call pq_check_row_groups() first */
	int			nchunks;		/* column chunks this row group actually carries */
} PqRowGroup;

typedef struct PqFile
{
	int			nelems;			/* all schema elements, pre-order (root at [0]) */
	PqSchemaCol *elems;
	int			ncols;			/* leaf columns (= column chunks per row group) */
	PqLeafInfo *leaves;			/* [ncols], in pre-order = column-chunk order */
	int			ntop;			/* top-level columns (root's children) */
	int			nrowgroups;
	PqRowGroup *rgs;
} PqFile;

/*
 * Parse a Statistics struct into *ch. Prefers the current min_value (field 6) /
 * max_value (field 5) over the deprecated min (2) / max (1). Values are kept as
 * raw pointers into the metadata buffer. Other fields, including null_count, are
 * skipped: nothing reads them yet, and an all-NULL skip would additionally need
 * the operator's strictness checked.
 */
static void
parse_statistics(TCReader *r, PqChunk *ch)
{
	int			lastId = 0;

	for (;;)
	{
		int			ft,
					fid;

		ColumnarThriftField(r, &ft, &fid, &lastId);
		if (ft == TC_STOP || r->error)
			break;
		switch (fid)
		{
			case 1:				/* max (deprecated): fallback only */
				{
					uint32		n;
					const uint8 *p = ColumnarThriftBytes(r, &n);

					if (p && !ch->has_max)
					{
						ch->stat_max = p;
						ch->stat_max_len = n;
						ch->has_max = true;
					}
					break;
				}
			case 2:				/* min (deprecated): fallback only */
				{
					uint32		n;
					const uint8 *p = ColumnarThriftBytes(r, &n);

					if (p && !ch->has_min)
					{
						ch->stat_min = p;
						ch->stat_min_len = n;
						ch->has_min = true;
					}
					break;
				}
			case 5:				/* max_value (preferred) */
				{
					uint32		n;
					const uint8 *p = ColumnarThriftBytes(r, &n);

					if (p)
					{
						ch->stat_max = p;
						ch->stat_max_len = n;
						ch->has_max = true;
					}
					break;
				}
			case 6:				/* min_value (preferred) */
				{
					uint32		n;
					const uint8 *p = ColumnarThriftBytes(r, &n);

					if (p)
					{
						ch->stat_min = p;
						ch->stat_min_len = n;
						ch->has_min = true;
					}
					break;
				}
			default:
				ColumnarThriftSkip(r, ft);
				break;
		}
	}
}

/* parse a ColumnMetaData struct into *ch */
static void
parse_column_meta(TCReader *r, PqChunk *ch)
{
	int			lastId = 0;

	ch->codec = PQC_UNCOMPRESSED;
	ch->num_values = 0;
	ch->data_page_offset = 0;
	ch->dict_page_offset = 0;
	ch->total_compressed_size = 0;
	ch->has_min = false;
	ch->has_max = false;
	ch->stat_min = NULL;
	ch->stat_max = NULL;
	ch->stat_min_len = 0;
	ch->stat_max_len = 0;

	for (;;)
	{
		int			ft,
					fid;

		ColumnarThriftField(r, &ft, &fid, &lastId);
		if (ft == TC_STOP || r->error)
			break;
		switch (fid)
		{
			case 4:				/* codec */
				ch->codec = (int) ColumnarThriftZigzag(r);
				break;
			case 5:				/* num_values */
				ch->num_values = ColumnarThriftZigzag(r);
				break;
			case 7:				/* total_compressed_size */
				ch->total_compressed_size = ColumnarThriftZigzag(r);
				break;
			case 9:				/* data_page_offset */
				ch->data_page_offset = ColumnarThriftZigzag(r);
				break;
			case 11:			/* dictionary_page_offset */
				ch->dict_page_offset = ColumnarThriftZigzag(r);
				break;
			case 12:			/* statistics */
				if (ft == TC_STRUCT)
					parse_statistics(r, ch);
				else
					ColumnarThriftSkip(r, ft);
				break;
			default:
				ColumnarThriftSkip(r, ft);
				break;
		}
	}
}

/* parse a ColumnChunk struct (field 3 is the ColumnMetaData) */
static void
parse_column_chunk(TCReader *r, PqChunk *ch)
{
	int			lastId = 0;

	for (;;)
	{
		int			ft,
					fid;

		ColumnarThriftField(r, &ft, &fid, &lastId);
		if (ft == TC_STOP || r->error)
			break;
		if (fid == 3 && ft == TC_STRUCT)
			parse_column_meta(r, ch);
		else
			ColumnarThriftSkip(r, ft);
	}
}

/*
 * Parse a LogicalType union into *sc, recording the time unit for TIME and
 * TIMESTAMP. Every other member is skipped: the ConvertedType path already covers
 * what the reader uses of them. TimeUnit is itself a union of empty structs, so
 * the set field id is the whole answer.
 *
 * This hand-walks nested Thrift unions and assumes the compact-protocol field
 * ordering the spec prescribes. A writer that reorders or partially populates the
 * union could desync the cursor -- but a desync fails the surrounding footer
 * parse (ColumnarThriftField / bounds checks catch it), so the blast radius is "file
 * rejected", never a wrong value silently returned from a good decode.
 */
static void
parse_logical_type(TCReader *r, PqSchemaCol *sc)
{
	int			lastId = 0;

	for (;;)
	{
		int			ft,
					fid;

		ColumnarThriftField(r, &ft, &fid, &lastId);
		if (ft == TC_STOP || r->error)
			break;
		if ((fid == PQ_LT_TIME || fid == PQ_LT_TIMESTAMP) && ft == TC_STRUCT)
		{
			int			innerLast = 0;
			bool		isTs = (fid == PQ_LT_TIMESTAMP);

			for (;;)
			{
				int			ift,
							ifid;

				ColumnarThriftField(r, &ift, &ifid, &innerLast);
				if (ift == TC_STOP || r->error)
					break;
				if (ifid == 2 && ift == TC_STRUCT)	/* unit: union TimeUnit */
				{
					int			uLast = 0;
					int			uft,
								ufid;

					ColumnarThriftField(r, &uft, &ufid, &uLast);
					if (uft != TC_STOP && !r->error)
					{
						switch (ufid)
						{
							case PQ_TUNIT_MILLIS:
								sc->time_unit = PQ_TU_MILLIS;
								break;
							case PQ_TUNIT_MICROS:
								sc->time_unit = PQ_TU_MICROS;
								break;
							case PQ_TUNIT_NANOS:
								sc->time_unit = PQ_TU_NANOS;
								break;
						}
						sc->is_timestamp = isTs;
						ColumnarThriftSkip(r, uft);	/* the unit member is an empty struct */
						/* consume the union's STOP */
						ColumnarThriftField(r, &uft, &ufid, &uLast);
					}
				}
				else
					ColumnarThriftSkip(r, ift);	/* isAdjustedToUTC and anything later */
			}
		}
		else
			ColumnarThriftSkip(r, ft);
	}
}

static int
parse_schema_element(TCReader *r, PqSchemaCol *sc)
{
	int			lastId = 0;
	int			num_children = 0;

	sc->phys_type = -1;
	sc->repetition = 0;
	sc->converted_type = -1;
	sc->time_unit = PQ_TU_NONE;
	sc->is_timestamp = false;
	sc->type_length = 0;
	sc->scale = 0;
	sc->precision = 0;
	sc->num_children = 0;
	sc->name = NULL;

	for (;;)
	{
		int			ft,
					fid;

		ColumnarThriftField(r, &ft, &fid, &lastId);
		if (ft == TC_STOP || r->error)
			break;
		switch (fid)
		{
			case 1:				/* type */
				sc->phys_type = (int) ColumnarThriftZigzag(r);
				break;
			case 2:				/* type_length */
				sc->type_length = (int) ColumnarThriftZigzag(r);
				break;
			case 3:				/* repetition_type */
				sc->repetition = (int) ColumnarThriftZigzag(r);
				break;
			case 4:				/* name */
				{
					uint32		n;
					const uint8 *p = ColumnarThriftBytes(r, &n);

					if (p)
						sc->name = pnstrdup((const char *) p, n);
					break;
				}
			case 5:				/* num_children */
				num_children = (int) ColumnarThriftZigzag(r);
				sc->num_children = num_children;
				break;
			case 6:				/* converted_type */
				sc->converted_type = (int) ColumnarThriftZigzag(r);
				break;
			case 7:				/* scale (DECIMAL) */
				sc->scale = (int) ColumnarThriftZigzag(r);
				break;
			case 8:				/* precision (DECIMAL) */
				sc->precision = (int) ColumnarThriftZigzag(r);
				break;
			case 10:			/* logicalType */
				parse_logical_type(r, sc);
				break;
			default:
				ColumnarThriftSkip(r, ft);
				break;
		}
	}

	/*
	 * Fall back to the deprecated ConvertedType when no LogicalType was present.
	 * LogicalType wins when both appear: it is the current spelling, and it is the
	 * only one that can say NANOS.
	 */
	if (sc->time_unit == PQ_TU_NONE)
	{
		switch (sc->converted_type)
		{
			case PQ_CT_TIMESTAMP_MILLIS:
				sc->time_unit = PQ_TU_MILLIS;
				sc->is_timestamp = true;
				break;
			case PQ_CT_TIMESTAMP_MICROS:
				sc->time_unit = PQ_TU_MICROS;
				sc->is_timestamp = true;
				break;
			case PQ_CT_TIME_MILLIS:
				sc->time_unit = PQ_TU_MILLIS;
				break;
			case PQ_CT_TIME_MICROS:
				sc->time_unit = PQ_TU_MICROS;
				break;
		}
	}
	return num_children;
}

/*
 * Recursively walk one schema element at *cursor (pre-order), accumulating the
 * definition/repetition level bounds. A primitive (num_children == 0) becomes a
 * leaf; a group recurses into its children. Repetition contributes: OPTIONAL
 * +1 def, REPEATED +1 def and +1 rep (Dremel).
 */
static bool
walk_schema(PqFile *pf, int *cursor, int def, int rep,
			PqLeafInfo *leaves, int *nleaf)
{
	PqSchemaCol *e;
	int			d,
				rp;

	if (*cursor >= pf->nelems)
		return false;
	e = &pf->elems[(*cursor)++];
	d = def + (e->repetition == 1 ? 1 : 0) + (e->repetition == 2 ? 1 : 0);
	rp = rep + (e->repetition == 2 ? 1 : 0);

	if (e->num_children == 0)
	{
		leaves[*nleaf].sc = e;
		leaves[*nleaf].max_def = d;
		leaves[*nleaf].max_rep = rp;
		(*nleaf)++;
	}
	else
	{
		int			c;

		for (c = 0; c < e->num_children; c++)
			if (!walk_schema(pf, cursor, d, rp, leaves, nleaf))
				return false;
	}
	return true;
}

/* parse the whole FileMetaData; returns false on error or unsupported shape */
static bool
parse_file_metadata(const uint8 *buf, size_t len, PqFile *pf)
{
	TCReader	r = {buf, len, 0, false};
	int			lastId = 0;

	pf->ncols = 0;
	pf->nelems = 0;
	pf->elems = NULL;
	pf->leaves = NULL;
	pf->ntop = 0;
	pf->nrowgroups = 0;
	pf->rgs = NULL;

	for (;;)
	{
		int			ft,
					fid;

		ColumnarThriftField(&r, &ft, &fid, &lastId);
		if (ft == TC_STOP || r.error)
			break;

		if (fid == 2 && ft == TC_LIST)	/* schema: list<SchemaElement> */
		{
			int			etype;
			uint32		n = ColumnarThriftListHeader(&r, &etype);
			uint32		i;
			PqSchemaCol *tmp = palloc0(sizeof(PqSchemaCol) * Max(n, 1));

			for (i = 0; i < n && !r.error; i++)
				parse_schema_element(&r, &tmp[i]);
			pf->nelems = (int) n;
			pf->elems = tmp;
		}
		else if (fid == 4 && ft == TC_LIST)		/* row_groups */
		{
			int			etype;
			uint32		n = ColumnarThriftListHeader(&r, &etype);
			uint32		i;

			pf->nrowgroups = n;
			pf->rgs = palloc0(sizeof(PqRowGroup) * Max(n, 1));
			for (i = 0; i < n && !r.error; i++)
			{
				PqRowGroup *rg = &pf->rgs[i];
				int			rgLast = 0;

				rg->chunks = NULL;
				rg->nchunks = 0;
				for (;;)
				{
					int			rft,
								rfid;

					ColumnarThriftField(&r, &rft, &rfid, &rgLast);
					if (rft == TC_STOP || r.error)
						break;
					if (rfid == 1 && rft == TC_LIST)	/* columns */
					{
						int			cet;
						uint32		cn = ColumnarThriftListHeader(&r, &cet);
						uint32		ci;

						rg->chunks = palloc0(sizeof(PqChunk) * Max(cn, 1));
						rg->nchunks = (int) cn;
						for (ci = 0; ci < cn && !r.error; ci++)
							parse_column_chunk(&r, &rg->chunks[ci]);
					}
					else if (rfid == 3)		/* num_rows */
						rg->num_rows = ColumnarThriftZigzag(&r);
					else
						ColumnarThriftSkip(&r, rft);
				}
			}
		}
		else
			ColumnarThriftSkip(&r, ft);
	}

	if (r.error || pf->nelems < 1)
		return false;

	/* derive leaf columns + their level bounds from the schema tree */
	{
		int			cursor = 1;	/* skip the root element */
		int			nleaf = 0;
		int			c;
		PqLeafInfo *leaves = palloc0(sizeof(PqLeafInfo) * Max(pf->nelems, 1));

		pf->ntop = pf->elems[0].num_children;
		for (c = 0; c < pf->ntop; c++)
			if (!walk_schema(pf, &cursor, 0, 0, leaves, &nleaf))
				return false;
		pf->ncols = nleaf;
		pf->leaves = leaves;
	}
	if (pf->ncols <= 0)
		return false;

	return true;
}

/*
 * Reject a file whose row groups do not carry one column chunk per schema leaf.
 *
 * Every value consumer indexes rgs[].chunks[] by the schema's leaf count, not by
 * whatever the row group happened to carry: pq_read_rows() walks i < ncols and
 * pqfdw_compute_skip() takes chunks[top->firstLeaf]. A row group with a short
 * column list is therefore an out-of-bounds read, and one with no `columns` field
 * at all leaves chunks NULL. A row group that disagrees with the schema is
 * malformed and there is no safe reading of it.
 *
 * This is deliberately separate from parsing, and from the schema itself, so that
 * parquet_schema() still describes such a file. Reporting the schema is exactly
 * what one wants when diagnosing a suspect file, and it touches no chunk.
 */
static void
pq_check_row_groups(const PqFile *pf, const char *path)
{
	int			rg;

	for (rg = 0; rg < pf->nrowgroups; rg++)
		if (pf->rgs[rg].chunks == NULL || pf->rgs[rg].nchunks != pf->ncols)
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("Parquet file \"%s\" has a malformed row group", path),
					 errdetail("Row group %d carries %d column chunks, but the schema has %d leaf columns.",
							   rg, pf->rgs[rg].nchunks, pf->ncols)));
}

/* -------------------------------------------------------------------------
 * RLE / bit-packing hybrid decoder (Parquet). Decodes `count` values of
 * bit_width bits into out[]. Used for definition levels and dictionary indices.
 * ------------------------------------------------------------------------- */
static bool
rle_bitpack_decode(const uint8 *buf, size_t len, int bit_width,
				   int count, uint32 *out)
{
	size_t		pos = 0;
	int			produced = 0;

	if (bit_width == 0)
	{
		int			i;

		for (i = 0; i < count; i++)
			out[i] = 0;
		return true;
	}

	while (produced < count)
	{
		uint64		header = 0;
		int			shift = 0;

		while (pos < len)
		{
			uint8		b = buf[pos++];

			header |= (uint64) (b & 0x7f) << shift;
			if ((b & 0x80) == 0)
				break;
			shift += 7;
			if (shift > 63)
				return false;
		}

		if (header & 1)			/* bit-packed run */
		{
			int			ngroups = (int) (header >> 1);
			int			nvals = ngroups * 8;
			int			bytes = ngroups * bit_width;
			int			v;

			if (pos + bytes > len)
				return false;
			for (v = 0; v < nvals && produced < count; v++)
			{
				uint32		val = 0;
				int			bit;

				for (bit = 0; bit < bit_width; bit++)
				{
					int			abs = v * bit_width + bit;

					if (buf[pos + (abs >> 3)] & (1 << (abs & 7)))
						val |= (1u << bit);
				}
				out[produced++] = val;
			}
			pos += bytes;
		}
		else					/* RLE run */
		{
			int			runlen = (int) (header >> 1);
			int			nbytes = (bit_width + 7) / 8;
			uint32		val = 0;
			int			i;

			if (pos + nbytes > len)
				return false;
			for (i = 0; i < nbytes; i++)
				val |= (uint32) buf[pos + i] << (8 * i);
			pos += nbytes;
			for (i = 0; i < runlen && produced < count; i++)
				out[produced++] = val;
		}
	}
	return true;
}

static int
bits_for(int maxval)
{
	int			b = 0;

	while ((1 << b) <= maxval)
		b++;
	return b;
}

/* -------------------------------------------------------------------------
 * Per-column import plan derived from the target tuple descriptor.
 * ------------------------------------------------------------------------- */
typedef struct PqColPlan
{
	Oid			typid;
	int16		typlen;
	bool		typbyval;
	int			expect_phys;	/* required Parquet physical type */
	int			time_unit;		/* PQ_TU_* when the source column is TIME/TIMESTAMP */
	int			type_length;	/* FIXED_LEN_BYTE_ARRAY width, for uuid/decimal */
	int			dec_scale;		/* DECIMAL scale, when the target is numeric */
	bool		is_decimal;		/* the bytes are a DECIMAL unscaled integer */
} PqColPlan;

/*
 * Convert a stored TIME/TIMESTAMP value to the microseconds PostgreSQL stores,
 * per the column's declared unit. Returns false if the conversion overflows.
 *
 * A column with no declared unit is read as microseconds: the target type is
 * microsecond-based and there is nothing else to go on.
 *
 * NANOS is divided rather than refused. PostgreSQL has no nanosecond timestamp,
 * so sub-microsecond precision cannot survive regardless; truncating yields the
 * right instant, whereas reading nanoseconds as microseconds is wrong by a factor
 * of 1000. C division truncates toward zero, so a pre-epoch value rounds toward
 * the epoch rather than toward negative infinity: a sub-microsecond difference,
 * and the same narrowing other readers apply.
 */
static bool
pq_scale_to_usecs(int unit, int64 v, int64 *out)
{
	switch (unit)
	{
		case PQ_TU_MILLIS:
			return !pg_mul_s64_overflow(v, INT64CONST(1000), out);
		case PQ_TU_NANOS:
			*out = v / INT64CONST(1000);
			return true;
		case PQ_TU_MICROS:
		case PQ_TU_NONE:
		default:
			*out = v;
			return true;
	}
}

/*
 * The DECIMAL precision and scale a file declares, and the PostgreSQL typmod they
 * map to. One implementation, used by both the schema-advice path and the bind
 * path, so a file can never be described one way and bound another. The bound
 * matters beyond tidiness: pq_decimal_to_numeric zero-fills about `scale` bytes
 * into a fixed buffer, so an unvalidated scale is a stack overflow.
 */
static inline bool
pq_decimal_bounds_ok(const PqSchemaCol *sc)
{
	return sc->precision >= 1 && sc->precision <= 38 &&
		sc->scale >= 0 && sc->scale <= sc->precision;
}

static inline int32
pq_decimal_typmod(const PqSchemaCol *sc)
{
	return (int32) (((sc->precision << 16) | (sc->scale & 0xffff)) + VARHDRSZ);
}

/*
 * Build a numeric Datum from a DECIMAL held in an INT32 or INT64. Parquet stores
 * that form as the plain little-endian integer, not as the big-endian bytes the
 * byte-array forms use, so it is widened into a big-endian buffer and handed to
 * the one conversion that knows about scale. Sign-extending into the buffer keeps
 * negatives correct: pq_decimal_to_numeric reads the top bit of the first byte.
 */
static bool pq_decimal_to_numeric(const uint8 *be, int len, int scale, Datum *out);

static bool
pq_int_decimal_to_numeric(int64 v, int width, int scale, Datum *out)
{
	uint8		be[8];
	int			i;

	Assert(width == 4 || width == 8);
	for (i = width - 1; i >= 0; i--)
	{
		be[i] = (uint8) (v & 0xff);
		v >>= 8;
	}
	return pq_decimal_to_numeric(be, width, scale, out);
}

/*
 * Build a numeric Datum from a DECIMAL stored as `len` big-endian two's-complement
 * bytes at the given scale -- the inverse of the exporter's numeric_to_int128 plus
 * its byte-swap, and the layout pyarrow writes for decimal128. Values up to 16
 * bytes (128 bits) are supported, which covers DECIMAL(38); a wider decimal256
 * returns false. The unscaled integer is turned into its canonical text form and
 * parsed by numeric_in, mirroring how the exporter went numeric -> text.
 */
static bool
pq_decimal_to_numeric(const uint8 *be, int len, int scale, Datum *out)
{
	unsigned __int128 mag = 0;
	__int128	val;
	bool		neg;
	char		digits[40];
	int			nd = 0;
	char		buf[64];
	int			bi = 0;
	int			i;

	if (len < 1 || len > 16)
		return false;
	/*
	 * Defence in depth against a crafted scale: the bind-time guard in
	 * pq_want_phys_for already rejects scale outside [0, precision<=38], but this
	 * function's zero-fill writes about scale bytes into a fixed buffer, so refuse
	 * anything it could not hold even if reached another way. A negative scale
	 * would also decode as an unscaled integer, a wrong value; reject it too.
	 */
	if (scale < 0 || scale > 38)
		return false;

	for (i = 0; i < len; i++)
		mag = (mag << 8) | be[i];

	/* interpret as two's complement of `len` bytes */
	neg = (be[0] & 0x80) != 0;
	if (len == 16)
		val = (__int128) mag;	/* full width: the bit pattern is the value */
	else if (neg)
		val = (__int128) mag - (((__int128) 1) << (8 * len));
	else
		val = (__int128) mag;

	{
		unsigned __int128 a = (val < 0) ? -(unsigned __int128) val
			: (unsigned __int128) val;

		if (a == 0)
			digits[nd++] = '0';
		while (a > 0)
		{
			digits[nd++] = (char) ('0' + (int) (a % 10));
			a /= 10;
		}
	}
	/* digits[] now holds the magnitude least-significant first */

	if (val < 0)
		buf[bi++] = '-';

	if (scale <= 0)
	{
		for (i = nd - 1; i >= 0; i--)
			buf[bi++] = digits[i];
	}
	else
	{
		int			intlen = nd - scale;	/* digits left of the point */
		int			k;

		if (intlen <= 0)
		{
			buf[bi++] = '0';
			buf[bi++] = '.';
			for (k = 0; k < -intlen; k++)
				buf[bi++] = '0';			/* leading fractional zeros */
			for (i = nd - 1; i >= 0; i--)
				buf[bi++] = digits[i];
		}
		else
		{
			for (i = nd - 1; i >= scale; i--)
				buf[bi++] = digits[i];
			buf[bi++] = '.';
			for (; i >= 0; i--)
				buf[bi++] = digits[i];
		}
	}
	buf[bi] = '\0';

	*out = DirectFunctionCall3(numeric_in, CStringGetDatum(buf),
							   ObjectIdGetDatum(InvalidOid), Int32GetDatum(-1));
	return true;
}

/*
 * A physical value that does not fit the bound PostgreSQL type. On the data path
 * (strict) this is an error: the file is well-formed, the value simply cannot be
 * represented as the column's declared type, and silently substituting a wrapped
 * one would be a wrong answer. On the statistics path (not strict) it only means
 * the bounds cannot be trusted, so the caller declines to skip and reads the group.
 */
static Datum
pq_value_out_of_range(bool strict, bool *ok, int sqlerrcode, const char *typname,
					  int64 value)
{
	if (strict)
		ereport(ERROR,
				(errcode(sqlerrcode),
				 errmsg("value out of range for type %s", typname),
				 errdetail("The Parquet file stores " INT64_FORMAT
						   ", which cannot be represented as %s.",
						   value, typname)));
	*ok = false;
	return (Datum) 0;
}

/*
 * Convert one PLAIN physical value at *p (advancing *p) to a target Datum.
 *
 * Several PostgreSQL types bind to a wider Parquet physical type, because Parquet
 * has no narrower one: int2 and date ride on INT32, time and the timestamps on
 * INT64. Those conversions are range-checked rather than cast, so an out-of-range
 * value raises instead of wrapping. See pq_value_out_of_range for what strict
 * selects.
 */
static Datum
plain_value_to_datum(const PqColPlan *plan, const uint8 **p, const uint8 *end,
					 bool strict, bool *ok)
{
	const uint8 *cur = *p;

	*ok = true;
	switch (plan->expect_phys)
	{
		case PQ_INT32:
			{
				int32		v;

				if (cur + 4 > end)
				{
					*ok = false;
					return (Datum) 0;
				}
				memcpy(&v, cur, 4);
				*p = cur + 4;
				if (plan->is_decimal)
				{
					Datum		num;

					if (!pq_int_decimal_to_numeric((int64) v, 4,
												   plan->dec_scale, &num))
					{
						*ok = false;
						return (Datum) 0;
					}
					return num;
				}
				if (plan->typid == INT2OID)
				{
					if (v < PG_INT16_MIN || v > PG_INT16_MAX)
						return pq_value_out_of_range(strict, ok,
													 ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE,
													 "smallint", (int64) v);
					return Int16GetDatum((int16) v);
				}
				if (plan->typid == TIMEOID)
				{
					int64		us;

					/* TIME_MILLIS: milliseconds since midnight, in an INT32 */
					if (!pq_scale_to_usecs(plan->time_unit, (int64) v, &us) ||
						us < INT64CONST(0) || us > USECS_PER_DAY)
						return pq_value_out_of_range(strict, ok,
													 ERRCODE_DATETIME_FIELD_OVERFLOW,
													 "time", (int64) v);
					return TimeADTGetDatum((TimeADT) us);
				}
				if (plan->typid == DATEOID)
				{
					int32		d;

					if (pg_sub_s32_overflow(v, PG_TO_UNIX_DAYS, &d) ||
						!IS_VALID_DATE((DateADT) d))
						return pq_value_out_of_range(strict, ok,
													 ERRCODE_DATETIME_FIELD_OVERFLOW,
													 "date", (int64) v);
					return DateADTGetDatum((DateADT) d);
				}
				return Int32GetDatum(v);
			}
		case PQ_INT64:
			{
				int64		v;

				if (cur + 8 > end)
				{
					*ok = false;
					return (Datum) 0;
				}
				memcpy(&v, cur, 8);
				*p = cur + 8;
				if (plan->is_decimal)
				{
					Datum		num;

					if (!pq_int_decimal_to_numeric(v, 8, plan->dec_scale, &num))
					{
						*ok = false;
						return (Datum) 0;
					}
					return num;
				}
				if (plan->typid == TIMESTAMPOID || plan->typid == TIMESTAMPTZOID)
				{
					int64		us;
					int64		t;
					const char *tn = (plan->typid == TIMESTAMPOID)
						? "timestamp" : "timestamp with time zone";

					if (!pq_scale_to_usecs(plan->time_unit, v, &us) ||
						pg_sub_s64_overflow(us, PG_TO_UNIX_USECS, &t) ||
						!IS_VALID_TIMESTAMP((Timestamp) t))
						return pq_value_out_of_range(strict, ok,
													 ERRCODE_DATETIME_FIELD_OVERFLOW,
													 tn, v);
					return TimestampGetDatum((Timestamp) t);
				}
				if (plan->typid == TIMEOID)
				{
					int64		us;

					/* TimeADT is microseconds since midnight; nothing else is a time */
					if (!pq_scale_to_usecs(plan->time_unit, v, &us) ||
						us < INT64CONST(0) || us > USECS_PER_DAY)
						return pq_value_out_of_range(strict, ok,
													 ERRCODE_DATETIME_FIELD_OVERFLOW,
													 "time", v);
					return TimeADTGetDatum((TimeADT) us);
				}
				return Int64GetDatum(v);
			}
		case PQ_FLOAT:
			{
				float4		v;

				if (cur + 4 > end)
				{
					*ok = false;
					return (Datum) 0;
				}
				memcpy(&v, cur, 4);
				*p = cur + 4;
				return Float4GetDatum(v);
			}
		case PQ_DOUBLE:
			{
				float8		v;

				if (cur + 8 > end)
				{
					*ok = false;
					return (Datum) 0;
				}
				memcpy(&v, cur, 8);
				*p = cur + 8;
				return Float8GetDatum(v);
			}
		case PQ_BOOLEAN:
			/* PLAIN booleans are bit-packed; handled by the caller, not here */
			*ok = false;
			return (Datum) 0;
		case PQ_BYTE_ARRAY:
			{
				uint32		blen;
				text	   *t;

				if (cur + 4 > end)
				{
					*ok = false;
					return (Datum) 0;
				}
				memcpy(&blen, cur, 4);
				cur += 4;
				if (cur + blen > end)
				{
					*ok = false;
					return (Datum) 0;
				}
				if (plan->is_decimal)
				{
					Datum	   num;

					if (!pq_decimal_to_numeric(cur, (int) blen,
						   plan->dec_scale, &num))
					{
						*ok = false;
						return (Datum) 0;
					}
					*p = cur + blen;
					return num;
				}
				if (plan->typid == BYTEAOID)
				{
					bytea	   *b = (bytea *) palloc(blen + VARHDRSZ);

					SET_VARSIZE(b, blen + VARHDRSZ);
					memcpy(VARDATA(b), cur, blen);
					*p = cur + blen;
					return PointerGetDatum(b);
				}
				t = cstring_to_text_with_len((const char *) cur, blen);
				*p = cur + blen;
				return PointerGetDatum(t);
			}
			case PQ_FIXED_LEN_BYTE_ARRAY:
			{
				int	   flen = plan->type_length;

				if (flen <= 0 || cur + flen > end)
				{
					*ok = false;
					return (Datum) 0;
				}
				if (plan->is_decimal)
				{
					Datum	   num;

					if (!pq_decimal_to_numeric(cur, flen, plan->dec_scale, &num))
					{
						*ok = false;
						return (Datum) 0;
					}
					*p = cur + flen;
					return num;
				}
				if (plan->typid == UUIDOID)
				{
					pg_uuid_t  *u;

					if (flen != UUID_LEN)
					{
						*ok = false;
						return (Datum) 0;
					}
					u = (pg_uuid_t *) palloc(sizeof(pg_uuid_t));
					memcpy(u->data, cur, UUID_LEN);
					*p = cur + flen;
					return UUIDPGetDatum(u);
				}
				/* plain fixed-width bytes -> bytea */
				{
					bytea	   *b = (bytea *) palloc(flen + VARHDRSZ);

					SET_VARSIZE(b, flen + VARHDRSZ);
					memcpy(VARDATA(b), cur, flen);
					*p = cur + flen;
					return PointerGetDatum(b);
				}
			}
		default:
			*ok = false;
			return (Datum) 0;
	}
}

/* parsed Parquet PageHeader (only the fields we use) */
typedef struct PqPageHeader
{
	int			type;
	int			uncompressed_size;
	int			compressed_size;
	int			num_values;		/* data page: values (rows) in the page */
	int			encoding;		/* data page value encoding */
	/* v2 only */
	int			def_levels_len;
	int			rep_levels_len;
	bool		is_compressed;	/* v2; default true */
	bool		is_v2;
} PqPageHeader;

static void
parse_data_page_header(TCReader *r, PqPageHeader *h, bool v2)
{
	int			lastId = 0;

	h->is_v2 = v2;
	h->is_compressed = true;
	for (;;)
	{
		int			ft,
					fid;

		ColumnarThriftField(r, &ft, &fid, &lastId);
		if (ft == TC_STOP || r->error)
			break;
		if (!v2)
		{
			switch (fid)
			{
				case 1:
					h->num_values = (int) ColumnarThriftZigzag(r);
					break;
				case 2:
					h->encoding = (int) ColumnarThriftZigzag(r);
					break;
				default:
					ColumnarThriftSkip(r, ft);
					break;
			}
		}
		else
		{
			switch (fid)
			{
				case 1:
					h->num_values = (int) ColumnarThriftZigzag(r);
					break;
				case 4:
					h->encoding = (int) ColumnarThriftZigzag(r);
					break;
				case 5:
					h->def_levels_len = (int) ColumnarThriftZigzag(r);
					break;
				case 6:
					h->rep_levels_len = (int) ColumnarThriftZigzag(r);
					break;
				case 7:
					h->is_compressed = (ft == TC_BOOL_TRUE);
					break;
				default:
					ColumnarThriftSkip(r, ft);
					break;
			}
		}
	}
}

/* parse a PageHeader; on return r->pos is just past the header (page data next) */
static void
parse_page_header(TCReader *r, PqPageHeader *h)
{
	int			lastId = 0;

	memset(h, 0, sizeof(*h));
	h->is_compressed = true;
	for (;;)
	{
		int			ft,
					fid;

		ColumnarThriftField(r, &ft, &fid, &lastId);
		if (ft == TC_STOP || r->error)
			break;
		switch (fid)
		{
			case 1:
				h->type = (int) ColumnarThriftZigzag(r);
				break;
			case 2:
				h->uncompressed_size = (int) ColumnarThriftZigzag(r);
				break;
			case 3:
				h->compressed_size = (int) ColumnarThriftZigzag(r);
				break;
			case 5:				/* DataPageHeader (v1) */
				parse_data_page_header(r, h, false);
				break;
			case 7:				/* DictionaryPageHeader */
				{
					int			dl = 0;

					for (;;)
					{
						int			dft,
									dfid;

						ColumnarThriftField(r, &dft, &dfid, &dl);
						if (dft == TC_STOP || r->error)
							break;
						if (dfid == 1)
							h->num_values = (int) ColumnarThriftZigzag(r);
						else
							ColumnarThriftSkip(r, dft);
					}
					break;
				}
			case 8:				/* DataPageHeaderV2 */
				parse_data_page_header(r, h, true);
				break;
			default:
				ColumnarThriftSkip(r, ft);
				break;
		}
	}
}

/* decode `n` PLAIN booleans (bit-packed) into Datums */
static void
decode_plain_bools(const uint8 *buf, int n, Datum *out)
{
	int			i;

	for (i = 0; i < n; i++)
		out[i] = BoolGetDatum((buf[i >> 3] >> (i & 7)) & 1);
}

/*
 * An open Parquet file, read on demand.
 *
 * Only the footer is held: `meta` is the serialized file metadata, and the
 * parsed PqFile's chunk statistics (PqChunk.stat_min and stat_max) point into
 * it, so it must outlive every consumer of those pointers, which means the whole
 * scan of this file. Page bytes are read as they are needed, so peak memory does
 * not scale with the file.
 */
typedef struct PqSource
{
	FILE	   *f;				/* AllocateFile handle (buffered) */
	const char *path;			/* for error messages; palloc'd by the caller */
	int64		len;			/* file length in bytes */
	uint8	   *meta;			/* serialized footer metadata */
	uint32		metalen;
} PqSource;

/*
 * Read `n` bytes at `off` into `buf`. Every caller has already bounded `off` and
 * `n` against src->len; this reports the I/O failure that is left.
 */
static void
pq_source_read(PqSource *src, int64 off, void *buf, size_t n)
{
	Assert(off >= 0 && n <= (size_t) (src->len - off));
	if (fseeko(src->f, (off_t) off, SEEK_SET) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not seek in \"%s\": %m", src->path)));
	if (fread(buf, 1, n, src->f) != n)
	{
		/*
		 * A short read is not an I/O error, so errno holds whatever a previous
		 * call left there; reporting %m would name an unrelated cause. Only a
		 * real stream error gets %m.
		 */
		if (ferror(src->f))
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not read \"%s\": %m", src->path)));
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("unexpected end of file in \"%s\"", src->path)));
	}
}

/*
 * Open a Parquet file and parse its footer. Reads the two magics and the footer,
 * never the body. The error texts match what the whole-file reader raised, so a
 * crafted file reports the same thing through either path.
 */
static void
pq_source_open(const char *path, PqSource *src, PqFile *pf)
{
	uint8		tail[8];
	uint8		head[4];

	memset(src, 0, sizeof(*src));
	src->path = path;
	src->f = AllocateFile(path, PG_BINARY_R);
	if (src->f == NULL)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\" for reading: %m", path)));
	/* off_t, not long: a 32-bit long would cap a readable file at 2GB */
	if (fseeko(src->f, 0, SEEK_END) != 0 || (src->len = ftello(src->f)) < 0)
	{
		FreeFile(src->f);
		ereport(ERROR, (errcode_for_file_access(),
						errmsg("could not size \"%s\": %m", path)));
	}
	if (src->len < 12)
	{
		FreeFile(src->f);
		ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
						errmsg("\"%s\" is not a Parquet file", path)));
	}

	/* "PAR1" opens the file, and closes it after the 4-byte footer length */
	pq_source_read(src, 0, head, 4);
	pq_source_read(src, src->len - 8, tail, 8);
	if (memcmp(head, "PAR1", 4) != 0 || memcmp(tail + 4, "PAR1", 4) != 0)
	{
		FreeFile(src->f);
		ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
						errmsg("\"%s\" is not a Parquet file (bad magic)", path)));
	}
	memcpy(&src->metalen, tail, 4);

	/*
	 * The footer length is file-declared, so it is bounded before it sizes an
	 * allocation: it must fit between the leading magic and the 8-byte trailer,
	 * which also keeps it under MaxAllocSize on any file palloc could hold.
	 */
	if ((int64) src->metalen + 8 > src->len || src->metalen > MaxAllocSize)
	{
		FreeFile(src->f);
		ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
						errmsg("\"%s\" has a corrupt Parquet footer", path)));
	}

	src->meta = (uint8 *) palloc(Max(src->metalen, 1));
	pq_source_read(src, src->len - 8 - src->metalen, src->meta, src->metalen);

	if (!parse_file_metadata(src->meta, src->metalen, pf))
	{
		FreeFile(src->f);
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						errmsg("could not parse \"%s\" (unsupported or corrupt Parquet metadata)", path)));
	}
}

static void
pq_source_close(PqSource *src)
{
	if (src->f != NULL)
	{
		FreeFile(src->f);
		src->f = NULL;
	}
}

/*
 * Page headers are small thrift structures, but a v2 header can carry column
 * statistics whose min and max are values from the column, so the size is
 * file-controlled. Read a window and grow it rather than guessing: start well
 * above a typical header, and refuse past a cap instead of reading unboundedly
 * on a corrupt file.
 */
#define PQ_PAGE_HDR_WIN_MIN 4096
#define PQ_PAGE_HDR_WIN_MAX (16 * 1024 * 1024)

/*
 * Parse the page header at `off`, returning its parsed form and encoded length.
 *
 * The thrift reader sets `error` both when the input is structurally wrong and
 * when it simply ran out of bytes, and those are indistinguishable from inside
 * the parse. They are separable from out here: if the window stopped short of
 * end of file, a failure may be truncation, so grow and retry; if the window
 * already reached end of file, or the cap, the header is corrupt.
 */
static bool
pq_read_page_header(PqSource *src, int64 off, PqPageHeader *h, size_t *hdrlenOut)
{
	int64		avail;
	size_t		win = PQ_PAGE_HDR_WIN_MIN;

	/*
	 * A page offset outside the file. In practice the reachable case is a
	 * negative offset from a crafted footer: the decode loop's own "pos < len"
	 * condition already stops before an offset past end of file, and the file is
	 * then rejected by the short-chunk check. The upper half is kept because it
	 * is pq_source_read's precondition, which that function asserts.
	 */
	if (off < 0 || off >= src->len)
		return false;
	avail = src->len - off;

	for (;;)
	{
		TCReader	hr;
		uint8	   *buf;
		size_t		n = (size_t) Min((int64) win, avail);

		buf = (uint8 *) palloc(n);
		pq_source_read(src, off, buf, n);
		hr.buf = buf;
		hr.len = n;
		hr.pos = 0;
		hr.error = false;
		parse_page_header(&hr, h);
		if (!hr.error)
		{
			*hdrlenOut = hr.pos;
			pfree(buf);
			return true;
		}
		pfree(buf);
		if ((int64) n >= avail || win >= PQ_PAGE_HDR_WIN_MAX)
			return false;
		win *= 2;
	}
}

/*
 * Decode a whole column chunk into its Dremel entry sequence: defs[nEntries],
 * reps[nEntries], and vals[nPresent] (present entries, def == max_def, densely
 * packed in order). The caller pre-allocates the arrays to ch->num_values. A
 * flat scalar (max_rep 0, max_def <= 1) yields one entry per row; nested leaves
 * carry rep/def levels the assembler groups into arrays/composites.
 */
static bool
decode_leaf_entries(PqSource *src, PqChunk *ch,
					PqColPlan *plan, int max_def, int max_rep,
					uint32 *defs, uint32 *reps, Datum *vals,
					int64 *nEntriesOut, int64 *nPresentOut)
{
	int64		pos = ch->dict_page_offset ? ch->dict_page_offset
		: ch->data_page_offset;
	int64		nEntries = 0;
	int64		nPresent = 0;
	Datum	   *dict = NULL;
	int			dictCount = 0;
	int			nDictPages = 0;

	while (nEntries < ch->num_values && pos < src->len)
	{
		PqPageHeader h;
		const uint8 *praw;
		uint8	   *pagebuf;
		size_t		hdrlen;
		StringInfoData dec;

		CHECK_FOR_INTERRUPTS();

		if (!pq_read_page_header(src, pos, &h, &hdrlen))
			return false;

		/*
		 * Progress. A data page claiming no values makes none toward
		 * ch->num_values, and a run of zero bytes parses as exactly that (a zero
		 * byte is a Thrift STOP, giving a v1 data page with num_values 0 and
		 * compressed_size 0), so such a file would otherwise walk the loop once
		 * per byte to end of file: unbounded work on a file the reader can now
		 * open at any size.
		 *
		 * A DICTIONARY page is exempt, because an empty one is legitimate: an
		 * all-null column written by pyarrow carries a dictionary page with zero
		 * entries, and rejecting it broke a file real writers produce. Progress
		 * is preserved instead by the format's own rule that a column chunk has
		 * at most one dictionary page, so a crafted run of them cannot walk the
		 * file either.
		 */
		if (h.type == PQ_PAGE_DICTIONARY)
		{
			if (++nDictPages > 1)
				return false;
		}
		else if (h.num_values <= 0)
			return false;

		/*
		 * v2 keeps its levels uncompressed at the front of the page, and both
		 * lengths are file-declared. Unchecked, a large def_levels_len reads past
		 * the page (now a tight per-page allocation, so immediately off the end),
		 * and compressed_size - levLen goes negative into a size_t, making every
		 * later bounds check meaningless. Bound the pair against the page before
		 * either is used.
		 */
		if (h.is_v2 &&
			(h.def_levels_len < 0 || h.rep_levels_len < 0 ||
			 (int64) h.def_levels_len + (int64) h.rep_levels_len >
			 (int64) h.compressed_size))
			return false;

		/*
		 * compressed_size is file-declared, so it is bounded against what is
		 * actually left after this header before it sizes the read. Every value
		 * decoded below is copied out of this buffer (plain_value_to_datum
		 * palloc's and memcpy's, including for the dictionary), so the page is
		 * freed at the end of the iteration and peak memory stays at one page.
		 */
		if (h.compressed_size < 0 ||
			(int64) h.compressed_size > src->len - pos - (int64) hdrlen)
			return false;
		pagebuf = (uint8 *) palloc(Max(h.compressed_size, 1));
		pq_source_read(src, pos + (int64) hdrlen, pagebuf,
					   (size_t) h.compressed_size);
		praw = pagebuf;

		initStringInfo(&dec);

		if (h.type == PQ_PAGE_DICTIONARY)
		{
			const uint8 *db;
			size_t		dblen;
			const uint8 *p;
			const uint8 *end;
			int			i;

			if (!ColumnarParquetDecompress(ch->codec, praw, h.compressed_size,
							   h.uncompressed_size, &dec, &db, &dblen))
				return false;
			dictCount = h.num_values;
			dict = palloc(sizeof(Datum) * Max(dictCount, 1));
			p = db;
			end = db + dblen;
			if (plan->expect_phys == PQ_BOOLEAN)
				decode_plain_bools(db, dictCount, dict);
			else
				for (i = 0; i < dictCount; i++)
				{
					bool		ok;

					dict[i] = plain_value_to_datum(plan, &p, end, true, &ok);
					if (!ok)
						return false;
				}
			pos += hdrlen + h.compressed_size;
			pfree(pagebuf);
			pfree(dec.data);
			continue;
		}

		/* a data page (v1 or v2) */
		{
			int			npage = h.num_values;
			uint32	   *pdefs = NULL;
			uint32	   *preps = NULL;
			const uint8 *valbuf;
			size_t		vallen;
			int			i;
			int			nnn;
			Datum	   *pv;

			if (h.is_v2)
			{
				const uint8 *levels = praw;
				int			levLen = h.def_levels_len + h.rep_levels_len;
				const uint8 *vraw = praw + levLen;
				int			vrawlen = h.compressed_size - levLen;

				if (max_rep > 0)
				{
					preps = palloc(sizeof(uint32) * npage);
					if (!rle_bitpack_decode(levels, h.rep_levels_len,
											bits_for(max_rep), npage, preps))
						return false;
				}
				if (max_def > 0)
				{
					pdefs = palloc(sizeof(uint32) * npage);
					if (!rle_bitpack_decode(levels + h.rep_levels_len,
											h.def_levels_len, bits_for(max_def),
											npage, pdefs))
						return false;
				}
				if (h.is_compressed)
				{
					/* v2 stores levels uncompressed; the compressed body is the
					 * values, whose uncompressed size is the page total minus the
					 * (uncompressed) level bytes. */
					size_t		vusize = (h.uncompressed_size > levLen)
						? (size_t) (h.uncompressed_size - levLen) : 0;

					if (!ColumnarParquetDecompress(ch->codec, vraw, vrawlen, vusize,
									   &dec, &valbuf, &vallen))
						return false;
				}
				else
				{
					valbuf = vraw;
					vallen = vrawlen;
				}
			}
			else
			{
				const uint8 *pb;
				size_t		pblen;
				size_t		off = 0;

				if (!ColumnarParquetDecompress(ch->codec, praw, h.compressed_size,
								   h.uncompressed_size, &dec, &pb, &pblen))
					return false;
				/* v1: repetition levels first, then definition levels, both
				 * prefixed with a 4-byte length */
				if (max_rep > 0)
				{
					uint32		llen;

					if (off + 4 > pblen)
						return false;
					memcpy(&llen, pb + off, 4);
					off += 4;
					if (off + llen > pblen)
						return false;
					preps = palloc(sizeof(uint32) * npage);
					if (!rle_bitpack_decode(pb + off, llen, bits_for(max_rep),
											npage, preps))
						return false;
					off += llen;
				}
				if (max_def > 0)
				{
					uint32		llen;

					if (off + 4 > pblen)
						return false;
					memcpy(&llen, pb + off, 4);
					off += 4;
					if (off + llen > pblen)
						return false;
					pdefs = palloc(sizeof(uint32) * npage);
					if (!rle_bitpack_decode(pb + off, llen, bits_for(max_def),
											npage, pdefs))
						return false;
					off += llen;
				}
				valbuf = pb + off;
				vallen = pblen - off;
			}

			if (max_def > 0)
			{
				nnn = 0;
				for (i = 0; i < npage; i++)
					if (pdefs[i] == (uint32) max_def)
						nnn++;
			}
			else
				nnn = npage;

			pv = palloc(sizeof(Datum) * Max(nnn, 1));
			if (h.encoding == PQE_RLE_DICTIONARY || h.encoding == PQE_PLAIN_DICTIONARY)
			{
				uint32	   *idx;
				int			bw;

				if (dict == NULL || vallen < 1)
					return false;
				bw = valbuf[0];
				idx = palloc(sizeof(uint32) * Max(nnn, 1));
				if (!rle_bitpack_decode(valbuf + 1, vallen - 1, bw, nnn, idx))
					return false;
				for (i = 0; i < nnn; i++)
				{
					if ((int) idx[i] >= dictCount)
						return false;
					pv[i] = dict[idx[i]];
				}
			}
			else if (h.encoding == PQE_PLAIN)
			{
				if (plan->expect_phys == PQ_BOOLEAN)
					decode_plain_bools(valbuf, nnn, pv);
				else
				{
					const uint8 *p = valbuf;
					const uint8 *end = valbuf + vallen;

					for (i = 0; i < nnn; i++)
					{
						bool		ok;

						pv[i] = plain_value_to_datum(plan, &p, end, true, &ok);
						if (!ok)
							return false;
					}
				}
			}
			else if (h.encoding == PQE_RLE && plan->expect_phys == PQ_BOOLEAN)
			{
				uint32		rlen;
				uint32	   *bits;

				if (vallen < 4)
					return false;
				memcpy(&rlen, valbuf, 4);
				if ((size_t) rlen + 4 > vallen)
					return false;
				bits = palloc(sizeof(uint32) * Max(nnn, 1));
				if (!rle_bitpack_decode(valbuf + 4, rlen, 1, nnn, bits))
					return false;
				for (i = 0; i < nnn; i++)
					pv[i] = BoolGetDatum(bits[i] != 0);
			}
			else
				return false;	/* unsupported value encoding */

			/* append this page's entries (levels) and present values */
			for (i = 0; i < npage; i++)
			{
				defs[nEntries] = (max_def > 0) ? pdefs[i] : 0;
				reps[nEntries] = (max_rep > 0) ? preps[i] : 0;
				nEntries++;
			}
			for (i = 0; i < nnn; i++)
				vals[nPresent++] = pv[i];
			pos += hdrlen + h.compressed_size;

			/*
			 * Both buffers are freed each iteration, which is what makes peak raw
			 * memory one page rather than one row group: groupCtx is only reset at
			 * the row-group boundary, so without this they would accumulate across
			 * every page of the chunk. Safe because each value is copied out of
			 * the page above (plain_value_to_datum palloc's and memcpy's, and the
			 * dictionary is built the same way), so nothing points into either
			 * buffer after this point.
			 */
			pfree(pagebuf);
			pfree(dec.data);
		}
	}
	*nEntriesOut = nEntries;
	*nPresentOut = nPresent;
	return nEntries == ch->num_values;
}

/*
 * Map a target PostgreSQL scalar type to the Parquet physical type it must have
 * been written as. Returns -1 for an unsupported type.
 */
static int
pq_want_phys(Oid typid)
{
	switch (typid)
	{
		case INT2OID:
		case INT4OID:
		case DATEOID:
			return PQ_INT32;
		case INT8OID:
		case TIMESTAMPOID:
		case TIMESTAMPTZOID:
		case TIMEOID:
			return PQ_INT64;
		case FLOAT4OID:
			return PQ_FLOAT;
		case FLOAT8OID:
			return PQ_DOUBLE;
		case BOOLOID:
			return PQ_BOOLEAN;
		case TEXTOID:
		case VARCHAROID:
		case BYTEAOID:
			return PQ_BYTE_ARRAY;
		default:
			return -1;
	}
}

/*
 * The schema column for leaf lf, or NULL when lf is past the file's columns.
 * The bind sites below compute the wanted physical type before checking that
 * lf is in range, so this must tolerate an out-of-range index rather than read
 * past pf->leaves[].
 */
static const PqSchemaCol *
pq_leaf_sc(const PqFile *pf, int lf)
{
	return (lf >= 0 && lf < pf->ncols) ? pf->leaves[lf].sc : NULL;
}

/*
 * Copy the schema-derived decode parameters for one leaf onto its plan. Called at
 * each bind site once plan->typid and expect_phys are set. is_decimal keys off the
 * already-set typid, so the decoder only treats bytes as a DECIMAL when the target
 * really is numeric.
 */
static void
pq_plan_bind_schema(PqColPlan *plan, const PqSchemaCol *sc)
{
	plan->time_unit = sc->time_unit;
	plan->type_length = sc->type_length;
	plan->dec_scale = sc->scale;
	plan->is_decimal = (plan->typid == NUMERICOID &&
						sc->converted_type == PQ_CT_DECIMAL);
}

/*
 * The Parquet physical type a target PostgreSQL type must be stored as, for one
 * specific source column. Only `time` is column-dependent: Parquet spells
 * TIME_MILLIS as INT32 and TIME_MICROS/TIME_NANOS as INT64, so the same
 * PostgreSQL type binds to either width depending on the unit the file declares.
 * Everything else is a fixed mapping and falls through to pq_want_phys().
 */
static int
pq_want_phys_for(Oid typid, const PqSchemaCol *sc)
{
	if (sc != NULL)
	{
		if (typid == TIMEOID &&
			sc->time_unit == PQ_TU_MILLIS && !sc->is_timestamp)
			return PQ_INT32;
		/* uuid is a 16-byte fixed-length binary */
		if (typid == UUIDOID)
			return PQ_FIXED_LEN_BYTE_ARRAY;
		/* DECIMAL as fixed or variable big-endian two's-complement bytes, or as
		 * an INT32/INT64 holding the unscaled integer (what writers use for small
		 * precisions). precision and scale come straight from the footer, so they
		 * are bounded before the decoder trusts scale: an unvalidated scale drives
		 * pq_decimal_to_numeric's zero-fill. */
		if (typid == NUMERICOID && sc->converted_type == PQ_CT_DECIMAL &&
			pq_decimal_bounds_ok(sc) &&
			(sc->phys_type == PQ_FIXED_LEN_BYTE_ARRAY ||
			 sc->phys_type == PQ_BYTE_ARRAY ||
			 sc->phys_type == PQ_INT32 ||
			 sc->phys_type == PQ_INT64))
			return sc->phys_type;
	}
	return pq_want_phys(typid);
}

/*
 * Infer the PostgreSQL column type a Parquet leaf should map to. This is the
 * inverse of the exporter's parquet_kind_for_type (columnar_parquet.c): it reads
 * the physical type plus the ConvertedType annotation, so a round-tripped file
 * reports the source column types. It is tolerant of files other writers produce
 * (both the millis and micros time/timestamp variants, INT_8/INT_32 widths) so
 * the schema view is useful for foreign Parquet too. Returns true and sets
 * the out-params typid and typmod on success; returns false for a leaf whose
 * type cannot be mapped to a supported scalar (the caller reports it unknown).
 */
static bool
pq_leaf_to_pgtype(const PqSchemaCol *sc, Oid *typid, int32 *typmod)
{
	int			ct = sc->converted_type;

	*typmod = -1;

	switch (sc->phys_type)
	{
		case PQ_BOOLEAN:
			*typid = BOOLOID;
			return true;
		case PQ_INT32:
			if (ct == PQ_CT_DECIMAL && pq_decimal_bounds_ok(sc))
			{
				*typid = NUMERICOID;
				*typmod = pq_decimal_typmod(sc);
				return true;
			}
			if (ct == PQ_CT_DATE)
				*typid = DATEOID;
			else if (sc->time_unit != PQ_TU_NONE && !sc->is_timestamp)
				*typid = TIMEOID;	/* TIME_MILLIS is physically INT32 */
			else if (ct == PQ_CT_INT_8 || ct == PQ_CT_INT_16)
				*typid = INT2OID;
			else
				*typid = INT4OID;	/* INT_32 or unannotated */
			return true;
		case PQ_INT64:

			/*
			 * Advise a temporal type only when the unit converts to PostgreSQL's
			 * microseconds without loss. Millis and micros do. Nanos do not:
			 * PostgreSQL has no nanosecond type, so the advice stays bigint, which
			 * holds the stored value exactly and leaves the choice to the user.
			 * Declaring timestamp anyway is supported and decodes correctly, with
			 * the sub-microsecond digits truncated -- but that is a loss worth
			 * opting into rather than being advised into. float8 would be worse
			 * than either: a nanosecond timestamp of this era needs about 61 bits
			 * and a double carries 53, so it cannot even represent the value.
			 */
			if (ct == PQ_CT_DECIMAL && pq_decimal_bounds_ok(sc))
			{
				*typid = NUMERICOID;
				*typmod = pq_decimal_typmod(sc);
				return true;
			}
			if (sc->time_unit == PQ_TU_MILLIS || sc->time_unit == PQ_TU_MICROS)
				*typid = sc->is_timestamp ? TIMESTAMPOID : TIMEOID;
			else
				*typid = INT8OID;	/* INT_64, nanos, or unannotated */
			return true;
		case PQ_FLOAT:
			*typid = FLOAT4OID;
			return true;
		case PQ_DOUBLE:
			*typid = FLOAT8OID;
			return true;
		case PQ_BYTE_ARRAY:
			/* UTF8/ENUM/JSON annotate string data; anything else is raw bytes */
			if (ct == PQ_CT_UTF8 || ct == PQ_CT_ENUM || ct == PQ_CT_JSON)
				*typid = TEXTOID;
			else
				*typid = BYTEAOID;
			return true;
		case PQ_FIXED_LEN_BYTE_ARRAY:
			if (ct == PQ_CT_DECIMAL && pq_decimal_bounds_ok(sc))
			{
				*typid = NUMERICOID;
				*typmod = pq_decimal_typmod(sc);
				return true;
			}
			if (ct < 0 && sc->type_length == 16)
			{
				/* the exporter writes uuid as an unannotated 16-byte FLBA */
				*typid = UUIDOID;
				return true;
			}
			*typid = BYTEAOID;
			return true;
		default:
			return false;
	}
}

/* -------------------------------------------------------------------------
 * Nested import assembly. A target column is one of three shapes, mirroring the
 * nested Parquet exporter: a scalar leaf, a 1-D array (LIST of one element leaf),
 * or a composite (group of scalar field leaves). Each leaf is decoded into its
 * full Dremel entry sequence (defs/reps/dense values), then rows are assembled
 * by walking the entries and grouping repeated runs (rep > 0) into arrays.
 * ------------------------------------------------------------------------- */
typedef enum
{
	IMP_SCALAR,
	IMP_LIST,
	IMP_STRUCT
}			ImpKind;

/* one primitive leaf column: decoding plan + decoded entry stream + cursors */
typedef struct ImpLeaf
{
	PqColPlan	plan;
	int			max_def;
	int			max_rep;
	/* decoded per row group */
	uint32	   *defs;
	uint32	   *reps;
	Datum	   *vals;
	int64		nEntries;
	int64		nPresent;
	int64		ei;				/* entry cursor */
	int64		vi;				/* present-value cursor */
}			ImpLeaf;

typedef struct ImpTop
{
	ImpKind		kind;
	int			attno;			/* target attribute index (0-based) */
	int			firstLeaf;		/* index into leaves[] */
	int			nleaves;
	/* IMP_LIST */
	Oid			elemtype;
	int16		elemlen;
	bool		elembyval;
	char		elemalign;
	/* IMP_STRUCT */
	TupleDesc	structDesc;
	int		   *fieldLeaf;		/* [structDesc->natts] leaf index or -1 */
}			ImpTop;

/*
 * Build the target tree from the tuple descriptor and bind each leaf to a
 * Parquet leaf column (validating physical type and Dremel level bounds).
 * Returns the tops array; sets the leaves array and top count via out-params.
 *
 * Relation-free: on a binding error it just ereports, and any relation the caller
 * holds is released by transaction abort. This lets a caller with no relation (the
 * read_parquet function, the FDW) bind a descriptor against a file exactly as
 * import binds a target table's descriptor.
 */
static ImpTop *
build_imp_targets(TupleDesc tupdesc, PqFile *pf,
				  ImpLeaf **pleaves, int *ntops, const bool *skipAtt)
{
	int			natts = tupdesc->natts;
	ImpTop	   *tops = palloc0(sizeof(ImpTop) * Max(natts, 1));
	ImpLeaf    *leaves = palloc0(sizeof(ImpLeaf) * Max(pf->ncols, 1));
	int			nt = 0;
	int			lf = 0;
	int			i;

#define IMP_FAIL(...) \
	ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH), errmsg(__VA_ARGS__)))

	for (i = 0; i < natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(tupdesc, i);
		Oid			typid;
		Oid			elemtype;
		ImpTop	   *t;

		if (att->attisdropped)
			continue;
		/*
		 * A column the file does not carry: a partition column, whose value comes
		 * from the directory name rather than from any leaf. Skipping it here is
		 * what keeps the "every leaf must be declared" identity intact, since it
		 * consumes no leaf.
		 */
		if (skipAtt != NULL && skipAtt[i])
			continue;
		typid = att->atttypid;
		t = &tops[nt];
		t->attno = i;
		t->firstLeaf = lf;

		elemtype = get_element_type(typid);
		if (OidIsValid(elemtype))
		{
			/* 1-D array -> LIST(element) */
			int			want = pq_want_phys_for(elemtype, pq_leaf_sc(pf, lf));
			ImpLeaf    *l = &leaves[lf];

			if (want < 0)
				IMP_FAIL("array column \"%s\" has element type %s, which columnar.import_parquet does not support",
						 NameStr(att->attname), format_type_be(elemtype));
			if (lf >= pf->ncols)
				IMP_FAIL("Parquet file has fewer columns than the target table");
			if (pf->leaves[lf].max_rep < 1)
				IMP_FAIL("target column \"%s\" is an array but the Parquet column is not repeated",
						 NameStr(att->attname));
			if (pf->leaves[lf].sc->phys_type != want)
				IMP_FAIL("Parquet column for array \"%s\" has incompatible physical type",
						 NameStr(att->attname));
			t->kind = IMP_LIST;
			t->nleaves = 1;
			t->elemtype = elemtype;
			get_typlenbyvalalign(elemtype, &t->elemlen, &t->elembyval, &t->elemalign);
			l->plan.typid = elemtype;
			get_typlenbyval(elemtype, &l->plan.typlen, &l->plan.typbyval);
			l->plan.expect_phys = want;
			pq_plan_bind_schema(&l->plan, pf->leaves[lf].sc);
			l->max_def = pf->leaves[lf].max_def;
			l->max_rep = pf->leaves[lf].max_rep;
			lf++;
		}
		else if (get_typtype(typid) == TYPTYPE_COMPOSITE)
		{
			/* composite -> group of scalar field leaves */
			TupleDesc	td = lookup_rowtype_tupdesc(typid, att->atttypmod);
			int			a;

			t->kind = IMP_STRUCT;
			t->structDesc = CreateTupleDescCopy(td);
			t->fieldLeaf = palloc(sizeof(int) * td->natts);
			for (a = 0; a < td->natts; a++)
			{
				Form_pg_attribute fa = TupleDescAttr(td, a);
				int			want;
				ImpLeaf    *l;

				if (fa->attisdropped)
				{
					t->fieldLeaf[a] = -1;
					continue;
				}
				want = pq_want_phys_for(fa->atttypid, pq_leaf_sc(pf, lf));
				if (want < 0)
				{
					ReleaseTupleDesc(td);
					IMP_FAIL("composite column \"%s\" field \"%s\" has type %s, which columnar.import_parquet does not support",
							 NameStr(att->attname), NameStr(fa->attname),
							 format_type_be(fa->atttypid));
				}
				if (lf >= pf->ncols)
				{
					ReleaseTupleDesc(td);
					IMP_FAIL("Parquet file has fewer columns than the target table");
				}
				if (pf->leaves[lf].max_rep != 0)
				{
					ReleaseTupleDesc(td);
					IMP_FAIL("Parquet column for composite field \"%s\" is unexpectedly repeated",
							 NameStr(fa->attname));
				}
				if (pf->leaves[lf].sc->phys_type != want)
				{
					ReleaseTupleDesc(td);
					IMP_FAIL("Parquet column for composite field \"%s\" has incompatible physical type",
							 NameStr(fa->attname));
				}
				l = &leaves[lf];
				l->plan.typid = fa->atttypid;
				get_typlenbyval(fa->atttypid, &l->plan.typlen, &l->plan.typbyval);
				l->plan.expect_phys = want;
				pq_plan_bind_schema(&l->plan, pf->leaves[lf].sc);
				l->max_def = pf->leaves[lf].max_def;
				l->max_rep = pf->leaves[lf].max_rep;
				t->fieldLeaf[a] = lf;
				lf++;
			}
			t->nleaves = lf - t->firstLeaf;
			ReleaseTupleDesc(td);
		}
		else
		{
			/* plain scalar */
			int			want = pq_want_phys_for(typid, pq_leaf_sc(pf, lf));
			ImpLeaf    *l = &leaves[lf];

			if (want < 0)
				IMP_FAIL("column \"%s\" has type %s, which columnar.import_parquet does not support",
						 NameStr(att->attname), format_type_be(typid));
			if (lf >= pf->ncols)
				IMP_FAIL("Parquet file has fewer columns than the target table");
			if (pf->leaves[lf].max_rep != 0)
				IMP_FAIL("Parquet column for scalar \"%s\" is unexpectedly repeated",
						 NameStr(att->attname));
			if (pf->leaves[lf].sc->phys_type != want)
				IMP_FAIL("Parquet column %d physical type is not compatible with target column \"%s\" (%s)",
						 lf, NameStr(att->attname), format_type_be(typid));
			t->kind = IMP_SCALAR;
			t->nleaves = 1;
			l->plan.typid = typid;
			get_typlenbyval(typid, &l->plan.typlen, &l->plan.typbyval);
			l->plan.expect_phys = want;
			pq_plan_bind_schema(&l->plan, pf->leaves[lf].sc);
			l->max_def = pf->leaves[lf].max_def;
			l->max_rep = pf->leaves[lf].max_rep;
			lf++;
		}
		nt++;
	}

	if (lf != pf->ncols)
		IMP_FAIL("Parquet file has %d leaf columns, target table expands to %d",
				 pf->ncols, lf);
#undef IMP_FAIL

	*pleaves = leaves;
	*ntops = nt;
	return tops;
}

/*
 * Read an entire server-side Parquet file into a palloc'd buffer and parse its
 * footer metadata into *pf. On success the file bytes are returned in *bufOut
 * (length *lenOut), allocated in the caller's memory context. This never returns
 * on failure: any open/size/read/format/metadata error is reported with ereport,
 * so the caller does not need to check a return value or clean the buffer up.
 * The caller is responsible for any privilege check before calling.
 */
/* strcmp comparator for list_sort over a List of cstrings */
static int
pq_list_str_cmp(const ListCell *a, const ListCell *b)
{
	return strcmp((const char *) lfirst(a), (const char *) lfirst(b));
}

/* does this string contain a glob metacharacter? */
static bool
pq_has_glob_meta(const char *s)
{
	return strpbrk(s, "*?[") != NULL;
}

/* case-insensitive test for a ".parquet" suffix */
static bool
pq_has_parquet_ext(const char *name)
{
	size_t		n = strlen(name);

	return n >= 8 && pg_strcasecmp(name + n - 8, ".parquet") == 0;
}

/*
 * Whether a path produced by a directory listing or a glob expansion should be
 * handed to the reader.
 *
 * The test is not "is this a regular file" but "do we know what it is". A path we
 * cannot stat is kept, so the reader's open reports it by name with errno
 * (a dangling symlink, a parent that denies search, a symlink loop); dropping it
 * here would turn those into a query that succeeds with fewer rows, which is the
 * one failure a read surface must not produce.
 *
 * A directory is skipped: a foo.parquet directory is a normal thing to find in a
 * Hive-style tree, and before this it reached the parser as "not a Parquet file".
 * Any other non-regular entry is skipped too, and that exclusion is not
 * cosmetic: AllocateFile() on a FIFO blocks in open(2) until a writer appears,
 * and because the signal handlers are installed with SA_RESTART the open resumes
 * rather than failing with EINTR, so a query cancel does not reliably get the
 * backend back.
 */
static bool
pq_path_is_candidate(const char *path)
{
	struct stat st;

	if (stat(path, &st) != 0)
		return true;			/* unknown: let the caller's open report it */
	return S_ISREG(st.st_mode);
}

/*
 * The deepest directory nesting a resolved path may have. A bound is needed
 * because the walk below recurses, and a tree can be arbitrarily deep; erroring
 * is better than truncating, which would silently read fewer rows.
 */
#define PQ_MAX_WALK_DEPTH 32

/*
 * Collect the *.parquet files at or below `path`, descending into subdirectories.
 *
 * Symlinked directories are deliberately not followed. A symlink to an ancestor
 * makes the walk infinite, and detecting that properly means carrying the set of
 * visited (st_dev, st_ino) pairs down the recursion. Refusing to descend through
 * a directory symlink is a rule a user can predict, and it costs only the case of
 * a tree stitched together from links. A symlink to a FILE is still followed, as
 * before, so the common "link one file into a directory" layout keeps working.
 *
 * Each directory is closed before recursing into its children, so open
 * descriptors do not grow with depth.
 */
static void
pq_walk_dir(const char *path, int depth, List **files, int *skipped)
{
	DIR		   *dir;
	struct dirent *de;
	List	   *subdirs = NIL;
	ListCell   *lc;

	if (depth > PQ_MAX_WALK_DEPTH)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("directory tree under \"%s\" is nested deeper than %d levels",
						path, PQ_MAX_WALK_DEPTH)));

	dir = AllocateDir(path);
	if (dir == NULL)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open directory \"%s\": %m", path)));

	while ((de = ReadDir(dir, path)) != NULL)
	{
		char	   *full;
		struct stat st;
		struct stat lst;

		if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
			continue;

		/*
		 * Skip names beginning with '_' or '.', the convention every engine in
		 * this ecosystem writes and reads: a Spark or Hive output directory
		 * carries _SUCCESS and a _temporary tree of in-progress task output, and
		 * reading that tree means reading files another writer is still producing.
		 * Hidden dotfiles are skipped for the same reason. This applies to
		 * directories and files alike, and only to a walk: a path named
		 * explicitly is still read.
		 */
		if (de->d_name[0] == '_' || de->d_name[0] == '.')
			continue;

		full = psprintf("%s/%s", path, de->d_name);

		/* a directory reached through a symlink: not followed, see above */
		if (lstat(full, &lst) == 0 && S_ISLNK(lst.st_mode) &&
			stat(full, &st) == 0 && S_ISDIR(st.st_mode))
		{
			pfree(full);
			continue;
		}
		if (stat(full, &st) == 0 && S_ISDIR(st.st_mode))
		{
			subdirs = lappend(subdirs, full);
			continue;
		}
		/* a plain entry: only *.parquet names are candidates */
		if (!pq_has_parquet_ext(de->d_name))
		{
			pfree(full);
			continue;
		}
		if (pq_path_is_candidate(full))
			*files = lappend(*files, full);
		else
		{
			(*skipped)++;
			pfree(full);
		}
	}
	FreeDir(dir);

	foreach(lc, subdirs)
		pq_walk_dir((char *) lfirst(lc), depth + 1, files, skipped);
}

/*
 * Resolve a path option into the concrete file(s) to read, in a stable sorted
 * order:
 *   - a regular file            -> just that file
 *   - a directory               -> every *.parquet directly inside it
 *   - a glob pattern (* ? [)     -> its matches
 *   - anything else              -> the path as-is, so the caller's open raises
 *     the normal "could not open file" error for a genuine typo.
 * An empty directory or a non-matching glob is an error: the user named a set and
 * meant to read something. Returns a List of palloc'd cstrings.
 */
static List *
pq_resolve_paths(const char *path)
{
	struct stat st;
	List	   *files = NIL;

	if (stat(path, &st) == 0 && S_ISDIR(st.st_mode))
	{
		int			skipped = 0;

		pq_walk_dir(path, 0, &files, &skipped);
		if (files == NIL)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_FILE),
					 errmsg("directory \"%s\" contains no .parquet files", path),
			/* say why a name the user can see in the listing did not count */
					 skipped > 0 ?
					 errdetail_plural("%d matching name is not a regular file.",
									  "%d matching names are not regular files.",
									  skipped, skipped) : 0));
		list_sort(files, pq_list_str_cmp);
		return files;
	}

	if (pq_has_glob_meta(path))
	{
		glob_t		g;
		int			rc;
		size_t		i;

		memset(&g, 0, sizeof(g));
		rc = glob(path, GLOB_NOSORT, NULL, &g);
		if (rc == GLOB_NOMATCH || g.gl_pathc == 0)
		{
			globfree(&g);
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_FILE),
					 errmsg("no files match pattern \"%s\"", path)));
		}
		if (rc != 0)
		{
			globfree(&g);
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not expand pattern \"%s\"", path)));
		}
		for (i = 0; i < g.gl_pathc; i++)
			if (pq_path_is_candidate(g.gl_pathv[i]))
				files = lappend(files, pstrdup(g.gl_pathv[i]));
		globfree(&g);
		if (files == NIL)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_FILE),
					 errmsg("pattern \"%s\" matched no regular files", path)));
		list_sort(files, pq_list_str_cmp);
		return files;
	}

	/* a plain path (possibly nonexistent): let the caller's open report it */
	return list_make1(pstrdup(path));
}

/*
 * Row sink for the shared reader: called once per assembled row with the row in
 * slot (already ExecStoreVirtualTuple'd). The sink must copy the row out, because
 * the caller resets the per-row memory immediately after; both table_tuple_insert
 * and tuplestore_puttupleslot do.
 */
typedef void (*PqRowSink) (TupleTableSlot *slot, void *arg);

typedef struct PqInsertSinkArg
{
	Relation	rel;
	CommandId	cid;
	ColumnarIndexInsertState *indexes;	/* NULL when the table has none */
}			PqInsertSinkArg;

static void
pq_insert_sink(TupleTableSlot *slot, void *arg)
{
	PqInsertSinkArg *a = (PqInsertSinkArg *) arg;

	table_tuple_insert(a->rel, slot, a->cid, 0, NULL);

	/*
	 * table_tuple_insert writes the row and nothing else: index maintenance is
	 * the executor's job, and there is no executor here. Without this the
	 * imported rows are invisible to every index scan and a unique index accepts
	 * duplicates (issue #153). tts_tid carries the row number the insert
	 * assigned.
	 */
	if (a->indexes != NULL)
		ColumnarIndexInsertRow(a->indexes, a->rel, slot->tts_values,
							   slot->tts_isnull,
							   ColumnarItemPointerToRowNumber(&slot->tts_tid),
							   true);
}

static void
pq_tuplestore_sink(TupleTableSlot *slot, void *arg)
{
	tuplestore_puttupleslot((Tuplestorestate *) arg, slot);
}

/*
 * The shared row-producing core (Phase G scan core). For each row group it decodes
 * every leaf column into its Dremel entry stream, then assembles each row into slot
 * per the bound target tree (scalar, 1-D array from a LIST, composite from a group)
 * and hands it to sink. Returns the number of rows produced.
 *
 * groupCtx bounds each group's decoded streams; rowCtx bounds each row's transient
 * arrays/composites and is reset after the sink copies the row, so a large file
 * never accumulates O(rows) memory. Both import (insert sink) and read_parquet
 * (tuplestore sink) run through here, so their row semantics are identical.
 */
static int64
pq_read_rows(PqFile *pf, PqSource *src,
			 ImpTop *tops, int ntops, ImpLeaf *leaves,
			 TupleTableSlot *slot, PqRowSink sink, void *sinkarg,
			 const bool *skipGroup, const bool *needTop,
			 const Datum *constVals, const bool *constHas,
			 const bool *constNull)
{
	int			natts = slot->tts_tupleDescriptor->natts;
	MemoryContext groupCtx;
	MemoryContext rowCtx;
	bool	   *needLeaf;
	int64		total = 0;
	int			i;
	int			rg;
	int			t0;

	/*
	 * Projection pushdown: needTop[t] says whether target column t is referenced
	 * by the scan. NULL means every column is needed (import and read_parquet,
	 * which materialize all declared columns). A leaf is decoded only if some
	 * needed top reads it, so an unreferenced column's chunk is never decompressed
	 * or decoded. Its slot value stays NULL, which is safe precisely because
	 * nothing above the scan reads it.
	 */
	needLeaf = (bool *) palloc0(sizeof(bool) * Max(pf->ncols, 1));
	for (t0 = 0; t0 < ntops; t0++)
	{
		int			li;

		if (needTop != NULL && !needTop[t0])
			continue;
		for (li = 0; li < tops[t0].nleaves; li++)
			needLeaf[tops[t0].firstLeaf + li] = true;
	}

	groupCtx = AllocSetContextCreate(CurrentMemoryContext,
									 "columnar parquet read group",
									 ALLOCSET_DEFAULT_SIZES);
	rowCtx = AllocSetContextCreate(CurrentMemoryContext,
								   "columnar parquet read row",
								   ALLOCSET_DEFAULT_SIZES);

	for (rg = 0; rg < pf->nrowgroups; rg++)
	{
		PqRowGroup *g = &pf->rgs[rg];
		int64		n = g->num_rows;
		int64		r;
		int			t;
		MemoryContext oldCtx;

		/* row-group skipping (predicate pushdown): the group cannot match, so
		 * decode nothing and emit nothing. The executor still rechecks quals on
		 * the rows we do emit, so a missed skip only costs work, never rows. */
		if (skipGroup != NULL && skipGroup[rg])
			continue;

		/* decode every leaf column of this row group into its entry stream */
		MemoryContextReset(groupCtx);
		oldCtx = MemoryContextSwitchTo(groupCtx);
		for (i = 0; i < pf->ncols; i++)
		{
			ImpLeaf    *l = &leaves[i];
			PqChunk    *ch = &g->chunks[i];
			int64		cap = Max(ch->num_values, 1);

			if (!needLeaf[i])
				continue;		/* projected out: never decode this chunk */

			l->defs = palloc(sizeof(uint32) * cap);
			l->reps = palloc(sizeof(uint32) * cap);
			l->vals = palloc(sizeof(Datum) * cap);
			l->ei = 0;
			l->vi = 0;
			if (!decode_leaf_entries(src, ch, &l->plan,
									 l->max_def, l->max_rep,
									 l->defs, l->reps, l->vals,
									 &l->nEntries, &l->nPresent))
			{
				MemoryContextSwitchTo(oldCtx);
				ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
								errmsg("could not decode Parquet column %d in row group %d",
									   i, rg)));
			}
		}
		MemoryContextSwitchTo(oldCtx);

		for (r = 0; r < n; r++)
		{
			MemoryContext rowOld;

			ExecClearTuple(slot);
			for (i = 0; i < natts; i++)
				slot->tts_isnull[i] = true;

			/*
			 * Columns whose value is the same for every row of this file, which
			 * today means partition columns read from the directory names. They
			 * are stamped before the file's own columns are decoded so a decoded
			 * column always wins if the two ever overlap.
			 */
			if (constHas != NULL)
			{
				for (i = 0; i < natts; i++)
				{
					if (constHas[i])
					{
						bool		null = constNull != NULL && constNull[i];

						slot->tts_values[i] = null ? (Datum) 0 : constVals[i];
						slot->tts_isnull[i] = null;
					}
				}
			}

			rowOld = MemoryContextSwitchTo(rowCtx);
			for (t = 0; t < ntops; t++)
			{
				ImpTop	   *tp = &tops[t];

				/* projected out: its leaves were not decoded, so it cannot be
				 * assembled and its slot value stays NULL. */
				if (needTop != NULL && !needTop[t])
					continue;

				if (tp->kind == IMP_SCALAR)
				{
					ImpLeaf    *l = &leaves[tp->firstLeaf];
					bool		present = (l->defs[l->ei] == (uint32) l->max_def);

					slot->tts_values[tp->attno] = present ? l->vals[l->vi++] : (Datum) 0;
					slot->tts_isnull[tp->attno] = !present;
					l->ei++;
				}
				else if (tp->kind == IMP_LIST)
				{
					ImpLeaf    *l = &leaves[tp->firstLeaf];
					uint32		def0 = l->defs[l->ei];

					if (def0 == 0)
					{
						/* NULL array */
						slot->tts_isnull[tp->attno] = true;
						l->ei++;
					}
					else if (def0 == 1)
					{
						/* empty array */
						ArrayType  *arr = construct_empty_array(tp->elemtype);

						slot->tts_values[tp->attno] = PointerGetDatum(arr);
						slot->tts_isnull[tp->attno] = false;
						l->ei++;
					}
					else
					{
						/* one or more elements (rep marks continuation) */
						Datum	   *elems = palloc(sizeof(Datum) * Max(l->nEntries - l->ei, 1));
						bool	   *enulls = palloc(sizeof(bool) * Max(l->nEntries - l->ei, 1));
						int			k = 0;
						int			dims[1];
						int			lbs[1] = {1};
						ArrayType  *arr;

						do
						{
							uint32		d = l->defs[l->ei];

							if (d == (uint32) l->max_def)
							{
								elems[k] = l->vals[l->vi++];
								enulls[k] = false;
							}
							else
							{
								elems[k] = (Datum) 0;
								enulls[k] = true;
							}
							k++;
							l->ei++;
						} while (l->ei < l->nEntries && l->reps[l->ei] != 0);

						dims[0] = k;
						arr = construct_md_array(elems, enulls, 1, dims, lbs,
												 tp->elemtype, tp->elemlen,
												 tp->elembyval, tp->elemalign);
						slot->tts_values[tp->attno] = PointerGetDatum(arr);
						slot->tts_isnull[tp->attno] = false;
					}
				}
				else			/* IMP_STRUCT */
				{
					TupleDesc	sd = tp->structDesc;
					Datum	   *fv = palloc(sizeof(Datum) * sd->natts);
					bool	   *fn = palloc(sizeof(bool) * sd->natts);
					bool		structNull = false;
					int			a;

					for (a = 0; a < sd->natts; a++)
					{
						int			li = tp->fieldLeaf[a];
						ImpLeaf    *l;
						uint32		d;

						if (li < 0)
						{
							fv[a] = (Datum) 0;
							fn[a] = true;
							continue;
						}
						l = &leaves[li];
						d = l->defs[l->ei];
						if (d == 0)
							structNull = true;	/* every field agrees */
						if (d == (uint32) l->max_def)
						{
							fv[a] = l->vals[l->vi++];
							fn[a] = false;
						}
						else
						{
							fv[a] = (Datum) 0;
							fn[a] = true;
						}
						l->ei++;
					}

					if (structNull)
						slot->tts_isnull[tp->attno] = true;
					else
					{
						HeapTuple	htup = heap_form_tuple(sd, fv, fn);

						slot->tts_values[tp->attno] = HeapTupleGetDatum(htup);
						slot->tts_isnull[tp->attno] = false;
					}
				}
			}

			ExecStoreVirtualTuple(slot);
			sink(slot, sinkarg);
			MemoryContextSwitchTo(rowOld);
			MemoryContextReset(rowCtx);
			total++;
			CHECK_FOR_INTERRUPTS();
		}
	}

	MemoryContextDelete(groupCtx);
	MemoryContextDelete(rowCtx);
	return total;
}

/*
 * Read one file's rows into a sink, binding it against tupdesc. Factors the
 * slurp+validate+bind+read sequence shared by the multi-file loops so a directory
 * or glob reads each of its files through the same path a single file takes. The
 * per-file decode buffers are freed by the caller resetting the context this runs
 * in, so a large directory does not accumulate O(total bytes). Returns rows read.
 */
static int64
pq_read_file_into(const char *path, TupleDesc tupdesc, TupleTableSlot *slot,
				  PqRowSink sink, void *sinkarg)
{
	PqSource	src;
	PqFile		pf;
	ImpTop	   *tops;
	ImpLeaf    *leaves;
	int			ntops;
	int64		n;

	pq_source_open(path, &src, &pf);
	pq_check_row_groups(&pf, path);
	tops = build_imp_targets(tupdesc, &pf, &leaves, &ntops, NULL);
	n = pq_read_rows(&pf, &src, tops, ntops, leaves,
					 slot, sink, sinkarg, NULL, NULL, NULL, NULL, NULL);
	pq_source_close(&src);
	return n;
}

/*
 * columnar.import_parquet(rel regclass, path text) -> bigint
 */
Datum
columnar_import_parquet(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);
	char	   *path = text_to_cstring(PG_GETARG_TEXT_PP(1));
	Relation	rel;
	TupleDesc	tupdesc;
	TupleTableSlot *slot;
	PqInsertSinkArg sinkarg;
	int64		total = 0;
	List	   *files;
	ListCell   *lc;
	MemoryContext fileCtx;

	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("columnar.import_parquet requires superuser (reads a server-side file)")));

	/* resolve the path (file, directory, or glob) before taking the lock */
	files = pq_resolve_paths(path);

	rel = table_open(relid, RowExclusiveLock);
	tupdesc = RelationGetDescr(rel);
	slot = table_slot_create(rel, NULL);

	sinkarg.rel = rel;
	sinkarg.cid = GetCurrentCommandId(true);
	sinkarg.indexes = ColumnarRelationHasIndexes(rel)
		? ColumnarIndexInsertBegin(rel) : NULL;
	/* insert every resolved file's rows; the per-file decode is bounded by
	 * fileCtx. Each file is bound against the target's descriptor, so a directory
	 * whose files disagree with the table errors rather than importing garbage. */
	fileCtx = AllocSetContextCreate(CurrentMemoryContext,
									"pgcolumnar import_parquet file",
									ALLOCSET_DEFAULT_SIZES);
	foreach(lc, files)
	{
		MemoryContext old = MemoryContextSwitchTo(fileCtx);

		total += pq_read_file_into((char *) lfirst(lc), tupdesc, slot,
								   pq_insert_sink, &sinkarg);
		MemoryContextSwitchTo(old);
		MemoryContextReset(fileCtx);
	}
	MemoryContextDelete(fileCtx);

	if (sinkarg.indexes != NULL)
		ColumnarIndexInsertEnd(sinkarg.indexes);

	ExecDropSingleTupleTableSlot(slot);
	table_close(rel, RowExclusiveLock);

	PG_RETURN_INT64(total);
}

/*
 * columnar.read_parquet(path text) returns setof record
 *
 * Stream a server-side Parquet file's rows in place, without importing. The caller
 * supplies a column definition list:
 *
 *   SELECT * FROM pgcolumnar.read_parquet('/data/f.parquet') AS t(id int, name text);
 *
 * The declared descriptor is bound against the file's leaf columns by position,
 * exactly as import binds a target table's descriptor (same type-compatibility
 * rules, same "declared column count must equal the file's" contract), and rows are
 * produced through the shared scan core. Superuser only (reads a server-side file);
 * materialize-mode SRF.
 */
Datum
columnar_read_parquet(PG_FUNCTION_ARGS)
{
	char	   *path = text_to_cstring(PG_GETARG_TEXT_PP(0));
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	retdesc;
	Tuplestorestate *tupstore;
	TupleTableSlot *slot;
	MemoryContext oldContext;
	MemoryContext fileCtx;
	List	   *files;
	ListCell   *lc;

	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("pgcolumnar.read_parquet requires superuser (reads a server-side file)")));

	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo) ||
		!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));

	/* the caller's column definition list defines the output columns and types */
	if (get_call_result_type(fcinfo, NULL, &retdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("pgcolumnar.read_parquet requires a column definition list"),
				 errhint("Call it as SELECT * FROM pgcolumnar.read_parquet(path) AS t(col1 type1, ...).")));

	files = pq_resolve_paths(path);

	oldContext = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);
	retdesc = CreateTupleDescCopy(retdesc);
	tupstore = tuplestore_begin_heap(true, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = retdesc;
	MemoryContextSwitchTo(oldContext);

	slot = MakeSingleTupleTableSlot(retdesc, &TTSOpsVirtual);

	/* read each resolved file into the one tuplestore; the per-file decode is
	 * bounded by fileCtx, reset between files. Every file is bound against the
	 * same declared descriptor, so a mismatched file in a directory errors. */
	fileCtx = AllocSetContextCreate(CurrentMemoryContext,
									"pgcolumnar read_parquet file",
									ALLOCSET_DEFAULT_SIZES);
	foreach(lc, files)
	{
		MemoryContext old = MemoryContextSwitchTo(fileCtx);

		(void) pq_read_file_into((char *) lfirst(lc), retdesc, slot,
								 pq_tuplestore_sink, tupstore);
		MemoryContextSwitchTo(old);
		MemoryContextReset(fileCtx);
	}
	MemoryContextDelete(fileCtx);
	ExecDropSingleTupleTableSlot(slot);

	PG_RETURN_NULL();
}

/*
 * columnar.parquet_schema(path text)
 *     -> table(column_name text, data_type text, nullable bool)
 *
 * Read a server-side Parquet file's footer and report its leaf columns with the
 * PostgreSQL type each maps to (see pq_leaf_to_pgtype). This is the schema half
 * of the external-Parquet scan core: it shares the file open/parse and type
 * inference the data path will use, and lets a caller inspect a file (and the
 * round-trip test confirm exported types) without importing it. A leaf whose
 * physical type has no supported mapping is reported with data_type NULL. Nested
 * files are reported as their flattened leaf columns.
 */
Datum
columnar_parquet_schema(PG_FUNCTION_ARGS)
{
	char	   *path = text_to_cstring(PG_GETARG_TEXT_PP(0));
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	PqSource	src;
	PqFile		pf;
	TupleDesc	retdesc;
	Tuplestorestate *tupstore;
	MemoryContext oldContext;
	int			i;

	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("columnar.parquet_schema requires superuser (reads a server-side file)")));

	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo) ||
		!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));

	/* describe the first resolved file; a directory/glob is assumed uniform */
	path = (char *) linitial(pq_resolve_paths(path));

	/* the schema lives in the footer, so the body is never read */
	pq_source_open(path, &src, &pf);
	pq_source_close(&src);

	retdesc = CreateTemplateTupleDesc(3);
	TupleDescInitEntry(retdesc, 1, "column_name", TEXTOID, -1, 0);
	TupleDescInitEntry(retdesc, 2, "data_type", TEXTOID, -1, 0);
	TupleDescInitEntry(retdesc, 3, "nullable", BOOLOID, -1, 0);

	oldContext = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);
	tupstore = tuplestore_begin_heap(true, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = retdesc;
	MemoryContextSwitchTo(oldContext);

	for (i = 0; i < pf.ncols; i++)
	{
		PqSchemaCol *sc = pf.leaves[i].sc;
		Oid			typid;
		int32		typmod;
		Datum		values[3];
		bool		nulls[3] = {false, false, false};

		values[0] = CStringGetTextDatum(sc->name != NULL ? sc->name : "");
		if (pq_leaf_to_pgtype(sc, &typid, &typmod))
			values[1] = CStringGetTextDatum(
				format_type_extended(typid, typmod, FORMAT_TYPE_TYPEMOD_GIVEN));
		else
			nulls[1] = true;
		/* a column is nullable iff it is OPTIONAL somewhere above the leaf */
		values[2] = BoolGetDatum(pf.leaves[i].max_def > 0);

		tuplestore_putvalues(tupstore, retdesc, values, nulls);
	}

	PG_RETURN_NULL();
}

/* -------------------------------------------------------------------------
 * Parquet foreign-data wrapper (Phase G). A foreign table over a single Parquet
 * file: its column definitions are bound against the file's leaves exactly as
 * read_parquet's column list is, and rows are produced through the same scan
 * core. Read-only, superuser (reads a server-side file). The single required
 * table option is "path". Projection and predicate pushdown are a follow-on; this
 * surface returns full rows and lets the executor project and filter.
 *
 *   CREATE SERVER pq FOREIGN DATA WRAPPER pgcolumnar_parquet;
 *   CREATE FOREIGN TABLE ft (id int, name text) SERVER pq
 *       OPTIONS (path '/data/f.parquet');
 * ------------------------------------------------------------------------- */

/* per-scan state: the whole file materialized into a tuplestore, drained by
 * IterateForeignScan. Eager (reads the file up front); streaming is a follow-on.
 * readslot is a minimal-tuple slot the tuplestore drains into; each row is then
 * copied into the scan slot, whose ops are not guaranteed to be minimal-tuple. */
typedef struct PqFdwScanState
{
	Tuplestorestate *tupstore;
	TupleTableSlot *readslot;
	int			groupsTotal;	/* row groups across all files */
	int			groupsSkipped;	/* skipped by predicate pushdown */
	int			colsTotal;		/* top-level columns (same across files) */
	int			colsRead;		/* decoded after projection pushdown */
	int			filesRead;		/* files the path resolved to, after pruning */
	int			filesPruned;	/* dropped by a partition predicate, never opened */
}			PqFdwScanState;

/* a named option of a foreign table, or NULL if unset */
static char *
pqfdw_get_option(Oid foreigntableid, const char *name)
{
	ForeignTable *ft = GetForeignTable(foreigntableid);
	ListCell   *lc;

	foreach(lc, ft->options)
	{
		DefElem    *def = (DefElem *) lfirst(lc);

		if (strcmp(def->defname, name) == 0)
			return defGetString(def);
	}
	return NULL;
}

static char *
pqfdw_get_path(Oid foreigntableid)
{
	return pqfdw_get_option(foreigntableid, "path");
}

/*
 * Hive-style partitioning: a path like /data/events/dt=2026-01-01/region=eu/f.parquet
 * carries column values in its directory names. The columns are DECLARED, through
 * the partition_columns table option, rather than inferred from the tree. Inference
 * would mean guessing which components are partitions, and a wrong guess silently
 * changes which rows a query returns, the same reason read_parquet requires a
 * column definition list instead of inferring one.
 *
 * Returns a natts-sized mask of which attributes are partition columns, and NULL
 * when the option is unset. Unknown names are an error: a typo must not silently
 * degrade into "no partitioning".
 */
static bool *
pqfdw_partition_mask(Oid foreigntableid, TupleDesc tupdesc, int *ncols)
{
	char	   *raw = pqfdw_get_option(foreigntableid, "partition_columns");
	List	   *names = NIL;
	ListCell   *lc;
	bool	   *mask;

	*ncols = 0;
	if (raw == NULL)
		return NULL;

	if (!SplitIdentifierString(pstrdup(raw), ',', &names))
		ereport(ERROR,
				(errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
				 errmsg("\"partition_columns\" is not a valid comma-separated column list")));

	mask = (bool *) palloc0(sizeof(bool) * Max(tupdesc->natts, 1));
	foreach(lc, names)
	{
		char	   *nm = (char *) lfirst(lc);
		int			i;
		bool		found = false;

		for (i = 0; i < tupdesc->natts; i++)
		{
			Form_pg_attribute att = TupleDescAttr(tupdesc, i);

			if (att->attisdropped)
				continue;
			if (strcmp(NameStr(att->attname), nm) == 0)
			{
				if (mask[i])
					ereport(ERROR,
							(errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
							 errmsg("column \"%s\" is listed twice in \"partition_columns\"",
									nm)));
				mask[i] = true;
				(*ncols)++;
				found = true;
				break;
			}
		}
		if (!found)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_COLUMN),
					 errmsg("column \"%s\" named in \"partition_columns\" does not exist",
							nm)));
	}
	if (*ncols == 0)
		ereport(ERROR,
				(errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
				 errmsg("\"partition_columns\" cannot be empty")));
	return mask;
}

/*
 * The marker Hive and Spark write for a null partition value. A directory named
 * dt=__HIVE_DEFAULT_PARTITION__ means the column is null for those rows, not that
 * it holds that string, and every reader in this ecosystem treats it that way.
 */
#define PQ_HIVE_NULL_PARTITION "__HIVE_DEFAULT_PARTITION__"

/*
 * Percent-decode a partition value.
 *
 * A path component cannot contain a slash, and an equals sign in a value would be
 * ambiguous against the key separator, so writers percent-encode those and any
 * character they consider unsafe. Decoding is therefore part of reading the value,
 * not a nicety: a value written as a%3Db is the string "a=b", and reading it
 * literally gives a different value with no error.
 *
 * Only a well-formed %XX with two hex digits is decoded. A stray percent is left
 * alone rather than treated as an error, because a value that legitimately
 * contains one and was written by something that does not encode is more likely
 * than a corrupt path.
 *
 * Two things the decoding itself must refuse, because percent-encoding can carry
 * any byte and the value ends up in a PostgreSQL text datum:
 *
 * - An embedded NUL. Everything downstream is a C string, so %00 would truncate
 *   the value silently; for a typed column the short text usually fails to parse,
 *   but for text or varchar it lands as a quietly different value. The explicit
 *   check below is for the diagnosis, not the detection: pg_verifymbstr also
 *   rejects an embedded NUL, verified by removing this check and watching the
 *   same file fail with "invalid byte sequence for encoding UTF8: 0x00". This
 *   message names the file and says what is wrong with it, so it is kept, but no
 *   test can isolate it from the encoding check and none claims to.
 * - A byte sequence invalid in the server encoding. textin does not validate
 *   encoding, so %FF in a UTF-8 database would admit invalid text that then flows
 *   into result sets, comparisons and indexes. PostgreSQL validates
 *   externally-sourced text at the boundary for this reason, which is what COPY
 *   does with pg_verifymbstr, and this is the same boundary.
 *
 * The hex tests are ASCII-only rather than the ctype macros, whose behaviour is
 * locale-dependent in principle.
 */
static inline bool
pq_is_hex(char c)
{
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
		(c >= 'A' && c <= 'F');
}

static inline int
pq_hex_val(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return c - 'A' + 10;
}

static char *
pq_percent_decode(const char *src, const char *file)
{
	char	   *out = palloc(strlen(src) + 1);
	const char *in = src;
	char	   *o = out;

	while (*in != '\0')
	{
		if (in[0] == '%' && pq_is_hex(in[1]) && pq_is_hex(in[2]))
		{
			int			b = (pq_hex_val(in[1]) << 4) | pq_hex_val(in[2]);

			if (b == 0)
				ereport(ERROR,
						(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
						 errmsg("partition value in \"%s\" contains an encoded null byte",
								file)));
			*o++ = (char) b;
			in += 3;
		}
		else
			*o++ = *in++;
	}
	*o = '\0';

	/* the same check COPY makes on text arriving from outside the server */
	pg_verifymbstr(out, o - out, false);
	return out;
}

/*
 * Read one file's partition values out of its path.
 *
 * Every declared partition column must appear as a `name=value` directory
 * component, and a file that is missing one is an error rather than a null: a
 * tree that does not match what the table declares is a mistake worth reporting,
 * not rows with holes in them. Values are converted with the column's own input
 * function, so the declared type decides what a directory name means, and a value
 * that will not convert raises through the normal input-function error.
 *
 * The value text is taken literally. Hive percent-encodes characters that cannot
 * appear in a path component, and that decoding is deliberately not done here;
 * see the limitation in the docs.
 */
static void
pqfdw_partition_values(const char *root, const char *file, TupleDesc tupdesc,
					   const bool *partMask, Datum *vals, bool *have,
					   bool *isnull)
{
	size_t		rootlen = strlen(root);
	const char *rel = file;
	char	   *work;
	char	   *base;
	char	   *comp;
	char	   *save = NULL;
	int			i;

	/*
	 * Only the directory components between the declared root and the file are
	 * partition components. Scanning the whole absolute path would let a
	 * component above the root decide a column (a root under /exports/region=eu
	 * would set "region" for every file), and would let a file literally named
	 * dt=2026-01-02.parquet set "dt" from its own basename.
	 */
	if (strncmp(file, root, rootlen) == 0)
		rel = file + rootlen;
	work = pstrdup(rel);
	base = strrchr(work, '/');
	if (base != NULL)
		*base = '\0';			/* drop the file name itself */
	else
		*work = '\0';			/* the file sits directly in the root */

	for (i = 0; i < tupdesc->natts; i++)
	{
		have[i] = false;
		isnull[i] = false;
	}

	for (comp = strtok_r(work, "/", &save); comp != NULL;
		 comp = strtok_r(NULL, "/", &save))
	{
		char	   *eq = strchr(comp, '=');
		char	   *key;

		if (eq == NULL || eq == comp)
			continue;
		key = pnstrdup(comp, eq - comp);

		for (i = 0; i < tupdesc->natts; i++)
		{
			Form_pg_attribute att = TupleDescAttr(tupdesc, i);

			if (!partMask[i] || att->attisdropped)
				continue;
			if (strcmp(NameStr(att->attname), key) != 0)
				continue;
			{
				char	   *text = pq_percent_decode(eq + 1, file);

				/*
				 * The null marker is checked after decoding, so a value that
				 * spells it out through escapes is treated the same way a writer
				 * that emitted it plainly would be.
				 */
				if (strcmp(text, PQ_HIVE_NULL_PARTITION) == 0)
				{
					vals[i] = (Datum) 0;
					isnull[i] = true;
				}
				else
				{
					Oid			infunc;
					Oid			ioparam;

					getTypeInputInfo(att->atttypid, &infunc, &ioparam);
					vals[i] = OidInputFunctionCall(infunc, text, ioparam,
												   att->atttypmod);
					isnull[i] = false;
				}
				have[i] = true;
			}
			break;
		}
	}

	for (i = 0; i < tupdesc->natts; i++)
	{
		if (partMask[i] && !have[i])
			ereport(ERROR,
					(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
					 errmsg("file \"%s\" has no \"%s=\" directory component",
							file, NameStr(TupleDescAttr(tupdesc, i)->attname)),
					 errhint("Every file under a partitioned path must carry a directory component for each column in \"partition_columns\".")));
	}
}

/*
 * Compile the quals that a file's partition values alone can decide.
 *
 * Done once for the scan, not once per file, for two reasons. It is the same
 * expression every time, so recompiling per file is pure waste on a tree with
 * many partitions. And ExecInitQual on a clause containing a SubPlan appends a
 * SubPlanState to node->ss.ps.subPlan, which ExecEndNode walks at the end of the
 * scan: compiled inside the per-file context, that list cell is freed by the
 * reset at the bottom of the same iteration and read again much later. A
 * partition-only clause can contain a SubPlan (`dt IN (SELECT ...)` leaves
 * `dt = ANY (SubPlan 1)`, whose only Var is dt), so this is reachable, not
 * theoretical.
 *
 * A clause qualifies when every Var it reads is a partition column AND it holds
 * no volatile function. The Var test alone is not enough: pull_varattnos says
 * nothing about volatility, so `dt = X OR random() < 0.5` would qualify, and
 * deciding it once for a whole file is not the same as deciding it per row. One
 * draw would then keep or drop every row of the file, silently returning fewer
 * rows than the query asks for. Stable and immutable stay eligible; stable is
 * constant within a statement, which is exactly the guarantee this needs.
 */
static List *
pqfdw_partition_quals(ForeignScanState *node, TupleDesc tupdesc,
					  const bool *partMask)
{
	ForeignScan *fs = (ForeignScan *) node->ss.ps.plan;
	List	   *compiled = NIL;
	ListCell   *lc;

	foreach(lc, fs->scan.plan.qual)
	{
		Node	   *clause = (Node *) lfirst(lc);
		Bitmapset  *attrs = NULL;
		bool		partitionOnly = true;
		int			x = -1;

		pull_varattnos(clause, fs->scan.scanrelid, &attrs);
		if (bms_is_empty(attrs))
			continue;			/* no columns at all: not ours to decide */
		while ((x = bms_next_member(attrs, x)) >= 0)
		{
			int			attno = x + FirstLowInvalidHeapAttributeNumber;

			/* whole-row or system column: cannot be decided from the path */
			if (attno < 1 || attno > tupdesc->natts || !partMask[attno - 1])
			{
				partitionOnly = false;
				break;
			}
		}
		if (!partitionOnly)
			continue;
		if (contain_volatile_functions(clause))
			continue;			/* not decidable once per file */

		compiled = lappend(compiled, ExecInitQual(list_make1(clause),
												 (PlanState *) node));
	}
	return compiled;
}

/*
 * Whether the compiled partition quals exclude this file outright.
 *
 * Pruning happens before the file is opened, so a pruned file costs no I/O at
 * all, and its row groups never reach the EXPLAIN counters.
 *
 * Params are not a hazard here, though ExecQual would happily read one: the
 * wrapper advertises no parameterized path (see pqfdwGetForeignPaths), so a
 * rescan cannot arrive with different parameter values, which is the same
 * assumption pqfdw_compute_skip already documents for the row-group skip mask.
 * If a parameterized path is ever added, both become recompute-per-rescan.
 */
static bool
pqfdw_partition_excludes_file(ForeignScanState *node, TupleTableSlot *slot,
							  List *partQuals, TupleDesc tupdesc,
							  Datum *vals, bool *have, const bool *isnull)
{
	ExprContext *econtext = node->ss.ps.ps_ExprContext;
	ListCell   *lc;
	int			i;

	if (partQuals == NIL)
		return false;

	ExecClearTuple(slot);
	for (i = 0; i < tupdesc->natts; i++)
	{
		slot->tts_values[i] = (have[i] && !isnull[i]) ? vals[i] : (Datum) 0;
		slot->tts_isnull[i] = !have[i] || isnull[i];
	}
	ExecStoreVirtualTuple(slot);

	econtext->ecxt_scantuple = slot;
	foreach(lc, partQuals)
	{
		if (!ExecQual((ExprState *) lfirst(lc), econtext))
			return true;
	}
	return false;
}

static void
pqfdwGetForeignRelSize(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid)
{
	char	   *path = pqfdw_get_path(foreigntableid);
	struct stat st;
	double		rows = 1000.0;

	/*
	 * Estimate row count from the file size without reading it: a generic
	 * bytes-per-row divisor. Only a planning ballpark; the executor reads the
	 * real rows. The stat() is gated on superuser -- the same bar the scan
	 * enforces -- so a non-privileged planner cannot use the EXPLAIN estimate to
	 * probe whether a server-side path exists or how big it is.
	 */
	if (superuser() && path != NULL && stat(path, &st) == 0 && st.st_size > 0)
		rows = Max(1.0, (double) st.st_size / 64.0);
	baserel->rows = rows;
}

static void
pqfdwGetForeignPaths(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid)
{
	Cost		startup_cost = 0;
	Cost		total_cost = baserel->rows;

	add_path(baserel, (Path *)
			 COLUMNAR_CREATE_FOREIGNSCAN_PATH(root, baserel,
											  NULL, /* default pathtarget */
											  baserel->rows,
											  startup_cost, total_cost,
											  NIL,	/* no pathkeys */
											  NULL, /* no outer rel */
											  NULL, /* no extra plan */
											  NIL));
}

static ForeignScan *
pqfdwGetForeignPlan(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid,
					ForeignPath *best_path, List *tlist, List *scan_clauses,
					Plan *outer_plan)
{
	Bitmapset  *attrs = NULL;
	List	   *needed = NIL;
	int			x = -1;

	/*
	 * Clause evaluation stays with the executor; pushdown here is row-group
	 * skipping only (see pqfdw_compute_skip), so every clause is still recheckable
	 * and must remain in the plan's qual.
	 */
	scan_clauses = extract_actual_clauses(scan_clauses, false);

	/*
	 * Projection pushdown: record which columns the scan actually needs -- the
	 * ones its output target references plus the ones its local quals read. This
	 * is computed here, not at execution time, because the executor may hand the
	 * scan a physical (all-column) target list; reltarget is the true minimal set,
	 * empty for count(*). The attnos travel to BeginForeignScan as fdw_private.
	 */
	pull_varattnos((Node *) baserel->reltarget->exprs, baserel->relid, &attrs);
	pull_varattnos((Node *) scan_clauses, baserel->relid, &attrs);
	while ((x = bms_next_member(attrs, x)) >= 0)
		needed = lappend_int(needed,
							 (int) (x + FirstLowInvalidHeapAttributeNumber));

	return make_foreignscan(tlist, scan_clauses, baserel->relid,
							NIL, needed, NIL, NIL, outer_plan);
}

/* the top (target column) bound to attribute attno0, or NULL */
static ImpTop *
pqfdw_top_for_attno(ImpTop *tops, int ntops, int attno0)
{
	int			t;

	for (t = 0; t < ntops; t++)
		if (tops[t].attno == attno0)
			return &tops[t];
	return NULL;
}

/*
 * Decide whether a single row group can be skipped for the qual `col op const`
 * (with the Var on varLeft). Conservative: returns true only when the group's
 * min/max prove no row can match. Anything uncertain -- missing stats, an
 * unsupported physical type, a mismatched constant type, a non-btree operator --
 * returns false (do not skip). Restricted to fixed-width ordered physical types,
 * whose statistics decode unambiguously.
 */
static bool
pqfdw_clause_excludes_group(ImpLeaf *leaf, PqChunk *ch, int strategy,
							bool varLeft, Const *con)
{
	TypeCacheEntry *tce;
	const uint8 *p;
	bool		ok;
	Datum		minD;
	Datum		maxD;
	int			phys = leaf->plan.expect_phys;

	if (!ch->has_min || !ch->has_max)
		return false;
	/* only fixed-width ordered stats decode without ambiguity */
	if (phys != PQ_INT32 && phys != PQ_INT64 &&
		phys != PQ_FLOAT && phys != PQ_DOUBLE)
		return false;
	if (con->consttype != leaf->plan.typid || con->constisnull)
		return false;

	tce = lookup_type_cache(leaf->plan.typid, TYPECACHE_CMP_PROC_FINFO);
	if (!OidIsValid(tce->cmp_proc_finfo.fn_oid))
		return false;

	p = ch->stat_min;
	minD = plain_value_to_datum(&leaf->plan, &p, p + ch->stat_min_len, false, &ok);
	if (!ok)
		return false;
	p = ch->stat_max;
	maxD = plain_value_to_datum(&leaf->plan, &p, p + ch->stat_max_len, false, &ok);
	if (!ok)
		return false;

#define PQ_CMP(a, b) \
	DatumGetInt32(FunctionCall2Coll(&tce->cmp_proc_finfo, InvalidOid, (a), (b)))

	/*
	 * Every test below assumes min <= max, and the decoded statistics may not
	 * satisfy that. plain_value_to_datum() narrows a Parquet INT32 to int16 when
	 * the column is bound to a PG int2, so a group holding 30000 and 40000
	 * decodes to min=30000, max=-25536. Parquet's UINT_32/UINT_64 logical types
	 * sort unsigned while we decode signed, so any group straddling the sign
	 * boundary inverts the same way, as can a corrupt file. Refuse to skip on an
	 * interval we cannot trust: the data path applies the identical narrowing, so
	 * those rows are real matches and dropping them would be an unsound skip that
	 * the executor's recheck can never recover.
	 */
	if (PQ_CMP(minD, maxD) > 0)
		return false;

	/* normalize `const op var` to `var op' const` by flipping the strategy */
	if (!varLeft)
	{
		switch (strategy)
		{
			case BTLessStrategyNumber:
				strategy = BTGreaterStrategyNumber;
				break;
			case BTLessEqualStrategyNumber:
				strategy = BTGreaterEqualStrategyNumber;
				break;
			case BTGreaterStrategyNumber:
				strategy = BTLessStrategyNumber;
				break;
			case BTGreaterEqualStrategyNumber:
				strategy = BTLessEqualStrategyNumber;
				break;
				/* BTEqual is symmetric */
		}
	}

	/*
	 * Float and double statistics do not describe NaN. parquet.thrift's
	 * TypeDefinedOrder compatibility rules exclude NaN from min/max, and require
	 * that a NaN-valued min or max be ignored outright. PostgreSQL instead orders
	 * NaN above every other value and treats NaN = NaN as true, so a group that
	 * holds a NaN advertises finite bounds while its NaN row still satisfies
	 * col > c, col >= c and col = 'NaN'. Skipping on those would drop rows that
	 * never reach the executor's recheck, so refuse them. col < c and col <= c
	 * stay sound, because a NaN row cannot satisfy those either.
	 *
	 * The +/-0 clauses in the same spec block need no handling: PostgreSQL
	 * compares -0 and +0 as equal, which is exactly what those rules require.
	 */
	if (phys == PQ_FLOAT || phys == PQ_DOUBLE)
	{
		float8		lo = (phys == PQ_FLOAT)
			? (float8) DatumGetFloat4(minD) : DatumGetFloat8(minD);
		float8		hi = (phys == PQ_FLOAT)
			? (float8) DatumGetFloat4(maxD) : DatumGetFloat8(maxD);
		float8		c = (phys == PQ_FLOAT)
			? (float8) DatumGetFloat4(con->constvalue)
			: DatumGetFloat8(con->constvalue);

		if (isnan(lo) || isnan(hi))
			return false;
		if (strategy == BTGreaterStrategyNumber ||
			strategy == BTGreaterEqualStrategyNumber)
			return false;
		if (strategy == BTEqualStrategyNumber && isnan(c))
			return false;
	}

	switch (strategy)
	{
		case BTLessStrategyNumber:	/* col < const: skip if min >= const */
			return PQ_CMP(minD, con->constvalue) >= 0;
		case BTLessEqualStrategyNumber: /* col <= const: skip if min > const */
			return PQ_CMP(minD, con->constvalue) > 0;
		case BTEqualStrategyNumber: /* col = const: skip if const outside [min,max] */
			return PQ_CMP(con->constvalue, minD) < 0 ||
				PQ_CMP(con->constvalue, maxD) > 0;
		case BTGreaterEqualStrategyNumber:	/* col >= const: skip if max < const */
			return PQ_CMP(maxD, con->constvalue) < 0;
		case BTGreaterStrategyNumber:	/* col > const: skip if max <= const */
			return PQ_CMP(maxD, con->constvalue) <= 0;
		default:
			return false;
	}
#undef PQ_CMP
}

/*
 * Compute the per-row-group skip mask from the scan's restriction clauses and the
 * file's statistics. skipGroup[rg] becomes true when some pushable `col op const`
 * clause proves the group empty. Returns the number of groups marked skippable.
 *
 * Only Const operands are pushable, so the mask cannot change between rescans;
 * that is what lets BeginForeignScan compute it once and ReScanForeignScan merely
 * rewind. Adding Param support would invalidate that and require recomputing the
 * mask (and re-reading the file) on each rescan.
 *
 * leaves[] and rgs[rg].chunks[] are both indexed by top->firstLeaf. That is valid
 * because build_imp_targets() binds leaves strictly positionally against
 * pf->leaves[] and errors unless it consumes exactly pf->ncols of them, which is
 * the same identity pq_read_rows() already relies on.
 */
static int
pqfdw_compute_skip(ForeignScanState *node, PqFile *pf,
				   ImpTop *tops, int ntops, ImpLeaf *leaves, bool *skipGroup)
{
	ForeignScan *fs = (ForeignScan *) node->ss.ps.plan;
	List	   *quals = fs->scan.plan.qual;
	int			skipped = 0;
	int			rg;

	for (rg = 0; rg < pf->nrowgroups; rg++)
	{
		ListCell   *lc;

		skipGroup[rg] = false;
		foreach(lc, quals)
		{
			OpExpr	   *op = (OpExpr *) lfirst(lc);
			Node	   *larg;
			Node	   *rarg;
			Var		   *var;
			Const	   *con;
			bool		varLeft;
			ImpTop	   *top;
			List	   *interp;
			ListCell   *ic;
			int			strategy = 0;

			if (!IsA(op, OpExpr) || list_length(op->args) != 2)
				continue;
			larg = (Node *) linitial(op->args);
			rarg = (Node *) lsecond(op->args);
			if (IsA(larg, Var) && IsA(rarg, Const))
			{
				var = (Var *) larg;
				con = (Const *) rarg;
				varLeft = true;
			}
			else if (IsA(larg, Const) && IsA(rarg, Var))
			{
				var = (Var *) rarg;
				con = (Const *) larg;
				varLeft = false;
			}
			else
				continue;
			if (var->varattno < 1)
				continue;

			top = pqfdw_top_for_attno(tops, ntops, var->varattno - 1);
			if (top == NULL || top->kind != IMP_SCALAR)
				continue;

			/*
			 * First btree comparison interpretation gives the strategy. Any
			 * btree family will do: a given operator means the same comparison
			 * in every family that lists it.
			 */
			interp = ColumnarGetOpInterpretation(op->opno);
			foreach(ic, interp)
			{
				ColumnarOpInterpretation *o = (ColumnarOpInterpretation *) lfirst(ic);
				int			s = ColumnarOpInterpStrategy(o);

				if (s >= BTLessStrategyNumber && s <= BTGreaterStrategyNumber)
				{
					strategy = s;
					break;
				}
			}
			if (strategy == 0)
				continue;

			if (pqfdw_clause_excludes_group(&leaves[top->firstLeaf],
											&pf->rgs[rg].chunks[top->firstLeaf],
											strategy, varLeft, con))
			{
				skipGroup[rg] = true;
				break;
			}
		}
		if (skipGroup[rg])
			skipped++;
	}
	return skipped;
}

/*
 * Turn the plan-time needed-attribute list (fdw_private, built in GetForeignPlan)
 * into a per-top bool array for pq_read_rows. A column not in the list is left
 * false and never decoded. A whole-row reference (attno 0) forces every column,
 * and a scan that needs nothing (count(*)) decodes nothing.
 */
static bool *
pqfdw_compute_needed(ForeignScanState *node, ImpTop *tops, int ntops,
					 int *nNeeded)
{
	ForeignScan *fs = (ForeignScan *) node->ss.ps.plan;
	List	   *needed = (List *) fs->fdw_private;
	bool	   *needTop = (bool *) palloc0(sizeof(bool) * Max(ntops, 1));
	bool		wholeRow = list_member_int(needed, 0);
	int			t;
	int			cnt = 0;

	for (t = 0; t < ntops; t++)
	{
		if (wholeRow || list_member_int(needed, tops[t].attno + 1))
		{
			needTop[t] = true;
			cnt++;
		}
	}
	*nNeeded = cnt;
	return needTop;
}

static void
pqfdwBeginForeignScan(ForeignScanState *node, int eflags)
{
	Relation	rel = node->ss.ss_currentRelation;
	TupleDesc	tupdesc = RelationGetDescr(rel);
	char	   *path;
	TupleTableSlot *slot;
	PqFdwScanState *st;
	bool	   *needTop;
	int			nNeeded;
	List	   *files;
	ListCell   *lc;
	MemoryContext fileCtx;
	bool	   *partMask;
	int			nPart;
	Datum	   *partVals = NULL;
	bool	   *partHas = NULL;
	bool	   *partNull = NULL;
	List	   *partQuals = NIL;
	TupleTableSlot *partSlot = NULL;

	/* nothing to do for a plan-only (EXPLAIN without ANALYZE) invocation */
	if (eflags & EXEC_FLAG_EXPLAIN_ONLY)
		return;

	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("pgcolumnar_parquet foreign tables require superuser (read a server-side file)")));

	path = pqfdw_get_path(RelationGetRelid(rel));
	if (path == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_FDW_OPTION_NAME_NOT_FOUND),
				 errmsg("foreign table \"%s\" has no \"path\" option",
						RelationGetRelationName(rel))));

	files = pq_resolve_paths(path);
	partMask = pqfdw_partition_mask(RelationGetRelid(rel), tupdesc, &nPart);
	if (partMask != NULL)
	{
		/* compiled once, in the scan's own context, and reused for every file */
		partQuals = pqfdw_partition_quals(node, tupdesc, partMask);
		partSlot = MakeSingleTupleTableSlot(tupdesc, &TTSOpsVirtual);
	}

	st = (PqFdwScanState *) palloc0(sizeof(PqFdwScanState));
	/* randomAccess so ReScan can rewind the materialized rows */
	st->tupstore = tuplestore_begin_heap(true, false, work_mem);
	st->readslot = MakeSingleTupleTableSlot(tupdesc, &TTSOpsMinimalTuple);

	slot = MakeSingleTupleTableSlot(tupdesc, &TTSOpsVirtual);

	/*
	 * Read each resolved file into the one tuplestore. Predicate pushdown is per
	 * file (each file's own row-group statistics); projection is query-derived and
	 * identical across files, since every file shares the target descriptor. The
	 * EXPLAIN counters sum row groups across files while the column counts are the
	 * same each file. The per-file decode is bounded by fileCtx.
	 */
	fileCtx = AllocSetContextCreate(CurrentMemoryContext,
									"pgcolumnar parquet fdw file",
									ALLOCSET_DEFAULT_SIZES);
	foreach(lc, files)
	{
		MemoryContext old = MemoryContextSwitchTo(fileCtx);
		PqSource	src;
		PqFile		pf;
		ImpTop	   *tops;
		ImpLeaf    *leaves;
		int			ntops;
		bool	   *skipGroup;

		/*
		 * Partition pruning, before the file is opened: a file whose directory
		 * values fail a partition-only qual costs no I/O at all, which is what
		 * makes this cheaper than row-group skipping rather than a variant of it.
		 */
		if (partMask != NULL)
		{
			partVals = (Datum *) palloc0(sizeof(Datum) * Max(tupdesc->natts, 1));
			partHas = (bool *) palloc0(sizeof(bool) * Max(tupdesc->natts, 1));
			partNull = (bool *) palloc0(sizeof(bool) * Max(tupdesc->natts, 1));
			pqfdw_partition_values(path, (char *) lfirst(lc), tupdesc, partMask,
								   partVals, partHas, partNull);
			if (pqfdw_partition_excludes_file(node, partSlot, partQuals, tupdesc,
											  partVals, partHas, partNull))
			{
				st->filesPruned++;
				MemoryContextSwitchTo(old);
				MemoryContextReset(fileCtx);
				continue;
			}
		}

		st->filesRead++;
		pq_source_open((char *) lfirst(lc), &src, &pf);
		pq_check_row_groups(&pf, (char *) lfirst(lc));
		tops = build_imp_targets(tupdesc, &pf, &leaves, &ntops, partMask);

		/* projection: decode only referenced columns (same set each file) */
		needTop = pqfdw_compute_needed(node, tops, ntops, &nNeeded);
		st->colsTotal = ntops;
		st->colsRead = nNeeded;

		st->groupsTotal += pf.nrowgroups;
		skipGroup = (bool *) palloc0(sizeof(bool) * Max(pf.nrowgroups, 1));
		st->groupsSkipped += pqfdw_compute_skip(node, &pf, tops, ntops,
												leaves, skipGroup);

		(void) pq_read_rows(&pf, &src, tops, ntops, leaves,
							slot, pq_tuplestore_sink, st->tupstore, skipGroup,
							needTop, partVals, partHas, partNull);
		pq_source_close(&src);

		MemoryContextSwitchTo(old);
		MemoryContextReset(fileCtx);
	}
	MemoryContextDelete(fileCtx);
	ExecDropSingleTupleTableSlot(slot);
	if (partSlot != NULL)
		ExecDropSingleTupleTableSlot(partSlot);

	node->fdw_state = st;
}

static TupleTableSlot *
pqfdwIterateForeignScan(ForeignScanState *node)
{
	PqFdwScanState *st = (PqFdwScanState *) node->fdw_state;
	TupleTableSlot *slot = node->ss.ss_ScanTupleSlot;
	MemoryContext oldcxt;
	bool		got;

	if (st == NULL)
		return ExecClearTuple(slot);

	/*
	 * Drain one row into our minimal-tuple readslot, then copy it into the scan
	 * slot (a heap-tuple slot: table_slot_callbacks() hands foreign tables
	 * TTSOpsHeapTuple, which cannot receive a minimal tuple directly).
	 *
	 * The fetch must run in a context that outlives the row. ForeignNext() calls
	 * us in ecxt_per_tuple_memory, and ExecScan resets that before every fetch --
	 * including the no-qual fast path. Whenever tuplestore_gettupleslot hands the
	 * slot a palloc'd tuple it also hands over ownership (TTS_FLAG_SHOULDFREE),
	 * and the slot frees it on its next store. Allocated in the per-tuple context
	 * that pointer is already reclaimed by then, so the next store frees wiped
	 * memory and corrupts the allocator. That happens for a spilled tuplestore
	 * even with copy=false (readtup palloc's and sets should_free), so pin the
	 * context rather than the copy flag.
	 */
	oldcxt = MemoryContextSwitchTo(node->ss.ps.state->es_query_cxt);
	got = tuplestore_gettupleslot(st->tupstore, true, false, st->readslot);
	MemoryContextSwitchTo(oldcxt);

	if (!got)
		return ExecClearTuple(slot);
	return ExecCopySlot(slot, st->readslot);
}

static void
pqfdwReScanForeignScan(ForeignScanState *node)
{
	PqFdwScanState *st = (PqFdwScanState *) node->fdw_state;

	if (st != NULL && st->tupstore != NULL)
		tuplestore_rescan(st->tupstore);
}

static void
pqfdwEndForeignScan(ForeignScanState *node)
{
	PqFdwScanState *st = (PqFdwScanState *) node->fdw_state;

	if (st == NULL)
		return;

	/* drop the slot first: a non-copied fetch leaves it pointing into the
	 * tuplestore's own memory, which tuplestore_end() releases */
	if (st->readslot != NULL)
	{
		ExecDropSingleTupleTableSlot(st->readslot);
		st->readslot = NULL;
	}
	if (st->tupstore != NULL)
	{
		tuplestore_end(st->tupstore);
		st->tupstore = NULL;
	}
}

static void
pqfdwExplainForeignScan(ForeignScanState *node, ExplainState *es)
{
	PqFdwScanState *st = (PqFdwScanState *) node->fdw_state;

	/* only populated once the scan has begun (EXPLAIN ANALYZE) */
	if (st == NULL)
		return;
	ExplainPropertyInteger("Row Groups", NULL, st->groupsTotal, es);
	ExplainPropertyInteger("Row Groups Skipped", NULL, st->groupsSkipped, es);
	ExplainPropertyInteger("Columns Read", NULL, st->colsRead, es);
	ExplainPropertyInteger("Columns Total", NULL, st->colsTotal, es);
	ExplainPropertyInteger("Files", NULL, st->filesRead, es);
	if (st->filesPruned > 0)
		ExplainPropertyInteger("Files Pruned", NULL, st->filesPruned, es);
}

Datum
pgcolumnar_parquet_fdw_handler(PG_FUNCTION_ARGS)
{
	FdwRoutine *r = makeNode(FdwRoutine);

	r->GetForeignRelSize = pqfdwGetForeignRelSize;
	r->GetForeignPaths = pqfdwGetForeignPaths;
	r->GetForeignPlan = pqfdwGetForeignPlan;
	r->BeginForeignScan = pqfdwBeginForeignScan;
	r->IterateForeignScan = pqfdwIterateForeignScan;
	r->ReScanForeignScan = pqfdwReScanForeignScan;
	r->ExplainForeignScan = pqfdwExplainForeignScan;
	r->EndForeignScan = pqfdwEndForeignScan;

	PG_RETURN_POINTER(r);
}

/*
 * Option validator: the only accepted option is "path" on a foreign table. Server,
 * wrapper, and user-mapping objects take no options.
 */
Datum
pgcolumnar_parquet_fdw_validator(PG_FUNCTION_ARGS)
{
	List	   *options = untransformRelOptions(PG_GETARG_DATUM(0));
	Oid			catalog = PG_GETARG_OID(1);
	ListCell   *lc;

	foreach(lc, options)
	{
		DefElem    *def = (DefElem *) lfirst(lc);

		if (catalog == ForeignTableRelationId && strcmp(def->defname, "path") == 0)
		{
			if (defGetString(def)[0] == '\0')
				ereport(ERROR,
						(errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
						 errmsg("\"path\" option cannot be empty")));
		}
		else if (catalog == ForeignTableRelationId &&
				 strcmp(def->defname, "partition_columns") == 0)
		{
			List	   *names = NIL;

			if (defGetString(def)[0] == '\0')
				ereport(ERROR,
						(errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
						 errmsg("\"partition_columns\" option cannot be empty")));
			if (!SplitIdentifierString(pstrdup(defGetString(def)), ',', &names) ||
				names == NIL)
				ereport(ERROR,
						(errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
						 errmsg("\"partition_columns\" is not a valid comma-separated column list")));
		}
		else
			ereport(ERROR,
					(errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
					 errmsg("invalid option \"%s\"", def->defname),
					 errhint("The pgcolumnar_parquet wrapper accepts the foreign-table options \"path\" and \"partition_columns\".")));
	}

	PG_RETURN_VOID();
}
