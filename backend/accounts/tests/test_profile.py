import base64
import uuid

import pytest

from accounts.models import ProfileBlob, User
from conftest import PASSWORD
from core.buckets import PROFILE_BUCKETS
from devices.models import Device

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)

MY_PROFILE_URL = "/api/v1/me/profile"


def peer_profile_url(user_id):
    return f"/api/v1/users/{user_id}/profile"


def blob_of(nbytes, fill=b"\x00"):
    return base64.b64encode(fill * nbytes).decode()


@pytest.fixture
def headers(active_user, device, bearer):
    return bearer(active_user, device)


class TestReadProfile:
    def test_returns_the_stored_blob_and_version(self, http, active_user, headers):
        raw = b"\x01" * PROFILE_BUCKETS[0]
        ProfileBlob.objects.create(user=active_user, blob=raw, version=3)

        response = http.get(peer_profile_url(active_user.id), headers=headers)

        assert response.status_code == 200
        assert base64.b64decode(response.json()["blob"]) == raw
        assert response.json()["version"] == 3

    def test_own_profile_is_readable(self, http, active_user, headers):
        raw = b"\x03" * PROFILE_BUCKETS[0]
        ProfileBlob.objects.create(user=active_user, blob=raw, version=2)

        response = http.get(MY_PROFILE_URL, headers=headers)

        assert response.status_code == 200
        assert base64.b64decode(response.json()["blob"]) == raw
        assert response.json()["version"] == 2

    def test_missing_profile_is_a_404(self, http, active_user, headers):
        response = http.get(peer_profile_url(active_user.id), headers=headers)

        assert response.status_code == 404
        assert response.json()["code"] == "not_found"

    def test_inactive_users_profile_is_not_served(self, http, active_user, headers):
        pending = User.objects.create_user(username="pending", password=PASSWORD)
        ProfileBlob.objects.create(
            user=pending, blob=b"\x02" * PROFILE_BUCKETS[0], version=1
        )

        response = http.get(peer_profile_url(pending.id), headers=headers)

        assert response.status_code == 404

    def test_a_malformed_user_id_is_an_invalid_request(self, http, headers):
        response = http.get(peer_profile_url("not-a-uuid"), headers=headers)

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"

    def test_your_own_missing_profile_reads_a_different_404_from_a_peers(
        self, http, active_user, headers
    ):
        """Two absences, two sentences: the client that has never published one is
        told so, and the client asking about somebody else is told nothing about
        whether that account exists."""
        mine = http.get(MY_PROFILE_URL, headers=headers)
        theirs = http.get(peer_profile_url(active_user.id), headers=headers)

        assert mine.status_code == theirs.status_code == 404
        assert mine.json() == {"code": "not_found", "detail": "No profile yet."}
        assert theirs.json() == {
            "code": "not_found",
            "detail": "No profile for that user.",
        }

    def test_a_user_id_that_names_nobody_is_the_same_404_as_a_missing_profile(
        self, http, active_user, headers
    ):
        """A different answer here would turn the profile route into a directory of
        accounts the caller was never shown."""
        absent = http.get(peer_profile_url(uuid.uuid4()), headers=headers)
        pending = User.objects.create_user(username="pending", password=PASSWORD)
        deactivated = http.get(peer_profile_url(pending.id), headers=headers)

        assert absent.status_code == deactivated.status_code == 404
        assert absent.json() == deactivated.json()

    def test_a_peer_reads_the_version_the_owner_last_wrote(
        self, http, active_user, headers, bob, bearer
    ):
        bobs_device = Device.objects.create(
            user=bob,
            ik_pub=b"ik",
            spk_id=1,
            spk_pub=b"spk",
            spk_sig=b"sig",
            registration_id=4004,
        )
        http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0], fill=b"\x0f"), "version": 7},
            headers=headers,
        )

        response = http.get(
            peer_profile_url(active_user.id), headers=bearer(bob, bobs_device)
        )

        assert response.status_code == 200
        assert response.json()["version"] == 7
        assert base64.b64decode(response.json()["blob"]) == b"\x0f" * PROFILE_BUCKETS[0]


class TestWriteProfile:
    def test_stores_a_bucket_sized_blob(self, http, active_user, headers):
        response = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": 1},
            headers=headers,
        )

        assert response.status_code == 200
        assert response.content == b""
        stored = ProfileBlob.objects.get(user=active_user)
        assert len(bytes(stored.blob)) == PROFILE_BUCKETS[0]
        assert stored.version == 1

    @pytest.mark.parametrize(
        "size",
        [
            PROFILE_BUCKETS[0] - 1,
            PROFILE_BUCKETS[0] + 1,
            PROFILE_BUCKETS[-1] + 1,
            1,
        ],
    )
    def test_wrong_length_blob_is_bad_bucket(self, http, active_user, headers, size):
        response = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(size), "version": 1},
            headers=headers,
        )

        assert response.status_code == 400
        assert response.json()["code"] == "bad_bucket"
        assert not ProfileBlob.objects.filter(user=active_user).exists()

    def test_non_base64_blob_is_bad_bucket(self, http, active_user, headers):
        response = http.put(
            MY_PROFILE_URL,
            json={"blob": "definitely not base64 !!", "version": 1},
            headers=headers,
        )

        assert response.status_code == 400
        assert response.json()["code"] == "bad_bucket"

    def test_a_missing_version_is_an_invalid_request_not_a_bad_bucket(
        self, http, active_user, headers
    ):
        """The blob decodes only once every field has validated, so a body that
        fails both reports the field error rather than the payload one."""
        response = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0] + 1)},
            headers=headers,
        )

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"
        assert set(response.json()["detail"]) == {"version"}

    def test_bad_bucket_response_never_echoes_the_payload(
        self, http, active_user, headers
    ):
        payload = blob_of(PROFILE_BUCKETS[0] + 1, fill=b"\xab")

        response = http.put(
            MY_PROFILE_URL, json={"blob": payload, "version": 1}, headers=headers
        )

        assert payload not in response.text

    def test_version_must_increase(self, http, active_user, headers):
        http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": 5},
            headers=headers,
        )

        response = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": 5},
            headers=headers,
        )

        assert response.status_code == 409
        assert response.json()["code"] == "stale_version"

    def test_a_higher_version_overwrites(self, http, active_user, headers):
        http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": 1},
            headers=headers,
        )

        response = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[1], fill=b"\x09"), "version": 2},
            headers=headers,
        )

        assert response.status_code == 200
        stored = ProfileBlob.objects.get(user=active_user)
        assert stored.version == 2
        assert len(bytes(stored.blob)) == PROFILE_BUCKETS[1]

    def test_unknown_fields_are_rejected(self, http, active_user, headers):
        response = http.put(
            MY_PROFILE_URL,
            json={
                "blob": blob_of(PROFILE_BUCKETS[0]),
                "version": 1,
                "user_id": "someone-else",
            },
            headers=headers,
        )

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"

    def test_a_negative_version_is_rejected(self, http, active_user, headers):
        response = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": -1},
            headers=headers,
        )

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"

    def test_a_coerced_version_is_rejected(self, http, active_user, headers):
        """Strict mode: `true` and `"1"` both satisfy a lax `int` field and arrive
        as 1, so the stored version would be a value no client sent."""
        for version in (True, "1", 1.0):
            response = http.put(
                MY_PROFILE_URL,
                json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": version},
                headers=headers,
            )

            assert response.status_code == 400, version
            assert response.json()["code"] == "invalid_request"

    def test_the_first_version_may_be_zero_and_the_next_must_exceed_it(
        self, http, active_user, headers
    ):
        """Zero is a legal first version — the field is non-negative, not positive —
        and the monotonic rule then applies from there."""
        first = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": 0},
            headers=headers,
        )

        repeat = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": 0},
            headers=headers,
        )
        higher = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": 1},
            headers=headers,
        )

        assert first.status_code == 200
        assert repeat.status_code == 409
        assert higher.status_code == 200
        assert ProfileBlob.objects.get(user=active_user).version == 1

    def test_a_write_never_reaches_another_accounts_profile(
        self, http, active_user, headers, bob
    ):
        """The row is chosen by the principal on the token, so `PUT /me/profile`
        cannot be aimed at anybody."""
        ProfileBlob.objects.create(user=bob, blob=b"\x0b" * PROFILE_BUCKETS[0], version=2)

        response = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0], fill=b"\x0c"), "version": 3},
            headers=headers,
        )

        assert response.status_code == 200
        theirs = ProfileBlob.objects.get(user=bob)
        assert theirs.version == 2
        assert bytes(theirs.blob) == b"\x0b" * PROFILE_BUCKETS[0]
        assert ProfileBlob.objects.count() == 2
