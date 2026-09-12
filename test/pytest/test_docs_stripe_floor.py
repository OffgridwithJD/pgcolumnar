"""The docs must name 1024 as the floor for `stripe_row_limit` (#1017).

A vector is a fixed 1024 values (`COLUMNAR_NATIVE_VECTOR_LENGTH`), so a row group
smaller than one vector never fills one and the chunk-shared FSST symbol table is
not built. Measured on 200,000 rows of a text column, `compression = none`:

    stripe_row_limit 1000   0 FSST tables    13,625,000   106.4% of raw
    stripe_row_limit 1200   166 tables        6,998,031    54.7% of raw

The accepted minimum is 1000, so the most aggressive legal setting is the one that
pays this. `docs/administration.md` tells a reader to LOWER this setting for
point-lookup-heavy tables, which is the path into it, so the warning has to live
beside that advice and not only in a reference table.

Public seam: the three published pages. Read independently of docs_style.sh --
this parses the pages itself rather than sharing a helper with the shell arm.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "docs" / "configuration.md"
ADMIN = ROOT / "docs" / "administration.md"
PRACTICES = ROOT / "docs" / "best-practices.md"


def _states_the_floor(path):
    """True when ONE LINE names the setting and the floor together.

    Not a block, and not a proximity window. Both were tried and both were born
    green: `configuration.md`'s GUC table has no blank lines, so a paragraph reader
    puts `stripe_row_limit`'s row and `chunk_group_row_limit`'s "fixed 1024-value
    vectors" in one unit, and those rows are adjacent so a three-line window does
    the same. Measured on `main`: block and window both say yes, one line says no
    for all three pages.

    Requiring one line is also a claim about the PROSE -- the floor has to be stated
    in a sentence, not inferred from two tokens that happen to be neighbours.
    """
    for line in path.read_text(encoding="utf-8").splitlines():
        if "stripe_row_limit" in line and "1024" in line:
            return True
    return False


def test_configuration_states_the_floor_where_it_documents_the_setting(expect):
    expect.num(int(CONFIG.is_file()), 1, "premise: configuration.md is in the tree")
    expect.num(int(_states_the_floor(CONFIG)), 1,
               "configuration.md states the 1024 floor on the setting's own line")


def test_administration_states_it_beside_the_advice_to_lower_it(expect):
    """`administration.md` tells a reader to LOWER this setting for point lookups.
    That is the path into the cliff, so the floor has to be on this page."""
    expect.num(int(ADMIN.is_file()), 1, "premise: administration.md is in the tree")
    expect.num(int(_states_the_floor(ADMIN)), 1,
               "administration.md states the floor beside the lowering advice")
    low = ADMIN.read_text(encoding="utf-8").lower()
    expect.num(int("fsst" in low), 1, "and names what lowering past it costs")


def test_best_practices_carries_the_floor_with_the_load_sizing_advice(expect):
    expect.num(int(PRACTICES.is_file()), 1, "premise: best-practices.md is in the tree")
    expect.num(int(_states_the_floor(PRACTICES)), 1,
               "the load-sizing advice states the floor on the same line")
