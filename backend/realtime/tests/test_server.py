"""What a real server does with the gateway, as against what the application says.

Every other suite here drives the ASGI application directly, which is where the
close codes live and where the frame protocol is decided. Two lines of
`realtime/API.md` are not the application's to keep, though, and only a server
can settle them:

- Every refusal is decided before the accept, so it is a `websocket.close` at the
  ASGI layer — but a server has no accepted socket to send a close frame on. It
  answers the handshake with `403 Forbidden` instead. The documentation says so
  because of this test.
- `1012` on shutdown is uvicorn's, not this application's: uvicorn closes each
  live socket itself before the lifespan shutdown runs, so `gateway.drain` never
  sees them on the normal path.

The flags below are the ones `ops/systemd/chat.service` runs with, so a change to
either implementation is caught here rather than on the VPS.
"""

import asyncio
import socket
import threading

import pytest
import uvicorn
import websockets
from websockets.exceptions import ConnectionClosed, InvalidStatus

from .conftest import mint_session

pytestmark = pytest.mark.django_db(transaction=True)

STARTUP_TIMEOUT_SECONDS = 10


class Server:
    """One uvicorn process-in-a-thread, on a port the kernel picks.

    The socket is bound here rather than by uvicorn so the test knows the port
    without polling for it, and the server runs in a thread of its own with its
    own event loop — which is the shape production runs in, and the reason this
    file cannot use the in-process driver the rest of the suite uses.
    """

    def __init__(self):
        self.socket = socket.socket()
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(("127.0.0.1", 0))
        self.port = self.socket.getsockname()[1]
        self.server = uvicorn.Server(
            uvicorn.Config(
                "config.asgi:application",
                log_config=None,
                access_log=False,
                ws="websockets-sansio",
                timeout_graceful_shutdown=5,
            )
        )
        self.thread = threading.Thread(
            target=self.server.run, kwargs={"sockets": [self.socket]}, daemon=True
        )

    @property
    def url(self):
        return f"ws://127.0.0.1:{self.port}/ws"

    async def start(self):
        self.thread.start()
        async with asyncio.timeout(STARTUP_TIMEOUT_SECONDS):
            while not self.server.started:
                await asyncio.sleep(0.01)

    async def stop(self):
        self.server.should_exit = True
        async with asyncio.timeout(STARTUP_TIMEOUT_SECONDS):
            while self.thread.is_alive():
                await asyncio.sleep(0.01)


@pytest.fixture
async def server():
    running = Server()
    await running.start()
    try:
        yield running
    finally:
        await running.stop()


async def test_a_refused_token_is_a_failed_handshake(server, db):
    """The gateway binds before the accept, so a token that fails ends the
    handshake: there is no accepted socket to carry a close code, and a client
    must read a failed upgrade as "renew the session token and reconnect"
    rather than wait for one."""
    with pytest.raises(InvalidStatus) as refusal:
        await websockets.connect(
            server.url, additional_headers={"authorization": "Bearer not-a-jwt"}
        )

    assert refusal.value.response.status_code == 403


async def test_a_handshake_with_no_token_is_refused_the_same_way(server, db):
    """The one handshake path carries the token on the upgrade request. Without
    the header there is nothing to authenticate, and the refusal is the same
    `403` — not an accepted socket waiting for the client to say something."""
    with pytest.raises(InvalidStatus) as refusal:
        await websockets.connect(server.url)

    assert refusal.value.response.status_code == 403


async def test_a_shutdown_closes_a_live_socket_with_1012(server, active_user, device):
    """The drain window of `ops/systemd/chat.service`, exercised end to end: a
    deploy has to reach the client as a reconnect signal, not as a dropped
    connection it will retry blindly."""
    access = await mint_session(active_user, device)

    async with websockets.connect(
        server.url, additional_headers={"authorization": f"Bearer {access}"}
    ) as client:
        await server.stop()

        with pytest.raises(ConnectionClosed) as closed:
            await client.recv()

    assert closed.value.rcvd is not None, "the socket dropped without a close frame"
    assert closed.value.rcvd.code == 1012


async def test_a_protocol_violation_after_the_accept_arrives_as_a_close_frame(
    server, active_user, device
):
    """The other half of what this file exists to draw. A refusal decided before
    the accept is an HTTP failure with no code on it; once a socket is accepted
    the documented code is a real close frame, and a client can read it."""
    access = await mint_session(active_user, device)

    async with websockets.connect(
        server.url, additional_headers={"authorization": f"Bearer {access}"}
    ) as client:
        await client.send(b"\x00\x01")  # binary: this protocol is JSON text only

        with pytest.raises(ConnectionClosed) as closed:
            async with asyncio.timeout(STARTUP_TIMEOUT_SECONDS):
                await client.recv()

    assert closed.value.rcvd is not None, "the socket dropped without a close frame"
    assert closed.value.rcvd.code == 4008
