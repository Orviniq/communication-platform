"""The composed FastAPI application, with the Django admin behind it.

FastAPI serves every route of this API: the HTTP surface through its routers and
the `/ws` gateway through the WebSocket route of `realtime/gateway.py`. The
Django ASGI application answers `ADMIN_PATH` and, in development, the static
files the admin renders with; a path that is neither reaches FastAPI's own
`not_found`, never a Django 404 page.
"""

from contextlib import asynccontextmanager

from django.conf import settings
from fastapi import FastAPI
from starlette.exceptions import HTTPException
from starlette.websockets import WebSocketClose

from accounts.routes import anonymous as accounts_anonymous
from accounts.routes import authenticated as accounts_authenticated
from api import errors, schema
from api.middleware import (
    BodyCap,
    Limits,
    RequestDeadline,
    ResponseHeaders,
    ThreadSensitive,
    TrustedHost,
)
from api.redis import close_client
from attachments.routes import router as attachments_router
from config.urls import ADMIN_PATH
from core.buckets import ATTACHMENT_BUCKETS
from core.routes import router as core_router
from devices.routes import authenticated as devices_authenticated
from devices.routes import registration as devices_registration
from messaging.routes import router as messaging_router
from realtime import bus, gateway
from realtime.routes import router as realtime_router
from vault.routes import router as vault_router

API_PREFIX = "/api/v1"


def route_limits():
    """The body cap and the deadline of each route class, and the class each route
    takes.

    Four classes, and every route names one. The JSON class covers a body of a
    few fields; the backup class the one blob an account keeps whole; the batch
    class the `devices` and `messaging` bodies, whose length is a list cap times a
    base64 cap — 200 ML-KEM prekeys at 1184 bytes each, or a 256-item batch of
    256 KiB envelopes — and whose 70 MiB is what nginx admits rather than what
    those schemas could produce, so the largest batch a schema allows is already
    refused. The attachment class is the largest bucket plus the multipart
    wrapper, which is the only body of this API that is bytes rather than JSON.

    A path no route claims takes the JSON class. Only the admin, and the static
    files in development, ever reach it, and Django bounds its own forms below
    that anyway.
    """
    json_class = Limits(settings.BODY_CAP_JSON_BYTES, settings.REQUEST_DEADLINE_SECONDS)
    backup_class = Limits(
        settings.BODY_CAP_BACKUP_BYTES, settings.REQUEST_DEADLINE_SECONDS
    )
    batch_class = Limits(settings.BODY_CAP_BATCH_BYTES, settings.UPLOAD_DEADLINE_SECONDS)
    attachment_class = Limits(
        max(ATTACHMENT_BUCKETS) + settings.MULTIPART_OVERHEAD_BYTES,
        settings.UPLOAD_DEADLINE_SECONDS,
    )
    per_route = {
        f"{API_PREFIX}/health": json_class,
        f"{API_PREFIX}/config": json_class,
        f"{API_PREFIX}/auth/register": json_class,
        f"{API_PREFIX}/auth/login": json_class,
        f"{API_PREFIX}/auth/renew": json_class,
        f"{API_PREFIX}/auth/logout": json_class,
        f"{API_PREFIX}/users": json_class,
        f"{API_PREFIX}/users/{{user_id}}/profile": json_class,
        f"{API_PREFIX}/me/profile": json_class,
        f"{API_PREFIX}/me/keybackup": backup_class,
        f"{API_PREFIX}/me/identity": json_class,
        f"{API_PREFIX}/users/{{user_id}}/identity": json_class,
        f"{API_PREFIX}/me/devices": batch_class,
        f"{API_PREFIX}/me/devices/{{device_id}}": json_class,
        f"{API_PREFIX}/me/devices/{{device_id}}/prekeys": batch_class,
        f"{API_PREFIX}/me/devices/{{device_id}}/prekeys/count": json_class,
        f"{API_PREFIX}/me/devicelog": batch_class,
        f"{API_PREFIX}/users/{{user_id}}/devicelog": json_class,
        f"{API_PREFIX}/users/{{user_id}}/devices": json_class,
        f"{API_PREFIX}/peers": json_class,
        f"{API_PREFIX}/users/{{user_id}}/keys/claim": batch_class,
        f"{API_PREFIX}/envelopes": batch_class,
        f"{API_PREFIX}/me/envelopes": batch_class,
        f"{API_PREFIX}/me/envelopes/ack": batch_class,
        f"{API_PREFIX}/attachments": attachment_class,
        f"{API_PREFIX}/attachments/{{attachment_id}}": json_class,
        f"{API_PREFIX}/me/relay": json_class,
    }

    return per_route, json_class


def build_limits():
    """The lookup the middleware stack holds: a path to the limits it carries."""
    per_route, fallback = route_limits()

    def limits_for(path):
        return per_route.get(path, fallback)

    return limits_for


def django_paths(django_app):
    """The dispatcher that stands where Starlette's own `not_found` would.

    Django answers `ADMIN_PATH` and, in development, `STATIC_URL`. Every other
    unmatched path raises the same `HTTPException` the router raises for a miss,
    so it renders as this API's `not_found` envelope rather than as Django's HTML
    404 page.

    A websocket scope that no route claims is refused with a close instead, which
    is what Starlette's own `not_found` does. Rendering the envelope for it would
    answer the handshake with the websocket denial-response extension, which this
    application never declares and a server need not implement.
    """
    prefixes = ["/" + ADMIN_PATH.strip("/")]
    if settings.DEBUG:
        prefixes.append("/" + settings.STATIC_URL.strip("/"))

    async def dispatch(scope, receive, send):
        if scope["type"] == "websocket":
            await WebSocketClose()(scope, receive, send)
            return
        path = scope.get("path", "")
        if any(path == prefix or path.startswith(prefix + "/") for prefix in prefixes):
            await django_app(scope, receive, send)
            return
        raise HTTPException(status_code=404)

    return dispatch


@asynccontextmanager
async def lifespan(app):
    """Release what the process holds when the server sends a shutdown.

    Nothing is built here. What the process holds is bound to the running event
    loop — the Redis client, the bus subscriber and its reader task — and each is
    built on first use, so a worker that never opens a socket never opens a
    subscription. Shutdown runs in the order the dependencies run: the sockets
    first, because a socket that outlives the subscriber would go silent rather
    than closed, then the subscriber, then the client whose pool it borrowed.
    """
    try:
        yield
    finally:
        await gateway.drain()
        await bus.stop_subscriber()
        await close_client()


def create_app(django_app):
    # No schema route and no interactive documentation, in any mode (ADR-0020).
    # They render for a browser, and the product has no browser client; the
    # document itself describes every route and every payload of a server whose
    # posture is to reveal nothing. `manage.py openapi` writes `openapi.json` from
    # the generator `schema.install` puts on the application below, and the
    # committed artefact is the only reference.
    app = FastAPI(
        title="communication platform",
        version="v1",
        lifespan=lifespan,
        generate_unique_id_function=schema.operation_id,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    errors.install(app)
    schema.install(app)
    app.include_router(core_router, prefix=API_PREFIX)
    app.include_router(accounts_anonymous, prefix=API_PREFIX)
    app.include_router(accounts_authenticated, prefix=API_PREFIX)
    app.include_router(vault_router, prefix=API_PREFIX)
    app.include_router(devices_registration, prefix=API_PREFIX)
    app.include_router(devices_authenticated, prefix=API_PREFIX)
    app.include_router(messaging_router, prefix=API_PREFIX)
    app.include_router(attachments_router, prefix=API_PREFIX)
    app.include_router(realtime_router, prefix=API_PREFIX)
    # The gateway is at the root, not under the version prefix: `/ws` is the path
    # `realtime/API.md` publishes and the client already opens. Added to the
    # application rather than included as a router, because a websocket route
    # inside an included router reports an empty path to FastAPI's own route
    # walker, and the route table, the limit table and the log-silence pass all
    # read the surface through it.
    app.add_api_websocket_route(gateway.PATH, gateway.gateway)
    # The Django application is reached through the router's `default`, not a
    # mount at "/". A mount matches every path, so it would answer before the
    # wrong-method 405 of a route this API serves; `default` runs only when no
    # route matched at all.
    app.router.default = django_paths(django_app)
    # A mismatched trailing slash is a 404, never a redirect: the redirect
    # rebuilds an absolute address from the scope path and drops any prefix the
    # proxy stripped.
    app.router.redirect_slashes = False
    return app


def wrap(app):
    """The middleware stack, from the outside in."""
    limits_for = build_limits()
    stack = ThreadSensitive(app)
    stack = ResponseHeaders(stack)
    stack = BodyCap(stack, limits_for)
    stack = RequestDeadline(stack, limits_for)
    return TrustedHost(stack, settings.ALLOWED_HOSTS)
