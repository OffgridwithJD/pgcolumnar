#!/usr/bin/env python3
"""Compare a bash suite and its pytest port PROPERTY BY PROPERTY, by name.

Counting is the wrong instrument. The bash suite has 8 checks and the port has 7
tests, and that difference is legitimate: one pytest test carries two of the bash
assertions. A count comparison calls that a defect. A name comparison does not,
and it catches the thing that matters, which is a property asserted in one
harness and nowhere in the other.

The port makes this possible by passing each assertion the SAME name string the
bash check uses. That is a convention the port must keep, so this script is also
what enforces it.

THE PYTHON SIDE IS PARSED, NOT MATCHED (#432, #897)
---------------------------------------------------

This read the pytest file with a regex and got the wrong argument:

    expect.sqlstate(err, "42501", "a role with no privilege is refused")
                         ^^^^^^^ reported as the assertion's name

`[^)]*?"([^"]+)"` is lazy, so it stops at the FIRST quoted argument. For
`expect.num(got, 1, "name")` that happens to be the name and the tool looked
correct. For any helper whose WANT is itself a string it is not:

    expect.sqlstate(err, "42501", NAME)   -> "42501"
    expect.text(got, "none", NAME)        -> "none"

So every SQLSTATE assertion was read as the literal `42501`, counted as an
"extra" name the bash suite does not have, and the real property was reported
MISSING. That is a false red aimed squarely at the ports #432 exists to produce,
which are the ones replacing a `grep` on an error message with a SQLSTATE. The
tool got blinder as the work it grades got better.

It is parsed with `ast` now, and the name is the LAST string argument of the
call, which is the convention every port already follows.

INTERPOLATED NAMES ARE MATCHED AS TEMPLATES
-------------------------------------------

Both harnesses build some names at runtime, bash as `non-owner refused: ${1%%(*}`
and pytest as an f-string. Neither can be expanded without running the suite, so
this compares the SHAPE: every interpolation on both sides becomes `{}`, and two
names match when their templates do.

That is a weaker claim than a literal match and it is reported separately rather
than folded in, because a template match says the two harnesses assert a property
of the same shape, not that they assert it over the same values. A port should
still prefer literal names.

Exit status is 1 when a bash property has no counterpart of either kind.
"""
import ast
import re
import sys


def _parametrized_names(tree):
    """-> every name supplied by a `@pytest.mark.parametrize` that declares one.

    A port of a suite whose bash half repeats a property per function writes the arm
    once and parametrises it, carrying the bash name as a parameter:

        @pytest.mark.parametrize("func,name", USAGE_ONLY)
        def test_a_role_with_only_schema_usage_is_refused(..., func, name):
            expect.sqlstate(err, "42501", name)

    The name reaching `expect` is then a variable, and reading only the call site
    reports every such property MISSING -- which would push a port AWAY from the one
    idiom that keeps the two harnesses one-to-one across a repeated property.

    Only the column actually called `name` is read, resolved through module-level
    constants, so the other parameters of the same decorator contribute nothing.
    """
    consts = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and \
                isinstance(node.targets[0], ast.Name):
            try:
                consts[node.targets[0].id] = ast.literal_eval(node.value)
            except (ValueError, TypeError, SyntaxError):
                pass

    out = []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "parametrize" and len(node.args) >= 2):
            continue
        argnames = _as_names(node.args[0])
        if not argnames:
            continue
        cols = [c.strip() for c in argnames[0].split(",")]
        if "name" not in cols:
            continue
        idx = cols.index("name")

        values = node.args[1]
        if isinstance(values, ast.Name):
            rows = consts.get(values.id)
        else:
            try:
                rows = ast.literal_eval(values)
            except (ValueError, TypeError, SyntaxError):
                rows = None
        if rows is None:
            continue
        for row in rows:
            if len(cols) == 1:
                cell = row
            elif isinstance(row, (tuple, list)) and len(row) > idx:
                cell = row[idx]
            else:
                continue
            if isinstance(cell, str):
                out.append(cell)
    return out


# WHERE THE NAME SITS, for the helpers where it is not the last argument (#1036).
#
# The rule for most of `Expect` is "the name is the last argument", and for 14 of its 18
# helpers that is true. It is not a property of the helpers, though, only of most of them,
# and the four below were read wrong in silence: the last argument is a real string in each
# case, so a wrong name looked exactly like a right one.
#
#   refusal(result, name, *patterns)      the last argument is a PATTERN
#   cannot_run(reason, detail="")         records `name=reason`, the FIRST argument
#   plan_marker(plan, key, name=None)     the last argument is a plan KEY
#   plan_node(plan, ..., name=None)       the last argument describes the NODE
#
# A value here is the index of the call argument carrying the name; `None` means no
# positional argument carries it and only a `name=` keyword can. `-1`, the default for
# every helper not listed, means the last one.
#
# This is a hand-written derived value, so it is pinned: the drift guard in
# `test_compare_to_bash.py` re-derives every entry from the real signatures in
# `pgc_vacuity.py` and fails with the helper named when the two disagree. Add a helper
# whose name is not last and that arm goes red before this table is wrong in the field.
_NAME_ARG = {
    "refusal": 1,
    "cannot_run": 0,
    "plan_marker": None,
    "plan_node": None,
}


def _py_names(src):
    """Every assertion name in the port, by parsing rather than matching.

    The name is the LAST argument of an `expect.<helper>(...)` call, or the value of
    a `name=` keyword, read through `_as_names` so a conditional carries both of
    its arms. Four helpers put it somewhere else and are read through `_NAME_ARG`.
    """
    tree = ast.parse(src)
    out = _parametrized_names(tree)
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        is_expect = (isinstance(func, ast.Attribute)
                     and isinstance(func.value, ast.Name)
                     and func.value.id == "expect")
        for kw in node.keywords:
            if kw.arg == "name":
                out.extend(_as_names(kw.value))
        if not is_expect or not node.args:
            continue
        idx = _NAME_ARG.get(func.attr, -1)
        if idx is None:
            continue
        if idx != -1 and len(node.args) <= idx:
            continue
        out.extend(_as_names(node.args[idx]))
    return out


def _as_names(node):
    """-> every string this node can evaluate to; [] when it states none.

    A LIST rather than one string, because `"a" if cond else "b"` is a name argument
    that carries two properties depending on the arm, and both are asserted by the
    suite. Reading only one of them reported the other MISSING, which is the same
    false red as reading the wrong argument, one level in.

    An f-string becomes a `{}` template. A node that is neither contributes nothing:
    reporting a name as absent is better than reporting the wrong string as present.
    """
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return [node.value]
    if isinstance(node, ast.JoinedStr):
        parts = []
        for v in node.values:
            if isinstance(v, ast.Constant) and isinstance(v.value, str):
                parts.append(v.value)
            else:
                parts.append("{}")
        return ["".join(parts)]
    if isinstance(node, ast.IfExp):
        return _as_names(node.body) + _as_names(node.orelse)
    return []


# `${...}`, `$(...)`, `$NAME`, and the POSITIONAL parameters. `$1` is how a bash
# helper names the thing it was called about, so it is the commonest interpolation
# in a check name and the first version of this missed every one of them.
_BASH_INTERP = re.compile(
    r'\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9]+|\$[@*#?]')


# EVERY CHECK HELPER `lib.sh` DEFINES, and the pattern built from it (#1040).
#
# This read five of the eight. `check_unrunnable`, `check_skip` and
# `check_ratio_needs_quiet_machine` matched no branch, so a bash property asserted
# through any of them was INVISIBLE: never reported MISSING, never able to move `rc`,
# and therefore a pair could grade one-for-one because the grader could not see the
# gap. `hilbert_locality` was exactly that -- two of the four properties its
# unrunnable branch records had no counterpart in the port.
#
# All eight take the check NAME as `$1`, so one pattern serves them all; that is a
# property of these helpers rather than of bash, and the drift guard re-reads it.
#
# `check_ratio` is a prefix of `check_ratio_needs_quiet_machine`, and the OLD pattern
# shape could not read the longer one at all: `check(?:_num|_ratio|_text|_timing)?\s+"`
# matches `check_ratio`, needs whitespace, finds `_needs...`, backtracks to the empty
# option, needs whitespace after `check`, and fails. Measured on a fixture holding both:
# the old form reads ['short'], this one reads ['short', 'long'].
#
# The entries are written longest-first for readability. **That ordering is NOT what
# makes it work** -- Python's `re` backtracks across alternatives, so a pure reorder
# reads both names identically (measured). An arm pins the BEHAVIOUR rather than the
# order, because the order is the thing that looks load-bearing and is not.
#
# WHICH ARGUMENT CARRIES THE NAME, per helper. This is the bash mirror of
# `_NAME_ARG` above, and it exists for the same reason: a helper's name is not
# always its first argument, and a pattern that assumes so reads the wrong string
# rather than no string.
#
# `pgc_skip <capability> <message>` is the case that forced it (#1045). Its check
# name is `$2`; `$1` is a capability, written bare at 68 of its 70 call sites and
# QUOTED at the other two. A single pattern keyed to the first quoted argument
# therefore reads the name almost everywhere and the CAPABILITY at
# `pgc_skip "test_decoding" "..."` -- and a wrong name is worse than an absent one,
# because it can never be matched by a port and is reported MISSING for ever.
#
# `diff_query` and `diff_query_ordered` are the other half: `lib.sh` wrappers that
# forward their `$1` into `check`. The NAME is in the suite, only the RECORDER is
# in `lib.sh`, and the extractor read neither. 225 names across 59 suites were
# invisible, 80 of them in `differential`, which graded one-for-one on 6 of its 86.
#
# Hand-written so the tool stays standalone, and pinned like `_NAME_ARG`: the drift
# guard in `test_compare_to_bash.py` DERIVES this table from `lib.sh` -- membership
# and position both -- and fails with the helper named when the two disagree.
_BASH_NAME_ARG = {
    "check_ratio_needs_quiet_machine": 1,
    "check_unrunnable": 1,
    "diff_query_ordered": 1,
    "diff_query": 1,
    "check_timing": 1,
    "check_ratio": 1,
    "check_text": 1,
    "check_skip": 1,
    "check_num": 1,
    "check": 1,
    "pgc_pass": 1,
    "pgc_fail": 1,
    "pgc_skip": 2,
}

# The membership view of the table, kept because that is what the reader wants when
# the question is "does the extractor know about X".
_BASH_HELPERS = tuple(_BASH_NAME_ARG)


def _template(name):
    """-> the name with every interpolation reduced to `{}`.

    Applied to both sides, so `non-owner refused: ${1%%(*}` and the f-string
    `f"non-owner refused: {fn}"` land on the same string.
    """
    return re.sub(r"\{[^{}]*\}", "{}", _BASH_INTERP.sub("{}", name))


def _at(pos):
    return tuple(h for h, p in _BASH_NAME_ARG.items() if p == pos)


# One shell word: a double-quoted string, or a run of non-space. Used only to STEP
# OVER the arguments before the name, never to capture one.
_WORD = r'(?:"[^"]*"|\S+)'

# `\b` before the alternation, so `check` does not match inside `pgc_check_thing`.
# The alternatives are listed longest-first, which READS as though it matters and
# does not: python's `re` backtracks across them. The pattern SHAPE is what makes
# `check_ratio_needs_quiet_machine` readable, and an arm holds that.
_BASH_PATTERN = r'\b(?:' + "|".join(_at(1)) + r')\s+"([^"]+)"'
_BASH_PATTERN_2 = r'\b(?:' + "|".join(_at(2)) + r')\s+' + _WORD + r'\s+"([^"]+)"'


def _bash_names(text):
    """-> every check name the suite states, each read from the argument that holds it.

    A LIST, not a set, because the caller reports both the total and the distinct
    count and the difference between them is information: a suite asserting the same
    property twice is a different thing from one asserting it once.
    """
    return re.findall(_BASH_PATTERN, text) + re.findall(_BASH_PATTERN_2, text)


def main(bash_file, py_file):
    """-> the exit status: 1 when a bash property has no counterpart."""
    bash_names = _bash_names(open(bash_file).read())
    py_names = _py_names(open(py_file).read())

    bset, pset = set(bash_names), set(py_names)

    print(f"bash checks: {len(bash_names)} ({len(bset)} distinct)")
    print(f"pytest named assertions: {len(py_names)} ({len(pset)} distinct)")
    print()

    literal = bset & pset
    # Only names with no literal partner are considered as templates, so a template
    # match can never hide a literal one or be double-counted.
    b_left, p_left = bset - literal, pset - literal
    p_templates = {_template(n) for n in p_left}
    templated = {n for n in b_left if _template(n) in p_templates}

    missing = sorted(b_left - templated)
    extra = sorted(n for n in p_left if _template(n) not in {_template(m) for m in templated})

    print("PROPERTIES IN THE BASH SUITE AND NOT IN THE PORT:")
    if missing:
        for n in missing:
            print(f"  MISSING  {n}")
    else:
        print("  none -- every bash property is asserted by name in the port")
    print()
    if templated:
        print("MATCHED BY TEMPLATE ONLY (both sides build the name at runtime):")
        for n in sorted(templated):
            print(f"  shape    {n}")
        print()
    print("ASSERTIONS IN THE PORT AND NOT IN THE BASH SUITE:")
    if extra:
        for n in extra:
            print(f"  extra    {n}")
    else:
        print("  none")
    print()
    print(f"literal matches: {len(literal)} | template matches: {len(templated)} | "
          f"missing: {len(missing)}")
    print("VERDICT:", "PORT IS INCOMPLETE" if missing else "every bash property is covered")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
