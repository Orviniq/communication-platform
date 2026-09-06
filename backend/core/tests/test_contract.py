"""Every answer `backend/openapi.json` declares, produced by the running surface.

`core/tests/artefact.py` reads the committed document and lists the 216
`(method, template, status)` triples it declares. A document may declare a status
no code path can reach, and nothing in the drift gate would notice: the gate
proves the document matches the *routes*, not that the surface can actually
answer what the document promises a client. A client that branches on a status
this server never sends is a client with dead code, and one that meets a status
the document never mentioned is a client that crashes.

So the table below drives the composed application until it answers each of those
triples, and holds every one of those responses to the artefact with
`artefact.check`. Six seams make most of the table mechanical — the unhandled
failure, the dependency that is down, the throttle, the oversized body, the
missing credential and the wrong scope are the same request with one thing
changed, so each is written once and applied to every operation whose document
declares it. What is left is the per-route half: the success, the empty read, the
stale version, the conditional request.

The property run at the foot of the file goes the other way. It builds Hypothesis
strategies out of the document's own request schemas and fires generated bodies —
whole, and then deliberately broken — at every operation that takes one, asserting
only what the contract itself promises: never a `500`, never a status the document
does not declare, never a body that fails the document's schema, and never an echo
of what the client sent.
"""

import base64
import dataclasses
import functools

import anyio
import pytest
from fastapi.routing import iter_route_contexts
from hypothesis import given
from hypothesis import settings as hypothesis_settings
from hypothesis import strategies as st

from accounts.models import ProfileBlob, User
from api import app as api_app
from api.app import create_app, wrap
from attachments.models import Attachment
from config.asgi import api_application, application, django_asgi_app
from conftest import PASSWORD, AsgiClient
from core.buckets import (
    ATTACHMENT_BUCKETS,
    BACKUP_BUCKETS,
    DEVICELOG_BUCKETS,
    ENVELOPE_BUCKETS,
    LABEL_BUCKETS,
    PROFILE_BUCKETS,
)
from core.tests import artefact
from devices.models import Device, UserIdentity
from vault.models import KeyBackup

# `transaction=True` because `api.orm.run_unit` closes the connection around every
# unit of work, which under a wrapping test transaction would sever the connection
# the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)

PREFIX = "/api/v1"
# A path segment that is syntactically not a UUID, for the routes whose `400` is a
# path parameter the document types as one.
NOT_A_UUID = "not-a-uuid"
# Carried by the exception the `500` seam raises and by the request the deadline
# seam never lets finish, so a body that leaked either would be visible.
UNSPEAKABLE = "device 8a1f had 41 undelivered envelopes"
# Short enough that a whole test stays under a second, long enough that the
# request is observably cut off at it rather than by chance.
DEADLINE_SECONDS = 0.05
# Nothing listens on port 1, so the limiter's first command raises `RedisError`
# and the route fails closed with `unavailable` (ADR-0010).
DEAD_REDIS = "redis://127.0.0.1:1/0"


def blob(nbytes):
    """Base64 of an opaque payload of exactly one bucket length."""
    return base64.b64encode(b"\x00" * nbytes).decode()


def key(nbytes):
    return base64.b64encode(b"\x01" * nbytes).decode()


IDENTITY_BODY = {
    "master_pub": key(32),
    "self_signing_pub": key(32),
    "user_signing_pub": key(32),
    "master_sig": key(64),
    "version": 4,
}
DEVICE_BODY = {
    "ik_pub": key(32),
    "spk_id": 1,
    "spk_pub": key(32),
    "spk_sig": key(64),
    "registration_id": 11,
    "otpks": [{"key_id": 1, "pub": key(32)}],
}


@dataclasses.dataclass(frozen=True)
class Call:
    """One request, held apart from the client that sends it: the seams below take
    a well-formed call and change exactly one thing about it."""

    method: str
    path: str
    headers: dict | None = None
    body: dict = dataclasses.field(default_factory=dict)


def send(client, call):
    return client.request(call.method, call.path, headers=call.headers, **call.body)


def route_for(app, method, template):
    """The route context the application serves that operation with.

    Through `iter_route_contexts` rather than off `app.routes`, because an
    included router reaches the application as one object and the route that
    answers a request is the effective context it builds under the prefix — which
    is also the object that carries the dependant the handler calls. Matched on the
    method as well as the path: two routes share `/me/devices` and two share
    `/me/devices/{device_id}`.
    """
    for context in iter_route_contexts(app.routes):
        if context.path == template and method in (context.methods or ()):
            return context
    raise LookupError(f"{method} {template} is served by no route")


def scope_of(route):
    """The throttle scope the route counts against, read off the dependency name
    the limiter carries, or None for the one route with no limiter."""
    for dependency in route.dependant.dependencies:
        name = dependency.call.__name__
        if name.startswith("rate_limit_"):
            return name.removeprefix("rate_limit_")
    return None


def uuid_path_parameter(method, template):
    """The name of the path parameter the document types as a UUID, or None. The
    document is what says so, so a parameter that stops being a UUID stops being
    this operation's `400`."""
    operation = artefact.DOCUMENT["paths"][template][method.lower()]
    for parameter in operation.get("parameters", []):
        if parameter["in"] == "path" and parameter["schema"].get("format") == "uuid":
            return parameter["name"]
    return None


class Stage:
    """The world a driver drives against.

    Every row it needs is built on first touch and never twice, because the
    throttle seam sends the same sample call a second time and a driver that
    inserted its own fixture would fail on the repeat rather than on the status.
    """

    def __init__(self, http, monkeypatch, settings, user, device, bearer, register):
        self.http = http
        self.monkeypatch = monkeypatch
        self.settings = settings
        self.user = user
        self.device = device
        self._bearer = bearer
        self._register = register

    @functools.cached_property
    def auth(self):
        return self._bearer(self.user, self.device)

    @functools.cached_property
    def register_scope(self):
        """A register-scope token for the same account: the credential every
        full-scope route answers `scope_forbidden` to."""
        return self._register(self.user)

    @functools.cached_property
    def peer(self):
        """A second activated account. It never authenticates, so it is created
        with no usable password rather than paying for an Argon2 hash."""
        return User.objects.create_user(username="bob", is_active=True)

    @functools.cached_property
    def peer_device(self):
        return Device.objects.create(
            user=self.peer,
            ik_pub=b"peer-ik",
            spk_id=1,
            spk_pub=b"peer-spk",
            spk_sig=b"peer-signature",
            registration_id=2002,
        )

    @functools.cached_property
    def newcomer(self):
        """An activated account with no device: the state a register-scope token
        exists for, and the only one where adding a device needs no identity."""
        return User.objects.create_user(username="carol", is_active=True)

    @functools.cached_property
    def newcomer_scope(self):
        return self._register(self.newcomer)

    @functools.cached_property
    def my_profile(self):
        return ProfileBlob.objects.create(
            user=self.user, blob=b"p" * min(PROFILE_BUCKETS), version=1
        )

    @functools.cached_property
    def peer_profile(self):
        return ProfileBlob.objects.create(
            user=self.peer, blob=b"q" * min(PROFILE_BUCKETS), version=1
        )

    @functools.cached_property
    def my_backup(self):
        return KeyBackup.objects.create(
            user=self.user, blob=b"b" * min(BACKUP_BUCKETS), version=1
        )

    @functools.cached_property
    def peer_identity(self):
        return UserIdentity.objects.create(
            user=self.peer,
            master_pub=b"m" * 32,
            self_signing_pub=b"s" * 32,
            user_signing_pub=b"u" * 32,
            master_sig=b"g" * 64,
            version=1,
        )

    @functools.cached_property
    def attachment(self):
        return Attachment.objects.create(uploader=self.user, size=min(ATTACHMENT_BUCKETS))


@pytest.fixture
def stage(
    http, monkeypatch, settings, tmp_path, active_user, device, bearer, register_bearer
):
    """Uploads land in a temp directory, never the repository's `media_root`."""
    settings.ATTACHMENTS_ROOT = tmp_path
    return Stage(
        http, monkeypatch, settings, active_user, device, bearer, register_bearer
    )


# --- The table ------------------------------------------------------------------

# (method, template) -> the well-formed, authorised call for that operation. The
# seams below all start from it, so an operation is described once.
SAMPLES = {}
# (method, template, status) -> the driver that makes the surface answer it.
DRIVERS = {}


def sample(method, template, status):
    """Register the operation's canonical call, and the status it answers."""

    def register(build):
        SAMPLES[(method, template)] = build
        DRIVERS[(method, template, status)] = lambda stage: send(stage.http, build(stage))
        return build

    return register


def drives(method, template, status):
    def register(driver):
        DRIVERS[(method, template, status)] = driver
        return driver

    return register


# --- The canonical call of each operation, and the status it answers -------------


@sample("GET", f"{PREFIX}/health", "200")
def _health(stage):
    return Call("GET", f"{PREFIX}/health")


@sample("GET", f"{PREFIX}/config", "200")
def _config(stage):
    return Call("GET", f"{PREFIX}/config", stage.auth)


@sample("POST", f"{PREFIX}/auth/register", "201")
def _register(stage):
    return Call(
        "POST",
        f"{PREFIX}/auth/register",
        body={"json": {"username": "newcomer", "password": PASSWORD}},
    )


@sample("POST", f"{PREFIX}/auth/login", "200")
def _login(stage):
    return Call(
        "POST",
        f"{PREFIX}/auth/login",
        body={"json": {"username": stage.user.username, "password": PASSWORD}},
    )


@sample("POST", f"{PREFIX}/auth/renew", "200")
def _renew(stage):
    return Call("POST", f"{PREFIX}/auth/renew", stage.auth)


@sample("POST", f"{PREFIX}/auth/logout", "204")
def _logout(stage):
    return Call("POST", f"{PREFIX}/auth/logout", stage.auth)


@sample("GET", f"{PREFIX}/users", "200")
def _directory(stage):
    return Call("GET", f"{PREFIX}/users", stage.auth)


@sample("GET", PREFIX + "/users/{user_id}/profile", "200")
def _peer_profile(stage):
    stage.peer_profile
    return Call("GET", f"{PREFIX}/users/{stage.peer.id}/profile", stage.auth)


@sample("GET", f"{PREFIX}/me/profile", "200")
def _my_profile(stage):
    stage.my_profile
    return Call("GET", f"{PREFIX}/me/profile", stage.auth)


@sample("PUT", f"{PREFIX}/me/profile", "200")
def _write_profile(stage):
    return Call(
        "PUT",
        f"{PREFIX}/me/profile",
        stage.auth,
        {"json": {"blob": blob(min(PROFILE_BUCKETS)), "version": 9}},
    )


@sample("GET", f"{PREFIX}/me/keybackup", "200")
def _read_backup(stage):
    stage.my_backup
    return Call("GET", f"{PREFIX}/me/keybackup", stage.auth)


@sample("PUT", f"{PREFIX}/me/keybackup", "200")
def _write_backup(stage):
    return Call(
        "PUT",
        f"{PREFIX}/me/keybackup",
        stage.auth,
        {"json": {"blob": blob(min(BACKUP_BUCKETS)), "version": 9}},
    )


@sample("PUT", f"{PREFIX}/me/identity", "200")
def _publish_identity(stage):
    return Call("PUT", f"{PREFIX}/me/identity", stage.auth, {"json": IDENTITY_BODY})


@sample("GET", PREFIX + "/users/{user_id}/identity", "200")
def _peer_identity(stage):
    stage.peer_identity
    return Call("GET", f"{PREFIX}/users/{stage.peer.id}/identity", stage.auth)


@sample("POST", f"{PREFIX}/me/devices", "201")
def _register_device(stage):
    """Driven as the account a register-scope token belongs to: one with no device
    yet, which is the one case registration needs no published identity for."""
    return Call(
        "POST", f"{PREFIX}/me/devices", stage.newcomer_scope, {"json": DEVICE_BODY}
    )


@sample("GET", f"{PREFIX}/me/devices", "200")
def _own_devices(stage):
    return Call("GET", f"{PREFIX}/me/devices", stage.auth)


@sample("PUT", PREFIX + "/me/devices/{device_id}", "200")
def _relabel_device(stage):
    return Call(
        "PUT",
        f"{PREFIX}/me/devices/{stage.device.id}",
        stage.auth,
        {"json": {"label_blob": blob(min(LABEL_BUCKETS))}},
    )


@sample("DELETE", PREFIX + "/me/devices/{device_id}", "204")
def _revoke_device(stage):
    return Call("DELETE", f"{PREFIX}/me/devices/{stage.device.id}", stage.auth)


@sample("PUT", PREFIX + "/me/devices/{device_id}/prekeys", "200")
def _replenish(stage):
    return Call(
        "PUT",
        f"{PREFIX}/me/devices/{stage.device.id}/prekeys",
        stage.auth,
        {"json": {"otpks": [{"key_id": 1, "pub": key(32)}]}},
    )


@sample("GET", PREFIX + "/me/devices/{device_id}/prekeys/count", "200")
def _prekey_count(stage):
    return Call("GET", f"{PREFIX}/me/devices/{stage.device.id}/prekeys/count", stage.auth)


@sample("POST", f"{PREFIX}/me/devicelog", "201")
def _append_log(stage):
    return Call(
        "POST",
        f"{PREFIX}/me/devicelog",
        stage.auth,
        {"json": {"records": [{"blob": blob(min(DEVICELOG_BUCKETS))}]}},
    )


@sample("GET", PREFIX + "/users/{user_id}/devicelog", "200")
def _peer_log(stage):
    return Call("GET", f"{PREFIX}/users/{stage.peer.id}/devicelog", stage.auth)


@sample("GET", PREFIX + "/users/{user_id}/devices", "200")
def _peer_devices(stage):
    stage.peer_device
    return Call("GET", f"{PREFIX}/users/{stage.peer.id}/devices", stage.auth)


@sample("POST", f"{PREFIX}/peers", "200")
def _peer_state(stage):
    stage.peer_device
    return Call(
        "POST",
        f"{PREFIX}/peers",
        stage.auth,
        {"json": {"peers": [{"user_id": str(stage.peer.id)}]}},
    )


@sample("POST", PREFIX + "/users/{user_id}/keys/claim", "200")
def _claim(stage):
    return Call(
        "POST",
        f"{PREFIX}/users/{stage.peer.id}/keys/claim",
        stage.auth,
        {"json": {"device_ids": [str(stage.peer_device.id)]}},
    )


@sample("POST", f"{PREFIX}/envelopes", "202")
def _send_envelopes(stage):
    return Call(
        "POST",
        f"{PREFIX}/envelopes",
        stage.auth,
        {
            "json": {
                "messages": [
                    {
                        "device_id": str(stage.peer_device.id),
                        "blob": blob(min(ENVELOPE_BUCKETS)),
                    }
                ]
            }
        },
    )


@sample("GET", f"{PREFIX}/me/envelopes", "200")
def _drain(stage):
    return Call("GET", f"{PREFIX}/me/envelopes", stage.auth)


@sample("POST", f"{PREFIX}/me/envelopes/ack", "200")
def _ack(stage):
    return Call("POST", f"{PREFIX}/me/envelopes/ack", stage.auth, {"json": {"ids": []}})


@sample("POST", f"{PREFIX}/me/relay", "200")
def _relay_credential(stage):
    """The one sample that configures the deployment before it calls it.

    Every other operation answers its success on the settings the suite already
    runs under; this one answers `503 voice_unconfigured` unless `TURN_URLS` names
    a relay, because voice is configured on rather than off. The sample is what
    every seam starts from — the `429`, the `500` and the `503` all re-send it —
    so the configuration belongs here rather than in one driver.

    198.51.100.0/24 is the documentation range and nothing resolves it: the route
    reads the list to echo it back and never connects to it. The secret is a fixed
    test value that no process outside this suite reads.
    """
    stage.settings.TURN_URLS = ["turn:198.51.100.10:3478"]
    stage.settings.TURN_STATIC_AUTH_SECRET = "contract-suite-relay-secret-32ch"
    return Call("POST", f"{PREFIX}/me/relay", stage.auth)


@sample("POST", f"{PREFIX}/attachments", "201")
def _upload(stage):
    return Call(
        "POST",
        f"{PREFIX}/attachments",
        stage.auth,
        {"files": {"blob": ("blob", b"\x01" * min(ATTACHMENT_BUCKETS))}},
    )


@sample("GET", PREFIX + "/attachments/{attachment_id}", "200")
def _download(stage):
    return Call("GET", f"{PREFIX}/attachments/{stage.attachment.id}", stage.auth)


# --- The reads that find nothing -------------------------------------------------

MISSING_UUID = "00000000-0000-4000-8000-000000000000"
# A capability id is base64url of 32 random bytes; this one names no row.
MISSING_ATTACHMENT = "A" * 43


@drives("GET", PREFIX + "/attachments/{attachment_id}", "404")
def _no_such_attachment(stage):
    return stage.http.get(
        f"{PREFIX}/attachments/{MISSING_ATTACHMENT}", headers=stage.auth
    )


@drives("DELETE", PREFIX + "/me/devices/{device_id}", "404")
def _no_such_device_to_revoke(stage):
    return stage.http.delete(f"{PREFIX}/me/devices/{MISSING_UUID}", headers=stage.auth)


@drives("PUT", PREFIX + "/me/devices/{device_id}", "404")
def _no_such_device_to_relabel(stage):
    return stage.http.put(
        f"{PREFIX}/me/devices/{MISSING_UUID}",
        headers=stage.auth,
        json={"label_blob": blob(min(LABEL_BUCKETS))},
    )


@drives("GET", f"{PREFIX}/me/keybackup", "404")
def _no_backup_yet(stage):
    """The sample builds the row; this driver is the account before it has one."""
    return stage.http.get(f"{PREFIX}/me/keybackup", headers=stage.auth)


@drives("GET", f"{PREFIX}/me/profile", "404")
def _no_profile_yet(stage):
    return stage.http.get(f"{PREFIX}/me/profile", headers=stage.auth)


@drives("GET", PREFIX + "/users/{user_id}/identity", "404")
def _no_published_identity(stage):
    return stage.http.get(f"{PREFIX}/users/{MISSING_UUID}/identity", headers=stage.auth)


@drives("GET", PREFIX + "/users/{user_id}/profile", "404")
def _no_peer_profile(stage):
    return stage.http.get(f"{PREFIX}/users/{MISSING_UUID}/profile", headers=stage.auth)


# --- The writes that conflict with what is already stored ------------------------


@drives("POST", f"{PREFIX}/auth/register", "409")
def _username_taken(stage):
    return stage.http.post(
        f"{PREFIX}/auth/register",
        json={"username": stage.user.username, "password": PASSWORD},
    )


@drives("POST", f"{PREFIX}/me/devicelog", "409")
def _device_log_full(stage):
    """The ceiling is a deployment setting, so the log is driven against a
    deployment whose ceiling is zero rather than by writing ten thousand rows."""
    stage.settings.MAX_DEVICELOG_RECORDS = 0
    return stage.http.post(
        f"{PREFIX}/me/devicelog",
        headers=stage.auth,
        json={"records": [{"blob": blob(min(DEVICELOG_BUCKETS))}]},
    )


@drives("POST", f"{PREFIX}/me/devices", "409")
def _device_limit(stage):
    stage.settings.MAX_DEVICES_PER_USER = 1
    return stage.http.post(f"{PREFIX}/me/devices", headers=stage.auth, json=DEVICE_BODY)


@drives("PUT", PREFIX + "/me/devices/{device_id}/prekeys", "409")
def _prekey_limit(stage):
    """The stored cap, reached by storing it: the first call fills the pool to
    exactly the ceiling and the second asks for one key more."""
    path = f"{PREFIX}/me/devices/{stage.device.id}/prekeys"
    filled = stage.http.put(
        path,
        headers=stage.auth,
        json={"otpks": [{"key_id": i, "pub": key(32)} for i in range(200)]},
    )
    assert filled.status_code == 200, filled.text
    return stage.http.put(
        path, headers=stage.auth, json={"otpks": [{"key_id": 999, "pub": key(32)}]}
    )


def _write_then_rewind(stage, path, body):
    """Publish a version, then offer a lower one: the `stale_version` of the three
    versioned writes."""
    first = stage.http.put(path, headers=stage.auth, json={**body, "version": 5})
    assert first.status_code == 200, first.text
    return stage.http.put(path, headers=stage.auth, json={**body, "version": 1})


@drives("PUT", f"{PREFIX}/me/identity", "409")
def _stale_identity(stage):
    return _write_then_rewind(stage, f"{PREFIX}/me/identity", IDENTITY_BODY)


@drives("PUT", f"{PREFIX}/me/keybackup", "409")
def _stale_backup(stage):
    return _write_then_rewind(
        stage, f"{PREFIX}/me/keybackup", {"blob": blob(min(BACKUP_BUCKETS))}
    )


@drives("PUT", f"{PREFIX}/me/profile", "409")
def _stale_profile(stage):
    return _write_then_rewind(
        stage, f"{PREFIX}/me/profile", {"blob": blob(min(PROFILE_BUCKETS))}
    )


# --- The conditional reads -------------------------------------------------------


def _repeat_with_the_tag(stage, path):
    first = stage.http.get(path, headers=stage.auth)
    assert first.status_code == 200, first.text
    headers = {**stage.auth, "If-None-Match": first.headers["ETag"]}
    return stage.http.get(path, headers=headers)


@drives("GET", f"{PREFIX}/me/devices", "304")
def _own_devices_unchanged(stage):
    return _repeat_with_the_tag(stage, f"{PREFIX}/me/devices")


@drives("GET", PREFIX + "/users/{user_id}/devices", "304")
def _peer_devices_unchanged(stage):
    stage.peer_device
    return _repeat_with_the_tag(stage, f"{PREFIX}/users/{stage.peer.id}/devices")


@drives("GET", PREFIX + "/users/{user_id}/identity", "304")
def _peer_identity_unchanged(stage):
    stage.peer_identity
    return _repeat_with_the_tag(stage, f"{PREFIX}/users/{stage.peer.id}/identity")


# --- The three refusals the anonymous routes carry themselves --------------------


@drives("POST", f"{PREFIX}/auth/login", "401")
def _wrong_password(stage):
    return stage.http.post(
        f"{PREFIX}/auth/login",
        json={"username": stage.user.username, "password": "not-the-password"},
    )


@drives("POST", f"{PREFIX}/auth/login", "403")
def _account_awaiting_activation(stage):
    """Activation state becomes observable only once the password is proven, so
    the driver has to present the right one."""
    dormant = User.objects.create_user(
        username="dormant", password=PASSWORD, is_active=False
    )
    return stage.http.post(
        f"{PREFIX}/auth/login", json={"username": dormant.username, "password": PASSWORD}
    )


# --- The seams: one request, one thing changed -----------------------------------


async def explode(**_values):
    """Stands in for an endpoint. `async def` on purpose: FastAPI decides whether
    to await the endpoint or push it to a thread once, when the route is built, and
    every endpoint of this surface is a coroutine function."""
    raise RuntimeError(UNSPEAKABLE)


async def crawl(**_values):
    await anyio.sleep(DEADLINE_SECONDS * 20)
    raise AssertionError("the deadline should have cut this request off")


def an_unhandled_failure(stage, method, template):
    """`500` for any route. The endpoint is reached through the route's dependant,
    so replacing what it calls leaves the authentication, the limiter and the body
    validation exactly as they were — the failure is the handler's own."""
    call = SAMPLES[(method, template)](stage)
    route = route_for(api_application, method, template)
    stage.monkeypatch.setattr(route.dependant, "call", explode)
    reading = AsgiClient(application, api_application, reraise=False)
    response = send(reading, call)
    assert UNSPEAKABLE not in response.text
    return response


def an_unavailable_dependency(stage, method, template):
    """`503` for any route.

    A throttled route reaches Redis before it reaches its handler, and the limiter
    fails closed when the store is gone (ADR-0010). The one route with no limiter
    answers `503` at the request deadline instead, which is a property of the
    middleware stack and so needs the stack rebuilt around the shortened value.
    """
    call = SAMPLES[(method, template)](stage)
    if scope_of(route_for(api_application, method, template)) is not None:
        stage.settings.REDIS_URL = DEAD_REDIS
        return send(stage.http, call)
    stage.settings.REQUEST_DEADLINE_SECONDS = DEADLINE_SECONDS
    fresh = create_app(django_asgi_app)
    stage.monkeypatch.setattr(route_for(fresh, method, template).dependant, "call", crawl)
    response = send(AsgiClient(wrap(fresh), fresh, reraise=False), call)
    assert UNSPEAKABLE not in response.text
    return response


# The two operations whose sample cannot be sent twice: each ends the session the
# next call would authenticate with. They burn their scope on a route that shares
# it and leaves the token alone.
def _burn_the_accounts_scope(stage):
    return stage.http.get(f"{PREFIX}/users", headers=stage.auth)


BURNERS = {
    ("POST", f"{PREFIX}/auth/logout"): _burn_the_accounts_scope,
    ("DELETE", PREFIX + "/me/devices/{device_id}"): _burn_the_accounts_scope,
}


def a_throttled_call(stage, method, template):
    """`429` for any throttled route. The limiter reads the rate at request time,
    so a scope set to one request and then spent answers the next call from the
    same caller — before the handler, whatever the body says."""
    scope = scope_of(route_for(api_application, method, template))
    stage.settings.THROTTLE_RATES = {**stage.settings.THROTTLE_RATES, scope: "1/min"}
    burn = BURNERS.get((method, template))
    if burn is None:
        send(stage.http, SAMPLES[(method, template)](stage))
    else:
        burn(stage)
    return send(stage.http, SAMPLES[(method, template)](stage))


def an_oversized_body(stage, method, template):
    """`413` for any route that takes a body. The cap is frozen when the middleware
    stack is wrapped, so it is shrunk below every legal body and the stack rebuilt
    around the same application every other driver uses."""
    stage.settings.BODY_CAP_JSON_BYTES = 1
    stage.settings.BODY_CAP_BACKUP_BYTES = 1
    stage.settings.BODY_CAP_BATCH_BYTES = 1
    stage.settings.MULTIPART_OVERHEAD_BYTES = 0
    stage.monkeypatch.setattr(api_app, "ATTACHMENT_BUCKETS", [1])
    call = SAMPLES[(method, template)](stage)
    capped = AsgiClient(api_app.wrap(api_application), api_application)
    return send(capped, call)


def an_unauthenticated_call(stage, method, template):
    """`401` for any route behind a token: the same request with no credential."""
    call = SAMPLES[(method, template)](stage)
    return send(stage.http, dataclasses.replace(call, headers=None))


def a_forbidden_scope(stage, method, template):
    """`403` for any full-scope route: a register-scope token, whose only power is
    adding a device."""
    call = SAMPLES[(method, template)](stage)
    return send(stage.http, dataclasses.replace(call, headers=stage.register_scope))


def an_invalid_request(stage, method, template):
    """`400` for any route that validates something.

    A path parameter the document types as a UUID is the shortest route to it; an
    operation with none is driven with a body it cannot accept — every request
    model of this API forbids an unknown field, and the one multipart body refuses
    a JSON content type outright.
    """
    call = SAMPLES[(method, template)](stage)
    name = uuid_path_parameter(method, template)
    if name is not None:
        call = dataclasses.replace(call, path=template.replace(f"{{{name}}}", NOT_A_UUID))
    else:
        call = dataclasses.replace(call, body={"json": {"unexpected": "value"}})
    return send(stage.http, call)


SEAMS = {
    "400": an_invalid_request,
    "401": an_unauthenticated_call,
    "403": a_forbidden_scope,
    "413": an_oversized_body,
    "429": a_throttled_call,
    "500": an_unhandled_failure,
    "503": an_unavailable_dependency,
}

for _method, _template, _status in sorted(artefact.DECLARED):
    _key = (_method, _template, _status)
    if _key in DRIVERS or _status not in SEAMS:
        continue
    DRIVERS[_key] = functools.partial(SEAMS[_status], method=_method, template=_template)


# --- The walk --------------------------------------------------------------------


def held_to_the_document(response):
    """The template the response was matched to, once the artefact has judged it.

    Called on the response the driver produced rather than trusted to the client
    in `conftest.py`: a driver that stopped reaching the surface at all would
    otherwise pass by never producing a response to check.
    """
    template = artefact.check(
        response.request.method,
        response.request.url.path,
        response.status_code,
        response.headers.get("content-type", ""),
        response.content,
    )
    assert template is not None, response.request.url.path
    return template


@pytest.mark.parametrize(
    "case", sorted(DRIVERS), ids=lambda case: f"{case[0]} {case[1]} {case[2]}"
)
def test_the_surface_answers_every_status_the_document_declares(case, stage):
    method, template, status = case

    response = DRIVERS[case](stage)

    assert response.status_code == int(status), response.text
    assert held_to_the_document(response) == template


def test_every_declared_answer_has_a_driver_and_no_driver_invents_one():
    """The gate that keeps the table honest in both directions.

    A route or a status added to the document with no driver here is uncovered,
    and would stay uncovered in silence — the walk above only ever walks what the
    table holds. A driver for a triple the document does not declare is a test
    asserting a contract nobody published.
    """
    assert set(DRIVERS) == set(artefact.DECLARED)


# --- Generated bodies, out of the document's own request schemas -----------------

# The keywords the document constrains a request body with. A document that grows
# another one has to be handled here rather than silently under-tested, so
# anything outside these two sets stops the module at import.
KEYWORDS = frozenset(
    {
        "type",
        "properties",
        "required",
        "items",
        "minItems",
        "maxItems",
        "minLength",
        "maxLength",
        "minimum",
        "maximum",
        "anyOf",
        "const",
        "format",
        "additionalProperties",
        "$ref",
    }
)
# Annotations. They describe a value for a reader and constrain nothing, so a
# strategy that ignores them generates exactly the same set.
ANNOTATIONS = frozenset({"title", "description", "default", "contentMediaType"})

REFERENCE_PREFIX = "#/components/schemas/"
JSON_MEDIA = "application/json"
MULTIPART_MEDIA = "multipart/form-data"

# The generation budget, and the whole reason this file still fits inside its time
# bound. The document's own ceilings are a 256-item envelope batch, a 200-key
# prekey batch and a 1.4 MB backup blob; generating at that size would spend the
# run on serialising bodies rather than on reaching answers, and the sizes
# themselves are already the driver table's business — `413` and `409` are pinned
# there against the real caps. Twelve examples for each of the sixteen bodies,
# each sent whole and then in up to four broken forms, is about eight hundred
# requests and some seven seconds.
MAX_GENERATED_ITEMS = 2
MAX_GENERATED_CHARS = 24
EXAMPLES_PER_OPERATION = 12
# A generated string this long appearing verbatim in a response is an echo; a
# shorter one could be a coincidence inside a validation message, and an assertion
# that fires on a coincidence is an assertion nobody keeps.
ECHO_FLOOR = 8

# A property the document constrains in no way at all — `cross_sig` and
# `bundle_version` on the registration body, which are declared only so that
# sending either is answered rather than reported as an unknown field. Anything a
# client could put there is in range.
UNCONSTRAINED = st.one_of(
    st.none(),
    st.booleans(),
    st.integers(),
    st.text(max_size=MAX_GENERATED_CHARS),
)


def resolve(reference):
    assert reference.startswith(REFERENCE_PREFIX), reference
    return artefact.DOCUMENT["components"]["schemas"][
        reference.removeprefix(REFERENCE_PREFIX)
    ]


def bounded(schema, floor_key, ceiling_key, budget):
    """The size range to generate in: the document's floor, and the lower of its
    ceiling and the budget."""
    floor = schema.get(floor_key, 0)
    ceiling = min(schema.get(ceiling_key, budget), budget)
    return floor, max(floor, ceiling)


def strategy_for(schema):
    unknown = set(schema) - KEYWORDS - ANNOTATIONS
    if unknown:
        raise NotImplementedError(f"{artefact.ARTEFACT} grew {sorted(unknown)}")
    if "$ref" in schema:
        return strategy_for(resolve(schema["$ref"]))
    if "const" in schema:
        return st.just(schema["const"])
    if "anyOf" in schema:
        return st.one_of([strategy_for(member) for member in schema["anyOf"]])
    kind = schema.get("type")
    if kind == "object":
        extra = schema.get("additionalProperties", False)
        if extra is not False:
            raise NotImplementedError(f"{artefact.ARTEFACT} grew open objects")
        properties = schema.get("properties", {})
        required = set(schema.get("required", []))
        return st.fixed_dictionaries(
            {
                name: strategy_for(sub)
                for name, sub in properties.items()
                if name in required
            },
            optional={
                name: strategy_for(sub)
                for name, sub in properties.items()
                if name not in required
            },
        )
    if kind == "array":
        floor, ceiling = bounded(schema, "minItems", "maxItems", MAX_GENERATED_ITEMS)
        return st.lists(strategy_for(schema["items"]), min_size=floor, max_size=ceiling)
    if kind == "string":
        return _string_strategy(schema)
    if kind == "integer":
        return st.integers(
            min_value=int(schema["minimum"]) if "minimum" in schema else None,
            max_value=int(schema["maximum"]) if "maximum" in schema else None,
        )
    if kind == "boolean":
        return st.booleans()
    if kind == "null":
        return st.none()
    if kind is None:
        return UNCONSTRAINED
    raise NotImplementedError(f"{artefact.ARTEFACT} grew the type {kind}")


def _string_strategy(schema):
    fmt = schema.get("format")
    floor, ceiling = bounded(schema, "minLength", "maxLength", MAX_GENERATED_CHARS)
    if fmt == "uuid":
        # Generated as identifiers rather than as text, so a body reaches the
        # service instead of stopping at the parameter that names it.
        return st.uuids().map(str)
    if fmt == "binary":
        return st.binary(min_size=floor, max_size=ceiling)
    if fmt is not None:
        raise NotImplementedError(f"{artefact.ARTEFACT} grew the format {fmt}")
    return st.text(min_size=floor, max_size=ceiling)


def request_bodies():
    """(method, template) -> (media type, schema) for every operation that takes a
    body, read off the document rather than off the routers."""
    bodies = {}
    for method, template in SAMPLES:
        operation = artefact.DOCUMENT["paths"][template][method.lower()]
        described = operation.get("requestBody")
        if described is None:
            continue
        ((media_type, media),) = described["content"].items()
        schema = media["schema"]
        # Resolved here rather than left to the strategy walker, because the
        # mutations below read `required` and `properties` off this schema and a
        # bare `$ref` carries neither — a body whose reference was never followed
        # would be generated whole and then never broken.
        if "$ref" in schema:
            schema = resolve(schema["$ref"])
        bodies[(method, template)] = (media_type, schema)
    return bodies


BODIES = request_bodies()
# Built at import: a document that grows a keyword this walker does not handle
# fails the whole file loudly rather than quietly generating less.
STRATEGIES = {
    operation: strategy_for(schema) for operation, (_media, schema) in BODIES.items()
}


def encode(media_type, instance):
    if media_type == JSON_MEDIA:
        return {"json": instance}
    if media_type == MULTIPART_MEDIA:
        return {"files": {name: (name, value) for name, value in instance.items()}}
    raise NotImplementedError(media_type)


def string_bound(schema):
    """The `maxLength` of the string this property accepts, looking through an
    `anyOf` for the branch that is a string, or None when it has none."""
    for branch in schema.get("anyOf", [schema]):
        if branch.get("type") == "string" and "maxLength" in branch:
            return branch["maxLength"]
    return None


DROPPED = "a required field dropped"
WRONG_TYPE = "a field of the wrong type"
OVERLONG = "a string one past its maxLength"
UNKNOWN = "an unknown field added"
MUTATIONS = (DROPPED, WRONG_TYPE, OVERLONG, UNKNOWN)

# A value of a different JSON type from the one in hand. `bool` before `int`
# because in Python it is one.
OTHER_TYPE = ((bool, "true"), (str, 1), (int, "1"), (list, 1), (dict, 1))


def other_type(value):
    for kind, replacement in OTHER_TYPE:
        if isinstance(value, kind):
            return replacement
    return 1  # the value was null


def mutations(media_type, schema, instance):
    """The four ways a client gets a body wrong, as bodies to send.

    A mutation the schema gives no site for is left out rather than faked: an
    operation whose body has no required field cannot have one dropped, and the
    one multipart body declares no `maxLength` to push a string past.
    """
    if media_type == MULTIPART_MEDIA:
        return [
            (DROPPED, {}),
            # A form field where the route demands a file part, which its parser
            # is built with `max_fields=0` to refuse.
            (WRONG_TYPE, {"data": {name: "not-a-file" for name in instance}}),
            (
                UNKNOWN,
                {
                    "files": {
                        **{name: (name, value) for name, value in instance.items()},
                        "undeclared": ("undeclared", b"\x00"),
                    }
                },
            ),
        ]
    broken = []
    required = [name for name in schema.get("required", []) if name in instance]
    if required:
        kept = {key: value for key, value in instance.items() if key != required[0]}
        broken.append((DROPPED, kept))
    if instance:
        name = sorted(instance)[0]
        broken.append((WRONG_TYPE, {**instance, name: other_type(instance[name])}))
    for name, sub in sorted(schema.get("properties", {}).items()):
        bound = string_bound(sub)
        if bound is not None:
            broken.append((OVERLONG, {**instance, name: "a" * (bound + 1)}))
            break
    broken.append((UNKNOWN, {**instance, "__undeclared__": "value"}))
    return [(label, {"json": body}) for label, body in broken]


def echoable(body):
    """Every string long enough that finding it in a response would be an echo of
    the request rather than a coincidence. Values only: a field *name* is what an
    `invalid_request` body is supposed to carry."""
    return sorted(_strings_in(body.get("json", {})))


def _strings_in(value):
    if isinstance(value, str):
        return {value} if len(value) >= ECHO_FLOOR else set()
    if isinstance(value, dict):
        return set().union(*(_strings_in(item) for item in value.values()), set())
    if isinstance(value, list):
        return set().union(*(_strings_in(item) for item in value), set())
    return set()


def unthrottled(stage):
    """A generated body has to reach its route to say anything about it. `429` is
    a documented answer, but it is the driver table's business and not this run's."""
    stage.settings.THROTTLE_RATES = {
        scope: "1000000/min" for scope in stage.settings.THROTTLE_RATES
    }


@pytest.mark.parametrize(
    "operation", sorted(BODIES), ids=lambda operation: f"{operation[0]} {operation[1]}"
)
@hypothesis_settings(max_examples=EXAMPLES_PER_OPERATION)
@given(data=st.data())
def test_a_generated_body_never_takes_the_surface_outside_its_document(
    stage, operation, data
):
    """Whatever a client sends, the answer stays inside the contract.

    The body is drawn from the document's own request schema and then broken four
    ways, and the request is otherwise the operation's own — an authorised caller,
    the real path, the real headers. What is asserted is only what the document
    promises: never an unhandled failure, never a status it does not declare,
    never a body its schema refuses, and never the request read back.
    """
    method, template = operation
    media_type, schema = BODIES[operation]
    unthrottled(stage)
    call = SAMPLES[operation](stage)
    instance = data.draw(STRATEGIES[operation])

    sent = [("as generated", encode(media_type, instance))]
    sent.extend(mutations(media_type, schema, instance))
    for label, body in sent:
        response = send(stage.http, dataclasses.replace(call, body=body))

        assert response.status_code != 500, (label, response.text)
        if not artefact.declares(method, template, response.status_code):
            assert response.json() in artefact.BEFORE_THE_ROUTE, (label, response.text)
        assert held_to_the_document(response) == template, label
        for text in echoable(body):
            assert text not in response.text, (label, text)


def test_every_way_of_getting_a_body_wrong_has_somewhere_to_apply(stage):
    """A mutation with no site in a schema is skipped rather than faked, so a
    mutator that quietly stopped applying anywhere would leave the run above
    weaker with nothing on the report to say so."""
    applied = set()
    for operation, (media_type, schema) in BODIES.items():
        body = SAMPLES[operation](stage).body
        instance = body.get("json", {"blob": b"\x00"})
        applied.update(label for label, _sent in mutations(media_type, schema, instance))

    assert applied == set(MUTATIONS)
