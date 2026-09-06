"""The route table of this API, and the gate that keeps it closed.

FastAPI has no project-wide permission default, so a route whose author forgot the
dependency is public and nothing reports it. This walks every route the
application serves and asserts that each one carries exactly the requirement the
phase records, that the requirement is resolved before the limiter that keys on
it, and that the table holds nothing else.
"""

import pytest
from fastapi.routing import iter_route_contexts

from api.auth import allow_anonymous, require_full_device, require_register_or_full
from config.asgi import api_application
from config.urls import ADMIN_PATH
from devices.routes import require_own_device

ANONYMOUS = allow_anonymous.__name__
FULL_DEVICE = require_full_device.__name__
REGISTER_OR_FULL = require_register_or_full.__name__
REQUIREMENTS = frozenset({ANONYMOUS, FULL_DEVICE, REGISTER_OR_FULL})

OWN_DEVICE = require_own_device.__name__

# (method, path) -> (authentication requirement, rate-limit scope or None).
# A route is closed by default: every entry is FULL_DEVICE unless it is one of
# the routes the phase records as declaring otherwise.
EXPECTED = {
    ("GET", "/api/v1/health"): (ANONYMOUS, None),
    ("GET", "/api/v1/config"): (FULL_DEVICE, "accounts"),
    ("POST", "/api/v1/auth/register"): (ANONYMOUS, "register"),
    ("POST", "/api/v1/auth/login"): (ANONYMOUS, "login"),
    ("POST", "/api/v1/auth/renew"): (FULL_DEVICE, "accounts"),
    ("POST", "/api/v1/auth/logout"): (FULL_DEVICE, "accounts"),
    # The one authenticated route that takes a password, and the only
    # irreversible one. It counts against `accounts` like every other route of
    # that app; the per-name cool-off is a second bound the scope does not give.
    ("DELETE", "/api/v1/me"): (FULL_DEVICE, "accounts"),
    ("GET", "/api/v1/users"): (FULL_DEVICE, "accounts"),
    ("GET", "/api/v1/users/{user_id}/profile"): (FULL_DEVICE, "accounts"),
    ("GET", "/api/v1/me/profile"): (FULL_DEVICE, "accounts"),
    ("PUT", "/api/v1/me/profile"): (FULL_DEVICE, "accounts"),
    ("GET", "/api/v1/me/keybackup"): (FULL_DEVICE, "accounts"),
    ("PUT", "/api/v1/me/keybackup"): (FULL_DEVICE, "accounts"),
    ("PUT", "/api/v1/me/identity"): (FULL_DEVICE, "accounts"),
    ("GET", "/api/v1/users/{user_id}/identity"): (FULL_DEVICE, "accounts"),
    # Registration is the one route a register-scope token reaches, and it is a
    # per-method opt-down: the device list on the same path stays full scope.
    ("POST", "/api/v1/me/devices"): (REGISTER_OR_FULL, "accounts"),
    ("GET", "/api/v1/me/devices"): (FULL_DEVICE, "accounts"),
    ("PUT", "/api/v1/me/devices/{device_id}"): (FULL_DEVICE, "accounts"),
    ("DELETE", "/api/v1/me/devices/{device_id}"): (FULL_DEVICE, "accounts"),
    ("PUT", "/api/v1/me/devices/{device_id}/prekeys"): (FULL_DEVICE, "accounts"),
    ("GET", "/api/v1/me/devices/{device_id}/prekeys/count"): (FULL_DEVICE, "accounts"),
    ("POST", "/api/v1/me/devicelog"): (FULL_DEVICE, "accounts"),
    ("GET", "/api/v1/users/{user_id}/devicelog"): (FULL_DEVICE, "accounts"),
    ("GET", "/api/v1/users/{user_id}/devices"): (FULL_DEVICE, "accounts"),
    ("POST", "/api/v1/peers"): (FULL_DEVICE, "accounts"),
    ("POST", "/api/v1/users/{user_id}/keys/claim"): (FULL_DEVICE, "claim"),
    ("POST", "/api/v1/envelopes"): (FULL_DEVICE, "envelopes"),
    ("GET", "/api/v1/me/envelopes"): (FULL_DEVICE, "envelopes"),
    ("POST", "/api/v1/me/envelopes/ack"): (FULL_DEVICE, "envelopes"),
    ("POST", "/api/v1/attachments"): (FULL_DEVICE, "attachments"),
    ("GET", "/api/v1/attachments/{attachment_id}"): (FULL_DEVICE, "attachments"),
    # The one HTTP route voice has. It reads no row and writes none: the
    # credential is computed from a shared secret, so the scope is what bounds
    # an account rather than anything the route stores.
    ("POST", "/api/v1/me/relay"): (FULL_DEVICE, "relay"),
}

# The routes whose path names a device the token itself must be. Recorded here
# rather than left to each handler, because a route that drops the gate reads
# exactly like one that never needed it.
OWN_DEVICE_ROUTES = frozenset(
    {
        ("PUT", "/api/v1/me/devices/{device_id}/prekeys"),
        ("GET", "/api/v1/me/devices/{device_id}/prekeys/count"),
    }
)

LIMITER_PREFIX = "rate_limit_"

# The paths FastAPI would add itself: the schema route and the interactive
# documentation. ADR-0020 closed all four in every mode, so the application
# registers none of them and `test_no_documentation_route_is_registered` is what
# keeps it that way.
DOCUMENTATION = {
    "/openapi.json",
    "/docs",
    "/docs/oauth2-redirect",
    "/redoc",
}


def served(app=api_application):
    """(method, path) -> the names of the dependencies the route declares.

    HTTP only. The `/ws` gateway declares no dependency because it authenticates
    on the handshake instead, and it is held by the two tests below rather than
    by this table.
    """
    table = {}
    for context in iter_route_contexts(app.routes):
        if context.methods is None:
            continue
        names = [dep.call.__name__ for dep in context.dependant.dependencies]
        for method in context.methods:
            table[(method, context.path)] = names
    return table


def registered_paths(app):
    return {context.path for context in iter_route_contexts(app.routes)}


def websocket_routes():
    return [
        context
        for context in iter_route_contexts(api_application.routes)
        if context.methods is None
    ]


def test_the_route_table_is_exactly_the_declared_one():
    assert set(served()) == set(EXPECTED)


def test_the_gateway_is_the_only_route_without_an_http_method():
    """A second WebSocket route would otherwise be invisible to every assertion in
    this file, because each one walks the HTTP table."""
    assert [context.path for context in websocket_routes()] == ["/ws"]


def test_the_gateway_declares_no_authentication_dependency():
    """A FastAPI dependency answers with an HTTP response, and a refused upgrade
    is not one: the gateway reads the `Authorization` header itself and refuses
    the handshake before the accept. `realtime/tests/test_auth.py` is the gate
    that proves it, with the same strength the HTTP requirement has."""
    declared = {dep.call.__name__ for dep in websocket_routes()[0].dependant.dependencies}

    assert declared & REQUIREMENTS == set()


@pytest.mark.parametrize("route", sorted(EXPECTED))
def test_every_route_declares_exactly_one_authentication_requirement(route):
    declared = {name for name in served()[route] if name in REQUIREMENTS}

    assert declared == {EXPECTED[route][0]}, route


@pytest.mark.parametrize("route", sorted(EXPECTED))
def test_every_route_counts_against_its_declared_scope(route):
    scopes = [
        name.removeprefix(LIMITER_PREFIX)
        for name in served()[route]
        if name.startswith(LIMITER_PREFIX)
    ]
    expected = EXPECTED[route][1]

    assert scopes == ([] if expected is None else [expected]), route


@pytest.mark.parametrize(
    "route", sorted(key for key, value in EXPECTED.items() if value[1] is not None)
)
def test_the_requirement_is_resolved_before_the_limiter(route):
    """The limiter keys an authenticated request on the account, which it can only
    read once the requirement has put the principal on the request."""
    names = served()[route]
    limiter = next(i for i, name in enumerate(names) if name.startswith(LIMITER_PREFIX))
    requirement = next(i for i, name in enumerate(names) if name in REQUIREMENTS)

    assert requirement < limiter, route


@pytest.mark.parametrize("route", sorted(EXPECTED))
def test_only_the_recorded_routes_gate_on_the_calling_device(route):
    """The own-device gate is an authorization dependency on top of the
    requirement, not a replacement for it: a route that carries it must still
    declare that it needs a full-scope token."""
    gated = OWN_DEVICE in served()[route]

    assert gated == (route in OWN_DEVICE_ROUTES), route


def test_only_the_recorded_routes_are_open():
    anonymous = {route for route, names in served().items() if ANONYMOUS in names}

    assert anonymous == {
        route for route, (kind, _scope) in EXPECTED.items() if kind == ANONYMOUS
    }


def test_the_django_application_answers_only_what_no_route_claims():
    """It is reached through the router's `default`, not a mount: a mount at "/"
    matches every path and would answer before the wrong-method refusal of a route
    this API serves."""
    assert not any(
        route.path == "/" for route in api_application.routes if hasattr(route, "path")
    )


def test_a_trailing_slash_is_never_a_redirect():
    """The redirect rebuilds an absolute address from the scope path and drops any
    prefix a proxy stripped, which turns a write into a lost request."""
    assert api_application.router.redirect_slashes is False


@pytest.mark.django_db(transaction=True)
def test_the_django_application_answers_the_admin_and_nothing_else(http):
    """The admin is the whole of what Django serves, so what this asserts is the
    composed topology and not Django alone."""
    admin = http.get(f"/{ADMIN_PATH}")
    assert admin.status_code == 302
    assert "login" in admin.headers["location"]

    # Not Django's HTML 404 page: an unclaimed path is this API's own envelope.
    stray = http.get("/api/v1/nothing-here")
    assert stray.status_code == 404
    assert stray.json() == {"code": "not_found", "detail": "No such route or resource."}
    assert stray.headers["content-type"].startswith("application/json")


@pytest.mark.parametrize("path", sorted(DOCUMENTATION))
@pytest.mark.django_db(transaction=True)
def test_no_documentation_route_is_registered(http, path):
    """The two interactive views render for a browser, which this product no
    longer has, and all four describe every route, model and parameter of a
    server whose posture is to reveal nothing (ADR-0020). The suite runs under the
    development settings, where FastAPI would open them by default, so this is the
    mode that would regress first: an unregistered path is this API's own
    `not_found` envelope, never a page that says a document exists somewhere.
    """
    assert path not in registered_paths(api_application)

    answer = http.get(path)
    assert answer.status_code == 404
    assert answer.json() == {"code": "not_found", "detail": "No such route or resource."}


def test_every_http_route_is_served_under_the_version_prefix():
    """A route registered outside `/api/v1` is one no client version covers and
    no future version can move: the prefix is the whole of this API's versioning
    scheme (ADR-0008)."""
    unversioned = sorted(
        path for _method, path in served() if not path.startswith("/api/v1/")
    )

    assert unversioned == []


def test_the_gateway_is_the_only_path_the_prefix_does_not_cover():
    """`/ws` is at the root because that is the path `realtime/API.md` publishes
    and the client already opens; it is recorded here rather than left as the one
    exception every reader has to rediscover."""
    outside = {
        path
        for path in registered_paths(api_application)
        if not path.startswith("/api/v1/")
    }

    assert outside == {"/ws"}


def test_no_method_and_path_is_registered_twice():
    """`served()` is a mapping, so a route registered a second time would replace
    the first and every assertion in this file would read the survivor. Two route
    objects on one method and path is a shadowed handler: the router matches the
    first and the second is unreachable, whatever it declares."""
    registered = []
    for context in iter_route_contexts(api_application.routes):
        if context.methods is None:
            continue
        registered.extend((method, context.path) for method in context.methods)

    duplicated = sorted({pair for pair in registered if registered.count(pair) > 1})

    assert duplicated == []
    assert len(registered) == len(EXPECTED)
