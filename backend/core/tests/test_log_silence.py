"""System-wide log-silence audit, driving ops/audit/log_silence.py.

The per-app suites spot-check their own paths; this pass runs one scripted sequence
across auth, devices, messaging, attachments and realtime, and asserts none
of the identifiers/blobs/tokens it generated reached any log line. The second test
proves the audit itself still has teeth, including against loggers that do not
propagate to root, the blind spot that would let a leak grade its own homework. The
third holds the pass to the whole route table, because a route the audit never calls
is a route it never cleared.
"""

import logging

import pytest
from fastapi.routing import iter_route_contexts
from starlette.routing import compile_path

from api.redis import close_client
from config.asgi import api_application
from core.tests.test_route_table import EXPECTED
from ops.audit.log_silence import CANARY_CLOSE, CANARY_OPEN, run_audit
from realtime.bus import stop_subscriber

pytestmark = pytest.mark.django_db(transaction=True)


@pytest.fixture(autouse=True)
async def _isolated_runtime(settings, tmp_path):
    """Uploads stay out of the repo, and the bus the socket half opens is released
    with the loop it was opened on."""
    settings.ATTACHMENTS_ROOT = tmp_path
    # Voice is configured on rather than off: with no `TURN_URLS` the relay route
    # answers `503 voice_unconfigured` and the pass would never mint the credential
    # it exists here to prove silent. 198.51.100.0/24 is the documentation range
    # and nothing resolves it; the secret is a fixed test value that no process
    # outside this suite reads.
    settings.TURN_URLS = ["turn:198.51.100.10:3478"]
    settings.TURN_STATIC_AUTH_SECRET = "log-silence-audit-relay-secret-32"
    yield
    await stop_subscriber()
    await close_client()


def matchers():
    """(method, compiled path, path template) for every route the API serves.

    Compiled from the templates rather than matched through the router, because a
    router included under a prefix is not itself a route with a path.
    """
    for context in iter_route_contexts(api_application.routes):
        if context.methods is None:
            continue  # the `/ws` gateway, which the audit drives as a socket
        regex, _format, _convertors = compile_path(context.path)
        for method in context.methods:
            yield method, regex, context.path


MATCHERS = list(matchers())


def route_of(method, path):
    """The route-table entry a recorded request landed on, or None for a path this
    API serves through the Django application."""
    for candidate, regex, template in MATCHERS:
        if candidate == method and regex.match(path):
            return (method, template)
    return None


async def test_scripted_traffic_across_every_surface_leaks_nothing():
    leaks, secrets, _lines, _requested = await run_audit()

    assert leaks == [], f"identifiers/payloads reached the logs: {leaks}"
    # Anti-vacuity: every step really ran and generated its secret.
    for label in (
        "user id",
        "register-scope token",
        "device id",
        "session token",
        "envelope blob",
        "queued envelope id",
        "attachment id",
        "relay username",
        "relay credential",
        "signal blob",
        "profile blob",
        "key backup blob",
        "renewed session token",
    ):
        assert secrets.get(label), f"the audit never exercised the {label} step"


@pytest.mark.parametrize("logger_name", ["django.request", "uvicorn.access"])
async def test_the_audit_catches_a_leak_even_on_a_non_propagating_logger(logger_name):
    """Each of these owns its handler and sets propagate=False, the spot assertLogs
    misses. A deliberate leak on one must come back non-empty, or the audit is dead.

    `uvicorn.access` is the server's own request line: claimed in `LOGGING` precisely
    so it goes through the scrub filter rather than a stream of its own, and named
    here so the audit is proved to reach it and not only Django's loggers."""

    def leak(secrets):
        logging.getLogger(logger_name).error("device %s misbehaved", secrets["device id"])

    leaks, _secrets, _lines, _requested = await run_audit(probe=leak)

    assert any("device id" in leak_line for leak_line in leaks), (
        "a deliberately logged device id was not detected"
    )


async def test_the_pass_drives_every_route_of_the_table():
    """A route the audit never calls is a route it never cleared, and a route added
    to the table without a step here would be cleared by silence."""
    _leaks, _secrets, _lines, requested = await run_audit()

    driven = {route_of(method, path) for method, path in requested}

    assert driven - {None} == set(EXPECTED)


@pytest.mark.parametrize(
    "label",
    [
        "envelope blob",
        "key backup blob",
        "profile blob",
        "session token",
        "attachment id",
        "queued envelope id",
        "relay credential",
    ],
)
async def test_the_audit_catches_a_leak_of_every_kind_of_secret_it_collected(label):
    """The scan has to recognise each shape, not just an identifier.

    The existing probe leaks a device id, which is a UUID; a ciphertext blob, a
    bearer token, a base64 capability id and the base64 HMAC of a relay
    credential are matched by different patterns and would each be a different way
    for the pass to clear a leak it never looked for. Every label here is one the
    audit records, so a step that stops generating its secret fails the
    anti-vacuity test above rather than quietly narrowing this one.
    """

    def leak(secrets):
        logging.getLogger("django.request").error("stray value %s", secrets[label])

    leaks, _secrets, _lines, _requested = await run_audit(probe=leak)

    assert any(label in leak_line for leak_line in leaks), (
        f"a deliberately logged {label} was not detected"
    )


async def test_the_capture_window_was_open_for_the_whole_pass():
    """The audit's own guard, asserted from outside it: the canary is written on
    both sides of the scripted traffic, so a capture that was never installed — or
    that a `dictConfig` re-application tore down halfway — cannot come back as an
    empty leak list."""
    _leaks, _secrets, lines, _requested = await run_audit()

    assert any(CANARY_OPEN in line for line in lines)
    assert any(CANARY_CLOSE in line for line in lines)
    assert len(lines) >= 2
