"""pgColumnar pytest harness: fixtures.

The vacuity layer in pgc_vacuity.py is loaded for every run through the `-p`
argument in pytest.ini, not imported here, so that a test file cannot opt out of it.

`pytester` is enabled because the layer's own tests run pytest inside pytest: a
guard is proven to REFUSE rather than assumed to.

PSYCOPG IS IMPORTED INSIDE THE FIXTURES THAT USE IT, NOT HERE, AND THAT IS
LOAD-BEARING RATHER THAN TIDINESS. conftest is imported before every run, so a
module-scope `import psycopg` made a DATABASE DRIVER a hard requirement of the
whole corpus -- including every test that never opens a connection. With the
import at module scope NO test runs without the driver, and the failure is a
conftest ImportError before collection rather than a failed test.

No count is written here. Which files need no database is decided in
test_harness_deps.py, from the corpus, and the gate's job prints what it ran:
a number in this docstring would be a hand-maintained derived value (#908).

That is the difference between "this harness needs Postgres" and "the tests that
talk to Postgres need Postgres", and it is what lets the guard-testing half of
this corpus run somewhere that has no database at all -- which is where the gate
is (README.md, "This is not in the gate yet").
"""

import os
import re
import pathlib
import shutil
import signal

import pytest

import pgc_vacuity

from pgc_cluster import _pg_config, build_once, make_cluster

pytest_plugins = ["pytester"]

DEFAULT_PG_CONFIG = "/usr/local/pg18a/bin/pg_config"


def pytest_addoption(parser):
    parser.addoption(
        "--pg-config",
        action="store",
        default=os.environ.get("PGC_PG_CONFIG", DEFAULT_PG_CONFIG),
        help="pg_config of the server build under test (assert-enabled, per lib.sh)",
    )


SRCDIR = pathlib.Path(__file__).resolve().parents[2]


def major_of(version_text):
    """"PostgreSQL 18.4" -> "18". The build stamp is per major, because objects
    from another major link and then fail to load (#536)."""
    m = re.search(r"(\d+)", version_text or "")
    return m.group(1) if m else ""


def _raise_system_exit(signum, *_frame):
    """Turn SIGTERM into SystemExit so `finally` blocks run (#1170).

    128 + signum is the exit status a shell reports for a signalled process, so a
    caller reading `$?` sees 143 either way and nothing downstream has to learn a
    new number.

    THE FRAME IS TAKEN AS A VARARG BECAUSE IT IS GENUINELY UNREAD. Python calls a
    signal handler with two positional arguments, and naming the second one would
    be a parameter this function ignores -- which
    `test_no_helper_in_this_corpus_takes_a_parameter_it_never_reads` refuses,
    corpus-wide and correctly. It caught this on the first run.
    """
    raise SystemExit(128 + signum)


@pytest.fixture(scope="session")
def pgc_cluster(request, worker_id):
    """One cluster per xdist worker, built once and torn down at session end."""
    pg_config = request.config.getoption("--pg-config")

    # BUILD BEFORE THE SERVER STARTS. This ran the other way round first, and the
    # ordering was not a detail: shared_preload_libraries maps the library at
    # postmaster start, so a cluster started before the install keeps the OLD
    # .so mapped for its whole life. The build would report success and every
    # test would still measure the previous branch's code -- the same defect the
    # build guard exists to close, reintroduced by the order of two lines.
    #
    # It showed up as a flake: the first run after a source change failed to
    # start a cluster, and the next run passed because the install had already
    # landed.
    major = major_of(_pg_config(pg_config, "--version"))
    verdict = build_once(str(SRCDIR), pg_config, major)

    cluster, root = make_cluster(pg_config, worker_id)
    print(f"\n-- build: {verdict} from {SRCDIR}")
    # Printed for the same reason lib.sh prints it: so a reader can tell which
    # binary produced the results below.
    print(f"-- cluster: worker={worker_id} port={cluster.port} "
          f"{cluster.version} .so={cluster.so_md5()}")
    # And the running server is the one that loaded THAT library. @jdatcmd noted
    # a start-time check would be near-vacuous because the cluster is initdb'd
    # fresh each session, so the postmaster always starts after the .so. That is
    # true once the order above is right, and it is exactly what pins the order:
    # with the build after the start, the .so is NEWER than the postmaster and
    # this refuses.
    cluster.require_server_loaded_this_binary()
    import psycopg          # deferred: see the module docstring

    # A KILLED RUN MUST NOT LEAK ITS CLUSTER (#1170). Python does not run
    # `finally` blocks when the DEFAULT SIGTERM disposition terminates the
    # process, so the teardown below was unreachable for every interrupted run --
    # and interrupting a run is normal and correct, not an error. The postmaster
    # then survives holding its port, its shared memory and its datadir.
    #
    # Measured before this handler existed: 21 orphaned postmasters and ~2.5 GB
    # of datadirs across the two development containers, the oldest 33 hours, and
    # one container had background tasks killed for low memory as a result. A
    # leaked cluster holding a port is also the documented false-red source: a
    # later run fails for a reason that has nothing to do with the code.
    #
    #     plain try/finally, kill -TERM                 0 finally blocks ran
    #     SIGTERM handler raising SystemExit, same kill 1 finally block ran
    #
    # SIGKILL IS UNCATCHABLE and no handler will ever cover it. The stale
    # clusters that predate this were `pkill -9` and the OOM killer.
    #
    # THE SHELL HALF ALREADY HANDLES THIS AND MUST NOT BE "FIXED": lib.sh's
    # `trap pgc_teardown EXIT` already runs on TERM, INT and HUP, and naming the
    # signals explicitly makes the handler fire twice.
    previous = None
    try:
        previous = signal.signal(signal.SIGTERM, _raise_system_exit)
    except ValueError:
        # Not the main thread of the main interpreter. Nothing to install, and
        # the run is not worse off than it was.
        previous = None

    try:
        with psycopg.connect(cluster.dsn(), autocommit=True) as conn:
            conn.execute("CREATE EXTENSION IF NOT EXISTS pgcolumnar")
        yield cluster
    finally:
        if previous is not None:
            try:
                signal.signal(signal.SIGTERM, previous)
            except ValueError:
                pass
        cluster.stop()
        shutil.rmtree(root, ignore_errors=True)


@pytest.fixture
def pgc_conn(pgc_cluster, request):
    """A direct connection, in a schema private to this one test.

    A private schema rather than a private database: isolation without paying an
    initdb per test. It is first on the search_path, so an unqualified CREATE TABLE
    lands in it and cannot collide with another test's fixture.

    autocommit is ON deliberately. With it off, a fixture that forgets to commit
    leaves the next connection looking at an absent table, which is measured in the
    design document as a way to make a test assert nothing.
    """
    import psycopg          # deferred: see the module docstring

    schema = "pgc_test_" + "".join(
        ch if ch.isalnum() else "_" for ch in request.node.name
    )[:48]
    conn = psycopg.connect(pgc_cluster.dsn(), autocommit=True)
    try:
        conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
        conn.execute(f'CREATE SCHEMA "{schema}"')
        conn.execute(f'SET search_path TO "{schema}", public')
        # WATCHED, so a write that wrote nothing cannot pass unnoticed. The three
        # statements above run on the raw connection deliberately: they are this
        # fixture's own DDL, not the test's writes, and DDL carries no row count
        # anyway. See pgc_vacuity.watch_writes and test_writes_wrote_rows.py.
        yield pgc_vacuity.watch_writes(conn, request.node.nodeid)
    finally:
        try:
            conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
        finally:
            conn.close()
