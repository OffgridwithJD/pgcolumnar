"""Incremental rollups, phase 1: append-only (#1294).

A rollup is a view over a partials table; refresh_rollup folds the rows of the
row groups appended since the last refresh, in ONE statement, so the group list,
the folded rows and the recorded groups share a snapshot. The design, its eight
points and the owner's decisions are on #1294.

THE ORACLE is a full recompute of the same GROUP BY, every time. Exactness was
fixed by the design so it cannot be loosened here: count, integer sum, min and
max exact; avg of an integer column exact too (numeric partials); avg of
float8 within a relative 1e-12. This file uses an integer avg, so it is exact.

Two things the shell twin found while the code was written, held here too: a
lateral per-group subquery pulled up into a join read every row group (a TID
range is built only from a relation's own restrictions), and every arm run as a
superuser bypassed the row-level security on the rollup catalogs, so an owner
and a stranger are tested as ordinary roles.

ON A PRIVATE DATABASE (`pgc_own_db`): the roles and pg_stat_reset. Independent
of `test/rollup.sh`: its own table, 15-minute buckets, aggregates (count, sum,
max, avg of an integer), zones, row counts and roles.
"""

import threading
import time

import psycopg

ORIGIN = "2025-12-29 06:00:00+00"
AGG_FUNCS = "{count,sum,max,avg}"
AGG_COLS = "{*,reading,temp,reading}"


def _one(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        row = cur.fetchone()
    return row[0] if row else None


def _state(conn, sql):
    try:
        return str(_one(conn, sql))
    except psycopg.Error as e:
        return e.sqlstate or "?"


def _load(conn, lo, hi, start):
    with conn.cursor() as cur:
        cur.execute(f"INSERT INTO feed SELECT '{start}'::timestamptz + (g - {lo}) * interval '23 s',"
                    f" g % 11, (g * 31337) % 65521, ((g * 2654435761) % 4093) / 7.0"
                    f" FROM generate_series({lo}::bigint, {hi}) g")


RECOMPUTE = (f"SELECT date_bin('15 minutes', at, '{ORIGIN}') AS bucket, sensor, count(*) AS count,"
             " sum(reading)::numeric AS sum_reading, max(temp) AS max_temp, avg(reading) AS avg_reading"
             " FROM feed GROUP BY 1, 2")


def _digest(conn, rel_sql):
    return _one(conn, "SELECT count(*) || '|' || md5(string_agg(bucket || ',' || sensor || ',' || count"
                      " || ',' || sum_reading || ',' || max_temp || ',' || avg_reading, ';'"
                      f" ORDER BY bucket, sensor)) FROM ({rel_sql}) x")


def _matches(conn, rollup="gauge_15m"):
    return _digest(conn, f"SELECT * FROM {rollup}")


def _oracle(conn):
    return _digest(conn, RECOMPUTE)


def _refresh(conn, rollup="gauge_15m"):
    return _state(conn, f"SELECT pgcolumnar.refresh_rollup('{rollup}')")


def test_rollup_phase_one(pgc_own_db, pgc_cluster, expect):
    conn = pgc_own_db
    dsn = pgc_cluster.dsn(dbname=_one(conn, "SELECT current_database()"))
    expect.num(_one(conn, "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
                          " WHERE n.nspname = 'pgcolumnar'"
                          " AND p.proname IN ('create_rollup', 'refresh_rollup', 'rebase_rollup')"), 3,
               "premise: the rollup functions exist")
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE feed (at timestamptz, sensor int, reading bigint, temp float8) USING pgcolumnar")
        cur.execute("SELECT pgcolumnar.set_options('feed', stripe_row_limit => 3000)")
    _load(conn, 1, 24000, "2026-02-01 00:00:00+00")
    expect.num(_one(conn, "SELECT count(*) FROM feed"), 24000, "premise: the source holds every row")

    with conn.cursor() as cur:
        cur.execute(f"SELECT pgcolumnar.create_rollup('gauge_15m', 'feed', 'at', '15 minutes', '{ORIGIN}',"
                    f" '{{sensor}}', '{AGG_FUNCS}', '{AGG_COLS}')")
    expect.text(_one(conn, "SELECT string_agg(attname, ',' ORDER BY attnum) FROM pg_attribute"
                           " WHERE attrelid = to_regclass('gauge_15m') AND attnum > 0 AND NOT attisdropped"),
                "bucket,sensor,count,sum_reading,max_temp,avg_reading",
                "premise: the rollup table exists with the documented columns")

    expect.text(_refresh(conn), "24000", "the first refresh folds every row")
    expect.text(_matches(conn), _oracle(conn), "and the rollup equals a full recompute")
    expect.text(_refresh(conn), "0", "a refresh with nothing new folds nothing")
    expect.text(_matches(conn), _oracle(conn), "and leaves the rollup as it was")

    _load(conn, 24001, 27000, "2026-02-08 00:00:00+00")
    _load(conn, 27001, 27900, "2026-02-01 03:00:00+00")      # late: old buckets
    expect.text(_refresh(conn), "3900",
                "a refresh after appends folds exactly the appended rows, late ones included")
    expect.text(_matches(conn), _oracle(conn), "and the rollup still equals a full recompute")

    # Rows committed while a refresh runs are the next refresh's.
    _load(conn, 27901, 28300, "2026-02-09 00:00:00+00")
    out = {}

    def paused():
        with psycopg.connect(dsn, autocommit=True) as c:
            c.execute("SET pgcolumnar.rollup_pause = on")
            out["folded"] = c.execute("SELECT pgcolumnar.refresh_rollup('gauge_15m')").fetchone()[0]
    th = threading.Thread(target=paused)
    th.start()
    time.sleep(0.8)
    _load(conn, 28301, 28520, "2026-02-09 05:00:00+00")
    th.join(60)
    expect.num(out.get("folded"), 400, "premise: the paused refresh folded what was there before it began")
    expect.text(_refresh(conn), "220", "the next refresh folds the rows committed during the last one, once")
    expect.text(_matches(conn), _oracle(conn), "and the rollup equals a full recompute")

    # Two refreshes at once.
    _load(conn, 28521, 30020, "2026-02-10 00:00:00+00")
    got = []

    def refresher():
        with psycopg.connect(dsn, autocommit=True) as c:
            got.append(c.execute("SELECT pgcolumnar.refresh_rollup('gauge_15m')").fetchone()[0])
    ts = [threading.Thread(target=refresher) for _ in range(2)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(60)
    expect.text(" ".join(str(x) for x in sorted(got)), "0 1500",
                "two refreshes started together fold the new rows once between them")
    expect.text(_matches(conn), _oracle(conn), "and the rollup equals a full recompute")

    # Zones.
    for zone, name in (("UTC", "z_utc"), ("America/St_Johns", "z_stjohns")):
        with conn.cursor() as cur:
            cur.execute(f"SET TimeZone = '{zone}'")
            cur.execute(f"SELECT pgcolumnar.create_rollup('{name}', 'feed', 'at', '15 minutes', '{ORIGIN}',"
                        f" '{{sensor}}', '{AGG_FUNCS}', '{AGG_COLS}')")
            cur.execute(f"SELECT pgcolumnar.refresh_rollup('{name}')")
            cur.execute("SET TimeZone = 'UTC'")
    expect.text(_matches(conn, "z_utc"), _matches(conn, "z_stjohns"),
                "refreshes from sessions in different time zones build the same rollup")
    expect.num(_one(conn, "SELECT count(*) FROM z_utc"), _one(conn, f"SELECT count(*) FROM ({RECOMPUTE}) z"),
               "premise: the zone rollups hold a row per key of the recompute")
    expect.at_least(_one(conn, "SELECT count(*) FROM z_utc"), 1, "premise: and that is not zero")

    # Cost, on a source of real size.
    _load(conn, 100001, 260000, "2026-03-01 00:00:00+00")
    expect.text(_refresh(conn), "160000", "a refresh folds a bulk append")
    expect.text(_matches(conn), _oracle(conn), "and the rollup equals a full recompute")
    _load(conn, 30021, 30820, "2026-02-11 00:00:00+00")
    with conn.cursor() as cur:
        cur.execute("SELECT pg_stat_force_next_flush()")
        cur.execute("SELECT pg_stat_reset()")
        cur.execute("SELECT pgcolumnar.refresh_rollup('gauge_15m')")
        cur.execute("SELECT pg_stat_force_next_flush()")
    read = _one(conn, "SELECT coalesce(heap_blks_read, 0) + coalesce(heap_blks_hit, 0)"
                      " FROM pg_statio_user_tables WHERE relname = 'feed'")
    pages = _one(conn, "SELECT pg_relation_size('feed') / 8192")
    print(f"-- refresh after an 800-row append read {read} of {pages} blocks")
    expect.at_least(read, 1, "premise: the refresh after a small append read the source at all")
    expect.at_least(pages - 5 * read if read else 0, 1,
                    "a refresh after a small append reads under a fifth of the source")
    expect.text(_matches(conn), _oracle(conn), "and the rollup equals a full recompute")

    # A rewrite of the source, and rebase.
    def identity():
        return _one(conn, "SELECT pgcolumnar.get_storage_id('feed') || ':' || string_agg(group_number::text, ','"
                          " ORDER BY group_number) FROM pgcolumnar.row_group"
                          " WHERE storage_id = pgcolumnar.get_storage_id('feed')")
    before = identity()
    with conn.cursor() as cur:
        cur.execute("SELECT pgcolumnar.vacuum('feed')")
    expect.text("renumbered" if identity() != before else "same", "renumbered",
                "premise: pgcolumnar.vacuum gave the source's row groups new identities")
    vb = _matches(conn)
    expect.at_least(_one(conn, "SELECT count(*) FROM gauge_15m"), 1, "premise: the rollup holds rows before the rewrite")
    expect.text(f"{_refresh(conn)}|{_matches(conn)}", f"55000|{vb}",
                "a refresh after the source was rewritten is refused, naming rebase_rollup")
    # Not through _state: a SQLSTATE such as 42883 is all digits and would read as a count.
    try:
        rebased = _one(conn, "SELECT pgcolumnar.rebase_rollup('gauge_15m')")
    except psycopg.Error:
        rebased = -1
    expect.at_least(rebased, 1, "rebase_rollup records the source's current row groups")
    expect.text(_matches(conn), vb, "and leaves the rollup's rows alone")
    _load(conn, 30821, 31420, "2026-02-12 00:00:00+00")
    expect.text(_refresh(conn), "600", "after a rebase the next refresh folds exactly the appended rows")
    expect.text(_matches(conn), _oracle(conn), "and the rollup equals a full recompute")

    # Phase 1 refuses anything but appends.
    before = _matches(conn)
    expect.at_least(_one(conn, "SELECT count(*) FROM gauge_15m"), 1, "premise: the rollup holds rows before the delete")
    with conn.cursor() as cur:
        cur.execute("DELETE FROM feed WHERE sensor = 4 AND at < '2026-02-01 01:00:00+00'")
    expect.text(_refresh(conn), "0A000", "a refresh after a delete is refused until phase 2")
    expect.text(_matches(conn), before, "and the refused refresh changed nothing")

    # Ordinary roles: row-level security on the rollup catalogs is what is tested.
    with conn.cursor() as cur:
        for r in ("rp_owner", "rp_other"):
            cur.execute(f"DO $$ BEGIN CREATE ROLE {r}; EXCEPTION WHEN duplicate_object THEN NULL; END $$")
            cur.execute(f"GRANT USAGE, CREATE ON SCHEMA public TO {r}")
            cur.execute(f"GRANT USAGE ON SCHEMA pgcolumnar TO {r}")

    def as_role(role, sql):
        with psycopg.connect(dsn, autocommit=True) as c:
            c.execute(f"SET ROLE {role}")
            try:
                row = c.execute(sql).fetchone()
                return str(row[0]) if row else ""
            except psycopg.Error as e:
                return e.sqlstate or "?"
    as_role("rp_owner", "CREATE TABLE meter (at timestamptz, kwh int) USING pgcolumnar")
    as_role("rp_owner", "INSERT INTO meter SELECT '2026-04-01'::timestamptz + g * interval '7 min', g % 50"
                        " FROM generate_series(1, 3000) g")
    expect.text(as_role("rp_owner", f"SELECT pgcolumnar.create_rollup('meter_daily', 'meter', 'at', '1 day',"
                                    f" '{ORIGIN}', '{{}}', '{{count,max}}', '{{*,kwh}}')"),
                "meter_daily", "a table's owner, not a superuser, creates a rollup of it")
    expect.text(as_role("rp_owner", "SELECT pgcolumnar.refresh_rollup('meter_daily')"), "3000", "and refreshes it")
    expect.text(as_role("rp_owner", "SELECT string_agg(bucket || ':' || count || ':' || max_kwh, ' ' ORDER BY bucket)"
                                    " FROM meter_daily"),
                _one(conn, f"SELECT string_agg(b || ':' || n || ':' || m, ' ' ORDER BY b) FROM"
                           f" (SELECT date_bin('1 day', at, '{ORIGIN}') b, count(*) n, max(kwh) m FROM meter GROUP BY 1) x"),
                "and reads what a recompute gives")
    expect.text(f"{as_role('rp_other', 'SELECT count(*) FROM pgcolumnar.rollup')} "
                f"{as_role('rp_other', 'SELECT count(*) FROM pgcolumnar.rollup_group')}", "0 0",
                "another role sees none of its rollup catalog rows")
    expect.text(as_role("rp_other", "SELECT pgcolumnar.refresh_rollup('public.meter_daily')"), "42704",
                "and cannot refresh it")

    # access_method: a heap rollup folds and matches the same way.
    with conn.cursor() as cur:
        cur.execute(f"SELECT pgcolumnar.create_rollup('heap_15m', 'feed', 'at', '15 minutes', '{ORIGIN}',"
                    f" '{{sensor}}', '{AGG_FUNCS}', '{AGG_COLS}', 'heap')")
    am = _one(conn, "SELECT a.amname FROM pg_class c JOIN pg_am a ON a.oid = c.relam"
                    " WHERE c.oid = 'heap_15m__partials'::regclass")
    folded = _refresh(conn, "heap_15m")
    expect.text(f"{am}|{folded.isdigit() and int(folded) > 0}|{_matches(conn, 'heap_15m')}",
                f"heap|True|{_oracle(conn)}",
                "a rollup kept in a heap table refreshes and equals a full recompute")

    # REPEATABLE READ is refused: its snapshot would predate the refresh's lock.
    with psycopg.connect(dsn, autocommit=True) as c:
        c.execute("BEGIN ISOLATION LEVEL REPEATABLE READ")
        try:
            c.execute("SELECT pgcolumnar.refresh_rollup('z_utc')")
            rr = "ok"
        except psycopg.Error as e:
            rr = e.sqlstate
        c.execute("ROLLBACK")
    expect.text(rr, "25000", "a refresh at REPEATABLE READ is refused")

    # Refused at creation.
    def refused(name, width, funcs, cols):
        return _state(conn, f"SELECT pgcolumnar.create_rollup('{name}', 'feed', 'at', '{width}', '{ORIGIN}',"
                            f" '{{}}', '{funcs}', '{cols}')")
    expect.text(refused("q_m", "2 months", "{count}", "{*}"), "22023", "a width with months is refused")
    expect.text(refused("q_p", "1 hour", "{stddev}", "{temp}"), "22023", "an aggregate that does not combine is refused")
    expect.text(refused("q_l", "1 hour", "{count,max}", "{*}"), "22023",
                "aggregate functions and columns of different lengths are refused")
    expect.text(refused("q_c", "1 hour", "{max}", "{humidity}"), "22023",
                "an aggregate column the source does not have is refused")
    expect.text(refused("q_s", "1 hour", "{max}", "{*}"), "22023", "* with anything but count is refused")
    expect.num(_one(conn, "SELECT count(*) FROM pg_class WHERE relname IN ('q_m', 'q_p', 'q_l', 'q_c', 'q_s')"), 0,
               "premise: and no refused rollup left a table behind")
