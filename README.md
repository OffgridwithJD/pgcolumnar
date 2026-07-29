<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="logo/pgcolumnar-logo-dark.svg">
  <img src="logo/pgcolumnar-logo.svg" alt="pgColumnar" width="360">
</picture>

<p><strong>Analytic column storage for PostgreSQL, built as a native table access method.</strong></p>

[![PostgreSQL 15–19](https://img.shields.io/badge/PostgreSQL-15%E2%80%9319-336791?style=flat-square&logo=postgresql&logoColor=white)](docs/installation.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Built with C](https://img.shields.io/badge/Built%20with-C-555555?style=flat-square&logo=c&logoColor=white)](docs/ARCHITECTURE.md)
[![Version 1.0-dev](https://img.shields.io/badge/version-1.0--dev-orange?style=flat-square)](VERSION)
[![Status: pre-release](https://img.shields.io/badge/status-pre--release-yellow?style=flat-square)](docs/limitations.md#release-status)

</div>

Column-oriented storage for PostgreSQL, implemented as a table access method. A
table created `USING pgcolumnar` stores its data by column, with per-column
compression, chunk-group skipping, and a vectorized aggregate path. It is for
analytic workloads: large scans, aggregates, and column projections over
append-mostly data.

pgColumnar builds from one source tree on PostgreSQL 15 through 19 and is
licensed under the [MIT License](LICENSE). It is [pre-release](docs/limitations.md#release-status); the version marker
is `1.0-dev`, recorded in `VERSION`. A table `USING pgcolumnar` is stored in the
native on-disk format, PGCN v1.

## Documentation

| | |
| --- | --- |
| [Features](docs/features.md) | What pgColumnar provides |
| [Installation](docs/installation.md) | Build, load, and create the extension |
| [User guide](docs/user-guide.md) | Create tables, load data, and query |
| [Administration](docs/administration.md) | Operate columnar tables in production |
| [Configuration](docs/configuration.md) | Settings and per-table options |
| [SQL reference](docs/sql-reference.md) | The `pgcolumnar.*` functions |
| [Limitations](docs/limitations.md) | Compatibility and known constraints |
| [Benchmarks](docs/benchmarks.md) | Size and latency numbers |
| [Testing](docs/testing.md) | The test suite and version matrix |
| [Changelog](CHANGELOG.md) | Notable changes |
| [Architecture](docs/ARCHITECTURE.md) | Source map for developers |

## Quick start

Build with PGXS against the target server, add the library to
`shared_preload_libraries`, and restart:

```sh
make PG_CONFIG=/path/to/pg_config
make install PG_CONFIG=/path/to/pg_config
```

```
shared_preload_libraries = 'pgcolumnar'
```

Then, in a database:

```sql
CREATE EXTENSION pgcolumnar;

CREATE TABLE events (id bigint, ts timestamptz, kind int, payload text)
  USING pgcolumnar;

INSERT INTO events
  SELECT g, now(), g % 8, 'p' || g
  FROM generate_series(1, 1000000) g;

SELECT count(*), avg(kind) FROM events WHERE kind = 3;
```

See the [installation guide](docs/installation.md) for requirements and the
[user guide](docs/user-guide.md) for loading and querying.

## Independence

pgColumnar is an independent implementation. It is not derived from the source of
any other columnar project. Its on-disk format, metadata catalog, and SQL
interface are designed from published column-store research and the open Apache
Arrow, Parquet, and ORC specifications, and are recorded in
[design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md](design/NATIVE_FORMAT_AND_INTERFACE_SPEC.md).
The implementation is built from that specification and the public PostgreSQL
API, by the clean-room method described in [PROVENANCE.md](PROVENANCE.md).

## License

MIT. See [LICENSE](LICENSE).
