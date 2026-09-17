"""A covering projection scan must not be priced at half the base.

PgColumnarSetRelPathlist offers a covering-projection path by taking the
base custom-scan run cost and multiplying by 0.5. That constant does not
depend on the restriction, so two ranges on the sort key are quoted at
the same fraction of the base.

This file asserts the PLANNER ratio, not a runtime. Independent of
test/projection_scan_cost.sh: same public seam (EXPLAIN of a columnar
scan with the projection-scan GUC on and off), own fixture, own
observations. Assertion names match the shell suite so the two can be
compared by name, not by importing each other.
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


def _plan(conn, sql, projection_scan):
    with conn.cursor() as cur:
        cur.execute("SET max_parallel_workers_per_gather = 0")
        cur.execute("SET pgcolumnar.enable_ungrouped_vector_agg = off")
        cur.execute("SET pgcolumnar.enable_group_vectorization = off")
        cur.execute("SET jit = off")
        cur.execute(
            "SET pgcolumnar.enable_projection_scan = "
            + ("on" if projection_scan else "off")
        )
        cur.execute("EXPLAIN (FORMAT JSON, COSTS ON) " + sql)
        return cur.fetchone()[0]


def test_projection_scan_cost(pgc_conn, expect):
    n = 24000
    tight_hi = 1800
    loose_hi = 12000
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE pscost (k int, blob text) USING pgcolumnar")
        cur.execute(
            "SELECT pgcolumnar.set_options('pscost', stripe_row_limit => 1200, "
            "chunk_group_row_limit => 400)"
        )
        # Scrambled insert order so the base layout cannot prune on k.
        # Different N, stripe, payload, and bounds from the shell twin.
        cur.execute(
            f"INSERT INTO pscost SELECT k, md5(k::text) FROM generate_series(1, {n}) k "
            "ORDER BY md5((k + 17)::text)"
        )
        cur.execute(
            "SELECT pgcolumnar.add_projection('pscost', 'onk', ARRAY['k'], ARRAY['k'])"
        )
        cur.execute("ANALYZE pscost")
        cur.execute("SELECT count(*) FROM pscost")
        expect.num(cur.fetchone()[0], n, "premise: the table holds every inserted row")
        cur.execute(
            "SELECT count(*) FROM pgcolumnar.projection_declaration "
            "WHERE rel = 'pscost'::regclass AND name = 'onk'"
        )
        expect.num(cur.fetchone()[0], 1, "premise: a covering projection exists")

    sql_tight = f"SELECT k FROM pscost WHERE k BETWEEN 1 AND {tight_hi}"
    sql_loose = f"SELECT k FROM pscost WHERE k BETWEEN 1 AND {loose_hi}"

    tight_proj = _plan(pgc_conn, sql_tight, True)
    loose_proj = _plan(pgc_conn, sql_loose, True)
    tight_base = _plan(pgc_conn, sql_tight, False)
    loose_base = _plan(pgc_conn, sql_loose, False)

    tp = _custom_scan(tight_proj)
    lp = _custom_scan(loose_proj)
    tb = _custom_scan(tight_base)
    lb = _custom_scan(loose_base)

    expect.text(
        (tp or {}).get("Columnar Projection") or "none",
        "onk",
        "premise: the tight plan uses the covering projection",
    )
    expect.text(
        (lp or {}).get("Columnar Projection") or "none",
        "onk",
        "premise: the loose plan uses the covering projection",
    )
    expect.text(
        "none" if tb is None or "Columnar Projection" not in tb else tb["Columnar Projection"],
        "none",
        "premise: without the projection scan, the tight plan is a base columnar scan",
    )
    expect.text(
        "none" if lb is None or "Columnar Projection" not in lb else lb["Columnar Projection"],
        "none",
        "premise: without the projection scan, the loose plan is a base columnar scan",
    )

    t_proj_run = tp["Total Cost"] - tp["Startup Cost"]
    l_proj_run = lp["Total Cost"] - lp["Startup Cost"]
    t_base_run = tb["Total Cost"] - tb["Startup Cost"]
    l_base_run = lb["Total Cost"] - lb["Startup Cost"]
    expect.text(
        "yes" if min(t_proj_run, l_proj_run, t_base_run, l_base_run) > 0 else "no",
        "yes",
        "premise: every compared scan has a positive run cost",
    )

    t_ratio = t_proj_run / t_base_run
    l_ratio = l_proj_run / l_base_run
    print(
        f"-- tight proj_run={t_proj_run} base_run={t_base_run} ratio={t_ratio:.3f}"
    )
    print(
        f"-- loose proj_run={l_proj_run} base_run={l_base_run} ratio={l_ratio:.3f}"
    )

    expect.text(
        "tighter" if t_ratio < l_ratio else "not",
        "tighter",
        "a tight covering projection is cheaper relative to the base than a loose one",
    )
    both_halved = (
        0.45 < t_ratio < 0.55 and 0.45 < l_ratio < 0.55
    )
    expect.text(
        "both-halved" if both_halved else "scaled",
        "scaled",
        "tight and loose covering scans are not both priced at half the base",
    )
