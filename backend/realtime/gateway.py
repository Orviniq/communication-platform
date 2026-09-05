"""The `/ws` gateway: one Starlette WebSocket route on the FastAPI application.

One socket carries envelope delivery and volatile device-to-device signals. The
wire contract is `realtime/API.md` and this module is the whole of its server
half; `realtime/bus.py` carries a frame between two sockets, wherever in the
process set they are.

A connection authenticates before it is accepted, so every accepted socket is
already bound to a device. It is then a receive loop and a send loop in one task
group, plus the watch that turns an out-of-band stop — a revocation, a slow
consumer — into a close code. Every task of the group dies with the first one that
raises, and the cleanup that follows runs on every exit path alike: the
unsubscription of its topic.

The gateway holds no presence (ADR-0022). A presence subscription is a contact
list the client declares to the server, and the server needs none of it: who is
in a conversation is the client's knowledge, and presence between its members is
client protocol carried over `signal` frames like every other announcement.

Nothing here is persisted and nothing here is logged. The database is reached only
through `api/orm.py`, on the thread the ORM owns, and Redis only through the async
client of `api/redis.py`, so no frame ever blocks the event loop.
"""

import asyncio
import base64
import json
import time
import uuid

from django.conf import settings
from fastapi import WebSocket

from core.buckets import SIGNAL_BUCKETS
from core.fields import BadBucket, decode_blob_or_400
from realtime import auth, bus

RATE_WINDOW_SECONDS = 1.0
RATE_MAX_IN_WINDOW = 100
ACK_IDS_MAX = 200

# The most characters a `signal` blob may carry: the base64 of the largest signal
# bucket. A longer blob cannot decode to a bucket length, so it is refused on its
# length alone rather than decoded first — a frame may be as long as
# `WS_MAX_FRAME`, and decoding half a mebibyte to learn it was never a bucket is
# event-loop time spent on a frame the contract already refuses.
SIGNAL_BLOB_MAX = len(base64.b64encode(bytes(max(SIGNAL_BUCKETS))))

# The bound on the one per-connection buffer that an outside writer fills. A
# socket that cannot drain it is a slow consumer and closes with 4008 rather than
# growing a queue the process has no memory for: 1 GB across every live socket is
# what makes a bound mandatory and this number small.
SEND_QUEUE_MAX = 256

# The shutdown close code. `1012` is "service restart", which tells the client to
# reconnect rather than to treat a deploy as a network failure. The drain waits
# for the sockets to answer, but never past this, because a shutdown that a stuck
# socket can hold open is not a shutdown.
SHUTDOWN_CODE = 1012
DRAIN_TIMEOUT_SECONDS = 5

PATH = "/ws"

# Every accepted connection of this worker, so a lifespan shutdown can drain them.
LIVE = set()


class _Stop(Exception):
    """Tear down the task group. The code to close with is on the connection."""


async def gateway(websocket: WebSocket):
    await Connection(websocket).serve(_header_token(websocket))


async def drain():
    """Close every live socket of this worker with `1012`.

    uvicorn's own graceful shutdown closes the sockets with the same code before
    the lifespan shutdown reaches this, so in a normal stop it finds nothing
    left. It is what covers a shutdown that arrives by any other route.
    """
    connections = tuple(LIVE)
    for connection in connections:
        connection.stop(SHUTDOWN_CODE)
    if not connections:
        return
    try:
        async with asyncio.timeout(DRAIN_TIMEOUT_SECONDS):
            for connection in connections:
                await connection.wait_closed()
    except TimeoutError:
        return  # silent: naming the socket that hung would name its device


class Connection:
    """One socket: its identity, its bounded buffers, and its two loops."""

    def __init__(self, websocket):
        self.websocket = websocket
        self.user = None
        self.device = None
        self.device_topic = None
        self._msg_times = []
        self._outbox = asyncio.Queue(maxsize=SEND_QUEUE_MAX)
        self._stop = asyncio.Event()
        self._closed = asyncio.Event()
        self._close_code = None

    # ---- lifecycle -------------------------------------------------------
    async def serve(self, token):
        if token is None:
            await self.websocket.close()
            return
        try:
            bound = await self._bind(token)
        except BaseException:
            # The bind subscribes the topic before it touches the device row, and
            # the subscriber records a sink before it sends SUBSCRIBE, so a raise
            # after either point has registered a sink for a socket that will
            # never exist. Left there it lives as long as the worker: the topic
            # is never unsubscribed for the device, because a later socket of it
            # joins the holders and its own cleanup leaves this one behind, and
            # every frame published to the device fills a dead outbox to its
            # bound. Release it, and let the handshake fail as it did.
            await self._cleanup()
            raise
        if not bound:
            # Decided before the accept, so this is a refused handshake rather
            # than a close frame: a server answers the upgrade request with an
            # HTTP failure and there is no socket to carry a code on.
            # `realtime/API.md` documents both halves.
            await self.websocket.close()
            return
        try:
            await self.websocket.accept()
            LIVE.add(self)
            await self._loops()
        finally:
            LIVE.discard(self)
            await self._cleanup()
            await self._close()
            self._closed.set()

    async def wait_closed(self):
        await self._closed.wait()

    async def _loops(self):
        try:
            async with asyncio.TaskGroup() as group:
                group.create_task(self._receive_loop())
                group.create_task(self._send_loop())
                group.create_task(self._stop_watch())
        except* _Stop:
            pass

    def stop(self, code):
        """End this connection with `code`, from anywhere including a sync sink.

        First writer wins: a socket that trips the rate cap while a revocation is
        already in flight closes for one reason, not two.
        """
        if self._close_code is None:
            self._close_code = code
        self._stop.set()

    async def _stop_watch(self):
        await self._stop.wait()
        raise _Stop

    async def _cleanup(self):
        if self.device_topic is None:
            return  # the bind failed before it registered anything
        await bus.get_subscriber().unsubscribe(self.device_topic, self.deliver)

    async def _close(self):
        if self._close_code is None:
            return  # the client went away first; there is nothing to answer
        try:
            await self.websocket.close(code=self._close_code)
        except RuntimeError:
            # Starlette refuses a second close, and the client may already have
            # dropped. Silent: the message would name the socket.
            pass

    # ---- the bus sink ----------------------------------------------------
    def deliver(self, payload):
        """Hand one bus payload to this socket. Synchronous, and never blocks:
        the subscriber fans out to every sink in turn, so an await here would let
        one slow socket hold up every other socket of the process."""
        if payload.get("type") == bus.CLOSE:
            self.stop(4003)
            return
        try:
            self._outbox.put_nowait(payload)
        except asyncio.QueueFull:
            self.stop(4008)  # a slow consumer is a protocol violation

    async def _send_loop(self):
        while True:
            frame = await self._outbox.get()
            try:
                await self.websocket.send_text(json.dumps(frame))
            except (RuntimeError, OSError):
                self.stop(None)
                raise _Stop from None

    # ---- inbound ---------------------------------------------------------
    async def _receive_loop(self):
        while True:
            message = await self.websocket.receive()
            if message["type"] == "websocket.disconnect":
                self.stop(None)
                raise _Stop
            if message.get("bytes") is not None:
                self._violation()  # this protocol is JSON text only
            text = message.get("text") or ""
            if len(text) > settings.WS_MAX_FRAME:
                self._violation()
            if not self._rate_ok():
                self._violation()
            try:
                content = json.loads(text)
            except ValueError:
                # Undecodable JSON is a protocol violation, not a gateway crash:
                # the WS twin of the REST guard for malformed bodies.
                self._violation()
            if not isinstance(content, dict):
                # A JSON scalar or array frame decodes fine but has no `.get()`;
                # the same bug class the REST ack guards against.
                self._violation()
            await self._handle(content)

    def _violation(self):
        self.stop(4008)
        raise _Stop

    async def _handle(self, content):
        message_type = content.get("type")
        if message_type == "ack":
            await self._handle_ack(content)
        elif message_type == "signal":
            await self._handle_signal(content)
        # Unknown types are ignored (but counted by the rate limiter above).

    async def _handle_ack(self, content):
        ids = content.get("ids") or []
        if not (isinstance(ids, list) and 0 < len(ids) <= ACK_IDS_MAX):
            return
        try:
            # Unparsed, a non-UUID id reaches the uuid pk column and raises
            # Django's ValidationError, the identical 500 the REST ack guards
            # against. Malformed acks are dropped like malformed signals.
            parsed = [uuid.UUID(str(i)) for i in ids]
        except (AttributeError, TypeError, ValueError):
            return
        await auth.delete_envelopes(self.device.id, parsed)

    async def _handle_signal(self, content):
        to_device = content.get("to_device")
        blob = content.get("blob")
        # Volatile relay: forward opaque ciphertext, drop it if the target is
        # offline, and never persist or log to_device or blob.
        if not to_device or not signal_blob_ok(blob):
            return
        try:
            # Normalized, not raw: uuid.UUID accepts braced/urn/uppercase
            # spellings, and a topic built from one of those is a topic the
            # target never subscribed to.
            to_device = str(uuid.UUID(str(to_device)))
        except (ValueError, TypeError):
            return
        await bus.relay_signal(to_device, blob)

    # ---- helpers ---------------------------------------------------------
    async def _bind(self, token_str):
        result = await auth.authenticate_session(token_str)
        if result is None:
            return False
        self.user, self.device = result
        self.device_topic = bus.device_topic(self.device.id)
        await bus.get_subscriber().subscribe(self.device_topic, self.deliver)
        await auth.touch_active(self.device.id)
        return True

    def _rate_ok(self):
        now = time.monotonic()
        self._msg_times = [t for t in self._msg_times if now - t < RATE_WINDOW_SECONDS]
        self._msg_times.append(now)
        return len(self._msg_times) <= RATE_MAX_IN_WINDOW


def signal_blob_ok(blob):
    """True when `blob` is standard base64 of exactly one signal bucket.

    The padding rule of every stored ciphertext, applied to the one ciphertext
    the server relays without storing: length is the one thing a relay can see,
    so a blob outside the bucket set is a malformed frame and is dropped in
    silence like every other malformed but well-typed frame. It is a guard and
    never a security control — a modified server would relay anything. The
    decoder is the one every route uses; its refusal is a drop here where a
    route answers `400 bad_bucket`.
    """
    if not isinstance(blob, str) or len(blob) > SIGNAL_BLOB_MAX:
        return False
    try:
        decode_blob_or_400(blob, SIGNAL_BUCKETS)
    except BadBucket:
        return False
    return True


def _header_token(websocket):
    header = websocket.headers.get("authorization")
    if not header:
        return None
    parts = header.split()
    return parts[1] if len(parts) == 2 and parts[0] == "Bearer" else None
