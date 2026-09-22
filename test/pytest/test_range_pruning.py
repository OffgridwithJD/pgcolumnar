"""A range column prunes on overlap and containment, and under its own collation.

A zone map recorded `minimum` and `maximum` only. Those are the range type's btree
ordering, which sorts by lower bound and then upper bound, so the largest range is
not the one reaching furthest right: a unit holding `[1,2)` and `[3,100)` has the
same `maximum` as one holding `[1,2)` and `[3,4)`. Neither `&&` nor `@>` can be
answered from that. `zone_map.max_upper` records the greatest upper bound, in three
states, and the scan skips a unit only when the summary proves it cannot match.

This file asserts the engine's own counters and a heap oracle. Independent of
test/range_pruning.sh: same public seam (a query against a columnar table and the
counters its scan prints), own fixture, own row counts, own observations. Neither
file reads or runs the other.

THE COUNTERS ARE READ AS TYPED JSON. `EXPLAIN (ANALYZE, FORMAT JSON)` comes back as
parsed Python, so "Columnar Chunk Groups Read" is a key holding an int rather than a
number a regex found in text.

THE HEAP IS THE ORACLE. A pruning defect returns FEWER rows, not an error, so every
predicate is answered by a heap table built from the same generator and the two row
sets are compared. Counting alone would miss a unit skipped and another wrongly
read, so the identifiers are compared, not only the count.
"""

ROWS = 12000
GROUP = 1000   # set_options refuses anything smaller


def _plan(conn, sql):
    with conn.cursor() as cur:
        cur.execute(f"EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, FORMAT JSON) {sql}")
        return cur.fetchone()[0]


def _counter(plan, key):
    stack = [plan[0]["Plan"]]
    while stack:
        node = stack.pop(0)
        if key in node:
            return node[key]
        stack.extend(node.get("Plans") or ())
    return None


def _ids(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        return sorted(r[0] for r in cur.fetchall())


def _build(cur, name, order_by, am):
    using = "USING pgcolumnar" if am else ""
    cur.execute(f"CREATE TABLE {name} (id int, span tstzrange) {using}")
    if am:
        cur.execute(
            f"SELECT pgcolumnar.set_options('{name}', stripe_row_limit => {GROUP},"
            f" chunk_group_row_limit => {GROUP})"
        )
    cur.execute(
        f"INSERT INTO {name} SELECT g, tstzrange(t, t + interval '30 minutes') "
        f"FROM (SELECT g, timestamptz '2024-01-01' + (g * interval '1 hour') AS t "
        f"FROM generate_series(1, {ROWS}) g) s ORDER BY {order_by}"
    )
    cur.execute(f"ANALYZE {name}")


def test_range_pruning(pgc_conn, expect):
    probe = "tstzrange(timestamptz '2024-03-01', timestamptz '2024-03-01 06:00')"
    with pgc_conn.cursor() as cur:
        _build(cur, "rp_heap", "g", False)
        _build(cur, "rp_col", "g", True)
        _build(cur, "rp_scatter", "md5(g::text)", True)

        cur.execute("SELECT count(*) FROM rp_col")
        expect.num(cur.fetchone()[0], ROWS,
                   "premise: the table holds every inserted row")

        cur.execute(
            "SELECT count(*) FROM pgcolumnar.zone_map z"
            " JOIN pgcolumnar.storage s USING (storage_id)"
            " WHERE s.relation_oid = 'rp_col'::regclass AND z.max_upper IS NOT NULL")
        expect.at_least(cur.fetchone()[0], 2,
                        "premise: the range column is summarised in several units")

    # THE CLUSTERED CASE. Groups hold consecutive spans, so a summary can exclude
    # most of them.
    sql = f"SELECT id FROM rp_col WHERE span && {probe}"
    plan = _plan(pgc_conn, sql)
    total = _counter(plan, "Columnar Chunk Groups Total")
    read = _counter(plan, "Columnar Chunk Groups Read")
    expect.at_least(total, 2,
                    "premise: the scan saw more than one chunk group to choose from")
    expect.text("pruned" if (read or 0) < (total or 0) else f"read {read} of {total}",
                "pruned",
                "a clustered overlap skips chunk groups instead of reading them all")

    expect.rows(_ids(pgc_conn, sql),
                _ids(pgc_conn, f"SELECT id FROM rp_heap WHERE span && {probe}"),
                "and an overlap returns the heap's rows")

    contains = "SELECT id FROM %s WHERE span @> timestamptz '2024-03-01 02:15'"
    expect.rows(_ids(pgc_conn, contains % "rp_col"),
                _ids(pgc_conn, contains % "rp_heap"),
                "containment of a point returns the heap's rows")

    # THE DOCUMENTED ZERO. Scattered, every group holds a span near the maximum,
    # so no summary can exclude any of them. This is the outcome, not a shortfall.
    splan = _plan(pgc_conn, f"SELECT id FROM rp_scatter WHERE span && {probe}")
    stotal = _counter(splan, "Columnar Chunk Groups Total")
    sread = _counter(splan, "Columnar Chunk Groups Read")
    expect.num(sread, stotal,
               "a scattered column skips nothing, which is what the documentation says")
    expect.rows(_ids(pgc_conn, f"SELECT id FROM rp_scatter WHERE span && {probe}"),
                _ids(pgc_conn, f"SELECT id FROM rp_heap WHERE span && {probe}"),
                "and it still returns the right rows")


def test_a_range_prunes_under_its_declared_collation(pgc_conn, expect):
    """A range compares under the collation it was DECLARED with.

    The type cache carries that as rng_collation; the element type's typcollation
    is a different value. Summarising under one ordering and pruning under another
    makes the scan MISS ROWS. Not reachable with a built-in range type, whose
    subtypes are all non-collatable, so this needs a user-defined one.
    """
    # ASKED OF THE CATALOG, NOT OF A FAILED STATEMENT. Naming a collation that
    # does not exist raises, and one failed statement makes psycopg raise for
    # every later one in the transaction, so a try/except here would both hide a
    # real failure and poison the rest of the test.
    coll = None
    with pgc_conn.cursor() as cur:
        cur.execute(
            "SELECT collname FROM pg_collation"
            " WHERE collname = ANY(%s)"
            # ICU collations are listed even in a build without ICU, and naming
            # one raises FeatureNotSupported rather than returning a wrong answer.
            "   AND collprovider <> 'i'"
            "   AND (collencoding = -1"
            "        OR collencoding = (SELECT encoding FROM pg_database"
            "                           WHERE datname = current_database()))",
            (["en_US.utf8", "en_GB.utf8", "unicode", "ucs_basic", "C"],))
        available = [r[0] for r in cur.fetchall()]
        for candidate in available:
            cur.execute(
                'SELECT (\'B\' < \'a\' COLLATE "%s") <> (\'B\' < \'a\')'
                % candidate)
            if cur.fetchone()[0]:
                coll = '"%s"' % candidate
                break
    if coll is None:
        expect.cannot_run(
            "MISSING_DEPENDENCY",
            "no available collation orders differently from this database's "
            "default, so the arm cannot pose its question",
            name="a range prunes under its declared collation")
        return

    with pgc_conn.cursor() as cur:
        cur.execute(f"CREATE TYPE rp_tr AS RANGE (SUBTYPE = text, COLLATION = {coll})")
        cur.execute("CREATE TABLE rpc_heap (id int, span rp_tr)")
        cur.execute("CREATE TABLE rpc_col (id int, span rp_tr) USING pgcolumnar")
        cur.execute("SELECT pgcolumnar.set_options('rpc_col',"
                    " stripe_row_limit => 1000, chunk_group_row_limit => 1000)")
        gen = ("SELECT g, rp_tr(v, v || 'zz') FROM (SELECT g,"
               " (ARRAY['A','a','B','b','C','c','M','m','Y','y'])[1 + (g / 1000) % 10]"
               " AS v FROM generate_series(1, 10000) g) s")
        cur.execute(f"INSERT INTO rpc_heap {gen}")
        cur.execute(f"INSERT INTO rpc_col {gen}")
        cur.execute("ANALYZE rpc_heap")
        cur.execute("ANALYZE rpc_col")

        cur.execute("SELECT (SELECT rngcollation FROM pg_range"
                    " WHERE rngtypid = 'rp_tr'::regtype)"
                    " <> (SELECT typcollation FROM pg_type WHERE oid = 'text'::regtype)")
        expect.text("differs" if cur.fetchone()[0] else "same", "differs",
                    "premise: the range collates differently from its element type")

        cur.execute("SELECT count(*) FROM pgcolumnar.zone_map z"
                    " JOIN pgcolumnar.storage s USING (storage_id)"
                    " WHERE s.relation_oid = 'rpc_col'::regclass"
                    " AND z.max_upper IS NOT NULL")
        expect.at_least(cur.fetchone()[0], 1,
                        "premise: the collated range column is summarised")

    for lo, hi in (("A", "C"), ("B", "M"), ("a", "b")):
        q = "SELECT id FROM %%s WHERE span && rp_tr('%s', '%s')" % (lo, hi)
        expect.rows(_ids(pgc_conn, q % "rpc_col"),
                    _ids(pgc_conn, q % "rpc_heap"),
                    f"overlap [{lo},{hi}] returns the heap's rows under a declared collation")
