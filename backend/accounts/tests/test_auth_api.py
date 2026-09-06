"""Registration, login, renewal, and logout.

Every route here answers through FastAPI. The token semantics are ADR-0023's:
one device-bound session token, no token stored, and revocation is the one
generation counter on the device row. `token_generation` kills every token of
the device at once, and nothing else ends a token before its own `exp`.
"""

from unittest import mock

import pytest
from django.conf import settings
from django.contrib.auth.hashers import check_password

from accounts.models import User
from accounts.services import DUMMY_HASH
from api.auth import decode, issue_session
from conftest import PASSWORD
from devices.models import Device

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)

GOOD_PASSWORD = "a-sufficiently-long-passphrase"
REGISTER_URL = "/api/v1/auth/register"
LOGIN_URL = "/api/v1/auth/login"
RENEW_URL = "/api/v1/auth/renew"
LOGOUT_URL = "/api/v1/auth/logout"
DIRECTORY_URL = "/api/v1/users"


class TestRegister:
    def test_creates_an_inactive_account(self, http):
        response = http.post(
            REGISTER_URL, json={"username": "bob", "password": GOOD_PASSWORD}
        )

        assert response.status_code == 201
        assert set(response.json()) == {"user_id"}
        user = User.objects.get(id=response.json()["user_id"])
        assert user.is_active is False

    def test_username_is_normalised_to_lowercase(self, http):
        response = http.post(
            REGISTER_URL, json={"username": "BoB", "password": GOOD_PASSWORD}
        )

        assert response.status_code == 201
        assert User.objects.get(id=response.json()["user_id"]).username == "bob"

    def test_duplicate_username_is_a_conflict(self, http):
        http.post(REGISTER_URL, json={"username": "bob", "password": GOOD_PASSWORD})

        response = http.post(
            REGISTER_URL, json={"username": "bob", "password": GOOD_PASSWORD}
        )

        assert response.status_code == 409
        assert response.json()["code"] == "username_taken"

    def test_case_variant_collides_with_an_existing_username(self, http):
        http.post(REGISTER_URL, json={"username": "bob", "password": GOOD_PASSWORD})

        response = http.post(
            REGISTER_URL, json={"username": "BOB", "password": GOOD_PASSWORD}
        )

        assert response.status_code == 409
        assert response.json()["code"] == "username_taken"

    @pytest.mark.parametrize(
        "username", ["ab", "x" * 33, "has space", "Ünicode", "dash-es"]
    )
    def test_username_must_match_the_model_validator(self, http, username):
        response = http.post(
            REGISTER_URL, json={"username": username, "password": GOOD_PASSWORD}
        )

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"
        assert set(response.json()["detail"]) == {"username"}

    @pytest.mark.parametrize("password", ["short", "password123"])
    def test_password_must_pass_django_validators(self, http, password):
        response = http.post(REGISTER_URL, json={"username": "bob", "password": password})

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"
        assert not User.objects.filter(username="bob").exists()

    def test_unknown_fields_are_rejected(self, http):
        response = http.post(
            REGISTER_URL,
            json={"username": "bob", "password": GOOD_PASSWORD, "is_staff": True},
        )

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"

    # Both are rejected — one for length, one for being common — so there is
    # always an error body that could have leaked the value.
    @pytest.mark.parametrize("password", ["zzqqxvw", "password123"])
    def test_error_never_echoes_the_submitted_password(self, http, password):
        response = http.post(REGISTER_URL, json={"username": "bob", "password": password})

        assert response.status_code == 400
        assert password not in response.text


class TestLogin:
    def test_unknown_username_still_pays_for_a_dummy_argon2_verify(self, http):
        with mock.patch(
            "accounts.services.check_password", wraps=check_password
        ) as verify:
            response = http.post(
                LOGIN_URL, json={"username": "ghost", "password": GOOD_PASSWORD}
            )

        assert response.status_code == 401
        assert verify.call_count == 1
        # Verified against a real Argon2id hash, so the work matches a live account.
        assert verify.call_args.args[1] == DUMMY_HASH
        assert DUMMY_HASH.startswith("argon2$argon2id$")

    def test_unknown_user_and_wrong_password_are_indistinguishable(
        self, http, active_user
    ):
        unknown = http.post(
            LOGIN_URL, json={"username": "ghost", "password": GOOD_PASSWORD}
        )
        wrong = http.post(
            LOGIN_URL, json={"username": "alice", "password": "the-wrong-passphrase"}
        )

        assert unknown.status_code == wrong.status_code == 401
        assert unknown.json() == wrong.json()
        assert unknown.json()["code"] == "invalid_credentials"

    def test_inactive_account_is_told_to_wait(self, http):
        User.objects.create_user(username="bob", password=GOOD_PASSWORD)

        response = http.post(
            LOGIN_URL, json={"username": "bob", "password": GOOD_PASSWORD}
        )

        assert response.status_code == 403
        assert response.json()["code"] == "account_inactive"

    def test_activation_state_leaks_only_after_the_password_is_proven(self, http):
        User.objects.create_user(username="bob", password=GOOD_PASSWORD)

        response = http.post(
            LOGIN_URL, json={"username": "bob", "password": "the-wrong-passphrase"}
        )

        assert response.status_code == 401
        assert response.json()["code"] == "invalid_credentials"

    def test_without_a_device_only_a_register_scope_token_is_issued(
        self, http, active_user
    ):
        response = http.post(LOGIN_URL, json={"username": "alice", "password": PASSWORD})

        body = response.json()
        assert response.status_code == 200
        assert body["scope"] == "register"
        assert set(body) == {"token", "expires_in", "user_id", "scope"}
        assert body["expires_in"] == settings.REGISTER_SCOPE_ACCESS_MIN * 60

    def test_with_a_live_device_a_session_token_is_issued(
        self, http, active_user, device
    ):
        response = http.post(
            LOGIN_URL,
            json={
                "username": "alice",
                "password": PASSWORD,
                "device_id": str(device.id),
            },
        )

        body = response.json()
        assert response.status_code == 200
        assert set(body) == {"token", "expires_in", "user_id", "scope", "device_id"}
        assert body["scope"] == "full"
        assert body["device_id"] == str(device.id)
        assert body["expires_in"] == settings.SESSION_TOKEN_DAYS * 86400
        assert decode(body["token"])["typ"] == "session"

    def test_a_login_leaves_the_tokens_the_device_already_held_alive(
        self, http, active_user, device
    ):
        """No rotation: the token a client held before the login is still the
        same session afterwards, so two clients of one device never race each
        other out of it."""
        older, _expires_in = issue_session(active_user, device)

        http.post(
            LOGIN_URL,
            json={
                "username": "alice",
                "password": PASSWORD,
                "device_id": str(device.id),
            },
        )

        device.refresh_from_db()
        assert device.token_generation == 1
        still_live = http.get(DIRECTORY_URL, headers={"Authorization": f"Bearer {older}"})
        assert still_live.status_code == 200

    def test_revoked_device_falls_back_to_register_scope(self, http, active_user, device):
        device.revoked_date = "2026-01-01"
        device.save(update_fields=["revoked_date"])

        response = http.post(
            LOGIN_URL,
            json={
                "username": "alice",
                "password": PASSWORD,
                "device_id": str(device.id),
            },
        )

        assert response.json()["scope"] == "register"

    # Login parses anonymous input, so a type confusion here is an
    # unauthenticated 500.
    @pytest.mark.parametrize(
        "payload",
        [
            {"username": {"$ne": None}, "password": GOOD_PASSWORD},
            {"username": ["alice"], "password": GOOD_PASSWORD},
            {"username": "alice", "password": GOOD_PASSWORD, "device_id": "not-a-uuid"},
            {"username": "alice", "password": 12345},
        ],
    )
    def test_malformed_input_is_rejected_without_a_server_error(self, http, payload):
        response = http.post(LOGIN_URL, json=payload)

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"

    def test_a_device_belonging_to_another_user_is_never_honoured(
        self, http, active_user
    ):
        intruder = User.objects.create_user(
            username="mallory", password=PASSWORD, is_active=True
        )
        their_device = Device.objects.create(
            user=intruder,
            ik_pub=b"ik",
            spk_id=1,
            spk_pub=b"spk",
            spk_sig=b"sig",
            registration_id=7,
        )

        response = http.post(
            LOGIN_URL,
            json={
                "username": "alice",
                "password": PASSWORD,
                "device_id": str(their_device.id),
            },
        )

        assert response.json()["scope"] == "register"
        their_device.refresh_from_db()
        assert their_device.token_generation == 1


class TestRenew:
    def test_a_session_token_buys_another_one_and_writes_nothing(
        self, http, active_user, device, bearer
    ):
        response = http.post(RENEW_URL, headers=bearer(active_user, device))

        body = response.json()
        assert response.status_code == 200
        assert set(body) == {"token", "expires_in"}
        assert body["expires_in"] == settings.SESSION_TOKEN_DAYS * 86400
        device.refresh_from_db()
        assert device.token_generation == 1

    def test_the_presented_token_stays_valid_beside_the_new_one(
        self, http, active_user, device, bearer
    ):
        """The whole of the change from rotation: renewing invalidates nothing,
        so a client that renews twice from two isolates keeps three working
        tokens rather than losing its session to the loser of a race."""
        headers = bearer(active_user, device)

        first = http.post(RENEW_URL, headers=headers).json()["token"]
        second = http.post(RENEW_URL, headers=headers).json()["token"]

        assert first != second
        for token in (headers["Authorization"].split()[1], first, second):
            live = http.get(DIRECTORY_URL, headers={"Authorization": f"Bearer {token}"})
            assert live.status_code == 200

    def test_the_renewed_token_can_renew_again(self, http, active_user, device, bearer):
        renewed = http.post(RENEW_URL, headers=bearer(active_user, device)).json()

        again = http.post(
            RENEW_URL, headers={"Authorization": f"Bearer {renewed['token']}"}
        )

        assert again.status_code == 200

    def test_a_token_renew_issued_dies_with_the_next_revocation(
        self, http, active_user, device, bearer
    ):
        """Renewal must not put a token beyond the one counter that ends them.

        The route mints at the generation the row carries now, so a logout that
        lands after it kills the new token exactly as it kills the old one. A
        token minted outside that counter would be a session no revocation could
        reach for `SESSION_TOKEN_DAYS`.
        """
        headers = bearer(active_user, device)
        renewed = http.post(RENEW_URL, headers=headers).json()["token"]
        renewed_headers = {"Authorization": f"Bearer {renewed}"}
        assert http.get(DIRECTORY_URL, headers=renewed_headers).status_code == 200

        assert http.post(LOGOUT_URL, headers=headers).status_code == 204

        dead = http.get(DIRECTORY_URL, headers=renewed_headers)
        assert dead.status_code == 401
        assert dead.json()["code"] == "token_revoked"

    def test_a_revoked_device_cannot_renew(self, http, active_user, device, bearer):
        headers = bearer(active_user, device)
        device.revoked_date = "2026-01-01"
        device.save(update_fields=["revoked_date"])

        response = http.post(RENEW_URL, headers=headers)

        assert response.status_code == 401
        assert response.json()["code"] == "token_revoked"

    def test_a_logged_out_device_cannot_renew(self, http, active_user, device, bearer):
        headers = bearer(active_user, device)
        assert http.post(LOGOUT_URL, headers=headers).status_code == 204

        response = http.post(RENEW_URL, headers=headers)

        assert response.status_code == 401
        assert response.json()["code"] == "token_revoked"

    def test_a_deactivated_account_cannot_renew(self, http, active_user, device, bearer):
        headers = bearer(active_user, device)
        active_user.is_active = False
        active_user.save(update_fields=["is_active"])

        response = http.post(RENEW_URL, headers=headers)

        assert response.status_code == 401
        assert response.json()["code"] == "token_revoked"

    def test_a_register_token_cannot_renew_its_way_to_a_session(
        self, http, active_user, register_bearer
    ):
        """The register token is the one credential an account with no device
        holds. Renewing with it would mint the device-bound token its holder was
        deliberately not given."""
        response = http.post(RENEW_URL, headers=register_bearer(active_user))

        assert response.status_code == 403
        assert response.json()["code"] == "scope_forbidden"

    def test_renewal_requires_authentication(self, http):
        response = http.post(RENEW_URL)

        assert response.status_code == 401
        assert response.json()["code"] == "unauthenticated"

    def test_a_garbage_token_is_an_invalid_token(self, http):
        response = http.post(RENEW_URL, headers={"Authorization": "Bearer not-a-jwt"})

        assert response.status_code == 401
        assert response.json()["code"] == "invalid_token"


class TestLogout:
    def test_ends_every_token_of_the_calling_device(
        self, http, active_user, device, bearer
    ):
        headers = bearer(active_user, device)
        sibling, _expires_in = issue_session(active_user, device)

        response = http.post(LOGOUT_URL, headers=headers)

        assert response.status_code == 204
        assert response.content == b""
        device.refresh_from_db()
        assert device.token_generation == 2
        assert (
            http.get(
                DIRECTORY_URL, headers={"Authorization": f"Bearer {sibling}"}
            ).status_code
            == 401
        )

    def test_takes_no_body_and_ignores_one(self, http, active_user, device, bearer):
        response = http.post(
            LOGOUT_URL, headers=bearer(active_user, device), json={"token": "junk"}
        )

        assert response.status_code == 204

    def test_the_presented_token_cannot_log_out_twice(
        self, http, active_user, device, bearer
    ):
        """Logout advances the token generation, so the token that performed it
        is finished the moment it succeeds."""
        headers = bearer(active_user, device)

        assert http.post(LOGOUT_URL, headers=headers).status_code == 204

        repeat = http.post(LOGOUT_URL, headers=headers)
        assert repeat.status_code == 401
        assert repeat.json()["code"] == "token_revoked"

    def test_touches_no_other_account(self, http, active_user, device, bearer):
        victim = User.objects.create_user(
            username="victim", password=PASSWORD, is_active=True
        )
        victim_device = Device.objects.create(
            user=victim,
            ik_pub=b"ik",
            spk_id=1,
            spk_pub=b"spk",
            spk_sig=b"sig",
            registration_id=9,
        )
        victim_headers = bearer(victim, victim_device)

        assert (
            http.post(LOGOUT_URL, headers=bearer(active_user, device)).status_code == 204
        )

        assert http.post(RENEW_URL, headers=victim_headers).status_code == 200

    def test_requires_authentication(self, http):
        response = http.post(LOGOUT_URL)

        assert response.status_code == 401
        assert response.json()["code"] == "unauthenticated"
        assert response.headers["www-authenticate"] == "Bearer"


class TestLoginLockout:
    """The cool-off on a login name, shared with the admin panel (`core/lockout.py`).

    The address limiter alone bounds a guesser to its rate per address, and an
    attacker with many addresses multiplies it. The name is the thing being
    attacked, so the name is what locks: five failures in fifteen minutes refuse
    the name — real or not, so the lock confirms nothing about existence — before
    the password is hashed.
    """

    def fail(self, http, username, times):
        for _ in range(times):
            response = http.post(
                LOGIN_URL, json={"username": username, "password": "the-wrong-one"}
            )
            assert response.status_code == 401

    def test_repeated_failures_lock_the_name_with_a_retry_after(self, http, active_user):
        from core.lockout import COOLOFF_SECONDS, FAILURE_THRESHOLD

        self.fail(http, "alice", FAILURE_THRESHOLD)

        # The right password now, and it is still refused.
        response = http.post(LOGIN_URL, json={"username": "alice", "password": PASSWORD})

        assert response.status_code == 429
        assert response.json()["code"] == "throttled"
        assert 0 < int(response.headers["Retry-After"]) <= COOLOFF_SECONDS

    def test_a_locked_name_never_reaches_the_password_hash(self, http, active_user):
        from core.lockout import FAILURE_THRESHOLD

        self.fail(http, "alice", FAILURE_THRESHOLD)

        with (
            mock.patch.object(User, "check_password", autospec=True) as known,
            mock.patch("accounts.services.check_password") as unknown,
        ):
            http.post(LOGIN_URL, json={"username": "alice", "password": PASSWORD})

        assert known.call_count == 0
        assert unknown.call_count == 0

    def test_the_lock_is_keyed_on_the_name_and_not_on_existence(self, http):
        """A name that exists and one that does not lock the same way, so the
        lock is not an oracle for the directory."""
        from core.lockout import FAILURE_THRESHOLD

        self.fail(http, "ghost", FAILURE_THRESHOLD)

        response = http.post(LOGIN_URL, json={"username": "ghost", "password": PASSWORD})

        assert response.status_code == 429
        assert response.json()["code"] == "throttled"

    def test_the_lock_holds_for_one_name_only(self, http, active_user, bob):
        from core.lockout import FAILURE_THRESHOLD

        self.fail(http, "alice", FAILURE_THRESHOLD)

        response = http.post(LOGIN_URL, json={"username": "bob", "password": PASSWORD})

        assert response.status_code == 200

    def test_a_successful_login_forgets_the_earlier_failures(self, http, active_user):
        from core.lockout import FAILURE_THRESHOLD

        self.fail(http, "alice", FAILURE_THRESHOLD - 1)
        assert (
            http.post(
                LOGIN_URL, json={"username": "alice", "password": PASSWORD}
            ).status_code
            == 200
        )
        self.fail(http, "alice", FAILURE_THRESHOLD - 1)

        response = http.post(LOGIN_URL, json={"username": "alice", "password": PASSWORD})

        assert response.status_code == 200

    def test_the_lock_refuses_when_redis_cannot_be_read(
        self, http, active_user, monkeypatch
    ):
        """Fails closed, like the address limiter (ADR-0010) and the admin form:
        a control whose purpose is to refuse cannot answer "allow" when it does
        not know."""
        import redis

        class Unreachable:
            def ttl(self, *args, **kwargs):
                raise redis.ConnectionError("redis is down")

        monkeypatch.setattr("core.lockout._redis", lambda: Unreachable())

        response = http.post(LOGIN_URL, json={"username": "alice", "password": PASSWORD})

        assert response.status_code == 503
        assert response.json()["code"] == "unavailable"


class TestTheAccountSideOfRevocation:
    """What a logout, a revocation and a deactivation look like from the account
    rather than from the token. The verifier's half — what a claim set must carry
    and how a signature is checked — is `test_device_auth.py`."""

    def test_a_logout_on_one_device_never_ends_another_device_of_the_account(
        self, http, active_user, device, bearer
    ):
        second = Device.objects.create(
            user=active_user,
            ik_pub=b"ik",
            spk_id=2,
            spk_pub=b"spk",
            spk_sig=b"sig",
            registration_id=2002,
        )
        untouched = bearer(active_user, second)

        http.post(LOGOUT_URL, headers=bearer(active_user, device))

        assert http.get(DIRECTORY_URL, headers=untouched).status_code == 200
        second.refresh_from_db()
        assert second.token_generation == 1

    def test_logout_ends_the_session_without_ending_the_device(
        self, http, active_user, device, bearer
    ):
        """Logout is not revocation: the device row stays live, so the same device
        signs in again and is handed a working token."""
        http.post(LOGOUT_URL, headers=bearer(active_user, device))

        device.refresh_from_db()
        assert device.revoked_date is None

        again = http.post(
            LOGIN_URL,
            json={
                "username": "alice",
                "password": PASSWORD,
                "device_id": str(device.id),
            },
        )

        assert again.json()["scope"] == "full"
        assert (
            http.get(
                DIRECTORY_URL,
                headers={"Authorization": f"Bearer {again.json()['token']}"},
            ).status_code
            == 200
        )

    def test_a_dead_token_presented_after_a_logout_advances_nothing_further(
        self, http, active_user, device, bearer
    ):
        """A token whose generation is already behind the row is refused on that
        alone, so presenting one after a logout cannot advance the counter a
        second time and cut a session the account has since started."""
        stale = bearer(active_user, device)
        http.post(LOGOUT_URL, headers=stale)

        refused = http.post(LOGOUT_URL, headers=stale)

        assert refused.status_code == 401
        assert refused.json()["code"] == "token_revoked"
        device.refresh_from_db()
        assert device.token_generation == 2

    def test_deactivating_an_account_freezes_its_live_tokens_and_thaws_them_back(
        self, http, active_user, device, bearer
    ):
        """Deactivation is a flag on the account, not a generation bump: every live
        token stops working while the flag is down and works again if the operator
        puts it back. The irreversible answer is revoking the devices, which is what
        the panel's other action does."""
        auth = bearer(active_user, device)
        active_user.is_active = False
        active_user.save(update_fields=["is_active"])

        frozen = http.get(DIRECTORY_URL, headers=auth)
        device.refresh_from_db()
        assert frozen.status_code == 401
        assert frozen.json()["code"] == "token_revoked"
        assert device.token_generation == 1

        active_user.is_active = True
        active_user.save(update_fields=["is_active"])

        assert http.get(DIRECTORY_URL, headers=auth).status_code == 200
        assert http.post(RENEW_URL, headers=auth).status_code == 200

    def test_a_deactivated_account_cannot_sign_in_to_mint_new_tokens(
        self, http, active_user, device
    ):
        active_user.is_active = False
        active_user.save(update_fields=["is_active"])

        response = http.post(
            LOGIN_URL,
            json={
                "username": "alice",
                "password": PASSWORD,
                "device_id": str(device.id),
            },
        )

        assert response.status_code == 403
        assert response.json()["code"] == "account_inactive"


class TestTheLockoutBoundary:
    """The threshold is a number, and both sides of it are behaviour a person
    hits: one mistyped password too many locks an account out of its own server."""

    def fail(self, http, username, times):
        for _ in range(times):
            assert (
                http.post(
                    LOGIN_URL, json={"username": username, "password": "the-wrong-one"}
                ).status_code
                == 401
            )

    def test_one_failure_short_of_the_threshold_leaves_the_name_open(
        self, http, active_user
    ):
        from core.lockout import FAILURE_THRESHOLD

        self.fail(http, "alice", FAILURE_THRESHOLD - 1)

        response = http.post(LOGIN_URL, json={"username": "alice", "password": PASSWORD})

        assert response.status_code == 200
        assert response.json()["scope"] == "register"

    def test_the_failure_that_reaches_the_threshold_is_still_answered_as_a_refusal(
        self, http, active_user
    ):
        """The lock is read before the attempt and written after it, so the attempt
        that trips the threshold is refused for the password it got wrong; only the
        one after it is refused for the lock."""
        from core.lockout import FAILURE_THRESHOLD

        self.fail(http, "alice", FAILURE_THRESHOLD - 1)

        tripping = http.post(
            LOGIN_URL, json={"username": "alice", "password": "the-wrong-one"}
        )
        after = http.post(LOGIN_URL, json={"username": "alice", "password": PASSWORD})

        assert tripping.status_code == 401
        assert tripping.json()["code"] == "invalid_credentials"
        assert after.status_code == 429
        assert after.json()["code"] == "throttled"


class TestRegistrationCannotTakeOverAName:
    def test_a_second_registration_never_replaces_the_stored_password(self, http):
        """The conflict has to be a refusal rather than an update: an account that
        is awaiting activation would otherwise be a name anybody could claim by
        registering it again."""
        first = http.post(
            REGISTER_URL, json={"username": "bob", "password": GOOD_PASSWORD}
        )

        response = http.post(
            REGISTER_URL, json={"username": "bob", "password": "a-different-passphrase"}
        )

        assert response.status_code == 409
        account = User.objects.get(id=first.json()["user_id"])
        assert account.check_password(GOOD_PASSWORD) is True
        assert account.check_password("a-different-passphrase") is False

    def test_an_account_awaiting_activation_already_holds_its_name(self, http):
        http.post(REGISTER_URL, json={"username": "bob", "password": GOOD_PASSWORD})

        response = http.post(
            REGISTER_URL, json={"username": "bob", "password": GOOD_PASSWORD}
        )

        assert response.status_code == 409
        assert User.objects.filter(username="bob", is_active=False).count() == 1


def test_the_api_login_writes_no_login_timing(http, active_user, device):
    """ADR-0023 stores no token because a per-device login record at rest is the
    login history a seizure would otherwise yield. A `last_login` written by the
    client-facing login would be that record by another name, so this route must
    leave the column alone.

    `login` in `accounts/services.py` authenticates against the hash directly and
    never calls `django.contrib.auth.login`, so it sends no `user_logged_in` and
    Django's `update_last_login` receiver never fires. That is the property; this
    test is what keeps a later refactor onto the Django helper from ending it
    silently."""
    before = User.objects.get(pk=active_user.pk).last_login

    response = http.post(
        LOGIN_URL,
        json={"username": "alice", "password": PASSWORD, "device_id": str(device.id)},
    )

    assert response.status_code == 200
    assert response.json()["scope"] == "full"
    assert before is None
    assert User.objects.get(pk=active_user.pk).last_login is None
