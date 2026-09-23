"""Planning a columnar query uses the options and projection primary keys.

`options_pkey` is `(regclass)` and `projection_pkey` leads with `storage_id`.
The planner looks those catalogs up by exactly those columns, and both scans
passed `InvalidOid`, so a plan sequentially scanned every columnar table's
options row and every projection row.

Independent of `test/catalog_plan_index.sh`: same public seam
(`pg_stat_all_tables` after one filtered scan), own tables, own row counts,
own observations. The measured scan runs on a second connection. A session
that just wrote can take a different catalog path; this arm is about the
session that only plans and reads.

`pg_stat_reset()` is database-wide. Tests run serially within a worker, so
nothing else is counting during this test, and this file must not be run
concurrently with another that reads statistics.
"""

import psycopg

ROWS = 1200
# sum(1..1200)
FULL_SUM = ROWS * (ROWS + 1) // 2


def _stats(conn, relname):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT coalesce(idx_scan,0), coalesce(seq_scan,0) "
            "FROM pg_stat_all_tables "
            "WHERE schemaname = 'pgcolumnar' AND relname = %s",
            (relname,),
        )
        row = cur.fetchone()
    if row is None:
        return 0, 0
    return int(row[0]), int(row[1])


def test_catalog_plan_index(pgc_cluster, pgc_conn, expect):
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE side_m (n bigint) USING pgcolumnar")
        cur.execute("CREATE TABLE side_n (n bigint) USING pgcolumnar")
        cur.execute("CREATE TABLE side_o (n bigint) USING pgcolumnar")
        cur.execute("INSERT INTO side_m SELECT g FROM generate_series(1,17) g")
        cur.execute("INSERT INTO side_n SELECT g FROM generate_series(1,19) g")
        cur.execute("INSERT INTO side_o SELECT g FROM generate_series(1,23) g")
        cur.execute("CREATE TABLE planner_opts (n bigint) USING pgcolumnar")
        cur.execute(
            f"INSERT INTO planner_opts SELECT g FROM generate_series(1,{ROWS}) g"
        )
        cur.execute("SELECT count(*) FROM planner_opts")
        expect.num(
            cur.fetchone()[0],
            ROWS,
            "premise: the measured table holds its rows",
        )
        cur.execute("SELECT current_schema()")
        schema = cur.fetchone()[0]
        cur.execute("SELECT pg_stat_reset()")

    reader = psycopg.connect(pgc_cluster.dsn(), autocommit=True)
    try:
        with reader.cursor() as cur:
            cur.execute(f'SET search_path TO "{schema}", public')
            cur.execute("SELECT sum(n) FROM planner_opts WHERE n >= 1")
            scanned = cur.fetchone()[0]
            cur.execute("SELECT pg_stat_force_next_flush()")
    finally:
        reader.close()

    expect.num(
        scanned,
        FULL_SUM,
        "premise: the filtered scan returned every row",
    )

    opt_idx, opt_seq = _stats(pgc_conn, "options")
    prj_idx, prj_seq = _stats(pgc_conn, "projection")
    print(
        f"-- options idx_scan={opt_idx} seq_scan={opt_seq} "
        f"projection idx_scan={prj_idx} seq_scan={prj_seq}"
    )
    expect.at_least(
        opt_idx,
        1,
        "planning probed pgcolumnar.options through options_pkey",
    )
    expect.num(
        opt_seq,
        0,
        "planning did not sequentially scan pgcolumnar.options",
    )
    expect.at_least(
        prj_idx,
        1,
        "planning probed pgcolumnar.projection through projection_pkey",
    )
    expect.num(
        prj_seq,
        0,
        "planning did not sequentially scan pgcolumnar.projection",
    )
