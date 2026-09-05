"""The units of work behind the accounts routes, called directly.

Each function here is one transaction, and what it leaves behind is a row or a
raised `ApiError`. Driving them without a request is what makes the row state
observable at the point the unit commits it; the same paths as they look through
the HTTP surface are in `test_auth_api.py` and `test_directory_profile.py`.
"""

import base64
import uuid

import pytest

from accounts import services
from accounts.models import ProfileBlob, User
from api.errors import ApiError
from conftest import PASSWORD
from core.buckets import PROFILE_BUCKETS
from devices.models import Device

pytestmark = pytest.mark.django_db

GOOD_PASSWORD = "a-sufficiently-long-passphrase"


def refusal(exc_info):
    """The three parts of a refusal a client can see."""
    error = exc_info.value
    return error.status_code, error.code, error.detail


def other_account_device(username, registration_id):
    owner = User.objects.create_user(username=username, password=PASSWORD, is_active=True)
    return owner, Device.objects.create(
        user=owner,
        ik_pub=b"ik",
        spk_id=1,
        spk_pub=b"spk",
        spk_sig=b"sig",
        registration_id=registration_id,
    )


class TestRegister:
    def test_the_account_lands_inactive_with_only_a_hash_of_the_password(self):
        body = services.register("zed", GOOD_PASSWORD)

        account = User.objects.get(id=body["user_id"])
        assert account.is_active is False
        assert account.password.startswith("argon2$argon2id$")
        assert GOOD_PASSWORD not in account.password

    def test_the_second_registration_of_a_name_is_a_conflict(self):
        services.register("zed", GOOD_PASSWORD)

        with pytest.raises(ApiError) as exc_info:
            services.register("zed", GOOD_PASSWORD)

        assert refusal(exc_info) == (409, "username_taken", "That username is taken.")
        assert User.objects.filter(username="zed").count() == 1

    def test_the_conflict_is_the_unique_index_and_not_a_probe(self):
        """The manager lowercases before it writes, so a name the route already
        normalised is normalised again here and the index still settles it."""
        services.register("zed", GOOD_PASSWORD)

        with pytest.raises(ApiError) as exc_info:
            services.register("ZED", GOOD_PASSWORD)

        assert refusal(exc_info)[1] == "username_taken"
        assert User.objects.count() == 1


class TestLogin:
    def test_an_unknown_name_and_a_wrong_password_refuse_identically(self, active_user):
        with pytest.raises(ApiError) as unknown:
            services.login("ghost", GOOD_PASSWORD, None)
        with pytest.raises(ApiError) as wrong:
            services.login("alice", "the-wrong-passphrase", None)

        assert refusal(unknown) == refusal(wrong)
        assert refusal(wrong) == (
            401,
            "invalid_credentials",
            services.INVALID_CREDENTIALS,
        )

    def test_a_correct_password_on_an_account_awaiting_activation_is_refused(self):
        User.objects.create_user(username="pending", password=PASSWORD)

        with pytest.raises(ApiError) as exc_info:
            services.login("pending", PASSWORD, None)

        assert refusal(exc_info) == (
            403,
            "account_inactive",
            "This account is awaiting activation.",
        )

    def test_without_a_device_only_a_register_scope_token_comes_back(self, active_user):
        body = services.login("alice", PASSWORD, None)

        assert set(body) == {"token", "expires_in", "user_id", "scope"}
        assert body["scope"] == "register"
        assert body["user_id"] == str(active_user.id)

    def test_a_device_of_this_account_is_named_and_its_row_is_left_alone(
        self, active_user, device
    ):
        body = services.login("alice", PASSWORD, device.id)

        device.refresh_from_db()
        assert set(body) == {"token", "expires_in", "user_id", "scope", "device_id"}
        assert body["scope"] == "full"
        assert body["device_id"] == str(device.id)
        assert device.token_generation == 1

    def test_a_revoked_device_falls_back_and_its_generation_is_left_alone(
        self, active_user, device
    ):
        device.revoked_date = "2026-01-01"
        device.save(update_fields=["revoked_date"])

        body = services.login("alice", PASSWORD, device.id)

        device.refresh_from_db()
        assert body["scope"] == "register"
        assert device.token_generation == 1

    def test_a_device_of_another_account_is_never_honoured(self, active_user):
        _owner, theirs = other_account_device("mallory", 7)

        body = services.login("alice", PASSWORD, theirs.id)

        theirs.refresh_from_db()
        assert body["scope"] == "register"
        assert theirs.token_generation == 1

    def test_a_device_id_that_names_nothing_falls_back_to_register_scope(
        self, active_user
    ):
        body = services.login("alice", PASSWORD, uuid.uuid4())

        assert body["scope"] == "register"


class TestLogout:
    def test_the_token_generation_of_the_named_device_advances(self, active_user, device):
        services.logout(active_user.id, device.id)

        device.refresh_from_db()
        assert device.token_generation == 2

    def test_a_device_of_another_account_is_untouched(self, active_user, device):
        _owner, theirs = other_account_device("victim", 9)

        services.logout(active_user.id, theirs.id)

        theirs.refresh_from_db()
        device.refresh_from_db()
        assert theirs.token_generation == 1
        assert device.token_generation == 1

    def test_a_device_that_is_already_gone_is_a_silent_no_op(self, active_user, device):
        """The rare case: the operator deleted the device between the token check
        and the logout. There is nothing left to revoke and nothing to report."""
        device_id = device.id
        device.delete()

        services.logout(active_user.id, device_id)

        assert Device.objects.count() == 0


class TestDirectory:
    def test_an_empty_directory_is_an_empty_list(self):
        assert services.directory() == {"users": []}

    def test_only_activated_accounts_appear_and_they_are_ordered_by_name(
        self, active_user
    ):
        User.objects.create_user(username="carol", password=PASSWORD, is_active=True)
        User.objects.create_user(username="pending", password=PASSWORD)

        body = services.directory()

        assert [row["username"] for row in body["users"]] == ["alice", "carol"]
        assert set(body["users"][0]) == {"user_id", "username"}


class TestProfiles:
    def stored(self, user, size=PROFILE_BUCKETS[0], version=1, fill=b"\x05"):
        return ProfileBlob.objects.create(user=user, blob=fill * size, version=version)

    def test_a_missing_own_profile_and_a_missing_peer_profile_read_differently(
        self, active_user
    ):
        with pytest.raises(ApiError) as mine:
            services.my_profile(active_user.id)
        with pytest.raises(ApiError) as theirs:
            services.peer_profile(active_user.id)

        assert refusal(mine) == (404, "not_found", "No profile yet.")
        assert refusal(theirs) == (404, "not_found", "No profile for that user.")

    def test_the_body_is_base64_of_the_stored_bytes(self, active_user):
        self.stored(active_user, version=3)

        body = services.peer_profile(active_user.id)

        assert base64.b64decode(body["blob"]) == b"\x05" * PROFILE_BUCKETS[0]
        assert body["version"] == 3

    def test_a_deactivated_owner_keeps_a_profile_it_can_still_read_itself(self):
        """`peer_profile` filters on activation, `my_profile` does not: a
        deactivated account is invisible to everyone else and unchanged to itself."""
        pending = User.objects.create_user(username="pending", password=PASSWORD)
        self.stored(pending)

        with pytest.raises(ApiError) as exc_info:
            services.peer_profile(pending.id)

        assert refusal(exc_info)[0] == 404
        assert services.my_profile(pending.id)["version"] == 1

    def test_the_first_write_may_carry_version_zero(self, active_user):
        services.write_profile(active_user.id, b"\x01" * PROFILE_BUCKETS[0], 0)

        row = ProfileBlob.objects.get(user=active_user)
        assert row.version == 0
        assert bytes(row.blob) == b"\x01" * PROFILE_BUCKETS[0]

    @pytest.mark.parametrize("version", [4, 3])
    def test_a_version_that_does_not_increase_is_stale(self, active_user, version):
        self.stored(active_user, version=4)

        with pytest.raises(ApiError) as exc_info:
            services.write_profile(active_user.id, b"\x02" * PROFILE_BUCKETS[0], version)

        assert refusal(exc_info) == (409, "stale_version", "Version must increase.")
        assert bytes(ProfileBlob.objects.get(user=active_user).blob) == (
            b"\x05" * PROFILE_BUCKETS[0]
        )

    def test_a_higher_version_replaces_the_blob_and_may_change_bucket(self, active_user):
        self.stored(active_user, version=1)

        services.write_profile(active_user.id, b"\x09" * PROFILE_BUCKETS[1], 2)

        row = ProfileBlob.objects.get(user=active_user)
        assert row.version == 2
        assert len(bytes(row.blob)) == PROFILE_BUCKETS[1]
