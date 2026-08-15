/*-------------------------------------------------------------------------
 *
 * columnar_parquet_reader.h
 *		The narrow public surface of the hand-written Parquet reader: reading a
 *		file's rows into a tuplestore, projected by Parquet field id. The Iceberg
 *		scan (columnar_iceberg.c) uses this to read each data file by the table's
 *		field ids; everything else in the reader stays file-local.
 *
 *-------------------------------------------------------------------------
 */
#ifndef COLUMNAR_PARQUET_READER_H
#define COLUMNAR_PARQUET_READER_H

#include "postgres.h"

#include "access/tupdesc.h"
#include "executor/tuptable.h"
#include "utils/tuplestore.h"

/*
 * Read one Parquet file's rows into `tupstore`, binding output column i (of
 * `tupdesc`) to the file column whose Parquet field id equals field_ids[i], and
 * dropping any row whose 0-based file ordinal is in the sorted-ascending
 * `skipPos` set (Iceberg position deletes; pass NULL/0 to keep every row). This
 * is the field-id projection of pgcolumnar.read_parquet, exposed for the Iceberg
 * scan. `slot` must match `tupdesc`. `path` should already be an opened-safe
 * resolved path (the caller applies its own path boundary). Returns rows read.
 */
extern int64 PgColumnarReadParquetByFieldId(const char *path, TupleDesc tupdesc,
											 const int *field_ids, int nfield,
											 Tuplestorestate *tupstore,
											 TupleTableSlot *slot,
											 const uint64 *skipPos, int nSkipPos);

#endif							/* COLUMNAR_PARQUET_READER_H */
