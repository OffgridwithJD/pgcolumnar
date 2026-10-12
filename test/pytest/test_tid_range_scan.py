"""A ctid range reads only the row groups that hold it (TID range scans).

Before this, `WHERE ctid >= '(600000,0)'` on a 10M-row table matched 0 rows and
still read all 67 row groups (#1294): the access method had no scan_set_tidrange,
so the range was a per-row filter over the whole table.

THE ORACLE is the same query with `enable_tidscan = off`, which is that per-row
filter. THE COST is the table's own blocks from pg_statio, read under a decode the
zone maps cannot answer (`max(body || 'y')`: an unfiltered max is metadata-only).

The bounds that matter are the ones no row has. A block holds 291 rows
(MaxHeapTuplesPerPage), offsets 1..291, but a bound may say offset 0 or anything up
to 65535, and the executor makes `ctid < '(B,0)'` into an upper bound of
(B-1, 65535). Read without clamping, offset 400 named a row in the next block.

ON A PRIVATE DATABASE (`pgc_own_db`): `pg_stat_reset()` resets the database's
counters, and nothing else may be counting there. Independent of
`test/tid_range_scan.sh`: its own columns, row count, group size, and ranges.
"""

ROWS = 260000
GROUP = 7000


def _one(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        row = cur.fetchone()
    return row[0] if row else None


def _plan(conn, sql):
    with conn.cursor() as cur:
        cur.execute("EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) " + sql)
        return "\n".join(r[0] for r in cur.fetchall())


def _digest(conn, where, tidscan):
    with conn.cursor() as cur:
        cur.execute(f"SET enable_tidscan = {tidscan}")
        cur.execute("SELECT count(*), md5(string_agg(k::text || body, ',' ORDER BY k))"
                    f" FROM tids WHERE {where}")
        n, h = cur.fetchone()
        cur.execute("RESET enable_tidscan")
    return f"{n}|{h}"


def _blocks(conn, where):
    """Blocks of `tids` read while a forced decode over `where` ran."""
    with conn.cursor() as cur:
        cur.execute("SELECT pg_stat_force_next_flush()")
        cur.execute("SELECT pg_stat_reset()")
        cur.execute(f"SELECT count(*), max(body || 'y') FROM tids WHERE {where}")
        cur.fetchall()
        cur.execute("SELECT pg_stat_force_next_flush()")
        cur.execute("SELECT coalesce(heap_blks_read,0) + coalesce(heap_blks_hit,0)"
                    " FROM pg_statio_user_tables WHERE relname = 'tids'")
        row = cur.fetchone()
    return int(row[0]) if row else None


def _tid(conn, k):
    return _one(conn, f"SELECT ctid FROM tids WHERE k = {k}")


def _fixture(conn, expect):
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE tids (k bigint, body text) USING pgcolumnar")
        cur.execute(f"SELECT pgcolumnar.set_options('tids', stripe_row_limit => {GROUP})")
        cur.execute(f"INSERT INTO tids SELECT g, repeat(md5((g * 7)::text), 2)"
                    f" FROM generate_series(1, {ROWS}) g")
        cur.execute("ANALYZE tids")
    expect.num(_one(conn, "SELECT count(*) FROM tids"), ROWS, "premise: the table holds every row")
    groups = _one(conn, "SELECT count(*) FROM pgcolumnar.row_group"
                        " WHERE storage_id = pgcolumnar.get_storage_id('tids')")
    expect.at_least(groups, 30, "premise: the table has many row groups, so skipping can show")


def test_a_ctid_range_reads_only_its_row_groups(pgc_own_db, expect):
    conn = pgc_own_db
    _fixture(conn, expect)

    tail, a, b, last = _tid(conn, 246001), _tid(conn, 61234), _tid(conn, 98765), _tid(conn, ROWS)
    blk = int(a.strip("()").split(",")[0])
    print(f"-- ctids: 246001={tail} 61234={a} 98765={b} {ROWS}={last}")

    expect.text("yes" if "Tid Range Scan" in _plan(conn, f"SELECT k FROM tids WHERE ctid >= '{tail}'")
                else "no", "yes", "premise: a ctid range plans a TID range scan, so the arms below exercise it")

    ranges = [
        f"ctid >= '{tail}'",
        f"ctid > '{a}' AND ctid < '{b}'",
        f"ctid <= '{a}'",
        f"ctid >= '{last}'",
        f"ctid > '{last}'",
        "ctid < '(0,1)'",
        f"ctid < '({blk},0)'",
        f"ctid >= '({blk},0)' AND ctid <= '({blk + 3},0)'",
        f"ctid > '({blk},291)'",
        f"ctid >= '({blk},500)' AND ctid <= '({blk + 1},700)'",
        f"ctid <= '({blk},65535)'",
    ]
    for where in ranges:
        expect.text(_digest(conn, where, "on"), _digest(conn, where, "off"),
                    f"a ctid range returns what the per-row filter returns: {where}")

    # Rescanned with new bounds per outer row: a reader built for one range must
    # not answer the next. The plan premise is taken on the very query compared.
    lat = ("SELECT string_agg(r.i || ':' || x.n || ':' || x.h, ' ' ORDER BY r.i)"
           f" FROM (VALUES (1, '{a}'::tid, '{b}'::tid), (2, '{tail}'::tid, '{last}'::tid),"
           f"              (3, '{b}'::tid, '{a}'::tid), (4, '(0,0)'::tid, '{a}'::tid)) r(i, lo, hi),"
           " LATERAL (SELECT count(*) n, md5(string_agg(k::text, ',' ORDER BY k)) h FROM tids"
           "          WHERE ctid >= r.lo AND ctid <= r.hi) x")
    expect.text("yes" if "Tid Range Scan" in _plan(conn, lat) else "no", "yes",
                "premise: the per-range join rescans a TID range scan")
    with conn.cursor() as cur:
        on = _one(conn, lat)
        cur.execute("SET enable_tidscan = off")
        off = _one(conn, lat)
        cur.execute("RESET enable_tidscan")
    expect.text(on, off, "a TID range scan rescanned with new bounds returns what the filter returns")

    whole = _blocks(conn, "true")
    part = _blocks(conn, f"ctid >= '{tail}'")
    print(f"-- blocks: whole {whole}, tail {part}")
    expect.at_least(whole, 100, "premise: reading the whole table reads its blocks")
    expect.at_least(part, 1, "premise: the tail range read the table at all")
    # The margin is whole - 5 * part: positive passes, and a failure reports by how much.
    expect.at_least(whole - 5 * part, 1,
                    "a ctid range over the last row groups reads under a fifth of the table")

    # Deletes inside the range, then compaction, which gives the surviving rows of
    # the thinned group new, higher row numbers.
    before = _tid(conn, 249000)
    with conn.cursor() as cur:
        cur.execute("DELETE FROM tids WHERE k BETWEEN 250500 AND 251900")
    expect.text(_digest(conn, f"ctid >= '{tail}'", "on"), _digest(conn, f"ctid >= '{tail}'", "off"),
                "and rows deleted inside the range stay deleted")
    with conn.cursor() as cur:
        cur.execute("SET enable_tidscan = off")
        left = _one(conn, f"SELECT count(*) FROM tids WHERE ctid >= '{tail}'")
        cur.execute("RESET enable_tidscan")
    # 246001..260000 is 14,000 rows; the delete took 1,401 of them.
    expect.num(left, 14000 - 1401, "premise: the delete removed rows from the range")
    expect.num(_one(conn, "SELECT pgcolumnar.compact_rewrite('tids', 0.1, 0)"), 1,
               "premise: compaction rewrote the group the delete thinned")
    moved = _tid(conn, 249000)
    expect.text("moved" if moved != before else f"kept {moved}", "moved",
                "premise: compaction gave the surviving rows new addresses")
    for where in (f"ctid >= '{tail}'", f"ctid >= '{moved}'", f"ctid >= '{a}' AND ctid <= '{moved}'"):
        expect.text(_digest(conn, where, "on"), _digest(conn, where, "off"),
                    f"after compaction a ctid range returns what the filter returns: {where}")


def test_a_parallel_tid_range_scan_returns_what_the_filter_returns(pgc_own_db, expect):
    conn = pgc_own_db
    major = int(_one(conn, "SHOW server_version_num")) // 10000
    if major < 19:
        expect.cannot_run(
            "UNSUPPORTED_MAJOR",
            f"parallel TID range scans arrived in PostgreSQL 19; this server is {major}",
            name="a parallel TID range scan returns what the filter returns")
        return
    _fixture(conn, expect)
    lo, hi = _tid(conn, 40001), _tid(conn, 222222)
    where = f"ctid >= '{lo}' AND ctid <= '{hi}'"
    want = _digest(conn, where, "off")
    with conn.cursor() as cur:
        # The custom scan off: with parallelism cheap the planner prefers a parallel
        # custom scan that filters ctid per row, and this is about the AM's path.
        for s in ("parallel_setup_cost = 0", "parallel_tuple_cost = 0",
                  "min_parallel_table_scan_size = 0", "max_parallel_workers_per_gather = 2",
                  "parallel_leader_participation = off", "pgcolumnar.enable_custom_scan = off"):
            cur.execute("SET " + s)
    q = ("SELECT count(*) || '|' || md5(string_agg(k::text || body, ',' ORDER BY k))"
         f" FROM tids WHERE {where}")
    plan = _plan(conn, q)
    launched = [ln.strip() for ln in plan.splitlines() if "Workers Launched" in ln]
    expect.text(f"{'Parallel Tid Range Scan' in plan}|{launched}",
                "True|['Workers Launched: 2']",
                "premise: the range runs as a parallel TID range scan with two workers")
    expect.text(_one(conn, q), want, "a parallel TID range scan returns what the filter returns")
