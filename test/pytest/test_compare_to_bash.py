"""`compare_to_bash.py` must read the assertion's NAME, not some other argument (#432).

The parity tool is what decides whether a port is one-for-one with its bash suite, which
is #432's definition of done. So the tool is a claim like any other, and it was wrong in a
way that pointed directly at the work it grades.

THE DEFECT. The python side was matched with a regex:

    expect\\.\\w+\\([^)]*?"([^"]+)"\\s*(?:,[^)]*)?\\)

`[^)]*?` is lazy, so it stopped at the FIRST quoted argument. For `expect.num(got, 1,
NAME)` that is the name, and the tool looked correct on every arm anyone checked. For a
helper whose WANT is itself a string it is not:

    expect.sqlstate(err, "42501", NAME)   -> read "42501" as the name
    expect.text(got, "none", NAME)        -> read "none"

Every SQLSTATE assertion was therefore read as the literal `42501`, reported as an "extra"
name the bash suite does not have, while the real property was reported MISSING. #432's
ports are precisely the ones replacing a grep on an error message with a SQLSTATE
assertion, so the tool went blind in proportion to the work being done well. Measured over
the seven pairs in the tree: **61 bash properties reported missing, of which 34 were not
missing at all.** Two whole pairs flipped from `PORT IS INCOMPLETE` to complete.

WHY A GUARD AND NOT JUST A FIX. Nothing could see this. The tool's own output was the only
evidence either way, and its verdict for a correct port was a plausible-looking list of
names that really were absent from the port -- absent because the tool had matched a
different string, which is not visible from the list. `test_hilbert_locality.py` records
somebody working around it by rewriting their test file until the count fell, and
concluding the rest needed a change to this tool. It did.

THE ARMS BELOW DRIVE THE REAL EXTRACTORS, never a copy. A python twin of a python rule
would agree with itself.
"""

import ast
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from compare_to_bash import _as_names, _parametrized_names, _py_names, _template  # noqa: E402


def _names(src):
    return _py_names(src)


def test_the_name_is_the_last_argument_not_the_first_string(expect):
    """THE REGRESSION. Three helpers, one of which always worked.

    `expect.num` is the control: its want is a number, so the old regex happened to reach
    the name and the tool looked correct. Without that arm this test would pass over a
    rule that returns the last argument of nothing at all.
    """
    src = (
        'def t(expect):\n'
        '    expect.sqlstate(err, "42501", "a role with no privilege is refused")\n'
        '    expect.text(got, "none", "no key is stated twice")\n'
        '    expect.num(got, 1, "the owner reads its own table")\n'
    )
    got = _names(src)
    expect.text(", ".join(sorted(got)),
                "a role with no privilege is refused, no key is stated twice, "
                "the owner reads its own table",
                "each helper contributes its NAME and not its want")
    expect.num(len(got), 3, "three assertions, three names")
    expect.num(sum(1 for n in got if n in ("42501", "none")), 0,
               "and no want is mistaken for a name, which is the defect this closes")


def test_a_call_whose_name_is_not_a_literal_contributes_nothing(expect):
    """Better absent than wrong.

    A name the tool cannot read must be reported MISSING, which a person then fixes.
    Guessing at it reports the wrong string as PRESENT, and a false green on a parity tool
    is how a property ends up asserted in neither harness.
    """
    src = 'def t(expect):\n    expect.sqlstate(err, "42501", some_variable)\n'
    expect.num(len(_names(src)), 0,
               "an unreadable name yields nothing rather than the want beside it")


def test_an_fstring_name_becomes_a_template(expect):
    """Both harnesses build some names at runtime. The shape is what can be compared."""
    src = 'def t(expect):\n    expect.num(got, 1, f"premise: {r} can open a session")\n'
    expect.text(_names(src)[0], "premise: {} can open a session",
                "the interpolated part is reduced to a placeholder")


def test_a_conditional_name_carries_both_of_its_arms(expect):
    """`"a" if cond else "b"` asserts two properties depending on the arm taken.

    Reading one of them reports the other MISSING, which is the same false red as reading
    the wrong argument, one level in.
    """
    src = ('def t(expect):\n'
           '    expect.num(got, 1, "the owner reads" if f == "read" else "the owner writes")\n')
    expect.text(", ".join(sorted(_names(src))), "the owner reads, the owner writes",
                "both arms of a conditional name are collected")


def test_a_parametrized_name_is_resolved_from_the_decorator(expect):
    """The idiom a repeated bash property should be ported to.

    When the bash suite states the same property once per function, the port writes the arm
    once and parametrises it, carrying the bash name as a parameter. If the tool cannot see
    those names it reports every one of them MISSING, which pushes a port away from the one
    idiom that keeps the two harnesses one-to-one.

    The control is the second decorator: a parametrize with no `name` column must
    contribute nothing, or the tool would harvest every parameter in the file as an
    assertion name and report a pile of extras.
    """
    src = (
        'USAGE_ONLY = (\n'
        '    ("read_projection", "a role with only schema USAGE is refused"),\n'
        '    ("reconstruct_via_projection", "and is refused reconstruct"),\n'
        ')\n'
        '@pytest.mark.parametrize("func,name", USAGE_ONLY)\n'
        'def t(expect, func, name):\n'
        '    expect.sqlstate(err, "42501", name)\n'
        '@pytest.mark.parametrize("func", ["read_projection", "reconstruct"])\n'
        'def u(expect, func):\n'
        '    expect.num(got, 1, "an unrelated property")\n'
    )
    got = _names(src)
    expect.num(int("a role with only schema USAGE is refused" in got), 1,
               "a parametrized name is resolved through the module-level constant")
    expect.num(int("and is refused reconstruct" in got), 1, "for every row of it")
    expect.num(int("read_projection" in got), 0,
               "while the OTHER column of the same decorator is not a name")
    expect.num(int("reconstruct" in got), 0,
               "and a parametrize with no name column contributes nothing")


def test_the_parametrize_reader_takes_the_column_called_name(expect):
    """Position is not the rule; the declared column is.

    A port that writes `parametrize("name,func", ...)` states the same properties, and a
    reader keyed on position silently harvests the function names instead.
    """
    tree = ast.parse(
        'ROWS = (("the property", "read_projection"),)\n'
        '@pytest.mark.parametrize("name,func", ROWS)\n'
        'def t(name, func):\n    pass\n'
    )
    expect.text(", ".join(_parametrized_names(tree)), "the property",
                "the name column is found by its declared name, whatever its position")


def test_the_two_harnesses_interpolations_land_on_one_template(expect):
    """What makes a template match mean anything: bash and python spell it differently."""
    expect.text(_template("non-owner refused: ${1%%(*}"), "non-owner refused: {}",
                "a bash parameter expansion is reduced to a placeholder")
    expect.text(_template("non-owner refused: {}"), "non-owner refused: {}",
                "and an f-string template is already in that form, so the two meet")
    expect.text(_template("premise: $PGC_PORT is open"), "premise: {} is open",
                "a bare variable reference too")


def test_refusal_names_its_second_argument_not_its_last_pattern(expect):
    """`refusal(result, name, *patterns)` puts the name in the MIDDLE.

    The last argument is a pattern -- a fragment of the message the refusal must carry --
    so the last-argument rule read a substring of an error message as the property's name.
    The real name went MISSING and the pattern arrived as an EXTRA: two false entries from
    one call, which is the same defect this file exists to close, one helper along.
    """
    src = ('def t(expect):\n'
           '    expect.refusal(result, "a role with no privilege is refused",\n'
           '                   "permission denied", "for table")\n')
    got = _names(src)
    expect.text(", ".join(sorted(got)), "a role with no privilege is refused",
                "the name is read and neither pattern is")
    expect.num(len(got), 1, "one call contributes exactly one name")


def test_refusal_with_no_pattern_is_not_the_arm_that_proves_it(expect):
    """THE CONTROL that keeps the arm above honest.

    `expect.refusal(result, NAME)` has the name last, so it is read correctly by the rule
    this change replaces AND by the rule that replaces it. An arm built only on that shape
    would pass against the defect, which is how the shape got missed in the first place.
    """
    src = 'def t(expect):\n    expect.refusal(result, "the write is refused")\n'
    expect.text(", ".join(_names(src)), "the write is refused",
                "the no-pattern shape reads the same either way, so it proves nothing alone")


def test_cannot_run_names_its_reason_not_its_detail(expect):
    """`cannot_run(reason, detail="")` records `name=reason`: the FIRST argument.

    It is the only helper whose name is argument zero, and the detail beside it is prose
    about one run -- "the two partitions are not different ({})" -- which can never match
    a bash check name. Reading it produced an extra that no bash suite could ever satisfy.
    """
    src = ('def t(expect):\n'
           '    expect.cannot_run("MISSING_DEPENDENCY",\n'
           '                      "the two partitions are not different")\n')
    got = _names(src)
    expect.text(", ".join(got), "MISSING_DEPENDENCY",
                "the reason CODE is the name, and the detail is not a name at all")
    expect.num(len(got), 1, "the detail contributes nothing")


def test_a_helper_whose_name_is_optional_takes_it_only_from_the_keyword(expect):
    """`plan_marker` and `plan_node` carry no name positionally. Better absent than wrong.

    `plan_marker(plan, key, name=None)` records `name or f"plan carries {key!r}"`, so the
    KEY is not the name even when no name is given -- it is a fragment of one. The
    last-argument rule emitted the bare key as a name the bash suite does not have, and
    `Columnar Projected Columns` duly appeared as an extra on a pair that is complete.

    With no name= the call contributes NOTHING, which reports MISSING rather than inventing
    a name: the rule this file already applies to a name it cannot read.
    """
    named = _names('def t(expect):\n'
                   '    expect.plan_marker(plan, "Columnar Projected Columns",\n'
                   '                       name="the plan projects two columns")\n')
    expect.text(", ".join(named), "the plan projects two columns",
                "the name= keyword is the name, and the key is not also collected")
    expect.num(len(named), 1, "one call, one name -- the key is not a second entry")

    bare = _names('def t(expect):\n'
                  '    expect.plan_marker(plan, "Columnar Projected Columns")\n')
    expect.num(len(bare), 0, "with no name= the key is still not a name")

    node = _names('def t(expect):\n'
                  '    expect.plan_node(plan, provider="columnar",\n'
                  '                     name="the scan is columnar")\n')
    expect.text(", ".join(node), "the scan is columnar",
                "plan_node reads its name= and not the arguments describing the node")


def test_the_tools_table_agrees_with_the_signatures_it_describes(expect):
    """THE DRIFT GUARD, and the reason the table is allowed to be a hand-written map.

    `compare_to_bash.py` is deliberately standalone -- `ast`, `re`, `sys` -- so it cannot
    import `Expect` to ask where each name sits, and a hand-written table is a derived
    value that goes stale the day somebody adds a helper. This arm is what stops that: it
    reads the REAL signatures out of `pgc_vacuity.py` and recomputes, for every public
    helper, which call argument carries the name the helper records.

    It is not a copy of the table. The table says where to look; this derives where to look
    from the source of truth and compares. A helper added with its name anywhere but last,
    or a signature reordered, fails here with the helper named.
    """
    from compare_to_bash import _NAME_ARG

    # The ONE thing a signature cannot state: which parameter becomes the record's name.
    # `cannot_run` records `name=reason`; every other helper calls its parameter `name`.
    # Pinned below against the body, so this line cannot quietly become wrong either.
    records_name_as = {"cannot_run": "reason"}

    src = (HERE / "pgc_vacuity.py").read_text()
    tree = ast.parse(src)
    klass = [n for n in ast.walk(tree)
             if isinstance(n, ast.ClassDef) and n.name == "Expect"]
    expect.num(len(klass), 1, "premise: exactly one Expect class to read")

    helpers = [f for f in klass[0].body
               if isinstance(f, ast.FunctionDef) and not f.name.startswith("_")]
    # `records` and `count` take no arguments and record no name.
    helpers = [f for f in helpers if [a.arg for a in f.args.args if a.arg != "self"]]
    expect.at_least(len(helpers), 15,
                    "premise: the Expect helpers were found, not an empty list")

    disagree, checked = [], 0
    for f in helpers:
        params = [a.arg for a in f.args.args if a.arg != "self"]
        ndef = len(f.args.defaults)
        required = params[:len(params) - ndef] if ndef else params
        param = records_name_as.get(f.name, "name")
        # Optional => no positional carries it; only a `name=` keyword can.
        want = required.index(param) if param in required else None
        got = _NAME_ARG.get(f.name, -1)
        # -1 is "the last positional". That equals the name's own index only when the
        # name really is last AT THE CALL SITE, and a `*args` AFTER it means it is not:
        # `refusal(result, name, *patterns)` declares `name` last and is still called
        # with patterns beyond it. Without that clause this arm accepted a missing
        # `refusal` entry, which is the very shape it is here to catch.
        if (got == -1 and want is not None and want == len(required) - 1
                and f.args.vararg is None):
            got = want
        checked += 1
        if got != want:
            disagree.append(f"{f.name}: table says {got!r}, signature says {want!r}")

    expect.num(checked, len(helpers), "inputs == sum(buckets): every helper was compared")
    expect.text("; ".join(disagree) or "none", "none",
                "every entry in the table matches the signature it describes")

    # The one hand-written semantic claim above, pinned against the body it describes:
    # read cannot_run's own `_record(...)` call and check which parameter it names.
    #
    fn = [f for f in helpers if f.name == "cannot_run"]
    expect.num(len(fn), 1, "premise: cannot_run is among the helpers read")
    recorded = [kw.value.id for call in ast.walk(fn[0])
                if isinstance(call, ast.Call)
                and isinstance(call.func, ast.Attribute) and call.func.attr == "_record"
                for kw in call.keywords
                if kw.arg == "name" and isinstance(kw.value, ast.Name)]
    expect.text(", ".join(recorded), "reason",
                "cannot_run really does record its reason as the name")

def test_no_later_argument_can_overtake_the_name(expect):
    """`-1` is a claim about the CALL SITE, and the arm above only reads the SIGNATURE.

    Found by @OffgridwithJD reviewing the change this file documents, inside the very
    clause that fixed the vararg coincidence. The guard asks "which parameter carries the
    name", which is a fact about the declaration. `-1` says "the last argument", which is
    a fact about the call. They agree only while no OPTIONAL parameter sits after the
    name, because an optional one may still be passed POSITIONALLY:

        expect.rows(got, want, "THE NAME", "the reason")   -> read 'the reason'
        expect.plan_marker(plan, "key", "THE NAME")        -> read nothing at all

    Both were legal, both read wrong, and every guard in this file stayed green. The
    second is the worse one: a DROPPED name reports the bash property MISSING, and
    MISSING is what drives `rc`.

    Latent rather than live -- no call site in the tree passes a trailing optional
    positionally -- but #1037 makes `allow_empty` a reason STRING, which is exactly the
    argument somebody writes positionally next to a name.

    So the property is closed in the SIGNATURES rather than patched in the reader: every
    parameter after the name is keyword-only, and this arm holds that. A wrong call is
    then a `TypeError`, not a silently misread name.
    """
    src = (HERE / "pgc_vacuity.py").read_text()
    klass = [n for n in ast.walk(ast.parse(src))
             if isinstance(n, ast.ClassDef) and n.name == "Expect"]
    expect.num(len(klass), 1, "premise: exactly one Expect class to read")
    helpers = [f for f in klass[0].body
               if isinstance(f, ast.FunctionDef) and not f.name.startswith("_")
               and [a.arg for a in f.args.args if a.arg != "self"]]
    expect.at_least(len(helpers), 15, "premise: the helpers were found, not an empty list")

    from compare_to_bash import _NAME_ARG

    overtakable, checked = [], 0
    for f in helpers:
        params = [a.arg for a in f.args.args if a.arg != "self"]
        checked += 1
        if "name" not in params:
            # Carried only as a keyword, or named something else (`cannot_run`, whose
            # name is argument 0 and cannot be overtaken by anything after it).
            continue
        if _NAME_ARG.get(f.name, -1) is None:
            # The table says NO positional argument carries the name, so the reader
            # skips the call entirely. If `name` can still be written positionally the
            # name is DROPPED, which reports the bash property MISSING and moves `rc`.
            overtakable.append(f"{f.name}: the table reads no positional name, yet name "
                               f"can be passed positionally")
            continue
        after = params[params.index("name") + 1:]
        if after:
            overtakable.append(f"{f.name}: {', '.join(after)} can be passed positionally "
                               f"after name")

    expect.num(checked, len(helpers), "inputs == sum(buckets): every helper was examined")
    expect.text("; ".join(overtakable) or "none", "none",
                "no positional argument can be written after the name and be read as it")


def test_the_extractor_reads_every_check_helper_lib_sh_defines(expect):
    """THE BASH-SIDE DRIFT GUARD (#1040), and the mirror of the table guard above.

    The extractor read five of the eight check helpers `lib.sh` defines. The other
    three -- `check_unrunnable`, `check_skip`, `check_ratio_needs_quiet_machine` --
    matched no branch of its pattern, so a bash property asserted through any of
    them was invisible, was never reported MISSING, and could not move `rc`.

    **A pair could therefore be declared one-for-one on the strength of the grader's
    blind spot**, which is what `hilbert_locality` was: two of the four properties
    its unrunnable branch records had no counterpart in the port at all.

    The helper list is hand-written, for the same reason `_NAME_ARG` is: the tool
    stays standalone. So it is pinned the same way -- this reads the DEFINITIONS out
    of `lib.sh` and fails with the helper named when the two part company. Add a
    `check_whatever()` to `lib.sh` and this goes red before a suite using it is
    silently ungraded.

    Suite-LOCAL helpers are deliberately not in scope here; that is asserted, with
    its reason, in the arm below.
    """
    from compare_to_bash import _BASH_HELPERS

    lib = (HERE.parent / "lib.sh").read_text()
    # `check` or `check_<something>`. NOT `check[a-z_]*`, which also matches
    # `checks_in` -- a COUNTING utility in decode_interrupts.sh that returns a
    # number and records nothing. Define the population before counting it.
    defined = set(re.findall(r'^(check(?:_[a-z_]+)?)\(\)\s*\{', lib, re.M))
    expect.at_least(len(defined), 8,
                    "premise: lib.sh's check helpers were found, not an empty set")

    missing = sorted(defined - set(_BASH_HELPERS))
    extra = sorted(set(_BASH_HELPERS) - defined)
    expect.text(", ".join(missing) or "none", "none",
                "every check helper lib.sh defines is one the extractor reads")
    expect.text(", ".join(extra) or "none", "none",
                "and the extractor claims no helper lib.sh does not define")
    expect.num(len(_BASH_HELPERS), len(defined),
               "inputs == sum(buckets): the two lists are the same size")


def test_a_longer_helper_name_is_not_shadowed_by_a_shorter_one(expect):
    r"""`check_ratio` is a PREFIX of `check_ratio_needs_quiet_machine`.

    THE PRE-#1040 PATTERN COULD NOT READ THE LONGER ONE AT ALL, and that is what this
    holds. `check(?:_num|_ratio|_text|_timing)?\s+"` matches `check_ratio`, wants
    whitespace, finds `_needs...`, backtracks to the empty option, wants whitespace
    after `check`, and fails. Measured on the fixture below: the old form reads
    `['short']`, the current one reads `['short', 'long']`.

    WHAT THIS ARM DOES NOT HOLD, said out loud because the code reads as though it
    does: the entries are listed longest-first, and that ordering is NOT load-bearing.
    Python's `re` backtracks across alternatives, so a PURE REORDER putting
    `check_ratio` first reads both names identically -- measured, and this arm stays
    green under it. The order is the thing that looks decisive and is not; the pattern
    SHAPE is the thing that is.
    """
    import re as _re
    from compare_to_bash import _BASH_PATTERN
    src = ('\tcheck_ratio "the short one" "$a" "$b" 2\n'
           '\tcheck_ratio_needs_quiet_machine "the long one" "$a" "$b" 2\n')
    got = _re.findall(_BASH_PATTERN, src)
    expect.text(", ".join(sorted(got)), "the long one, the short one",
                "both are read; the longer name is not eaten by the shorter")


def test_the_suite_local_helpers_are_known_and_excluded(expect):
    """Four helpers are defined by ONE suite each, and the extractor does not read
    them. That is a scope decision and it is asserted rather than left implicit.

    `compare_to_bash.py` grades a `test/<stem>.sh` against a
    `test/pytest/test_<stem>.py`. None of the four suites defining its own helper
    has a pytest twin, so none is graded and the exclusion costs nothing TODAY.
    The day one of them is ported, this arm is what says the grader cannot see it.

    The population is `check_<something>`, which is not the same as "starts with
    check": `checks_in` in `decode_interrupts.sh` is a COUNTING utility returning a
    number of interrupt checks in a function body, and records nothing. It was in
    this list until the arm printed it and the definition was read.
    """
    root = HERE.parent
    local = {}
    for sh in sorted(root.glob("*.sh")):
        if sh.name == "lib.sh":
            continue
        for h in re.findall(r'^(check_[a-z_]+)\(\)\s*\{', sh.read_text(), re.M):
            local.setdefault(h, sh.name)
    expect.text(", ".join(f"{h} ({f})" for h, f in sorted(local.items())),
                "check_float (parquet_export_stats.sh), "
                "check_reconstruct (parallel_copy.sh), "
                "check_split_happened (parallel_copy.sh), "
                "check_structure (parallel_copy.sh)",
                "the suite-local helpers are exactly these four")
    twinned = [f for h, f in local.items()
               if (HERE / f"test_{f[:-3]}.py").exists()]
    expect.num(len(twinned), 0,
               "and none of their suites has a pytest twin, so none is graded today")


def test_the_ported_suites_in_this_tree_are_graded_one_for_one(expect):
    """THE STANDING ARM, and the reason this file is not only about fixtures.

    A guard over invented sources proves the extractor reads python. It cannot prove the
    tool grades THIS tree, which is the claim #432 rests on. So the pairs that are declared
    complete are asserted complete here, and a later edit that breaks parity fails with the
    pair named rather than the whole gate going red for an unrelated reason.

    Only the pairs that reach zero today are listed. A pair with a real gap is not pinned to
    its gap: that would turn the gap into the expected state.

    THE LIST IS HAND-WRITTEN FOR THAT REASON AND NOTHING ENFORCES IT, which is a
    different thing from the reason being wrong. The comment below already says a new
    port belongs here; no arm reddens when one does not arrive. Today the list happens
    to equal the pairs that exist, so nothing has ever been silently ungraded -- but an
    eighth complete pair omitted would leave this arm passing while it graded seven,
    which is absent-from-the-list and no-gap-found producing the same green.

    #1046 TRACKS MAKING THIS ASSERTION TWO-DIRECTIONAL, in the shape `SHELL_REFERENCES`
    already uses: derive the pairs that EXIST and require the declared list to equal that
    set. It is not a tidy-up -- it changes what happens to an INCOMPLETE port, which is
    quietly absent today and would have to redden, so the issue records the design
    question rather than settling it. Kept out of the PR that added the eighth pair.
    """
    from compare_to_bash import main
    import contextlib
    import io

    root = HERE.parent.parent
    # EVERY pair in the tree. When a new port lands it belongs here, and when one
    # cannot reach zero the reason belongs in its own file rather than in an omission
    # from this list.
    complete = ["differential", "hilbert_cluster", "hilbert_locality",
                "native_ownership", "native_projection", "projection_privilege",
                "stats_privilege", "zonemap_boundaries"]
    verdicts = {}
    for stem in complete:
        sh, py = root / "test" / f"{stem}.sh", HERE / f"test_{stem}.py"
        expect.num(int(sh.exists() and py.exists()), 1, f"premise: both halves of {stem} exist")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = main(str(sh), str(py))
        verdicts[stem] = rc
    expect.text(", ".join(f"{k}={v}" for k, v in sorted(verdicts.items())),
                ", ".join(f"{k}=0" for k in sorted(complete)),
                "every pair declared one-for-one still grades one-for-one")
