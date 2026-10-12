"""pgcolumnar.partition_create_ahead keeps a time-partitioned parent ahead of now (#1297).

The function makes columnar partitions, each `width` wide and contiguous with the
highest existing upper bound, until they reach now plus `ahead` widths. It never
takes ACCESS EXCLUSIVE on the parent: a standalone CREATE followed by ATTACH
takes SHARE UPDATE EXCLUSIVE, which readers and writers pass (#1297 note 1).

THE SESSION'S ZONE IS WHERE THE FIRST PROTOTYPE BROKE. A `timestamp` key holds
wall-clock time with no zone. The prototype read its bounds as timestamptz in the
session's zone and wrote the next ones converted from UTC: in America/New_York
that left a four-hour gap between partitions, so a row at the boundary had
nowhere to go, and "daily" partitions made from Tokyo started at 15:00. So the
arms here continue from hand-made partitions in sessions west and east of UTC,
and check contiguity, routing at every boundary, coverage of the session's own
local now, and alignment to the width in the key's wall clock.

Independent of `test/partition_lifecycle.sh`: its own widths (six hours, not a
day), leads, zones (America/Los_Angeles, and Asia/Kolkata for a half-hour
offset) and rows.
"""

import re

import psycopg

LEAD = 5           # widths ahead of now
WIDTH = "6 hours"

BOUND = re.compile(r"FROM \('([^']+)'\) TO \('([^']+)'\)")


def _one(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        row = cur.fetchone()
    return row[0] if row else None


def _bounds(conn, parent):
    """[(from, to)] as the catalog prints them, in order of `from`."""
    with conn.cursor() as cur:
        cur.execute("SELECT pg_get_expr(c.relpartbound, c.oid) FROM pg_inherits i"
                    " JOIN pg_class c ON c.oid = i.inhrelid"
                    f" WHERE i.inhparent = '{parent}'::regclass")
        out = []
        for (expr,) in cur.fetchall():
            m = BOUND.search(expr)
            out.append((m.group(1), m.group(2)) if m else (expr, expr))
    return sorted(out)


def _contiguous(bounds):
    for (_, prev_to), (nxt_from, _) in zip(bounds, bounds[1:]):
        if nxt_from != prev_to:
            return f"break: {prev_to} then {nxt_from}"
    return "ok"


def _kids(conn, parent):
    return _one(conn, f"SELECT count(*) FROM pg_inherits WHERE inhparent = '{parent}'::regclass")


def _create_ahead(conn, parent, ahead=LEAD, width=WIDTH):
    return _one(conn, f"SELECT pgcolumnar.partition_create_ahead('{parent}', '{width}', {ahead})")


def _create_ahead_or_error(conn, parent, ahead=LEAD, width=WIDTH):
    """The count as text, or the SQLSTATE: a repeat call that errors must be
    reported by the arm that asked, not as an unhandled exception."""
    try:
        return str(_create_ahead(conn, parent, ahead, width))
    except psycopg.Error as e:
        return f"error {e.sqlstate}"


def test_partition_create_ahead(pgc_conn, expect):
    conn = pgc_conn
    expect.num(_one(conn, "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
                          " WHERE n.nspname = 'pgcolumnar' AND p.proname = 'partition_create_ahead'"), 1,
               "premise: the function exists")

    # From nothing. In UTC, six-hour widths align to 00/06/12/18, so reaching
    # now + 5 widths takes 6 partitions (the one holding now, and 5 more), or 7
    # when now + 5 widths lands exactly on a boundary -- it never does here,
    # because now() carries microseconds.
    with conn.cursor() as cur:
        cur.execute("SET TimeZone = 'UTC'")
        cur.execute("CREATE TABLE gauge (at timestamptz NOT NULL, reading float8) PARTITION BY RANGE (at)")
    made = _create_ahead(conn, "gauge")
    expect.num(made, LEAD + 1, "from no partitions it creates enough to reach now plus the lead")
    expect.num(_kids(conn, "gauge"), made, "premise: the parent now has the partitions it reported")
    expect.text(_one(conn, "SELECT string_agg(DISTINCT a.amname, ',') FROM pg_inherits i"
                           " JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_am a ON a.oid = c.relam"
                           " WHERE i.inhparent = 'gauge'::regclass"),
                "pgcolumnar", "every partition it creates is columnar")
    b = _bounds(conn, "gauge")
    widths = _one(conn, "SELECT count(DISTINCT t - f) FROM (VALUES "
                        + ", ".join(f"('{f}'::timestamptz, '{t}'::timestamptz)" for f, t in b)
                        + ") v(f, t)")
    expect.text(f"{_contiguous(b)}|{widths}", "ok|1", "they are contiguous, each one width wide")
    expect.text(str(_one(conn, f"SELECT now() + {LEAD} * interval '{WIDTH}' >= '{b[-1][0]}'::timestamptz"
                               f" AND now() + {LEAD} * interval '{WIDTH}' < '{b[-1][1]}'::timestamptz")),
                "True", "and they cover now() plus the lead")

    expect.text(_create_ahead_or_error(conn, "gauge"), "0", "a second call creates nothing")
    expect.text(_create_ahead_or_error(conn, "gauge", ahead=LEAD + 3), "3",
                "asking further ahead creates only the difference")

    with conn.cursor() as cur:
        cur.execute(f"INSERT INTO gauge SELECT now() + g * interval '17 min', g"
                    f" FROM generate_series(0, 77) g")
    expect.num(_one(conn, "SELECT count(*) FROM gauge"), 78, "rows within the covered range go in")
    expect.text(_one(conn, "SELECT string_agg(DISTINCT a.amname, ',') FROM gauge t"
                           " JOIN pg_class c ON c.oid = t.tableoid JOIN pg_am a ON a.oid = c.relam"),
                "pgcolumnar", "and land in columnar partitions")

    # The parent's lock, read inside the transaction that made the partitions.
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE gauge_lock (at timestamptz NOT NULL, reading float8) PARTITION BY RANGE (at)")
        cur.execute("BEGIN")
        cur.execute(f"SELECT pgcolumnar.partition_create_ahead('gauge_lock', '30 minutes', 9)")
        locked_made = cur.fetchone()[0]
        cur.execute("SELECT coalesce(string_agg(DISTINCT mode, ',' ORDER BY mode), 'none') FROM pg_locks"
                    " WHERE relation = 'gauge_lock'::regclass AND pid = pg_backend_pid()")
        locks = cur.fetchone()[0]
        cur.execute("ROLLBACK")
    expect.at_least(locked_made, 1, "premise: the call inside the transaction created partitions")
    expect.text(f"held: {locks}" if "AccessExclusiveLock" in locks else "none", "none",
                "it never takes AccessExclusiveLock on the parent")

    # West of UTC: continue from a hand-made partition, for both key types.
    for key in ("timestamp", "timestamptz"):
        t = f"west_{key}"
        with conn.cursor() as cur:
            cur.execute("SET TimeZone = 'America/Los_Angeles'")
            cur.execute(f"CREATE TABLE {t} (at {key} NOT NULL, reading float8) PARTITION BY RANGE (at)")
            cur.execute(f"CREATE TABLE {t}_seed PARTITION OF {t} FOR VALUES"
                        f" FROM (date_trunc('day', now() - interval '1 day')::{key})"
                        f" TO ((date_trunc('day', now() - interval '1 day') + interval '6 hours')::{key})"
                        " USING pgcolumnar")
        west = _create_ahead(conn, t, ahead=4)
        expect.at_least(west, 5, f"premise: a {key} parent continued from a hand-made partition, in a session west of UTC")
        expect.text(_contiguous(_bounds(conn, t)), "ok",
                    f"a {key} parent's partitions are contiguous across a non-UTC session")
        # One row at the lower bound of every partition: each must route.
        firsts = [f for f, _ in _bounds(conn, t)]
        routed = 0
        for f in firsts:
            try:
                with conn.cursor() as cur:
                    cur.execute(f"INSERT INTO {t} VALUES ('{f}'::{key}, 1)")
                routed += 1
            except psycopg.Error:
                pass
        expect.num(routed, len(firsts),
                   f"and a row at every boundary has exactly one partition to go to ({key})")
        with conn.cursor() as cur:
            cur.execute("SET TimeZone = 'UTC'")

    # East of UTC, at a half-hour offset: coverage of the session's own local now,
    # and alignment to the width in the key's wall clock.
    with conn.cursor() as cur:
        cur.execute("SET TimeZone = 'Asia/Kolkata'")
        cur.execute("CREATE TABLE east (at timestamp NOT NULL, reading float8) PARTITION BY RANGE (at)")
    east = _create_ahead(conn, "east", ahead=3)
    expect.at_least(east, 1, "premise: a timestamp parent was given partitions from a session east of UTC")
    eb = _bounds(conn, "east")
    local_target = _one(conn, f"SELECT (localtimestamp + 3 * interval '{WIDTH}')::text")
    expect.text(str(_one(conn, f"SELECT bool_or('{local_target}'::timestamp >= f AND '{local_target}'::timestamp < t)"
                               " FROM (VALUES " + ", ".join(f"('{f}'::timestamp, '{t}'::timestamp)" for f, t in eb)
                               + ") v(f, t)")),
                "True", "a timestamp parent made east of UTC covers the local now plus the lead")
    off = [f for f, _ in eb if not re.search(r" (00|06|12|18):00:00$", f)]
    expect.text(f"not on the width: {off[0]}" if off else "ok", "ok",
                "and its partitions start on the width's boundary in the key's own wall clock")
    with conn.cursor() as cur:
        cur.execute("SET TimeZone = 'UTC'")

    # Refused: a DEFAULT partition.
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE fallback (at timestamptz NOT NULL, reading float8) PARTITION BY RANGE (at)")
        cur.execute("CREATE TABLE fallback_rest PARTITION OF fallback DEFAULT USING pgcolumnar")
    try:
        _create_ahead(conn, "fallback")
        state = "ok"
    except psycopg.Error as e:
        state = e.sqlstate or "?"
    expect.text(state, "55000", "a parent with a DEFAULT partition is refused")
    expect.num(_kids(conn, "fallback"), 1, "and nothing was created for it")
