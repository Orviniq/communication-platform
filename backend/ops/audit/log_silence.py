"""Log-silence audit: one scripted pass over every traffic surface (auth, devices,
messaging, attachments, realtime), captured at DEBUG, then scanned for every
identifier, blob, and token the pass generated. Returns a list of leaks; the system
is honest only when it is empty.

Two properties make this stricter than per-app spot checks:

- The capture bypasses the ScrubFilter. The filter mutates records in place, so any
  capture attached after the console handler grades the scrubber, not the code. The
  scrubber is a backstop; the primary control, audited here, is that nothing is ever
  logged in the first place.
- The capture swaps the handlers of the root logger and of every named logger that
  has its own (django.request/django.server/uvicorn/websockets set propagate=False,
  so a root-only swap, which is what assertLogs does, never sees them).

One httpx client over the composed ASGI application drives every HTTP route, and
the gateway suite's own ASGI socket driver drives `/ws`. The client records what it
asked for, so `core/tests/test_log_silence.py` can hold the pass to the route table
rather
than to whatever it happened to call. The httpx client logs the URL of every
request it makes, which is a request path in a log line — the suite's
`conftest.py` disables that logger, because the client is this harness and not the
server.

Driven by core/tests/test_log_silence.py; needs the test DB, a running Redis for
the fan-out bus, and a temp ATTACHMENTS_ROOT. No network is ever touched.
"""

import base64
import logging
import secrets as random_secrets
from contextlib import contextmanager

CANARY_OPEN = "log-silence-audit-canary-open"
CANARY_CLOSE = "log-silence-audit-canary-close"


class _RawCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(f"{record.levelname} {record.name} {record.getMessage()}")


@contextmanager
def capture_all_logging():
    """Route every logger that owns handlers (plus root) into one raw capture list,
    at DEBUG, with the configured handlers, and therefore the ScrubFilter, bypassed."""
    handler = _RawCapture()
    root = logging.getLogger()
    named = [logging.getLogger(name) for name in list(logging.root.manager.loggerDict)]
    targets = [root] + [
        lg for lg in named if isinstance(lg, logging.Logger) and lg.handlers
    ]
    saved = [(lg, lg.handlers[:], lg.level) for lg in targets]
    for lg in targets:
        lg.handlers[:] = [handler]
        lg.setLevel(logging.DEBUG)
    try:
        yield handler.lines
    finally:
        for lg, handlers, level in saved:
            lg.handlers[:] = handlers
            lg.setLevel(level)


def _b64_filled(size, fill):
    return base64.b64encode(bytes([fill]) * size).decode()


def _activate(user_id):
    from accounts.models import User

    User.objects.filter(id=user_id).update(is_active=True)


async def _scripted_account_traffic(client):
    """The account half: register, activate, log in. Returns {label: generated
    secret}, everything a log line must never contain."""
    from api.redis import get_client

    await get_client().flushdb()  # rate counters are shared
    s = {
        "username": f"aud{random_secrets.token_hex(6)}",
        "password": random_secrets.token_urlsafe(24),
    }

    # Register, then activate. Activation is the owner's admin action; its
    # server-side effect is the is_active flip.
    r = await client.post(
        "/api/v1/auth/register",
        json={"username": s["username"], "password": s["password"]},
    )
    assert r.status_code == 201, f"register: {r.status_code}"
    s["user id"] = r.json()["user_id"]
    from api.orm import run_unit

    await run_unit(_activate, s["user id"])

    # Login with no device: the register-scope token whose only power is
    # POST /me/devices.
    r = await client.post(
        "/api/v1/auth/login",
        json={"username": s["username"], "password": s["password"]},
    )
    assert r.status_code == 200, f"login: {r.status_code}"
    s["register-scope token"] = r.json()["token"]
    return s


async def _scripted_device_traffic(client, s):
    """The device registry and the mailbox: register, cross-sign, publish an
    identity, append and read the device log, then send, drain and ack an
    envelope. Every one of these carries key material or ciphertext."""
    from core.buckets import DEVICELOG_BUCKETS, ENVELOPE_BUCKETS, LABEL_BUCKETS

    # No cross_sig here: the bundle it signs covers the device_id this call assigns,
    # so registration refuses the field. It goes to the prekeys endpoint below, which
    # is where a real client cross-signs — and where this audit must therefore prove
    # a cross signature never reaches a log line.
    r = await client.post(
        "/api/v1/me/devices",
        json={
            "ik_pub": _b64_filled(64, 0x69),
            "spk_id": 1,
            "spk_pub": _b64_filled(32, 0x73),
            "spk_sig": _b64_filled(32, 0x67),
            "registration_id": 4242,
            "otpks": [{"key_id": 1, "pub": _b64_filled(32, 0x6F)}],
        },
        headers={"Authorization": f"Bearer {s['register-scope token']}"},
    )
    assert r.status_code == 201, f"device register: {r.status_code}"
    body = r.json()
    s["device id"] = body["device_id"]
    s["session token"] = body["token"]
    auth = {"Authorization": f"Bearer {s['session token']}"}

    # Cross-sign the device now that its device_id is known (CLIENT_CONTRACT.md §M).
    s["cross signature"] = _b64_filled(64, 0x78)
    r = await client.put(
        f"/api/v1/me/devices/{s['device id']}/prekeys",
        json={"cross_sig": s["cross signature"], "bundle_version": 1},
        headers=auth,
    )
    assert r.status_code == 200, f"cross-sign: {r.status_code}"

    # Publish the cross-signing identity and append a device-log record: both
    # surfaces carry key material and must stay as silent as the rest.
    s["master public key"] = _b64_filled(32, 0x6D)
    r = await client.put(
        "/api/v1/me/identity",
        json={
            "master_pub": s["master public key"],
            "self_signing_pub": _b64_filled(32, 0x74),
            "user_signing_pub": _b64_filled(32, 0x75),
            "master_sig": _b64_filled(64, 0x76),
            "version": 1,
        },
        headers=auth,
    )
    assert r.status_code == 200, f"identity publish: {r.status_code}"
    r = await client.get(f"/api/v1/users/{s['user id']}/identity", headers=auth)
    assert r.status_code == 200, f"identity read: {r.status_code}"
    s["identity tag"] = r.headers["etag"]
    r = await client.get(
        f"/api/v1/users/{s['user id']}/identity",
        headers={**auth, "If-None-Match": s["identity tag"]},
    )
    assert r.status_code == 304, f"conditional identity read: {r.status_code}"

    # A second device, so the revocation below ends something other than the
    # device this pass is authenticated as. Its own key material joins the set.
    s["second device identity key"] = _b64_filled(64, 0x32)
    r = await client.post(
        "/api/v1/me/devices",
        json={
            "ik_pub": s["second device identity key"],
            "spk_id": 2,
            "spk_pub": _b64_filled(32, 0x33),
            "spk_sig": _b64_filled(32, 0x34),
            "registration_id": 4343,
            "otpks": [{"key_id": 2, "pub": _b64_filled(32, 0x35)}],
        },
        headers=auth,
    )
    assert r.status_code == 201, f"second device register: {r.status_code}"
    s["second device id"] = r.json()["device_id"]
    s["second device session token"] = r.json()["token"]

    # Rename, list, count, then revoke the second device. The label is client
    # ciphertext and the revocation is the one write that reaches a live socket.
    s["device label blob"] = _b64_filled(min(LABEL_BUCKETS), 0x1B)
    r = await client.put(
        f"/api/v1/me/devices/{s['device id']}",
        json={"label_blob": s["device label blob"]},
        headers=auth,
    )
    assert r.status_code == 200, f"relabel: {r.status_code}"
    r = await client.get("/api/v1/me/devices", headers=auth)
    assert r.status_code == 200, f"own device list: {r.status_code}"
    r = await client.get(
        f"/api/v1/me/devices/{s['device id']}/prekeys/count", headers=auth
    )
    assert r.status_code == 200, f"prekey count: {r.status_code}"
    r = await client.delete(f"/api/v1/me/devices/{s['second device id']}", headers=auth)
    assert r.status_code == 204, f"revoke: {r.status_code}"

    s["device log blob"] = _b64_filled(min(DEVICELOG_BUCKETS), 0xD1)
    r = await client.post(
        "/api/v1/me/devicelog",
        json={"records": [{"blob": s["device log blob"]}]},
        headers=auth,
    )
    assert r.status_code == 201, f"devicelog append: {r.status_code}"
    r = await client.get(f"/api/v1/users/{s['user id']}/devicelog", headers=auth)
    assert r.status_code == 200, f"devicelog read: {r.status_code}"
    r = await client.get(f"/api/v1/users/{s['user id']}/devices", headers=auth)
    assert r.status_code == 200, f"peer device list: {r.status_code}"
    # The peer-state batch, and then the same call carrying the tag it answered
    # with, so both branches of the route are driven: the full answer and the
    # unchanged one. The tag is a hash of what the route serves, so it goes into
    # the secret set with everything else the pass generated.
    r = await client.post(
        "/api/v1/peers",
        json={"peers": [{"user_id": s["user id"]}]},
        headers=auth,
    )
    assert r.status_code == 200, f"peer state: {r.status_code}"
    s["peer state tag"] = r.json()["peers"][0]["etag"]
    r = await client.post(
        "/api/v1/peers",
        json={"peers": [{"user_id": s["user id"], "etag": s["peer state tag"]}]},
        headers=auth,
    )
    assert r.json()["peers"][0]["unchanged"] is True, "the peer tag did not hold"
    r = await client.post(
        f"/api/v1/users/{s['user id']}/keys/claim", json={}, headers=auth
    )
    assert r.status_code == 200, f"claim: {r.status_code}"
    s["claimed one-time prekey"] = r.json()["bundles"][0]["otpk"]["pub"]

    # Send an envelope to our own device (self-sync shape), drain it, ack it.
    s["envelope blob"] = _b64_filled(min(ENVELOPE_BUCKETS), 0xA5)
    r = await client.post(
        "/api/v1/envelopes",
        json={"messages": [{"device_id": s["device id"], "blob": s["envelope blob"]}]},
        headers=auth,
    )
    assert r.status_code == 202, f"send: {r.status_code}"
    r = await client.get("/api/v1/me/envelopes", headers=auth)
    assert r.status_code == 200 and r.json()["envelopes"], "drain returned nothing"
    envelopes = r.json()["envelopes"]
    s["queued envelope id"] = envelopes[0]["id"]
    r = await client.post(
        "/api/v1/me/envelopes/ack",
        json={"ids": [e["id"] for e in envelopes]},
        headers=auth,
    )
    assert r.status_code == 200, f"ack: {r.status_code}"
    return s


async def _scripted_blob_traffic(client, s):
    """The attachment store: a multipart upload and the redirect that serves it
    back. The upload is the one body of this API that is bytes rather than JSON."""
    from core.buckets import ATTACHMENT_BUCKETS

    auth = {"Authorization": f"Bearer {s['session token']}"}

    # Upload + download an attachment (download answers via X-Accel-Redirect).
    upload_bytes = b"\x01" * min(ATTACHMENT_BUCKETS)
    r = await client.post(
        "/api/v1/attachments", files={"blob": ("blob", upload_bytes)}, headers=auth
    )
    assert r.status_code == 201, f"upload: {r.status_code}"
    s["attachment id"] = r.json()["attachment_id"]
    r = await client.get(f"/api/v1/attachments/{s['attachment id']}", headers=auth)
    assert r.status_code == 200, f"download: {r.status_code}"
    return s


async def _scripted_account_state_traffic(client, s):
    """The account's own state: the directory, the profile blobs, the key backup,
    and a token rotation. Adds each payload and each issued token to the secret
    set."""
    from core.buckets import BACKUP_BUCKETS, PROFILE_BUCKETS

    auth = {"Authorization": f"Bearer {s['session token']}"}

    r = await client.get("/api/v1/health")
    assert r.status_code == 200, f"health: {r.status_code}"
    r = await client.get("/api/v1/config", headers=auth)
    assert r.status_code == 200, f"config: {r.status_code}"
    r = await client.get("/api/v1/users", headers=auth)
    assert r.status_code == 200, f"directory: {r.status_code}"

    s["profile blob"] = _b64_filled(min(PROFILE_BUCKETS), 0xC3)
    r = await client.put(
        "/api/v1/me/profile",
        json={"blob": s["profile blob"], "version": 1},
        headers=auth,
    )
    assert r.status_code == 200, f"profile write: {r.status_code}"
    r = await client.get(f"/api/v1/users/{s['user id']}/profile", headers=auth)
    assert r.status_code == 200, f"peer profile read: {r.status_code}"
    r = await client.get("/api/v1/me/profile", headers=auth)
    assert r.status_code == 200, f"own profile read: {r.status_code}"

    s["key backup blob"] = _b64_filled(min(BACKUP_BUCKETS), 0xB4)
    r = await client.put(
        "/api/v1/me/keybackup",
        json={"blob": s["key backup blob"], "version": 1},
        headers=auth,
    )
    assert r.status_code == 200, f"key backup write: {r.status_code}"
    r = await client.get("/api/v1/me/keybackup", headers=auth)
    assert r.status_code == 200, f"key backup read: {r.status_code}"

    # Renewal issues a second session token; it must stay out of every log line.
    r = await client.post("/api/v1/auth/renew", headers=auth)
    assert r.status_code == 200, f"renew: {r.status_code}"
    s["renewed session token"] = r.json()["token"]


async def _scripted_logout(client, s):
    """Last, because it ends every token of the device."""
    r = await client.post(
        "/api/v1/auth/logout",
        headers={"Authorization": f"Bearer {s['renewed session token']}"},
    )
    assert r.status_code == 204, f"logout: {r.status_code}"


async def _scripted_relay_traffic(client, s):
    """The voice half's HTTP surface: mint one coturn credential.

    The route reads no row and writes none — the credential is computed from a
    shared secret — so what it contributes here is the two values it returns.
    Both are exactly what invariant 4 forbids in a log line: the username is the
    identifier coturn will see, and the credential is the password that opens a
    relay allocation on this deployment until its own expiry. A deployment with no
    `TURN_URLS` answers `503 voice_unconfigured`, so the suites that drive this
    audit configure one.
    """
    auth = {"Authorization": f"Bearer {s['session token']}"}

    r = await client.post("/api/v1/me/relay", headers=auth)
    assert r.status_code == 200, f"relay credential: {r.status_code}"
    s["relay username"] = r.json()["username"]
    s["relay credential"] = r.json()["credential"]
    return s


async def _scripted_socket_traffic(s):
    """The realtime half: authenticated connect, a volatile signal round-trip to our own
    device, disconnect. Adds the signal blob to the secret set."""
    from config.asgi import application
    from core.buckets import SIGNAL_BUCKETS
    from realtime.tests.socket import WebSocketCommunicator

    comm = WebSocketCommunicator(
        application,
        "/ws",
        headers=[(b"authorization", f"Bearer {s['session token']}".encode())],
    )
    connected, _ = await comm.connect(timeout=2)
    assert connected, "socket handshake refused"
    # Bucketed like every stored ciphertext: the gateway relays a blob only when
    # it is standard base64 of exactly one signal bucket.
    s["signal blob"] = base64.b64encode(
        random_secrets.token_bytes(min(SIGNAL_BUCKETS))
    ).decode()
    await comm.send_json_to(
        {"type": "signal", "to_device": s["device id"], "blob": s["signal blob"]}
    )
    frame = await comm.receive_json_from(timeout=2)
    assert frame == {"type": "signal", "blob": s["signal blob"]}, "signal did not relay"
    await comm.disconnect()


def scan(lines, secrets):
    """Every captured line vs every generated secret. Substring match: an id inside a
    traceback, a repr, or a formatted message is still a leak."""
    return [
        f"{label} leaked into: {line[:160]}"
        for line in lines
        for label, secret in secrets.items()
        if secret and str(secret) in line
    ]


async def run_audit(probe=None):
    """Run the scripted sequence under full capture.

    Returns (leaks, secrets, lines, requested), where `requested` is every
    (method, path) the pass asked for, in order.

    `probe(secrets)` is a test hook, called inside the capture window after the
    scripted traffic, so the suite can prove the audit still catches a deliberate
    leak."""
    from httpx import ASGITransport, AsyncClient

    # Import the ASGI application before the capture opens. That import runs
    # django.setup(), which re-applies LOGGING through dictConfig and replaces the
    # handlers this audit swapped in. Inside the capture window it would kill the
    # capture halfway through, and every assertion after that point would grade an
    # empty list instead of the real log stream.
    import config.asgi

    transport = ASGITransport(app=config.asgi.application)
    lifespan = config.asgi.api_application.router.lifespan_context
    requested = []

    async def record(request):
        requested.append((request.method, request.url.path))

    with capture_all_logging() as lines:
        logging.getLogger("ops.audit.canary").debug(CANARY_OPEN)
        async with lifespan(config.asgi.api_application):
            async with AsyncClient(
                transport=transport,
                base_url="http://testserver",
                event_hooks={"request": [record]},
            ) as client:
                secrets = await _scripted_account_traffic(client)
                await _scripted_device_traffic(client, secrets)
                await _scripted_blob_traffic(client, secrets)
                await _scripted_account_state_traffic(client, secrets)
                await _scripted_relay_traffic(client, secrets)
                await _scripted_socket_traffic(secrets)
                await _scripted_logout(client, secrets)
        if probe is not None:
            probe(secrets)
        logging.getLogger("ops.audit.canary").debug(CANARY_CLOSE)
    if not any(CANARY_OPEN in line for line in lines):
        raise RuntimeError("log capture was not live; this audit proved nothing")
    if not any(CANARY_CLOSE in line for line in lines):
        raise RuntimeError(
            "log capture stopped before the run ended; this audit proved nothing"
        )
    return scan(lines, secrets), secrets, lines, requested
