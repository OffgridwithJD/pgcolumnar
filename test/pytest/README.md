# Running the pytest harness

This is the issue #432 pilot. It runs beside `test/*.sh`, and replaces nothing.

- `TESTS.md` in this directory documents every test and every assertion helper.
- `VACUITY_MODES.md` is the inventory of ways a pytest harness can report a false
  pass: 79 modes produced by the enumeration, 72 of them named in that
  file, 73 demonstrated by a run, and 28 refused by this layer today.
  VACUITY_MODES.md section 1a gives the counting rule and reconciles the
  run's totals against what is actually written down.
- `design/ISSUE_432_PYTEST_HARNESS.md` holds the design and the measurements
  behind each guard.

## Prerequisites

The interpreter is marked `EXTERNALLY-MANAGED`, so install into a virtual
environment rather than into system Python:

```sh
apt-get install -y python3.14-venv        # ensurepip is not in the base image
python3 -m venv /root/pyenv
/root/pyenv/bin/pip install -r test/pytest/requirements-test.txt
```

## Running it

```sh
cd test/pytest
PYTHONPATH=. /root/pyenv/bin/pytest                      # serial
PYTHONPATH=. /root/pyenv/bin/pytest -n 4                 # four workers
PYTHONPATH=. /root/pyenv/bin/pytest --pgc-expect-tests 24 # assert the run's shape
PGC_PG_CONFIG=/usr/local/pg19a/bin/pg_config PYTHONPATH=. /root/pyenv/bin/pytest
```

Each worker builds its own throwaway cluster on a port derived from its worker id,
and drops it at session end. Nothing survives a run.

## Checking a port against its bash original

```sh
/root/pyenv/bin/python test/pytest/compare_to_bash.py \
    test/native_projection.sh test/pytest/test_native_projection.py
```

It compares the two by assertion NAME and exits non-zero if the bash suite asserts
a property the port does not. A port keeps this working by passing each assertion
the same name string the bash check uses.

## Both halves are in the gate (#1016)

`test/run_all_versions.sh` does not run these tests and must not: the two harnesses stay
independent, and the shell runner invoking pytest is the cross-harness call the project
forbids. Registering the run in `SUITES` was the plan recorded in section 1a of the design
document, and it was the wrong mechanism for that reason. A second CI job is the right one.

`ci.yml` runs two:

- **`pytest-guards`** runs the files `NO_CLUSTER` names, in a venv where psycopg is
  deliberately ABSENT. That absence is what proves those files need no database.
- **`pytest-cluster`** runs the complement, with every pin from
  `requirements-test.txt` and a PGDG PostgreSQL 18 with its headers.

Both pass `--pgc-expect-tests` from `expected_tests.txt`, so a run that collects fewer
tests than it should fails instead of reporting a green that means nothing. **Adding a test
moves a number in that file**, and the diff sits next to the test that moved it.

## Warnings

The vacuity layer is loaded through `pytest.ini` and cannot be turned off by a test
file. A test that concludes nothing fails, a bare skip fails the run, and a
comparison that could not have failed is refused. If a guard blocks something
legitimate, the escape hatches take a reason rather than a flag, and every one of
them is listed in the design document. Adding a new escape hatch needs a red test
that proves the guard still fires without it.
