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
    # concat_ws over coalesce: a plain || turns a row with any NULL into NULL, and
    # string_agg drops it, so NULL keys would be compared by their absence.
    return _one(conn, "SELECT count(*) || '|' || md5(string_agg(concat_ws(',', coalesce(bucket::text, '~'),"
                      " coalesce(sensor::text, '~'), count, coalesce(sum_reading::text, '~'),"
                      " coalesce(max_temp::text, '~'), coalesce(avg_reading::text, '~')), ';'"
                      f" ORDER BY bucket NULLS FIRST, sensor NULLS FIRST)) FROM ({rel_sql}) x")


def _matches(conn, rollup="gauge_15m"):
    return _digest(conn, f"SELECT * FROM {rollup}")


def _oracle(conn):
    return _digest(conn, RECOMPUTE)


def _refresh(conn, rollup="gauge_15m"):
    return _state(conn, f"SELECT pgcolumnar.refresh_rollup('{rollup}')")


def _folds(conn, rollup="gauge_15m"):
    # "folded", or the SQLSTATE: a count of five digits would read as one.
    try:
        _one(conn, f"SELECT pgcolumnar.refresh_rollup('{rollup}')")
        return "folded"
    except psycopg.Error as e:
        return e.sqlstate or "?"


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
                "the rollup table exists with the documented columns")

    expect.text(_refresh(conn), "24000", "the first refresh folds every row")
    expect.text(_matches(conn), _oracle(conn), "and after the first refresh the rollup equals a full recompute")
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
    expect.num(out.get("folded"), 400, "the paused refresh folded what was there before it began")
    expect.text(_refresh(conn), "220", "the next refresh folds the rows committed during the last one, once")
    expect.text(_matches(conn), _oracle(conn), "and after the refresh that ran beside an insert the rollup equals a full recompute")

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
    expect.text(_matches(conn), _oracle(conn), "and after two refreshes started together the rollup equals a full recompute")

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
               "the zone rollups hold a row per key of the recompute")
    expect.at_least(_one(conn, "SELECT count(*) FROM z_utc"), 1, "and that is not zero")

    # Cost, on a source of real size.
    _load(conn, 100001, 260000, "2026-03-01 00:00:00+00")
    expect.text(_refresh(conn), "160000", "a refresh folds a bulk append")
    expect.text(_matches(conn), _oracle(conn), "and after the bulk append the rollup equals a full recompute")
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
    expect.at_least(read, 1, "the refresh after a small append read the source at all")
    expect.at_least(pages - 5 * read if read else 0, 1,
                    "a refresh after a small append reads under a fifth of the source")
    expect.text(_matches(conn), _oracle(conn), "and after the small append the rollup equals a full recompute")

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
    expect.at_least(_one(conn, "SELECT count(*) FROM gauge_15m"), 1, "the rollup holds rows before the rewrite")
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
    expect.text(_matches(conn), _oracle(conn), "and after the rebase the rollup equals a full recompute")

    # Phase 2: a delete, update or rewrite makes the buckets of the changed groups
    # dirty; the refresh recomputes them and leaves every other partial alone (a
    # recomputed partial is a new row, so a new ctid). The groups were last
    # recorded by rebase_rollup, so this also needs rebase to record time ranges.
    far = "bucket >= '2026-02-04 00:00:00+00'"     # past every group the delete reaches
    at_far = ("SELECT count(*) || '|' || md5(string_agg(ctid::text, ',' ORDER BY ctid))"
              f" FROM gauge_15m__partials WHERE {far}")
    far_before = _one(conn, at_far)
    expect.at_least(_one(conn, f"SELECT count(*) FROM gauge_15m__partials WHERE {far}"), 1,
                    "premise: the rollup holds partials the delete below cannot reach")
    with conn.cursor() as cur:
        cur.execute("DELETE FROM feed WHERE sensor = 4 AND at < '2026-02-01 01:00:00+00'")
    expect.text(_folds(conn), "folded",
                "a refresh after a delete is not refused")
    expect.text(_matches(conn), _oracle(conn), "and after a delete the rollup equals a full recompute")
    expect.text(_one(conn, at_far), far_before,
                "and the refresh rewrote no partial outside the changed groups' time range")
    expect.text(_refresh(conn), "0", "and the next refresh, with nothing changed since, recomputes nothing")

    with conn.cursor() as cur:
        cur.execute("UPDATE feed SET at = at + interval '3 days 7 hours'"
                    " WHERE at >= '2026-02-02 08:00:00+00' AND at < '2026-02-02 08:10:00+00'")
    _refresh(conn)
    expect.text(_matches(conn), _oracle(conn),
                "after an update that moves rows to another bucket the rollup equals a full recompute")

    # A dirty bucket and a new group in one refresh: the recompute already counts
    # the new rows in the dirty bucket. 150 rows an hour apart outrun any group.
    with conn.cursor() as cur:
        cur.execute("DELETE FROM feed WHERE sensor = 2 AND at >= '2026-02-02 20:00:00+00'"
                    " AND at < '2026-02-02 20:15:00+00'")
        cur.execute("INSERT INTO feed SELECT '2026-02-02 20:05:00+00'::timestamptz + g * interval '1 hour',"
                    " 2, g * 3, g / 7.0 FROM generate_series(0, 149) g")
    _refresh(conn)
    expect.text(_matches(conn), _oracle(conn),
                "after a delete and an append that straddles its bucket, a refresh counts the new rows once")

    with conn.cursor() as cur:
        cur.execute("DELETE FROM feed WHERE at >= '2026-02-05 00:00:00+00' AND at < '2026-02-05 09:00:00+00'")
    try:
        rewrote = _one(conn, "SELECT pgcolumnar.compact_rewrite('feed', 0.02)")
    except psycopg.Error:
        rewrote = -1
    expect.at_least(rewrote, 1, "premise: compact_rewrite rewrote a row group")
    _refresh(conn)
    expect.text(_matches(conn), _oracle(conn), "after compact_rewrite the rollup equals a full recompute")
    expect.text(_refresh(conn), "0", "and the refresh after the rewrite recomputes nothing")

    # The TID range of each row group comes from the access method's own mapping
    # (row_tid), so it holds exactly the group's rows at any block size.
    bad, groups = conn.execute(
        "SELECT count(*) FILTER (WHERE got <> want), count(*) FROM ("
        " SELECT g.row_count - g.deleted_count AS want,"
        "  (SELECT count(*) FROM feed WHERE ctid >= pgcolumnar.row_tid(g.first_row_number)"
        "     AND ctid <= pgcolumnar.row_tid(g.first_row_number + g.row_count - 1)) AS got"
        " FROM pgcolumnar.rollup_source_groups('feed') g) x").fetchone()
    expect.text(f"{bad}|{groups}",
                f"0|{_one(conn, 'SELECT count(*) FROM pgcolumnar.row_group WHERE storage_id = pgcolumnar.get_storage_id(' + chr(39) + 'feed' + chr(39) + ')')}",
                "each row group's TID range holds exactly that group's rows")

    # NULL keys and NULL timestamps (#1319 review): keys match with IS NOT
    # DISTINCT FROM, and a NULL ts is a NULL bucket.
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE holes (at timestamptz, sensor int, reading bigint, temp float8) USING pgcolumnar")
        cur.execute("SELECT pgcolumnar.set_options('holes', stripe_row_limit => 1000)")
        cur.execute("INSERT INTO holes SELECT CASE WHEN g % 13 = 0 THEN NULL ELSE '2026-07-01'::timestamptz"
                    " + g * interval '47 s' END, CASE WHEN g % 6 = 0 THEN NULL ELSE g % 4 END, g, g / 4.0"
                    " FROM generate_series(1, 2600) g")
        cur.execute(f"SELECT pgcolumnar.create_rollup('holes_15m', 'holes', 'at', '15 minutes', '{ORIGIN}',"
                    f" '{{sensor}}', '{AGG_FUNCS}', '{AGG_COLS}')")
        cur.execute("SELECT pgcolumnar.refresh_rollup('holes_15m')")
        cur.execute("INSERT INTO holes SELECT CASE WHEN g % 13 = 0 THEN NULL ELSE '2026-07-01'::timestamptz"
                    " + g * interval '47 s' END, CASE WHEN g % 6 = 0 THEN NULL ELSE g % 4 END, g, g / 4.0"
                    " FROM generate_series(2601, 3900) g")
    expect.text(_refresh(conn, "holes_15m"), "1300", "the second refresh of the NULL-key rollup folded the append")
    holes_recompute = RECOMPUTE.replace("FROM feed", "FROM holes")
    nulls = f"SELECT count(*) FILTER (WHERE sensor IS NULL) || ' ' || count(*) FILTER (WHERE bucket IS NULL) FROM ({{}}) z"
    expect.text(f"{_digest(conn, 'SELECT * FROM holes_15m')}|{_one(conn, nulls.format('SELECT * FROM holes_15m'))}",
                f"{_digest(conn, holes_recompute)}|{_one(conn, nulls.format(holes_recompute))}",
                "a rollup with NULL keys and NULL timestamps equals a full recompute")
    expect.at_least(_one(conn, f"SELECT count(*) FROM ({holes_recompute}) z WHERE sensor IS NULL OR bucket IS NULL"), 2,
                    "premise: and the fixture has NULL-key and NULL-bucket groups")
    with conn.cursor() as cur:
        cur.execute("DELETE FROM holes WHERE at IS NULL AND sensor = 1")
    _refresh(conn, "holes_15m")
    expect.text(_digest(conn, "SELECT * FROM holes_15m"), _digest(conn, holes_recompute),
                "after a delete of rows whose ts is NULL the NULL-bucket rollup equals a full recompute")

    # Retention keeps history: groups expire retires (pgcolumnar.retired_group,
    # #1314) leave the snapshot, and their buckets keep what they folded.
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE aged (at timestamptz, reading int) USING pgcolumnar")
        cur.execute("SELECT pgcolumnar.set_options('aged', stripe_row_limit => 1000)")
        cur.execute("INSERT INTO aged SELECT now() - interval '90 days' + g * interval '45 s', g % 97"
                    " FROM generate_series(1, 3200) g")
        cur.execute("INSERT INTO aged SELECT now() - interval '3 days' + g * interval '20 s', g % 89"
                    " FROM generate_series(1, 1600) g")
        cur.execute(f"SELECT pgcolumnar.create_rollup('aged_hourly', 'aged', 'at', '1 hour', '{ORIGIN}', '{{}}',"
                    " '{count,max}', '{*,reading}')")
    expect.text(_refresh(conn, "aged_hourly"), "4800", "the history rollup folded every row")
    hist = "SELECT md5(string_agg(bucket || ':' || count || ':' || max_reading, ',' ORDER BY bucket)) FROM aged_hourly"
    before_hist = _one(conn, hist)
    old_buckets = _one(conn, "SELECT count(*) FROM aged_hourly WHERE bucket < now() - interval '60 days'")
    expect.at_least(old_buckets, 1, "the history rollup holds old buckets")
    with conn.cursor() as cur:
        cur.execute("SELECT pgcolumnar.set_options('aged', ttl_column => 'at', ttl_interval => '14 days')")
    expect.at_least(_one(conn, "SELECT pgcolumnar.expire('aged')"), 1, "premise: expire retired the old row groups")
    expect.text(f"{_refresh(conn, 'aged_hourly')}|{_one(conn, hist)}", f"0|{before_hist}",
                "a refresh after retention folds nothing, refuses nothing, and keeps every bucket")
    expect.num(_one(conn, "SELECT count(*) FROM pgcolumnar.rollup_group rg JOIN pgcolumnar.retired_group t"
                          " ON t.group_number = rg.group_number AND t.storage_id = pgcolumnar.get_storage_id('aged')"
                          " WHERE rg.rollup = 'aged_hourly'::regclass"), 0,
               "and the rollup no longer records the groups retention retired")
    with conn.cursor() as cur:
        cur.execute("INSERT INTO aged SELECT now() - interval '5 hours' + g * interval '3 s', g % 83"
                    " FROM generate_series(1, 700) g")
    expect.text(_refresh(conn, "aged_hourly"), "700", "and after retention an append still folds")
    recent = _one(conn, "SELECT md5(string_agg(bucket || ':' || count || ':' || max_reading, ',' ORDER BY bucket))"
                        " FROM aged_hourly WHERE bucket >= now() - interval '14 days'")
    recomputed = _one(conn, f"SELECT md5(string_agg(b || ':' || n || ':' || m, ',' ORDER BY b)) FROM"
                            f" (SELECT date_bin('1 hour', at, '{ORIGIN}') b, count(*) n, max(reading) m FROM aged"
                            " WHERE at >= now() - interval '14 days' GROUP BY 1) x WHERE b >= now() - interval '14 days'")
    still_old = _one(conn, "SELECT count(*) FROM aged_hourly WHERE bucket < now() - interval '60 days'")
    expect.text(f"{recent}|{still_old}", f"{recomputed}|{old_buckets}",
                "and the recent buckets equal a recompute, while the expired ones keep their history")

    # History and dirty buckets: a bucket that also holds a retired group's rows
    # cannot be recomputed, so that refresh is refused and changes nothing; a
    # delete whose buckets hold no history folds. One group per INSERT: OLD
    # retires, KEPT shares OLD's hour H and reaches past the cutoff, LATE is
    # days later.
    h = f"date_bin('1 hour', now() - interval '20 days', '{ORIGIN}')"

    def layer(table):
        with conn.cursor() as cur:
            cur.execute(f"CREATE TABLE {table} (at timestamptz, reading int) USING pgcolumnar")
            cur.execute(f"SELECT pgcolumnar.set_options('{table}', stripe_row_limit => 5000)")
            cur.execute(f"INSERT INTO {table} SELECT {h} + g * interval '7 s', g FROM generate_series(1, 300) g")
            cur.execute(f"INSERT INTO {table} SELECT {h} + interval '40 min' + g * interval '10 min', g"
                        " FROM generate_series(1, 1000) g")
            cur.execute(f"INSERT INTO {table} SELECT {h} + interval '12 days' + g * interval '1 min', g"
                        " FROM generate_series(1, 900) g")
            cur.execute(f"SELECT pgcolumnar.create_rollup('{table}_hourly', '{table}', 'at', '1 hour', '{ORIGIN}',"
                        " '{}', '{count,max}', '{*,reading}')")
            cur.execute(f"SELECT pgcolumnar.refresh_rollup('{table}_hourly')")
            cur.execute(f"SELECT pgcolumnar.set_options('{table}', ttl_column => 'at', ttl_interval => '14 days')")
            cur.execute(f"SELECT pgcolumnar.expire('{table}')")
    layer("layered")
    expect.text(_one(conn, f"SELECT count(*) FILTER (WHERE at < {h} + interval '40 min') || '|'"
                           f" || count(*) FILTER (WHERE at >= {h} + interval '40 min' AND at < {h} + interval '1 hour')"
                           " FROM layered"), "0|1",
                "premise: expire retired the group in bucket D alone and kept the one that shares it")
    lq = "SELECT md5(string_agg(bucket || ':' || count || ':' || max_reading, ',' ORDER BY bucket)) FROM layered_hourly"
    lr = (f"SELECT md5(string_agg(b || ':' || n || ':' || m, ',' ORDER BY b)) FROM (SELECT date_bin('1 hour', at,"
          f" '{ORIGIN}') b, count(*) n, max(reading) m FROM layered GROUP BY 1) x")
    with conn.cursor() as cur:
        cur.execute(f"DELETE FROM layered WHERE at >= {h} + interval '12 days 5 hours' AND reading % 3 = 0")
    expect.text(f"{_folds(conn, 'layered_hourly')}|{_one(conn, f'{lq} WHERE bucket > {h}')}"
                f"|{_one(conn, f'SELECT count || chr(58) || max_reading FROM layered_hourly WHERE bucket = {h}')}",
                f"folded|{_one(conn, f'{lr} WHERE b > {h}')}|301:300",
                "a delete in buckets with no history, next to retired ones, folds: "
                "those buckets equal a recompute and D keeps its history")
    before_layered = _one(conn, lq)
    with conn.cursor() as cur:
        cur.execute(f"DELETE FROM layered WHERE at >= {h} + interval '2 hours' AND at < {h} + interval '3 hours'")
    expect.text(f"{_refresh(conn, 'layered_hourly')}|{_one(conn, lq)}", f"0A000|{before_layered}",
                "a delete in a bucket that holds retired history is refused, and the rollup is unchanged")

    # No refresh between expire and the delete: the same refresh retires the
    # history that blocks it.
    layer("relayered")
    rq = lq.replace("layered_hourly", "relayered_hourly")
    before_re = _one(conn, rq)
    with conn.cursor() as cur:
        cur.execute(f"DELETE FROM relayered WHERE at >= {h} + interval '2 hours' AND at < {h} + interval '3 hours'")
    expect.text(f"{_refresh(conn, 'relayered_hourly')}|{_one(conn, rq)}", f"0A000|{before_re}",
                "a delete in a bucket whose history the same refresh retires is refused, and the rollup is unchanged")

    # Rows deleted from a group expire then retires (found on #1328): they cannot
    # be recomputed, and history would keep counting them, so the refresh refuses.
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE thinned (at timestamptz, reading int) USING pgcolumnar")
        cur.execute("SELECT pgcolumnar.set_options('thinned', stripe_row_limit => 2000)")
        cur.execute("INSERT INTO thinned SELECT now() - interval '45 days' + g * interval '2 s', g"
                    " FROM generate_series(1, 1500) g")
        cur.execute("INSERT INTO thinned SELECT now() - interval '2 days' + g * interval '2 s', g"
                    " FROM generate_series(1, 1500) g")
        cur.execute(f"SELECT pgcolumnar.create_rollup('thinned_hourly', 'thinned', 'at', '1 hour', '{ORIGIN}',"
                    " '{}', '{count,max}', '{*,reading}')")
        cur.execute("SELECT pgcolumnar.refresh_rollup('thinned_hourly')")
        cur.execute("DELETE FROM thinned WHERE at < now() - interval '14 days' AND reading % 5 = 0")
        cur.execute("SELECT pgcolumnar.set_options('thinned', ttl_column => 'at', ttl_interval => '14 days')")
    expect.num(_one(conn, "SELECT pgcolumnar.expire('thinned')"), 1,
               "premise: expire retired the group the delete thinned")
    tq = "SELECT string_agg(bucket || ':' || count || ':' || max_reading, ',' ORDER BY bucket) FROM thinned_hourly"
    before_thin = _one(conn, tq)
    expect.text(f"{_refresh(conn, 'thinned_hourly')}|{_one(conn, tq)}", f"0A000|{before_thin}",
                "a delete in a group that expire then retires is refused, and the rollup is unchanged")

    # A day is 24 hours to date_bin in every zone. Europe/Berlin moves its clocks
    # at 01:00 UTC on 2026-03-29, inside the bucket [03-28 06:00, 03-29 06:00) UTC
    # (ORIGIN is at 06:00), so that bucket is 23 hours long in Berlin. It must be
    # recomputed to its end: the rows run to 05:40 UTC. (Rows ending at 23:40 UTC
    # first, a bucket the switch is not in, left this arm green under the mutation.)
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE springs (at timestamptz, reading int) USING pgcolumnar")
        cur.execute("SELECT pgcolumnar.set_options('springs', stripe_row_limit => 4000)")
        cur.execute("INSERT INTO springs SELECT '2026-03-27 06:00:00+00'::timestamptz + g * interval '4 min', g"
                    " FROM generate_series(1, 715) g")
        cur.execute(f"SELECT pgcolumnar.create_rollup('springs_daily', 'springs', 'at', '1 day', '{ORIGIN}',"
                    " '{}', '{count,max}', '{*,reading}')")
        cur.execute("SELECT pgcolumnar.refresh_rollup('springs_daily')")
        cur.execute("DELETE FROM springs WHERE reading = 2")
        cur.execute("SET TimeZone = 'Europe/Berlin'")
        cur.execute("SELECT pgcolumnar.refresh_rollup('springs_daily')")
        cur.execute("SET TimeZone = 'UTC'")
    expect.text(_one(conn, "SELECT string_agg(bucket || ':' || count || ':' || max_reading, ',' ORDER BY bucket)"
                           " FROM springs_daily"),
                _one(conn, f"SELECT string_agg(b || ':' || n || ':' || m, ',' ORDER BY b) FROM (SELECT"
                           f" date_bin('1 day', at, '{ORIGIN}') b, count(*) n, max(reading) m FROM springs GROUP BY 1) x"),
                "a refresh in a zone with a DST change recomputes a whole day bucket")

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
    # create_rollup reads the source's storage id through get_storage_id, which
    # refuses a caller that cannot SELECT the table: refused at creation.
    expect.text(as_role("rp_other", f"SELECT pgcolumnar.create_rollup('other_daily', 'public.meter', 'at', '1 day',"
                                    f" '{ORIGIN}', '{{}}', '{{count}}', '{{*}}')"),
                "42501", "a role that cannot read the source cannot create a rollup of it")

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
    # More columns than functions, so only the length check can catch it.
    expect.text(refused("q_l", "1 hour", "{count}", "{*,temp}"), "22023",
                "aggregate functions and columns of different lengths are refused")
    # Under min, which has no "cannot be folded" check to catch it first.
    expect.text(refused("q_c", "1 hour", "{min}", "{humidity}"), "22023",
                "an aggregate column the source does not have is refused")
    expect.text(refused("q_s", "1 hour", "{max}", "{*}"), "22023", "* with anything but count is refused")
    expect.num(_one(conn, "SELECT count(*) FROM pg_class WHERE relname IN ('q_m', 'q_p', 'q_l', 'q_c', 'q_s')"), 0,
               "and no refused rollup left a table behind")
