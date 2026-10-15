"""`GET` and `PUT /api/v1/me/discoverability`: the owner's "find me by username"
setting (ADR-0028).

On for every account, read and set by the account itself and by nothing else, and
set only by a JSON boolean. What it does to `POST /api/v1/users/lookup`, and what it
does not do to the routes addressed by a `user_id`, is held in `test_lookup.py`.
"""

import pytest

from accounts.models import User

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)

DISCOVERABILITY_URL = "/api/v1/me/discoverability"


@pytest.fixture
def headers(active_user, device, bearer):
    return bearer(active_user, device)


class TestTheSetting:
    def test_every_account_starts_discoverable(self, http, headers):
        response = http.get(DISCOVERABILITY_URL, headers=headers)

        assert (response.status_code, response.json()) == (200, {"discoverable": True})

    def test_a_repeat_is_the_same_answer_and_the_same_state(self, http, headers):
        first = http.put(
            DISCOVERABILITY_URL, headers=headers, json={"discoverable": False}
        )
        second = http.put(
            DISCOVERABILITY_URL, headers=headers, json={"discoverable": False}
        )

        assert first.json() == second.json() == {"discoverable": False}
        assert http.get(DISCOVERABILITY_URL, headers=headers).json() == {
            "discoverable": False
        }

    def test_it_changes_the_callers_account_and_no_other(
        self, http, headers, active_user, bob
    ):
        http.put(DISCOVERABILITY_URL, headers=headers, json={"discoverable": False})

        assert User.objects.get(pk=active_user.pk).discoverable is False
        assert User.objects.get(pk=bob.pk).discoverable is True

    @pytest.mark.parametrize(
        "body",
        [
            {},
            {"discoverable": "false"},
            {"discoverable": 0},
            {"discoverable": None},
            {"discoverable": False, "username": "bob"},
        ],
        ids=["missing", "a string", "an integer", "null", "an extra field"],
    )
    def test_only_a_json_boolean_is_an_answer(self, http, headers, active_user, body):
        """Strict: a client bug that sends `"false"` is refused rather than read as
        a choice the owner did not make — in either direction."""
        response = http.put(DISCOVERABILITY_URL, headers=headers, json=body)

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"
        assert User.objects.get(pk=active_user.pk).discoverable is True

    def test_a_register_token_reaches_neither_method(
        self, http, active_user, register_bearer
    ):
        scoped = register_bearer(active_user)

        read = http.get(DISCOVERABILITY_URL, headers=scoped)
        write = http.put(
            DISCOVERABILITY_URL, headers=scoped, json={"discoverable": False}
        )

        assert (read.status_code, write.status_code) == (403, 403)
        assert User.objects.get(pk=active_user.pk).discoverable is True
