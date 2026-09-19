"""Repeated compact_rewrite cycles must not self-conflict, lose rows, or grow the file.

`PgColumnarAllocateFreeSpace` consumed a `free_space` row without a
`CommandCounterIncrement`, so a `compact_rewrite` that allocated MORE THAN ONCE in one
command re-selected the row it had just consumed and died with "tuple already updated
by self" (#84). It only fires once reusable free space exists -- the second compaction
onward -- so a single-cycle or single-group test misses it. `native_reclaim.sh` misses
it too, because `recluster` advances the command counter between groups and
`compact_rewrite` does not.

Independent of test/native_reclaim_cycles.sh: same public seam (`compact_rewrite` and
`pg_relation_size`), own fixture, own observations. Assertion names match the shell
suite so the two can be compared by name, not by importing each other.

Row sets are compared as sorted tuples in Python rather than through `pgc_set_hash`.
That keeps the two harnesses independent by construction, and a failure prints the
rows that differ instead of two unequal hashes.

THE FIXTURE IS FRAGMENTED ON PURPOSE, AND THAT IS THE WHOLE DIFFERENCE. The shell
suite's fixture cannot reach the defect it is the regression guard for. Measured:
delete the #84 fix, and the shell suite reports 12 passed / 0 failed, unchanged.

The reason is `pgcolumnar.reclaim_coalesce`, which defaults ON. Compaction then merges
adjacent freed ranges, so the free list holds one or two rows however much is freed,
one command allocates from it at most once, and the just-consumed row is never
re-selected. Measured on the shell suite's own fixture, per cycle:

        free_space rows before compact_rewrite:  0, 1, 2, 2, 2

With coalescing OFF the same workload keeps the ranges separate and the precondition
holds. Two cells, each built from its own source and printing its own `.so` hash:

        fix present (.so e95880e45673)   3 cycles, no error, free list steady at 18
        fix removed (.so 42bb17933a55)   first compact_rewrite raises
                                         "tuple already updated by self"

So this file runs its cycles with coalescing off, and asserts the free list is
actually fragmented before relying on it. That premise is what keeps the suite from
going quietly vacuous again if the allocator's shape changes.
"""
import psycopg

ROWS = 30_000
GROUP = 1_000
DEL_LO, DEL_HI = 6001, 24000
CYCLES = 5
# The steady-state assertion's NAME carries this number as a literal, because the bash
# suite states it literally and a template cannot match a literal. Pinned so the two
# cannot drift apart silently.
assert CYCLES == 5, "the steady-state check name says cycle 5; update both together"


def _rows(conn, table):
    """The whole live set, sorted, as tuples -- the port's own oracle."""
    with conn.cursor() as cur:
        cur.execute(f"SELECT id, v, payload FROM {table}")
        return sorted(cur.fetchall())


def _one(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        return cur.fetchone()[0]


def _free_rows(conn):
    return _one(conn, "SELECT count(*) FROM pgcolumnar.free_space "
                      "WHERE storage_id = pgcolumnar.get_storage_id('n')")


def test_native_reclaim_cycles(pgc_conn, expect):
    gen = (f"SELECT g AS id, (g % 100) AS v, md5(g::text) AS payload "
           f"FROM generate_series(1, {ROWS}) g")
    with pgc_conn.cursor() as cur:
        # OFF for the whole test, so every free range stays its own row.
        cur.execute("SET pgcolumnar.reclaim_coalesce = off")
        cur.execute("CREATE TABLE h (id int, v int, payload text)")
        cur.execute("CREATE TABLE n (id int, v int, payload text) USING pgcolumnar")
        cur.execute(
            f"SELECT pgcolumnar.set_options('n', stripe_row_limit => {GROUP}, "
            f"chunk_group_row_limit => {GROUP})"
        )
        cur.execute(f"INSERT INTO h {gen}")
        cur.execute(f"INSERT INTO n {gen}")

    expect.num(_one(pgc_conn, "SELECT count(*) FROM n"), ROWS,
               f"premise: n holds all {ROWS} rows")
    groups = _one(
        pgc_conn,
        "SELECT count(*) FROM pgcolumnar.storage s "
        "JOIN pgcolumnar.row_group rg USING (storage_id) "
        "WHERE s.relation_oid = 'n'::regclass")
    print(f"-- row groups written: {groups}")
    # SEVERAL GROUPS OR ONE COMMAND CANNOT ALLOCATE TWICE. Read back from the
    # catalog rather than assumed from the option that asked for it.
    expect.at_least(groups, 2, "premise: the table has several row groups to rewrite")

    # Free a large CONTIGUOUS block of whole groups and compact, which is what puts
    # many separate reusable ranges on the free list.
    with pgc_conn.cursor() as cur:
        cur.execute(f"DELETE FROM h WHERE id BETWEEN {DEL_LO} AND {DEL_HI}")
        cur.execute(f"DELETE FROM n WHERE id BETWEEN {DEL_LO} AND {DEL_HI}")
        cur.execute("SELECT pgcolumnar.compact('n')")
    free = _free_rows(pgc_conn)
    print(f"-- free_space rows after the block delete: {free}")
    # THE PRECONDITION FOR #84, ASSERTED RATHER THAN HOPED FOR. With a free list of
    # one row -- which is what coalescing produces -- no command allocates from it
    # twice and every arm below passes on a build with the fix removed.
    expect.at_least(
        free, 5,
        "premise: the free list is fragmented, so one command allocates from it "
        "more than once",
    )

    expect.rows(_rows(pgc_conn, "n"), _rows(pgc_conn, "h"), "initial parity")

    sizes = {}
    for r in range(1, CYCLES + 1):
        with pgc_conn.cursor() as cur:
            cur.execute(f"DELETE FROM h WHERE id % 8 = {r % 8}")
            cur.execute(f"DELETE FROM n WHERE id % 8 = {r % 8}")
        # THE CALL IS THE SUBJECT. Pre-fix it raises; the driver turns that into an
        # exception rather than a line of text, so "it raised" and "it returned
        # something that is not a count" are reported apart.
        try:
            got = _one(pgc_conn, "SELECT pgcolumnar.compact_rewrite('n', 0.02)")
            verdict = "ok" if isinstance(got, int) else f"bad:{got!r}"
        except psycopg.Error as exc:
            verdict = f"bad:{str(exc).splitlines()[0]}"
        expect.text(
            verdict, "ok",
            f"compact_rewrite cycle {r} returns a count (no self-conflict)",
        )
        expect.rows(
            _rows(pgc_conn, "n"), _rows(pgc_conn, "h"),
            f"parity after compact_rewrite cycle {r}",
        )
        sizes[r] = _one(pgc_conn, "SELECT pg_relation_size('n')")

    print(f"-- file sizes by cycle: {[sizes[r] for r in range(1, CYCLES + 1)]}")
    # Cycles 2..5 reuse the prior cycle's frees, so the file must not grow past
    # cycle 2. Deletes only -- no inserts -- so compaction is the only writer.
    expect.text(
        "yes" if sizes[CYCLES] <= sizes[2]
        else f"no (cycle {CYCLES}={sizes[CYCLES]} > cycle 2={sizes[2]})",
        "yes",
        "file reaches steady state (cycle 5 <= cycle 2)",
    )
