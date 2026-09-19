"""Coalescing adjacent frees must merge them, stay correct, and never cost file size.

Phase F split/coalesce: with `pgcolumnar.reclaim_coalesce` on, an oversized freed
range is split on reuse and adjacent same-transaction frees are merged. The same
retire+recluster workload runs in both modes and must agree on the data while
disagreeing on the free list -- fewer `free_space` rows with coalescing on is the
direct, deterministic evidence that the coalesce path ran at all.

Independent of test/native_reclaim_frag.sh: same public seam (`pgcolumnar.free_space`,
`pg_relation_size`, and the maintenance functions), own fixture, own observations.
Assertion names match the shell suite so the two can be compared by name, not by
importing each other.

Row sets are compared as sorted tuples in Python rather than through `pgc_set_hash`,
which keeps the two harnesses independent by construction.

WHAT THE PORT ASSERTS THAT THE ORIGINAL SWALLOWS. The original wraps the whole
build-and-compact sequence in `{ ... } >/dev/null 2>&1`. That is deliberate -- the
noise is real -- but it means a failed `INSERT`, a refused `set_options` or an errored
`compact` produces exactly the same visible state as a successful one, and the arms
below it would then compare two empty tables and report parity. Here the driver raises
on any of them, and the row counts are asserted per mode before anything is compared,
so "both modes agree" cannot be satisfied by both modes having done nothing.
"""
ROWS = 30_000
GROUP = 1_000
DEL_LO, DEL_HI = 6001, 24000
LIVE = ROWS - (DEL_HI - DEL_LO + 1)

GEN = (f"SELECT g AS id, repeat('ab', 5 + ((g / 1000) % 16) * 8) AS payload "
       f"FROM generate_series(1, {ROWS}) g")


def _rows(conn, table):
    with conn.cursor() as cur:
        cur.execute(f"SELECT id, payload FROM {table}")
        return sorted(cur.fetchall())


def _run(conn, expect, mode):
    """One whole cycle in one coalesce mode -> (free rows after compact, final size)."""
    with conn.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS n")
        cur.execute("DROP TABLE IF EXISTS h")
        cur.execute(f"SET pgcolumnar.reclaim_coalesce = {mode}")
        cur.execute("CREATE TABLE h (id int, payload text)")
        cur.execute("CREATE TABLE n (id int, payload text) USING pgcolumnar")
        cur.execute(
            f"SELECT pgcolumnar.set_options('n', stripe_row_limit => {GROUP}, "
            f"chunk_group_row_limit => {GROUP})"
        )
        cur.execute(f"INSERT INTO h {GEN}")
        cur.execute(f"INSERT INTO n {GEN}")
        cur.execute("SELECT count(*) FROM n")
        expect.num(cur.fetchone()[0], ROWS,
                   f"premise: coalesce {mode} -- n holds all {ROWS} rows before the delete")

        # A large CONTIGUOUS block, so compaction frees many small adjacent ranges in
        # one transaction -- which is the only shape coalescing can merge.
        cur.execute(f"DELETE FROM h WHERE id BETWEEN {DEL_LO} AND {DEL_HI}")
        cur.execute(f"DELETE FROM n WHERE id BETWEEN {DEL_LO} AND {DEL_HI}")
        cur.execute("SELECT pgcolumnar.compact('n')")
        cur.execute("SELECT count(*) FROM n")
        expect.num(cur.fetchone()[0], LIVE,
                   f"premise: coalesce {mode} -- {LIVE} rows survive the delete")

        # Counted before anything consumes them.
        cur.execute(
            "SELECT count(*) FROM pgcolumnar.free_space "
            "WHERE storage_id = pgcolumnar.get_storage_id('n')"
        )
        free_rows = cur.fetchone()[0]

        # Force large output groups and recluster, which reuses the freed space.
        cur.execute(
            "SELECT pgcolumnar.set_options('n', stripe_row_limit => 20000, "
            "chunk_group_row_limit => 20000)"
        )
        cur.execute("SELECT pgcolumnar.recluster('n', 'id')")
        cur.execute("SELECT pg_relation_size('n')")
        size = cur.fetchone()[0]
    return free_rows, size


def test_native_reclaim_frag(pgc_conn, expect):
    on_free, on_size = _run(pgc_conn, expect, "on")
    expect.rows(_rows(pgc_conn, "n"), _rows(pgc_conn, "h"),
                "coalesce on: parity with heap")

    off_free, off_size = _run(pgc_conn, expect, "off")
    expect.rows(_rows(pgc_conn, "n"), _rows(pgc_conn, "h"),
                "coalesce off: parity with heap")

    print(f"-- free_space rows after compact: on={on_free} off={off_free}")
    print(f"-- final file size: on={on_size} off={off_size}")

    expect.text(
        "yes" if on_free < off_free else f"no (on={on_free} off={off_free})",
        "yes",
        "coalesce merges adjacent frees (fewer free_space rows)",
    )
    expect.text(
        "yes" if on_size <= off_size else f"no (on={on_size} off={off_size})",
        "yes",
        "coalesce never larger than whole-range reuse",
    )
