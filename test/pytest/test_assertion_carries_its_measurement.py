"""An assertion that collapses a measurement to a constant cannot say what failed.

    expect.num(1 if abs(on - off) <= 5 else 0, 1, "...")   ->   got 0 want 1

Four measured buffer counts, reduced to a boolean BEFORE the assert. The failure
message carries none of them, so a red says only that the arm failed -- which the
word FAILED already said.

WHAT IT COST, MEASURED RATHER THAN IMAGINED (#1164). A PG 15 leg reddened
`test_a_query_that_cannot_use_the_order_does_not_pay_to_decide`, and two sessions
spent an afternoon unable to say whether the ORACLE (`|on - off| <= 5`, a six-buffer
spurious gap) or the CONTROL (`order_on > order_off + 5`, a fourteen-buffer collapse)
had failed. Those are different defects with different owners -- one of them a
planning-buffer question and the other a timing question -- and the run could not tell
them apart. Four further experiments were then aimed at a target whose identity was
unknown.

TWO BUGS, ONE SYMPTOM, and the second is the one this file is about. The runner also
captured each leg into a shell variable and grepped it for summary lines, so the full
output never reached disk. That was repaired separately. **Repairing it alone would
still have left `got 0 want 1`**, because the measurement was discarded before the
message was built. A complete log of an empty sentence is still empty.

THE RULE, and it is narrower than "do not use a conditional expression".

An `IfExp` first argument is refused when BOTH of these hold:

  (a) the failing set has MORE THAN ONE MEMBER, so the boolean does not determine
      which state was reached; AND
  (b) NEITHER BRANCH carries the value, so the message cannot recover it.

`is None`, `is not None`, `in`, `==` and `!=` are determinate: knowing the boolean
already names the failing state. So is a nothing-versus-something comparison -- `x > 0`,
`n >= 1` -- because exactly one value fails, and `got 'no' want 'yes'` fixes it.

**Nothing-versus-something is determinate WHATEVER THE LEFT SIDE LOOKS LIKE.** That
was learned the expensive way: an earlier draft keyed on the left operand being a bare
`Name`, which flagged `(st['ret'] or 0) > 0` and `st['anylog'] >= 1`. The `or 0` is a
None-guard and the subscript is a lookup; neither is a measurement, and refusing them
was syntax standing in for semantics.

THE ONE EXCEPTION, which is why the carve-out cannot be "the comparator is 0 or 1":

    'yes' if min(t_proj_run, l_proj_run, t_base_run, l_base_run) > 0 else 'no'

The comparator IS 0, and the boolean still hides WHICH of four measurements went
non-positive. An aggregate over several operands is a measurement however it is
compared, so it stays in scope.

A TEST MAY BE A BOOLEAN COMBINATION, and both reviewers' first implementations got
this right or wrong by accident rather than by design. One bailed on anything that was
not a `Compare`, and silently scored `rng > 1000000000 and spread < 100000` as
determinate. The other walked the whole tree for comparisons, which reached inside
`BoolOp` for the wrong reason. It is stated here as a rule: every operand of a boolean
combination is examined, and one lossy operand is enough.

WHY THIS AND NOT A PARITY CHECK. `compare_to_bash` grades the check NAME. Two arms
grade `missing: 0` while one prints its measurement and the other prints `got 0 want 1`,
and nothing in the harness can see the difference -- which is how two of the four pairs
repaired under #1164 turned out to be PORT REGRESSIONS, where the shell original had
carried its numbers all along and the port dropped them. Name parity does not preserve
diagnostics, and no comparison of two independent implementations ever will. This
refuses the shape directly instead.

THE POPULATION, measured over the corpus before this was written rather than after:

    expect.*(<IfExp>, ...)                  190
      + both branches constant              148
        + a LOSSY test                       26   <- refused

The 26 were repaired under #1164, so this arm reaches zero on arrival. That is the
point rather than a weakness: the property is true today and nothing was holding it
there. `test_a_lossy_arm_is_caught` is what says the sweep can still see one.

THE SHELL CORPUS IS A DIFFERENT NUMBER AND ITS GUARD IS SHAPED DIFFERENTLY. It holds
55 such sites across 36 files, so its twin --
`test/selftest/540-an-arm-must-carry-its-measurement.sh` -- asserts a tracked list that
may only shrink, not zero. The asymmetry is deliberate: the two corpora are in
different states, and a guard that asserted zero over both would be claiming a property
this tree does not have.
"""

import ast
import pathlib

HERE = pathlib.Path(__file__).resolve().parent

# Comparisons whose failing state the boolean already names.
DETERMINATE_OPS = (ast.Is, ast.IsNot, ast.In, ast.NotIn, ast.Eq, ast.NotEq)
ORDERING_OPS = (ast.Lt, ast.LtE, ast.Gt, ast.GtE)


def _counted(node):
    """An `expect.<assertion>(...)` call. `cannot_run` declares a test unrunnable
    rather than concluding anything, so it is not an assertion to police."""
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "expect"
            and node.func.attr != "cannot_run")


def _aggregates(node):
    """`min(a, b, c)` and friends: one number standing for several measurements.

    The boolean hides WHICH operand failed, so these stay in scope even when the
    comparator is 0 -- which is the case a comparator-only carve-out gets wrong.
    """
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
            and node.func.id in {"min", "max", "sum"} and len(node.args) > 1)


def _comparison_is_lossy(test):
    """True when the boolean discards an operand the reader would need."""
    if not (isinstance(test, ast.Compare) and len(test.ops) == 1):
        return False
    op, lhs, rhs = test.ops[0], test.left, test.comparators[0]
    if isinstance(op, DETERMINATE_OPS):
        return False
    if not isinstance(op, ORDERING_OPS):
        return False
    # Nothing versus something: exactly one value fails, so the boolean fixes it.
    # Keyed on the COMPARATOR, never on the shape of the left side.
    if isinstance(rhs, ast.Constant) and rhs.value in (0, 1):
        return _aggregates(lhs)
    return True


def _is_lossy(test):
    """A test is lossy if it is a lossy comparison, or a boolean combination
    holding one. Every operand is examined; one is enough."""
    if isinstance(test, ast.BoolOp):
        return any(_is_lossy(v) for v in test.values)
    return _comparison_is_lossy(test)


def _branch_carries(node):
    """A branch that is not a bare constant carries the value into the message.

    An f-string does; a descriptive word like `'halved'` does not. Descriptive is
    not the same as carrying: `got 'halved' want 'io-kept'` tells the reader the
    verdict they already had from the word FAILED, and not the ratio behind it.
    """
    return not isinstance(node, ast.Constant)


def collapsing_arms(directory):
    """-> ["file:line  <test source>", ...] for every arm that discards its measurement."""
    out = []
    for path in sorted(pathlib.Path(directory).glob("test_*.py")):
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"))
        except SyntaxError:
            continue
        for call in [n for n in ast.walk(tree) if _counted(n)]:
            if not call.args or not isinstance(call.args[0], ast.IfExp):
                continue
            arg = call.args[0]
            if _branch_carries(arg.body) or _branch_carries(arg.orelse):
                continue
            if _is_lossy(arg.test):
                out.append(f"{path.name}:{call.lineno}  {ast.unparse(arg.test)[:60]}")
    return out


def test_no_arm_collapses_its_measurement_to_a_constant(expect):
    """The corpus itself. Green on arrival, and that is the point."""
    offenders = collapsing_arms(HERE)
    expect.text(", ".join(offenders) or "none", "none",
                "no assertion discards its measurement before comparing")


def test_the_sweep_finds_the_arms_it_is_meant_to_classify(expect):
    """The coverage premise this file's own sweep needs.

    A sweep that parses nothing reports no offenders, which is exactly what a clean
    corpus reports. So count what it CLASSIFIED, not only what it rejected -- the
    same shape `test_loop_coverage_premise` needs for the same reason.
    """
    seen = 0
    for path in sorted(HERE.glob("test_*.py")):
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"))
        except SyntaxError:
            continue
        for call in [n for n in ast.walk(tree) if _counted(n)]:
            if call.args and isinstance(call.args[0], ast.IfExp):
                seen += 1
    expect.at_least(seen, 100,
                    "premise: the sweep found conditional arms to classify")


def _fixture(tmp_path, body):
    d = tmp_path / "corpus"
    d.mkdir(exist_ok=True)
    (d / "test_probe.py").write_text(body)
    return d


def test_a_lossy_arm_is_caught(tmp_path, expect):
    """The removal proof, with its control beside it.

    The fixture is the real shape with one property removed, rather than an empty
    file: an empty file is caught by a sweep that does nothing at all.
    """
    lossy = _fixture(tmp_path, "def test_x(expect):\n"
                               "    expect.num(1 if abs(on - off) <= 5 else 0, 1, 'n')\n")
    expect.num(len(collapsing_arms(lossy)), 1,
               "a tolerance collapsed to a boolean is caught")

    carried = _fixture(tmp_path, "def test_x(expect):\n"
                                 "    expect.text(f'differs by {d}' if d > 5 else 'within 5',\n"
                                 "                'within 5', 'n')\n")
    expect.num(len(collapsing_arms(carried)), 0,
               "control: an arm whose branch carries the value is not caught")


def test_a_determinate_arm_is_not_caught(tmp_path, expect):
    """The carve-out, driven rather than described.

    Each of these has exactly one failing state, so the boolean already names it.
    Without this the rule would refuse most of the corpus and be switched off.
    """
    for src, why in (
        ("1 if rows > 0 else 0", "nothing versus something"),
        ("1 if n >= 1 else 0", "the same, spelled with a floor"),
        ("1 if (st['ret'] or 0) > 0 else 0", "a None-guard is not a measurement"),
        ("1 if st['anylog'] >= 1 else 0", "a subscript is a lookup, not a measurement"),
        ("1 if exc is not None else 0", "identity"),
        ("1 if 'wrote' in buckets else 0", "membership"),
    ):
        d = _fixture(tmp_path, f"def test_x(expect):\n    expect.num({src}, 1, 'n')\n")
        expect.num(len(collapsing_arms(d)), 0, f"determinate, so not caught: {why}")


def test_an_aggregate_over_several_operands_stays_in_scope(tmp_path, expect):
    """The exception that stops the carve-out being 'the comparator is 0 or 1'.

    `min(a, b, c, d) > 0` compares against 0 and still hides which of four
    measurements went non-positive.
    """
    d = _fixture(tmp_path, "def test_x(expect):\n"
                           "    expect.text('yes' if min(a, b, c, d) > 0 else 'no', 'yes', 'n')\n")
    expect.num(len(collapsing_arms(d)), 1,
               "an aggregate over several operands is lossy even against 0")

    single = _fixture(tmp_path, "def test_x(expect):\n"
                                "    expect.text('yes' if min(a) > 0 else 'no', 'yes', 'n')\n")
    expect.num(len(collapsing_arms(single)), 0,
               "control: a one-operand min hides nothing, so it is determinate")


def test_a_boolean_combination_is_examined_operand_by_operand(tmp_path, expect):
    """One lossy operand is enough, and a determinate one does not excuse it.

    Both reviewers' first implementations got this right or wrong by accident: one
    bailed on anything that was not a `Compare`, the other reached inside `BoolOp`
    while looking for something else.
    """
    mixed = _fixture(tmp_path, "def test_x(expect):\n"
                               "    expect.num(1 if req is not None and req >= 2 else 0, 1, 'n')\n")
    expect.num(len(collapsing_arms(mixed)), 1,
               "a determinate operand does not excuse a lossy one beside it")

    both_ok = _fixture(tmp_path, "def test_x(expect):\n"
                                 "    expect.num(1 if a is not None and b > 0 else 0, 1, 'n')\n")
    expect.num(len(collapsing_arms(both_ok)), 0,
               "control: a combination of determinate operands is determinate")
