"""A table-AM parallel scan must share work across workers.

With the custom scan off, Parallel Seq Scan goes through the AM. The AM
used to treat phs_nallocated as a first-wins flag: one backend claimed
the whole scan and the others marked themselves exhausted. Workers
launched, one backend read.

Independent of test/parallel_am_scan.sh: same public seam (EXPLAIN ANALYZE
of a Parallel Seq Scan), own fixture, own observations. Assertion names
match the shell suite so the two can be compared by name, not by importing
each other. Leader participation is off so the two launched workers are
the claimers under test. Many small row groups keep both workers busy
before either finishes the table.
"""

import pathlib
import re
import uuid



def _nodes(plan):
    stack = [plan[0]["Plan"]]
    while stack:
        node = stack.pop(0)
        yield node
        stack.extend(node.get("Plans") or ())


def _first(plan, node_type):
    for node in _nodes(plan):
        if node.get("Node Type") == node_type:
            return node
    return None


def _worker_rows(plan):
    rows = []
    scan = _first(plan, "Seq Scan")
    if scan is None:
        return rows
    for worker in scan.get("Workers") or ():
        if "Actual Rows" in worker:
            rows.append(worker["Actual Rows"])
    return rows


def _plan(conn, workers, analyze=False):
    opts = "ANALYZE, VERBOSE, TIMING OFF, SUMMARY OFF, " if analyze else "VERBOSE, "
    with conn.cursor() as cur:
        cur.execute(f"SET max_parallel_workers_per_gather = {workers}")
        cur.execute(
            f"EXPLAIN ({opts}FORMAT JSON, COSTS OFF) SELECT id FROM ampar"
        )
        return cur.fetchone()[0]


def test_parallel_am_scan(pgc_conn, expect):
    n = 80000
    with pgc_conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE ampar (id int, k int, payload text) USING pgcolumnar"
        )
        cur.execute(
            "SELECT pgcolumnar.set_options('ampar', "
            "chunk_group_row_limit => 200, stripe_row_limit => 1000)"
        )
        cur.execute(
            f"INSERT INTO ampar SELECT g, g, md5(g::text) "
            f"FROM generate_series(1, {n}) g"
        )
        cur.execute("ALTER TABLE ampar SET (parallel_workers = 2)")
        cur.execute("ANALYZE ampar")
        cur.execute("SELECT count(*) FROM ampar")
        expect.num(cur.fetchone()[0], n, "premise: the table holds every inserted row")

        cur.execute("SET pgcolumnar.enable_custom_scan = off")
        cur.execute("SET parallel_setup_cost = 0")
        cur.execute("SET parallel_tuple_cost = 0")
        cur.execute("SET min_parallel_table_scan_size = 0")
        cur.execute("SET jit = off")
        cur.execute("SET parallel_leader_participation = off")

    serial = _plan(pgc_conn, 0)
    parallel = _plan(pgc_conn, 2)
    analyzed = _plan(pgc_conn, 2, analyze=True)

    expect.text(
        "Seq Scan" if _first(serial, "Seq Scan") else "none",
        "Seq Scan",
        "premise: with the custom scan off the serial plan is a Seq Scan",
    )
    expect.text(
        "none" if _first(serial, "Custom Scan") is None else "Custom Scan",
        "none",
        "premise: the serial plan is not a columnar custom scan",
    )
    expect.text(
        "Gather" if _first(parallel, "Gather") is not None else "none",
        "Gather",
        "premise: the parallel plan has Gather",
    )
    expect.num(
        (_first(parallel, "Gather") or {}).get("Workers Planned"),
        2,
        "premise: the parallel plan uses two workers",
    )
    expect.text(
        "Seq Scan" if _first(analyzed, "Seq Scan") else "none",
        "Seq Scan",
        "premise: the parallel plan is still a Seq Scan, not a custom scan",
    )
    expect.num(
        (_first(analyzed, "Gather") or {}).get("Workers Launched"),
        2,
        "premise: EXPLAIN ANALYZE launched two workers",
    )

    with pgc_conn.cursor() as cur:
        cur.execute("SET max_parallel_workers_per_gather = 0")
        cur.execute("SELECT count(*) FROM ampar")
        serial_cnt = cur.fetchone()[0]
        cur.execute("SET max_parallel_workers_per_gather = 2")
        cur.execute("SELECT count(*) FROM ampar")
        par_cnt = cur.fetchone()[0]
    expect.num(
        par_cnt,
        serial_cnt,
        "a parallel table-AM scan returns the same row count as serial",
    )

    worker_rows = _worker_rows(analyzed)
    expect.num(
        len(worker_rows),
        2,
        "premise: ANALYZE printed a rows= line per launched worker",
    )
    n_busy = sum(1 for r in worker_rows if r and r > 0)
    print(f"-- worker rows {worker_rows} busy={n_busy}")
    expect.num(
        n_busy,
        2,
        "workers share the table-AM scan, it is not a single claimer",
    )


# ---- a parallel INDEX BUILD is the other consumer of the shared claim --------
#
# The scan arms above drive pgcolumnar_next_group_index through a parallel seq
# scan. A parallel index build reaches the same claim through
# table_beginscan_parallel, and it is the consumer where a claim bug is silent:
# a scan that double-claims returns duplicate rows and someone notices, while an
# index that SKIPS a group is simply missing entries.
#
# THE WORKER COUNT IS NOT A pgcolumnar GUC, and max_parallel_maintenance_workers
# alone will not produce one. That GUC is a gate -- 0 builds serially -- but core
# sizes the request in plan_create_index_workers() from relpages, and a columnar
# table reports very few pages for many rows (measured: 69 pages for 2,000,000),
# so the heuristic grants ONE worker however large the fixture. The table's
# `parallel_workers` reloption is the only dial.
#
# Independent of test/parallel_am_scan.sh: that suite reads PGC_LOGFILE with awk
# and compares a concatenated string; this one reads the cluster's own
# server.log through the pgc_cluster fixture and compares a tuple. Same seam,
# separate observers, neither invoking the other.
def _requested_workers(cluster, marker):
    """Workers the build asked for, from the first request line after MARKER.

    Scoped to a marker this test wrote, so a build from an earlier test in the
    same session cluster cannot answer for this one.
    """
    log = pathlib.Path(cluster.datadir) / "server.log"
    if not log.is_file():
        return None
    seen = False
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        if not seen:
            if marker in line:
                seen = True
            continue
        m = re.search(r"with request for (\d+) parallel worker", line)
        if m:
            return int(m.group(1))
    return None


def _scan_node_of(plan):
    stack = [plan[0]["Plan"]]
    while stack:
        node = stack.pop(0)
        t = node.get("Node Type", "")
        if t in ("Index Only Scan", "Index Scan", "Seq Scan", "Custom Scan"):
            return t
        stack.extend(node.get("Plans") or ())
    return ""


def test_a_parallel_index_build_covers_the_whole_table(pgc_cluster, pgc_conn, expect):
    """The index built in parallel must describe every row."""
    marker = "pamidx_" + uuid.uuid4().hex[:12]
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE pamidx (id int, v int) USING pgcolumnar")
        cur.execute(
            "INSERT INTO pamidx SELECT g, g % 1000 FROM generate_series(1, 300000) g"
            # single %, not %%: psycopg only un-doubles when it is
            # interpolating, and this call passes no parameters.
        )
        cur.execute("ALTER TABLE pamidx SET (parallel_workers = 4)")
        cur.execute("ANALYZE pamidx")
        # The marker is interpolated, not bound: a placeholder inside a DO
        # body cannot be typed ("could not determine data type of parameter
        # $1"), because the body is a string literal to the server. Safe to
        # interpolate and asserted so -- it is uuid4 hex generated here.
        assert marker.replace("_", "").isalnum(), marker
        cur.execute("DO $pgcmark$ BEGIN RAISE LOG '%s'; END $pgcmark$" % marker)
        cur.execute("SET log_min_messages = debug1")
        cur.execute("SET max_parallel_maintenance_workers = 4")
        cur.execute("SET min_parallel_table_scan_size = 0")
        cur.execute("CREATE INDEX pamidx_id ON pamidx (id)")
        cur.execute("RESET log_min_messages")

    req = _requested_workers(pgc_cluster, marker)
    # THREE FAILING STATES, not one: no line in the log at all, a request of zero,
    # or a request below what this premise needs. `got 0 want 1` named none of them.
    expect.text(
        "requested" if (req is not None and req >= 2)
        else ("no worker request found in the log" if req is None
              else f"requested {req}, needs 2"),
        "requested",
        "premise: the index build requested parallel workers",
    )

    with pgc_conn.cursor() as cur:
        cur.execute("SET enable_seqscan = off")
        cur.execute("SET pgcolumnar.enable_custom_scan = off")
        cur.execute(
            "EXPLAIN (FORMAT JSON, COSTS OFF) "
            "SELECT count(*) FROM pamidx WHERE id > 0"
        )
        plan = cur.fetchone()[0]
        cur.execute("SELECT count(*), coalesce(sum(id), 0) FROM pamidx WHERE id > 0")
        via_index = cur.fetchone()
    expect.text(
        _scan_node_of(plan),
        "Index Only Scan",
        "premise: the comparison reads the table through the index",
    )

    with pgc_conn.cursor() as cur:
        cur.execute("SET enable_indexscan = off")
        cur.execute("SET enable_bitmapscan = off")
        cur.execute("SELECT count(*), coalesce(sum(id), 0) FROM pamidx WHERE id > 0")
        via_seq = cur.fetchone()

    expect.num(
        1 if (via_index is not None and via_seq is not None) else 0,
        1,
        "premise: both sides of the comparison returned a value",
    )
    # The SUM, not just the count: a group read twice cancelling a group skipped
    # leaves the count right and the sum wrong.
    # FAIL CLOSED, same reason as the shell twin: if the build errored both
    # fetches return None and [None] == [None] would report PASS on a broken
    # tree. Distinct sentinels cannot collide.
    expect.rows(
        [via_index if via_index is not None else ("the index read returned nothing",)],
        [via_seq if via_seq is not None else ("the sequential read returned nothing",)],
        "a parallel index build indexes every row of the table",
    )
