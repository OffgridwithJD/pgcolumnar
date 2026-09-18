"""A columnar scan's cost scales with the decoded columns, and with their WIDTH.

Two defects, one cost term. #503: the custom scan inherited the heap seqscan cost,
whose CPU term is per ROW, so decoding nine columns was priced exactly what decoding
one was. #768: the fix that followed charged per decoded VALUE, which left a 324-byte
text column charged what a 4-byte int4 column is. And #171 bounds the correction from
the other side -- raising the full-scan cost must not push a point lookup off its
index.

This file asserts the PLANNER's arithmetic, never a clock. The decode timings that
motivate the bounds live on the bench and in the shell twin's header.

Independent of test/scan_decode_cost.sh: same public seam (EXPLAIN of a columnar
scan), own fixture, own observations. Assertion names match the shell suite so the
two can be compared by name, not by importing each other.

THE FIXTURES ARE SMALLER THAN THE SHELL TWIN'S, AND THE RATIOS WERE MEASURED BEFORE
THEY WERE SHRUNK. The twin writes 2,000,000 rows twice. Measured on this box, PG18
assert build, total cost of the top node:

        rows        narrow(1 col)    wide(9 cols)    ratio      insert
         100,000          1250.9          5266.0     4.210       0.08s
         200,000          2501.8         10530.0     4.209       0.15s
         500,000          6254.2         26322.0     4.209       0.35s
       1,000,000         12508.5         52645.0     4.209       0.70s
       2,000,000         25016.9        105288.0     4.209       1.42s

The ratio the arm bounds at 1.5 is FLAT to three decimals across a 20x range, so the
extra rows buy the assertion nothing. 200,000 is kept rather than the cheapest cell
because at the default 150,000-row group limit it spans more than one row group,
which one of 100,000 would not.

The point-lookup arm is the one size actually decides, and its boundary was measured
rather than guessed:

         50,000   Custom Scan          <- the arm would fail here
        100,000   Index Scan
        200,000   Index Scan           <- chosen, one doubling of margin
      2,000,000   Index Scan

The width arm keeps the twin's 100,000 rows: its ratio is 7.3 there against 8.5 at
25,000, so that is the least favourable of the sizes measured and there is no reason
to trade margin for 1.1 seconds.
"""

N = 200_000
TW = 100_000
INDEX_NODES = ("Index Scan", "Index Only Scan", "Bitmap Index Scan", "Bitmap Heap Scan")


def _nodes(plan):
    stack = [plan[0]["Plan"]]
    while stack:
        node = stack.pop(0)
        yield node
        stack.extend(node.get("Plans") or ())


def _topcost(conn, sql):
    """Total cost of the top plan node, read from typed JSON rather than grepped.

    The shell twin runs `grep -oiE 'cost=[0-9.]+\\.\\.[0-9.]+' | head -1`. That reads
    the first cost on the first line, which IS the top node, but it reads it out of
    text in which a property line can also carry the substring.
    """
    with conn.cursor() as cur:
        cur.execute(f"EXPLAIN (FORMAT JSON, COSTS ON) {sql}")
        return cur.fetchone()[0][0]["Plan"]["Total Cost"]


def test_scan_decode_cost(pgc_conn, expect):
    # ---- #503: nine decoded columns must not cost what one costs --------------
    with pgc_conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE cw (k int, v1 bigint, v2 bigint, v3 bigint, v4 bigint,"
            " v5 bigint, v6 bigint, v7 bigint, v8 bigint) USING pgcolumnar"
        )
        cur.execute(
            f"INSERT INTO cw SELECT (g % 1000000), g,g,g,g,g,g,g,g "
            f"FROM generate_series(1,{N}) g"
        )
        cur.execute("ANALYZE cw")
        cur.execute("SELECT count(*) FROM cw")
        expect.num(cur.fetchone()[0], N, f"premise: cw holds all {N} rows")

    narrow = _topcost(pgc_conn, "SELECT k FROM cw")
    wide = _topcost(pgc_conn, "SELECT k,v1,v2,v3,v4,v5,v6,v7,v8 FROM cw")

    # A COST OR NOTHING TO TALK ABOUT. The twin asks whether its `sed` produced a
    # non-empty string; here the value is typed, so the question is whether it is a
    # real estimate. A floor of 1 refuses a zero or a missing node without pinning
    # any cost constant.
    expect.at_least(narrow, 1, "premise: the narrow scan has a cost")
    expect.at_least(wide, 1, "premise: the wide scan has a cost")

    ratio = wide / narrow
    print(f"-- #503: 9 columns cost {wide}, 1 column costs {narrow} ({ratio:.3f}x)")
    # The bound stays the twin's 1.5. Flat pricing puts these ~1.014 apart (the
    # width difference alone), so 1.5 is unreachable without the decode charge, and
    # the measured 4.2 leaves the bound a wide margin rather than a calibration.
    expect.at_least(
        ratio, 1.5,
        "a wide projection costs materially more than a narrow one (decode is priced)",
    )

    # ---- #768: and the charge must follow WIDTH, not the column count ----------
    with pgc_conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE cwide (a int4,b int4,c int4,d int4,e int4,f int4,"
            "g int4,h int4, t1 text, t2 text, t3 text, t4 text) USING pgcolumnar"
        )
        cur.execute(
            "INSERT INTO cwide SELECT i,i,i,i,i,i,i,i,"
            "repeat(md5(i::text),3), repeat(md5((i+1)::text),3),"
            "repeat(md5((i+2)::text),3), repeat(md5((i+3)::text),3)"
            f" FROM generate_series(1,{TW}) i"
        )
        cur.execute("ANALYZE cwide")
        cur.execute("SELECT count(*) FROM cwide")
        expect.num(cur.fetchone()[0], TW, f"premise: cwide holds all {TW} rows")
        cur.execute(
            "SELECT attname, avg_width FROM pg_stats WHERE tablename = 'cwide'"
            " AND attname IN ('a', 't1')"
        )
        widths = dict(cur.fetchall())
    wt, wa = widths.get("t1"), widths.get("a")
    print(f"-- widths from pg_stats: a={wa} t1={wt}")

    # THE MODEL READS WIDTH FROM THE STATISTICS, so a missing statistic makes this
    # a test about ANALYZE rather than about costing: the two arms would then differ
    # by nothing the planner can observe.
    expect.at_least(wt, 64, "premise: the wide column's width is in the statistics")
    expect.text(
        "yes" if wa and wt and 0 < wa < wt else f"no (a={wa} t1={wt})",
        "yes",
        "premise: and the narrow column's width is too, and is smaller",
    )

    ctext = _topcost(pgc_conn, "SELECT t1,t2,t3,t4 FROM cwide")
    cint = _topcost(pgc_conn, "SELECT a,b,c,d,e,f,g,h FROM cwide")
    expect.at_least(min(ctext, cint), 1, "premise: both projections priced")

    wratio = ctext / cint
    print(f"-- #768: 4 wide text columns cost {ctext}, 8 narrow int columns cost "
          f"{cint} ({wratio:.3f}x)")
    # Deliberately weak, as in the twin: the point is the SIGN. Charging by column
    # count puts the text projection BELOW the int one at 0.79x, so 2.0 cannot be
    # reached without width entering the charge.
    expect.at_least(
        wratio, 2.0,
        "four wide text columns cost more than eight narrow int ones (#768)",
    )

    # ---- #171: and none of it may cost a point lookup its index ---------------
    #
    # THIS ARM IS A GUARD ON A NEIGHBOURING SUBSYSTEM, NOT ON THIS FILE'S SUBJECT,
    # and it is worth saying so because the section reads like a bound on the decode
    # charge above it. It is not. Two mutations, each x1,000,000, each built and run:
    #
    #   the SCAN decode charge      #503 ratio 4.209 -> 16.999, and this arm PASSES
    #                               (Index Scan). A dearer scan makes the index MORE
    #                               attractive, so no over-charge of the term this
    #                               file is about can take a point lookup off its
    #                               index.
    #   the INDEX-FETCH penalty     this arm REDDENS: got 'Custom Scan' want 'index',
    #                               with the #503 ratio unchanged at 4.209.
    #
    # So the arm is falsifiable and it is not decoration -- but the only thing that
    # reddens it lives in pgcolumnar_index_fetch_penalty, which
    # test_index_fetch_penalty_width.py and test_index_fetch_penalty_crossover.py
    # are about. Keep it here, where the bash suite states it, and do not read it as
    # evidence that the decode charge is bounded from the other side. Nothing in
    # either harness bounds that today.
    with pgc_conn.cursor() as cur:
        cur.execute("CREATE TABLE pt (id int, v bigint) USING pgcolumnar")
        cur.execute(f"INSERT INTO pt SELECT g, g FROM generate_series(1,{N}) g")
        cur.execute("CREATE INDEX pt_id ON pt (id)")
        cur.execute("ANALYZE pt")
        cur.execute(
            "EXPLAIN (FORMAT JSON, COSTS OFF) SELECT v FROM pt WHERE id = 12345"
        )
        plan = cur.fetchone()[0]
    types = [n["Node Type"] for n in _nodes(plan)]
    print(f"-- #171 point-lookup plan: {' > '.join(types)}")
    # The twin greps the plan text for `Index`, which any of these node types
    # satisfies; classified rather than matched so a failure names what was chosen.
    expect.text(
        "index" if any(t in INDEX_NODES for t in types) else " > ".join(types),
        "index",
        "#171: a point lookup still uses the index, not a full scan",
    )
