"""A suite's own EXIT trap must still stop its cluster (#1321).

The pytest half of selftest part 620, with its own reader. It does not source, call
or import lib.sh, the part, or any shell helper: it reads the suites as text, the
way the part does, but through Python's shlex rather than sed and awk, so the twins
share the rule and not the parser.

pgc_setup arms `trap pgc_on_exit EXIT`; pgc_on_exit stops the server and removes the
workdir (pgc_teardown) and gives a suite that died its accounting (#1233). Bash keeps
one EXIT trap, so a suite that arms its own after pgc_setup must call back into one
of the two. native_upgrade_converge.sh did not, and every run left its server
listening and its workdir in /tmp.

Needs no cluster and no driver.
"""

import pathlib
import re
import shlex

HERE = pathlib.Path(__file__).resolve().parent
TESTDIR = HERE.parent
CHAIN = ("pgc_on_exit", "pgc_teardown")


def _code(text):
    """The text with shell comments removed: a `#` that starts a word, outside quotes.

    Not "everything after #": `$#` and `${x#y}` are not comments. A backslash escapes
    the next character except inside single quotes, as in the shell.
    """
    out = []
    for line in text.splitlines():
        cut, quote, i = None, None, 0
        while i < len(line):
            ch = line[i]
            if ch == "\\" and quote != "'":
                i += 2
                continue
            if quote:
                if ch == quote:
                    quote = None
            elif ch in "'\"":
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1] in " \t;"):
                cut = i
                break
            i += 1
        out.append(line if cut is None else line[:cut])
    return out


def _handlers(lines):
    """The handler of every `trap HANDLER ... EXIT ...` line."""
    found = []
    for line in lines:
        try:
            words = shlex.split(line)
        except ValueError:
            continue
        if len(words) >= 3 and words[0] == "trap" and "EXIT" in words[2:]:
            found.append(words[1])
    return found


def _body(lines, name):
    """The function's own lines: one for `name() { ...; }`, else up to its `}`."""
    for i, line in enumerate(lines):
        if not line.startswith(name + "()"):
            continue
        if re.search(r"\{.*\}\s*$", line):
            return [line]
        body = [line]
        for nxt in lines[i + 1:]:
            body.append(nxt)
            if nxt.startswith("}"):
                break
        return body
    return []


def _offenders(paths):
    bad = []
    for path in paths:
        lines = _code(pathlib.Path(path).read_text())
        if not any(re.match(r"\s*pgc_setup(\s|$)", ln) for ln in lines):
            continue
        for h in _handlers(lines):
            if any(c in h for c in CHAIN):
                continue
            if any(c in ln for ln in _body(lines, h) for c in CHAIN):
                continue
            bad.append(pathlib.Path(path).name)
            break
    return bad


SUITES = {
    "replaces": "pgc_setup x\ncleanup() {\n\trm -f y\n}\ntrap cleanup EXIT\n",
    "replaces_on_signals": "pgc_setup x\ncleanup() {\n\trm -f y\n}\ntrap cleanup EXIT INT TERM\n",
    "names_it_in_a_comment": "pgc_setup x\ncleanup() {\n\trm -f y # then pgc_teardown\n}\ntrap cleanup EXIT\n",
    "next_function_has_it": "pgc_setup x\nt() { a; }\nother() {\n\tpgc_teardown\n}\ntrap t EXIT\n",
    "chains_the_wrapper": "pgc_setup x\ncleanup() {\n\tpgc_on_exit\n\trm -f y\n}\ntrap cleanup EXIT\n",
    "chains_the_teardown": "pgc_setup x\nt() { a; pgc_teardown; }\ntrap t EXIT INT TERM\n",
    "chains_in_quotes": "pgc_setup x\ntrap 'restore; pgc_on_exit' EXIT\n",
    "no_setup": "cleanup() {\n\trm -f y\n}\ntrap cleanup EXIT\n",
}


def _built(tmp_path, *names):
    paths = []
    for n in names:
        p = tmp_path / f"{n}.sh"
        p.write_text(SUITES[n])
        paths.append(p)
    return paths


def test_the_detector_flags_a_handler_that_reaches_neither(tmp_path, expect):
    expect.text("\n".join(_offenders(_built(tmp_path, "replaces", "replaces_on_signals"))),
                "replaces.sh\nreplaces_on_signals.sh",
                "the detector flags a handler that reaches neither pgc_on_exit nor pgc_teardown")


def test_the_detector_is_not_satisfied_by_a_comment_or_the_next_function(tmp_path, expect):
    expect.text("\n".join(_offenders(_built(tmp_path, "names_it_in_a_comment", "next_function_has_it"))),
                "names_it_in_a_comment.sh\nnext_function_has_it.sh",
                "and is not satisfied by the name in a comment or in the next function")


def test_the_detector_passes_a_handler_that_chains(tmp_path, expect):
    got = _offenders(_built(tmp_path, "chains_the_wrapper", "chains_the_teardown",
                            "chains_in_quotes", "no_setup"))
    expect.text(f"[{' '.join(got)}]", "[]",
                "and passes a handler that chains either, and a suite without pgc_setup")


def test_no_suites_own_exit_trap_leaves_its_cluster_running(expect):
    lib = _code((TESTDIR / "lib.sh").read_text())
    setup = _body(lib, "pgc_setup")
    expect.num(sum(1 for ln in setup if re.search(r"\btrap pgc_on_exit EXIT\b", ln)), 1,
               "premise: pgc_setup still arms the trap this part protects")
    got = _offenders(sorted(TESTDIR.glob("*.sh")))
    expect.text(f"[{' '.join(got)}]", "[]", "no suite's own EXIT trap leaves its cluster running")
