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


def _shipped_sources():
    """The versions an upgrade script starts from, from the filenames on disk."""
    out = set()
    for path in ROOT.glob("pgcolumnar--*--*.sql"):
        out.add(path.name[len("pgcolumnar--"):-len(".sql")].split("--")[0])
    return out


def _default_version():
    for line in CONTROL.read_text(encoding="utf-8").splitlines():
        hit = re.match(r"\s*default_version\s*=\s*'([^']*)'", line)
        if hit:
            return hit.group(1)
    return ""


def _claim_sentences(path):
    """Every sentence in the file that makes the upgrade-chain claim.

    A LIST, not the first match. Reading only the first leaves a second sentence
    unchecked, and a document that states the chain twice is the way this rule
    goes quiet without anything turning red.
    """
    flat = " ".join(path.read_text(encoding="utf-8").split())
    return [s for s in re.split(r"(?<=\.)\s+", flat) if _CLAIM.search(s)]


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


def test_every_document_names_the_versions_the_scripts_start_from(expect):
    """Both sides carry the versions, so a failure says what is wrong, not only where."""
    truth = " ".join(sorted(_shipped_sources()))
    got, want = [], []
    for path in _documents():
        named = set()
        for sentence in _claim_sentences(path):
            named |= _starting_versions(sentence)
        got.append(f"{path.name}=[{' '.join(sorted(named))}]")
        want.append(f"{path.name}=[{truth}]")
    expect.text(
        " ".join(got), " ".join(want),
        "every such document names the versions the shipped upgrade scripts start from")


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
