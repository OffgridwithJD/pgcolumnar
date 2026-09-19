"""Reading the delete vector uses `delete_vector_pkey`, not a sequential catalog scan.

`pgcolumnar.delete_vector` has a unique index on (storage_id, group_number), and the
sibling metadata tables all pass their `_pkey` to `systable_beginscan`. `delete_vector`
did not: `PgColumnarReadDeleteVectorList`, the reclaim deleted-count sum, and
`PgColumnarStorageHasDeleteVector` each passed `InvalidOid` / `indexOK=false`, so every
call scanned the whole catalog filtered by scan key. `ReadDeleteVectorList` runs once per
row group while a scan builds its liveness cache, so the cost was
O(groups * delete_vector_rows).

Independent of test/native_delete_vector_index.sh: same public seam
(`pg_stat_all_tables` over the catalog, and the visible sum), own fixture, own
observations. Assertion names match the shell suite so the two can be compared by name,
not by importing each other.

THE COUNT IS SCOPED TO THIS TABLE'S STORAGE, AND THAT IS NOT A STYLE CHOICE. The shell
suite runs `SELECT count(*) FROM pgcolumnar.delete_vector` against a cluster it created
moments earlier, where its own table is the only writer. A pytest worker shares ONE
cluster across the whole corpus, and `pgcolumnar.delete_vector` is database-wide: any
earlier test that deleted from a columnar table leaves rows in it. Unscoped, this arm
would pass or fail on test ORDER, which is the worst kind of flake because it is
reproducible only in a suite run. Scoped by `storage_id`, it asserts the same property
about the same table.

`pg_stat_reset()` is likewise database-wide. It is still the right instrument here --
tests run serially within a worker, so nothing else is counting -- but it is the reason
this file must not be run concurrently with another that reads statistics.

THE MEASURED SCAN RUNS ON A SECOND CONNECTION, AND THAT TURNS OUT TO BE LOAD-BEARING.
The shell suite sends every statement through its own `psql`, so the scan it measures is
always made by a session that did not do the writing. A pytest test holds ONE connection
for the whole test, and measured on this fixture the two are not the same:

        the scan runs in...          idx_scan   seq_scan
        the session that wrote             62         20
        a fresh session                    21          0

Twenty sequential catalog scans, one per row group, survive in the writing session --
which is the cost #-the-index-switch removed, still being paid by whoever just wrote. The
shell suite cannot see it because it has no long-lived session to see it with. Filed
separately; this port asserts the property the suite states, on a fresh connection, and
does not assert the writing-session behaviour either way.
"""
import psycopg
ROWS = 40_000
GROUP = 2_000
GROUPS = ROWS // GROUP
# sum(1..40000) minus the deleted multiples of 500
LIVE_SUM = sum(range(1, ROWS + 1)) - sum(range(500, ROWS + 1, 500))


def _one(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        row = cur.fetchone()
    return row[0] if row else None


def test_native_delete_vector_index(pgc_cluster, pgc_conn, expect):
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE t (id int, v bigint) USING pgcolumnar")
        cur.execute(f"SELECT pgcolumnar.set_options('t', stripe_row_limit => {GROUP})")
        cur.execute(f"INSERT INTO t SELECT g, g FROM generate_series(1,{ROWS}) g")
        cur.execute("SELECT count(*) FROM t")
        expect.num(cur.fetchone()[0], ROWS, f"premise: the table holds all {ROWS} rows")
        cur.execute("DELETE FROM t WHERE id % 500 = 0")

    groups = _one(pgc_conn,
                  "SELECT count(*) FROM pgcolumnar.storage s "
                  "JOIN pgcolumnar.row_group rg USING (storage_id) "
                  "WHERE s.relation_oid = 't'::regclass")
    print(f"-- row groups: {groups}")
    expect.num(groups, GROUPS, f"premise: the table was written as {GROUPS} row groups")

    # SCOPED BY storage_id -- see the module docstring.
    expect.num(
        _one(pgc_conn,
             "SELECT count(*) FROM pgcolumnar.delete_vector "
             "WHERE storage_id = pgcolumnar.get_storage_id('t')"),
        GROUPS,
        "the delete produced one delete_vector row per group",
    )

    # Reset, then run the measured scan ON A SECOND CONNECTION -- see the module
    # docstring; the writing session takes a different route and this arm is about the
    # reader's. Force the counters out rather than racing the collector.
    with pgc_conn.cursor() as cur:
        cur.execute("SELECT current_schema()")
        schema = cur.fetchone()[0]
        cur.execute("SELECT pg_stat_reset()")
    reader = psycopg.connect(pgc_cluster.dsn(), autocommit=True)
    try:
        with reader.cursor() as cur:
            cur.execute(f'SET search_path TO "{schema}", public')
            cur.execute("SELECT sum(v) FROM t")
            scanned = cur.fetchone()[0]
            cur.execute("SELECT pg_stat_force_next_flush()")
    finally:
        reader.close()
    # THE SCAN HAS TO HAVE HAPPENED, or the counters below are about nothing. A reset
    # followed by no reads gives idx_scan NULL and seq_scan 0 -- and seq_scan 0 is
    # what the second arm wants to see.
    expect.num(scanned, LIVE_SUM, "premise: the scan that builds the cache ran and was correct")

    idx = _one(pgc_conn,
               "SELECT coalesce(idx_scan,0) FROM pg_stat_all_tables "
               "WHERE relname='delete_vector' AND schemaname='pgcolumnar'")
    seq = _one(pgc_conn,
               "SELECT coalesce(seq_scan,0) FROM pg_stat_all_tables "
               "WHERE relname='delete_vector' AND schemaname='pgcolumnar'")
    print(f"-- delete_vector after one full scan: idx_scan={idx} seq_scan={seq}")
    expect.at_least(idx, 1, "delete_vector reads used the index (idx_scan > 0)")
    expect.num(seq, 0,
               "delete_vector reads did NOT sequentially scan the catalog (seq_scan = 0)")

    expect.num(_one(pgc_conn, "SELECT sum(v) FROM t"), LIVE_SUM,
               "the deletes are still applied (visibility unchanged by the index switch)")
