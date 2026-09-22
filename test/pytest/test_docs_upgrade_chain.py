"""A document naming the upgrade chain names the one the tree ships.

Two claims travel in one sentence. It says which installed versions a single
`ALTER EXTENSION pgcolumnar UPDATE` can start from, and which version it arrives
at. Both are knowable from the tree: the `pgcolumnar--A--B.sql` files give the
starting versions, and `pgcolumnar.control` gives the arrival.

Nothing compared them. Opening the `1.0-alpha5` cycle bumped `VERSION`, the
control file, the version badge and `META.json`, and CHANGELOG.md went on saying
that the chain starts at four versions and arrives at `1.0-alpha4`. Five ship and
it arrives at `1.0-alpha5`. `docs/limitations.md` was two cycles worse: it named
three scripts and stopped at `1.0-alpha3`.

THE TWO ERRORS CANCEL IF YOU COUNT. CHANGELOG.md named `1.0-alpha4` once too few
as a starting version and once too many as the destination, so the SET of
versions in the sentence was exactly right. A rule comparing that set against the
tree would have passed a sentence in which both halves were wrong. So the two
claims are read separately here, each against its own source on disk.

Read independently of docs_style.sh. That suite folds the file with `tr` and cuts
sentences with `sed`; this one splits on a lookbehind and collects with `re`, so
a parsing mistake in one is not a parsing mistake in the other.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTROL = ROOT / "pgcolumnar.control"
CANDIDATES = (
    [ROOT / "CHANGELOG.md", ROOT / "README.md"]
    + sorted((ROOT / "docs").glob("*.md"))
)

_CLAIM = re.compile(r"previously (?:shipped|published) version")
_VERSION = re.compile(r"`(1\.0-[a-z0-9]+)`")
_REACHES = re.compile(r"reaches `([^`]*)`")


def _upgrade_steps():
    """-> {starting version: [target, ...]} from the shipped script filenames."""
    steps = {}
    for path in ROOT.glob("pgcolumnar--*--*.sql"):
        src, _, dst = path.name[len("pgcolumnar--"):-len(".sql")].partition("--")
        steps.setdefault(src, []).append(dst)
    return steps


def _shipped_sources():
    """The versions an upgrade script starts from, from the filenames on disk."""
    return set(_upgrade_steps())


def _reaching_versions():
    """The versions that reach `default_version` by following the shipped scripts.

    THE CLAIM IS REACHABILITY, NOT MEMBERSHIP. "a single update reaches X from any
    of them" says the scripts form an unbroken chain, and the set of starting
    versions cannot see that: renaming `1.0-alpha2--1.0-alpha3.sql` to
    `1.0-alpha2--1.0-alphaX.sql` leaves `1.0-alpha2` starting a script while three
    of the five named versions can no longer arrive. Reported by @OffgridwithJD.

    The step count is bounded because two mis-generated scripts can form a cycle,
    and a guard that hangs is a guard that gets removed.
    """
    steps = _upgrade_steps()
    target = _default_version()
    out = set()
    for start in steps:
        cur, walked = start, 0
        while cur != target and walked < 50:
            nxt = steps.get(cur)
            if not nxt:
                break
            cur = sorted(nxt)[0]
            walked += 1
        if cur == target:
            out.add(start)
    return out


def _default_version():
    for line in CONTROL.read_text(encoding="utf-8").splitlines():
        hit = re.match(r"\s*default_version\s*=\s*'([^']*)'", line)
        if hit:
            return hit.group(1)
    return ""


_MARKER = re.compile(r"^(\d+)\. ")
_MASK = "@LM@"


def _flatten(text):
    """One line, with markdown list markers masked so they are not full stops.

    A LIST MARKER BEGINS A LINE, and nothing else does. The first version of this
    masked any number followed by period-space, which also protects a sentence
    ENDING in a number and merges it with the next one. @OffgridwithJD
    demonstrated it by injecting `The corpus held 1444. ` ahead of the claim, so
    the masking happens per line, before the lines are joined.

    NO VERDICT MOVES EITHER WAY TODAY, and that is stated rather than implied. The
    claim was moved into numbered step 3 and both halves read the whole sentence
    with and without any masking, because a marker PRECEDES a sentence rather than
    sitting inside it.

    THE OVER-MATCH WAS LIVE, THOUGH. Sentences found on the unmodified documents:

    Measured at acc4116d, and the revision is the load-bearing part: these
    documents grow, so CHANGELOG.md read 66 lost at 5649eba, 69 at 197602f and 71
    here, with nothing about the rule changing.

        docs/limitations.md    699 column-0    690 any-number    9 lost
        docs/installation.md    74              72               2 lost
        CHANGELOG.md          3957            3886              71 lost

    None of those merged pairs put a stray version token into the claim sentence,
    so no verdict changed. That is a property of today's prose rather than of the
    rule.

    COLUMN 0, NOT "LINE-INITIAL AFTER INDENT". Allowing an indented marker read
    3939 on CHANGELOG.md against @OffgridwithJD's 3942, and the three lines that
    differ are wrapped prose rather than list items -- a sentence ending in a
    number, wrapped so the number starts an indented line, which is the same
    over-match one indent to the right. Every real ordered-list marker in these
    documents is at column 0.
    """
    masked = [_MARKER.sub(lambda m: m.group(1) + "." + _MASK, line, count=1)
              for line in text.splitlines()]
    return " ".join(" ".join(masked).split())


def _sentences(flat):
    """Split on a full stop.

    A SCANNER, not a split. The shell twin runs `sed` over the file and cuts with
    a second `sed`; this walks the candidate boundaries and keeps each sentence
    with its own period, so a mistake in one is not a mistake in the other.
    """
    out, start = [], 0
    for m in re.finditer(r"\.\s+", flat):
        out.append(flat[start:m.end()].strip())
        start = m.end()
    out.append(flat[start:].strip())
    return [s.replace(_MASK, " ").strip() for s in out if s.strip()]


def _claim_sentences(path):
    """Every sentence in the file that makes the upgrade-chain claim.

    A LIST, not the first match. Reading only the first leaves a second sentence
    unchecked, and a document that states the chain twice is the way this rule
    goes quiet without anything turning red.
    """
    flat = _flatten(path.read_text(encoding="utf-8"))
    return [s for s in _sentences(flat) if _CLAIM.search(s)]


def _starting_versions(sentence):
    """The versions named as starting points, with the destination removed first.

    The two claims share one sentence, so the destination has to come out before
    the rest are collected or it reads as a starting version too.
    """
    return set(_VERSION.findall(_REACHES.sub("", sentence)))


def _destination(sentence):
    return set(_REACHES.findall(sentence))


def _documents():
    return [p for p in CANDIDATES if p.is_file() and _claim_sentences(p)]


def test_the_tree_states_a_chain_to_compare_against(expect):
    """The two sources on disk exist, so neither arm below compares with nothing."""
    expect.at_least(
        len(_shipped_sources()), 1,
        "premise: the tree ships upgrade scripts to derive the chain from")
    expect.at_least(
        len(_default_version()), 1,
        "premise: the control file names a default_version to arrive at")
    expect.at_least(
        len(_documents()), 1,
        "premise: at least one document states the upgrade chain")
    branching = {s: len(t) for s, t in _upgrade_steps().items() if len(t) != 1}
    expect.text(
        " ".join(f"{s}={n}" for s, n in sorted(branching.items())) or "none", "none",
        "each shipped version starts exactly one upgrade script, so the chain is a walk")
    expect.at_least(
        len(_reaching_versions()), 1,
        "premise: some shipped version reaches default_version, so the walk found a chain")


def test_every_document_states_the_chain_in_a_readable_form(expect):
    """A document this rule cannot read is how the rule stops holding.

    Named with its reason rather than merely named. `reaches it from every
    previously published version` is the form that hid in `docs/installation.md`:
    the sentence is correct English and carries no destination a machine can find.
    """
    got, want = [], []
    for path in _documents():
        sentences = _claim_sentences(path)
        if len(sentences) != 1:
            reason = f"claims={len(sentences)}"
        elif not _starting_versions(sentences[0]):
            reason = "no-starting-versions"
        elif not _destination(sentences[0]):
            reason = "no-destination"
        else:
            reason = "readable"
        got.append(f"{path.name}={reason}")
        want.append(f"{path.name}=readable")
    expect.text(
        " ".join(got), " ".join(want),
        "every document stating the upgrade chain states it in a form this rule can read")


def test_every_document_names_the_versions_that_reach_default_version(expect):
    """Both sides carry the versions, so a failure says what is wrong, not only where."""
    truth = " ".join(sorted(_reaching_versions()))
    got, want = [], []
    for path in _documents():
        named = set()
        for sentence in _claim_sentences(path):
            named |= _starting_versions(sentence)
        got.append(f"{path.name}=[{' '.join(sorted(named))}]")
        want.append(f"{path.name}=[{truth}]")
    expect.text(
        " ".join(got), " ".join(want),
        "every such document names the versions that reach default_version in one update")


def test_every_document_names_default_version_as_the_destination(expect):
    truth = _default_version()
    got, want = [], []
    for path in _documents():
        named = set()
        for sentence in _claim_sentences(path):
            named |= _destination(sentence)
        got.append(f"{path.name}=[{' '.join(sorted(named))}]")
        want.append(f"{path.name}=[{truth}]")
    expect.text(
        " ".join(got), " ".join(want),
        "every such document names default_version as the version one UPDATE reaches")
