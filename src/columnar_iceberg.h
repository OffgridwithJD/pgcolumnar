/*-------------------------------------------------------------------------
 * columnar_iceberg.h
 *		Internal interface to the Iceberg reader (#388).
 *-------------------------------------------------------------------------
 */
#ifndef COLUMNAR_ICEBERG_H
#define COLUMNAR_ICEBERG_H

#include "funcapi.h"
#include "access/tupdesc.h"
#include "utils/tuplestore.h"

#include "columnar_objstore.h"	/* PgColumnarObjStoreConfig */

struct PgColumnarAvroPartCell;
struct PgColumnarAvroBound;

/*
 * What a per-data-file filter (the FDW's pruning) sees about one data file: its
 * typed partition tuple (already transformed) and spec id, and its column
 * lower/upper bounds (Iceberg single-value binary, keyed by field id).
 */
typedef struct PgColumnarIceFileMeta
{
	const struct PgColumnarAvroPartCell *cells;
	int			ncells;
	int32		spec_id;
	const struct PgColumnarAvroBound *lower;
	int			nlower;
	const struct PgColumnarAvroBound *upper;
	int			nupper;
} PgColumnarIceFileMeta;

/*
 * A per-data-file filter for a filtered Iceberg scan: return true to SKIP
 * (prune) the file, false to read it.
 */
typedef bool (*PgColumnarIceFileFilter) (void *arg,
										 const PgColumnarIceFileMeta *meta);

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

/*
 * As PgColumnarIcebergScanInto, but reads into the caller-owned `tupstore` and
 * applies `filter` per data file (NULL reads all). Returns the number of data
 * files pruned. `tupdesc` is the output/projection descriptor, caller-owned. The
 * vehicle for the Iceberg FDW: it obtains the file list, prunes by the filter,
 * and reads the survivors (with their deletes applied) into the tuplestore.
 */
extern int64 PgColumnarIcebergScanCore(const char *path, TupleDesc tupdesc,
									   const PgColumnarObjStoreConfig *cfg,
									   Tuplestorestate *tupstore,
									   PgColumnarIceFileFilter filter,
									   void *filterarg);

/*
 * Map the current partition spec's IDENTITY fields to `tupdesc` columns for FDW
 * pruning: *out_attno[k] is the 1-based attno the identity partition field at
 * partition-tuple position k maps to (0 for a non-identity transform or an
 * absent source column); *out_npos the partition field count; *out_specid the
 * current spec id (a data file with a different spec_id must not be pruned with
 * this map). palloc'd in the current context.
 */
extern void PgColumnarIcebergIdentityPartMap(const char *path,
											 const PgColumnarObjStoreConfig *cfg,
											 TupleDesc tupdesc,
											 int **out_attno, int *out_npos,
											 int32 *out_specid);

/*
 * Per-column current-schema field ids (0 when absent), length tupdesc->natts,
 * for FDW metrics pruning keyed by field id. palloc'd in the current context.
 */
extern int *PgColumnarIcebergColumnFieldIds(const char *path,
											const PgColumnarObjStoreConfig *cfg,
											TupleDesc tupdesc);

#endif							/* COLUMNAR_ICEBERG_H */
