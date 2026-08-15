/*-------------------------------------------------------------------------
 *
 * columnar_avro.h
 *		A targeted Avro object-container-file reader for Iceberg manifests
 *		(#388 step 1). Not a general Avro implementation: it reads the subset
 *		Iceberg manifests use, decoding against the schema embedded in the file
 *		(avro.schema) so a v3 manifest reads structurally rather than as garbage.
 *
 * Written fresh for pgColumnar from the public Apache Avro specification.
 *
 *-------------------------------------------------------------------------
 */
#ifndef COLUMNAR_AVRO_H
#define COLUMNAR_AVRO_H

#include "postgres.h"

/*
 * One typed cell of a data file's partition tuple, captured for exact-equality
 * comparison (partition-scoped equality deletes, #388 phase 5). The value is
 * either an integer (int/long/boolean/date/time/timestamp, all compared as
 * int64) or raw bytes (string/binary), or null. A cell of a kind the reader
 * cannot compare for exact equality (float/double/fixed/other) is marked not
 * comparable, so the caller refuses rather than guesses.
 */
typedef struct PgColumnarAvroPartCell
{
	bool		isnull;
	bool		is_bytes;		/* true: bytes value; false: integer value */
	bool		comparable;		/* false for float/double/unhandled kinds */
	int64		ival;
	char	   *bytes;
	int			blen;
} PgColumnarAvroPartCell;

/*
 * One decoded manifest_entry, projected to the fields this step surfaces. The
 * many statistics maps a manifest also carries are skipped, not captured.
 */
typedef struct PgColumnarAvroManifestEntry
{
	int32		status;			/* 0 EXISTING, 1 ADDED, 2 DELETED */
	int32		content;		/* 0 DATA, 1 POSITION_DELETES, 2 EQUALITY_DELETES */
	char	   *file_path;		/* the data file's path */
	char	   *file_format;	/* "PARQUET", "ORC", "AVRO" */
	int64		record_count;
	int64		file_size_in_bytes;
	char	   *partition;		/* the partition struct rendered as text, or NULL */
	int64		sequence_number;	/* the entry's data sequence number, when present */
	bool		has_sequence_number;	/* false when the field is null (inherited) */
	bool		has_sequence_field; /* the schema carries the column at all; a v1
									 * manifest does not (files default to 0) */
	int32	   *equality_ids;	/* content 2: the field ids defining row equality */
	int			nequality_ids;	/* 0 when the field is null or absent */
	char	   *referenced_data_file;	/* v3: the one data file a deletion
										 * vector targets, or NULL */
	int64		content_offset; /* v3: the DV blob's offset in its Puffin file */
	bool		has_content_offset; /* false when the field is null or absent */
	int64		content_size_in_bytes;	/* v3: the DV blob's length */
	bool		has_content_size;	/* false when the field is null or absent */
	PgColumnarAvroPartCell *part_cells; /* the partition tuple, typed, or NULL */
	int			npart_cells;	/* 0 when there is no partition struct */
} PgColumnarAvroManifestEntry;

/*
 * One decoded manifest_file entry from a snapshot's manifest list: which
 * manifest files the snapshot points at, and their summary counts.
 */
typedef struct PgColumnarAvroManifestFile
{
	char	   *manifest_path;
	int64		manifest_length;
	int32		partition_spec_id;
	bool		has_partition_spec_id;	/* false when absent/null/mistyped; an
										 * equality delete cannot be scoped then */
	int32		content;		/* 0 DATA, 1 DELETES */
	int64		sequence_number;
	int64		min_sequence_number;
	int64		added_snapshot_id;
	int32		added_files_count;
	int32		existing_files_count;
	int32		deleted_files_count;
	int64		added_rows_count;
	int64		existing_rows_count;
	int64		deleted_rows_count;
} PgColumnarAvroManifestFile;

/*
 * Decode an Avro manifest file, or a manifest LIST file, (already slurped into
 * memory) into a palloc'd array of entries in the current memory context. Raises
 * on any malformed input rather than returning a partial result. *nout is set to
 * the count.
 */
extern PgColumnarAvroManifestEntry *PgColumnarAvroReadManifest(const uint8 *buf,
															   int64 len,
															   int *nout);
extern PgColumnarAvroManifestFile *PgColumnarAvroReadManifestList(const uint8 *buf,
																  int64 len,
																  int *nout);

#endif							/* COLUMNAR_AVRO_H */
