"""What every accounts route does with a body it cannot use.

One rule holds across the whole surface: a malformed request is a `400` carrying
the error envelope, and never a `500`. Two of the three bodies are anonymous
input, so a type confusion here would be an unauthenticated server error; that is
why the matrix below is a matrix rather than a spot check.

`transaction=True` because the ORM bracket of `api.orm.run_unit` closes the
connection around every unit of work, which under a wrapping test transaction
would sever the connection the test itself holds.
"""

import base64

import pytest

from accounts.models import ProfileBlob, User
from accounts.schemas import MAX_VERSION_INT
from core.buckets import PROFILE_BUCKETS

pytestmark = pytest.mark.django_db(transaction=True)

GOOD_PASSWORD = "a-sufficiently-long-passphrase"
REGISTER_URL = "/api/v1/auth/register"
LOGIN_URL = "/api/v1/auth/login"
RENEW_URL = "/api/v1/auth/renew"
LOGOUT_URL = "/api/v1/auth/logout"
DIRECTORY_URL = "/api/v1/users"
MY_PROFILE_URL = "/api/v1/me/profile"

# Every route of this app that reads a body, and whether it needs a credential.
BODY_ROUTES = [
    ("POST", REGISTER_URL, False),
    ("POST", LOGIN_URL, False),
    ("PUT", MY_PROFILE_URL, True),
]

NOT_OBJECTS = [[], ["username"], "a string", 5, 1.5, True, None]

MALFORMED_RAW = [
    (b"", "application/json"),
    (b"{", "application/json"),
    (b"not json at all", "application/json"),
    (b'{"username": }', "application/json"),
    (b"username=bob&password=x", "text/plain"),
]


def blob_of(nbytes, fill=b"\x00"):
    return base64.b64encode(fill * nbytes).decode()


def envelope(response, code):
    body = response.json()
    assert set(body) == {"code", "detail"}, body
    assert body["code"] == code, body
    return body


@pytest.fixture
def headers(active_user, device, bearer):
    return bearer(active_user, device)


def send(http, method, url, headers, **kwargs):
    return http.request(method, url, headers=headers, **kwargs)


class TestBodiesThatAreNotObjects:
    @pytest.mark.parametrize("method, url, needs_auth", BODY_ROUTES)
    @pytest.mark.parametrize("body", NOT_OBJECTS)
    def test_a_body_that_is_not_an_object_is_an_invalid_request(
        self, http, headers, method, url, needs_auth, body
    ):
        response = send(http, method, url, headers if needs_auth else None, json=body)

        assert response.status_code == 400
        envelope(response, "invalid_request")

    @pytest.mark.parametrize("method, url, needs_auth", BODY_ROUTES)
    @pytest.mark.parametrize("raw, content_type", MALFORMED_RAW)
    def test_a_body_that_is_not_json_is_an_invalid_request(
        self, http, headers, method, url, needs_auth, raw, content_type
    ):
        response = send(
            http,
            method,
            url,
            {**(headers if needs_auth else {}), "content-type": content_type},
            content=raw,
        )

        assert response.status_code == 400
        envelope(response, "invalid_request")

    def test_a_malformed_body_on_an_authenticated_route_is_still_a_401(self, http):
        """Authentication is resolved before the body is read, so an anonymous
        caller learns nothing about the shape of a body it may not send."""
        response = http.put(MY_PROFILE_URL, json=[])

        assert response.status_code == 401
        envelope(response, "unauthenticated")


class TestWrongTypesAndUnknownFields:
    @pytest.mark.parametrize(
        "url, payload",
        [
            (REGISTER_URL, {"username": ["bob"], "password": GOOD_PASSWORD}),
            (REGISTER_URL, {"username": "bob", "password": {"pw": GOOD_PASSWORD}}),
            (REGISTER_URL, {"username": None, "password": None}),
            (LOGIN_URL, {"username": {"$ne": None}, "password": GOOD_PASSWORD}),
            (LOGIN_URL, {"username": "alice", "password": GOOD_PASSWORD, "device_id": 7}),
        ],
    )
    def test_an_anonymous_route_refuses_a_wrong_type_without_a_server_error(
        self, http, url, payload
    ):
        response = http.post(url, json=payload)

        assert response.status_code == 400
        envelope(response, "invalid_request")

    @pytest.mark.parametrize(
        "payload",
        [
            {"blob": 5, "version": 1},
            {"blob": None, "version": 1},
            {"blob": blob_of(PROFILE_BUCKETS[0]), "version": "1"},
            {"blob": blob_of(PROFILE_BUCKETS[0])},
            {"version": 1},
            {},
        ],
    )
    def test_the_profile_write_refuses_a_wrong_type(self, http, headers, payload):
        response = http.put(MY_PROFILE_URL, json=payload, headers=headers)

        assert response.status_code == 400
        envelope(response, "invalid_request")
        assert not ProfileBlob.objects.exists()

    @pytest.mark.parametrize(
        "method, url, needs_auth, payload",
        [
            ("POST", REGISTER_URL, False, {"username": "bob", "password": GOOD_PASSWORD}),
            ("POST", LOGIN_URL, False, {"username": "alice", "password": GOOD_PASSWORD}),
            (
                "PUT",
                MY_PROFILE_URL,
                True,
                {"blob": blob_of(PROFILE_BUCKETS[0]), "version": 1},
            ),
        ],
    )
    def test_an_unknown_field_is_refused_on_every_body_route(
        self, http, headers, method, url, needs_auth, payload
    ):
        response = send(
            http,
            method,
            url,
            headers if needs_auth else None,
            json={**payload, "is_staff": True},
        )

        assert response.status_code == 400
        envelope(response, "invalid_request")

    def test_a_duplicate_key_settles_on_the_last_value_and_makes_one_account(self, http):
        """A JSON object with the same key twice is legal input a parser has to
        settle: this one keeps the last value, and the row that lands is that one
        and only that one."""
        response = http.post(
            REGISTER_URL,
            content=(
                b'{"username": "first", "username": "second",'
                b' "password": "a-sufficiently-long-passphrase"}'
            ),
            headers={"content-type": "application/json"},
        )

        assert response.status_code == 201
        assert User.objects.get(id=response.json()["user_id"]).username == "second"
        assert not User.objects.filter(username="first").exists()


class TestOversizedInput:
    @pytest.mark.parametrize(
        "method, url, needs_auth, payload, field",
        [
            (
                "POST",
                REGISTER_URL,
                False,
                {"username": "b" * 33, "password": GOOD_PASSWORD},
                "username",
            ),
            (
                "POST",
                REGISTER_URL,
                False,
                {"username": "bob", "password": "p" * 257},
                "password",
            ),
            (
                "POST",
                LOGIN_URL,
                False,
                {"username": "a" * 33, "password": GOOD_PASSWORD},
                "username",
            ),
            ("PUT", MY_PROFILE_URL, True, {"blob": "A" * 8193, "version": 1}, "blob"),
        ],
    )
    def test_an_oversized_string_is_refused_and_names_its_field(
        self, http, headers, method, url, needs_auth, payload, field
    ):
        response = send(http, method, url, headers if needs_auth else None, json=payload)

        assert response.status_code == 400
        assert set(envelope(response, "invalid_request")["detail"]) == {field}
        assert not User.objects.exclude(username="alice").exists()

    @pytest.mark.parametrize(
        "method, url, needs_auth, payload",
        [
            ("POST", REGISTER_URL, False, {"username": "bob"}),
            ("PUT", MY_PROFILE_URL, True, {"version": 1}),
        ],
    )
    def test_a_body_above_the_json_cap_is_payload_too_large(
        self, http, headers, method, url, needs_auth, payload
    ):
        """Counted as the bytes arrive, so the field caps above are never the
        thing that stops a 17 KiB body."""
        response = send(
            http,
            method,
            url,
            headers if needs_auth else None,
            json={**payload, "filler": "x" * (17 * 1024)},
        )

        assert response.status_code == 413
        envelope(response, "payload_too_large")


class TestUsernamesThatAreNotNames:
    @pytest.mark.parametrize(
        "name",
        [
            "bo\x00b",
            "bo\nb",
            "bo\rb",
            "bo\tb",
            "bo\x1bb",
            "bo\x7fb",
            "bo​b",  # ZERO WIDTH SPACE
            "bob",  # NEXT LINE
        ],
    )
    def test_a_control_character_in_a_registered_name_is_refused(self, http, name):
        response = http.post(
            REGISTER_URL, json={"username": name, "password": GOOD_PASSWORD}
        )

        assert response.status_code == 400
        assert set(envelope(response, "invalid_request")["detail"]) == {"username"}
        assert not User.objects.exists()

    @pytest.mark.parametrize(
        "name",
        [
            "аlice",  # CYRILLIC SMALL LETTER A
            "alicе",  # CYRILLIC SMALL LETTER IE
            "ａlice",  # FULLWIDTH LATIN SMALL LETTER A
            "\U0001d5eelice",  # MATHEMATICAL SANS-SERIF BOLD SMALL A
            "ⁱlice",  # SUPERSCRIPT LATIN SMALL LETTER I
        ],
    )
    def test_a_confusable_that_is_not_ascii_never_becomes_a_second_account(
        self, http, name, active_user
    ):
        response = http.post(
            REGISTER_URL, json={"username": name, "password": GOOD_PASSWORD}
        )

        assert response.status_code == 400
        assert set(envelope(response, "invalid_request")["detail"]) == {"username"}
        assert User.objects.count() == 1

    def test_a_control_character_in_a_password_survives_only_as_a_hash(self, http):
        """The rare body that is legal: the password rules bound length and
        commonness and nothing else, and what lands in the row is an Argon2id
        digest, so a byte the column could not hold never reaches it."""
        password = "pass\x00word-long"

        response = http.post(REGISTER_URL, json={"username": "zed", "password": password})

        assert response.status_code == 201
        account = User.objects.get(id=response.json()["user_id"])
        assert account.password.startswith("argon2$argon2id$")
        assert account.check_password(password) is True

    def test_a_confusable_that_folds_onto_ascii_collides_instead_of_twinning(self, http):
        """The rare one that matters: KELVIN SIGN lowercases to `k`, so this name
        passes the shape rule as `kell` — and lands on the account that already
        holds that name rather than beside it."""
        first = http.post(
            REGISTER_URL, json={"username": "kell", "password": GOOD_PASSWORD}
        )

        response = http.post(
            REGISTER_URL, json={"username": "Kell", "password": GOOD_PASSWORD}
        )

        assert first.status_code == 201
        assert response.status_code == 409
        envelope(response, "username_taken")
        assert User.objects.filter(username="kell").count() == 1

    @pytest.mark.parametrize("name", ["ali\nce", "ali\x7fce", "аlice", "a" * 32])
    def test_a_name_that_could_never_be_registered_is_wrong_credentials_at_login(
        self, http, name, active_user
    ):
        """Login validates the type of a name and nothing else: a shape refusal
        there would be an oracle for what is registered."""
        response = http.post(
            LOGIN_URL, json={"username": name, "password": GOOD_PASSWORD}
        )

        assert response.status_code == 401
        envelope(response, "invalid_credentials")

    def test_a_nul_in_a_name_is_wrong_credentials_and_never_a_server_error(
        self, http, active_user
    ):
        """The rare one, and the reason `login` guards the byte rather than the
        shape: PostgreSQL text carries no NUL, so psycopg refuses the lookup
        outright instead of returning no row. This was an unauthenticated 500 on
        anonymous input. It answers as every other unregistrable name does, so the
        fix adds no oracle."""
        response = http.post(
            LOGIN_URL, json={"username": "ali\x00ce", "password": GOOD_PASSWORD}
        )

        assert response.status_code == 401
        envelope(response, "invalid_credentials")
        assert User.objects.count() == 1


class TestProfilePayloads:
    @pytest.mark.parametrize(
        "size", [0, 1, 512, PROFILE_BUCKETS[0] - 1, PROFILE_BUCKETS[0] + 1, 6144]
    )
    def test_an_off_bucket_profile_is_a_bad_bucket_that_writes_nothing(
        self, http, headers, size
    ):
        response = http.put(
            MY_PROFILE_URL, json={"blob": blob_of(size), "version": 1}, headers=headers
        )

        assert response.status_code == 400
        assert envelope(response, "bad_bucket")["detail"] == "Invalid payload."
        assert not ProfileBlob.objects.exists()

    @pytest.mark.parametrize(
        "blob",
        [
            "definitely not base64 !!",
            "AAAA\nAAAA",
            "q83vEjRWeJ",
            "_" * 1368,
            "=" * 1368,
        ],
    )
    def test_a_blob_that_is_not_strict_base64_is_a_bad_bucket(self, http, headers, blob):
        response = http.put(
            MY_PROFILE_URL, json={"blob": blob, "version": 1}, headers=headers
        )

        assert response.status_code == 400
        envelope(response, "bad_bucket")
        assert blob not in response.text

    def test_the_refusal_echoes_neither_the_payload_nor_its_length(self, http, headers):
        payload = blob_of(PROFILE_BUCKETS[0] + 1, fill=b"\xab")

        response = http.put(
            MY_PROFILE_URL, json={"blob": payload, "version": 1}, headers=headers
        )

        assert response.status_code == 400
        assert payload not in response.text
        assert str(PROFILE_BUCKETS[0] + 1) not in response.text

    def test_the_version_column_takes_its_largest_value_and_refuses_one_past_it(
        self, http, headers, active_user
    ):
        """The boundary, from both sides. `version` lands in a 32-bit column, so
        the schema bounds it rather than letting the column raise: without the
        ceiling the larger integer reached psycopg as a DataError and the route
        answered 500 to input it exists to filter."""
        at_ceiling = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": MAX_VERSION_INT},
            headers=headers,
        )
        past_it = http.put(
            MY_PROFILE_URL,
            json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": MAX_VERSION_INT + 1},
            headers=headers,
        )

        assert at_ceiling.status_code == 200
        assert past_it.status_code == 400
        assert set(envelope(past_it, "invalid_request")["detail"]) == {"version"}
        assert ProfileBlob.objects.get(user=active_user).version == MAX_VERSION_INT


class TestRoutingRefusals:
    @pytest.mark.parametrize(
        "method, url, allowed",
        [
            ("GET", REGISTER_URL, "POST"),
            ("GET", LOGIN_URL, "POST"),
            ("GET", RENEW_URL, "POST"),
            ("DELETE", DIRECTORY_URL, "GET"),
            ("POST", MY_PROFILE_URL, "GET"),
        ],
    )
    def test_a_method_the_route_does_not_serve_is_a_405_with_an_allow_header(
        self, http, method, url, allowed
    ):
        response = http.request(method, url)

        assert response.status_code == 405
        envelope(response, "method_not_allowed")
        assert allowed in response.headers["allow"]

    @pytest.mark.parametrize(
        "url", [f"{LOGIN_URL}/", f"{DIRECTORY_URL}/", f"{MY_PROFILE_URL}/"]
    )
    def test_a_trailing_slash_is_a_refusal_and_never_a_redirect(self, http, url):
        """A redirect would rebuild an absolute address out of the scope path and
        drop whatever prefix the proxy stripped."""
        response = http.post(url, json={})

        assert response.status_code == 404
        envelope(response, "not_found")

    def test_the_directory_ignores_a_body_it_was_never_meant_to_read(self, http, headers):
        response = http.request("GET", DIRECTORY_URL, headers=headers, json=[1, 2, 3])

        assert response.status_code == 200
        assert [row["username"] for row in response.json()["users"]] == ["alice"]

    def test_renew_ignores_a_malformed_body(self, http, active_user, device, bearer):
        """The route takes no body, so a client that sends one anyway is served
        rather than refused on a payload nothing reads."""
        response = http.post(
            RENEW_URL,
            headers={**bearer(active_user, device), "content-type": "application/json"},
            content=b"{not json",
        )

        assert response.status_code == 200
        assert set(response.json()) == {"token", "expires_in"}

    def test_logout_ignores_a_malformed_body(self, http, active_user, device, bearer):
        response = http.post(
            LOGOUT_URL,
            headers={**bearer(active_user, device), "content-type": "application/json"},
            content=b"{not json",
        )

        assert response.status_code == 204
        device.refresh_from_db()
        assert device.token_generation == 2

    def test_a_second_logout_with_the_dead_token_is_refused_not_repeated(
        self, http, active_user, device, bearer
    ):
        auth = bearer(active_user, device)
        assert http.post(LOGOUT_URL, headers=auth).status_code == 204

        response = http.post(LOGOUT_URL, headers=auth)

        assert response.status_code == 401
        envelope(response, "token_revoked")
        device.refresh_from_db()
        assert device.token_generation == 2
