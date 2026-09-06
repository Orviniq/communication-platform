"""Nothing the API layer refuses reaches a log line.

The per-app suites cover their own payloads; this one covers the layer in front of
all of them, which is where invariant 6 is easiest to break — every refusal here
holds a credential, an address, or a request path, and every one of them is
written by code that never sees a route.

The capture replaces every handler, so the configured `ScrubFilter` never runs on
what it collects. That is deliberate: the filter mutates records in place on the
console handler, so a capture behind it would grade the scrubber rather than the
code. The scrubber is a backstop; what these tests assert is that nothing is
emitted in the first place.
"""

import logging

import pytest

from api.auth import issue_register_scope, issue_session
from api.middleware import RESPONSE_HEADERS
from config.asgi import api_application, application
from conftest import PASSWORD, AsgiClient
from devices.models import Device
from messaging import services
from ops.audit.log_silence import capture_all_logging

pytestmark = pytest.mark.django_db(transaction=True)

DIRECTORY_URL = "/api/v1/users"
LOGIN_URL = "/api/v1/auth/login"
MARKED_PATH = "/api/v1/no-such-route-b3f1c9a7"
CALLER = "198.51.100.23"
FORGED = "forged.token.b3f1c9a7d2e4"


def scan(lines, secrets):
    return [
        f"{label} leaked into: {line[:160]}"
        for line in lines
        for label, secret in secrets.items()
        if str(secret) in line
    ]


def test_every_refusal_this_layer_writes_leaks_nothing(
    http, active_user, device, bearer, settings
):
    """One pass over every failure the API layer answers on its own: the two
    token refusals, the scope refusal, the routing refusals, the unknown host,
    the oversized body and the throttle."""
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "accounts": "1/min"}
    access, _expires_in = issue_session(active_user, device)
    register, _register_expires_in = issue_register_scope(active_user)
    oversized = "z" * (17 * 1024)

    with capture_all_logging() as lines:
        anonymous = http.get(DIRECTORY_URL)
        forged = http.get(DIRECTORY_URL, headers={"Authorization": f"Bearer {FORGED}"})
        scoped_out = http.get(
            DIRECTORY_URL, headers={"Authorization": f"Bearer {register}"}
        )
        missing = http.get(MARKED_PATH)
        wrong_method = http.delete("/api/v1/health")
        unknown_host = http.get("/api/v1/health", headers={"Host": CALLER})
        too_large = http.post(
            LOGIN_URL, json={"username": "alice", "password": oversized}
        )
        http.get(DIRECTORY_URL, headers={"Authorization": f"Bearer {access}"})
        throttled = http.get(DIRECTORY_URL, headers={"Authorization": f"Bearer {access}"})

    assert [
        anonymous.status_code,
        forged.status_code,
        scoped_out.status_code,
        missing.status_code,
        wrong_method.status_code,
        unknown_host.status_code,
        too_large.status_code,
        throttled.status_code,
    ] == [401, 401, 403, 404, 405, 400, 413, 429]
    assert (
        scan(
            lines,
            {
                "session token": access,
                "register-scope token": register,
                "forged token": FORGED,
                "caller account id": str(active_user.id),
                "caller device id": str(device.id),
                "requested path": MARKED_PATH,
                "unknown host": CALLER,
                "oversized body": oversized[:64],
            },
        )
        == []
    )


def test_a_password_never_reaches_a_log_line(http, active_user):
    """The one credential a client sends in a body rather than a header, on the
    one route that reads it. A refused login and an accepted one both."""
    with capture_all_logging() as lines:
        wrong = http.post(
            LOGIN_URL, json={"username": "alice", "password": "the-wrong-passphrase"}
        )
        right = http.post(LOGIN_URL, json={"username": "alice", "password": PASSWORD})

    assert wrong.status_code == 401
    assert right.status_code == 200
    assert (
        scan(lines, {"password": PASSWORD, "wrong password": "the-wrong-passphrase"})
        == []
    )


def test_a_revoked_token_is_refused_without_naming_the_device(
    http, active_user, device, bearer
):
    """The refusal that reads a row: the loader has the device id and the account
    id in hand at the moment it decides, which is exactly when a debugging line
    gets added."""
    headers = bearer(active_user, device)
    Device.objects.filter(id=device.id).update(revoked_date="2026-01-01")

    with capture_all_logging() as lines:
        refused = http.get(DIRECTORY_URL, headers=headers)

    assert refused.status_code == 401
    assert scan(lines, {"device id": device.id, "account id": active_user.id}) == []


def test_an_unhandled_failure_is_rendered_without_logging_what_it_carried(
    active_user, device, bearer, monkeypatch
):
    """The `500` handler renders a fixed string, and this is the other half of
    that: the exception it swallowed must not arrive in the journal either, with
    its message or with the traceback frames around it.

    Read off the wire through a transport that does not re-raise, because every
    other suite drives this surface through one that does.
    """
    secret = "device-8a1f-had-41-undelivered-envelopes"

    def explode(*_args, **_kwargs):
        raise RuntimeError(secret)

    monkeypatch.setattr(services, "drain", explode)
    client = AsgiClient(application, api_application, reraise=False)

    with capture_all_logging() as lines:
        response = client.get("/api/v1/me/envelopes", headers=bearer(active_user, device))

    assert response.status_code == 500
    assert response.json() == {"code": "server_error", "detail": "Internal error."}
    for header, value in RESPONSE_HEADERS:
        assert response.headers[header.decode()] == value.decode()
    assert scan(lines, {"exception message": secret}) == []


def test_the_capture_is_live_and_unscrubbed(active_user):
    """Guards the guards above. A clean refusal logs nothing at all, so a scan
    over an empty list would pass no matter what the code emitted; and a capture
    behind the console handler would read `[ID]` where the leak was and pass for
    the second wrong reason."""
    with capture_all_logging() as lines:
        logging.getLogger("api.tests.canary").debug("user %s", active_user.id)

    assert scan(lines, {"account id": active_user.id}) != []
