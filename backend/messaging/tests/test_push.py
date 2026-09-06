"""The live push is an optimization layered over the durable mailbox."""

import base64
import json
import time
from unittest import mock

import pytest
import redis
from django.utils import timezone
from redis.asyncio import Redis
from redis.asyncio.client import Pipeline

from devices.models import Device
from messaging.models import QueuedEnvelope
from realtime import bus

from .conftest import envelope_blob, make_device

pytestmark = pytest.mark.django_db(transaction=True)

SEND_URL = "/api/v1/envelopes"
DEAD_REDIS_URL = "redis://127.0.0.1:6390"


class Listener:
    """Stand in for the gateway, which subscribes to `ws:dev:<device id>` on bind.

    A real subscription on the real bus, because the bus is the contract under
    test: what the route publishes has to be what a socket would have received.

    Synchronous redis-py, not the async client the gateway uses: the send route is
    driven by the synchronous test client, which builds a fresh event loop for
    each call, and an async connection belongs to the loop that opened it — read
    from a second loop it never returns.
    """

    def __init__(self, url, topic):
        self.topic = topic
        self._client = redis.Redis.from_url(url)
        # The same push handler the bus passes, for the same reason: redis-py's
        # default logs the topic and the payload it just received.
        self._pubsub = self._client.pubsub(push_handler_func=lambda response: response)

    def __enter__(self):
        self._pubsub.subscribe(self.topic)
        # Read the SUBSCRIBE confirmation before the test publishes anything: the
        # command is sent without waiting for its reply, and Redis drops a publish
        # that lands before the server holds the subscription.
        self._await_kind("subscribe")
        return self

    def __exit__(self, *_exc):
        self._pubsub.close()
        self._client.close()

    def _await_kind(self, kind, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise AssertionError(f"no {kind} message on {self.topic} in {timeout}s")
            message = self._pubsub.get_message(timeout=left)
            if message is not None and message["type"] == kind:
                return message

    def receive(self, timeout=5):
        return json.loads(self._await_kind("message", timeout)["data"])

    def received_nothing(self, timeout=0.5):
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return True
            message = self._pubsub.get_message(timeout=left)
            if message is not None and message["type"] == "message":
                return False


@pytest.fixture
def listener(settings):
    def build(device_id):
        return Listener(settings.REDIS_URL, bus.device_topic(device_id))

    return build


def test_an_accepted_envelope_is_pushed_to_the_devices_topic(
    http, active_user, device, bearer, bob_devices, listener
):
    target = bob_devices[0]
    blob = envelope_blob(b"p")

    with listener(target.id) as subscriber:
        resp = http.post(
            SEND_URL,
            json={"messages": [{"device_id": str(target.id), "blob": blob}]},
            headers=bearer(active_user, device),
        )

        assert resp.status_code == 202
        message = subscriber.receive()

    assert message["type"] == "envelope"
    assert message["blob"] == blob
    assert message["seq"] == 1


def test_a_send_to_a_device_with_no_socket_is_a_no_op(
    http, active_user, device, bearer, bob_devices
):
    """A publish to a topic nobody holds is dropped by Redis; the row is what
    matters."""
    resp = http.post(
        SEND_URL,
        json={
            "messages": [{"device_id": str(bob_devices[0].id), "blob": envelope_blob()}]
        },
        headers=bearer(active_user, device),
    )

    assert resp.status_code == 202
    assert (
        QueuedEnvelope.objects.filter(recipient_device_id=bob_devices[0].id).count() == 1
    )


def test_a_dead_bus_does_not_fail_the_send(
    http, active_user, device, bearer, bob_devices, monkeypatch
):
    """The rows are already committed, so a push failure must not 500; the client
    would retry and duplicate every envelope.

    Only the bus is pointed at the dead port. Redis itself has to stay up, because
    the rate limiter of this route fails closed and would answer 503 before the
    send ever ran — which would pass this assertion for the wrong reason.
    """
    monkeypatch.setattr(bus, "get_client", lambda: Redis.from_url(DEAD_REDIS_URL))

    resp = http.post(
        SEND_URL,
        json={
            "messages": [{"device_id": str(bob_devices[0].id), "blob": envelope_blob()}]
        },
        headers=bearer(active_user, device),
    )

    assert resp.status_code == 202
    assert (
        QueuedEnvelope.objects.filter(recipient_device_id=bob_devices[0].id).count() == 1
    )


def test_a_rolled_back_send_publishes_nothing(
    http, active_user, device, bearer, bob_devices, listener, monkeypatch
):
    """The publish is after the commit, never inside the transaction.

    A frame announced for a row a rollback then takes away is worse than no frame
    at all: the client would ack an envelope id this server has never held, and
    the ack — which matches nothing — would look to it like delivery succeeded.

    The mutation is the last statement of the unit, so the counters really have
    moved when it fails; `queue_seq` back at 0 is what proves the rollback
    happened rather than that the unit never ran.
    """
    target = bob_devices[0]

    def explode(*_args, **_kwargs):
        raise RuntimeError("the insert fails after the counters have moved")

    monkeypatch.setattr(QueuedEnvelope.objects, "bulk_create", explode)

    with listener(target.id) as subscriber:
        # The failure reaches the test rather than rendering the `server_error`
        # envelope: Starlette's error middleware re-raises after answering, and
        # the ASGI transport this client uses re-raises in turn, which is what
        # keeps a 500 from being mistaken for a passing request.
        with pytest.raises(RuntimeError):
            http.post(
                SEND_URL,
                json={
                    "messages": [{"device_id": str(target.id), "blob": envelope_blob()}]
                },
                headers=bearer(active_user, device),
            )

        assert subscriber.received_nothing()

    assert QueuedEnvelope.objects.filter(recipient_device_id=target.id).count() == 0
    assert Device.objects.get(id=target.id).queue_seq == 0


def test_a_batch_send_publishes_every_copy_in_one_round_trip(
    http, active_user, device, bearer, bob, listener
):
    """One `POST /envelopes` names up to 256 recipient devices, and one awaited
    publish each is 256 sequential round trips on the event loop — 37.1 ms
    measured on loopback, against 1.5 ms for the pipeline. The loop is the whole
    process on one vCPU, so the fan-out costs one round trip whatever the batch.
    """
    targets = [make_device(bob, 400 + index) for index in range(6)]
    body = {
        "messages": [
            {"device_id": str(target.id), "blob": envelope_blob(b"q")}
            for target in targets
        ]
    }
    headers = bearer(active_user, device)
    executes, publishes = [], []
    real_execute, real_command = Pipeline.execute, Redis.execute_command

    async def counted_execute(self, *args, **kwargs):
        # The fan-out's own pipeline, and not every pipeline the request opens:
        # `api/ratelimit.py` also batches its counter and its expiry into one, and
        # counting that one here would make this assertion about the limiter.
        queued = [entry[0][0] for entry in self.command_stack if entry and entry[0]]
        if "PUBLISH" in queued:
            executes.append(1)
        return await real_execute(self, *args, **kwargs)

    async def counted_command(self, *args, **kwargs):
        # A `Pipeline` is a `Redis`, so patching `publish` would catch the batched
        # commands too. Only a command issued on the client itself reaches here.
        if args and args[0] == "PUBLISH":
            publishes.append(1)
        return await real_command(self, *args, **kwargs)

    with (
        mock.patch.object(Pipeline, "execute", counted_execute),
        mock.patch.object(Redis, "execute_command", counted_command),
    ):
        resp = http.post(SEND_URL, json=body, headers=headers)

    assert resp.json()["accepted"] == len(targets)
    assert len(executes) == 1
    assert publishes == []


def test_the_push_re_encodes_nothing_the_client_already_sent(
    http, active_user, device, bearer, bob_devices
):
    """The route decodes the client's base64 to store the bytes, so encoding those
    bytes back for the push produces the identical string at the cost of a second
    pass over every blob. At the largest bucket and the largest batch that is
    53 ms of event-loop CPU per request, spent to reproduce what the request body
    already carried.

    The body and the credential are built before the patch, because both are
    base64 of their own and neither is part of what the request costs.
    """
    body = {
        "messages": [{"device_id": str(bob_devices[0].id), "blob": envelope_blob(b"r")}]
    }
    headers = bearer(active_user, device)
    encodings = []
    real_encode = base64.b64encode

    def counted(raw, *args, **kwargs):
        encodings.append(len(raw))
        return real_encode(raw, *args, **kwargs)

    with mock.patch.object(base64, "b64encode", counted):
        resp = http.post(SEND_URL, json=body, headers=headers)

    assert resp.status_code == 202
    assert encodings == []


def test_the_pushed_frame_is_the_documented_four_fields_and_nothing_more(
    http, active_user, device, bearer, bob_devices, listener
):
    """What the gateway forwards is what the socket receives, so the frame is
    asserted whole. A field more would be one no client contract names; a field
    less would leave the client with an envelope it cannot ack, because `id` is
    the only handle the ack route takes."""
    target = bob_devices[0]
    blob = envelope_blob(b"f")

    with listener(target.id) as subscriber:
        resp = http.post(
            SEND_URL,
            json={"messages": [{"device_id": str(target.id), "blob": blob}]},
            headers=bearer(active_user, device),
        )

        assert resp.status_code == 202
        frame = subscriber.receive()

    row = QueuedEnvelope.objects.get(recipient_device_id=target.id)
    assert frame == {"type": "envelope", "id": str(row.id), "seq": 1, "blob": blob}


def test_a_stale_target_is_pushed_nothing_because_nothing_was_queued(
    http, active_user, device, bearer, bob_devices, listener
):
    """A revoked device may still hold a live socket for the moment it takes the
    gateway to notice, and a frame for a row that was never written would be an
    envelope id the client could ack for ever."""
    target = bob_devices[0]
    target.revoked_date = timezone.now().date()
    target.save(update_fields=["revoked_date"])

    with listener(target.id) as subscriber:
        resp = http.post(
            SEND_URL,
            json={"messages": [{"device_id": str(target.id), "blob": envelope_blob()}]},
            headers=bearer(active_user, device),
        )

        assert resp.json()["stale_devices"] == [str(target.id)]
        assert subscriber.received_nothing()

    assert QueuedEnvelope.objects.count() == 0


def test_a_full_mailbox_is_pushed_nothing_while_its_neighbour_still_is(
    http, active_user, device, bearer, bob_devices, listener, settings
):
    """The refusal is per device and so is the push: the device that was refused
    hears nothing, and the one that was accepted in the same batch still does."""
    from .conftest import SMALLEST_BUCKET

    settings.MAILBOX_MAX_BYTES = SMALLEST_BUCKET
    full, free = bob_devices
    QueuedEnvelope.objects.create(
        recipient_device=full, seq=1, blob=b"q" * SMALLEST_BUCKET
    )
    blob = envelope_blob(b"G")

    with listener(full.id) as refused, listener(free.id) as accepted:
        resp = http.post(
            SEND_URL,
            json={
                "messages": [
                    {"device_id": str(full.id), "blob": envelope_blob(b"F")},
                    {"device_id": str(free.id), "blob": blob},
                ]
            },
            headers=bearer(active_user, device),
        )

        assert resp.json()["full_devices"] == [str(full.id)]
        assert accepted.receive()["blob"] == blob
        assert refused.received_nothing()
