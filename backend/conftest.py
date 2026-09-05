import logging

import httpx
import pytest
import redis
from asgiref.sync import async_to_sync
from django.conf import settings
from httpx import ASGITransport
from hypothesis import HealthCheck
from hypothesis import settings as hypothesis_settings

from accounts.models import User
from api.auth import issue_register_scope, issue_session
from config.asgi import api_application, application
from core.tests import artefact
from devices.models import Device

PASSWORD = "correct-horse-battery-staple"
BASE_URL = "http://testserver"

# httpx logs every request it makes, with its URL, at INFO. That client is this
# harness, not the server, and a request path in a log line is exactly what the
# log-silence suites exist to catch — so silence the harness rather than let it
# grade the server. The server imports no HTTP client: httpx is a test-only
# dependency and this logger does not exist in production.
logging.getLogger("httpx").disabled = True

# The property tests run under `pytest-randomly`, which reseeds the global RNG for
# every test, so an entropy-driven Hypothesis would explore a different set of
# examples in each of the two orders the gate gives it. `derandomize` fixes the
# examples to the test itself: a property that fails, fails in both runs, and the
# failing example is in the log rather than behind a seed nobody recorded.
#
# The budget is fixed for the same reason the gate has to finish: this is a suite,
# not a fuzzing campaign. `database=None` keeps the run from writing a `.hypothesis`
# directory into the tree, and the deadline is off because a per-example wall-clock
# limit turns a loaded machine into a red build.
hypothesis_settings.register_profile(
    "chatapp",
    max_examples=200,
    derandomize=True,
    deadline=None,
    database=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
hypothesis_settings.load_profile("chatapp")


class AsgiClient:
    """A synchronous facade over `httpx.AsyncClient` on the composed application.

    Synchronous on purpose. asgiref runs thread-sensitive work — which is every
    ORM unit of work — in the thread that called `async_to_sync`, so a request
    uses the test's own connection, sees the test's uncommitted rows, and lands
    in the counter `django_assert_num_queries` installed. An async test would
    push the ORM onto a second thread with a second connection and see none of
    that.

    Each call runs with the FastAPI lifespan entered. `ASGITransport` never
    enters it, and `async_to_sync` builds a fresh event loop for each call, so
    nothing the lifespan holds may outlive one call.

    `reraise` is the transport's own default and stays on: an unhandled failure
    reaching the test is what keeps a `500` from being mistaken for a passing
    request. Turn it off only to read the `500` body itself, which is the one
    thing the default hides.
    """

    def __init__(self, transport_app, lifespan_app, reraise=True):
        self._client = httpx.AsyncClient(
            transport=ASGITransport(app=transport_app, raise_app_exceptions=reraise),
            base_url=BASE_URL,
        )
        self._lifespan_app = lifespan_app

    async def _request(self, method, url, **kwargs):
        async with self._lifespan_app.router.lifespan_context(self._lifespan_app):
            return await self._client.request(method, url, **kwargs)

    def request(self, method, url, **kwargs):
        response = async_to_sync(self._request)(method, url, **kwargs)
        # Every response this client produces is held to `backend/openapi.json`,
        # which makes the whole suite the sample rather than one file of contract
        # tests. The document is what a client generates from, so a body it does
        # not describe is a client that breaks on a field nobody published, and a
        # status it does not declare is a branch no generated client has.
        # `core/tests/artefact.py` carries the mechanism, and the four refusals
        # this surface answers before it has chosen a route, which belong to no
        # operation and are let through on any of them.
        artefact.check(
            method,
            response.request.url.path,
            response.status_code,
            response.headers.get("content-type", ""),
            response.content,
        )
        return response

    def get(self, url, **kwargs):
        return self.request("GET", url, **kwargs)

    def post(self, url, **kwargs):
        return self.request("POST", url, **kwargs)

    def put(self, url, **kwargs):
        return self.request("PUT", url, **kwargs)

    def delete(self, url, **kwargs):
        return self.request("DELETE", url, **kwargs)


def flush_redis():
    """Empty the shared Redis database: the rate counters and the lockout state.
    Through the redis client rather than Django's cache framework, which this
    project keeps off Redis (ADR-0018)."""
    store = redis.Redis.from_url(settings.REDIS_URL)
    try:
        store.flushdb()
    finally:
        store.close()


@pytest.fixture(autouse=True)
def flush_redis_state():
    """Rate-limit counters live in the shared Redis instance, so without this they
    leak between tests and across whole runs (the login scope is 20/hour)."""
    flush_redis()
    yield


@pytest.fixture
def http():
    """Drives every route of this API through the whole composed stack: the
    middleware, the FastAPI routes, and the Django admin behind them."""
    return AsgiClient(application, api_application)


@pytest.fixture
def new_http():
    """A client factory, for a race test that drives the surface from threads.

    One `AsgiClient` holds one `httpx.AsyncClient`, and `async_to_sync` builds a
    fresh event loop for each call in the thread that made it, so a client shared
    across threads would carry connections bound to a loop that is already gone.
    Each thread builds its own, and its ORM work then runs on that thread, against
    that thread's own database connection.
    """
    return lambda: AsgiClient(application, api_application)


@pytest.fixture
def active_user(db):
    """An account the owner has already activated."""
    return User.objects.create_user(username="alice", password=PASSWORD, is_active=True)


@pytest.fixture
def device(active_user):
    """A live device for `active_user`, enough to mint session tokens."""
    return Device.objects.create(
        user=active_user,
        ik_pub=b"ik-public",
        spk_id=1,
        spk_pub=b"spk-public",
        spk_sig=b"spk-signature",
        registration_id=1001,
    )


@pytest.fixture
def bearer():
    """`Authorization` for a session token bound to `device`."""

    def build(user, device):
        token, _expires_in = issue_session(user, device)
        return {"Authorization": f"Bearer {token}"}

    return build


@pytest.fixture
def register_bearer():
    """`Authorization` for the short-lived token whose only power is adding a
    device."""

    def build(user):
        token, _expires_in = issue_register_scope(user)
        return {"Authorization": f"Bearer {token}"}

    return build


@pytest.fixture
def bob(db):
    """A second activated account, for the tests that need two."""
    return User.objects.create_user(username="bob", password=PASSWORD, is_active=True)
