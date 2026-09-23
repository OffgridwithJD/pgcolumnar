"""Retiring a row group probes its five catalogs through their primary keys.

`delete_group_rows()` opens its catalog from a `const char *tableName`
PARAMETER, and `PgColumnarDeleteGroupMetadata` calls it five times, for
`delete_vector`, `column_chunk`, `zone_map`, `bloom` and `row_group`. One
`systable_beginscan` in the source is therefore five sequential scans per
retired group at run time, and a static enumeration by relation handle cannot
see any of them: at the call site the catalog has no name.

Independent of `test/catalog_delete_index.sh`: same public seam
(`pg_stat_all_tables` around one maintenance call), different table, different
row count, different group size, different retention pattern, and this half
reads its counters in one query keyed by `relname` rather than one query per
catalog.

`pg_stat_reset()` is database-wide. Tests run serially within a worker, so
nothing else is counting during this test, and this file must not be run
concurrently with another that reads statistics.

WHY EVERY ARM CARRIES A PREMISE. Each arm expects `seq_scan == 0`, and a
maintenance call that retired nothing reports 0 exactly as loudly as one that
retired fifteen groups through an index.
"""

ROWS = 30000
GROUP = 1000
GROUPS = ROWS // GROUP
RETIRED = GROUPS // 2
SURVIVING = ROWS - RETIRED * GROUP

CATALOGS = (
    "bloom",
    "column_chunk",
    "delete_vector",
    "free_space",
    "row_group",
    "zone_map",
)


def _build_kind(conn):
    """Which build kind this run measured, printed rather than asserted.

    Two of the nine converted scan sites are in
    `PgColumnarCheckFreeSpaceNoOverlap`, which is assert-only. On a release
    build they do not execute, so every arm here is a WEAKER claim there: it
    says nothing about those two sites rather than clearing them.

    The probe run that closed the account for #1207 was on a release build and
    reported the compaction path fully clean while the assert-enabled suite
    still showed a scan on each of two catalogs. Nothing in the measurement
    said which build it was, so the zero read as an answer rather than a
    partial one.

    Printed and NOT made an arm: it records the condition the run happened in,
    and breaking the code under test cannot change it, so no removal proof can
    reach it.
    """
    with conn.cursor() as cur:
        cur.execute("SHOW debug_assertions")
        return cur.fetchone()[0]


def _counters(conn):
    """Every catalog's (idx_scan, seq_scan) in ONE query.

    One query rather than one per catalog, so no two arms can describe
    readings taken at different moments.
    """
    with conn.cursor() as cur:
        cur.execute(
            "SELECT relname, coalesce(idx_scan,0), coalesce(seq_scan,0) "
            "FROM pg_stat_all_tables "
            "WHERE schemaname = 'pgcolumnar' AND relname = ANY(%s)",
            (list(CATALOGS),),
        )
        return {r[0]: (int(r[1]), int(r[2])) for r in cur.fetchall()}


def _groups_of(conn, table):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) FROM pgcolumnar.row_group r "
            "JOIN pgcolumnar.storage s USING (storage_id) "
            "WHERE s.relation_oid = %s::regclass::oid",
            (table,),
        )
        return cur.fetchone()[0]


def test_retiring_a_group_probes_its_catalogs_by_index(pgc_conn, expect):
    conn = pgc_conn
    print(f"-- debug_assertions={_build_kind(conn)} "
          "(off = the two assert-only sites did not run)")
    with conn.cursor() as cur:
        # A second columnar table in the same catalogs. A sequential scan
        # walks its rows too; an index probe does not. Without it every arm
        # could pass on a catalog that happens to hold one storage's rows.
        cur.execute("CREATE TABLE retire_side (k bigint) USING pgcolumnar")
        cur.execute("SELECT pgcolumnar.set_options('retire_side', stripe_row_limit => %s)", (GROUP,))
        cur.execute("INSERT INTO retire_side SELECT g FROM generate_series(1,9000) g")

        cur.execute("CREATE TABLE retire_main (k bigint, tag int) USING pgcolumnar")
        cur.execute("SELECT pgcolumnar.set_options('retire_main', stripe_row_limit => %s)", (GROUP,))
        cur.execute(
            f"INSERT INTO retire_main SELECT g, g % 7 FROM generate_series(1,{ROWS}) g"
        )

        cur.execute("SELECT count(*) FROM retire_main")
        expect.num(cur.fetchone()[0], ROWS, "premise: the measured table holds its rows")

        # Retire the LAST half of the groups rather than every other one, so
        # this half is not merely the shell suite's pattern in Python.
        cur.execute(
            f"DELETE FROM retire_main WHERE k > {RETIRED * GROUP}"
        )
        cur.execute("SELECT count(*) FROM retire_main")
        expect.num(
            cur.fetchone()[0],
            RETIRED * GROUP,
            "premise: the delete removed the groups it was aimed at",
        )

    groups_before = _groups_of(conn, "retire_main")
    expect.num(groups_before, GROUPS, "premise: the table had every group to retire from")

    with conn.cursor() as cur:
        # FLUSH BEFORE THE RESET, NOT ONLY AFTER. This harness holds ONE
        # connection for the whole file, so the writes above leave pending
        # statistics in this backend that pg_stat_reset() does not clear --
        # they are flushed afterwards and land on top of the reading. The
        # shell twin cannot hit this: it runs every statement in a fresh
        # backend, which flushes on exit before the next one starts.
        #
        # Measured, on an otherwise identical single-session fixture:
        #     reset with pending stats   row_group idx=36 seq=15
        #     flush BEFORE reset         row_group idx=32 seq=0
        # The fifteen were this test's own DELETE, one row_group_exists scan
        # per retired group, arriving after the counter had been zeroed.
        cur.execute("SELECT pg_stat_force_next_flush()")
        cur.execute("SELECT pg_stat_reset()")
        cur.execute("SELECT pgcolumnar.compact('retire_main')")
        cur.execute("SELECT pg_stat_force_next_flush()")

    # READ THE COUNTERS BEFORE ANY OTHER QUERY. pg_stat_all_tables
    # accumulates, and the premises below are themselves planned queries over
    # a columnar table, which read these same catalogs.
    counters = _counters(conn)

    groups_after = _groups_of(conn, "retire_main")
    print(f"-- row groups {groups_before} -> {groups_after}")
    expect.num(
        groups_before - groups_after,
        RETIRED,
        "premise: the compaction retired the emptied groups",
    )

    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM retire_main")
        expect.num(
            cur.fetchone()[0],
            RETIRED * GROUP,
            "premise: the compaction kept every surviving row",
        )

    # A catalog missing from the reading would otherwise read as a catalog
    # that was never scanned, which is the answer these arms look for.
    expect.num(
        len(counters),
        len(CATALOGS),
        "premise: the reading covers every catalog the arms name",
    )

    for cat in CATALOGS:
        idx, seq = counters.get(cat, (0, 0))
        print(f"-- {cat} idx_scan={idx} seq_scan={seq}")
        expect.at_least(idx, 1, f"retiring a group probed pgcolumnar.{cat} by index")
        expect.num(seq, 0, f"retiring a group did not sequentially scan pgcolumnar.{cat}")


def test_vacuum_probes_the_row_group_catalog_by_index(pgc_conn, expect):
    """The vacuum path reaches a row_group scan the compaction path does not.

    `PgColumnarVMSetVisibleForRelation` calls
    `PgColumnarComputeAllVisibleGroups`, and nothing in the test above reaches
    it. Probing every scan site during a compaction shows that function never
    fires, so without this test a change to it would ride along on arms that
    could not fail if it were reverted.

    The premise reads `delete_vector`, a DIFFERENT catalog from the one the
    arms are about, so it cannot be satisfied by whatever makes them pass.
    `relallvisible` is the obvious premise and is the wrong quantity: it stays
    0 on this fixture however many times the table is vacuumed. So do
    `vacuum_count` and `last_vacuum`, which this table access method's vacuum
    does not report through at all.
    """
    conn = pgc_conn
    print(f"-- debug_assertions={_build_kind(conn)}")
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE vac_main (k bigint) USING pgcolumnar")
        cur.execute("SELECT pgcolumnar.set_options('vac_main', stripe_row_limit => %s)", (GROUP,))
        cur.execute("INSERT INTO vac_main SELECT g FROM generate_series(1,12000) g")
        cur.execute("DELETE FROM vac_main WHERE k % 3 = 0")

        cur.execute("SELECT count(*) FROM vac_main")
        expect.at_least(cur.fetchone()[0], 1, "premise: the vacuumed table holds rows")

        # Flush before the reset; see the note in the test above.
        cur.execute("SELECT pg_stat_force_next_flush()")
        cur.execute("SELECT pg_stat_reset()")
        cur.execute("VACUUM vac_main")
        cur.execute("SELECT pg_stat_force_next_flush()")

    counters = _counters(conn)
    dv_idx, _dv_seq = counters.get("delete_vector", (0, 0))
    rg_idx, rg_seq = counters.get("row_group", (0, 0))
    print(f"-- VACUUM: row_group idx_scan={rg_idx} seq_scan={rg_seq} "
          f"delete_vector idx_scan={dv_idx}")

    expect.at_least(dv_idx, 1, "premise: the vacuum walked this table's groups")
    expect.at_least(rg_idx, 1, "the vacuum probed pgcolumnar.row_group by index")
    expect.num(rg_seq, 0, "the vacuum did not sequentially scan pgcolumnar.row_group")
