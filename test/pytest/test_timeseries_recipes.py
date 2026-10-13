"""The time-series recipes in docs/how-to.md answer what they claim (#1296).

Gap filling, last observation carried forward (LOCF) and linear interpolation are
recipes rather than features: phase 0 on #1296 measured core SQL fast enough on
columnar, with the vectorized grouped node still under the LEFT JOIN. So the
deliverable is the recipe, and this file holds each one to a reference.

Independent of `test/timeseries_recipes.sh`. The recipes are read from the
document, as the shell suite reads them, because the document is what is under
test. Everything else is this file's own: the rows are generated in Python and
inserted, and the reference is computed in Python from those same rows, so it
shares nothing with the shell suite's plpgsql reference. Check names match so the
pair can be graded by name.

The fixture's 24 hours hold every case a recipe can get wrong: an empty first
hour, a run of empty hours, an hour with some NULL values, an hour of only NULL
values, and two empty last hours. Values grow as the square of the hour, so a
line through the wrong neighbours lands on the wrong value, and every value is a
multiple of 1/16, so every comparison is exact in float8.
"""

import datetime
import pathlib
import re

DOC = pathlib.Path(__file__).resolve().parents[2] / "docs" / "how-to.md"
T0 = datetime.datetime(2026, 10, 1, tzinfo=datetime.timezone.utc)
EMPTY = {0, 3, 4, 5, 22, 23}


def _recipe(heading):
    """-> the first ```sql block after `heading` in the how-to, its ';' removed."""
    text = DOC.read_text()
    parts = text.split("\n" + heading + "\n", 1)
    if len(parts) != 2:
        return None
    m = re.search(r"```sql\n(.*?)```", parts[1], re.S)
    return m.group(1).strip().rstrip(";") if m else None


def _rows():
    """-> (ts, v) for the fixture: every 10 minutes in each hour that has data."""
    out = []
    for h in range(24):
        if h in EMPTY:
            continue
        for k in range(6):
            ts = T0 + datetime.timedelta(hours=h, minutes=10 * k)
            if h == 7 or (h == 6 and k % 2 == 0):
                v = None
            else:
                v = (h * h * 4 + k % 4) / 4.0
            out.append((ts, v))
    return out


def _reference(rows):
    """-> per hour: (average, carried, interpolated), computed from the raw rows."""
    by_hour = {h: [] for h in range(24)}
    for ts, v in rows:
        if v is not None:
            by_hour[int((ts - T0).total_seconds() // 3600)].append(v)
    avg = [sum(by_hour[h]) / len(by_hour[h]) if by_hour[h] else None for h in range(24)]
    ref = []
    for h in range(24):
        prev = next((p for p in range(h, -1, -1) if avg[p] is not None), None)
        nxt = next((n for n in range(h, 24) if avg[n] is not None), None)
        locf = avg[prev] if prev is not None else None
        if avg[h] is not None:
            interp = avg[h]
        elif prev is None or nxt is None:
            interp = None
        else:
            interp = avg[prev] + (avg[nxt] - avg[prev]) * (h - prev) / (nxt - prev)
        ref.append((avg[h], locf, interp))
    return ref


def _fmt(pairs):
    """-> 'HH=value ...' with values rounded to 9 places, so a mismatch prints."""
    return " ".join(f"{b.astimezone(datetime.timezone.utc):%H}="
                    + ("NULL" if x is None else f"{round(x, 9):.9f}") for b, x in pairs)


def _query(conn, sql, cols):
    with conn.cursor() as cur:
        cur.execute(f"SELECT {cols} FROM ({sql}) r ORDER BY 1")
        return [(row[0], row[1]) for row in cur.fetchall()]


def _expected(column):
    ref = _reference(_rows())
    return _fmt([(T0 + datetime.timedelta(hours=h), ref[h][column]) for h in range(24)])


def _setup(conn):
    conn.execute("CREATE TABLE readings (ts timestamptz, v float8) USING pgcolumnar")
    with conn.cursor() as cur:
        cur.executemany("INSERT INTO readings VALUES (%s, %s)", _rows())


def test_the_recipes_are_in_the_how_to(expect):
    fill, locf, interp = (_recipe("### Fill empty buckets"),
                          _recipe("### Carry the last value forward"),
                          _recipe("### Interpolate between known values"))
    expect.num(1 if fill and "generate_series" in fill else 0, 1,
               "the how-to gives the gap-fill recipe")
    expect.num(1 if locf and "readings" in locf else 0, 1,
               "the how-to gives the LOCF recipe")
    expect.num(1 if interp and "readings" in interp else 0, 1,
               "the how-to gives the interpolation recipe")


def test_each_recipe_matches_the_reference(pgc_conn, expect):
    _setup(pgc_conn)
    am = pgc_conn.execute("SELECT a.amname FROM pg_class c JOIN pg_am a ON a.oid = c.relam"
                          " WHERE c.oid = 'readings'::regclass").fetchone()[0]
    expect.text(am, "pgcolumnar", "premise: the readings table is columnar")
    ref = _reference(_rows())
    expect.text(f"{len(ref)}/{sum(1 for a, _, _ in ref if a is None)}", "24/7",
                "premise: the reference has 24 hours, 6 of them empty and one all-NULL")

    fill = _recipe("### Fill empty buckets") or "SELECT NULL::timestamptz, NULL::float8 WHERE false"
    locf = _recipe("### Carry the last value forward") or "SELECT NULL::timestamptz AS bucket, NULL::float8 AS avg_v_locf WHERE false"
    interp = _recipe("### Interpolate between known values") or "SELECT NULL::timestamptz AS bucket, NULL::float8 AS avg_v_interp WHERE false"
    expect.text(_fmt(_query(pgc_conn, fill, "*")), _expected(0),
                "the gap-fill recipe returns every bucket, empty ones as NULL")
    expect.text(_fmt(_query(pgc_conn, locf, "bucket, avg_v_locf")), _expected(1),
                "the LOCF recipe carries the last value forward, and leaves a leading gap NULL")
    expect.text(_fmt(_query(pgc_conn, interp, "bucket, avg_v_interp")), _expected(2),
                "the interpolation recipe fills a gap linearly, and leaves both ends NULL")

    # date_trunc truncates in the session's zone; at a half-hour offset its
    # buckets start at :30 UTC and match none of the series. date_bin has no zone.
    pgc_conn.execute("SET TimeZone = 'Asia/Kolkata'")
    try:
        kolkata = _fmt(_query(pgc_conn, fill, "*"))
    finally:
        pgc_conn.execute("RESET TimeZone")
    expect.text(kolkata, _expected(0),
                "the gap-fill recipe gives the same buckets in a session at a half-hour offset")

    pgc_conn.execute("SET pgcolumnar.enable_group_vectorization = on")
    try:
        plan = "\n".join(r[0] for r in pgc_conn.execute(f"EXPLAIN (COSTS OFF) {fill}").fetchall())
    finally:
        pgc_conn.execute("RESET pgcolumnar.enable_group_vectorization")
    expect.num(plan.count("Columnar Vectorized Group Keys"), 1,
               "the gap-fill recipe's aggregate runs as the vectorized grouped node when it is on")
