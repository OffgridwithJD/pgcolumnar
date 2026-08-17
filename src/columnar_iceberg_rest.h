/*-------------------------------------------------------------------------
 * columnar_iceberg_rest.h
 *		Internal interface to the Iceberg REST Catalog client (#388 phase 7).
 *-------------------------------------------------------------------------
 */
#ifndef COLUMNAR_ICEBERG_REST_H
#define COLUMNAR_ICEBERG_REST_H

/*
 * Resolve the current metadata-location URI of `table` in `ns` at the catalog
 * `catalog_uri` (an http(s):// base). Raises on any failure. The returned
 * string is palloc'd in the current memory context.
 */
extern char *PgColumnarIcebergRestLoadTableLocation(const char *catalog_uri,
													const char *ns,
													const char *table,
													const char *token,
													const char *warehouse);

#endif							/* COLUMNAR_ICEBERG_REST_H */
