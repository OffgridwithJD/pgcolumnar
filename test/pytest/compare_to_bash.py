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
# Hand-written so the tool stays standalone, and pinned like `_NAME_ARG`:
# `test_compare_to_bash.py` reads the DEFINITIONS out of `lib.sh` and fails with the
# helper named when the two part company.
#
# SUITE-LOCAL HELPERS ARE OUT OF SCOPE, deliberately. Four suites define one of their
# own (`check_structure`, `check_reconstruct`, `check_split_happened` in
# `parallel_copy.sh`, `check_float` in `parquet_export_stats.sh`) and none of the four
# has a pytest twin, so none is graded. An arm asserts both halves of that.
_BASH_HELPERS = (
    "check_ratio_needs_quiet_machine",
    "check_unrunnable",
    "check_timing",
    "check_ratio",
    "check_text",
    "check_skip",
    "check_num",
    "check",
)

_BASH_PATTERN = (r'\b(?:' + "|".join(_BASH_HELPERS) + r')\s+"([^"]+)"')


def _template(name):
    """-> the name with every interpolation reduced to `{}`.

    Applied to both sides, so `non-owner refused: ${1%%(*}` and the f-string
    `f"non-owner refused: {fn}"` land on the same string.
    """
    return re.sub(r"\{[^{}]*\}", "{}", _BASH_INTERP.sub("{}", name))


def main(bash_file, py_file):
    """-> the exit status: 1 when a bash property has no counterpart."""
    bash_names = re.findall(_BASH_PATTERN, open(bash_file).read())
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
