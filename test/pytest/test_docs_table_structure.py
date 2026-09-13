"""A markdown table that stops being a table must fail the docs gate (#1026).

`docs_style.sh` enforced seven rules over every user-facing page -- sentence length, the
idiom list, em and en dashes, prose double-hyphens, conflict markers, the nav entry, and
every `VERSION` citation. **All seven are about prose.** So a table that had stopped being a
table passed the gate whose whole purpose is keeping those pages readable.

**The measured case.** A note and a second table spliced into the middle of
`configuration.md`'s `set_options` argument table left six of the nine arguments as a
headerless block, and `docs_style.sh` passed with 14 checks. Found in review by
@linuxhikerpm, after I had reviewed the same change twice checking sentence length, a
guard's scoping claim and a three-row mutation table -- and never asking whether the
markdown still rendered.

It was the second splice of the day. The first gave `configuration.md`'s GUC table no blank
lines, which made an `awk RS=''` guard read two GUC rows as one record and pass on `main`.
Both are the same fact: a markdown table is a contiguous run of `|` lines and a blank line
is structural.

**These tests drive the real checker**, for the reason the other guard tests do: a python
twin of a python rule would agree with itself.
"""

import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from plain_language_check import headerless_tables          # noqa: E402

WELL_FORMED = """Some prose.

| Setting | Default |
| --- | --- |
| `a` | `1` |
| `b` | `2` |

More prose.
"""

# The defect, reduced: a blank line ends the first table, and the rows after the note have
# no header of their own.
SPLICED = """Some prose.

| Setting | Default |
| --- | --- |
| `a` | `1` |

A note about `a`, and a table of its own:

| case | result |
| --- | --- |
| one | two |

More prose about it.
| `b` | `2` |
| `c` | `3` |
"""


def test_a_well_formed_table_is_not_flagged(expect):
    """THE CONTROL, and it comes first. A rule that flags every table would catch the
    defect and be turned off the same day, so the arm that matters is this one."""
    expect.num(len(headerless_tables(WELL_FORMED)), 0,
               "a table with its separator row is not flagged")


def test_rows_orphaned_by_a_splice_are_flagged_with_their_line(expect):
    """The defect itself, and the line number, because a report that cannot say WHERE is
    one somebody has to re-derive."""
    bad = headerless_tables(SPLICED)
    expect.num(len(bad), 1, "the orphaned rows are flagged exactly once")
    # The `| b |` row, which is line 14 of SPLICED.
    expect.num(bad[0], 14, "and the report names the line the orphaned block starts at")


def test_a_pipe_inside_a_fenced_code_block_is_not_a_table(expect):
    """Fences are tracked rather than stripped by regex.

    A shell pipeline in a code fence starts with a pipe often enough to matter, and the
    regex form used elsewhere in this file loses line numbers and breaks on an unclosed
    fence. Both halves are asserted: inside a fence nothing is flagged, and the same text
    outside one IS -- or the arm passes because the rule flags nothing anywhere.
    """
    fenced = "Prose.\n\n```\n| grep -c foo\n| wc -l\n```\n\nMore prose.\n"
    expect.num(len(headerless_tables(fenced)), 0,
               "pipes inside a fence are not a table")
    unfenced = "Prose.\n\n| grep -c foo\n| wc -l\n\nMore prose.\n"
    expect.num(len(headerless_tables(unfenced)), 1,
               "control: the same lines outside a fence ARE flagged, so the fence is "
               "what excluded them")


def test_an_unclosed_fence_does_not_swallow_the_rest_of_the_file(expect):
    """The case the regex form gets wrong.

    `re.sub(r'```.*?```')` needs a closing fence; with one missing it matches nothing and
    the fence's contents are scanned as prose. Tracking state by line means an unclosed
    fence swallows what follows, which is the safe direction -- it under-reports rather
    than inventing a table.
    """
    unclosed = "Prose.\n\n```\n| not a table\n\n| `b` | `2` |\n"
    expect.num(len(headerless_tables(unclosed)), 0,
               "an unclosed fence under-reports rather than inventing a table")


def test_the_documents_the_gate_checks_are_clean(expect):
    """The false-positive budget, asserted rather than measured once and trusted.

    A static guard in this tree has to be 0 over the tree before it lands, or it arrives
    red on existing content and somebody disables it. This keeps that true: the rule is
    green over the gate's own scope, and if a page acquires a headerless table the arm
    names the page rather than the whole gate going red for an unrelated reason.
    """
    root = HERE.parent.parent
    pages = sorted(root.glob("docs/*.md")) + [root / "README.md"]
    expect.at_least(len(pages), 8, "premise: the gate's scope is the pages it claims")
    offenders = {p.name: headerless_tables(p.read_text(errors="replace")) for p in pages}
    offenders = {k: v for k, v in offenders.items() if v}
    expect.text(", ".join(f"{k}:{v}" for k, v in offenders.items()) or "none", "none",
                "every page the gate checks carries well-formed tables only")
