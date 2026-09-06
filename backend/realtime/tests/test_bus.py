"""The bus underneath the sockets: every failure is swallowed, and the reader
survives every message shape a live connection can hand it.

`test_bus_batching.py` measures what a fan-out costs and `test_recovery.py` drives
a real connection drop. What is left, and what this file covers, is the set of
branches no end-to-end socket reaches: a Redis that is not listening, a URL that
cannot be parsed, a client that refuses to close, a pubsub whose own commands
raise, and the four message shapes the reader must drop without stopping.

Every swallow is asserted through delivery rather than through the absence of a
traceback: the failing call, then the same call against a working bus, and a sink
that saw only the second. A swallow that also swallowed the working case would
pass a test that only checked for silence.
"""

import asyncio
import json
import logging
import uuid

import pytest
import redis

from ops.audit.log_silence import capture_all_logging
from realtime import bus

pytestmark = pytest.mark.django_db(transaction=True)

# Nothing listens here. The kernel refuses the connect immediately on loopback, so
# an unreachable bus costs the test no wall clock.
DEAD_REDIS_URL = "redis://127.0.0.1:6390"
DELIVERY_TIMEOUT = 5


async def wait_for(predicate, timeout=DELIVERY_TIMEOUT):
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.01)


def topic_of(name):
    """A topic no other test in this run publishes to."""
    return bus.device_topic(f"{name}-{uuid.uuid4()}")


class _ScriptedPubSub:
    """Stands in for redis-py's `PubSub`, so the reader loop can be fed the message
    shapes a live connection produces only rarely: a read that yields nothing, a
    confirmation for a topic nobody is waiting on, a payload that is not JSON.

    A real pubsub blocks in `get_message` until the next push arrives, so this one
    blocks forever once the script is spent rather than returning and letting the
    loop spin.
    """

    def __init__(self, messages):
        self._messages = list(messages)

    async def get_message(self, timeout=None):
        if self._messages:
            return self._messages.pop(0)
        await asyncio.Event().wait()

    async def aclose(self):
        pass


def pushed(topic, payload):
    return {"type": "message", "channel": topic.encode(), "data": json.dumps(payload)}


async def scripted_reader(messages, topic, sink):
    """A subscriber whose reader is fed `messages` and whose only sink holds
    `topic`. Returned unstarted-and-running: the caller awaits its effect and
    closes it."""
    subscriber = bus.Subscriber()
    subscriber._sinks[topic] = {sink}
    subscriber._pubsub = _ScriptedPubSub(messages)
    subscriber._reader = asyncio.create_task(subscriber._read())
    return subscriber


# ---- publish ----------------------------------------------------------------


async def test_a_publish_to_an_unreachable_bus_is_dropped_and_the_next_one_lands(
    monkeypatch,
):
    """Best-effort is the contract: the durable mailbox is the source of truth, so
    a publish that cannot reach Redis must neither raise into the request that
    caused it nor leave the bus broken for the request after it."""
    received = []
    topic = topic_of("unreachable-publish")
    await bus.get_subscriber().subscribe(topic, received.append)
    dead = redis.asyncio.Redis.from_url(DEAD_REDIS_URL)
    live = bus.get_client()

    monkeypatch.setattr(bus, "get_client", lambda: dead)
    assert await bus.publish(topic, {"type": "lost"}) is None
    monkeypatch.setattr(bus, "get_client", lambda: live)
    await bus.publish(topic, {"type": "delivered"})

    await wait_for(lambda: received)
    assert received == [{"type": "delivered"}]
    await dead.aclose()


async def test_a_publish_of_something_json_cannot_encode_is_dropped(monkeypatch):
    """The serialization is inside the same best-effort bracket as the round trip.
    A payload the encoder refuses is a defect in a caller, and it must not take
    down the socket whose frame handler is awaiting the publish."""
    received = []
    topic = topic_of("unencodable-publish")
    await bus.get_subscriber().subscribe(topic, received.append)

    assert await bus.publish(topic, {"blob": object()}) is None
    await bus.publish(topic, {"type": "delivered"})

    await wait_for(lambda: received)
    assert received == [{"type": "delivered"}]


# ---- close_device_sockets ---------------------------------------------------


async def test_close_device_sockets_against_an_unreachable_bus_is_swallowed(
    settings,
):
    """The revoke cascade runs inside a unit of work that has already committed the
    revocation. A bus that is down must cost the caller nothing: the tokens are
    dead either way, and the socket dies with its next frame."""
    received = []
    device_id = uuid.uuid4()
    topic = bus.device_topic(device_id)
    await bus.get_subscriber().subscribe(topic, received.append)
    live_url = settings.REDIS_URL

    settings.REDIS_URL = DEAD_REDIS_URL
    assert bus.close_device_sockets(device_id) is None
    settings.REDIS_URL = live_url
    bus.close_device_sockets(device_id)

    await wait_for(lambda: received)
    assert received == [{"type": bus.CLOSE}]


async def test_close_device_sockets_with_an_unparseable_url_builds_no_client(
    settings,
):
    """`from_url` raises before the assignment, so the `finally` finds no client to
    close. A second exception out of the cleanup would escape the bracket that the
    first one was caught by."""
    received = []
    device_id = uuid.uuid4()
    topic = bus.device_topic(device_id)
    await bus.get_subscriber().subscribe(topic, received.append)
    live_url = settings.REDIS_URL

    settings.REDIS_URL = "not-a-url"
    assert bus.close_device_sockets(device_id) is None
    settings.REDIS_URL = live_url
    bus.close_device_sockets(device_id)

    await wait_for(lambda: received)
    assert received == [{"type": bus.CLOSE}]


async def test_close_device_sockets_still_delivers_when_the_client_cannot_close(
    monkeypatch,
):
    """The close is bookkeeping on a connection this call opened for itself. A
    failure there must not undo the publish that already reached Redis, and must
    not reach the admin action or the route that asked for the revocation."""
    received = []
    device_id = uuid.uuid4()
    await bus.get_subscriber().subscribe(bus.device_topic(device_id), received.append)

    def refuse_to_close(self):
        raise OSError("the connection went away before it could be closed")

    monkeypatch.setattr(redis.Redis, "close", refuse_to_close)
    assert bus.close_device_sockets(device_id) is None

    await wait_for(lambda: received)
    assert received == [{"type": bus.CLOSE}]


# ---- subscribe and unsubscribe ----------------------------------------------


async def test_a_second_sink_on_a_held_topic_is_joined_and_fed():
    """Two sockets of one device share one Redis subscription. The second sink must
    wait out the same confirmation the first did — returning before it would let a
    publish land on a topic the server does not yet hold — and must then be fed
    every payload the first is."""
    first, second = [], []
    topic = topic_of("two-sinks")
    subscriber = bus.get_subscriber()

    await subscriber.subscribe(topic, first.append)
    await subscriber.subscribe(topic, second.append)
    await bus.publish(topic, {"type": "shared"})

    await wait_for(lambda: first and second)
    assert first == second == [{"type": "shared"}]


async def test_unsubscribing_a_topic_that_was_never_held_disturbs_nothing():
    """A cleanup runs on every exit path, including one where the bind never
    completed, so it reaches here with a topic this worker holds no sink for."""
    received = []
    held = topic_of("still-held")
    subscriber = bus.get_subscriber()
    await subscriber.subscribe(held, received.append)

    assert await subscriber.unsubscribe(topic_of("never-held"), received.append) is None

    await bus.publish(held, {"type": "delivered"})
    await wait_for(lambda: received)
    assert received == [{"type": "delivered"}]


async def test_a_failing_unsubscribe_command_still_drops_the_sink(monkeypatch):
    """The sink map is what dispatch reads, so it is what has to be right. If the
    UNSUBSCRIBE never reaches Redis the worker keeps a subscription it does not
    need, which costs a round trip; a sink left registered for a socket that is
    gone would instead deliver its device's frames to a dead connection."""
    received = []
    topic = topic_of("failing-unsubscribe")
    subscriber = bus.get_subscriber()
    await subscriber.subscribe(topic, received.append)

    async def refuse(*_args, **_kwargs):
        raise redis.ConnectionError("the connection dropped mid-command")

    monkeypatch.setattr(subscriber._pubsub, "unsubscribe", refuse)
    assert await subscriber.unsubscribe(topic, received.append) is None

    # Redis still holds the subscription — the command that would have released it
    # never left the process — so the frame does reach the reader, and dispatch is
    # what has to drop it. The second topic is the barrier: one connection delivers
    # in publish order, so a sink that has seen the barrier has already seen
    # whatever the reader did with the frame before it.
    barrier, barrier_topic = [], topic_of("unsubscribe-barrier")
    await subscriber.subscribe(barrier_topic, barrier.append)
    await bus.publish(topic, {"type": "after-the-unsubscribe"})
    await bus.publish(barrier_topic, {"type": "barrier"})

    await wait_for(lambda: barrier)
    assert received == []


# ---- aclose -----------------------------------------------------------------


async def test_aclose_swallows_a_reader_that_raised_and_leaves_a_usable_subscriber():
    """A reader that died of a defect is exactly the case `aclose` runs in on a
    lifespan shutdown, and re-raising it there would turn one broken worker into a
    shutdown that never finishes."""
    subscriber = bus.Subscriber()

    async def defective():
        raise RuntimeError("a defect in the reader")

    subscriber._reader = asyncio.create_task(defective())
    await asyncio.sleep(0)  # let it reach the raise before the cancel

    assert await subscriber.aclose() is None

    assert (subscriber._reader, subscriber._sinks, subscriber._joined) == (None, {}, {})
    received = []
    topic = topic_of("after-a-dead-reader")
    await subscriber.subscribe(topic, received.append)
    await bus.publish(topic, {"type": "delivered"})
    await wait_for(lambda: received)
    assert received == [{"type": "delivered"}]
    await subscriber.aclose()


async def test_aclose_swallows_a_pubsub_that_refuses_to_close(monkeypatch):
    """Same shutdown, one layer down: the connection is going away with the process
    regardless, so a `aclose` that raises must not stop the registry being
    cleared."""
    subscriber = bus.Subscriber()
    topic = topic_of("unclosable-pubsub")
    await subscriber.subscribe(topic, [].append)

    async def refuse():
        raise redis.ConnectionError("the connection dropped before the close")

    monkeypatch.setattr(subscriber._pubsub, "aclose", refuse)

    assert await subscriber.aclose() is None

    assert (subscriber._pubsub, subscriber._sinks, subscriber._joined) == (None, {}, {})


# ---- the reader loop --------------------------------------------------------


async def test_a_read_that_yields_nothing_does_not_stop_the_reader():
    """`get_message` answers `None` for a read that produced no message. Treating
    that as a payload raises inside the reader, and a reader that stopped leaves
    every socket of the worker open and silent — the failure that is hardest to
    see from outside."""
    received = []
    topic = topic_of("empty-read")
    subscriber = await scripted_reader(
        [None, pushed(topic, {"type": "delivered"})], topic, received.append
    )

    await wait_for(lambda: received)
    assert received == [{"type": "delivered"}]
    await subscriber.aclose()


async def test_a_message_of_an_unknown_kind_and_an_undecodable_one_are_both_dropped():
    """A `psubscribe` confirmation is not ours, and a payload that is not JSON is
    truncated or belongs to another writer on the same instance. Neither is
    logged, because the line would name a topic and a topic names a device."""
    received = []
    topic = topic_of("junk-messages")
    subscriber = await scripted_reader(
        [
            {"type": "psubscribe", "channel": topic.encode(), "data": 1},
            {"type": "message", "channel": topic.encode(), "data": b"{not json"},
            pushed(topic, {"type": "delivered"}),
        ],
        topic,
        received.append,
    )

    await wait_for(lambda: received)
    assert received == [{"type": "delivered"}]
    await subscriber.aclose()


async def test_a_subscribe_confirmation_nobody_waits_on_is_dropped():
    """The confirmation for a topic already released — a socket that unsubscribed
    while its SUBSCRIBE was still in flight — arrives with no event to set."""
    received = []
    topic = topic_of("unawaited-confirmation")
    subscriber = await scripted_reader(
        [
            {"type": "subscribe", "channel": b"ws:dev:nobody-is-waiting", "data": 1},
            pushed(topic, {"type": "delivered"}),
        ],
        topic,
        received.append,
    )

    await wait_for(lambda: received)
    assert received == [{"type": "delivered"}]
    await subscriber.aclose()


# ---- the push handler and the registry --------------------------------------


async def test_the_push_handler_returns_the_response_and_writes_no_log_line():
    """redis-py's own default logs each push at DEBUG — a topic and a ciphertext
    blob in a log line — and installs a stdout handler outside Django's LOGGING
    the first time a PubSub is built without one. Passing this suppresses both."""
    push = [b"message", b"ws:dev:2a77d4b9-e611-4c0f-9f1c-6a2e3b7d4e0f", b"kzXhc-blob"]

    with capture_all_logging() as lines:
        logging.getLogger("test.canary").debug("canary")
        returned = await bus._keep(push)

    assert returned is push
    assert any("canary" in line for line in lines), "log capture was not live"
    assert not [line for line in lines if "ws:dev:" in line or "kzXhc" in line]


async def test_the_worker_holds_one_subscriber_for_its_loop():
    """One subscription connection for the process, which is what makes per-topic
    subscribe and unsubscribe affordable: a second subscriber would double the
    round trips of every bind."""
    assert bus.get_subscriber() is bus.get_subscriber()


async def test_stopping_a_subscriber_the_loop_never_built_is_a_no_op():
    """The lifespan shutdown runs on every worker, including one that served no
    socket at all and therefore never asked for a subscriber."""
    await bus.stop_subscriber()

    assert await bus.stop_subscriber() is None
