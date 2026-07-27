# Logical decoding for columnar tables

Status: proposal, for review. Nothing here is implemented.

## What is missing today

`docs/limitations.md` says it plainly:

> Logical decoding reads heap-tuple WAL records. Changes to columnar tables are
> not emitted through logical decoding, so logical replication does not carry
> them. Use physical replication for columnar tables.

That is accurate and it is worse in practice than it reads. A user with logical
replication, or any CDC consumer, gets **silence** rather than an error: the
columnar table's changes simply never appear in the stream. Nothing warns them.
Of everything in that file this is the entry most likely to be discovered in
production rather than in the manual.

## Why it does not already work

Two facts, both verified in the PostgreSQL 17 tree rather than assumed.

**Logical decoding is heap-shaped at the point where a change is represented.**
`ReorderBufferChange` holds `HeapTuple oldtuple` / `HeapTuple newtuple`. That is
less limiting than it sounds -- a `HeapTuple` can be built with
`heap_form_tuple` from values that never lived on a heap page -- but it means
every path into the reorder buffer is a path core owns.

**Dispatch is per resource manager.** `LogicalDecodingProcessRecord` calls
`rmgr.rm_decode`, and `RmgrData` does carry that callback:

```c
typedef struct RmgrData
{
    ...
    void (*rm_decode) (struct LogicalDecodingContext *ctx,
                       struct XLogRecordBuffer *buf);
} RmgrData;
```

So the record types that can produce logical changes are exactly the ones whose
rmgr implements `rm_decode`.

**Our data does not reach WAL as tuples.** Every byte of columnar data reaches
WAL through `log_newpage` and `log_newpage_buffer` as full-page images, plus one
`XLOG_SMGR_TRUNCATE`. `test/wal_envelope.sh` asserts that by source shape and
exists to keep it true. A full-page image has no tuple structure and no decode
path, so the row data is *in* the WAL stream and is not *reachable* from it.

The metadata catalog is a different story: `pgcolumnar.row_group`,
`column_chunk`, `delete_vector` and `storage` are ordinary heap tables, so their
changes **are** decoded today. A CDC consumer subscribed to them sees row groups
appear and delete vectors change. It just cannot see any user data.

## Options

Five, with the reason each is or is not the answer. The first is the obvious one
and it is rejected on policy, so it is stated first and in full rather than
omitted.

### A. A custom resource manager with `rm_decode`

Technically available: `RegisterCustomRmgr()` exists from PostgreSQL 15, and
`rm_decode` is the documented way a resource manager produces logical changes.
This is how one would do it with a free hand.

**Rejected**, and not merely deferred. `test/wal_envelope.sh` states the standing
constraint and its reasoning:

> An extension that defines a custom resource manager or a new record type
> couples the WAL stream to its own version, which breaks a standby or a recovery
> that does not have the same build loaded and turns an extension bug into an
> unrecoverable cluster.

That reasoning holds. A cluster whose WAL contains records only our extension can
replay is a cluster that cannot be recovered by a stock `postgres` binary. For a
storage extension that is the wrong risk to take for a feature, however good the
feature. It also doubles the WAL cost of every write, since the data is already
logged as full-page images.

### B. Derive changes from the metadata catalog, read the data at decode time

The catalog changes are decoded already. On seeing a committed `row_group` row, a
decoder knows exactly which row numbers a transaction added, and row group bytes
are immutable once written, so re-reading them yields what was committed whenever
the read happens.

**Rejected**, for two reasons rather than one.

It breaks the invariant that decoding is a function of the WAL stream alone. And
the practical consequence is a retention hazard with no good answer: compaction
and `pgcolumnar.vacuum` may rewrite or reclaim a row group before a lagging slot
has read it, at which point the change is unreconstructable and the stream is
silently short. Heap has no equivalent problem because the tuple data is in the
WAL record. Solving it would mean teaching every reclamation path about
replication slots -- a large amount of new coupling for a feature that has a
cheaper route.

### C. Decode the full-page images

The data really is in the WAL. Reassembling row groups from `XLOG_FPI` records
would be decoding from WAL alone, with no retention hazard.

**Not available to an extension.** Those records belong to `RM_XLOG_ID`, whose
`rm_decode` is core's, and there is no hook to extend it. This would be a core
patch, not an extension feature.

### D. Emit logical decoding messages  — recommended

`LogLogicalMessage()` is a **core mechanism using an existing record type**
(`RM_LOGICALMSG_ID` / `XLOG_LOGICAL_MESSAGE`). Core decodes it
(`logicalmsg_decode`) and delivers it to output plugins through the documented
message callback. `pgoutput` forwards messages when the subscription asks for
them.

It satisfies the constraint that rules out A, and does so for the exact reason
the constraint exists: **replay of a logical message is a no-op**, so a standby
or a recovery running a stock binary without this extension loaded replays the
WAL correctly and ignores the message. Nothing about the cluster's
recoverability depends on our build.

Available on every supported major. The signature gained a `flush` argument
after 15, so it needs one entry in `columnar_compat.h` beside the others:

```c
/* 15  */ LogLogicalMessage(prefix, message, size, transactional)
/* 16+ */ LogLogicalMessage(prefix, message, size, transactional, flush)
```

### E. Triggers, in user space  — available today, and the interim answer

Since #182 made `AFTER ... FOR EACH ROW` triggers work on columnar tables, a user
can capture changes into a heap side-table with an ordinary trigger, and that
heap table is decoded normally. It costs write amplification and it is entirely
manual, but it needs nothing from us and it works now.

**This should go in the documentation regardless of what we build**, because it
is the honest answer to "what do I do today", and because it will remain the
right answer for anyone who wants changes delivered as ordinary row changes to a
subscriber table.

## The recommended design in detail

### Shape

Per-table opt-in through `pgcolumnar.set_options`, defaulting to off, because it
costs WAL volume and most tables do not need it. A GUC alone would be wrong here
for the reason #170's review gives: the same table would be written differently
depending on which session loaded it.

On flush of a row group belonging to an opted-in table, emit one transactional
logical message per row group carrying the rows that group added. On flush of a
delete vector, emit one carrying the deleted row numbers and their identity
columns. Update is delete plus insert, which is what the access method already
does, so it needs no separate case.

`transactional = true` throughout, so messages appear in commit order inside the
transaction that produced them and vanish if it aborts. That is the property that
makes this correct rather than approximate, and it is core's to provide.

### Payload

A versioned binary payload under a fixed prefix (`pgcolumnar`), holding: format
version, relation identity, operation, the row-number range, and the row data.

For the row data, **reuse the Arrow IPC encoder in `columnar_arrow.c`**. It is
already written, already tested by four suites, self-describing, and consumers
have libraries for it. Inventing a payload format for this would be a second
serialization format in the tree to keep correct.

### What it gives, and what it does not

It gives a correct, ordered, transactional change stream that a CDC consumer can
read.

It does **not** give native logical replication into a subscriber table.
`pgoutput` delivers messages as messages; a subscriber will not turn them into
rows in a table by itself. Anyone wanting that needs a consumer that understands
the payload. This has to be said plainly in the documentation, because
"logical decoding works now" would be read as "logical replication works now"
and it does not.

### Cost

Row data is written to WAL twice: once as the full-page images that make the
storage crash-safe, and once in the message. That is the price of the constraint,
it is per-table and opt-in, and it should be measured and published rather than
described. On the shapes in #155 the write path is already the weak spot, so this
must be benchmarked before it is recommended for anything.

## Risks and open questions

1. **Message size.** A row group is 150,000 rows by default. One message per row
   group may be very large. Batching per N rows within the group is probably
   necessary; what N, and does it interact badly with `logical_decoding_work_mem`?
2. **`TRUNCATE` and DDL.** `TRUNCATE` on a columnar table, and `ALTER TABLE`
   shapes that rewrite, need a decided answer rather than an accident.
3. **Rewrites that are not user changes.** `pgcolumnar.vacuum`, `compact` and
   `recluster` move rows between groups without changing table contents. These
   must emit nothing, and the test for that matters more than the test for the
   happy path -- a compaction that replays as a stream of inserts would silently
   duplicate a table on the consumer.
4. **Identity for deletes.** A delete vector records row numbers. A consumer needs
   the key columns, so the identity columns have to be read at flush time. What
   is the analogue of `REPLICA IDENTITY` here, and what happens with no primary
   key?
5. **Import paths.** `import_arrow` / `import_parquet` insert rows without the
   executor. They must emit too, or an import is a silent gap in the stream.

## Test plan

The oracle is heap. For an identical workload against a heap table and an
opted-in columnar table, the change streams from
`pg_logical_slot_get_changes` must describe the same rows in the same order.

Discriminating cases, which matter more than the happy path:

- a transaction that **aborts** emits nothing
- `compact` / `recluster` / `vacuum` emit **nothing**, which is the one that
  turns a subtle bug into visible duplication on the consumer
- an import emits the imported rows
- a delete emits identity, not just a row number
- `wal_envelope.sh` still passes, which is what proves this did not reach for a
  custom rmgr
- volume: a large insert does not exceed `logical_decoding_work_mem` in a way
  that spills unboundedly

## Phasing

1. Per-table option, plumbing, and inserts only, with the abort and
   no-op-on-rewrite tests. This is where the design is proven or not.
2. Deletes and updates, with identity.
3. Import paths, `TRUNCATE`, and DDL.
4. A reference consumer, and the documentation that says what this is not.

Phase 1 is the one worth doing before deciding whether the rest is worth it: if
the WAL cost measured there is unacceptable, that is the answer, and it is
cheaper to learn it at phase 1 than at phase 4.
