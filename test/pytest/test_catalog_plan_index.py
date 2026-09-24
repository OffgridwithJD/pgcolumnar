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

    # THE FOUR ARMS THAT STOOD HERE ASSERTED THE ACCESS PATH (#1217): options
    # and projection each had to show idx_scan >= 1 and seq_scan == 0. This
    # fixture calls neither set_options nor add_projection, so both catalogs are
    # EMPTY, the size check declines both probes, and those arms fail against a
    # build that made planning strictly cheaper. A guard that fires on correct
    # code gets switched off. Replaced below by the work, in its own test, on a
    # database private to it.

    # ---- and pgcolumnar.storage, through storage_pkey (#1237) --------------
    #
    # Two readers key on storage_id and both passed InvalidOid, so both scanned
    # the catalog sequentially on the one column storage_pkey is a UNIQUE btree
    # over: PgColumnarGetSortedInfo at PLANNING (via pgcolumnar_sorted_pathkeys)
    # and PgColumnarCheckNativeFormatVersion once per relation scanned at
    # EXECUTION.
    #
    # TWO SHAPES BECAUSE THEY REACH DIFFERENT CODE. A no-qual count never
    # reaches the row-group-limit lookup, so its only storage access is the
    # format-version one and seq_scan == 0 reads cleanly. The join is measured
    # on idx_scan instead: its remaining sequential scan comes from
    # pgcolumnar_written_stripe_row_limit, which keys on relation_oid and has
    # no index to name -- that is #1210 and #1211, not this change. Measured
    # unfixed, join idx=0 seq=5; fixed, idx=4 seq=1, and the 1 is that lookup.
    #
    # Its own cursor and its own reader connection, like the arms above: the
    # session that wrote the rows must not be the session being measured.
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE planner_join (n bigint) USING pgcolumnar")
        cur.execute(
            f"INSERT INTO planner_join SELECT g FROM generate_series(1,{ROWS}) g"
        )
        cur.execute("SELECT pg_stat_reset()")

    reader = psycopg.connect(pgc_cluster.dsn(), autocommit=True)
    try:
        with reader.cursor() as cur:
            cur.execute(f'SET search_path TO "{schema}", public')
            cur.execute("SELECT count(*) FROM planner_opts")
            cur.execute("SELECT pg_stat_force_next_flush()")
    finally:
        reader.close()

    st_idx, st_seq = _stats(pgc_conn, "storage")
    print(f"-- storage after count(*) idx_scan={st_idx} seq_scan={st_seq}")
    expect.at_least(
        st_idx + st_seq,
        1,
        "premise: a no-qual count over a columnar table touched storage at all",
    )
    expect.num(
        st_seq,
        0,
        "a no-qual count did not sequentially scan pgcolumnar.storage",
    )

    with pgc_conn.cursor() as cur:
        cur.execute("SELECT pg_stat_reset()")

    reader = psycopg.connect(pgc_cluster.dsn(), autocommit=True)
    try:
        with reader.cursor() as cur:
            cur.execute(f'SET search_path TO "{schema}", public')
            cur.execute(
                "SELECT count(*) FROM planner_opts a "
                "JOIN planner_join b ON a.n = b.n WHERE a.n >= 1"
            )
            cur.execute("SELECT pg_stat_force_next_flush()")
    finally:
        reader.close()

    sj_idx, sj_seq = _stats(pgc_conn, "storage")
    print(f"-- storage after a two-relation join idx_scan={sj_idx} seq_scan={sj_seq}")
    expect.at_least(
        sj_idx + sj_seq,
        2,
        "premise: the join reached storage more than once",
    )
    expect.at_least(
        sj_idx,
        2,
        "planning a join probed pgcolumnar.storage through storage_pkey",
    )


PLAN_CATS = ("options", "projection")


def _plan_work(conn, n, min_blocks=None):
    """Buffers `options` and `projection` serve while one query is planned `n` times.

    `n` plans rather than one, because the effect is per-plan: six buffers is too
    small a base to divide into, and fifty makes it three hundred against
    nothing.
    """
    with conn.cursor() as cur:
        cur.execute("SELECT pg_stat_force_next_flush()")
        cur.execute("SELECT pg_stat_reset()")
        if min_blocks is not None:
            cur.execute(f"SET pgcolumnar.index_min_blocks = {min_blocks}")
        for _ in range(n):
            cur.execute("EXPLAIN (COSTS OFF) SELECT count(*) FROM pc_main WHERE v > 3")
        cur.execute("RESET pgcolumnar.index_min_blocks")
        cur.execute("SELECT pg_stat_force_next_flush()")
        cur.execute(
            "SELECT relname, "
            "  coalesce(heap_blks_read,0) + coalesce(heap_blks_hit,0) "
            "+ coalesce(idx_blks_read,0) + coalesce(idx_blks_hit,0) "
            "FROM pg_statio_all_tables "
            "WHERE schemaname = 'pgcolumnar' AND relname = ANY(%s)",
            (list(PLAN_CATS),),
        )
        per = {r[0]: int(r[1]) for r in cur.fetchall()}
    return sum(per.values()), per


def test_planning_costs_nothing_on_the_default_configuration(pgc_own_db, expect):
    """`options` and `projection` are empty unless you ask for them, and that is the default.

    A row reaches `pgcolumnar.options` only when `set_options` is called and
    `pgcolumnar.projection` only when a projection is added. An installation
    doing neither has both empty, the heap the probe replaces is zero pages, and
    the scan it replaces is literally free -- so the probe cannot win however
    large the database grows. There is no crossover to be above. Measured on
    main before the fix: six index buffers per plan, flat at 10, 200 and 1000
    columnar tables alike.

    ON A PRIVATE DATABASE, because `pgc_conn` gives a private schema and these
    catalogs are per database. Run inside the corpus with a shared one, other
    files have already populated them and the premise below is simply false.
    """
    conn = pgc_own_db
    with conn.cursor() as cur:
        for t in ("pc_side_a", "pc_side_b", "pc_main"):
            cur.execute(f"CREATE TABLE {t} (n bigint, v bigint) USING pgcolumnar")
            cur.execute(f"INSERT INTO {t} SELECT g, g % 11 FROM generate_series(1,120) g")
        cur.execute("SELECT count(*) FROM pc_main")
        expect.num(cur.fetchone()[0], 120, "premise: the measured table holds its rows")
        cur.execute(
            "SELECT (SELECT count(*) FROM pgcolumnar.options)"
            "     + (SELECT count(*) FROM pgcolumnar.projection)"
            "     + pg_relation_size('pgcolumnar.options') / 8192"
            "     + pg_relation_size('pgcolumnar.projection') / 8192"
        )
        expect.num(
            cur.fetchone()[0],
            0,
            "premise: this fixture is the default configuration, both catalogs empty",
        )

    default, per = _plan_work(conn, 50)
    probe, _ = _plan_work(conn, 50, 0)
    print(f"-- 50 plans: default={default} probe-always={probe}   by catalog {per}")

    # AN ARM EXPECTING ZERO IS OWED A PREMISE THAT ANYTHING WAS MEASURED: a run
    # that planned nothing reports 0 exactly as loudly as one that planned fifty
    # times for free.
    expect.at_least(
        probe, 50, "premise: forcing the probe costs something, so the instrument measured"
    )
    expect.at_least(
        probe - default, 1, "planning costs less than probing both catalogs would"
    )
    expect.num(default, 0, "and touches the empty catalogs not at all")


def test_planning_still_probes_a_populated_catalog(pgc_own_db, expect):
    """Declining everything would pass the test above, so require the probe where it pays.

    THE BULK OF THE PROJECTIONS GO ON A TABLE THAT IS NOT THE MEASURED ONE. A
    probe's cost scales with the rows MATCHING ITS KEY, not with the size of the
    catalog: putting them all on the measured table makes every row match, and
    the shell twin's first draft read the probe LOSING at seven pages for
    exactly that reason. The shape this change is about is a catalog made large
    by OTHER tables' rows.
    """
    conn = pgc_own_db
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE pc_bulk (n bigint, v bigint) USING pgcolumnar")
        cur.execute("INSERT INTO pc_bulk SELECT g, g FROM generate_series(1,60) g")
        cur.execute("CREATE TABLE pc_main (n bigint, v bigint) USING pgcolumnar")
        cur.execute("INSERT INTO pc_main SELECT g, g % 11 FROM generate_series(1,120) g")
        for i in range(260):
            cur.execute(
                "SELECT pgcolumnar.add_projection('pc_bulk', %s, ARRAY['n'], ARRAY['n'])",
                (f"bp{i}",),
            )
        cur.execute("SELECT pgcolumnar.add_projection('pc_main','own',ARRAY['n'],ARRAY['n'])")

        cur.execute("SHOW pgcolumnar.index_min_blocks")
        threshold = int(cur.fetchone()[0])
        cur.execute("SELECT pg_relation_size('pgcolumnar.projection') / 8192")
        pages = int(cur.fetchone()[0])
        cur.execute("SELECT count(*) FROM pgcolumnar.projection")
        total = cur.fetchone()[0]
        cur.execute(
            "SELECT count(*) FROM pgcolumnar.projection p "
            "JOIN pgcolumnar.storage s USING (storage_id) "
            "WHERE s.relation_oid = 'pc_main'::regclass::oid"
        )
        own = cur.fetchone()[0]
    print(f"-- projection {total} rows, {pages} pages, threshold {threshold}; "
          f"the measured table owns {own}")

    # Below the threshold the default declines and reads the heap, which is what
    # the other reading does too -- both come back equal and the arm reports no
    # difference. That reads as "the check is gone" and means "the fixture is
    # too small". Derived from the setting rather than typed.
    expect.at_least(
        pages - threshold, 1,
        "premise: projection is larger than the threshold, so the two paths differ",
    )
    # A SHARE, NOT A COUNT: add_projection writes more than one row per
    # projection, which is a fact about the function and not about the claim.
    expect.at_least(
        total - own * 10, 1,
        "premise: the measured table owns a small share of that catalog",
    )

    default, _ = _plan_work(conn, 50)
    whole, _ = _plan_work(conn, 50, 2147483647)
    print(f"-- 50 plans, projection populated: default={default} read-whole={whole}")
    expect.at_least(whole, 50, "premise: reading the populated catalog whole costs something")
    expect.at_least(
        whole - default, 1,
        "with the catalog populated, planning costs less than reading it whole",
    )
