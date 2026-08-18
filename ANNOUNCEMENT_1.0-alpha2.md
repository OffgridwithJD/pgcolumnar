# Announcing pgColumnar 1.0-alpha2

We have released pgColumnar 1.0-alpha2, the second alpha of the columnar table
access method for PostgreSQL.

The headline of this release is read-only Apache Iceberg support. You can now
read an Iceberg table at its current snapshot in three ways: by metadata path
with `pgcolumnar.iceberg_scan`, through a REST catalog with
`pgcolumnar.iceberg_rest_scan`, or as a PostgreSQL foreign table. All three apply
Iceberg row-level deletes of every kind, position deletes, equality deletes, and
format-version-3 deletion vectors, under their sequence and scope rules, and
resolve columns by schema field id so a data file written before a column rename
still reads. The foreign-data wrapper takes the query predicate and prunes whole
data files, by partition value and by column statistics, before it opens them.

Alongside Iceberg, this release adds object storage. The Parquet readers and
export functions, the Parquet foreign-data wrapper, and the Iceberg reader now
accept `s3://`, `http://`, and `https://` URLs wherever they accept a local path.
`s3://` requests are signed with AWS Signature Version 4, and `https://` verifies
the server certificate. Remote access is confined to an endpoint allow-list that
is empty by default, refuses link-local and instance-metadata addresses, and
lives in a separate module so no second TLS stack enters the main server process.

The release also adds a maintenance daemon, `pgcolumnar.autovacuum`, for the
online upkeep that core autovacuum does not perform on a columnar table, along
with functions to report when a table is due for maintenance and to flush a
stripe across background workers. Statistics collection now records most-common
values and honours per-column targets, and several planner cost estimates are
more accurate. Parameterized predicates, wide-table scans, and reads of tables
with deletes are faster.

This release includes a round of security and hardening work, some of it from an
adversarial audit. It bounds a varlena value's stored length against its buffer,
closes a stat-before-open race, makes the Thrift and Avro decoders interruptible,
refuses several classes of malformed Iceberg metadata, and closes an HTTP
request-line injection in the object-store client. Each fix ships with a
regression test and a proof that removing it reintroduces the failure.

pgColumnar is alpha software. Iceberg support is read-only and reads Parquet
data files. Interfaces may change before 1.0.

Upgrading from 1.0-alpha requires one command. After installing this build, run
`ALTER EXTENSION pgcolumnar UPDATE;` in every database that has the extension.
The extension's C symbols were namespaced in this cycle, and without the catalog
update an existing columnar table fails to read. No data is converted.

pgColumnar is available at https://github.com/commandprompt/pgcolumnar. The
release notes are in `RELEASE_NOTES_1.0-alpha2.md`, the complete change list is in
`CHANGELOG.md`, and installation and upgrade instructions are in `docs/`. Bug
reports and feedback are welcome on the issue tracker.
