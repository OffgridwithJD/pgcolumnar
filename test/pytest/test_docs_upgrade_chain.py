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


def _sentences(flat):
    """Split on a full stop, and NOT on a markdown list marker.

    A period after a bare number ends a list marker, not a sentence, and
    `docs/installation.md` already yields two fragments that are nothing but "2."
    and "3.". Raised by @OffgridwithJD.

    NO VERDICT CHANGES TODAY. The claim was moved into numbered step 3 and both
    halves still read the whole sentence, with and without this guard, because the
    marker PRECEDES the sentence rather than sitting inside it. This refuses a
    boundary the rest of the file was never designed to receive; it is not carrying
    a proof.

    A SCANNER, not a masking pass. The shell twin masks the markers, splits and
    restores; this walks the candidate boundaries and refuses the ones whose left
    side ends in a bare number. Same rule, and a mistake in one is not a mistake
    in the other.
    """
    out, start = [], 0
    for m in re.finditer(r"\.\s+", flat):
        if re.search(r"(?:^|\s)\d+$", flat[start:m.start()]):
            continue
        out.append(flat[start:m.end()].strip())
        start = m.end()
    out.append(flat[start:].strip())
    return [s for s in out if s]


def _claim_sentences(path):
    """Every sentence in the file that makes the upgrade-chain claim.

    A LIST, not the first match. Reading only the first leaves a second sentence
    unchecked, and a document that states the chain twice is the way this rule
    goes quiet without anything turning red.
    """
    flat = " ".join(path.read_text(encoding="utf-8").split())
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
