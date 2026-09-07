"""The one issuer and the one verifier of a token, driven at its own layer.

`accounts/tests/test_device_auth.py` covers what the HTTP surface answers for a
token it refuses. This file covers the parser and the two loaders themselves: what
`decode` does with input nobody minted, what a revocation reaches, and that the
scope split holds on every route the application actually serves rather than on a
list somebody remembered to update.
"""

import base64
import json
import re
import uuid
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from django.conf import settings
from django.db import connection
from django.test.utils import CaptureQueriesContext
from fastapi.routing import iter_route_contexts
from hypothesis import given
from hypothesis import strategies as st
from starlette.requests import Request

from accounts.models import User
from api.auth import (
    bearer,
    decode,
    decode_session,
    issue_register_scope,
    issue_session,
    load_device,
    load_register_user,
    require_full_device,
)
from api.errors import ApiError
from config.asgi import api_application
from core.tests.test_route_table import EXPECTED
from core.tests.test_route_table import FULL_DEVICE as RECORDED_FULL_DEVICE
from devices.models import Device, UserIdentity

DIRECTORY_URL = "/api/v1/users"
DEVICES_URL = "/api/v1/me/devices"
RENEW_URL = "/api/v1/auth/renew"
LOGIN_URL = "/api/v1/auth/login"
LOGOUT_URL = "/api/v1/auth/logout"

# One account and one device, never saved: minting reads three attributes and
# touches no row, so the parser properties below need no database at all.
UNSAVED_USER = User(username="parser")
UNSAVED_DEVICE = Device(user=UNSAVED_USER, spk_id=1, registration_id=1)
SESSION, SESSION_TTL = issue_session(UNSAVED_USER, UNSAVED_DEVICE)
REGISTER, REGISTER_TTL = issue_register_scope(UNSAVED_USER)
REAL = (SESSION, REGISTER)


def unverified(raw):
    return jwt.decode(raw, options={"verify_signature": False})


MINTED_JTI = frozenset({unverified(SESSION)["jti"], unverified(REGISTER)["jti"]})
SESSION_JTI = frozenset({unverified(SESSION)["jti"]})


def segment(payload):
    return (
        base64.urlsafe_b64encode(json.dumps(payload, default=str).encode())
        .rstrip(b"=")
        .decode()
    )


def resigned(raw, key):
    """The same claims, signed with a key this deployment does not hold."""
    return jwt.encode(unverified(raw), key, algorithm=settings.JWT_ALGORITHM)


def unsigned(raw):
    """An `alg: none` token carrying the claims of a real one."""
    return f"{segment({'alg': 'none', 'typ': 'JWT'})}.{segment(unverified(raw))}."


def tampered(raw, **overrides):
    """A real signature over claims the holder edited."""
    claims = unverified(raw)
    claims.update(overrides)
    header, _payload, signature = raw.split(".")
    return f"{header}.{segment(claims)}.{signature}"


def swapped(raw, other):
    """One token's payload under another token's signature."""
    header, payload, _signature = raw.split(".")
    return f"{header}.{payload}.{other.split('.')[2]}"


TRUNCATIONS = [token[:cut] for token in REAL for cut in range(0, len(token), 7)]
FORGERIES = [
    *(unsigned(token) for token in REAL),
    *(resigned(token, "another-signing-key-of-at-least-32-bytes") for token in REAL),
    *(swapped(SESSION, REGISTER), swapped(REGISTER, SESSION)),
    tampered(SESSION, typ="root"),
    tampered(SESSION, typ="register"),
    tampered(SESSION, typ="access"),
    tampered(SESSION, tgen=99),
    tampered(SESSION, user_id=str(uuid.uuid4())),
    tampered(SESSION, device_id=str(uuid.uuid4())),
    tampered(REGISTER, typ="session"),
]


def presented():
    """Everything a client can put in an `Authorization` header, and then some:
    arbitrary bytes, arbitrary text, a real token cut short, a forgery, and the
    empty string."""
    return st.one_of(
        st.binary(max_size=96),
        st.text(max_size=96),
        st.sampled_from(TRUNCATIONS),
        st.sampled_from(FORGERIES),
        st.just(""),
        st.tuples(st.sampled_from(REAL), st.text(max_size=6)).map(lambda p: p[0] + p[1]),
    )


@pytest.mark.parametrize(
    "parse, minted, refusals",
    [
        (decode, MINTED_JTI, {(401, "invalid_token")}),
        (
            decode_session,
            SESSION_JTI,
            {(401, "invalid_token"), (403, "scope_forbidden")},
        ),
    ],
    ids=["decode", "decode_session"],
)
@given(raw=presented())
def test_the_parser_answers_claims_it_minted_or_the_projects_own_refusal(
    parse, minted, refusals, raw
):
    """The whole contract of the parser, over anything at all: it returns the
    claims of a token this process signed, or it raises one of the refusals that
    parser is allowed to raise — `401 invalid_token` for a token nobody minted,
    and for `decode_session` the `403 scope_forbidden` an authentic register
    token earns.

    Nothing else. An unhandled exception here is a `500` on an unauthenticated
    route, and a returned principal for input nobody minted is the authentication
    bypass this file exists to rule out.
    """
    try:
        claims = parse(raw)
    except ApiError as refusal:
        assert (refusal.status_code, refusal.code) in refusals
    else:
        assert claims["jti"] in minted


@given(raw=presented())
def test_a_bearer_header_is_never_more_than_a_string_handed_to_the_parser(raw):
    """`bearer` is the other half of the same surface: whatever it returns goes
    straight into the parser above, so it must return a string or raise the
    project's own `401`, for any header a client can send."""
    header = raw.decode("latin-1") if isinstance(raw, bytes) else raw
    request = Request(
        {
            "type": "http",
            "method": "GET",
            "path": DIRECTORY_URL,
            "headers": [(b"authorization", header.encode("latin-1", "replace"))],
        }
    )

    try:
        token = bearer(request)
    except ApiError as refusal:
        assert refusal.status_code == 401
        assert refusal.code == "unauthenticated"
    else:
        assert isinstance(token, str) and token == token.strip()


def request_with(*headers):
    return Request(
        {"type": "http", "method": "GET", "path": DIRECTORY_URL, "headers": list(headers)}
    )


def test_the_scheme_is_matched_without_case_and_the_token_is_stripped():
    """The normal path of `bearer`, which RFC 7235 makes case-insensitive."""
    assert bearer(request_with((b"authorization", b"bEaReR   a.b.c  "))) == "a.b.c"


def test_a_missing_authorization_header_carries_the_challenge():
    """A `401` with no `WWW-Authenticate` tells a client nothing about how to
    authenticate, and it is the one header this refusal owes."""
    with pytest.raises(ApiError) as raised:
        bearer(request_with())

    assert raised.value.status_code == 401
    assert raised.value.code == "unauthenticated"
    assert raised.value.headers == {"WWW-Authenticate": "Bearer"}


def test_a_token_with_an_internal_space_is_handed_to_the_parser_whole():
    """The rare case: only the first space separates the scheme, so the rest is
    the token and the parser is what refuses it."""
    assert (
        bearer(request_with((b"authorization", b"Bearer a.b.c d.e.f"))) == "a.b.c d.e.f"
    )


def test_a_session_token_that_names_no_device_is_refused():
    """The boundary between the two powers: a session token is device-bound, and
    one that claims the type without the binding is not a lesser token, it is a
    forged one."""
    claims = unverified(SESSION)
    del claims["device_id"]
    forged = jwt.encode(
        claims, settings.JWT_SIGNING_KEY, algorithm=settings.JWT_ALGORITHM
    )

    with pytest.raises(ApiError) as raised:
        decode_session(forged)

    assert raised.value.code == "invalid_token"


@pytest.mark.parametrize("tgen", ["3", 3.5, None, [3]])
def test_a_generation_that_is_not_an_integer_is_refused(tgen):
    """`tgen` is compared to a column, so a string that looks like a number would
    never equal it and a float would compare equal to the wrong thing."""
    forged = jwt.encode(
        {**unverified(SESSION), "tgen": tgen},
        settings.JWT_SIGNING_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )

    with pytest.raises(ApiError) as raised:
        decode_session(forged)

    assert raised.value.code == "invalid_token"


def test_an_authentic_register_token_is_a_scope_refusal_and_not_a_forgery():
    """`typ` alone separates the two powers, and the two refusals it produces are
    not interchangeable: an authentic token used past its power is a `403`, and a
    `401` there would tell its holder the token itself is broken."""
    # Minted here rather than taken from the module-level `REGISTER`, and this is
    # the only test of the file that needs the token to still verify: the others
    # assert on a broken signature, which is refused before the expiry is read, or
    # on claims read unverified. A register token lives
    # `REGISTER_SCOPE_ACCESS_MIN` minutes — ten by default — and the module
    # constants are built once at import, so on a host where the suite takes
    # longer than that to reach this test the token has expired and the parser
    # answers `401 invalid_token` before the scope check is ever reached. That is
    # the assertion this test exists to make, inverted by the clock. Measured on
    # the VPS, where the suite runs 38 minutes against 4 on a developer machine.
    register, _ = issue_register_scope(UNSAVED_USER)

    with pytest.raises(ApiError) as raised:
        decode_session(register)

    assert (raised.value.status_code, raised.value.code) == (403, "scope_forbidden")
    assert decode(register)["jti"] == unverified(register)["jti"]


def test_a_register_token_can_never_claim_its_way_up_to_a_session():
    """A session token is the only device-bound one. A register token that
    carried the type would reach every route its holder was deliberately not
    given, and the signature is what refuses it."""
    forged = f"{REGISTER.rsplit('.', 1)[0]}.{SESSION.rsplit('.', 1)[1]}"

    with pytest.raises(ApiError) as raised:
        decode_session(forged)

    assert raised.value.code == "invalid_token"


def test_an_expired_token_is_refused_at_the_parser():
    issued = datetime.now(timezone.utc) - timedelta(days=40)
    expired = jwt.encode(
        {**unverified(SESSION), "iat": issued, "exp": issued + timedelta(days=30)},
        settings.JWT_SIGNING_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )

    with pytest.raises(ApiError) as raised:
        decode_session(expired)

    assert raised.value.code == "invalid_token"


def test_each_issuer_publishes_the_lifetime_it_signed():
    """The client is told when to renew rather than left to read a claim set
    whose shape is this server's alone, so the published number and the signed
    `exp` cannot drift apart."""
    for raw, published in ((SESSION, SESSION_TTL), (REGISTER, REGISTER_TTL)):
        claims = unverified(raw)
        assert claims["exp"] - claims["iat"] == published

    assert SESSION_TTL == settings.SESSION_TOKEN_DAYS * 86400
    assert REGISTER_TTL == settings.REGISTER_SCOPE_ACCESS_MIN * 60


class TestTheLoaders:
    """`load_device` and `load_register_user`: the one query each dependency
    makes, and what it refuses to return."""

    pytestmark = pytest.mark.django_db(transaction=True)

    def test_the_device_its_owner_and_the_prune_watermark_are_one_query(
        self, active_user, device
    ):
        """Everything the dependency and the envelope drain need, read together.
        A second query here is a second round trip on every authenticated
        request in the system."""
        claims = decode_session(issue_session(active_user, device)[0])

        with CaptureQueriesContext(connection) as queries:
            loaded = load_device(claims)
            reachable = (loaded.user.is_active, loaded.queue_pruned_through)

        assert len(queries.captured_queries) == 1
        assert reachable == (True, device.queue_pruned_through)

    @pytest.mark.parametrize(
        "spoil",
        ["revoked", "deleted", "stale generation", "deactivated owner", "other account"],
    )
    def test_every_dead_device_is_reported_the_same_way(
        self, active_user, device, bob, spoil
    ):
        """One answer for five states, so a client learns only that this token is
        finished and never why."""
        claims = decode_session(issue_session(active_user, device)[0])
        if spoil == "revoked":
            Device.objects.filter(id=device.id).update(revoked_date="2026-01-01")
        elif spoil == "deleted":
            device.delete()
        elif spoil == "stale generation":
            Device.objects.filter(id=device.id).update(token_generation=99)
        elif spoil == "deactivated owner":
            User.objects.filter(id=active_user.id).update(is_active=False)
        else:
            claims["user_id"] = str(bob.id)

        assert load_device(claims) is None

    def test_a_register_scope_token_loads_only_an_activated_owner(self, active_user, bob):
        claims = decode(issue_register_scope(active_user)[0])

        assert load_register_user(claims).id == active_user.id

        User.objects.filter(id=active_user.id).update(is_active=False)
        assert load_register_user(claims) is None

    def test_a_register_scope_token_for_an_account_that_is_gone_loads_nothing(
        self, active_user
    ):
        claims = decode(issue_register_scope(active_user)[0])
        active_user.delete()

        assert load_register_user(claims) is None


@pytest.mark.django_db(transaction=True)
class TestRevocation:
    """One counter on the device row, and what it reaches.

    The behaviour lives partly in `accounts/services.py`, but what it protects is
    the token layer, so the assertions here are on `api/auth.py`'s own loaders as
    well as on the routes.
    """

    def test_a_renewal_ends_nothing_the_device_already_holds(
        self, http, active_user, device, bearer
    ):
        """No rotation and no reuse detection: the token that bought the new one
        is still a token, which is what lets two clients of one device renew
        without arbitrating between themselves."""
        headers = bearer(active_user, device)
        renewed = http.post(RENEW_URL, headers=headers).json()["token"]

        device.refresh_from_db()
        assert device.token_generation == 1
        assert load_device(decode_session(renewed)) is not None
        assert load_device(decode_session(headers["Authorization"].split()[1]))

    def test_a_login_leaves_the_token_the_device_already_holds_alive(
        self, http, active_user, device
    ):
        """The login writes no generation, so a token minted before it is still
        good after it."""
        older, _expires_in = issue_session(active_user, device)

        issued = http.post(
            LOGIN_URL,
            json={
                "username": active_user.username,
                "password": "correct-horse-battery-staple",
                "device_id": str(device.id),
            },
        ).json()

        assert load_device(decode_session(older)) is not None
        assert load_device(decode_session(issued["token"])) is not None

    def test_after_logout_every_token_of_the_device_is_dead(
        self, http, active_user, device
    ):
        """The token stays authentic — nothing about it changed — and the device
        row is what ends it. That is the whole of revocation without a token
        table."""
        token, _expires_in = issue_session(active_user, device)
        sibling, _sibling_expires_in = issue_session(active_user, device)
        headers = {"Authorization": f"Bearer {token}"}

        assert http.post(LOGOUT_URL, headers=headers).status_code == 204

        assert decode_session(token)["jti"]  # still parses: the signature is intact
        assert load_device(decode_session(token)) is None
        assert load_device(decode_session(sibling)) is None
        dead = http.get(DIRECTORY_URL, headers=headers)
        assert dead.status_code == 401
        assert dead.json()["code"] == "token_revoked"

    def test_a_second_logout_with_the_same_token_is_refused(
        self, http, active_user, device
    ):
        """The token that authorised the logout dies with every other token of
        the device, so the retry a client makes on a dropped connection answers
        `401` rather than revoking a generation nobody holds."""
        headers = {"Authorization": f"Bearer {issue_session(active_user, device)[0]}"}
        http.post(LOGOUT_URL, headers=headers)

        second = http.post(LOGOUT_URL, headers=headers)

        assert second.status_code == 401
        device.refresh_from_db()
        assert device.token_generation == 2


def full_scope_routes():
    """Every (method, path) the application serves behind `require_full_device`.

    Read off the route table itself, so a route added after this file is written
    is covered by it without anybody remembering to add a line.
    """
    for context in iter_route_contexts(api_application.routes):
        if context.methods is None:
            continue  # the `/ws` gateway
        names = [
            dependency.call.__name__ for dependency in context.dependant.dependencies
        ]
        if require_full_device.__name__ in names:
            for method in context.methods:
                yield method, context.path


FULL_SCOPE_ROUTES = sorted(full_scope_routes())
PARAMETER = re.compile(r"\{[^}]+\}")


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize("method, path", FULL_SCOPE_ROUTES)
def test_a_register_scope_token_reaches_no_full_scope_route(
    http, active_user, register_bearer, method, path
):
    """The scope split, walked over the real table. Every path parameter is a
    UUID this account does not own, and no body is sent: the requirement is
    resolved before either is looked at, so a `403` here is the scope check and
    nothing else."""
    url = PARAMETER.sub(str(uuid.uuid4()), path)

    response = http.request(method, url, headers=register_bearer(active_user))

    assert response.status_code == 403, f"{method} {path} admitted a register token"
    assert response.json()["code"] == "scope_forbidden"


def test_the_walk_finds_every_route_the_phase_recorded_as_full_scope():
    """Anti-vacuity for the walk above: a table that came back empty, or short,
    would pass the parametrised test by never running it. Checked against the
    record `core/tests/test_route_table.py` keeps, which is the one place this
    project writes down what each route is supposed to require."""
    recorded = {
        route
        for route, (requirement, _scope) in EXPECTED.items()
        if requirement == RECORDED_FULL_DEVICE
    }

    assert set(FULL_SCOPE_ROUTES) == recorded
    assert ("POST", "/api/v1/me/devices") not in FULL_SCOPE_ROUTES


@pytest.mark.django_db(transaction=True)
def test_the_same_register_scope_token_still_registers_a_device(
    http, active_user, register_bearer
):
    """Guards the guard: if the token were simply invalid, every `403` above
    would pass for the wrong reason."""
    payload = {
        "ik_pub": base64.b64encode(b"i" * 32).decode(),
        "spk_id": 1,
        "spk_pub": base64.b64encode(b"s" * 32).decode(),
        "spk_sig": base64.b64encode(b"g" * 32).decode(),
        "registration_id": 4242,
        "otpks": [{"key_id": 1, "pub": base64.b64encode(b"o" * 32).decode()}],
    }

    response = http.post(DEVICES_URL, json=payload, headers=register_bearer(active_user))

    assert response.status_code == 201


def device_payload(registration_id=4242):
    """The smallest body `POST /me/devices` accepts."""
    return {
        "ik_pub": base64.b64encode(b"i" * 32).decode(),
        "spk_id": 1,
        "spk_pub": base64.b64encode(b"s" * 32).decode(),
        "spk_sig": base64.b64encode(b"g" * 32).decode(),
        "registration_id": registration_id,
        "otpks": [{"key_id": 1, "pub": base64.b64encode(b"o" * 32).decode()}],
    }


@pytest.mark.django_db(transaction=True)
class TestTheRegistrationRequirement:
    """`require_register_or_full` is declared on one route, and it admits both
    scopes: the account with no device yet, and the account adding its second."""

    def test_a_full_scope_token_reaches_the_registration_route_as_well(
        self, http, active_user, device, bearer
    ):
        """The second-device case. The principal it builds carries the calling
        device, where a register-scope token's carries none."""
        UserIdentity.objects.create(
            user=active_user,
            master_pub=b"m" * 32,
            self_signing_pub=b"s" * 32,
            user_signing_pub=b"u" * 32,
            master_sig=b"g" * 64,
            version=1,
        )

        response = http.post(
            DEVICES_URL, json=device_payload(5150), headers=bearer(active_user, device)
        )

        assert response.status_code == 201
        assert Device.objects.filter(user=active_user).count() == 2

    def test_a_register_scope_token_for_a_deactivated_account_is_refused(
        self, http, active_user, register_bearer
    ):
        """The token names no device, so the two generation counters have nothing
        to say here and the account's own state is the whole of the check."""
        headers = register_bearer(active_user)
        User.objects.filter(id=active_user.id).update(is_active=False)

        response = http.post(DEVICES_URL, json=device_payload(5152), headers=headers)

        assert response.status_code == 401
        assert response.json()["code"] == "token_revoked"
        assert not Device.objects.filter(user=active_user).exists()

    def test_a_full_scope_token_whose_device_is_gone_is_refused_there_too(
        self, http, active_user, device, bearer
    ):
        """The one route a register token reaches is not a way around revocation:
        a full-scope token presented here is loaded exactly as it is anywhere
        else."""
        headers = bearer(active_user, device)
        Device.objects.filter(id=device.id).update(revoked_date="2026-01-01")

        response = http.post(DEVICES_URL, json=device_payload(5151), headers=headers)

        assert response.status_code == 401
        assert response.json()["code"] == "token_revoked"
        assert Device.objects.filter(user=active_user).count() == 1


@pytest.mark.django_db(transaction=True)
def test_an_anonymous_route_counts_its_caller_by_address_and_never_by_account(http):
    """`allow_anonymous` is a declaration, not a no-op: it puts `None` on the
    request where the requirement would put a principal, and the limiter reads
    that to decide whether it counts an account or an address."""
    import redis
    from django.conf import settings as django_settings

    http.post(LOGIN_URL, json={"username": "ghost", "password": "a-long-passphrase"})

    store = redis.Redis.from_url(django_settings.REDIS_URL)
    try:
        counted = store.keys("ratelimit:login:*")
    finally:
        store.close()
    assert len(counted) == 1
    assert counted[0].startswith(b"ratelimit:login:addr:")
