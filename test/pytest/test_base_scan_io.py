"""A base scan must not be priced from sibling projection pages.

Projections share the relation's main fork. The planner's page count is
smgrnblocks of that file, so a scan of the BASE storage is charged for
every projection stored beside it.

This file asserts the PLANNER ratio, not a runtime. Independent of
test/base_scan_io.sh: same public seam (EXPLAIN cost of a base scan before
and after a sibling projection lands), own fixture, own observations.
Assertion names match the shell suite so the two can be compared by name,
not by importing each other.
"""


def _nodes(plan):
    stack = [plan[0]["Plan"]]
    while stack:
        node = stack.pop(0)
        yield node
        stack.extend(node.get("Plans") or ())


def _custom_scan(plan):
    for node in _nodes(plan):
        if node.get("Node Type") == "Custom Scan":
            return node
    return None


def _plan(conn, sql):
    with conn.cursor() as cur:
        cur.execute("SET max_parallel_workers_per_gather = 0")
        cur.execute("SET pgcolumnar.enable_ungrouped_vector_agg = off")
        cur.execute("SET pgcolumnar.enable_group_vectorization = off")
        cur.execute("SET jit = off")
        cur.execute("SET seq_page_cost = 2000")
        cur.execute("SET cpu_tuple_cost = 0")
        cur.execute("SET cpu_operator_cost = 0")
        cur.execute("SET cpu_index_tuple_cost = 0")
        cur.execute("SET pgcolumnar.enable_projection_scan = off")
        cur.execute("EXPLAIN (FORMAT JSON, COSTS ON) " + sql)
        return cur.fetchone()[0]


def test_base_scan_io(pgc_conn, expect):
    n = 30000
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE bpages (rid int, body text) USING pgcolumnar")
        cur.execute(
            "SELECT pgcolumnar.set_options('bpages', stripe_row_limit => 1500, "
            "chunk_group_row_limit => 500)"
        )
        # Compressible payload, independent of the shell twin: different
        # table, N, stripe, column names, and repeat length.
        cur.execute(
            f"INSERT INTO bpages SELECT rid, repeat('q', 1000) "
            f"FROM generate_series(1, {n}) rid ORDER BY md5((rid * 2)::text)"
        )
        cur.execute("ANALYZE bpages")
        cur.execute("SELECT count(*) FROM bpages")
        expect.num(
            cur.fetchone()[0], n, "premise: the table holds every inserted row"
        )

    sql = "SELECT rid, body FROM bpages"
    before = _plan(pgc_conn, sql)
    node = _custom_scan(before)
    expect.text(
        "Custom Scan" if node is not None else (before[0]["Plan"].get("Node Type") or "none"),
        "Custom Scan",
        "premise: the plan is a base columnar scan",
    )
    expect.text(
        (node or {}).get("Columnar Projection") or "none",
        "none",
        "premise: the base scan does not name a covering projection",
    )
    before_run = node["Total Cost"] - node["Startup Cost"]
    expect.text(
        "yes" if before_run > 0 else "no",
        "yes",
        "premise: the base scan has a positive run cost",
    )

    with pgc_conn.cursor() as cur:
        cur.execute("SELECT pg_relation_size('bpages')")
        before_bytes = cur.fetchone()[0]
        cur.execute(
            "SELECT pgcolumnar.add_projection('bpages', 'onrid', "
            "ARRAY['rid','body'], ARRAY['rid'])"
        )
        cur.execute(
            "SELECT count(*) FROM pgcolumnar.projection_declaration "
            "WHERE rel = 'bpages'::regclass AND name = 'onrid'"
        )
        expect.num(
            cur.fetchone()[0],
            1,
            "premise: a covering projection exists",
        )
        cur.execute("SELECT pg_relation_size('bpages')")
        after_bytes = cur.fetchone()[0]

    expect.text(
        "grew" if before_bytes > 0 and after_bytes > before_bytes * 1.3
        else f"stayed before={before_bytes} after={after_bytes}",
        "grew",
        "premise: adding the projection enlarged the relation file",
    )

    after = _plan(pgc_conn, sql)
    after_node = _custom_scan(after)
    expect.text(
        "Custom Scan" if after_node is not None else (after[0]["Plan"].get("Node Type") or "none"),
        "Custom Scan",
        "premise: the later plan is still a base columnar scan",
    )
    expect.text(
        (after_node or {}).get("Columnar Projection") or "none",
        "none",
        "premise: the later plan still does not name a covering projection",
    )
    after_run = after_node["Total Cost"] - after_node["Startup Cost"]
    ratio = (after_run / before_run) if before_run > 0 else 0.0
    print(
        f"-- before_run={before_run} after_run={after_run} ratio={ratio:.3f}"
    )
    print(f"-- before_bytes={before_bytes} after_bytes={after_bytes}")
    expect.text(
        f"inflated ratio={ratio:.3f} (after_run={after_run}, before_run={before_run})"
        if ratio > 1.25 else "stable",
        "stable",
        "a base scan is not priced from sibling projection pages",
    )
