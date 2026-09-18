"""ANALYZE must estimate the row count, not zero (#432, port of analyze_reltuples.sh).

A block was mapped to its row group by comparing the block's logical offset against
the group's `file_offset`, but the block's offset had `COLUMNAR_FIRST_LOGICAL_OFFSET`
subtracted from it while the group's had not. Every block compared two blocks low, so
a table whose only row group starts at the beginning matched no block at all and
`reltuples` came back 0 for 10,000 rows.

Zero is the sharp case and this file is built around it: an estimate that is merely
imprecise costs a plan, an estimate of zero costs the shape of every plan that joins
the table.

**heap is the oracle.** ANALYZE samples, so the columnar estimate is not required to
be exact. It is required to be as close as heap's is on the same data, which at these
sizes is exact.

TWO THINGS THIS PORT ASSERTS THAT THE BASH SUITE DOES NOT.

**The geometry the arm is named after.** `20 stripes: within 5% of actual` sets
`pgcolumnar.stripe_row_limit` and then checks only the estimate. The limit does take
effect today -- measured, 20 row groups with it against 1 without -- but nothing in
that arm would notice if it stopped, and a single-group table also passes a 5% check.
The premise here reads `pgcolumnar.row_group` and fails first if the fixture is not
the shape the name claims.

**That the two access methods hold the same data.** The bash helper builds the
columnar and heap tables from two separate `INSERT`s and compares their estimates. If
one insert silently wrote fewer rows the comparison still runs, against a different
population. A count premise makes that a failure rather than a quiet change of
subject.
"""


def _reltuples(cur, table):
    cur.execute(f"SELECT reltuples::bigint FROM pg_class WHERE oid = '{table}'::regclass")
    return cur.fetchone()[0]


def _rows(cur, table):
    cur.execute(f"SELECT count(*) FROM {table}")
    return cur.fetchone()[0]


def _groups(cur, table):
    cur.execute(
        "SELECT count(*) FROM pgcolumnar.row_group "
        f"WHERE storage_id = pgcolumnar.get_storage_id('{table}')"
    )
    return cur.fetchone()[0]


def _closeness(got, want, tol):
    """-> "close", or how far off, so a failure names the distance like the bash suite."""
    d = abs(got - want)
    return "close" if d <= tol else f"off by {d}"


def _both(cur, expect, lab, n, ddl, ex):
    """Build the same data in both access methods and compare the estimate.

    Separate statements per table, as in the bash suite, so a failure building one
    side cannot stop the other from being built and leave the comparison silently
    one-sided.
    """
    cur.execute(f"DROP TABLE IF EXISTS ar_c; CREATE TABLE ar_c ({ddl}) USING pgcolumnar")
    cur.execute(f"INSERT INTO ar_c SELECT {ex} FROM generate_series(1,{n}) g")
    cur.execute(f"DROP TABLE IF EXISTS ar_h; CREATE TABLE ar_h ({ddl})")
    cur.execute(f"INSERT INTO ar_h SELECT {ex} FROM generate_series(1,{n}) g")
    cur.execute("ANALYZE ar_c")
    cur.execute("ANALYZE ar_h")

    # EXTRA, not in the bash suite: the two sides must hold the same population, or
    # the comparison below is between two different tables.
    expect.num(_rows(cur, "ar_c"), n, f"premise: {lab} loaded every columnar row")
    expect.num(_rows(cur, "ar_h"), n, f"premise: {lab} loaded every heap row")

    c = _reltuples(cur, "ar_c")
    h = _reltuples(cur, "ar_h")

    expect.text("nonzero" if c > 0 else "ZERO", "nonzero",
                f"{lab}: estimate is not zero")
    expect.text(_closeness(c, n, n * 0.05), "close",
                f"{lab}: within 5% of actual (heap says {h})")


def test_analyze_estimates_the_row_count(pgc_conn, expect):
    with pgc_conn.cursor() as cur:
        # A single row group starting at the first logical offset is the case that
        # reported zero; the larger sizes cover the partial shift.
        _both(cur, expect, "10k rows", 10000, "id int, v int", "g, g*2")
        _both(cur, expect, "50k rows", 50000, "id int, v int", "g, g*2")
        _both(cur, expect, "200k rows", 200000, "id int, v int", "g, g*2")
        _both(cur, expect, "text column", 50000, "id int, v text", "g, 'x' || g")

        # Several stripes, so more than one group has to be mapped.
        #
        # RESET AFTERWARDS, which the bash suite gets for free and a port does not.
        # Each `psql_run` there is its own session, so the GUC dies with it. Here one
        # connection carries every arm, and leaving the limit set would silently
        # change the geometry of every table built below it.
        cur.execute("SET pgcolumnar.stripe_row_limit = 1000")
        cur.execute("DROP TABLE IF EXISTS ar_s; CREATE TABLE ar_s (id int, v int) USING pgcolumnar")
        cur.execute("INSERT INTO ar_s SELECT g, g FROM generate_series(1,20000) g")
        cur.execute("ANALYZE ar_s")

        # EXTRA: the arm below is named for a geometry it never checks.
        expect.num(_groups(cur, "ar_s"), 20,
                   "premise: the multi-stripe fixture really has twenty row groups")

        expect.text(_closeness(_reltuples(cur, "ar_s"), 20000, 1000), "close",
                    "20 stripes: within 5% of actual")

        # The estimate has to follow deletes down, not just up.
        cur.execute("DELETE FROM ar_s WHERE id % 2 = 0")
        cur.execute("ANALYZE ar_s")
        expect.text(_closeness(_reltuples(cur, "ar_s"), 10000, 500), "close",
                    "after deleting half, the estimate follows")

        # The sampling quality this mapping exists to protect must survive the fix: a
        # clustered column still has to report its true n_distinct rather than the
        # per-group count, which is what whole-group sampling would give.
        cur.execute("DROP TABLE IF EXISTS ar_n; CREATE TABLE ar_n (id int, k int) USING pgcolumnar")
        cur.execute("INSERT INTO ar_n SELECT g, g / 20 FROM generate_series(1,20000) g")
        cur.execute("ANALYZE ar_n")
        cur.execute("RESET pgcolumnar.stripe_row_limit")

        cur.execute(
            "SELECT CASE WHEN n_distinct < 0 THEN 'ratio' "
            "WHEN n_distinct > 500 THEN 'many' ELSE 'few:' || n_distinct END "
            "FROM pg_stats WHERE tablename = 'ar_n' AND attname = 'k'"
        )
        row = cur.fetchone()
        expect.text(row[0] if row else "no row in pg_stats", "many",
                    "a clustered column still reports many distinct values")
