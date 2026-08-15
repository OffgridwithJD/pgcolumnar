/*-------------------------------------------------------------------------
 * columnar_iceberg.h
 *		Internal interface to the Iceberg reader (#388).
 *-------------------------------------------------------------------------
 */
#ifndef COLUMNAR_ICEBERG_H
#define COLUMNAR_ICEBERG_H

#include "funcapi.h"
#include "access/tupdesc.h"

#include "columnar_objstore.h"	/* PgColumnarObjStoreConfig */

/*
 * Read the Iceberg table whose current metadata.json is at `path` (a local or
 * remote URI) into a materialize-mode tuplestore on `rsinfo`, projecting the
 * columns named by `tupdesc`. This is the body of iceberg_scan, shared with the
 * REST catalog client, which resolves a table by name into a metadata location
 * and reads it through the same path. `cfg` is the object-store config for every
 * remote file of the table (catalog-vended storage credentials), or NULL to use
 * the ambient environment. Raises on any failure.
 */
extern void PgColumnarIcebergScanInto(const char *path, TupleDesc tupdesc,
									  ReturnSetInfo *rsinfo,
									  const PgColumnarObjStoreConfig *cfg);

#endif							/* COLUMNAR_ICEBERG_H */
