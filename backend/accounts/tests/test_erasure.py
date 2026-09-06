"""`DELETE /api/v1/me`: the account and every row that depends on it.

The one irreversible act this API offers, so what it deletes and what it leaves is
asserted row by row rather than by a count. Three properties are held here:

* it takes the account's own password, under the same per-name cool-off the login
  route runs, because a session token lives thirty days and nothing detects its theft
  (AR-18);
* the cascade reaches every table that names the account, and stops there — the
  attachments have nothing that names it, so they stay for the sweep;
* no audit row is written, because no operator performed it.
"""

import pytest
from django.contrib.admin.models import LogEntry

from accounts.models import ProfileBlob, User
from attachments.models import Attachment
from conftest import PASSWORD
from core import lockout
from core.buckets import ATTACHMENT_BUCKETS
from devices.models import (
    Device,
    DeviceLogRecord,
    OneTimePrekey,
    PqOneTimePrekey,
    UserIdentity,
)
from messaging.models import QueuedEnvelope
from vault.models import KeyBackup

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)

ERASE_URL = "/api/v1/me"
LOGIN_URL = "/api/v1/auth/login"
DIRECTORY_URL = "/api/v1/users"


@pytest.fixture
def furnished(active_user, device):
    """One row in every table that depends on the account, so the cascade below is
    asserted against a schema that is actually populated. A test that erased an
    account with nothing under it would pass whatever the cascade reached."""
    UserIdentity.objects.create(
        user=active_user,
        master_pub=b"master",
        self_signing_pub=b"self",
        user_signing_pub=b"user",
        master_sig=b"sig",
    )
    ProfileBlob.objects.create(user=active_user, blob=b"\x00" * 1024, version=1)
    KeyBackup.objects.create(user=active_user, blob=b"\x00" * 4096, version=1)
    DeviceLogRecord.objects.create(user=active_user, seq=1, blob=b"\x00" * 256)
    OneTimePrekey.objects.create(device=device, key_id=1, pub=b"otpk")
    PqOneTimePrekey.objects.create(device=device, key_id=1, pub=b"pq-otpk")
    QueuedEnvelope.objects.create(recipient_device=device, seq=1, blob=b"\x00" * 1024)
    return active_user


def erase(http, headers, password=PASSWORD):
    return http.request("DELETE", ERASE_URL, json={"password": password}, headers=headers)


class TestTheCascade:
    def test_the_account_and_every_dependent_row_go(
        self, http, furnished, device, bearer
    ):
        response = erase(http, bearer(furnished, device))

        assert response.status_code == 204
        assert response.content == b""
        assert not User.objects.filter(pk=furnished.pk).exists()
        assert not Device.objects.filter(user_id=furnished.pk).exists()
        assert not UserIdentity.objects.filter(user_id=furnished.pk).exists()
        assert not ProfileBlob.objects.filter(user_id=furnished.pk).exists()
        assert not KeyBackup.objects.filter(user_id=furnished.pk).exists()
        assert not DeviceLogRecord.objects.filter(user_id=furnished.pk).exists()
        assert not OneTimePrekey.objects.filter(device_id=device.pk).exists()
        assert not PqOneTimePrekey.objects.filter(device_id=device.pk).exists()
        assert not QueuedEnvelope.objects.filter(recipient_device_id=device.pk).exists()

    def test_the_username_is_free_again(self, http, active_user, device, bearer):
        """The whole point of the route for a user who wants to leave and come
        back: the unique index no longer holds their name."""
        erase(http, bearer(active_user, device))

        response = http.post(
            "/api/v1/auth/register",
            json={"username": active_user.username, "password": "a-long-new-password"},
        )

        assert response.status_code == 201

    def test_another_account_is_untouched(self, http, active_user, device, bearer, bob):
        """The cascade is scoped to the account that asked. Bob's device, mailbox
        and directory entry survive, which is the assertion a `filter()` that lost
        its `user_id` would fail."""
        bob_device = Device.objects.create(
            user=bob,
            ik_pub=b"ik",
            spk_id=1,
            spk_pub=b"spk",
            spk_sig=b"sig",
            registration_id=99,
        )
        QueuedEnvelope.objects.create(
            recipient_device=bob_device, seq=1, blob=b"\x00" * 1024
        )

        erase(http, bearer(active_user, device))

        assert User.objects.filter(pk=bob.pk).exists()
        assert Device.objects.filter(pk=bob_device.pk).exists()
        assert QueuedEnvelope.objects.filter(recipient_device_id=bob_device.pk).exists()

    def test_the_account_leaves_the_directory(
        self, http, active_user, device, bearer, bob
    ):
        bob_device = Device.objects.create(
            user=bob,
            ik_pub=b"ik",
            spk_id=1,
            spk_pub=b"spk",
            spk_sig=b"sig",
            registration_id=98,
        )

        erase(http, bearer(active_user, device))

        listed = http.get(DIRECTORY_URL, headers=bearer(bob, bob_device)).json()["users"]
        assert [entry["username"] for entry in listed] == ["bob"]

    def test_the_attachments_stay_for_the_sweep(self, http, active_user, device, bearer):
        """Nothing on an attachment row names an account (ADR-0025), so there is no
        set of them this call could identify as this account's. They go on
        `ATTACH_TTL_DAYS` like every other attachment."""
        stored = Attachment.objects.create(size=min(ATTACHMENT_BUCKETS))

        erase(http, bearer(active_user, device))

        assert Attachment.objects.filter(pk=stored.pk).exists()

    def test_no_audit_row_is_written(self, http, active_user, device, bearer):
        """The panel's audit log records what the operator did, and the operator
        did nothing. A row here would be a record that this username erased itself
        on this day, which is exactly what the erasure removes."""
        erase(http, bearer(active_user, device))

        assert not LogEntry.objects.exists()


class TestThePassword:
    def test_a_wrong_password_refuses_and_deletes_nothing(
        self, http, furnished, device, bearer
    ):
        response = erase(http, bearer(furnished, device), password="not-the-password")

        assert response.status_code == 401
        assert response.json() == {
            "code": "invalid_credentials",
            "detail": "Username or password is incorrect.",
        }
        assert User.objects.filter(pk=furnished.pk).exists()
        assert Device.objects.filter(user_id=furnished.pk).exists()
        assert QueuedEnvelope.objects.filter(recipient_device_id=device.pk).exists()

    def test_a_missing_password_is_a_malformed_request(
        self, http, active_user, device, bearer
    ):
        response = http.request(
            "DELETE", ERASE_URL, json={}, headers=bearer(active_user, device)
        )

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"
        assert User.objects.filter(pk=active_user.pk).exists()

    def test_a_field_the_body_does_not_declare_is_refused(
        self, http, active_user, device, bearer
    ):
        """`extra="forbid"`: a client that sent `{"confirm": true}` and no password
        must be refused, never obeyed."""
        response = http.request(
            "DELETE",
            ERASE_URL,
            json={"password": PASSWORD, "confirm": True},
            headers=bearer(active_user, device),
        )

        assert response.status_code == 400
        assert User.objects.filter(pk=active_user.pk).exists()

    def test_the_wrong_password_does_not_echo_what_was_sent(
        self, http, active_user, device, bearer
    ):
        canary = "canary-password-that-must-not-come-back"

        response = erase(http, bearer(active_user, device), password=canary)

        assert canary not in response.text


class TestTheLockout:
    def test_five_wrong_passwords_lock_the_name(self, http, active_user, device, bearer):
        """The same counter the login route feeds, on the same name. Without it the
        `accounts` scope would allow 300 password guesses a minute against the one
        irreversible route of this API."""
        headers = bearer(active_user, device)
        for _ in range(lockout.FAILURE_THRESHOLD):
            assert erase(http, headers, password="wrong-password").status_code == 401

        response = erase(http, headers)

        assert response.status_code == 429
        assert response.json()["code"] == "throttled"
        assert 0 < int(response.headers["retry-after"]) <= lockout.COOLOFF_SECONDS
        assert User.objects.filter(pk=active_user.pk).exists()

    def test_a_name_locked_by_the_login_route_is_locked_here_too(
        self, http, active_user, device, bearer
    ):
        """One name, one counter, both surfaces. A guesser who could spend the lock
        on login and then move here would have twice the budget."""
        for _ in range(lockout.FAILURE_THRESHOLD):
            http.post(
                LOGIN_URL,
                json={"username": active_user.username, "password": "wrong-password"},
            )

        response = erase(http, bearer(active_user, device))

        assert response.status_code == 429
        assert User.objects.filter(pk=active_user.pk).exists()

    def test_the_correct_password_clears_the_failures_before_it_erases(
        self, http, active_user, device, bearer
    ):
        """Four failures then the real password: the account goes, and the name it
        freed carries no cool-off into the registration that reclaims it."""
        headers = bearer(active_user, device)
        for _ in range(lockout.FAILURE_THRESHOLD - 1):
            erase(http, headers, password="wrong-password")

        assert erase(http, headers).status_code == 204
        assert lockout.locked_for(active_user.username, lockout.API) == 0

    def test_an_unreachable_lockout_store_fails_closed(
        self, http, active_user, device, bearer, monkeypatch
    ):
        """The posture of ADR-0010, on the route where opening the door is worst: a
        control that cannot read its state must not erase an account on the
        strength of a password it could not rate-limit."""

        def unavailable(username, surface):
            raise lockout.LockoutUnavailable

        monkeypatch.setattr("accounts.services.lockout.locked_for", unavailable)

        response = erase(http, bearer(active_user, device))

        assert response.status_code == 503
        assert response.json()["code"] == "unavailable"
        assert User.objects.filter(pk=active_user.pk).exists()


class TestAfterwards:
    def test_the_same_token_answers_401(self, http, active_user, device, bearer):
        """The retry semantics the contract publishes: the device the token names
        is gone with the account, so a client that lost the `204` reads `401` and
        treats it as success."""
        headers = bearer(active_user, device)

        assert erase(http, headers).status_code == 204

        again = erase(http, headers)
        assert again.status_code == 401
        assert again.json()["code"] == "token_revoked"

    def test_a_login_with_the_old_credentials_is_refused(
        self, http, active_user, device, bearer
    ):
        erase(http, bearer(active_user, device))

        response = http.post(
            LOGIN_URL, json={"username": active_user.username, "password": PASSWORD}
        )

        assert response.status_code == 401
        assert response.json()["code"] == "invalid_credentials"

    def test_every_live_socket_of_the_account_is_told_to_close(
        self, http, active_user, device, bearer, monkeypatch
    ):
        """`4003`, through the same bus call a revocation and a deactivation use.
        A REST call re-reads the row every time, but a socket authenticated once at
        connect would keep relaying until it happened to drop."""
        second = Device.objects.create(
            user=active_user,
            ik_pub=b"ik2",
            spk_id=2,
            spk_pub=b"spk2",
            spk_sig=b"sig2",
            registration_id=2002,
        )
        revoked = Device.objects.create(
            user=active_user,
            ik_pub=b"ik3",
            spk_id=3,
            spk_pub=b"spk3",
            spk_sig=b"sig3",
            registration_id=3003,
            revoked_date="2026-01-01",
        )
        closed = []
        monkeypatch.setattr(
            "accounts.services.close_device_sockets",
            lambda device_id: closed.append(device_id),
        )

        erase(http, bearer(active_user, device))

        assert sorted(closed, key=str) == sorted([device.id, second.id], key=str)
        assert revoked.id not in closed

    def test_the_sockets_close_only_once_the_rows_are_gone(
        self, http, active_user, device, bearer, monkeypatch
    ):
        """A device told `4003` while the transaction could still roll back would
        reconnect to an account that still exists."""
        seen = []
        monkeypatch.setattr(
            "accounts.services.close_device_sockets",
            lambda device_id: seen.append(Device.objects.filter(pk=device_id).exists()),
        )

        erase(http, bearer(active_user, device))

        assert seen == [False]
