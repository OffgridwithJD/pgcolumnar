"""The pg_partman how-to keeps its own heading.

An edit that inserted a section before it replaced the heading instead (3627327,
#1315), and every docs check passed: the steps were still valid Markdown, filed
under "Count distinct values and percentiles approximately".

The pytest half of the docs_style.sh arm of the same name, written independently:
it splits the how-to on its level-two headings and reads the section's first
paragraph.

Needs the repository only, not a cluster or the driver.
"""
import pathlib
import re

HOWTO = pathlib.Path(__file__).resolve().parents[2] / "docs" / "how-to.md"


def _sections():
    """-> {heading text: body} for every '## ' section of the how-to."""
    parts = re.split(r"^## (.+)$", HOWTO.read_text(), flags=re.M)
    return {parts[i].strip(): parts[i + 1] for i in range(1, len(parts) - 1, 2)}


def test_the_how_to_keeps_its_pg_partman_section_under_its_own_heading(expect):
    body = _sections().get("Manage time partitions with pg_partman", "")
    first = next((p.strip() for p in body.split("\n\n") if p.strip()), "")
    expect.num(1 if first.startswith("pg_partman can create and drop columnar partitions") else 0, 1,
               "the how-to keeps its pg_partman section under its own heading")
