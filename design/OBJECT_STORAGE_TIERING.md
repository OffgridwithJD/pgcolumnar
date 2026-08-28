# Tiering columnar data to object storage: design and recommendation

Issue #403 item 5 records ClickHouse's TTL-to-volume feature, which ages cold
data to an object-storage volume:

```sql
TTL (ts + INTERVAL 1 WEEK) TO VOLUME 's3'
```

Its stated prerequisites, #393 (object storage reads) and #394 (object storage
writes), are both closed. This document is the answer to whether we should build
the feature on top of them.

**Recommendation: do not build native tiering.** Build the same capability as a
workflow over the pieces that already exist. The reasoning is below, and it is
not primarily about difficulty.

Written 2026-08-28. Item 5a, `pgcolumnar.expire`, is the other half of item 5 and
is implemented separately.

## Audience and scope

For anyone deciding whether to move columnar bytes out of the relation's main
fork. It covers native row-group data only. External Parquet and Iceberg reads
already live in object storage and are unaffected by everything here.

## What exists today, checked against the code

| Fact | Evidence |
| --- | --- |
| Native bytes live in the relation's main fork | `PgColumnarWriteLogicalData` writes through `ReadBufferExtended(rel, MAIN_FORKNUM, ...)` |
| There is one seam each way | 4 call sites read through `PgColumnarReadLogicalData` (all in `columnar_reader.c`), 1 writes through `PgColumnarWriteLogicalData` (`columnar_write_state.c:2755`) |
| Every page is WAL-logged as a full-page image | `log_newpage_buffer(buffer, true)` on each written page, and on each gap page |
| Object storage supports ranged reads | `PgColumnarObjStoreApi.read(h, off, buf, n)`, plus `open`, `close`, a multipart sink, `delete_object` and `list` |
| Physical replication is the supported path for columnar tables | `docs/limitations.md`: logical decoding reads heap tuple records, columnar data reaches WAL as full-page images carrying no tuple structure |

The seam is genuinely small, and the object-storage API already offers ranged
reads, which is exactly the shape a reader needs. **Feasibility is not the
problem.**

## The invariants a tier would have to preserve

A row group's bytes are, today, ordinary relation data. Five properties follow
from that, and a tier has to keep all five or say which it abandons.

1. **Crash recovery.** After a crash, replay of WAL restores every page. The
   bytes are in the WAL stream as full-page images.
2. **Physical replication.** A standby has the data because it replays the same
   WAL. This is the *only* supported replication path for columnar tables.
3. **Backup.** `pg_basebackup` copies the data directory and the WAL needed to
   make it consistent. A backup is complete by construction.
4. **Point-in-time recovery.** Restoring to a past point restores the bytes as
   they were at that point, because the WAL says what they were.
5. **Transactional rollback.** A rewrite that aborts leaves nothing behind that a
   reader can see, because the pages it wrote are never committed.

## Why tiering breaks them, and which break is fatal

Moving a row group's bytes to an object store removes them from the main fork.
They are then not in WAL, and each invariant fails in turn:

- **Crash recovery** no longer covers the data. This is the failure people expect
  and it is the least serious, because an object store is itself durable.
- **Physical replication silently stops carrying the data.** This is the fatal
  one. A standby replays WAL and finds no bytes. It cannot fetch them, because
  nothing in the WAL stream says they exist. The extension's own documented
  replication story is physical replication, so tiering removes the only
  supported way to replicate a columnar table, for the tables that use it.
- **Backup** stops being self-contained. `pg_basebackup` produces a backup that
  restores to a database referring to objects it does not contain.
- **PITR** becomes unsound in a way that cannot be fixed inside the extension.
  Restoring to a point before an object was deleted requires the object store to
  hold a version that the extension deleted, and object stores do not roll back.
- **Rollback** requires an aborted tiering rewrite to leave no reachable object,
  which means the abort path has to delete remote objects it may have already
  written, over a network that may be unreachable at that moment.

The second one is what settles it. The others are engineering problems with
known, expensive answers. Losing physical replication is a change to what the
product is.

## Why this is not deferrable

The project's standing constraint is that the extension may use core WAL
mechanisms and existing record types only. A tier that kept replication working
would have to put *something* in the WAL that a standby can act on: a record
saying "this row group now lives at this URL", which the standby then reads
remotely. That is a new WAL semantic, carried in a new record type, interpreted
by a replay path this extension does not own.

So this is not a large feature waiting for time. It is a design that the
extension's constraints reject. Recording it as **rejected** rather than
**deferred** is the honest disposition, and it is why this document exists
instead of a phase plan.

## What to build instead

The user-facing goal, "old data should stop occupying expensive local storage",
is achievable today by composing pieces that already exist, with none of the
invariants above touched:

1. Export the cold range to Parquet in object storage, with
   `pgcolumnar.export_parquet` or `pgcolumnar.parallel_export_parquet` (#394).
2. Drop the local rows, with `pgcolumnar.expire` (#403 item 5a) or an ordinary
   `DELETE` plus `pgcolumnar.compact`.
3. Read the exported data when it is needed, through the external Parquet reader
   or `iceberg_scan` (#388, #393).

The local relation stays entirely in its main fork, so crash recovery, physical
replication, backup, PITR and rollback are exactly what they were. What is given
up is that the cold data is no longer part of the same table: a query that spans
both has to union them.

That is a real limitation and it should be stated plainly rather than dressed up.
It is also the difference between a feature this extension can support and one it
cannot.

## What would change this answer

One thing: core PostgreSQL gaining a way for an extension to participate in WAL
and replay for data it stores outside the main fork. If that arrives, the seam
identified here is still the right place to start, and this document's invariant
list is the specification the work would have to satisfy.

Nothing about object storage, and nothing about the size of the change, is what
stands in the way.
