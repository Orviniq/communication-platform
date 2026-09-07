"""No vault endpoint logs an identifier or a payload.

The capture replaces every handler, so the configured `ScrubFilter` never runs on
what it collects. That is why `caplog` is not used here, and it is not a style
preference: the filter sets `record.msg = scrub(msg)` and clears `record.args`, it
sits on the root `StreamHandler` — handler zero — and `caplog` appends its own
behind it. A `caplog` assertion therefore reads text the scrubber has already
redacted and passes on a line the code really did leak, which grades the backstop
instead of the code. What these tests assert is that nothing is emitted in the
first place; `core/tests/test_scrub.py` covers the filter itself.
"""

import base64
import logging

import pytest

from core.buckets import BACKUP_BUCKETS
from ops.audit.log_silence import capture_all_logging

from .conftest import KEYBACKUP_URL, backup_blob

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)


def assert_absent(lines, forbidden):
    for line in lines:
        for label, secret in forbidden.items():
            assert secret not in line, f"{label} leaked into a log line: {line[:160]}"


def test_backup_paths_emit_no_identifier_or_blob(http, active_user, device, bearer):
    backup_payload = backup_blob(b"S")
    headers = bearer(active_user, device)

    with capture_all_logging() as lines:
        # A clean request logs nothing at all, so the canary is what proves the
        # capture was live rather than the assertions passing vacuously.
        logging.getLogger("test.canary").debug("canary")

        put = http.put(
            KEYBACKUP_URL,
            json={"blob": backup_payload, "version": 1},
            headers=headers,
        )
        get = http.get(KEYBACKUP_URL, headers=headers)

    assert put.status_code == 200
    assert get.status_code == 200
    assert any("canary" in line for line in lines)
    assert_absent(
        lines,
        {
            "owner id": str(active_user.id),
            "device id": str(device.id),
            "backup blob": backup_payload,
        },
    )


def test_no_vault_module_emits_a_log_record_at_all(http, active_user, device, bearer):
    """The strongest form of invariant 6 for this app: not "the identifiers are
    scrubbed" but "there is nothing to scrub", because no logger under `vault`
    ever fires. A record here would have to be reviewed line by line before it
    could ship."""
    headers = bearer(active_user, device)

    with capture_all_logging() as lines:
        logging.getLogger("test.canary").debug("canary")
        http.put(
            KEYBACKUP_URL,
            json={"blob": backup_blob(b"Q"), "version": 4},
            headers=headers,
        )
        http.get(KEYBACKUP_URL, headers=headers)

    assert any("canary" in line for line in lines)
    # `_RawCapture` writes "<LEVEL> <logger name> <message>", so the logger is the
    # second field and never the first.
    assert [line for line in lines if line.split(" ")[1].startswith("vault")] == []


def test_every_refusal_path_is_silent_too(
    http, active_user, device, bearer, register_bearer
):
    """A failure is where a logger normally appears — "bad blob from user X" is
    exactly the line an operator would add. Every refusal this route can answer
    runs here, and none of them may name the account, the device or the blob."""
    headers = bearer(active_user, device)
    stored = backup_blob(b"S")
    rejected = base64.b64encode(b"x" * (min(BACKUP_BUCKETS) - 1)).decode()
    http.put(KEYBACKUP_URL, json={"blob": stored, "version": 6}, headers=headers)

    with capture_all_logging() as lines:
        logging.getLogger("test.canary").debug("canary")
        answers = [
            http.put(
                KEYBACKUP_URL, json={"blob": rejected, "version": 7}, headers=headers
            ).status_code,
            http.put(
                KEYBACKUP_URL, json={"blob": stored, "version": 6}, headers=headers
            ).status_code,
            http.put(
                KEYBACKUP_URL, json={"blob": stored, "version": "six"}, headers=headers
            ).status_code,
            http.get(KEYBACKUP_URL).status_code,
            http.get(KEYBACKUP_URL, headers=register_bearer(active_user)).status_code,
            http.post(KEYBACKUP_URL, json={}, headers=headers).status_code,
        ]

    assert answers == [400, 409, 400, 401, 403, 405]
    assert any("canary" in line for line in lines)
    assert_absent(
        lines,
        {
            "owner id": str(active_user.id),
            "device id": str(device.id),
            "stored blob": stored,
            "rejected blob": rejected,
        },
    )


def test_a_404_read_names_no_account(http, active_user, device, bearer):
    """The one path where the server knows an account has no backup at all — the
    state most worth writing down, and the one it must not write down."""
    headers = bearer(active_user, device)

    with capture_all_logging() as lines:
        logging.getLogger("test.canary").debug("canary")
        missing = http.get(KEYBACKUP_URL, headers=headers)

    assert missing.status_code == 404
    assert any("canary" in line for line in lines)
    assert_absent(lines, {"owner id": str(active_user.id)})
