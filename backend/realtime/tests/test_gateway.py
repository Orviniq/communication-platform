"""The `Connection` object's own failure paths, which no socket driven end to end
reaches.

Everything a client can cause — a bad frame, a rate burst, a revocation, a
shutdown — is driven through the real ASGI application in the suites beside this
one, and that is where those belong. What is left here is what the transport
underneath can do to a connection that is behaving: refuse a second close, raise
out of a send, hand back a control event that is not a frame, or fill the one
buffer an outside writer fills. A `WebSocket` reached through the in-process
driver never does any of those, because the driver's send is a queue put and its
close is a message — so this file drives `Connection` against a transport of its
own, and asserts on the close code and the frames that transport received.
"""

import asyncio
import json

import pytest
from hypothesis import given
from hypothesis import strategies as st

from api.redis import close_client
from realtime import bus, gateway

from .conftest import PROBE_BLOB, bearer, connect_ok, mint_session, probe

pytestmark = pytest.mark.django_db(transaction=True)

DELIVERY_TIMEOUT = 5


async def wait_for(predicate, timeout=DELIVERY_TIMEOUT):
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.01)


class _Transport:
    """Stands in for the Starlette `WebSocket`, recording what the connection sent.

    `send_error` and `close_error` are the two things a real transport does that
    the in-process driver cannot be made to do: a peer that vanished mid-send, and
    Starlette refusing a close on a socket it has already closed.
    """

    def __init__(self, send_error=None, close_error=None):
        self.sent = []
        self.closes = []
        self._send_error = send_error
        self._close_error = close_error

    async def accept(self):
        pass

    async def send_text(self, text):
        if self._send_error is not None:
            raise self._send_error
        self.sent.append(text)

    async def close(self, code=None):
        self.closes.append(code)
        if self._close_error is not None:
            raise self._close_error


def signal_frame(index):
    return {"type": "signal", "blob": f"frame-{index}"}


async def test_a_close_the_transport_refuses_is_swallowed():
    """Starlette raises on a close for a socket it has already closed, and the peer
    may have dropped before either. The refusal arrives on the way out of `serve`,
    where raising would replace the connection's own reason for closing with the
    transport's, and would name the socket in the traceback."""
    transport = _Transport(
        close_error=RuntimeError('Cannot call "send" once a close message has been sent')
    )
    connection = gateway.Connection(transport)
    connection.stop(4008)

    assert await connection._close() is None

    assert transport.closes == [4008]


async def test_a_transport_that_raises_mid_send_closes_with_no_code_at_all():
    """A send that raises means the peer is already gone, so there is nothing to
    answer: the connection stops with no code and the cleanup sends no close
    frame. A code invented here would be a frame written to a dead socket."""
    transport = _Transport(send_error=OSError("the peer went away"))
    connection = gateway.Connection(transport)
    connection.deliver(signal_frame(0))

    with pytest.raises(gateway._Stop):
        await connection._send_loop()

    assert await connection._close() is None
    assert (transport.sent, transport.closes) == ([], [])


async def test_the_first_reason_to_close_is_the_one_the_client_is_given():
    """A revocation and a protocol violation can land on one socket in the same
    tick — the bus sink runs from the reader task while the receive loop is
    parsing a frame. The client must be told one reason, and it must be the one
    that decided the socket was over."""
    connection = gateway.Connection(_Transport())

    connection.stop(4003)
    connection.stop(4008)
    await connection._close()

    assert connection.websocket.closes == [4003]


async def test_a_bus_close_event_closes_the_socket_and_is_never_forwarded():
    """`socket.close` is a control event this module owns, not a server frame of
    `realtime/API.md`. Queueing it would hand the client a frame type the contract
    does not define, and would leak that a revocation happened over a socket that
    is about to close for that reason anyway."""
    connection = gateway.Connection(_Transport())

    connection.deliver({"type": bus.CLOSE})
    with pytest.raises(TimeoutError):
        await asyncio.wait_for(connection._send_loop(), 0.05)
    await connection._close()

    assert connection.websocket.sent == []
    assert connection.websocket.closes == [4003]


async def test_the_outbox_takes_its_bound_and_closes_the_socket_on_the_frame_past_it(
    monkeypatch,
):
    """The send queue is the one per-connection buffer an outside writer fills, so
    it is the one that grows without the client asking for anything. At the bound
    the socket is still healthy; one frame past it the socket is a slow consumer
    and 1 GB across every live socket is what makes that non-negotiable."""
    monkeypatch.setattr(gateway, "SEND_QUEUE_MAX", 4)

    at_the_bound = gateway.Connection(_Transport())
    for index in range(gateway.SEND_QUEUE_MAX):
        at_the_bound.deliver(signal_frame(index))
    await at_the_bound._close()

    past_the_bound = gateway.Connection(_Transport())
    for index in range(gateway.SEND_QUEUE_MAX + 1):
        past_the_bound.deliver(signal_frame(index))
    await past_the_bound._close()

    assert at_the_bound.websocket.closes == []
    assert past_the_bound.websocket.closes == [4008]


async def test_a_refused_handshake_runs_no_cleanup_and_joins_nothing(db):
    """The cleanup is what the bind pays for, so it runs only inside the accept.

    A refusal returns before it: nothing to announce offline and no topic to give
    back, because none was ever taken. Were the refusal inside the
    `finally` instead, the cleanup would read the device the connection does not
    have and raise on the way out of a handshake that had already been answered.
    """
    transport = _Transport()
    connection = gateway.Connection(transport)

    await connection.serve(None)

    assert transport.closes == [None]  # refused with no code; the server answers 403
    assert connection not in gateway.LIVE
    assert bus.get_subscriber()._sinks == {}


async def test_a_client_that_went_away_first_is_answered_with_no_close_frame(
    active_user, device
):
    """The disconnect is the client saying the socket is over. There is nothing to
    close, and a close frame written into a transport the server already tore down
    is what `_close`'s guard exists to avoid."""
    comm = await connect_ok(bearer(await mint_session(active_user, device)))
    await probe(comm, device.id)

    await comm.disconnect()

    assert await comm.receive_nothing(timeout=0.2)
    assert gateway.LIVE == set()
    assert bus.get_subscriber()._sinks == {}


# ---- every client frame, generated ------------------------------------------

# The field values a client can put where the contract wants an identifier or an
# opaque blob. Bounded, because the point is the shape rather than the size: the
# lengths are pinned by the cap tests in `test_limits.py`.
IDENTIFIERS = st.one_of(
    st.uuids().map(str),
    st.text(max_size=12),
    st.integers(),
    st.booleans(),
    st.none(),
    st.lists(st.integers(), max_size=2),
)
BLOBS = st.one_of(
    st.text(max_size=64),
    st.integers(),
    st.none(),
    st.dictionaries(st.text(max_size=4), st.integers(), max_size=2),
)
CLIENT_FRAMES = st.one_of(
    st.fixed_dictionaries(
        {
            "type": st.just("ack"),
            "ids": st.one_of(st.lists(IDENTIFIERS, max_size=4), IDENTIFIERS),
        }
    ),
    st.fixed_dictionaries(
        {"type": st.just("signal"), "to_device": IDENTIFIERS, "blob": BLOBS}
    ),
    st.fixed_dictionaries({"type": st.text(max_size=8)}),
    st.dictionaries(st.text(max_size=6), st.integers(), max_size=3),
)

# The only codes `realtime/API.md` lets a frame produce. Every socket below is
# authenticated, because the handshake is the only place a socket can be.
DOCUMENTED = (None, 4008)


@pytest.fixture
def run():
    """One event loop, and therefore one Redis client and one subscriber, for every
    example.

    `@given` re-enters the test body once per example, and both of those objects
    are keyed by the running loop. A loop per example would leave a client and a
    live reader task behind on a loop that is already closed — which is the shape
    `realtime/tests/socket.py` rejected the synchronous test clients for.
    """
    loop = asyncio.new_event_loop()
    try:
        yield loop.run_until_complete
    finally:
        loop.run_until_complete(bus.stop_subscriber())
        loop.run_until_complete(close_client())
        loop.close()


async def send_and_settle(user, device, batch):
    """One authenticated socket, `batch`, and then a probe. Returns the close code
    the socket ended on, or None if it is still open.

    The driver re-raises whatever the application raised, so an exception escaping
    the gateway fails the example here rather than showing up as a timeout.
    """
    comm = await connect_ok(bearer(await mint_session(user, device)))
    try:
        for frame in batch:
            await comm.send_json_to(frame)
        await comm.send_json_to(
            {"type": "signal", "to_device": str(device.id), "blob": PROBE_BLOB}
        )
        while True:
            message = await comm.receive_output(timeout=5)
            if message["type"] == "websocket.close":
                return message.get("code")
            if json.loads(message["text"]) == {"type": "signal", "blob": PROBE_BLOB}:
                return None
    finally:
        await comm.disconnect()


@given(batch=st.lists(CLIENT_FRAMES, min_size=1, max_size=4))
def test_no_client_frame_ends_a_socket_outside_the_documented_codes(
    active_user, device, run, batch
):
    """The whole client half of `realtime/API.md`, generated: whatever the frame,
    the socket either carries on or closes with a code the contract publishes.
    Nothing raises out of the application — an exception here is a socket dropped
    with no code, and a traceback carrying whatever the client sent."""
    assert run(send_and_settle(active_user, device, batch)) in DOCUMENTED
