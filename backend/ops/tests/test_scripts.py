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

Two of them carry more than syntax, and the second half of this file reads their
content. `ops/audit/postgres_posture.sh` is the only expression in this repository of
a posture that lives in a file on a host, and `ops/backup/identity_backup.sh` decides
what a seizure of the backup directory yields — a table added to its list is a table
copied out of the retention windows the rest of the design is built on.
"""

import re
import subprocess
from pathlib import Path

import pytest
from django.apps import apps
from django.conf import settings

OPS = Path(settings.BASE_DIR) / "ops"
SCRIPTS = sorted(path.relative_to(OPS).as_posix() for path in OPS.rglob("*.sh"))

# The two the failure rule of ADR-0012 names. Listed rather than derived, so a
# rename that drops one from the tree fails here rather than passing over an empty
# glob.
REQUIRED = ("audit/offline_rehearsal.sh", "offline_install.sh")

POSTURE = OPS / "audit" / "postgres_posture.sh"
BACKUP = OPS / "backup" / "identity_backup.sh"
PG_NOTES = OPS / "postgres" / "README.md"

# The eight tables a restore of identity needs. `user_id` is inside every signed
# device bundle, so a lost database is a new identity and a fresh verification with
# every contact for every account — that, and nothing else, is what the backup exists
# for.
BACKED_UP = {
    "accounts_user",
    "accounts_profileblob",
    "devices_useridentity",
    "devices_device",
    "devices_onetimeprekey",
    "devices_pqonetimeprekey",
    "devices_devicelogrecord",
    "vault_keybackup",
}

# The tables of this project that the backup deliberately does not copy, each because
# a copy of it outlives the retention window that bounds the original.
# `test_the_backup_decides_about_every_table_this_project_owns` is what makes a new
# model land in one set or the other rather than in neither.
NOT_BACKED_UP = {"messaging_queuedenvelope", "attachments_attachment"}

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


def test_the_backup_dumps_exactly_the_identity_tables():
    """The list, and the one place it is written. A table added here is a table
    copied into a directory the retention sweep does not reach and kept for seven
    days past every window the design states."""
    listed = bash_array(BACKUP.read_text(), "TABLES")

    assert set(listed) == BACKED_UP
    assert len(listed) == len(BACKED_UP), listed


def test_the_backup_dumps_no_table_it_does_not_list():
    """The array is the whole of the selection: one `--table=`, inside the loop that
    reads it. A second one written beside `pg_dump` would carry a table past the
    assertion above, which reads the array alone."""
    source = BACKUP.read_text()

    assert source.count("--table=") == 1
    assert 'selection+=(--table="$table")' in source
    for table in NOT_BACKED_UP:
        assert f"--table={table}" not in source


def test_the_backup_decides_about_every_table_this_project_owns():
    """Neither set is a guess about the schema: together they are every table this
    project declares a model for, so a model added in a later phase fails here until
    somebody decides which side it belongs on."""
    owned = {
        model._meta.db_table
        for model in apps.get_models()
        if not model._meta.app_config.name.startswith(("django.", "unfold"))
    }

    assert BACKED_UP | NOT_BACKED_UP == owned
    assert BACKED_UP & NOT_BACKED_UP == set()


def test_the_backup_is_encrypted_to_a_key_this_host_cannot_read():
    """The dump is piped into `age` and never staged: with `pipefail` a failed
    `pg_dump` fails the run, and the plaintext never touches the disk of the host it
    is being protected from. The recipient is the public half of a key whose private
    half is generated and kept off this machine."""
    source = BACKUP.read_text()

    assert "| age --encrypt --recipients-file" in source
    assert "RECIPIENT=/etc/chat/backup.pub" in source
    assert "umask 077" in source


def test_the_backup_keeps_seven():
    """Seven days of the newest identity state. The rotation reads the ISO date in
    the name rather than an mtime, so a file that was copied or touched does not
    reorder the set."""
    source = BACKUP.read_text()

    assert re.search(r"^KEEP=7$", source, re.M) is not None
    assert 'tail -n "+$((KEEP + 1))"' in source


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
