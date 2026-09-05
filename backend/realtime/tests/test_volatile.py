"""Signals relay between live sockets and leave zero trace: no new row in any table,
and no signal or presence table to write to.

The other half of the subject is the shape of the one thing this path carries. A
`signal` blob is standard base64 of exactly one `SIGNAL_BUCKETS` length, and a blob
outside that set is dropped in silence like every other malformed but well-typed
frame: no close, no error frame. It is a malformed-input guard and never a security
control — a modified server would relay anything at all — so what these tests hold
is the guard's boundary, not a promise about an attacker.
"""

import base64
import uuid

import pytest

from api.redis import get_client
from core.buckets import SIGNAL_BUCKETS
from realtime import gateway

from .conftest import (
    PROBE_BLOB,
    bearer,
    connect_ok,
    mint_session,
    probe,
    signal_blob,
    table_counts,
)

pytestmark = pytest.mark.django_db(transaction=True)

# A bucket that is deliberately not in the set: `core/buckets.py` records why the
# 2048 step was left out, and a blob of that length is the case a client reaches by
# padding to a bucket the server does not have.
LENGTH_IN_NO_BUCKET = 2048


async def test_signal_relays_and_writes_zero_rows_anywhere(
    active_user, device, peer, peer_device
):
    blob = signal_blob(b"c")
    comm_a = await connect_ok(bearer(await mint_session(active_user, device)))
    comm_b = await connect_ok(bearer(await mint_session(peer, peer_device)))
    before = await table_counts()

    await comm_a.send_json_to(
        {"type": "signal", "to_device": str(peer_device.id), "blob": blob}
    )

    frame = await comm_b.receive_json_from(timeout=2)
    # The relayed frame carries type and blob only: no to_device, and structurally no
    # sender.
    assert frame == {"type": "signal", "blob": blob}

    after = await table_counts()
    assert after == before, "a volatile signal changed a table's row count"
    await comm_a.disconnect()
    await comm_b.disconnect()


async def test_every_signal_bucket_relays(active_user, device, peer, peer_device):
    """A bucket is what a blob may be, not what it must be under. A client whose
    padded announcement lands exactly on a bucket has no smaller frame to send, so
    an off-by-one here silently breaks a whole protocol step — and the largest
    bucket carries the offer with its candidate set, which is the frame a call
    cannot be placed without."""
    comm_a = await connect_ok(bearer(await mint_session(active_user, device)))
    comm_b = await connect_ok(bearer(await mint_session(peer, peer_device)))

    for bucket in SIGNAL_BUCKETS:
        blob = signal_blob(b"b", bucket=bucket)
        await comm_a.send_json_to(
            {"type": "signal", "to_device": str(peer_device.id), "blob": blob}
        )
        assert await comm_b.receive_json_from(timeout=2) == {
            "type": "signal",
            "blob": blob,
        }, f"the {bucket}-byte bucket did not relay"

    await comm_a.disconnect()
    await comm_b.disconnect()


async def test_a_blob_one_byte_off_a_bucket_is_dropped_on_either_side(
    active_user, device, peer, peer_device
):
    """The boundary the rule turns on, from both sides of all three buckets. One
    byte under and one byte over are the two mistakes a padding implementation
    actually makes, and either one must be dropped rather than relayed — otherwise
    the bucket set is decoration and the lengths on the wire are whatever the client
    happened to produce."""
    comm_a = await connect_ok(bearer(await mint_session(active_user, device)))
    comm_b = await connect_ok(bearer(await mint_session(peer, peer_device)))

    for bucket in SIGNAL_BUCKETS:
        for size in (bucket - 1, bucket + 1):
            await comm_a.send_json_to(
                {
                    "type": "signal",
                    "to_device": str(peer_device.id),
                    "blob": base64.b64encode(b"o" * size).decode(),
                }
            )

    await probe(comm_a, device.id)  # every drop left the sender's socket healthy
    assert await comm_b.receive_nothing(timeout=0.3), "an off-bucket blob was relayed"
    await comm_a.disconnect()
    await comm_b.disconnect()


async def test_a_blob_longer_than_the_blob_cap_is_dropped_without_being_decoded(
    active_user, device, peer, peer_device, monkeypatch
):
    """`SIGNAL_BLOB_MAX` is the base64 length of the largest bucket, so a longer
    string cannot decode to a bucket and is refused on its length alone. Decoding it
    first would be event-loop time spent on a frame the contract already refuses —
    a frame may be as long as `WS_MAX_FRAME`, which is far longer than any bucket.
    """
    decoded = []
    real_decode = gateway.decode_blob_or_400

    def recording_decode(blob, bucket_set):
        decoded.append(blob)
        return real_decode(blob, bucket_set)

    monkeypatch.setattr(gateway, "decode_blob_or_400", recording_decode)
    too_long = base64.b64encode(b"o" * 65536).decode()
    assert len(too_long) > gateway.SIGNAL_BLOB_MAX
    comm_a = await connect_ok(bearer(await mint_session(active_user, device)))
    comm_b = await connect_ok(bearer(await mint_session(peer, peer_device)))

    await comm_a.send_json_to(
        {"type": "signal", "to_device": str(peer_device.id), "blob": too_long}
    )

    await probe(comm_a, device.id)
    assert await comm_b.receive_nothing(timeout=0.3), "an oversized blob was relayed"
    # The probe went through the decoder, so the recorder was live; the oversized
    # blob never reached it.
    assert PROBE_BLOB in decoded, "the decoder was never called at all"
    assert too_long not in decoded, "an oversized blob was decoded before it was dropped"
    await comm_a.disconnect()
    await comm_b.disconnect()


async def test_a_blob_that_is_not_base64_at_all_is_dropped(
    active_user, device, peer, peer_device
):
    """The alphabet, the padding and the embedded control character: three ways a
    string of the right length is not base64 at all. The decoder validates rather
    than skipping what it does not recognise, so none of them may relay."""
    comm_a = await connect_ok(bearer(await mint_session(active_user, device)))
    comm_b = await connect_ok(bearer(await mint_session(peer, peer_device)))
    bucketed = signal_blob(b"v")

    for blob in (
        "!" * len(bucketed),  # outside the alphabet
        bucketed[:-1],  # a length that is not a multiple of four
        bucketed[:100] + "\n" + bucketed[101:],  # an embedded newline
    ):
        await comm_a.send_json_to(
            {"type": "signal", "to_device": str(peer_device.id), "blob": blob}
        )

    await probe(comm_a, device.id)
    assert await comm_b.receive_nothing(timeout=0.3), "a non-base64 blob was relayed"
    await comm_a.disconnect()
    await comm_b.disconnect()


async def test_a_blob_of_a_length_in_no_bucket_is_dropped(
    active_user, device, peer, peer_device
):
    """Valid base64, a plausible power of two, and not a bucket. The rule is
    membership of the set and not an upper bound, so a length between two buckets
    is refused exactly like a length past the largest."""
    comm_a = await connect_ok(bearer(await mint_session(active_user, device)))
    comm_b = await connect_ok(bearer(await mint_session(peer, peer_device)))
    assert LENGTH_IN_NO_BUCKET not in SIGNAL_BUCKETS

    await comm_a.send_json_to(
        {
            "type": "signal",
            "to_device": str(peer_device.id),
            "blob": base64.b64encode(b"m" * LENGTH_IN_NO_BUCKET).decode(),
        }
    )

    await probe(comm_a, device.id)
    assert await comm_b.receive_nothing(timeout=0.3), "an unbucketed length relayed"
    await comm_a.disconnect()
    await comm_b.disconnect()


async def test_there_is_no_signal_or_presence_table_at_all(db):
    """The server has no schema for volatile traffic, so there is nothing to persist
    into."""
    labels = list(await table_counts())
    assert not [
        label
        for label in labels
        if "signal" in label.lower()
        or "presence" in label.lower()
        or "typing" in label.lower()
        or "receipt" in label.lower()
    ]


async def test_signal_to_an_offline_target_is_dropped_silently(active_user, device):
    """No error frame, nothing stored, and the sender's socket stays healthy."""
    comm = await connect_ok(bearer(await mint_session(active_user, device)))
    before = await table_counts()

    await comm.send_json_to(
        {"type": "signal", "to_device": str(uuid.uuid4()), "blob": signal_blob(b"o")}
    )

    await probe(comm, device.id)  # the drop didn't kill the consumer
    assert await comm.receive_nothing(timeout=0.2)
    assert await table_counts() == before
    await comm.disconnect()


async def test_malformed_signal_frames_are_dropped(active_user, device):
    comm = await connect_ok(bearer(await mint_session(active_user, device)))
    blob = signal_blob(b"m")

    await comm.send_json_to({"type": "signal", "to_device": "not-a-uuid", "blob": blob})
    await comm.send_json_to({"type": "signal", "to_device": str(uuid.uuid4())})
    await comm.send_json_to({"type": "signal", "blob": blob})
    await comm.send_json_to({"type": "signal", "to_device": {"a": 1}, "blob": blob})

    await probe(comm, device.id)
    await comm.disconnect()


async def test_alternate_uuid_spellings_still_reach_a_live_target(
    active_user, device, peer, peer_device
):
    """uuid.UUID accepts braces/urn/uppercase; the topic name must use the
    normalized form or a live target silently misses the signal."""
    comm_a = await connect_ok(bearer(await mint_session(active_user, device)))
    comm_b = await connect_ok(bearer(await mint_session(peer, peer_device)))
    blob = signal_blob(b"u")

    for spelling in (
        "{%s}" % peer_device.id,
        str(peer_device.id).upper(),
        f"urn:uuid:{peer_device.id}",
    ):
        await comm_a.send_json_to({"type": "signal", "to_device": spelling, "blob": blob})
        assert await comm_b.receive_json_from(timeout=2) == {
            "type": "signal",
            "blob": blob,
        }
    await comm_a.disconnect()
    await comm_b.disconnect()


async def test_a_signal_whose_blob_is_not_a_string_is_dropped(
    active_user, device, peer, peer_device
):
    """The blob is relayed verbatim and never inspected, so the one thing the
    gateway does check is that it is a string. A JSON object or number reaching the
    publish would be re-encoded into a frame whose `blob` no client can decrypt."""
    comm_a = await connect_ok(bearer(await mint_session(active_user, device)))
    comm_b = await connect_ok(bearer(await mint_session(peer, peer_device)))

    for blob in (42, {"nested": "ciphertext"}, ["ciphertext"], None, True):
        await comm_a.send_json_to(
            {"type": "signal", "to_device": str(peer_device.id), "blob": blob}
        )

    await probe(comm_a, device.id)  # the drops did not kill the sender
    assert await comm_b.receive_nothing(timeout=0.2)
    await comm_a.disconnect()
    await comm_b.disconnect()


async def test_a_relayed_signal_leaves_no_key_in_redis(
    active_user, device, peer, peer_device
):
    """Publish and subscribe holds a message only for the instant it takes to hand
    it to whoever is connected. A relay that left a key behind would be a message
    store — on an instance that runs with `save ""`, but a store all the same, and
    one a client that reconnects could be served from."""
    comm_a = await connect_ok(bearer(await mint_session(active_user, device)))
    comm_b = await connect_ok(bearer(await mint_session(peer, peer_device)))

    await comm_a.send_json_to(
        {"type": "signal", "to_device": str(peer_device.id), "blob": signal_blob(b"r")}
    )
    await comm_b.receive_json_from(timeout=2)

    assert await get_client().keys("*") == []
    await comm_a.disconnect()
    await comm_b.disconnect()
