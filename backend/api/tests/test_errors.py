"""The error envelope: one shape for every failure this surface can produce.

A client branches on `code` and never on prose, so the shape is the contract
(ADR-0007). Two halves here. The first drives every handler `errors.install`
registers on an application built for the purpose — the only way to reach the
undescribed `HTTPException`, the pool timeout and the unhandled failure without
breaking a real route. The second walks the real surface and asserts every
failure mode a client can actually provoke comes back in the same shape, with the
same headers, echoing none of what it refused.
"""

import base64
import json

import pytest
from django.db import OperationalError
from fastapi import FastAPI
from psycopg_pool import PoolTimeout
from pydantic import BaseModel, ConfigDict
from starlette.exceptions import HTTPException as StarletteHTTPException

from api import errors
from api.errors import ApiError, locator, validation_detail
from api.middleware import RESPONSE_HEADERS
from conftest import AsgiClient
from core.fields import BadBucket
from devices.models import Device

REGISTER_URL = "/api/v1/auth/register"
DISCOVERABILITY_URL = "/api/v1/me/discoverability"
PROFILE_URL = "/api/v1/me/profile"
GOOD_PASSWORD = "a-sufficiently-long-passphrase"
LEAKED = "device-8a1f-had-41-undelivered-envelopes"


class Body(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    name: str


@pytest.fixture
def isolated():
    """An application with this project's handlers and nothing else, so each
    handler can be reached on its own terms."""
    app = FastAPI()
    errors.install(app)

    @app.get("/refusal")
    async def refusal():
        raise ApiError(409, "username_taken", "That username is taken.")

    @app.get("/refusal-with-headers")
    async def refusal_with_headers():
        raise ApiError(429, "throttled", "Request was throttled.", {"Retry-After": "37"})

    @app.post("/validated")
    async def validated(payload: Body):
        return {"name": payload.name}

    @app.get("/off-bucket")
    async def off_bucket():
        raise BadBucket(LEAKED)

    @app.get("/teapot")
    async def teapot():
        raise StarletteHTTPException(status_code=418)

    @app.get("/saturated")
    async def saturated():
        failure = OperationalError("connection pool exhausted")
        failure.__cause__ = PoolTimeout("couldn't get a connection after 10.00 sec")
        raise failure

    @app.get("/dropped")
    async def dropped():
        raise OperationalError("server closed the connection unexpectedly")

    @app.get("/boom")
    async def boom():
        raise RuntimeError(LEAKED)

    return AsgiClient(app, app, reraise=False)


class TestEveryHandlerTheSurfaceInstalls:
    def test_an_api_error_renders_its_own_status_code_and_detail(self, isolated):
        response = isolated.get("/refusal")

        assert response.status_code == 409
        assert response.json() == {
            "code": "username_taken",
            "detail": "That username is taken.",
        }

    def test_an_api_error_carries_the_headers_it_was_raised_with(self, isolated):
        """`Retry-After` is the only part of a `429` a client can act on."""
        response = isolated.get("/refusal-with-headers")

        assert response.status_code == 429
        assert response.headers["retry-after"] == "37"

    def test_a_validation_failure_is_four_hundred_and_never_four_twenty_two(
        self, isolated
    ):
        """FastAPI's own handler answers `422` with a nested list. ADR-0007
        replaced it, and a `422` reaching a client is a contract break."""
        response = isolated.post("/validated", json={"name": 5})

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"
        assert response.json()["detail"] == {"name": ["Input should be a valid string"]}

    def test_an_off_bucket_payload_is_refused_without_echoing_it(self, isolated):
        """Invariant 4: an off-bucket payload is a `400 bad_bucket` and no echo."""
        response = isolated.get("/off-bucket")

        assert response.status_code == 400
        assert response.json() == {"code": "bad_bucket", "detail": "Invalid payload."}
        assert LEAKED not in response.text

    def test_an_http_exception_the_router_never_raises_is_a_server_error(self, isolated):
        """The rare case. Only `404` and `405` are described refusals; any other
        status arriving through this class is a defect in this codebase, and
        reporting it as a described refusal would hide it."""
        response = isolated.get("/teapot")

        assert response.status_code == 500
        assert response.json() == {"code": "server_error", "detail": "Internal error."}

    def test_a_pool_with_nothing_free_is_reported_as_unavailable(self, isolated):
        response = isolated.get("/saturated")

        assert response.status_code == 503
        assert response.json()["code"] == "unavailable"

    def test_any_other_operational_failure_stays_a_server_error(self, isolated):
        """Django wraps every psycopg `OperationalError` in one class, so the
        cause is what separates saturation from a defect."""
        response = isolated.get("/dropped")

        assert response.status_code == 500
        assert response.json()["code"] == "server_error"

    def test_an_unhandled_failure_carries_no_message_and_no_traceback(self, isolated):
        response = isolated.get("/boom")

        assert response.status_code == 500
        assert response.json() == {"code": "server_error", "detail": "Internal error."}
        assert LEAKED not in response.text


class TestTheFieldLocator:
    @pytest.mark.parametrize(
        "loc, expected",
        [
            (("body",), "body"),
            (("body", 0), "body"),
            (("body", 0, 3), "body"),
            (("body", "username"), "username"),
            (("body", "otpks", 0, "pub"), "otpks.0.pub"),
            (("query", "cursor"), "cursor"),
            (("header", "authorization"), "authorization"),
            (("path", "user_id"), "user_id"),
            (("cookie", "session"), "session"),
            (("username",), "username"),
            ((), ""),
        ],
        ids=[
            "the whole body",
            "a body that is a list",
            "a nested position",
            "a field",
            "a field of a list item",
            "a query parameter",
            "a header",
            "a path parameter",
            "a cookie",
            "no source marker",
            "nothing at all",
        ],
    )
    def test_the_path_is_walked_structurally_rather_than_read_by_index(
        self, loc, expected
    ):
        """A nested model and a list item must produce one path shape, and a
        failure that belongs to the whole body keeps `body` because it belongs to
        no field — which is also true of a body that is not JSON at all, whose
        location is a byte offset."""
        assert locator(loc) == expected


class TestTheValidationDetail:
    def test_every_message_of_one_field_is_kept_under_that_field(self):
        failures = [
            {"loc": ("body", "username"), "msg": "too short", "type": "x", "input": "s"},
            {"loc": ("body", "username"), "msg": "bad chars", "type": "y", "input": "s"},
            {"loc": ("body", "password"), "msg": "too common", "type": "z", "input": "s"},
        ]

        assert validation_detail(failures) == {
            "username": ["too short", "bad chars"],
            "password": ["too common"],
        }

    def test_the_value_the_client_sent_is_never_part_of_the_detail(self):
        """`input` is what the client sent, and no error body of this surface
        echoes input. `type` goes with it: it names a Pydantic internal that no
        client branches on."""
        failures = [
            {
                "loc": ("body", "password"),
                "msg": "This password is too common.",
                "type": "value_error",
                "input": LEAKED,
            }
        ]

        detail = validation_detail(failures)

        assert detail == {"password": ["This password is too common."]}
        assert LEAKED not in json.dumps(detail)


def off_bucket_blob():
    return base64.b64encode(b"q" * 7).decode()


def a_revoked_token(surface):
    Device.objects.filter(id=surface["device"].id).update(revoked_date="2026-01-01")
    return surface["http"].get(DISCOVERABILITY_URL, headers=surface["auth"])


def a_second_request_past_the_limit(surface):
    surface["http"].get(DISCOVERABILITY_URL, headers=surface["auth"])
    return surface["http"].get(DISCOVERABILITY_URL, headers=surface["auth"])


# code -> (status, the request that provokes it). Every mode a client can reach
# from outside; the three the client cannot provoke — `server_error`,
# `unavailable` and the undescribed refusal — are driven above.
FAILURES = {
    "invalid_request": (400, lambda s: s["http"].post(REGISTER_URL, json=[1, 2])),
    "bad_bucket": (
        400,
        lambda s: s["http"].put(
            PROFILE_URL, json={"blob": off_bucket_blob(), "version": 1}, headers=s["auth"]
        ),
    ),
    "unauthenticated": (401, lambda s: s["http"].get(DISCOVERABILITY_URL)),
    "invalid_token": (
        401,
        lambda s: s["http"].get(
            DISCOVERABILITY_URL, headers={"Authorization": "Bearer nope"}
        ),
    ),
    "token_revoked": (401, a_revoked_token),
    "scope_forbidden": (
        403,
        lambda s: s["http"].get(DISCOVERABILITY_URL, headers=s["register"]),
    ),
    "not_found": (404, lambda s: s["http"].get("/api/v1/no-such-route")),
    "method_not_allowed": (405, lambda s: s["http"].delete("/api/v1/health")),
    "username_taken": (
        409,
        lambda s: s["http"].post(
            REGISTER_URL, json={"username": "bob", "password": GOOD_PASSWORD}
        ),
    ),
    "payload_too_large": (
        413,
        lambda s: s["http"].post(
            REGISTER_URL,
            content=b"{" + b" " * (16 * 1024) + b"}",
            headers={"content-type": "application/json"},
        ),
    ),
    "throttled": (429, a_second_request_past_the_limit),
}


@pytest.mark.django_db(transaction=True)
class TestTheEnvelopeOnTheRealSurface:
    @pytest.fixture
    def surface(self, http, active_user, device, bob, bearer, register_bearer, settings):
        settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "accounts": "1/min"}
        return {
            "http": http,
            "device": device,
            "auth": bearer(active_user, device),
            "register": register_bearer(active_user),
        }

    @pytest.mark.parametrize("code", sorted(FAILURES))
    def test_every_failure_a_client_can_provoke_answers_one_shape(self, surface, code):
        status, provoke = FAILURES[code]

        response = provoke(surface)

        assert response.status_code == status
        body = response.json()
        assert set(body) == {"code", "detail"}
        assert body["code"] == code
        assert response.headers["content-type"].startswith("application/json")
        for name, value in RESPONSE_HEADERS:
            assert response.headers[name.decode()] == value.decode()

    @pytest.mark.parametrize("code", sorted(FAILURES))
    def test_the_detail_is_a_string_everywhere_but_a_validation_failure(
        self, surface, code
    ):
        """The one shape a client has to branch on, and the reason `ErrorOut`
        declares a union rather than a string."""
        _status, provoke = FAILURES[code]

        detail = provoke(surface).json()["detail"]

        if code == "invalid_request":
            assert isinstance(detail, dict)
            assert all(isinstance(key, str) for key in detail)
            assert all(
                isinstance(message, str)
                for messages in detail.values()
                for message in messages
            )
        else:
            assert isinstance(detail, str)


@pytest.mark.django_db(transaction=True)
class TestMalformedInput:
    """Nothing a client can send may reach a `500`, and nothing it sends may come
    back in the answer."""

    @pytest.mark.parametrize(
        "body",
        [[1, 2, 3], "a string", 5, None, True],
        ids=["a list", "a string", "a number", "null", "a boolean"],
    )
    def test_a_body_that_is_not_an_object_is_four_hundred(self, http, body):
        response = http.post(REGISTER_URL, json=body)

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"
        assert set(response.json()["detail"]) == {"body"}

    @pytest.mark.parametrize(
        "raw",
        [b"", b"{", b'{"username": }', b"\xff\xfe", b'{"username":"a\x00b"}'],
        ids=["empty", "truncated", "no value", "not utf-8", "a raw control character"],
    )
    def test_a_body_that_is_not_json_is_four_hundred(self, http, raw):
        response = http.post(
            REGISTER_URL, content=raw, headers={"content-type": "application/json"}
        )

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"

    @pytest.mark.parametrize(
        "payload",
        [
            {"username": 5, "password": GOOD_PASSWORD},
            {"username": ["bob"], "password": GOOD_PASSWORD},
            {"username": {"$ne": None}, "password": GOOD_PASSWORD},
            {"username": None, "password": GOOD_PASSWORD},
            {"username": "bob", "password": GOOD_PASSWORD, "is_staff": True},
            {"username": "bob"},
            {"username": "b" * 5000, "password": GOOD_PASSWORD},
            {"username": "a" + chr(0) + "b", "password": GOOD_PASSWORD},
            {"username": "bob\r\nSet-Cookie: x=1", "password": GOOD_PASSWORD},
        ],
        ids=[
            "a number for a string",
            "a list for a string",
            "an object for a string",
            "null for a string",
            "an unknown field",
            "a missing field",
            "an oversized string",
            "a null byte in a string",
            "a newline in a string",
        ],
    )
    def test_a_body_the_schema_refuses_is_four_hundred_and_never_five_hundred(
        self, http, payload
    ):
        response = http.post(REGISTER_URL, json=payload)

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"

    @pytest.mark.parametrize(
        "blob",
        ["not base64 at all", "===", "AAAA=AAA", ""],
        ids=["not base64", "padding only", "misplaced padding", "empty"],
    )
    def test_a_blob_that_is_not_base64_never_reaches_a_five_hundred(
        self, http, active_user, device, bearer, blob
    ):
        response = http.put(
            PROFILE_URL,
            json={"blob": blob, "version": 1},
            headers=bearer(active_user, device),
        )

        assert response.status_code == 400
        assert response.json()["code"] in {"invalid_request", "bad_bucket"}

    def test_the_refusal_never_repeats_what_it_refused(self, http):
        """No error body of this surface echoes input, so a rejected value cannot
        be reflected back into a client that renders it."""
        response = http.post(REGISTER_URL, json={"username": LEAKED, "password": LEAKED})

        assert response.status_code == 400
        assert LEAKED not in response.text
