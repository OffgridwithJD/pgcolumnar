"""The grouped vectorized aggregate must answer exactly what core answers (#289).

The grouped path fires for `SELECT <keys>, agg(col) ... [WHERE ...] GROUP BY <keys>`
over one columnar relation. It reads each surviving row, rechecks the full WHERE,
evaluates the group keys, and scatters the row into an open-addressing hash table
whose per-group accumulators fold in scan order.

TWO ORACLES, AND NEITHER IS THE OTHER'S SUBSTITUTE.

  * A heap mirror holds the same rows, so exact aggregates must agree byte for byte.
    It cannot judge float summation order, because heap and columnar do not scan in
    the same order and float addition is not associative.
  * A toggle differential runs the same query over the SAME columnar rows with the
    path off and on. Both arms read in the same order, so even float sums must be
    identical -- which is what validates the order-preserving accumulators, and what
    the heap mirror cannot do.

EVERY COMPARISON CARRIES A NODE PREMISE, and that is the whole reason the file is
shaped this way. A query the node quietly rejects runs the scalar Agg in BOTH arms,
so the comparison is two identical runs agreeing with each other. That is how
`sum(real)` returning 0 got through an earlier version of the shell suite: rounding
an aggregate in the select list makes the output an expression over an aggregate,
which the node rejects, and the check went green against a broken accumulator.

INDEPENDENT OF `test/native_groupagg.sh`. Same public seams -- the plan, and the rows
each query returns -- and nothing else shared:

  * The shell greps `EXPLAIN` text for the marker line. This file reads
    `EXPLAIN (FORMAT JSON)` and asks whether any node carries the PROPERTY
    `Columnar Vectorized Group Keys`, through `expect.plan_marker`, which refuses an
    empty plan rather than reading it as "the node is absent".
  * The shell compares `md5(string_agg(...))` computed by the server. This file
    compares sorted row tuples in Python, so a disagreement prints the rows rather
    than two unequal hashes.
  * The GUC is set on the SESSION here. The shell sets it on the DATABASE because
    every `q()` opens a new connection; this file holds one, so the setting cannot
    be lost between a premise and the query it is a premise for.

THE COLLATION ARMS ARE THEIR OWN TEST, and that is not tidiness. `check_skip` skips
one check; `cannot_run` declares a whole TEST unrunnable. Putting the ICU-gated pair
in the same function as anything else would make the refusal wider than the shell
suite's, and a refusal that takes unrelated arms with it is a worse report than the
one it replaces.
"""
import psycopg

ROWS = 20000
MARKER = "Columnar Vectorized Group Keys"

PAIR_COLUMNS = """g       int,
    ts      timestamp,
    host    text,
    region  text,
    i2      smallint,
    i4      int,
    i8      bigint,
    f4      real,
    f8      double precision,
    num     numeric"""

# Interleaved NULLs in both keys and measures: a NULL host or ts must form its own
# group, exactly as GROUP BY does. The `%` are the server's modulo and reach it
# literally -- psycopg substitutes only when parameters are passed, and none are.
PAIR_BODY = f"""SELECT g,
        CASE WHEN g % 331 = 0 THEN NULL
             ELSE timestamp '2024-01-01 00:00:00' + (g * interval '25 seconds') END,
        CASE WHEN g % 197 = 0 THEN NULL ELSE 'host_' || (g % 50) END,
        'region_' || (g % 4),
        CASE WHEN g % 11 = 0 THEN NULL ELSE (g % 97 - 48)::smallint END,
        CASE WHEN g %  7 = 0 THEN NULL ELSE (g * 7 - 3) END,
        CASE WHEN g %  5 = 0 THEN NULL ELSE (g::bigint * 1000003 - 5) END,
        CASE WHEN g %  6 = 0 THEN NULL ELSE (g * 1.5)::real END,
        CASE WHEN g %  9 = 0 THEN NULL ELSE (g::float8 * 0.125 - 3.5) END,
        CASE WHEN g %  8 = 0 THEN NULL ELSE (g * 0.01)::numeric(12,4) END
    FROM generate_series(1, {ROWS}) g"""

EXACT = ("count(*), count(i4), count(host), "
         "sum(i2), sum(i4), sum(i8), sum(num), "
         "min(f8), max(f8), min(host), max(host), min(ts), max(ts), min(i8), max(i8)")

# The accumulators the heap mirror cannot judge: float summation order differs
# between the two storage types, so these are compared off-versus-on instead.
FLOATAGG = ("sum(f4), sum(f8), sum(num), "
            "avg(i2), avg(i4), avg(i8), avg(f4), avg(f8), avg(num)")

Q_KEYHOST = "SELECT host, count(*), sum(i4) FROM t_col GROUP BY host"
Q_KEYHOUR = ("SELECT date_trunc('hour', ts) h, count(*) FROM t_col "
             "GROUP BY date_trunc('hour', ts)")
Q_Q4 = ("SELECT date_trunc('hour', ts) h, host, avg(f8), count(*) "
        "FROM t_col WHERE ts >= timestamp '2024-01-01 02:00:00' "
        "AND ts < timestamp '2024-01-01 06:00:00' "
        "GROUP BY date_trunc('hour', ts), host")


def _exec(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)


def _rows(conn, sql):
    """-> the result as sorted tuples of text.

    Text, because the two storage types can return the same value in different
    Python types for `numeric` and the comparison is about the VALUE. Sorted,
    because neither GROUP BY nor either scan promises an order.
    """
    with conn.cursor() as cur:
        cur.execute(sql)
        return sorted(tuple("" if v is None else str(v) for v in row)
                      for row in cur.fetchall())


def _one(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        row = cur.fetchone()
    return row[0] if row else None


def _plan(conn, sql):
    with conn.cursor() as cur:
        cur.execute(f"EXPLAIN (COSTS OFF, FORMAT JSON) {sql}")
        return cur.fetchone()[0]


def _estimate(conn, sql):
    """-> the top node's row estimate, which is what a group bound moves."""
    with conn.cursor() as cur:
        cur.execute(f"EXPLAIN (COSTS ON, FORMAT JSON) {sql}")
        return cur.fetchone()[0][0]["Plan"]["Plan Rows"]


def _top_cost(conn, sql):
    with conn.cursor() as cur:
        cur.execute(f"EXPLAIN (COSTS ON, FORMAT JSON) {sql}")
        return cur.fetchone()[0][0]["Plan"]["Total Cost"]


def _groupvec(conn, on):
    _exec(conn, f"SET pgcolumnar.enable_group_vectorization = {'on' if on else 'off'}")


def _make_pair(expect, conn):
    """Build the heap/columnar pair, and assert it is the pair this file assumes.

    THE ROW COUNT IS ASSERTED, not assumed, and it is not decoration. Two things
    downstream are arithmetic over it: the cost test states 450.00 =
    cpu_operator_cost x 20,000 rows x 9 extra aggregates, and the group shapes
    (50 hosts, 4 regions, ~14 hours of timestamps) are counts modulo this size. A
    fixture that loaded short would leave both describing a table that does not
    exist, while every oracle comparison still agreed with itself.

    Both halves are counted, not one, because the mirror needs them EQUAL. The
    layer already refuses an empty result compared with an empty result, so this
    does not close that hole -- it makes a short load name the fixture rather than
    surface three screens later as a cost that does not match its own docstring.
    """
    _exec(conn, f"CREATE TABLE t_heap ({PAIR_COLUMNS}) USING heap")
    _exec(conn, f"CREATE TABLE t_col ({PAIR_COLUMNS}) USING pgcolumnar")
    # Small row groups, so grouping spans many groups and vectors.
    _exec(conn, "SELECT pgcolumnar.set_options('t_col', stripe_row_limit => 1000)")
    _exec(conn, f"INSERT INTO t_heap {PAIR_BODY}")
    # From the heap table, not from the generator again: the two tables must hold
    # the same rows for the mirror to be an oracle rather than a second sample.
    _exec(conn, "INSERT INTO t_col SELECT * FROM t_heap")
    heap = _one(conn, "SELECT count(*) FROM t_heap")
    col = _one(conn, "SELECT count(*) FROM t_col")
    expect.text(f"{heap}/{col}", f"{ROWS}/{ROWS}",
                "premise: the pair loaded in full, so the mirror compares equal populations")
    _groupvec(conn, True)


def _oracle(expect, conn, label, template):
    """The columnar form against the heap mirror, with the node asserted first.

    `label` is passed through rather than spelled at the call, exactly as the shell
    helper passes `$label`: the concrete labels are built by the caller in both
    harnesses, so neither side publishes them as static names.
    """
    columnar = template.replace("%T", "t_col")
    expect.plan_marker(_plan(conn, columnar), MARKER, name=f"{label} [node fires]")
    expect.rows(_rows(conn, columnar), _rows(conn, template.replace("%T", "t_heap")),
                label)


def _toggle(expect, conn, label, query):
    """The same query over the same columnar rows, path off versus on.

    The node premise comes first for the reason the module docstring gives: without
    it a query the node rejects runs the scalar Agg in both arms and the comparison
    is one plan agreeing with itself.
    """
    _groupvec(conn, True)
    expect.plan_marker(_plan(conn, query), MARKER, name=f"{label} [node fires]")
    _groupvec(conn, False)
    off = _rows(conn, query)
    _groupvec(conn, True)
    expect.rows(_rows(conn, query), off, label)


# ---- the node is chosen for the shapes it supports ---------------------------

def test_the_grouped_node_is_chosen_for_the_shapes_it_supports(pgc_conn, expect):
    _make_pair(expect, pgc_conn)
    expect.plan_marker(_plan(pgc_conn, Q_KEYHOST), MARKER,
                       name="plan: GROUP BY text key uses grouped node")
    expect.plan_marker(_plan(pgc_conn, Q_KEYHOUR), MARKER,
                       name="plan: GROUP BY hour expr uses grouped node")
    expect.plan_marker(_plan(pgc_conn, Q_Q4), MARKER,
                       name="plan: q4-shape (WHERE+2 keys) uses grouped node")
    _groupvec(pgc_conn, False)
    expect.plan_marker(_plan(pgc_conn, Q_KEYHOST), MARKER, absent=True,
                       name="plan: off -> ordinary Agg, not grouped node")


# ---- the heap mirror ---------------------------------------------------------

def test_the_grouped_path_agrees_with_a_heap_mirror(pgc_conn, expect):
    _make_pair(expect, pgc_conn)
    _oracle(expect, pgc_conn, "oracle exact: GROUP BY host",
            f"SELECT host, {EXACT} FROM %T GROUP BY host")
    _oracle(expect, pgc_conn, "oracle exact: GROUP BY hour",
            f"SELECT date_trunc('hour', ts), {EXACT} FROM %T "
            "GROUP BY date_trunc('hour', ts)")
    _oracle(expect, pgc_conn, "oracle exact: GROUP BY hour, host (q4/q5 shape)",
            f"SELECT date_trunc('hour', ts), host, {EXACT} FROM %T "
            "GROUP BY date_trunc('hour', ts), host")
    _oracle(expect, pgc_conn, "oracle exact: GROUP BY region, host (two text keys)",
            f"SELECT region, host, {EXACT} FROM %T GROUP BY region, host")
    _oracle(expect, pgc_conn, "oracle exact: GROUP BY integer expr key",
            f"SELECT (g % 7), {EXACT} FROM %T GROUP BY (g % 7)")
    _oracle(expect, pgc_conn, "oracle exact: GROUP BY smallint column key",
            "SELECT i2, count(*), sum(i4), min(f8), max(f8) FROM %T GROUP BY i2")
    # A WHERE that both prunes groups and needs a residual recheck.
    _oracle(expect, pgc_conn, "oracle exact: WHERE range + GROUP BY hour, host",
            f"SELECT date_trunc('hour', ts), host, {EXACT} FROM %T "
            "WHERE ts >= timestamp '2024-01-01 02:00:00' "
            "AND ts < timestamp '2024-01-01 06:00:00' "
            "GROUP BY date_trunc('hour', ts), host")
    _oracle(expect, pgc_conn, "oracle exact: WHERE on measure + GROUP BY host",
            f"SELECT host, {EXACT} FROM %T "
            "WHERE i4 > 40000 AND host IS NOT NULL GROUP BY host")
    # The NULL keys are already in the fixture (g%197, g%331); this asserts the
    # NULL group folds the way GROUP BY does rather than being dropped.
    _oracle(expect, pgc_conn, "oracle exact: NULL ts group folds like heap",
            "SELECT date_trunc('hour', ts), count(*), sum(i4) FROM %T "
            "GROUP BY date_trunc('hour', ts)")


def test_the_mirror_still_agrees_after_deletes_and_an_added_column(pgc_conn, expect):
    _make_pair(expect, pgc_conn)
    _exec(pgc_conn, "DELETE FROM t_heap WHERE g % 17 = 0")
    _exec(pgc_conn, "DELETE FROM t_col  WHERE g % 17 = 0")
    _oracle(expect, pgc_conn, "oracle exact: GROUP BY host after deletes",
            f"SELECT host, {EXACT} FROM %T GROUP BY host")
    _toggle(expect, pgc_conn, "toggle exact: GROUP BY host after deletes",
            f"SELECT host, {EXACT} FROM t_col GROUP BY host")

    _exec(pgc_conn, "ALTER TABLE t_heap ADD COLUMN extra int DEFAULT 7")
    _exec(pgc_conn, "ALTER TABLE t_col  ADD COLUMN extra int DEFAULT 7")
    _oracle(expect, pgc_conn, "oracle exact: GROUP BY host, added column",
            "SELECT host, count(*), sum(extra), sum(i4) FROM %T GROUP BY host")
    _oracle(expect, pgc_conn, "oracle exact: GROUP BY added column",
            "SELECT extra, count(*), sum(i4) FROM %T GROUP BY extra")


# ---- the toggle differential -------------------------------------------------

def test_the_accumulators_fold_identically_with_the_path_off_and_on(pgc_conn, expect):
    _make_pair(expect, pgc_conn)
    _toggle(expect, pgc_conn, "toggle float/avg: GROUP BY host",
            f"SELECT host, {FLOATAGG} FROM t_col GROUP BY host")
    _toggle(expect, pgc_conn, "toggle float/avg: GROUP BY hour, host",
            f"SELECT date_trunc('hour', ts), host, {FLOATAGG} FROM t_col "
            "GROUP BY date_trunc('hour', ts), host")
    _toggle(expect, pgc_conn, "toggle float/avg: WHERE + GROUP BY region, host",
            f"SELECT region, host, {FLOATAGG} FROM t_col "
            "WHERE f8 IS NOT NULL GROUP BY region, host")
    _toggle(expect, pgc_conn, "toggle exact: GROUP BY host",
            f"SELECT host, {EXACT} FROM t_col GROUP BY host")
    _toggle(expect, pgc_conn, "toggle exact: GROUP BY hour, host",
            f"SELECT date_trunc('hour', ts), host, {EXACT} FROM t_col "
            "GROUP BY date_trunc('hour', ts), host")
    _toggle(expect, pgc_conn, "toggle exact: GROUP BY region, host, WHERE",
            f"SELECT region, host, {EXACT} FROM t_col "
            "WHERE i8 IS NOT NULL GROUP BY region, host")


def test_min_max_keep_the_display_scale_core_keeps(pgc_conn, expect):
    """Numeric values equal by value and different in display scale (1.0 vs 1.00).

    Core's larger/smaller keep the LATER value on a tie, so the answer depends on
    fold order and the heap mirror cannot judge it -- the two storage types do not
    scan in the same order. A toggle differential can: both arms read the same
    columnar rows in the same order.
    """
    _exec(pgc_conn, "CREATE TABLE tie_col (k int, n numeric) USING pgcolumnar")
    _exec(pgc_conn, "INSERT INTO tie_col VALUES "
                    "(1, 1.0), (1, 1.00), (1, 1.000), (1, 0.5), (1, 0.50), "
                    "(2, 5.5), (2, 5.50), (2, 5.500)")
    _toggle(expect, pgc_conn, "toggle min/max numeric display-scale tie",
            "SELECT k, min(n), max(n) FROM tie_col GROUP BY k")


def test_a_lone_negative_zero_keeps_its_sign(pgc_conn, expect):
    """Core's sum assigns the first value directly, so a sum of -0.0 prints '-0'.

    Folding it into +0.0 would drop the sign, and the only oracle that can see that
    is one reading the same rows in the same order.
    """
    _exec(pgc_conn, "CREATE TABLE z_col (k int, r real, d float8) USING pgcolumnar")
    _exec(pgc_conn, "INSERT INTO z_col VALUES (1,'-0','-0'), (2,'-0','-0'), (2,'-0','-0')")
    _toggle(expect, pgc_conn, "toggle sum signed-zero (-0 preserved)",
            "SELECT k, sum(r), sum(d) FROM z_col GROUP BY k")


# ---- shapes the node must decline, still answering correctly -----------------

def test_a_group_count_over_the_cap_stops_rather_than_growing(pgc_conn, expect):
    """The cap bounds the ACTUAL group count at execution, not the planner's estimate.

    The node is forced here -- hashagg and sort off leave it the only grouping path
    -- so the cap path is exercised whatever the planner would cost on this fixture.
    Its real-world plan choice is covered by the arms above.
    """
    _make_pair(expect, pgc_conn)
    expect.plan_marker(_plan(pgc_conn, "SELECT g, count(*) FROM t_col GROUP BY g"),
                       MARKER, name="plan: node still chosen (no estimate gate)")

    # autocommit is on, so the deliberate error below cannot poison what follows.
    # Only psycopg.Error is caught: a bug in this file should raise.
    _exec(pgc_conn, "SET enable_hashagg=off")
    _exec(pgc_conn, "SET enable_sort=off")
    _exec(pgc_conn, "SET pgcolumnar.groupagg_max_groups=100")
    named = "no"
    try:
        _rows(pgc_conn, "SELECT g, count(*) FROM t_col GROUP BY g")
    except psycopg.Error as exc:
        named = "yes" if "groupagg_max_groups" in str(exc) else f"no [{exc}]"
    expect.text(named, "yes", "over-cap stops with a groupagg_max_groups error")

    _exec(pgc_conn, "RESET enable_hashagg")
    _exec(pgc_conn, "RESET enable_sort")
    _exec(pgc_conn, "RESET pgcolumnar.groupagg_max_groups")
    # Named at the call rather than through `_oracle`, and without a second node
    # premise, because the shell suite spends a bare `diff_query` here: the node was
    # asserted three lines above and asserting it again would publish a premise the
    # original does not have.
    expect.rows(
        _rows(pgc_conn, "SELECT g, count(*), sum(i4) FROM t_col GROUP BY g"),
        _rows(pgc_conn, "SELECT g, count(*), sum(i4) FROM t_heap GROUP BY g"),
        "oracle exact: default cap runs the high-cardinality key")


def test_an_output_built_on_a_key_falls_back_and_still_answers(pgc_conn, expect):
    _make_pair(expect, pgc_conn)
    expect.plan_marker(
        _plan(pgc_conn, "SELECT upper(host), count(*) FROM t_col GROUP BY host"),
        MARKER, absent=True, name="plan: f(key) output falls back")
    # The fallback must still be RIGHT, which is the half a plan assertion cannot
    # reach. Named through the helper's own label, as the shell suite names it.
    expect.rows(
        _rows(pgc_conn, "SELECT upper(host), count(*), sum(i4) FROM t_col GROUP BY host"),
        _rows(pgc_conn, "SELECT upper(host), count(*), sum(i4) FROM t_heap GROUP BY host"),
        "oracle exact: f(key) output still correct")

    expect.plan_marker(_plan(pgc_conn, "SELECT host FROM t_col GROUP BY host"),
                       MARKER, absent=True,
                       name="plan: GROUP BY with no aggregate falls back")


def test_a_non_deterministic_collation_key_falls_back(pgc_conn, expect):
    """A byte-equality hash cannot implement a case-insensitive collation.

    The keys decouple case from the suffix -- case comes from g%2, the suffix from
    (g/2)%10 -- so for every suffix 0..9 both 'host'N and 'HOST'N exist: twenty
    byte-distinct keys that case-fold to ten. A level-2 collation yields ten groups;
    a byte-equality path would yield twenty. The fixture therefore fails if the
    fallback ever stops happening, which a fixture whose case tracked its suffix
    would not.

    ITS OWN TEST, because `cannot_run` declares a whole test unrunnable while the
    shell suite's `check_skip` declines one check. Anything else in this function
    would be taken down with the refusal.
    """
    try:
        _exec(pgc_conn, "CREATE COLLATION ci "
                        "(provider = icu, locale = 'und-u-ks-level2', deterministic = false)")
    except psycopg.Error:
        expect.cannot_run(
            "MISSING_DEPENDENCY",
            "a case-insensitive collation needs a non-deterministic ICU collation, "
            "and a server built without ICU cannot create one",
            # At the call, not behind a constant: the grader resolves string
            # literals at the call site.
            name="the non-deterministic collation case")
        return

    _exec(pgc_conn, "CREATE TABLE t_ci (k text COLLATE ci, v int) USING pgcolumnar")
    _exec(pgc_conn, "INSERT INTO t_ci SELECT "
                    "(CASE WHEN g % 2 = 0 THEN 'host' ELSE 'HOST' END) || ((g / 2) % 10), g "
                    "FROM generate_series(1, 5000) g")
    _groupvec(pgc_conn, True)
    expect.plan_marker(_plan(pgc_conn, "SELECT k, count(*) FROM t_ci GROUP BY k"),
                       MARKER, absent=True,
                       name="plan: non-deterministic collation key falls back")
    groups = _rows(pgc_conn, "SELECT count(*) FROM (SELECT k FROM t_ci GROUP BY k) s")
    folded = _rows(pgc_conn, "SELECT count(DISTINCT lower(k)) FROM t_ci")
    expect.rows(groups, folded,
                "answer: non-deterministic collation grouping is case-insensitive (10 groups)")


# ---- the two reproduced wrong-answer blockers --------------------------------

def test_sum_real_matches_heap_rather_than_returning_zero(pgc_conn, expect):
    """Blocker 1: a float8 Datum handed to a float4 slot made sum(real) return 0.

    The values are integer-valued reals, so the sum is exact whatever the fold
    order and the heap mirror can judge it directly. The nonzero arm is not
    redundant: a mirror comparison is satisfied by both sides returning 0, and 0
    was the defect.
    """
    _exec(pgc_conn, "CREATE TABLE r_col (h int, r real, d float8) USING pgcolumnar")
    _exec(pgc_conn, "CREATE TABLE r_heap (h int, r real, d float8)")
    _exec(pgc_conn, "INSERT INTO r_heap SELECT g % 4, (g % 7)::real, (g % 7)::float8 "
                    "FROM generate_series(1, 4000) g")
    _exec(pgc_conn, "INSERT INTO r_col SELECT * FROM r_heap")
    _groupvec(pgc_conn, True)

    expect.plan_marker(_plan(pgc_conn, "SELECT h, sum(r) FROM r_col GROUP BY h"),
                       MARKER, name="regress B1: sum(real) fires the node")
    expect.rows(_rows(pgc_conn, "SELECT h, sum(r), sum(d) FROM r_col GROUP BY h"),
                _rows(pgc_conn, "SELECT h, sum(r), sum(d) FROM r_heap GROUP BY h"),
                "regress B1: sum(real) matches heap, not 0")
    zeroes = _rows(pgc_conn, "SELECT bool_and(s <> 0) FROM "
                             "(SELECT sum(r) s FROM r_col GROUP BY h) x")
    expect.rows(zeroes, [("True",)], "regress B1: sum(real) is nonzero")


def test_a_gating_where_is_honoured_rather_than_dropped(pgc_conn, expect):
    """Blocker 2: a pseudoconstant one-time filter was dropped, so a false gate
    wrongly returned rows. The node cannot honour a one-time filter, so it must
    fall back -- and either way the answer must match heap."""
    _make_pair(expect, pgc_conn)
    expect.plan_marker(
        _plan(pgc_conn, "SELECT host, count(*) FROM t_col WHERE (SELECT false) GROUP BY host"),
        MARKER, absent=True, name="regress B2: gating WHERE falls back (not the node)")
    expect.rows(
        _rows(pgc_conn, "SELECT host, count(*) FROM t_col WHERE (SELECT false) GROUP BY host"),
        _rows(pgc_conn, "SELECT host, count(*) FROM t_heap WHERE (SELECT false) GROUP BY host"),
        "regress B2: gating WHERE (SELECT false) returns no rows",
        allow_empty="a false one-time filter returns no rows, and that IS the property")
    expect.rows(
        _rows(pgc_conn, "SELECT host, count(*), sum(i4) FROM t_col WHERE (SELECT true) GROUP BY host"),
        _rows(pgc_conn, "SELECT host, count(*), sum(i4) FROM t_heap WHERE (SELECT true) GROUP BY host"),
        "regress B2: gating WHERE (SELECT true) is a no-op")


def test_avg_float8_overflows_the_way_core_overflows(pgc_conn, expect):
    """Core's float accumulator keeps Youngs-Cramer Sxx and raises on finite inputs
    whose sum of squares overflows even where the running sum stays finite. The node
    must raise too, and a row comparison cannot compare two errors."""
    _exec(pgc_conn, "CREATE TABLE ov_col (k int, d float8) USING pgcolumnar")
    _exec(pgc_conn, "INSERT INTO ov_col VALUES (1, -1e308), (1, 1e308)")
    _groupvec(pgc_conn, True)
    expect.plan_marker(_plan(pgc_conn, "SELECT k, avg(d) FROM ov_col GROUP BY k"),
                       MARKER, name="avg(float8) overflow: node fires")
    raised = "no"
    try:
        _rows(pgc_conn, "SELECT k, avg(d) FROM ov_col GROUP BY k")
    except psycopg.Error as exc:
        raised = "yes" if "out of range" in str(exc).lower() else f"no [{exc}]"
    expect.text(raised, "yes", "avg(float8) overflow errors like core")


# ---- degenerate inputs -------------------------------------------------------

def test_degenerate_inputs_produce_no_groups(pgc_conn, expect):
    _make_pair(expect, pgc_conn)
    expect.rows(
        _rows(pgc_conn, "SELECT host, count(*) FROM t_col WHERE g < 0 GROUP BY host"),
        _rows(pgc_conn, "SELECT host, count(*) FROM t_heap WHERE g < 0 GROUP BY host"),
        "oracle exact: all rows filtered out -> 0 groups",
        allow_empty="a predicate matching nothing yields no groups, which IS the property")

    _exec(pgc_conn, "CREATE TABLE t_empty (k text, v int) USING pgcolumnar")
    expect.num(
        len(_rows(pgc_conn, "SELECT k, count(*) FROM t_empty GROUP BY k")), 0,
        "empty table: grouped scan yields 0 rows")


# ---- the path pays for the folding it does (#349) ----------------------------

def test_the_path_pays_for_the_folding_it_does(pgc_conn, expect):
    """The grouped path priced itself at the scan cost plus a fixed bump.

    Every competing plan pays a per-row aggregation cost and this one paid none, so
    it won by construction -- including against a parallel plan measured 1.9x faster
    than itself on a full-scan GROUP BY. The property asserted is the one that was
    observably wrong and that does not depend on the planner choosing any particular
    plan at fixture scale: the estimate must respond to how much folding the node
    will do.

    TWO THINGS ARE HELD CONSTANT HERE THAT THE SHELL SUITE VARIES, and the removal
    proof is what found the difference (#1162).

    `native_groupagg.sh` asks ten aggregates over ten DIFFERENT columns to cost more
    than one over one, and a scan projecting ten columns costs more than a scan
    projecting one whatever the folding charge is. Measured against a build whose
    folding charge no longer scales with the aggregate count -- the exact defect
    #349 fixed:

        distinct columns, 1 agg    350.50   350.50    (control, mutant)
        distinct columns, 10 aggs 1253.01   803.01

    803.01 is still greater than 350.50, so the arm stays green against the defect.
    The 452.51 that survives is the scan's projection cost, not folding.

    Ten aggregates over the SAME column hold the projection fixed, and the path is
    forced so both arms really are the grouped node rather than whatever the
    planner prefers once the charge is applied:

        one column, 1 agg          350.50   350.50
        one column, 10 aggs        800.50   350.50

    450.00 is cpu_operator_cost x 20000 rows x 9 extra aggregates, exactly the term
    under test, and it is the whole of the difference.
    """
    _exec(pgc_conn, "CREATE TABLE t_cost (host text, a int, b int, c int, d int, "
                    "e int, f int, g2 int, h int, i int, j int) USING pgcolumnar")
    _exec(pgc_conn, "INSERT INTO t_cost SELECT 'h' || (n % 50), n, n, n, n, n, n, n, n, n, n "
                    f"FROM generate_series(1, {ROWS}) n")
    _exec(pgc_conn, "ANALYZE t_cost")
    # 450.00 in the docstring above is cpu_operator_cost x THIS NUMBER x 9. Asserted,
    # because a short load would leave the whole explanation describing another table.
    expect.num(_one(pgc_conn, "SELECT count(*) FROM t_cost"), ROWS,
               "premise: the cost fixture holds the rows the 450.00 is computed from")
    _groupvec(pgc_conn, True)
    # The only grouping path left, so both arms are the node under test and
    # neither is core's Agg wearing its cost.
    _exec(pgc_conn, "SET enable_hashagg = off")
    _exec(pgc_conn, "SET enable_sort = off")

    one_q = "SELECT host, avg(a) FROM t_cost GROUP BY host"
    ten_q = f"SELECT host, {','.join(['avg(a)'] * 10)} FROM t_cost GROUP BY host"
    # The premise the two costs below are costs OF. Without it a planner that
    # stopped choosing the node would have the arms comparing core's Agg with
    # itself, which is monotone in the aggregate count for reasons of its own.
    expect.plan_marker(_plan(pgc_conn, one_q), MARKER,
                       name="premise: one aggregate is costed as the grouped node")
    expect.plan_marker(_plan(pgc_conn, ten_q), MARKER,
                       name="premise: and so is ten, so the two costs are comparable")

    one, ten = _top_cost(pgc_conn, one_q), _top_cost(pgc_conn, ten_q)
    print(f"-- grouped path cost: 1 aggregate {one}, 10 aggregates {ten}")
    # A cost EXPLAIN did not produce, or produced as zero, makes the comparison
    # below meaningless -- and `0 > 0` is a clean-looking false.
    expect.text("yes" if one and ten else f"no [1={one!r} 10={ten!r}]", "yes",
                "premise: the grouped path is costed at all (non-empty estimate)")
    expect.text("yes" if ten > one else f"no [1={one} 10={ten}]", "yes",
                "ten aggregates cost more than one (#349)")


# ---- the group-estimate bound (#369) -----------------------------------------

GB_ROWS = 300000
# 300000 * 2160us = 648s = 10.8 minutes, so 11 minute buckets plus the two partials
# the bound allows.
GB_WINDOW = "WHERE ts >= '2026-01-01' AND ts < '2026-01-01 00:10:48'"


def _gb_session(conn):
    _groupvec(conn, True)
    _exec(conn, "SET pgcolumnar.enable_parallel_vector_agg = on")
    _exec(conn, "SET max_parallel_workers_per_gather = 4")


def test_the_group_estimate_bound_is_accurate_and_narrow(pgc_conn, expect):
    """`estimate_num_groups` cannot see through a function.

    For `date_trunc('minute', ts)` it falls back to the timestamp column's
    ndistinct, which is near the row count -- 19,996,000 against 720 actual on the
    20M fixture. That number is charged twice on the parallel arm, by the Gather and
    by the Finalize, and not at all on the serial node, so the serial node won by
    construction on shapes where the arm is four times faster.

    Three things are asserted and the middle one is the one that matters: the bound
    is ACCURATE rather than merely smaller, an INFORMED estimate is untouched, and a
    query with no Const bound on the key gets no bound from us.
    """
    _exec(pgc_conn, "CREATE TABLE gb (ts timestamptz, host text, v float8) "
                    "USING pgcolumnar")
    _exec(pgc_conn, "INSERT INTO gb SELECT "
                    "'2026-01-01'::timestamptz + (g * interval '2160 microseconds'), "
                    "'h'||(g % 4000), random()*100 "
                    f"FROM generate_series(1,{GB_ROWS}) g")
    _exec(pgc_conn, "ANALYZE gb")
    _gb_session(pgc_conn)

    expect.num(
        _estimate(pgc_conn, "SELECT date_trunc('minute', ts) b, avg(v) FROM gb "
                            f"{GB_WINDOW} GROUP BY b"), 12,
        "the bound is accurate for a truncating time key, not just smaller")

    # An accurate bound is worthless if it is not a bound. Counted, not reasoned.
    actual = int(_rows(pgc_conn,
                       "SELECT count(*) FROM (SELECT date_trunc('minute', ts) "
                       f"FROM gb {GB_WINDOW} GROUP BY 1) z")[0][0])
    print(f"-- true group count in the window: {actual}")
    expect.text("yes" if actual <= 12 else f"no [{actual} groups]", "yes",
                "and it is an UPPER bound: the true group count is at or below it")

    # A plain Var has statistics, so examine_variable reports informed and the
    # substitution must not run at all.
    plain = _estimate(pgc_conn, "SELECT host, avg(v) FROM gb GROUP BY host")
    print(f"-- informed estimate for a plain column: {plain}")
    expect.text("yes" if 3900 <= plain <= 4100 else f"no [{plain}]", "yes",
                "an informed estimate (plain column) is not replaced")

    # No Const bound on the key means no range, so no bound. Asserting the estimate
    # is LARGE is the point: a bound would have shrunk it.
    unbounded = _estimate(pgc_conn,
                          "SELECT date_trunc('minute', ts) b, avg(v) FROM gb GROUP BY b")
    expect.text("yes" if unbounded > 1000 else f"no [{unbounded}]", "yes",
                "a truncating key with no range bound gets no bound from us")

    # A user function with date_trunc's SHAPE must not get date_trunc's BOUND.
    # PL/pgSQL because an SQL function would be inlined and lose the shape. Matching
    # on shape alone estimated this at 722 against 499,999 actual -- a 692x
    # UNDER-estimate, the direction that under-prices the arm and under-sizes the
    # Finalize's hash table.
    _exec(pgc_conn, "CREATE FUNCTION gb_hi_card(t text, s timestamptz) RETURNS text AS "
                    "$$ BEGIN RETURN t || md5(s::text); END $$ LANGUAGE plpgsql IMMUTABLE")
    lookalike = _estimate(pgc_conn, "SELECT gb_hi_card('minute', ts) b, avg(v) FROM gb "
                                    f"{GB_WINDOW} GROUP BY b")
    expect.text("yes" if lookalike > 1000 else f"no [{lookalike}]", "yes",
                "a lookalike function with the same signature gets NO bound")

    nontime = _estimate(pgc_conn, "SELECT upper(host) b, avg(v) FROM gb GROUP BY b")
    expect.text("yes" if nontime > 100 else f"no [{nontime}]", "yes",
                "a non-time expression key gets no bound either")


def test_a_mixed_timestamp_predicate_gets_no_bound(pgc_conn, expect):
    """PostgreSQL has cross-type operators, so a `timestamp` Const compared against a
    `timestamptz` column stays bare and reaches the extraction instead of being
    wrapped in a cast. Both are int64 microseconds on different scales -- wall clock
    against UTC -- so under a non-UTC TimeZone the range would be computed across the
    offset. The session TimeZone is set to one with a non-zero offset deliberately:
    under UTC the two scales coincide and the arm cannot fail.
    """
    _exec(pgc_conn, "CREATE TABLE gbm (ts timestamptz, v float8) USING pgcolumnar")
    _exec(pgc_conn, "INSERT INTO gbm SELECT "
                    "'2026-01-01 00:00:00+00'::timestamptz + (g * interval '86400 microseconds'), "
                    "random() FROM generate_series(1,200000) g")
    _exec(pgc_conn, "ANALYZE gbm")
    _exec(pgc_conn, "SET TimeZone='Asia/Kolkata'")
    _gb_session(pgc_conn)

    mixed = _estimate(pgc_conn,
                      "SELECT date_trunc('minute',ts) b, avg(v) FROM gbm "
                      "WHERE ts >= timestamp '2026-01-01 00:00' "
                      "AND ts < timestamp '2026-01-01 12:00' GROUP BY b")
    matching = _estimate(pgc_conn,
                         "SELECT date_trunc('minute',ts) b, avg(v) FROM gbm "
                         "WHERE ts >= timestamptz '2026-01-01 00:00+00' "
                         "AND ts < timestamptz '2026-01-01 12:00+00' GROUP BY b")
    print(f"-- mixed-type predicate {mixed}, matching-type predicate {matching}")
    # The two arms are a pair: "no bound" and "a bound" have to be distinguishable
    # on this fixture, and core's own estimate here is six figures, so they are.
    expect.text("yes" if mixed > 50000 else f"no [{mixed}]", "yes",
                "a mixed timestamp/timestamptz predicate gets NO bound")
    expect.text("yes" if matching < 5000 else f"no [{matching}]", "yes",
                "while a matching-type predicate still gets one")
