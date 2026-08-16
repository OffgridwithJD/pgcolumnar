/*-------------------------------------------------------------------------
 *
 * columnar_customscan.h
 *		The planner side: what columnar_customscan.c offers the table AM and the vectorized path.
 *
 * Split out of columnar.h (#496). Every declaration here had exactly ONE
 * consumer outside its defining file, so it was a private arrangement between
 * two files that the other twenty were forced to recompile for.
 *
 * The shared vocabulary these signatures take stays in columnar.h, which this
 * includes.
 *
 * Written fresh for pgColumnar.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PGCOLUMNAR_CUSTOMSCAN_H
#define PGCOLUMNAR_CUSTOMSCAN_H

#include "columnar.h"

extern Bitmapset *PgColumnarProjectionFromAttnos(Bitmapset *needed, int natts,
											   int *nProjected);

extern void PgColumnarCustomScanInit(void);

extern void pgcolumnar_refined_scan_cost(RelOptInfo *rel, Oid relid,
										 Path *seqpath, Cost *out_startup,
										 Cost *out_total);

extern void PgColumnarExplainPushedDown(int64 nfilters, ExplainState *es);

extern void PgColumnarExplainVectorPredicates(int64 npreds, ExplainState *es);

extern int	PgColumnarCountScanKeys(List *qual, Index scanrelid,
								  TupleDesc tupdesc);

extern void PgColumnarExplainGroupStats(const PgColumnarGroupStats *stats,
									  ExplainState *es);

#endif							/* PGCOLUMNAR_CUSTOMSCAN_H */
