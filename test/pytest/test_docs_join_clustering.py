"""Public docs must name the layout that makes a join runtime filter a no-op (#752).

The skip measurement is already in native_join_runtime_filter: 19 of 20 groups
removed when the keys are local in the stripe, 0 of 20 when they cycle. The
how-to page named the GUC and not that discriminator. A star-schema fact table
that is not clustered on the join key still holds every key in every group, so
sideways information passing cannot skip.
"""

from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
HOWTO = ROOT / "docs" / "how-to.md"
PRACTICES = ROOT / "docs" / "best-practices.md"


def _section_after(path, heading):
    text = path.read_text(encoding="utf-8")
    start = text.find(heading)
    if start < 0:
        return ""
    rest = text[start + len(heading):]
    nxt = rest.find("\n## ")
    if nxt < 0:
        return rest
    return rest[:nxt]


def test_how_to_names_join_key_clustering_for_the_runtime_filter(expect):
    """The star-schema how-to must say when group skip is a no-op.

    Public seam: docs/how-to.md. Independently of docs_style.sh, this reads the
    section and requires both the layout verb and the join key in that section.
    """
    expect.num(int(HOWTO.is_file()), 1, "premise: how-to.md is in the tree")
    section = _section_after(HOWTO, "## Skip fact-table work under a star-schema join")
    expect.at_least(len(section), 1, "premise: the star-schema join heading is present")
    low = section.lower()
    expect.contains(low, "cluster", "the runtime-filter how-to names clustering")
    expect.contains(low, "join key", "and it names the join key as the clustering column")


def test_best_practices_names_join_key_clustering_for_a_fact_table(expect):
    """Layout guidance must cover the star-schema join key, not only timestamps.

    Public seam: docs/best-practices.md. The skipping section told readers to
    cluster on the column they filter by ranges. A join key is not a range.
    """
    expect.num(int(PRACTICES.is_file()), 1, "premise: best-practices.md is in the tree")
    text = PRACTICES.read_text(encoding="utf-8").lower()
    expect.contains(text, "join key", "best-practices names clustering on the join key")
