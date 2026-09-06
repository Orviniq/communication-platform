"""The whole HTTP surface of voice: `POST /api/v1/me/relay`.

A relay credential is computed, never stored: coturn under `use-auth-secret` keeps
no account state, so a username is an expiry and a nonce and the password is an
HMAC over it under a secret the two processes share. That shapes everything here.
There is no row to assert against, so what is asserted instead is that the answer
is the four documented fields, that the credential is the one coturn will
recompute, that the username carries nothing that identifies the caller, and that
neither the credential nor the secret reaches a table or a log line.
"""

import base64
import hashlib
import hmac
import logging
import time

import pytest
from django.apps import apps

from ops.audit.log_silence import capture_all_logging
from realtime import relay

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)

RELAY_URL = "/api/v1/me/relay"
ENVELOPE_KEYS = {"code", "detail"}
FIELDS = {"urls", "username", "credential", "expires_in"}

# The configured relay of these tests: two `turn:` URLs in the order an operator
# would have written them, and an obvious test secret. Nothing outside this suite
# reads either — no coturn runs here and `.env` is not touched — so the secret is a
# fixed string rather than a generated one, which keeps the expected HMAC below
# something a reader can follow.
TURN_URLS = [
    "turn:relay.invalid:3478?transport=udp",
    "turn:relay.invalid:3478?transport=tcp",
]
TEST_TURN_SECRET = "turn-secret-for-tests-only-not-a-deployment-value"

# A clock far enough from any real one that a test reading it cannot pass by
# accident against `time.time()`.
FIXED_CLOCK = 1_800_000_000


@pytest.fixture(autouse=True)
def relay_configured(settings):
    """Voice is configured on by an operator filling these two in, so an
    unconfigured deployment is the default and every test but one turns it on."""
    settings.TURN_URLS = list(TURN_URLS)
    settings.TURN_STATIC_AUTH_SECRET = TEST_TURN_SECRET
    return settings


def table_counts():
    """Row counts across the whole schema, so "writes nothing" is asserted against
    every table rather than against the ones somebody remembered."""
    return {model._meta.label: model.objects.count() for model in apps.get_models()}


def expected_credential(username, secret=TEST_TURN_SECRET):
    """The TURN REST API password, recomputed here from the published rule.

    Written out rather than taken from `relay.credential_for`, because a test that
    calls the code it is checking agrees with it by construction: this is what
    coturn itself computes when it verifies the password, and if the two ever
    disagree the relay refuses every call while every test still passes.
    """
    digest = hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()
    return base64.b64encode(digest).decode()


def test_the_answer_is_the_four_documented_fields(
    http, active_user, device, bearer, settings
):
    """`urls` in the operator's order, because a client hands the list to
    `RTCPeerConnection` as written, and `expires_in` is the configured lifetime
    rather than a number the route invents."""
    response = http.post(RELAY_URL, headers=bearer(active_user, device))

    body = response.json()
    assert response.status_code == 200
    assert set(body) == FIELDS
    assert body["urls"] == TURN_URLS
    assert body["expires_in"] == settings.RELAY_CREDENTIAL_TTL_SECONDS


def test_the_credential_is_the_hmac_the_relay_will_recompute(
    http, active_user, device, bearer
):
    """The one thing that makes the credential usable at all. coturn recomputes
    base64 of HMAC-SHA1 over the username under the shared secret and compares; a
    credential under any other digest, encoding or key is one every allocation is
    refused with."""
    body = http.post(RELAY_URL, headers=bearer(active_user, device)).json()

    assert body["credential"] == expected_credential(body["username"])


def test_the_username_is_an_expiry_a_colon_and_sixteen_random_bytes(
    http, active_user, device, bearer, settings
):
    """The shape coturn parses: everything before the first colon is a Unix expiry
    it compares against its own clock, and everything after is opaque to it. A
    username whose expiry is already past is refused on arrival, so the window is
    asserted from both ends."""
    before = int(time.time())

    body = http.post(RELAY_URL, headers=bearer(active_user, device)).json()

    expiry, colon, nonce = body["username"].partition(":")
    assert colon == ":"
    assert expiry.isdigit()
    assert len(base64.urlsafe_b64decode(nonce)) == relay.USERNAME_RANDOM_BYTES
    lifetime = settings.RELAY_CREDENTIAL_TTL_SECONDS
    assert before + lifetime <= int(expiry) <= int(time.time()) + lifetime


def test_the_expiry_is_exactly_one_lifetime_past_the_moment_of_minting(settings):
    """The same claim without a window. `mint` carries a clock seam that no caller
    in the application passes, and with it the expiry is an equality rather than a
    range — which is what catches a lifetime added twice, or added to the wrong
    clock."""
    minted = relay.mint(now=FIXED_CLOCK)

    expiry = int(minted["username"].partition(":")[0])
    assert expiry == FIXED_CLOCK + settings.RELAY_CREDENTIAL_TTL_SECONDS


def test_the_username_carries_no_account_or_device_identifier(
    http, active_user, device, bearer
):
    """The username is the whole of what the credential tells coturn about a
    caller, and it travels in the clear on a control channel with no TLS. An account
    or device id in it would hand the relay a stable name for the device behind each
    call, and let anyone holding both the relay's view and the backend's join them
    by that name rather than by address and timing."""
    body = http.post(RELAY_URL, headers=bearer(active_user, device)).json()

    for label, identifier in (("account", active_user.id), ("device", device.id)):
        for spelling in (
            str(identifier),
            str(identifier).upper(),
            identifier.hex,
            identifier.hex.upper(),
            f"urn:uuid:{identifier}",
        ):
            assert spelling not in body["username"], f"the {label} id is in the username"


def test_two_calls_mint_two_credentials_that_both_verify(
    http, active_user, device, bearer
):
    """The retry safety the contract publishes. A client whose request times out
    calls again, and it must end up with two working credentials rather than one
    working and one that replaced it — nothing is stored, so nothing is
    invalidated, and the two must differ or the relay could link them."""
    headers = bearer(active_user, device)

    first = http.post(RELAY_URL, headers=headers).json()
    second = http.post(RELAY_URL, headers=headers).json()

    assert first["username"] != second["username"]
    assert first["credential"] != second["credential"]
    assert first["credential"] == expected_credential(first["username"])
    assert second["credential"] == expected_credential(second["username"])


def test_a_deployment_with_no_relay_answers_503_voice_unconfigured(
    http, active_user, device, bearer, settings
):
    """An empty `TURN_URLS` is a deployment that serves no voice, and the honest
    answer is the one a relay that is down would give — not a credential no relay
    would accept. The body is the envelope and nothing else: no half-built
    credential, and no hint of a URL or a secret the deployment does hold."""
    settings.TURN_URLS = []

    response = http.post(RELAY_URL, headers=bearer(active_user, device))

    assert response.status_code == 503
    assert set(response.json()) == ENVELOPE_KEYS
    assert response.json()["code"] == "voice_unconfigured"
    assert "turn:" not in response.text
    assert TEST_TURN_SECRET not in response.text


def test_a_request_with_no_token_is_401(http):
    response = http.post(RELAY_URL)

    assert response.status_code == 401
    assert response.json()["code"] == "unauthenticated"


def test_a_register_scope_token_is_403(http, active_user, register_bearer):
    """The token whose only power is adding a device does not place calls."""
    response = http.post(RELAY_URL, headers=register_bearer(active_user))

    assert response.status_code == 403
    assert response.json()["code"] == "scope_forbidden"


def test_the_relay_scope_is_the_counter_the_route_spends(
    http, active_user, device, bearer, settings
):
    """Only the `relay` entry is lowered, so a route counting against any other
    scope would answer 200 here. Minting is cheap — no row, no query of its own —
    but each credential is relay bandwidth on a host with one uplink, which is what
    the scope bounds."""
    settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "relay": "2/min"}
    headers = bearer(active_user, device)

    first = http.post(RELAY_URL, headers=headers)
    second = http.post(RELAY_URL, headers=headers)
    third = http.post(RELAY_URL, headers=headers)

    assert (first.status_code, second.status_code) == (200, 200)
    assert third.status_code == 429
    assert third.json()["code"] == "throttled"
    assert int(third.headers["Retry-After"]) > 0


def test_the_route_writes_nothing_at_all(http, active_user, device, bearer):
    """There is no issued-credential row and no per-device counter, and there must
    never be one: a table here would be a record of who placed a call and when,
    which is exactly what the voice design exists not to hold."""
    headers = bearer(active_user, device)
    before = table_counts()

    assert http.post(RELAY_URL, headers=headers).status_code == 200

    assert table_counts() == before


def test_the_answer_never_echoes_the_shared_secret(http, active_user, device, bearer):
    """The secret is the HMAC key, and it is the one value in this exchange that
    never travels: a client holding it could mint credentials for itself for as
    long as the deployment keeps the value."""
    response = http.post(RELAY_URL, headers=bearer(active_user, device))

    assert TEST_TURN_SECRET not in response.text
    assert TEST_TURN_SECRET not in str(dict(response.headers))


def test_no_credential_and_no_secret_reaches_a_log_line(
    http, active_user, device, bearer, settings
):
    """Invariant 4, on the one route that mints a bearer secret of its own. A
    minted credential in a log line is a credential anyone with the log can use
    until it expires, and the username beside it is the value coturn's own records
    would be joined on. The success and both refusals run inside one capture,
    because a refusal is where a logger normally appears."""
    headers = bearer(active_user, device)

    with capture_all_logging() as lines:
        logging.getLogger("test.canary").debug("canary")
        minted = http.post(RELAY_URL, headers=headers).json()
        anonymous = http.post(RELAY_URL)
        settings.TURN_URLS = []
        unconfigured = http.post(RELAY_URL, headers=headers)

    assert (anonymous.status_code, unconfigured.status_code) == (401, 503)
    assert any("canary" in line for line in lines), "log capture was not live"
    forbidden = {
        "minted username": minted["username"],
        "minted credential": minted["credential"],
        "relay secret": TEST_TURN_SECRET,
        "account id": str(active_user.id),
        "device id": str(device.id),
    }
    for line in lines:
        for label, secret in forbidden.items():
            assert secret not in line, f"{label} leaked into a log line: {line[:80]}"
