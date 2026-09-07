"""The headline restore flow, post-history: the key backup only.

Device 1 uploads the recovery-protected key backup (cross-signing private keys and
identity material); a brand-new device 2 for the same user reads it back
byte-identical. That is everything a new device gets from the server — message
history transfers client-to-client from an existing device and never appears here.
"""

import base64

import pytest

from core.buckets import BACKUP_BUCKETS
from vault.models import KeyBackup

from .conftest import KEYBACKUP_URL, backup_blob, make_device

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)


def test_a_new_device_restores_the_key_backup_byte_identical(
    http, active_user, device, bearer
):
    device1 = bearer(active_user, device)
    backup_payload = backup_blob(b"K", size=16384)

    assert (
        http.put(
            KEYBACKUP_URL,
            json={"blob": backup_payload, "version": 1},
            headers=device1,
        ).status_code
        == 200
    )

    # A brand-new device for the same account, with its own full-scope token.
    device2 = bearer(active_user, make_device(active_user, registration_id=2))
    assert http.get(KEYBACKUP_URL, headers=device2).json() == {
        "blob": backup_payload,
        "version": 1,
    }


def test_backups_are_scoped_to_their_owner(
    http, active_user, device, bearer, bob, bob_device
):
    http.put(
        KEYBACKUP_URL,
        json={"blob": backup_blob(b"A"), "version": 1},
        headers=bearer(active_user, device),
    )

    theirs = http.get(KEYBACKUP_URL, headers=bearer(bob, bob_device))

    assert theirs.status_code == 404


def test_a_restore_returns_the_newest_backup_not_the_one_the_device_last_wrote(
    http, active_user, device, bearer
):
    """The enrollment flow of `CLIENT_CONTRACT.md` §M: the new device reads what
    the account holds *now*. A device that wrote version 1 and went offline while
    another wrote version 2 must not be handed its own stale copy back."""
    headers = bearer(active_user, device)
    http.put(
        KEYBACKUP_URL, json={"blob": backup_blob(b"1"), "version": 1}, headers=headers
    )
    newest = backup_blob(b"2")
    http.put(KEYBACKUP_URL, json={"blob": newest, "version": 2}, headers=headers)

    restored = http.get(
        KEYBACKUP_URL,
        headers=bearer(active_user, make_device(active_user, registration_id=3)),
    )

    assert restored.json() == {"blob": newest, "version": 2}


def test_the_largest_bucket_restores_byte_identical(http, active_user, device, bearer):
    """A megabyte of wrapped key material through JSON, base64 and `bytea` and
    back. If any layer re-encoded or truncated it, the account's self-signing key
    would be unrecoverable and no earlier test would have noticed."""
    payload = backup_blob(b"L", size=max(BACKUP_BUCKETS))
    assert (
        http.put(
            KEYBACKUP_URL,
            json={"blob": payload, "version": 1},
            headers=bearer(active_user, device),
        ).status_code
        == 200
    )

    restored = http.get(
        KEYBACKUP_URL,
        headers=bearer(active_user, make_device(active_user, registration_id=4)),
    )

    assert base64.b64decode(restored.json()["blob"]) == b"L" * max(BACKUP_BUCKETS)


def test_restoring_twice_returns_the_same_bytes_and_writes_nothing(
    http, active_user, device, bearer
):
    """`vault/API.md`: `GET` writes nothing and is safe to repeat. Two devices
    enrolling from the same backup must see the identical answer, and the row
    must be untouched afterwards — a read that bumped a counter would be a
    per-device record of who restored when."""
    headers = bearer(active_user, device)
    http.put(
        KEYBACKUP_URL, json={"blob": backup_blob(b"R"), "version": 4}, headers=headers
    )
    before = KeyBackup.objects.get(user_id=active_user.id)

    first = http.get(KEYBACKUP_URL, headers=headers)
    second = http.get(
        KEYBACKUP_URL,
        headers=bearer(active_user, make_device(active_user, registration_id=5)),
    )

    assert first.json() == second.json()
    after = KeyBackup.objects.get(user_id=active_user.id)
    assert (after.version, bytes(after.blob)) == (before.version, bytes(before.blob))
    assert KeyBackup.objects.count() == 1


def test_a_device_that_enrolls_before_any_backup_exists_is_told_so(
    http, active_user, device, bearer
):
    """Step 5 of the first-device flow is `PUT /me/keybackup`; a user who skipped
    it strands every later device. The later device has to be able to tell that
    case apart from a failure, so it gets the documented `404` rather than an
    empty blob."""
    restored = http.get(
        KEYBACKUP_URL,
        headers=bearer(active_user, make_device(active_user, registration_id=6)),
    )

    assert restored.status_code == 404
    assert restored.json()["code"] == "not_found"
