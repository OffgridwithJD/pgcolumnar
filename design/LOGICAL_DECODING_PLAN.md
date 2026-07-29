# Logical decoding for columnar tables

Status: proposal, for review. Nothing here is implemented.

## What is missing today

`docs/limitations.md` says it plainly:

> Logical decoding reads heap-tuple WAL records. Changes to columnar tables are
> not emitted through logical decoding, so logical replication does not carry
> them. Use physical replication for columnar tables.

That is accurate and it is worse in practice than it reads. A user with logical
replication, or any CDC consumer, gets no error and no data. Nothing warns them.
Of everything in that file this is the entry most likely to be discovered in
production rather than in the manual.

"Silence" describes the signal and not the stream. Measured on a real slot with
`test_decoding`, over two inserts, an update and a delete:

```
changes naming the columnar table              0
changes naming pgcolumnar internal catalogs   33
changes naming an equivalent heap table        2
```

The consumer receives sixteen times more rows about our bookkeeping than a heap
table produces about the user's data, and none of them are the user's. A stream
that looks busy and carries nothing is harder to notice than one that carries
nothing at all. `docs/limitations.md` and `docs/user-guide.md` now say so (#190).

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

**Rejected**, but not for the reason this plan first gave, and the correction is
worth recording so B is not left looking impossible.

The first draft rejected it on a retention hazard: compaction and
`pgcolumnar.vacuum` may reclaim a row group before a lagging slot has read it,
leaving the stream silently short, and fixing that looked like teaching every
reclamation path to retain.

ChronicallyJD's answer on review is better than the objection: **do not teach
reclamation to retain, teach it to invalidate.** Core already makes exactly this
trade for WAL a slot still needs -- the slot is not preserved, it is marked
invalidated and the consumer finds out loudly. Reclamation would need to know
only the oldest slot LSN, and a reclaim that crosses it invalidates the slot
rather than truncating the stream. That is one comparison at reclaim time and no
change to retention policy anywhere, and it converts the failure from a silently
short stream into a visibly broken slot. Those are not the same class of problem.

So the retention hazard is answerable. B is still not the recommendation, for the
two reasons that remain: it breaks the invariant that decoding is a function of
the WAL stream alone, and it couples the correctness of the stream to
reclamation timing. The recommendation needs no decode-time access to storage at
all, which is a stronger position than needing it and having an answer for when
it fails.

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

Available on every supported major. The signature gained a `flush` argument at
**PostgreSQL 17**, verified in the headers of all five rather than inferred:

```c
/* 15, 16 */ LogLogicalMessage(prefix, message, size, transactional)
/* 17, 18, 19 */ LogLogicalMessage(prefix, message, size, transactional, flush)
```

so the guard is `PG_VERSION_NUM >= 170000`, and it gets **its own macro** in
`columnar_compat.h` rather than being folded in with another. Two signatures that
move at different versions under one guard is how `main` stopped compiling on 17
once already.

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

**The replay side is free and the emission side is not, and the plan should not
blur the two.** Physical replay of `XLOG_LOGICAL_MESSAGE` is a no-op, so a
standby costs nothing beyond carrying the bytes. On the primary the record is
ordinary WAL and is written whether or not anyone ever reads it. So emission is
**gated on the table being opted in, and a table nobody has opted in emits
nothing at all** -- no message, no size check, no branch beyond the flag test on
the flush path. A cluster that never uses this feature must pay exactly zero for
it, which is the difference between an opt-in feature and everyone subsidising a
feature few use.

Whether emission should be gated more tightly still -- on a replication slot
actually existing, rather than only on the table's opt-in -- is an open question
and is listed as one below. It is not obviously right: a slot created after the
writes have happened would silently have no history, which is a worse failure than
paying for WAL nobody read.

## Risks and open questions

1. **Message size.** A row group is 150,000 rows by default. One message per row
   group may be very large. Batching per N rows within the group is probably
   necessary; what N, and does it interact badly with `logical_decoding_work_mem`?
2. **What gates emission.** Opt-in per table is settled. Whether to gate more
   tightly on a slot existing is not. Gating on a slot makes an unused feature
   free even for an opted-in table, and makes a slot created afterwards see no
   history, which is a silent gap rather than a cost. Decide it before building,
   because it is the difference between "the table is being decoded" and "the
   table might be decoded later" and those need different guarantees.
2. **`TRUNCATE` and DDL.** `TRUNCATE` on a columnar table, and `ALTER TABLE`
   shapes that rewrite, need a decided answer rather than an accident.
3. **Rewrites that are not user changes.** Stated once as an invariant rather
   than as three cases, because future paths need a rule to check themselves
   against: **anything that moves rows without changing table contents emits
   nothing.** `pgcolumnar.vacuum`, `compact` and `recluster` are today's
   instances. It is the same rule `columnar_index.c` already follows on the
   rewrite path, where it enforces no constraint because the rows already
   satisfied them.

   This matters more than the happy path: a compaction replayed as a stream of
   inserts silently duplicates a table on the consumer.

   **The obvious test does not discriminate.** Asserting that a rewrite raises no
   error passes on a build that emits a full stream of inserts. The test has to
   assert that the consumer's change count is **unchanged across the rewrite**,
   and it has to be run against a build where the rewrite does emit, or it proves
   nothing. This project has been bitten five times by checks satisfied by both
   outcomes; this is the place it would happen again.
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

1. Plumbing and inserts, with the abort and no-op-on-rewrite tests. This is where
   the design is proven or not, and where the WAL cost gets measured. **The
   per-table option is not enabled by this phase.**
2. Deletes and updates, with identity. The option becomes reachable here.
3. Import paths, `TRUNCATE`, and DDL.
4. A reference consumer, and the documentation that says what this is not.

Phase 1 is the one worth doing before deciding whether the rest is worth it: if
the WAL cost measured there is unacceptable, that is the answer, and it is
cheaper to learn at phase 1 than at phase 4.

**The option must lag the capability, not lead it**, and this is a correction to
an earlier draft that had phase 1 shipping a usable option over inserts only.
ChronicallyJD's objection is right and it is the load-bearing one in this plan: a
consumer that enables change capture and receives inserts but not updates or
deletes does not get a partial answer, it gets a wrong one that looks complete,
and it builds a table that diverges from the source silently and permanently.
Today's behaviour is worse in every respect except the one that counts -- it
fails honestly, and the user eventually asks why they see nothing.

So a feature that is wrong when half-built must not be reachable when half-built.
Either the option refuses to enable until update and delete are covered, so
phase 1 is reachable only from a test, or it is named for exactly what it does
(`emit_inserts`, never `logical_decoding`) so nobody can turn it on believing
they have change capture. Either is fine. Shipping phase 1 as `logical_decoding`
is not.
