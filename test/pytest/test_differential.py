"""The differential oracle: a columnar table and a heap table must answer alike.

The governing property of `test/differential.sh`, and the reason that suite is the
largest in the tree: load the same data into both access methods and every query must
return the same thing. Heap is the oracle, so this catches encode/decode, null handling
and chunk-skipping bugs generically rather than one at a time.

**This is part 1 of that port: the type matrix.** Twenty columns covering every type the
suite exercises, at a null density that differs per column so no two columns share a null
pattern, loaded across many chunk groups and several stripes. The boundary, encoding,
bloom and aggregate parts are separate slices.

**Names are the bash suite's, character for character**, because that is what lets
`compare_to_bash.py` diff the two harnesses by property rather than by count. A port that
renames a check asserts the same thing and reports a different one.

**Why row lists and not hashes.** `lib.sh` compares `md5(string_agg(...))` because bash has
no structured result; `EMPTY` and a unique `QUERY_ERROR.N` keep an empty set apart from a
failed query there. Here `expect.row_set` compares the rows themselves, so a failure prints
the rows that differ instead of two hexadecimal strings, and the harness already refuses the
both-sides-empty comparison that a hash cannot see.

**The fixture is module-scoped and that is load-bearing.** Twelve thousand rows across twenty
columns is too slow to rebuild for each of ninety-odd assertions, so it is built once in its
own schema. That costs the `pgc_conn` write watch, so the load asserts its own row count --
the three premise arms below are not decoration, they are what `watch_writes` would otherwise
have done.
"""

import pytest

# Exactly the suite's MATRIX_DEFS, in order. The types are the point, so they are written
# out rather than generated: a generator would be a second place for the list to be wrong.
MATRIX_DEFS = """
    id        int,
    c_int     int,
    c_big     bigint,
    c_small   smallint,
    c_num     numeric(24,6),
    c_f4      real,
    c_f8      double precision,
    c_bool    boolean,
    c_date    date,
    c_ts      timestamp,
    c_tstz    timestamptz,
    c_uuid    uuid,
    c_bytea   bytea,
    c_vc      varchar(50),
    c_char    char(10),
    c_iv      interval,
    c_jsonb   jsonb,
    c_arr     int[],
    c_text    text,
    c_ztext   text
"""

# A DIFFERENT NULL MODULUS PER COLUMN, which is the fixture expressing the question: two
# columns sharing a pattern cannot distinguish a bug that keys on the pattern from one that
# keys on the column. %5, %17, %11, %3, %13, %7 and "every even row is the empty string"
# are the suite's own choices.
MATRIX_LOAD = """SELECT
    g AS id,
    CASE WHEN g%5=0  THEN NULL ELSE (g*7-100) END,
    CASE WHEN g%17=0 THEN NULL ELSE (g::bigint*1000000000) END,
    CASE WHEN g%17=0 THEN NULL ELSE ((g%100)-50)::smallint END,
    CASE WHEN g%11=0 THEN NULL ELSE (g::numeric*1.250000-1000) END,
    CASE WHEN g%17=0 THEN NULL ELSE (g*0.5-10)::real END,
    CASE WHEN g%3=0  THEN NULL ELSE (sqrt(g::float8)*(CASE WHEN g%2=0 THEN -1 ELSE 1 END)) END,
    CASE WHEN g%17=0 THEN NULL ELSE (g%3=0) END,
    CASE WHEN g%17=0 THEN NULL ELSE (DATE '2000-01-01' + g) END,
    CASE WHEN g%17=0 THEN NULL ELSE (TIMESTAMP '2000-01-01' + make_interval(hours => g)) END,
    CASE WHEN g%17=0 THEN NULL ELSE (TIMESTAMPTZ '2000-01-01 00:00:00+00' + make_interval(hours => g)) END,
    CASE WHEN g%13=0 THEN NULL ELSE (md5(g::text)::uuid) END,
    CASE WHEN g%13=0 THEN NULL ELSE decode(md5(g::text),'hex') END,
    CASE WHEN g%7=0  THEN NULL ELSE ('v'||g) END,
    CASE WHEN g%17=0 THEN NULL ELSE lpad(g::text,10,'0') END,
    CASE WHEN g%17=0 THEN NULL ELSE make_interval(days => g%1000, hours => g%24) END,
    CASE WHEN g%13=0 THEN NULL ELSE jsonb_build_object('n',g,'neg',-g,'s','x'||g) END,
    CASE WHEN g%17=0 THEN NULL ELSE ARRAY[g, g+1, -g] END,
    CASE WHEN g%7=0  THEN NULL WHEN g%500=0 THEN repeat('abc',4000) ELSE ('t'||g) END,
    CASE WHEN g%2=0  THEN '' ELSE ('z'||g) END
    FROM generate_series(1,12000) g"""

ALL_COLS = ["c_int", "c_big", "c_small", "c_num", "c_f4", "c_f8", "c_bool", "c_date",
            "c_ts", "c_tstz", "c_uuid", "c_bytea", "c_vc", "c_char", "c_iv", "c_jsonb",
            "c_arr", "c_text", "c_ztext"]

# uuid and bytea order under btree but have no min/max aggregate; the suite covers their
# ordering through the range predicates instead, and this list is why.
ORDERED = ["c_int", "c_big", "c_small", "c_num", "c_f4", "c_f8", "c_date", "c_ts",
           "c_tstz", "c_vc", "c_char", "c_iv", "c_text", "c_ztext"]

NUMERIC = ["c_int", "c_big", "c_small", "c_num", "c_f4", "c_f8"]

RANGES = {
    "c_int":   "c_int BETWEEN -50 AND 5000",
    "c_big":   "c_big > 6000000000000",
    "c_num":   "c_num BETWEEN 0 AND 5000",
    "c_f8":    "c_f8 < 0",
    "c_date":  "c_date BETWEEN DATE '2005-01-01' AND DATE '2010-01-01'",
    "c_ts":    "c_ts >= TIMESTAMP '2000-06-01'",
    "c_tstz":  "c_tstz < TIMESTAMPTZ '2000-03-01 00:00:00+00'",
    "c_vc":    "c_vc BETWEEN 'v100' AND 'v200'",
    "c_uuid":  "c_uuid > '80000000-0000-0000-0000-000000000000'::uuid",
    "c_bytea": r"c_bytea > '\x80'::bytea",
    "c_text":  "c_text > 't5000'",
}

EQUALITIES = {
    "c_int":   "c_int = 600",
    "c_vc":    "c_vc = 'v500'",
    "c_bool":  "c_bool = true",
    "c_uuid":  "c_uuid = md5('999')::uuid",
    "c_jsonb": "c_jsonb = jsonb_build_object('n',600,'neg',-600,'s','x600')",
    "c_arr":   "c_arr = ARRAY[600,601,-600]",
}


class _Pair:
    """The heap/columnar pair, and the one way to query both."""

    def __init__(self, conn):
        self.conn = conn

    def both(self, template):
        """(columnar_rows, heap_rows) for a query with %T for the table name."""
        col = self.conn.execute(template.replace("%T", "t_col")).fetchall()
        heap = self.conn.execute(template.replace("%T", "t_heap")).fetchall()
        return col, heap

    def one(self, sql):
        return self.conn.execute(sql).fetchone()[0]


@pytest.fixture(scope="module")
def matrix(pgc_cluster):
    """The type matrix, built once: 12,000 rows over twenty columns.

    Its own schema rather than `pgc_conn`'s per-test one, because the cost is the point --
    rebuilding this for each assertion would take the suite from seconds to minutes. The
    premise arms in test_the_matrix_fixture_is_what_it_claims stand in for the write watch
    that a module fixture cannot use.
    """
    import psycopg

    conn = psycopg.connect(pgc_cluster.dsn(), autocommit=True)
    schema = "pgc_differential_matrix"
    try:
        conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
        conn.execute(f'CREATE SCHEMA "{schema}"')
        conn.execute(f'SET search_path TO "{schema}", public')
        conn.execute("CREATE EXTENSION IF NOT EXISTS pgcolumnar")
        conn.execute(f"CREATE TABLE t_heap ({MATRIX_DEFS})")
        conn.execute(f"CREATE TABLE t_col ({MATRIX_DEFS}) USING pgcolumnar")
        # Small limits so 12,000 rows span many chunk groups and several stripes: the
        # skipping paths are only exercised when there is something to skip.
        conn.execute("SELECT pgcolumnar.set_options('t_col', "
                     "chunk_group_row_limit => 1000, stripe_row_limit => 5000)")
        conn.execute(f"INSERT INTO t_heap {MATRIX_LOAD}")
        conn.execute(f"INSERT INTO t_col {MATRIX_LOAD}")
        yield _Pair(conn)
    finally:
        try:
            conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
        finally:
            conn.close()


def test_the_matrix_fixture_is_what_it_claims(matrix, expect):
    """The premises the comparisons rest on, asserted rather than assumed.

    A differential suite over an empty table passes every comparison. So does one whose
    data fits in a single chunk group, while proving nothing about skipping. These three
    are the bash suite's own sanity arms, and here they also replace the `pgc_conn` write
    watch the module fixture cannot use.
    """
    expect.num(matrix.one("SELECT count(*) FROM t_col"), 12000, "matrix row count")
    # The catalogs lib.sh's chunk_group_count and stripe_count read. I guessed
    # `pgcolumnar.chunk_group` first and the server said it does not exist -- a guessed
    # catalog name is a premise arm that errors instead of asserting.
    expect.at_least(matrix.one(
        "SELECT count(*) FROM pgcolumnar.zone_map "
        "WHERE storage_id = pgcolumnar.get_storage_id('t_col') "
        "AND vector_index >= 0 AND column_index = 0"), 12, "matrix chunk groups>=12")
    expect.at_least(matrix.one(
        "SELECT count(*) FROM pgcolumnar.row_group "
        "WHERE storage_id = pgcolumnar.get_storage_id('t_col')"), 2, "matrix stripes>=2")


def test_the_whole_row_agrees_across_every_column(matrix, expect):
    """Every column of every row, in one comparison.

    The per-column arms below localise a failure; this one is what catches a bug that only
    shows when columns are read together -- a projection offset, a shared null bitmap.
    """
    col, heap = matrix.both("SELECT * FROM %T")
    expect.row_set(col, heap, "matrix whole-row")


@pytest.mark.parametrize("col", ALL_COLS)
def test_every_column_projects_counts_and_places_its_nulls(matrix, col, expect):
    """Projection, non-null count, and the positions of the nulls, per column.

    The null POSITIONS and not just the count: a decoder that loses the null bitmap's
    alignment returns the right number of nulls in the wrong rows, and a count alone
    cannot see it. Each column has its own null modulus, so the two directions
    (`IS NULL` and `IS NOT NULL`) partition that column's rows differently from every
    other column's.
    """
    c, h = matrix.both(f"SELECT id, {col} FROM %T")
    expect.row_set(c, h, f"{col} project")
    c, h = matrix.both(f"SELECT count({col}) FROM %T")
    expect.row_set(c, h, f"{col} count")
    # THE BASH ARM IS VACUOUS FOR c_ztext AND THIS PORT SAYS SO. c_ztext is
    # `CASE WHEN g%2=0 THEN '' ELSE 'z'||g END` -- never NULL, 6000 empty strings and
    # 6000 values. `diff_query "c_ztext is null"` therefore compares EMPTY against
    # EMPTY, which pgc_set_hash renders equal, and the check passes having compared
    # nothing to nothing. Measured: 0 rows IS NULL, 6000 rows = ''.
    #
    # So the assertion here is the one that can fail: the column's nulls agree AND the
    # column has nulls to agree about. Where it has none, that is stated as the
    # property instead, with the empty-string count as the positive control -- a
    # decoder that confused '' with NULL would move both numbers.
    c, h = matrix.both(f"SELECT id FROM %T WHERE {col} IS NULL")
    if col == "c_ztext":
        expect.row_set(c, h, f"{col} is null",
                       allow_empty="c_ztext is never NULL by construction; the arm below "
                                   "is what can fail")
        expect.num(matrix.one("SELECT count(*) FROM t_col WHERE c_ztext = ''"), 6000,
                   "c_ztext empty strings are not nulls")
    else:
        expect.row_set(c, h, f"{col} is null")
    c, h = matrix.both(f"SELECT id FROM %T WHERE {col} IS NOT NULL")
    expect.row_set(c, h, f"{col} not null")


@pytest.mark.parametrize("col", ORDERED)
def test_min_and_max_agree_for_every_ordered_type(matrix, col, expect):
    """min/max exercises the comparison operator the zone map also uses.

    A type whose stored min/max disagrees with its runtime comparison prunes a group that
    held a matching row, so this arm and the range arms below are the same property read
    from two directions.
    """
    c, h = matrix.both(f"SELECT min({col}), max({col}) FROM %T")
    expect.row_set(c, h, f"{col} min/max")


# Float addition is not associative, so a float sum has no single right answer: it has one
# per summation ORDER. MEASURED on heap alone, same table, three orders, full precision:
#
#     ORDER BY id        -0.27597385772197924
#     ORDER BY id DESC   -0.2759738577219848
#     ORDER BY c_f8      -0.2759738578545523
#
# Three answers from one table and one access method. So "columnar equals heap exactly" is
# false by construction for c_f4 and c_f8, and the bash suite asserts it anyway -- it passes
# because pgc_set_hash hashes the TEXT rendering, and psql's default precision rounds the
# difference away at some magnitudes and not others. Its tolerance is real, implicit, and
# magnitude-dependent.
#
# This port states the tolerance instead. Relative, because the error scales with the
# magnitude of the partial sums rather than the result: c_f8 sums to ~-0.28 out of terms of
# order 100, so an absolute bound would be either vacuous or false.
FLOAT_COLS = {"c_f4", "c_f8"}
FLOAT_RTOL = 1e-6


@pytest.mark.parametrize("col", NUMERIC)
def test_sum_and_avg_agree_for_every_numeric_type(matrix, col, expect):
    """sum and avg read every non-null value, so they catch a decode error the
    aggregates above can miss: min/max touch two rows, these touch all of them.

    Exact for the exact types -- int, bigint, smallint and numeric have no rounding, so a
    tolerance there would hide the defect this arm exists to find. Float is compared within
    a stated relative tolerance for the reason measured above the parametrize list.
    """
    c, h = matrix.both(f"SELECT sum({col}), avg({col}) FROM %T")
    if col not in FLOAT_COLS:
        expect.row_set(c, h, f"{col} sum/avg")
        return
    cs, hs = c[0], h[0]
    expect.num(len(cs), len(hs), f"{col} sum/avg returns the same shape")
    for got, want, what in zip(cs, hs, ("sum", "avg")):
        # A relative difference, asserted as a number so the failure prints it.
        rel = abs(got - want) / max(abs(want), 1e-300)
        expect.num(1 if rel <= FLOAT_RTOL else 0, 1,
                   f"{col} sum/avg agrees on {what} within {FLOAT_RTOL} relative "
                   f"(got {got!r} want {want!r}, relative {rel:.3e})")
    # AND THE CONTROL: the tolerance must not be so loose that it accepts anything. A
    # decode error large enough to matter is orders of magnitude outside it, so the arm
    # asserts the bound is tight enough to have a direction.
    expect.num(1 if FLOAT_RTOL < 1e-3 else 0, 1,
               f"{col} sum/avg tolerance is tight enough to fail on a real decode error")


@pytest.mark.parametrize("col", sorted(RANGES))
def test_a_range_predicate_agrees_for_every_type_that_has_one(matrix, col, expect):
    """Range predicates are what drive chunk-group skipping.

    A wrong zone map shows here and nowhere else: the rows are present and correct, and the
    scan never looks at the group that holds them. Per type, because the min/max comparison
    is the type's own.
    """
    c, h = matrix.both(f"SELECT id FROM %T WHERE {RANGES[col]}")
    expect.row_set(c, h, f"{col} range")


@pytest.mark.parametrize("col", sorted(EQUALITIES))
def test_an_equality_predicate_agrees_for_every_type_that_has_one(matrix, col, expect):
    """Equality is the predicate a bloom filter prunes on, and the one a hash can get
    wrong for a type whose equality is not byte equality -- jsonb and int[] are here for
    that reason."""
    # `c_int = 600` MATCHES NOTHING in the bash suite and the arm still passes. c_int is
    # `g*7-100`, so 600 needs g=100, and 100%5=0 puts a NULL there. Measured: 0 rows.
    # Both sides hash to EMPTY, compare equal, and the arm cannot fail.
    #
    # The fix is a probe value that is PRESENT, so the comparison has something to be
    # wrong about. 607 needs g=101, which no null modulus touches.
    c, h = matrix.both(f"SELECT id FROM %T WHERE {EQUALITIES[col]}")
    expect.row_set(c, h, f"{col} eq",
                   allow_empty=("c_int = 600 lands on a NULL row; see the present-value "
                                "arm below" if col == "c_int" else None))
    if col == "c_int":
        c, h = matrix.both("SELECT id FROM %T WHERE c_int = 607")
        expect.row_set(c, h, "c_int eq present")


def test_an_ordered_projection_agrees_in_order(matrix, expect):
    """ORDER BY ... LIMIT, where the ORDER is part of the assertion.

    `row_set` is order-blind deliberately, which is right for every arm above and wrong
    for these two: a query that asks for an order is the only kind that can be wrong about
    one. The premise comes first -- an oracle that cannot tell forward from reverse would
    pass both arms while asserting nothing, which is `pgc_check_ordered_oracle`'s third
    assertion and the reason it exists.
    """
    fwd, _ = matrix.both("SELECT id FROM %T ORDER BY id LIMIT 25")
    rev, _ = matrix.both("SELECT id FROM %T ORDER BY id DESC LIMIT 25")
    expect.ordering_observable(fwd, rev,
                              "premise: the ordered oracle is order-sensitive")

    c, h = matrix.both("SELECT id, c_int, c_text FROM %T ORDER BY id LIMIT 25")
    expect.ordered_rows(c, h, "order limit head")
    c, h = matrix.both("SELECT id, c_num, c_vc FROM %T ORDER BY id DESC LIMIT 25")
    expect.ordered_rows(c, h, "order limit tail")


def test_a_compound_predicate_over_several_columns_agrees(matrix, expect):
    """Four columns of four types in one WHERE, which is where a per-column arm cannot
    reach: the scan combines their skip decisions, and a predicate that is right alone can
    be wrong in conjunction."""
    c, h = matrix.both("SELECT id FROM %T WHERE c_int > 0 AND c_bool "
                       "AND c_vc IS NOT NULL AND c_num < 8000")
    expect.row_set(c, h, "compound")
