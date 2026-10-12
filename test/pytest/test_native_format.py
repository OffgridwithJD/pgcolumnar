"""The native format stamp is a RANGE, and the first write by a newer build raises it (#1137).

1.0-alpha5 writes chunks with no validity bitmap (#1130), which an alpha4 binary
misreads: some rows that hold a value come back NULL. So this build stamps
`pgcolumnar.storage.format_version` 2, and alpha4, which refuses any stamp but 1,
refuses the table at every decode entry point. This build still reads 1.

Each arm drives all four entry points that check the stamp:

    seq scan        PgColumnarBeginReadWithStorage   a non-aggregate SELECT
    aggregate scan  PgColumnarBeginAggScan           count(*)
    group agg scan  PgColumnarBeginGroupAggScan      GROUP BY
    row fetch       pgcolumnar_fetch_row             index scan, custom scan OFF

The custom scan has to be off for the fourth. With it on, the index query is
served by pgcolumnar's own node and never reaches `pgcolumnar_fetch_row`; that
path's check was deleted outright and every arm still passed (measured on the
shell twin).

A partial port of `test/native_format.sh`: the stamp arms and the version pin.
The metapage-version hook and the diverse-type round trip are not ported, and
`test_compare_to_bash.py` declares the pair INCOMPLETE with that reason.
Independent of the shell twin: its own table, row count and key.
"""

import psycopg

ROWS = 1500
# sum(1..1500)
FULL_SUM = ROWS * (ROWS + 1) // 2


def _one(cur, sql):
    cur.execute(sql)
    return cur.fetchone()[0]


def _sqlstate(conn, statements):
    """The SQLSTATE the last statement fails with, or "ok"."""
    try:
        with conn.cursor() as cur:
            for s in statements:
                cur.execute(s)
            if cur.description:
                cur.fetchall()
        return "ok"
    except psycopg.Error as e:
        return e.sqlstate or "?"
    finally:
        # Only what the fetch path SET: RESET ALL would also drop the private
        # search_path pgc_conn gives this test, and every later query would
        # fail 42P01 instead of measuring anything.
        with conn.cursor() as cur:
            for g in ("pgcolumnar.enable_custom_scan", "enable_seqscan",
                      "enable_bitmapscan"):
                cur.execute(f"RESET {g}")


def _four_paths(conn, t):
    return " ".join([
        _sqlstate(conn, [f"SELECT v FROM {t} LIMIT 1"]),
        _sqlstate(conn, [f"SELECT count(*) FROM {t}"]),
        _sqlstate(conn, [f"SELECT k % 5, count(*) FROM {t} GROUP BY 1"]),
        _sqlstate(conn, ["SET pgcolumnar.enable_custom_scan = off",
                         "SET enable_seqscan = off",
                         "SET enable_bitmapscan = off",
                         f"SELECT v FROM {t} WHERE k = 77"]),
    ])


def test_the_format_stamp_is_a_range_and_an_append_raises_it(pgc_conn, expect):
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE stamp_t (k int, v text) USING pgcolumnar")
        cur.execute(f"INSERT INTO stamp_t SELECT g, 'w' || g FROM generate_series(1,{ROWS}) g")
        cur.execute("CREATE INDEX ON stamp_t (k)")
        sid = _one(cur, "SELECT pgcolumnar.get_storage_id('stamp_t')")

    def stamp():
        with pgc_conn.cursor() as cur:
            return _one(cur, f"SELECT format_version FROM pgcolumnar.storage WHERE storage_id = {sid}")

    def set_stamp(v):
        with pgc_conn.cursor() as cur:
            cur.execute(f"UPDATE pgcolumnar.storage SET format_version = {v} WHERE storage_id = {sid}")

    def rows():
        with pgc_conn.cursor() as cur:
            cur.execute("SELECT count(*), sum(k) FROM stamp_t")
            c, s = cur.fetchone()
        return f"{c}|{s}"

    expect.num(stamp(), 2, "native format_version is 2")
    expect.num(stamp(), 2, "premise: the fixture was stamped by this build")

    # What an alpha4 table looks like to this build.
    set_stamp(1)
    expect.text(_four_paths(pgc_conn, "stamp_t"), "ok ok ok ok",
                "a table stamped 1 is read on all four paths")
    expect.text(rows(), f"{ROWS}|{FULL_SUM}", "and returns its rows")
    expect.num(stamp(), 1, "reading a table stamped 1 does not raise its stamp")

    # Appending is what puts bitmap-less chunks in it, so appending moves the stamp.
    with pgc_conn.cursor() as cur:
        cur.execute(f"INSERT INTO stamp_t SELECT g, 'w' || g FROM generate_series({ROWS + 1},{ROWS + 40}) g")
    expect.num(stamp(), 2, "appending to a table stamped 1 raises its stamp")
    total = ROWS + 40
    expect.text(rows(), f"{total}|{total * (total + 1) // 2}",
                "and the table still reads whole")

    # Either side of the range is refused, everywhere, by SQLSTATE. 0A000 is
    # feature_not_supported.
    set_stamp(3)
    expect.text(_four_paths(pgc_conn, "stamp_t"), "0A000 0A000 0A000 0A000",
                "a stamp above this build's is refused on all four paths")
    set_stamp(0)
    expect.text(_four_paths(pgc_conn, "stamp_t"), "0A000 0A000 0A000 0A000",
                "a stamp below MIN_READABLE is refused on all four paths")
    with pgc_conn.cursor() as cur:
        expect.num(_one(cur, "SELECT 1"), 1, "backend survives the range rejections")
