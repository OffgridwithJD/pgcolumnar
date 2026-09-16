"""Index-fetch I/O is one read per column. The scan path coalesces adjacent
chunk ranges. Independent of test/native_fetch_coalesce.sh: same public seam,
own fixture, own observations. Assertion names match the shell suite.
"""


NCOLS = 12
ROWS = 4500
STRIPE = 1500
TARGET_ID = 7


def _scan_node(plan):
    stack = [plan[0]["Plan"]]
    while stack:
        node = stack.pop(0)
        t = node["Node Type"]
        if t in (
            "Index Scan",
            "Index Only Scan",
            "Bitmap Heap Scan",
            "Custom Scan",
            "Seq Scan",
        ):
            return t
        stack.extend(node.get("Plans", ()))
    return ""


def _buffer_touches(plan):
    """Sum Shared Hit + Shared Read walking the JSON plan.

    FORMAT JSON, not the text Buffers: line the shell suite parses. The two
    harnesses must not share an observer.
    """
    n = 0

    def walk(obj):
        nonlocal n
        if isinstance(obj, dict):
            hit = obj.get("Shared Hit Blocks")
            rd = obj.get("Shared Read Blocks")
            if hit is not None:
                n += int(hit)
            if rd is not None:
                n += int(rd)
            for v in obj.values():
                walk(v)
        elif isinstance(obj, list):
            for v in obj:
                walk(v)

    walk(plan)
    return n


def _exec_buffer_touches(plan):
    """Executor pins only. Planning hits grow with the target list and are not
    fetch I/O; walking the whole JSON would count them.
    """
    return _buffer_touches(plan[0]["Plan"])


def _force(cur):
    cur.execute("SET max_parallel_workers_per_gather=0")
    cur.execute("SET enable_seqscan=off")
    cur.execute("SET enable_bitmapscan=off")
    cur.execute("SET pgcolumnar.enable_custom_scan=off")
    cur.execute("SET pgcolumnar.enable_index_fetch_penalty=off")


def _explain_buffers(cur, sql):
    _force(cur)
    cur.execute("EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, FORMAT JSON) " + sql)
    cur.fetchone()
    cur.execute("EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, FORMAT JSON) " + sql)
    return _exec_buffer_touches(cur.fetchone()[0])


def test_native_fetch_coalesce(pgc_conn, expect):
    cols = ", ".join(f"c{i:02d} int" for i in range(NCOLS))
    ins = ", ".join(f"g + {i}*100" for i in range(NCOLS))
    sel_wide = ", ".join(f"c{i:02d}" for i in range(NCOLS))
    with pgc_conn.cursor() as cur:
        cur.execute(f"CREATE TABLE nfc (id int, {cols}) USING pgcolumnar")
        cur.execute(
            "SELECT pgcolumnar.set_options('nfc', stripe_row_limit => %s, "
            "chunk_group_row_limit => 500, compression => 'none')",
            (STRIPE,),
        )
        cur.execute(
            f"INSERT INTO nfc SELECT g, {ins} FROM generate_series(1, %s) g",
            (ROWS,),
        )
        cur.execute("CREATE INDEX nfc_id ON nfc (id)")
        cur.execute("ANALYZE nfc")
        _force(cur)
        cur.execute(
            f"EXPLAIN (FORMAT JSON, COSTS OFF) SELECT {sel_wide} FROM nfc "
            f"WHERE id = {TARGET_ID}"
        )
        plan = cur.fetchone()[0]
    expect.text(
        _scan_node(plan),
        "Index Scan",
        "premise: a point lookup uses the index",
    )

    with pgc_conn.cursor() as cur:
        _force(cur)
        cur.execute(f"SELECT {sel_wide} FROM nfc WHERE id = {TARGET_ID}")
        got = cur.fetchone()
    want = tuple(TARGET_ID + i * 100 for i in range(NCOLS))
    expect.rows(
        [got],
        [want],
        "premise: the wide fetch returns the projected values",
    )

    with pgc_conn.cursor() as cur:
        narrow = _explain_buffers(cur, f"SELECT c00 FROM nfc WHERE id = {TARGET_ID}")
        wide = _explain_buffers(
            cur, f"SELECT {sel_wide} FROM nfc WHERE id = {TARGET_ID}"
        )
    expect.num(
        1 if narrow > 0 else 0,
        1,
        "premise: fetching one projected column touched a measurable number of buffers",
    )
    expect.num(
        1 if wide > 0 else 0,
        1,
        "premise: fetching every projected column touched a measurable number of buffers",
    )
    extra_cols = NCOLS - 1
    expect.num(
        1 if wide <= narrow + extra_cols else 0,
        1,
        "a wide index fetch does not pin once per column",
    )
