"""The operator's shell scripts parse, and the two that carry a decision hold it.

`ops/` is the half of this repository no test suite drives: the wheel cache, the
offline install and the offline rehearsal all need a machine with no network, and
the rehearsal runs the whole suite inside a venv it builds itself. What can be held
here is the property that makes the rest possible — the scripts are syntactically
valid bash, and each one arms the shell before it does anything, so a failed step
during a shutdown stops the run instead of continuing past it.

`ops/audit/offline_rehearsal.sh` is the invariant script of ADR-0012, and
`ops/offline_install.sh` is what the operator runs when the network is gone. Neither
has a second chance at that moment.

One of them carries more than syntax, and the second half of this file reads its
content. `ops/audit/postgres_posture.sh` is the only expression in this repository of
a posture that lives in a file on a host, so the notes that give the reason for each
setting and the script that checks it are held to the same list here.
"""

import re
import subprocess
from pathlib import Path

import pytest
from django.conf import settings

OPS = Path(settings.BASE_DIR) / "ops"
SCRIPTS = sorted(path.relative_to(OPS).as_posix() for path in OPS.rglob("*.sh"))

# The two the failure rule of ADR-0012 names. Listed rather than derived, so a
# rename that drops one from the tree fails here rather than passing over an empty
# glob.
REQUIRED = ("audit/offline_rehearsal.sh", "offline_install.sh")

POSTURE = OPS / "audit" / "postgres_posture.sh"
PG_NOTES = OPS / "postgres" / "README.md"

# The settings the posture names, read out of the script rather than repeated here.
# The two below are the ones that are not already a PostgreSQL default, which is what
# makes them the load-bearing pair: without them a failing statement reaches the
# server log with its bind parameters and its conflicting key values.
NOT_A_DEFAULT = {"log_min_error_statement": "panic", "log_error_verbosity": "terse"}


def bash_array(source, name):
    """The elements of a `NAME=( … )` array literal, in order."""
    body = re.search(rf"^{name}=\(\n(.*?)^\)$", source, re.M | re.S)
    assert body is not None, f"{name} is not an array literal"
    return [line.strip() for line in body.group(1).splitlines() if line.strip()]


def test_the_two_scripts_the_offline_rule_names_are_present():
    """The boundary of the sweep below: `rglob` over a tree that lost a file
    reports nothing rather than a failure."""
    assert set(REQUIRED) <= set(SCRIPTS)


@pytest.mark.parametrize("script", SCRIPTS)
def test_every_operator_script_parses(script):
    """`bash -n` reads the whole file and runs none of it, which is the only way to
    check a script whose one real run happens on a host with no network."""
    result = subprocess.run(
        ["bash", "-n", str(OPS / script)], capture_output=True, text=True
    )

    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("script", SCRIPTS)
def test_every_operator_script_arms_the_shell_before_it_acts(script):
    """`set -euo pipefail` on the first line that is not a comment.

    Without `-e` a failed `pip install` inside the offline install is followed by
    the next command and an "Offline install complete." that is not true; without
    `-o pipefail` a failure on the left of a pipe is hidden by the exit status on
    the right.
    """
    body = (OPS / script).read_text().splitlines()
    code = [line for line in body if line.strip() and not line.startswith("#")]

    assert code[0] == "set -euo pipefail"


def test_the_posture_script_checks_every_setting_the_notes_name():
    """`ops/postgres/README.md` is the reason for each setting and this script is the
    check for it, and the two are one posture in two files. A setting written into
    the notes and not into the script is a reason with no check behind it."""
    listed = bash_array(POSTURE.read_text(), "EXPECTED")
    checked = {pair.strip('"').split("=", 1)[0] for pair in listed}
    documented = set(re.findall(r"^\| `(log_\w+)` \|", PG_NOTES.read_text(), re.M))

    assert checked == documented
    assert len(listed) == len(checked), listed


def test_the_posture_script_pins_the_two_settings_that_are_not_defaults():
    """The rest of the list is stated because a default is not a decision. These two
    are the posture: at the stock values a failing statement reaches the server log
    with its bind parameters, and the DETAIL line beside it names the conflicting key
    values."""
    listed = bash_array(POSTURE.read_text(), "EXPECTED")
    values = dict(pair.strip('"').split("=", 1) for pair in listed)

    assert {name: values[name] for name in NOT_A_DEFAULT} == NOT_A_DEFAULT


def test_the_posture_script_names_every_setting_that_differs_and_then_fails():
    """It is a check and not a report: every difference is printed, so one run names
    all of them, and the exit status is non-zero afterwards. A script that exited on
    the first difference would take as many deploys to converge as there are
    settings."""
    source = POSTURE.read_text()

    assert "differing=$((differing + 1))" in source
    assert re.search(r'^\s*echo "DIFFERS: ', source, re.M) is not None
    assert re.search(r"^\s*exit 1$", source, re.M) is not None
