"""`pgcolumnar.expire` drops fully expired row groups and keeps every other row.

This is the suite for the one function in the tree that DELETES ROWS, so a wrong
answer here destroys data rather than reporting a wrong number. That is why it is
written twice (#1188).

THE ARM THAT MATTERS IS THE STRADDLING GROUP. Retiring a group whose rows are all
past the retention is the feature; retiring one that still holds live rows is data
loss. Every fixture below that can straddle is built to straddle, and the survivors
are counted. A suite that only proved expired data disappears would pass on an
implementation that dropped everything.

Two more ways "the maximum is expired" is not "every row is expired", and both have
their own section: a NULL in the retention column, which the zone map's maximum does
not cover, and an index-only scan after VACUUM, where the visibility-map bits stay
set over a group `expire` removed without going through the delete vector.

Independent of `test/ttl_expire.sh`. Same public seam -- `pgcolumnar.expire`, the
options catalog and the row-group catalog -- with its own tables, its own row
counts, its own retention windows and its own SQL. Neither file is read by the
other. Check names match so the pair can be graded by name.

THE GEOMETRY IS DECLARED PER TABLE, NOT PER CLUSTER, AND THEN ASSERTED. The shell
suite bakes `pgcolumnar.stripe_row_limit=1000` into the cluster config before the
postmaster starts, so its writing session cannot disagree with a later one (#806).
This corpus has one connection and no per-test cluster config, so it uses
`pgcolumnar.set_options(..., stripe_row_limit => 1000)`, which is catalog state
rather than a session setting and therefore travels with the table.

**A procedural substitute for a structural guarantee has to be asserted**, because
it can fail silently where the original cannot: `set_options` REFUSES a
`stripe_row_limit` below 1000 by raising, and 1000 is exactly its floor, so a future
change to that floor turns this fixture into one large row group where nothing
straddles and several arms below stop asserting anything. Every fixture therefore
pins its resulting group count.

AND THE TWO MECHANISMS WERE COMPARED RATHER THAN ASSUMED EQUIVALENT. Asked by
@OffgridwithJD: if the straddle premise holds under one and not the other, this file
is testing a different tree from the suite it is graded against. The same 5,000-row
fixture written both ways, read from the catalog:

    relname  | groups | min_rows | max_rows | first_row_numbers
    geo_guc  |      5 |     1000 |     1000 | 1,1001,2001,3001,4001   <- the GUC
    geo_opt  |      5 |     1000 |     1000 | 1,1001,2001,3001,4001   <- set_options

Identical boundaries, not merely an identical count, so the group a row lands in is
the same under both and the straddling group is the same group.
"""

import time

import psycopg

# 1,000 rows to a group, which is `set_options`' floor for `stripe_row_limit`.
GROUP = 1000


def _one(conn, sql, args=None):
    with conn.cursor() as cur:
        cur.execute(sql, args)
        row = cur.fetchone()
    return row[0] if row else None


def _groups(conn, table):
    """-> how many row groups `table` has, from the catalog."""
    return _one(
        conn,
        "SELECT count(*) FROM pgcolumnar.storage s "
        "JOIN pgcolumnar.row_group rg USING (storage_id) "
        "WHERE s.relation_oid = %s::regclass",
        (table,),
    )


def _sqlstate(conn, sql):
    """-> the SQLSTATE `sql` raises, or '' when it succeeds."""
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
        return ""
    except psycopg.Error as exc:
        return exc.sqlstate or ""


def test_expire_retires_expired_groups_and_keeps_the_straddling_one(pgc_conn, expect):
    """The headline property, and the safety property that constrains it.

    5,000 rows three minutes apart span about ten days, so a four-day retention
    puts the cutoff INSIDE a group rather than between two. That is the whole
    point of the fixture: "drop every group holding an expired row" and "drop
    every group whose rows are all expired" give different answers on it.
    """
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE ttl_ts (id int, ts timestamptz, v text) USING pgcolumnar")
        cur.execute(f"SELECT pgcolumnar.set_options('ttl_ts', stripe_row_limit => {GROUP})")
        cur.execute(
            "INSERT INTO ttl_ts SELECT g, now() - interval '8 days' "
            "+ make_interval(mins => g * 3), 'v' || g FROM generate_series(1,5000) g"
        )
        cur.execute("ANALYZE ttl_ts")

    cutoff = "now() - interval '4 days'"
    groups_before = _groups(pgc_conn, "ttl_ts")
    rows_before = _one(pgc_conn, "SELECT count(*) FROM ttl_ts")
    expired = _one(pgc_conn, f"SELECT count(*) FROM ttl_ts WHERE ts < {cutoff}")
    live = _one(pgc_conn, f"SELECT count(*) FROM ttl_ts WHERE ts >= {cutoff}")

    expect.at_least(
        groups_before, 4,
        "premise: the fixture is laid out in several row groups")
    expect.text(
        "both" if expired > 0 and live > 0 else f"expired {expired}, live {live}",
        "both",
        "premise: some rows are past the retention and some are not")

    # A GROUP THAT SPANS THE CUTOFF EXISTS, which is what makes the safety arm
    # below able to fail. Counted within a day either side, because a day is
    # wider than the ~2.1 days a 1,000-row group covers here only in the sense
    # that matters: rows on both sides of the cutoff close to it.
    straddle = _one(
        pgc_conn,
        f"SELECT count(*) FROM ttl_ts WHERE ts >= {cutoff} - interval '1 day' "
        f"AND ts < {cutoff} + interval '1 day'")
    expect.at_least(
        straddle, 1,
        "premise: rows exist on both sides of the cutoff within one day of it")

    with pgc_conn.cursor() as cur:
        cur.execute(
            "SELECT pgcolumnar.set_options('ttl_ts', ttl_column => 'ts',"
            " ttl_interval => '4 days')")
    expect.text(
        _one(pgc_conn,
             "SELECT ttl_column || ' / ' || ttl_interval FROM pgcolumnar.options"
             " WHERE regclass = 'ttl_ts'::regclass"),
        "ts / 4 days",
        "the retention is recorded where the other options live")

    retired = _one(pgc_conn, "SELECT pgcolumnar.expire('ttl_ts')")
    rows_after = _one(pgc_conn, "SELECT count(*) FROM ttl_ts")
    groups_after = _groups(pgc_conn, "ttl_ts")
    live_after = _one(pgc_conn, f"SELECT count(*) FROM ttl_ts WHERE ts >= {cutoff}")
    print(f"-- before: {rows_before} rows in {groups_before} groups "
          f"({expired} past retention)")
    print(f"-- expire retired {retired} group(s): {rows_after} rows in {groups_after}")

    expect.at_least(
        retired, 1,
        "expire retires at least one group (#403 item 5a)")
    expect.num(
        groups_before - retired, groups_after,
        "and the table lost exactly the groups it retired")

    # THE SAFETY CHECK. An implementation that retired the straddling group fails
    # here and nowhere else.
    expect.num(
        live_after, live,
        "NO row still inside the retention was dropped (#403 item 5a)")
    expect.text(
        "smaller" if rows_after < rows_before else f"UNCHANGED ({rows_after} of {rows_before})",
        "smaller",
        "and the table really is smaller than it was")
    expect.num(
        _one(pgc_conn, "SELECT count(*) FROM ttl_ts WHERE v <> 'v' || id"), 0,
        "every remaining row reads back its own value")
    expect.num(
        _one(pgc_conn, "SELECT pgcolumnar.expire('ttl_ts')"), 0,
        "running it again retires nothing, because nothing new expired")

    # A TABLE WITH NO RETENTION IS AN ERROR, ASSERTED BY SQLSTATE. The shell twin
    # greps the message; 55000 comes from the prerequisite-state check, while a
    # missing function is 42883 and a non-owner 42501, so the state distinguishes
    # the refusal from three other ways the call can fail.
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE ttl_bare (id int, ts timestamptz) USING pgcolumnar")
        cur.execute("INSERT INTO ttl_bare SELECT g, now() FROM generate_series(1,10) g")
    expect.text(
        _sqlstate(pgc_conn, "SELECT pgcolumnar.expire('ttl_bare')") or "ACCEPTED",
        "55000",
        "a table with no declared retention is an error, not a silent success")


def test_a_null_retention_value_keeps_its_group(pgc_conn, expect):
    """The zone map's maximum covers non-NULL values only.

    A group of old timestamps plus NULLs looks fully expired from the maximum
    alone, and retiring it would drop rows whose retention is unknown.
    """
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE ttl_nul (id int, ts timestamptz, v text) USING pgcolumnar")
        cur.execute(f"SELECT pgcolumnar.set_options('ttl_nul', stripe_row_limit => {GROUP})")
        # ONE statement, so the NULLs cannot land in a group of their own.
        cur.execute(
            "INSERT INTO ttl_nul SELECT g, CASE WHEN g <= 12 THEN NULL "
            "ELSE now() - interval '30 days' END, 'v' || g "
            "FROM generate_series(1,1000) g")
        cur.execute(
            "SELECT pgcolumnar.set_options('ttl_nul', ttl_column => 'ts',"
            " ttl_interval => '4 days')")

    expect.num(
        _one(pgc_conn, "SELECT count(*) FROM ttl_nul WHERE ts IS NULL"), 12,
        "premise: the table holds NULL retention rows at all")

    # A TABLE-LEVEL COUNT CANNOT SEE A ROW GROUP, and passes just as readily on a
    # fixture where the NULLs sit in a group of their own -- which is the
    # arrangement this premise exists to exclude. Count the groups holding both.
    expect.num(
        _one(pgc_conn,
             "SELECT count(*) FROM (SELECT z.group_number FROM pgcolumnar.zone_map z "
             "JOIN pgcolumnar.storage s ON s.storage_id = z.storage_id "
             "WHERE s.relation_oid = 'ttl_nul'::regclass AND z.null_count > 0 "
             "GROUP BY z.group_number) g"),
        1,
        "premise: and the SAME row group holds expired rows and NULL ones")

    expect.num(
        _one(pgc_conn, "SELECT pgcolumnar.expire('ttl_nul')"), 0,
        "expire does not retire a group that still holds NULL retention rows")
    expect.num(
        _one(pgc_conn, "SELECT count(*) FROM ttl_nul WHERE ts IS NULL"), 12,
        "and those NULL rows are still there")
    expect.num(
        _one(pgc_conn, "SELECT count(*) FROM ttl_nul"), 1000,
        "and the expired timestamps sharing the group were kept with them")


def test_an_index_only_scan_does_not_return_retired_rows(pgc_conn, expect):
    """`expire` retires live groups without going through the delete vector.

    So the visibility-map bits VACUUM set stay on, and an index-only scan can
    answer from the index alone about a group that is no longer there.

    SESSION SETTINGS, NOT `ALTER DATABASE`. The shell twin runs each statement in
    a fresh backend and therefore has to put the settings in the database; this
    corpus holds one connection, so a `SET` reaches every statement below. It is
    a procedural substitute for the same structural guarantee, so the premise
    arm asserts the plan it is meant to produce rather than assuming it.
    """
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE ttl_ios (id int, ts timestamptz) USING pgcolumnar")
        cur.execute("SELECT pgcolumnar.set_options('ttl_ios', stripe_row_limit => 16384)")
        cur.execute(
            "INSERT INTO ttl_ios SELECT g, now() - interval '30 days' "
            "FROM generate_series(1,6000) g")
        cur.execute("CREATE INDEX ttl_ios_id ON ttl_ios (id)")
        cur.execute("SET pgcolumnar.enable_index_only_scan = on")
        cur.execute("SET pgcolumnar.enable_custom_scan = off")
        cur.execute("SET enable_seqscan = off")
        cur.execute("SET enable_bitmapscan = off")
        # VACUUM UNTIL THE BITS ARE SET, OR SAY WHY THEY ARE NOT.
        #
        # A page is marked all-visible only when every tuple on it is visible to
        # ALL transactions, so ANY concurrent snapshot older than these rows
        # suppresses the bits entirely. The shell twin never meets that: it gets a
        # cluster to itself. This corpus shares one, so the condition the shell
        # suite has structurally is one the port has to establish.
        #
        # MEASURED by @OffgridwithJD, directly on this arm's SQL:
        #
        #     quiet cluster                         allvisible = 2 of 3, 6 of 6
        #     a snapshot opened before the INSERT   allvisible = 0,      3 of 3
        #     the holder commits, VACUUM again      allvisible = 2,      3 of 3
        #
        # and with ordinary one-statement churn rather than a held snapshot,
        # 7 of 20 runs read 0 without a retry and 0 of 20 with one, every recovery
        # taking exactly two attempts. Eight attempts is about four times the worst
        # case observed.
        #
        # NOT XDIST, which is what an earlier version of this comment said. The
        # ci.yml cluster job runs serial -- no `-n` anywhere in it -- and pgc_conn
        # is autocommit and function-scoped, so the corpus holds no second
        # snapshot of its own. The actor is other activity on the shared cluster.
        #
        # A retry is the honest remedy for a transient horizon and not for a broken
        # VACUUM, which is why the premise below still refuses if the bits never
        # arrive: under a SUSTAINED holder the loop correctly fails to save it.
        for _attempt in range(8):
            cur.execute("VACUUM ttl_ios")
            cur.execute("SELECT relallvisible FROM pg_class"
                        " WHERE oid = 'ttl_ios'::regclass")
            if cur.fetchone()[0] > 0:
                break
            time.sleep(0.25)
        cur.execute(
            "SELECT pgcolumnar.set_options('ttl_ios', ttl_column => 'ts',"
            " ttl_interval => '4 days')")
        cur.execute("EXPLAIN (COSTS OFF) SELECT id FROM ttl_ios WHERE id BETWEEN 1 AND 6000")
        plan_before = "\n".join(r[0] for r in cur.fetchall())

    expect.num(
        plan_before.count("Index Only Scan"), 1,
        "premise: an index-only scan is chosen on the all-visible table")

    # THE PLAN SHAPE IS DECIDED BY relallvisible AND THE TWO DISABLED SCANS, not
    # by the visibility-map bit this section is about. Stop the bits being written
    # and the plan is unchanged, so the arm above cannot fail for the thing under
    # test. Assert the bits.
    #
    # STILL A REFUSAL, not a tolerance. The loop above retries a transient xmin
    # horizon; if the bits never arrive this arm goes red, because everything
    # below it is vacuous without them.
    expect.text(
        _one(pgc_conn,
             "SELECT CASE WHEN relallvisible > 0 THEN 'set' ELSE 'none' END "
             "FROM pg_class WHERE oid = 'ttl_ios'::regclass"),
        "set",
        "premise: and VACUUM really did set visibility-map bits to clear")

    expect.at_least(
        _one(pgc_conn, "SELECT pgcolumnar.expire('ttl_ios')"), 1,
        "expire retires the all-visible expired group")

    # The catalog truth, read with the custom scan back on: the group is gone.
    with pgc_conn.cursor() as cur:
        cur.execute("SET enable_seqscan = on")
        cur.execute("SET pgcolumnar.enable_custom_scan = on")
        cur.execute("SELECT count(*) FROM ttl_ios")
        seq_after = cur.fetchone()[0]
        cur.execute("SET enable_seqscan = off")
        cur.execute("SET pgcolumnar.enable_custom_scan = off")
    expect.num(seq_after, 0, "seqscan agrees the expired rows are gone")

    with pgc_conn.cursor() as cur:
        cur.execute("EXPLAIN (COSTS OFF) SELECT id FROM ttl_ios WHERE id BETWEEN 1 AND 6000")
        plan_after = "\n".join(r[0] for r in cur.fetchall())
        cur.execute("SELECT count(*) FROM ttl_ios WHERE id BETWEEN 1 AND 6000")
        ios_after = cur.fetchone()[0]
    expect.num(
        plan_after.count("Index Only Scan"), 1,
        "the index-only scan is still the plan after expire")
    expect.num(
        ios_after, 0,
        "index-only scan does not return rows expire already retired")

    with pgc_conn.cursor() as cur:
        cur.execute("RESET pgcolumnar.enable_index_only_scan")
        cur.execute("RESET pgcolumnar.enable_custom_scan")
        cur.execute("RESET enable_seqscan")
        cur.execute("RESET enable_bitmapscan")


def test_a_non_positive_retention_is_refused(pgc_conn, expect):
    """A negative interval puts the cutoff in the FUTURE.

    `maximum < cutoff` is then true for groups entirely inside their retention,
    so `expire` would drop live rows: the failure this suite is named for.

    SQLSTATE, not message text. 22023 comes from the range check, while a missing
    function is 42883 and a non-owner 42501.
    """
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE ttl_neg (id int, ts timestamptz) USING pgcolumnar")
        cur.execute("INSERT INTO ttl_neg SELECT g, now() FROM generate_series(1,120) g")

    expect.text(
        _sqlstate(pgc_conn,
                  "SELECT pgcolumnar.set_options('ttl_neg', ttl_column => 'ts',"
                  " ttl_interval => '-4 days')") or "ACCEPTED",
        "22023",
        "a negative ttl_interval is refused with 22023")
    expect.text(
        _sqlstate(pgc_conn,
                  "SELECT pgcolumnar.set_options('ttl_neg', ttl_column => 'ts',"
                  " ttl_interval => '0 seconds')") or "ACCEPTED",
        "22023",
        "and a zero ttl_interval is refused too")

    # WITHOUT THIS PAIR, a guard that refused EVERY interval would look identical
    # to one that refuses only the dangerous ones.
    expect.text(
        _sqlstate(pgc_conn,
                  "SELECT pgcolumnar.set_options('ttl_neg', ttl_column => 'ts',"
                  " ttl_interval => '4 days')") or "accepted",
        "accepted",
        "control: and a positive one is still accepted")
    expect.num(
        _one(pgc_conn, "SELECT count(*) FROM ttl_neg"), 120,
        "control: and the rows are all still there")


def test_a_deleted_null_stops_pinning_its_group(pgc_conn, expect):
    """`null_count` is recorded at WRITE time and never revised.

    Read as the LIVE count it keeps a group whose every live row is past
    retention and whose NULL rows have all been deleted, and keeps it forever,
    because nothing rewrites a zone map on delete. That trades data loss for
    permanent over-retention, which is quieter and not better.
    """
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE ttl_dn (id int, ts timestamptz, v text) USING pgcolumnar")
        cur.execute(f"SELECT pgcolumnar.set_options('ttl_dn', stripe_row_limit => {GROUP})")
        # ONE statement. Two would flush two groups and the NULLs would never
        # share a group with the rows under test, so every arm below would answer
        # a question nobody asked.
        cur.execute(
            "INSERT INTO ttl_dn SELECT g, CASE WHEN g % 8 = 0 THEN NULL "
            "ELSE now() - interval '500 days' END, 'v' || g "
            "FROM generate_series(1,800) g")
        cur.execute(
            "SELECT pgcolumnar.set_options('ttl_dn', ttl_column => 'ts',"
            " ttl_interval => '120 days')")

    expect.num(
        _groups(pgc_conn, "ttl_dn"), 1,
        "premise: the fixture is ONE row group, so the NULLs share it")

    with pgc_conn.cursor() as cur:
        cur.execute("DELETE FROM ttl_dn WHERE ts IS NULL")

    expect.num(
        _one(pgc_conn, "SELECT count(*) FROM ttl_dn WHERE ts IS NULL"), 0,
        "premise: no LIVE row holds a NULL retention value any more")
    expect.text(
        _one(pgc_conn,
             "SELECT CASE WHEN sum(z.null_count) > 0 THEN 'still recorded' ELSE 'gone' END "
             "FROM pgcolumnar.zone_map z JOIN pgcolumnar.storage s "
             "ON s.storage_id = z.storage_id WHERE s.relation_oid = 'ttl_dn'::regclass"),
        "still recorded",
        "premise: but the zone map still records the deleted NULLs")
    expect.num(
        _one(pgc_conn,
             "SELECT count(*) FROM ttl_dn WHERE ts >= now() - interval '120 days'"),
        0,
        "premise: and every live row is past the retention")

    expect.num(
        _one(pgc_conn, "SELECT pgcolumnar.expire('ttl_dn')"), 1,
        "a group whose only NULLs have been deleted is retired")
    expect.num(
        _one(pgc_conn, "SELECT count(*) FROM ttl_dn"), 0,
        "and its rows are gone")

    # CONTROL: the live-NULL case must still be refused, or the behaviour above
    # is just "retire everything" wearing a delete.
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE ttl_dl (id int, ts timestamptz, v text) USING pgcolumnar")
        cur.execute(f"SELECT pgcolumnar.set_options('ttl_dl', stripe_row_limit => {GROUP})")
        cur.execute(
            "INSERT INTO ttl_dl SELECT g, CASE WHEN g % 8 = 0 THEN NULL "
            "ELSE now() - interval '500 days' END, 'v' || g "
            "FROM generate_series(1,800) g")
        cur.execute(
            "SELECT pgcolumnar.set_options('ttl_dl', ttl_column => 'ts',"
            " ttl_interval => '120 days')")
        # One row deleted, so the table HAS a delete vector and takes the same
        # path as ttl_dn -- but the NULLs are still live.
        cur.execute("DELETE FROM ttl_dl WHERE id = 1")

    expect.num(
        _one(pgc_conn, "SELECT pgcolumnar.expire('ttl_dl')"), 0,
        "control: a group whose NULLs are still live is NOT retired")
    expect.num(
        _one(pgc_conn, "SELECT count(*) FROM ttl_dl WHERE ts IS NULL"), 100,
        "control: and those NULL rows survive")


def test_a_date_retention_column_truncates_toward_keeping(pgc_conn, expect):
    """`date - interval` yields a TIMESTAMP, so the cutoff has to be truncated.

    Truncation KEEPS a row slightly older than the window rather than dropping
    one slightly younger, and for a function whose failure mode is deleting data
    that is the direction to err in (#1135). It is asserted rather than left to
    the reader: every other arm here passes whichever way the rounding goes.
    """
    days = 6
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE ttl_dt (id int, d date, v text) USING pgcolumnar")
        cur.execute(f"SELECT pgcolumnar.set_options('ttl_dt', stripe_row_limit => {GROUP})")
        cur.execute(
            f"INSERT INTO ttl_dt SELECT g, (CURRENT_DATE - {days}) + ((g - 1) / {GROUP}), "
            f"'v' || g FROM generate_series(1,6000) g")
        cur.execute("ANALYZE ttl_dt")
        cur.execute(
            "SELECT pgcolumnar.set_options('ttl_dt', ttl_column => 'd',"
            " ttl_interval => '4 days')")

    cutoff = "(CURRENT_DATE - 4)"
    groups_before = _groups(pgc_conn, "ttl_dt")
    rows_before = _one(pgc_conn, "SELECT count(*) FROM ttl_dt")
    d_expired = _one(pgc_conn, f"SELECT count(*) FROM ttl_dt WHERE d < {cutoff}")
    d_live = _one(pgc_conn, f"SELECT count(*) FROM ttl_dt WHERE d >= {cutoff}")
    on_cutoff = _one(pgc_conn, f"SELECT count(*) FROM ttl_dt WHERE d = {cutoff}")

    expect.at_least(
        groups_before, 4,
        "premise: the date fixture is laid out in several row groups")
    expect.text(
        "both" if d_expired > 0 and d_live > 0 else f"expired {d_expired}, live {d_live}",
        "both",
        "premise: the date fixture has rows on both sides of the cutoff")
    expect.at_least(
        on_cutoff, 1,
        "premise: and rows dated exactly ON the cutoff, which decide the rounding")

    state = _sqlstate(pgc_conn, "SELECT pgcolumnar.expire('ttl_dt')")
    expect.text(
        "accepted" if state == "" else f"refused ({state})",
        "accepted",
        "a date retention column is accepted, not refused (#1135)")

    # Re-read after the call above, which ran it once.
    retired = _one(pgc_conn, "SELECT pgcolumnar.expire('ttl_dt')")
    rows_after = _one(pgc_conn, "SELECT count(*) FROM ttl_dt")
    live_after = _one(pgc_conn, f"SELECT count(*) FROM ttl_dt WHERE d >= {cutoff}")
    print(f"-- date: {rows_before} rows in {groups_before} groups, "
          f"{d_expired} past retention, {on_cutoff} on the cutoff")
    print(f"-- date: rows left {rows_after}, second call retired {retired}")

    expect.text(
        "retired" if rows_after < rows_before else f"RETIRED NOTHING ({rows_after})",
        "retired",
        "expire on a date column retires at least one group")
    expect.num(
        live_after, d_live,
        "NO row still inside the retention was dropped, on a date column")
    expect.text(
        "smaller" if rows_after < rows_before else f"UNCHANGED ({rows_after} of {rows_before})",
        "smaller",
        "and the date table really is smaller than it was")

    # THE ROUNDING, PINNED. A row dated exactly on the cutoff day is inside the
    # window by the `<` rule the timestamp arms use, and truncation must not move
    # it outside. This is the only arm that notices if the cutoff rounds the
    # other way.
    expect.num(
        _one(pgc_conn, f"SELECT count(*) FROM ttl_dt WHERE d = {cutoff}"), on_cutoff,
        "a row dated exactly on the cutoff is kept, so truncation errs toward keeping")
    expect.num(
        _one(pgc_conn, "SELECT count(*) FROM ttl_dt WHERE v <> 'v' || id"), 0,
        "every remaining date row reads back its own value")


def test_the_cutoff_is_the_sessions_own_date(pgc_conn, expect):
    """`timestamptz_timestamp` converts through the SESSION's TimeZone.

    So the cutoff a `date` column is compared against is the calling session's
    own date, and two sessions can expire different sets.

    IT IS INHERITED, NOT INTRODUCED. timestamptz is zone-independent; the
    timestamp arms already convert through the session zone, because a zone-naive
    column forces a choice, and `date` follows its sibling. What changes is the
    GRANULARITY: hours for a timestamp, a whole day of rows for a date.

    THE ARM PINS THE RULE, NOT A DIFFERENCE. Asserting that two zones disagree
    would be a coin toss on the time of day -- at 23:00 UTC, Midway is 12:00 on
    the SAME date and there is nothing to see. So each zone asserts the identity
    that holds in every zone at every instant, and the two cutoffs are printed so
    a reader can see they are free to differ.

    THE ZONE LIST MUST MATCH THE SHELL TWIN'S. The zone is interpolated into the
    check name, so a port over different zones asserts every property correctly
    and still cannot be graded against the suite it mirrors.
    """
    for tz in ("UTC", "Pacific/Midway"):
        table = "ttl_tz_" + "".join(c if c.isalnum() else "_" for c in tz)
        with pgc_conn.cursor() as cur:
            cur.execute(f"DROP TABLE IF EXISTS {table}")
            cur.execute(f"CREATE TABLE {table} (id int, d date, v text) USING pgcolumnar")
            cur.execute(
                f"SELECT pgcolumnar.set_options('{table}', stripe_row_limit => {GROUP})")
            cur.execute(
                f"INSERT INTO {table} SELECT g, (CURRENT_DATE - 7) + ((g - 1) / {GROUP}), "
                f"'v' || g FROM generate_series(1,7000) g")
            cur.execute(f"SET TimeZone = '{tz}'")
            cur.execute("SELECT ((now() AT TIME ZONE %s) - interval '4 days')::date", (tz,))
            cut = cur.fetchone()[0]
            cur.execute(
                f"SELECT pgcolumnar.set_options('{table}', ttl_column => 'd',"
                " ttl_interval => '4 days')")
            cur.execute(f"SELECT count(*) FROM {table} WHERE d >= %s", (cut,))
            want = cur.fetchone()[0]
            cur.execute(f"SELECT count(*) FROM {table}")
            before = cur.fetchone()[0]
            groups = _groups(pgc_conn, table)
            cur.execute(f"SELECT count(DISTINCT d) FROM {table}")
            dates = cur.fetchone()[0]
            cur.execute(f"SELECT DISTINCT count(*) FROM {table} GROUP BY d")
            per_date = [r[0] for r in cur.fetchall()]
            cur.execute(f"SELECT pgcolumnar.expire('{table}')")
            retired = cur.fetchone()[0]
            cur.execute(f"SELECT count(*) FROM {table}")
            after = cur.fetchone()[0]
            cur.execute(f"SELECT count(*) FROM {table} WHERE d < %s", (cut,))
            below = cur.fetchone()[0]
            cur.execute("RESET TimeZone")
        print(f"-- tz {tz}: cutoff {cut}, {before} rows -> {after}, "
              f"retired {retired} group(s)")

        expect.text(
            "straddles" if 0 < want < before else f"want {want} of {before}",
            "straddles",
            f"premise: in {tz} the fixture straddles that session's cutoff")

        # AND NO GROUP STRADDLES IT, which is what makes the identity below legal.
        # `expire` keeps a straddling group WHOLE, so "survivors == rows at or
        # after the cutoff" is STRONGER than the contract and holds only on a
        # geometry where every group sits entirely on one side. That geometry
        # comes from set_options above, so a change to it must fail as a FIXTURE
        # problem rather than as a date defect. Asserted from counts, because the
        # zone map stores its bounds encoded.
        expect.text(
            "one per group" if groups == dates and per_date == [GROUP]
            else f"{groups} groups, {dates} dates, rows per date {per_date}",
            "one per group",
            f"premise: one date per row group in {tz}, so no group straddles the cutoff")
        expect.num(
            after, want,
            f"expire in {tz} keeps exactly the rows at or after that session's cutoff")
        expect.num(
            below, 0,
            f"and no row older than {tz}'s own cutoff survives")
