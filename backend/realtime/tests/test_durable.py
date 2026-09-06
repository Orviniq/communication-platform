"""Durable path: a live push mirrors the queue row; an ack deletes it. The row, not
the frame, is the source of truth. The send route enqueues, the socket optimizes."""

import pytest

from api.orm import run_unit
from core.buckets import ENVELOPE_BUCKETS
from messaging.models import QueuedEnvelope
from realtime import gateway

from .conftest import (
    bearer,
    connect_ok,
    envelope_blob,
    http_request,
    mint_session,
    probe,
)

pytestmark = pytest.mark.django_db(transaction=True)

SEND_URL = "/api/v1/envelopes"


async def send(access, device_id, blob):
    return await http_request(
        "POST",
        SEND_URL,
        access,
        json={"messages": [{"device_id": str(device_id), "blob": blob}]},
    )


async def queue_count(device_id):
    return await run_unit(
        QueuedEnvelope.objects.filter(recipient_device_id=device_id).count
    )


async def test_enqueued_envelope_is_pushed_acked_and_deleted(
    active_user, device, peer, peer_device
):
    """The headline durable exit test: enqueue via the messaging service, receive the
    `envelope` frame, ack it, and the queue row is gone."""
    comm = await connect_ok(bearer(await mint_session(peer, peer_device)))
    blob = envelope_blob(b"d")

    resp = await send(await mint_session(active_user, device), peer_device.id, blob)
    assert resp.status_code == 202 and resp.json()["accepted"] == 1

    frame = await comm.receive_json_from(timeout=2)
    row = await run_unit(QueuedEnvelope.objects.get, recipient_device_id=peer_device.id)
    assert frame == {"type": "envelope", "id": str(row.id), "seq": 1, "blob": blob}

    await comm.send_json_to({"type": "ack", "ids": [frame["id"]]})
    await probe(comm, peer_device.id)  # barrier: the ack has been fully processed
    assert await queue_count(peer_device.id) == 0
    await comm.disconnect()


async def test_ack_only_touches_the_calling_devices_rows(
    active_user, device, peer, peer_device
):
    """Device A acking device B's envelope id must delete nothing: the socket's
    device identity scopes the delete exactly like REST's ack."""
    row = await run_unit(
        QueuedEnvelope.objects.create,
        recipient_device_id=peer_device.id,
        seq=1,
        blob=b"e" * min(ENVELOPE_BUCKETS),
    )
    comm = await connect_ok(bearer(await mint_session(active_user, device)))

    await comm.send_json_to({"type": "ack", "ids": [str(row.id)]})
    await probe(comm, device.id)

    assert await queue_count(peer_device.id) == 1
    await comm.disconnect()


async def test_malformed_ack_ids_are_dropped_without_killing_the_socket(
    active_user, device
):
    """Non-UUID ids never reach the pk column (the WS twin of the ack route's
    guard); the socket survives and later frames still work."""
    comm = await connect_ok(bearer(await mint_session(active_user, device)))

    await comm.send_json_to({"type": "ack", "ids": ["not-a-uuid", {"nested": 1}]})
    await comm.send_json_to({"type": "ack", "ids": "not-a-list"})
    await comm.send_json_to({"type": "ack", "ids": [str(n) for n in range(201)]})

    await probe(comm, device.id)  # still alive, nothing crashed
    await comm.disconnect()


async def queued(device_id, count):
    """`count` rows waiting in one device's durable queue."""
    return await run_unit(
        QueuedEnvelope.objects.bulk_create,
        [
            QueuedEnvelope(
                recipient_device_id=device_id,
                seq=index + 1,
                blob=b"e" * min(ENVELOPE_BUCKETS),
            )
            for index in range(count)
        ],
    )


async def test_an_ack_of_exactly_the_id_cap_clears_every_row_it_names(
    active_user, device
):
    """200 is what a REST drain hands back at most, so it is what one ack has to be
    able to clear. A cap that admitted 199 would leave a row the client believes it
    acked, and the client would be pushed it again on its next reconnect."""
    rows = await queued(device.id, gateway.ACK_IDS_MAX)
    comm = await connect_ok(bearer(await mint_session(active_user, device)))

    await comm.send_json_to({"type": "ack", "ids": [str(row.id) for row in rows]})
    await probe(comm, device.id)  # barrier: the ack has been fully processed

    assert await queue_count(device.id) == 0
    await comm.disconnect()


async def test_an_ack_of_one_id_past_the_cap_deletes_nothing_at_all(active_user, device):
    """Over-cap acks are dropped whole rather than truncated. Deleting the first 200
    of 201 would tell the client its whole batch was cleared while one row stayed
    behind, and truncation is how an unbounded `id__in` gets in through the back
    door."""
    rows = await queued(device.id, gateway.ACK_IDS_MAX + 1)
    comm = await connect_ok(bearer(await mint_session(active_user, device)))

    await comm.send_json_to({"type": "ack", "ids": [str(row.id) for row in rows]})
    await probe(comm, device.id)

    assert await queue_count(device.id) == len(rows)
    await comm.disconnect()


async def test_every_socket_of_one_device_receives_the_same_envelope_push(
    active_user, device, peer, peer_device
):
    """A phone and a laptop signed in as one device are two sockets on one topic.
    Both are live, so both are pushed; the row behind them is one row, and either
    socket's ack clears it."""
    first = await connect_ok(bearer(await mint_session(peer, peer_device)))
    second = await connect_ok(bearer(await mint_session(peer, peer_device)))
    blob = envelope_blob(b"t")

    resp = await send(await mint_session(active_user, device), peer_device.id, blob)
    assert resp.status_code == 202

    row = await run_unit(QueuedEnvelope.objects.get, recipient_device_id=peer_device.id)
    expected = {"type": "envelope", "id": str(row.id), "seq": 1, "blob": blob}
    assert await first.receive_json_from(timeout=2) == expected
    assert await second.receive_json_from(timeout=2) == expected

    await first.send_json_to({"type": "ack", "ids": [str(row.id)]})
    await probe(first, peer_device.id)
    assert await queue_count(peer_device.id) == 0
    await first.disconnect()
    await second.disconnect()


async def test_closing_one_socket_of_a_device_leaves_the_other_delivering(
    active_user, device, peer, peer_device
):
    """The topic is released when its last sink goes, not when its first does.
    Unsubscribing on the first disconnect would silence the device's other socket
    until it happened to reconnect."""
    first = await connect_ok(bearer(await mint_session(peer, peer_device)))
    second = await connect_ok(bearer(await mint_session(peer, peer_device)))
    blob = envelope_blob(b"s")

    await first.disconnect()
    resp = await send(await mint_session(active_user, device), peer_device.id, blob)
    assert resp.status_code == 202

    frame = await second.receive_json_from(timeout=2)
    assert frame["blob"] == blob
    await second.disconnect()
