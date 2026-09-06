"""Nothing on the realtime path logs an identifier, a target, or a payload.

Like the messaging/devices suites, capture must bypass the configured ScrubFilter to
assert the code never emits an identifier in the first place. caplog is not enough:
the filter mutates records in place, so the console handler launders the message
before caplog's later-attached handler stores it, and a leak would grade its own
homework. So, like assertLogs, all root handlers are swapped out for the capture
window."""

import logging
import uuid
from contextlib import contextmanager

import pytest

from realtime import bus, gateway

from .conftest import (
    bearer,
    connect_ok,
    envelope_blob,
    expect_close,
    expect_refused,
    mint_session,
    probe,
    signal_blob,
)

# A string no client should ever send: a NUL, two more control characters, and
# enough shape to be recognisable if any layer echoes it back.
CONTROL_BLOB = "ciphertext\x00\x01\x1f-with-control-characters"

pytestmark = pytest.mark.django_db(transaction=True)


class _RawCapture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


@contextmanager
def raw_root_capture():
    root = logging.getLogger()
    handler = _RawCapture()
    old_handlers, old_level = root.handlers[:], root.level
    root.handlers[:] = [handler]
    root.setLevel(logging.DEBUG)
    try:
        yield handler.lines
    finally:
        root.handlers[:] = old_handlers
        root.setLevel(old_level)


async def test_every_socket_scenario_emits_no_identifier_or_payload(
    active_user, device, peer, peer_device
):
    access_a = await mint_session(active_user, device)
    access_b = await mint_session(peer, peer_device)
    volatile_blob = signal_blob(b"v")
    push_blob = envelope_blob(b"l")
    offline_target = str(uuid.uuid4())

    with raw_root_capture() as lines:
        logging.getLogger("test.canary").debug("canary")

        # Two authenticated sockets, one for each account.
        comm_a = await connect_ok(bearer(access_a))
        comm_b = await connect_ok(bearer(access_b))

        # Durable push and ack, including a malformed ack.
        await bus.push_envelopes([(device.id, str(uuid.uuid4()), 1, push_blob)])
        frame = await comm_a.receive_json_from(timeout=2)
        await comm_a.send_json_to({"type": "ack", "ids": [frame["id"]]})
        await comm_a.send_json_to({"type": "ack", "ids": [str(device.id) + "-corrupt"]})

        # Volatile signals: delivered, offline target, malformed target, off-bucket
        # blob, then the disconnect and the cleanup it runs.
        await comm_a.send_json_to(
            {"type": "signal", "to_device": str(peer_device.id), "blob": volatile_blob}
        )
        assert await comm_b.receive_json_from(timeout=2) == {
            "type": "signal",
            "blob": volatile_blob,
        }
        await comm_a.send_json_to(
            {"type": "signal", "to_device": offline_target, "blob": volatile_blob}
        )
        await comm_a.send_json_to(
            {"type": "signal", "to_device": "not-a-uuid", "blob": volatile_blob}
        )
        await comm_a.send_json_to(
            {"type": "signal", "to_device": str(peer_device.id), "blob": "off-bucket"}
        )
        await comm_a.disconnect()
        await comm_b.disconnect()

        # A refused handshake — with a bad token, and with none at all — and a
        # protocol-violation close.
        await expect_refused(bearer("garbage-token"))
        await expect_refused([])
        binary = await connect_ok(bearer(access_a))
        await binary.send_to(bytes_data=b"\x00")
        await expect_close(binary, 4008)
        await binary.disconnect()

    assert any("canary" in line for line in lines), "log capture was not live"
    forbidden = {
        "sender device id": str(device.id),
        "target device id": str(peer_device.id),
        "offline to_device": offline_target,
        "signal blob": volatile_blob,
        "envelope blob": push_blob,
        "access token A": access_a,
        "access token B": access_b,
        "user id": str(active_user.id),
        "peer user id": str(peer.id),
    }
    for line in lines:
        for label, secret in forbidden.items():
            assert secret not in line, f"{label} leaked into a log line: {line[:80]}"


async def test_the_whole_malformed_frame_class_emits_no_identifier_or_payload(
    active_user, device, peer, peer_device
):
    """Every shape a client can get wrong, in one capture window.

    The frames that are dropped go down one socket, because the point of dropping
    them is that the socket survives; each frame that closes needs a socket of its
    own. A traceback is the usual way a value reaches a log line, so the frames
    carrying control characters and a NUL are here as much for the close paths as
    for the parse.
    """
    access = await mint_session(active_user, device)

    with raw_root_capture() as lines:
        logging.getLogger("test.canary").debug("canary")

        comm = await connect_ok(bearer(access))
        for frame in (
            {"type": "ack", "ids": "not-a-list"},
            {"type": "ack", "ids": []},
            {"type": "ack", "ids": [str(uuid.uuid4()) for _ in range(201)]},
            {"type": "ack", "ids": [CONTROL_BLOB]},
            {"type": "signal", "to_device": str(peer_device.id), "blob": 7},
            {"type": "signal", "to_device": str(peer_device.id), "blob": CONTROL_BLOB},
            {"type": "signal", "to_device": CONTROL_BLOB, "blob": signal_blob()},
            {"type": CONTROL_BLOB},
        ):
            await comm.send_json_to(frame)
        await probe(comm, device.id)  # every one of them dropped, the socket alive
        await comm.disconnect()

        for text, binary in (
            ("{definitely not json", None),
            ('"a scalar"', None),
            ("[1, 2, 3]", None),
            (None, CONTROL_BLOB.encode()),
        ):
            closing = await connect_ok(bearer(access))
            await closing.send_to(text_data=text, bytes_data=binary)
            await expect_close(closing, 4008)

    assert any("canary" in line for line in lines), "log capture was not live"
    forbidden = {
        "device id": str(device.id),
        "peer device id": str(peer_device.id),
        "control payload": CONTROL_BLOB,
        "access token": access,
        "user id": str(active_user.id),
    }
    for line in lines:
        for label, secret in forbidden.items():
            assert secret not in line, f"{label} leaked into a log line: {line[:80]}"


async def test_a_slow_consumer_close_names_neither_the_device_nor_its_backlog(
    active_user, device, monkeypatch
):
    """The one close the client did not ask for by sending a bad frame. Whatever the
    server says about it would name the socket it dropped, and the frames it was
    holding for that socket are envelopes."""
    monkeypatch.setattr(gateway, "SEND_QUEUE_MAX", 2)
    blob = envelope_blob(b"q")

    with raw_root_capture() as lines:
        logging.getLogger("test.canary").debug("canary")
        # The wire holds one frame, so a peer that never reads blocks the send loop
        # after the first and everything behind it piles up in the send queue.
        comm = await connect_ok(
            bearer(await mint_session(active_user, device)), outbound_max=1
        )
        for index in range(10):
            await bus.push_envelopes([(device.id, str(uuid.uuid4()), index + 1, blob)])
        while True:
            out = await comm.receive_output(timeout=2)
            if out["type"] == "websocket.close":
                assert out["code"] == 4008
                break

    assert any("canary" in line for line in lines), "log capture was not live"
    for line in lines:
        assert str(device.id) not in line, f"the device id leaked: {line[:80]}"
        assert blob not in line, f"an envelope blob leaked: {line[:80]}"
