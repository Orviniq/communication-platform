import base64
import threading

import pytest
from django.db import connections

from devices.models import OneTimePrekey
from devices.schemas import MAX_STORED_OTPKS

from .conftest import (
    DEVICES_URL,
    connect_then_wait,
    make_device,
    pubkey,
    stock_prekeys,
)

pytestmark = pytest.mark.django_db(transaction=True)


def prekeys_url(device_id):
    return f"{DEVICES_URL}/{device_id}/prekeys"


def otpks(count, start=0):
    return [
        {"key_id": start + i, "pub": pubkey(bytes([65 + (i % 26)]))} for i in range(count)
    ]


def test_a_device_replenishes_its_own_prekeys(http, active_user, device, bearer):
    response = http.put(
        prekeys_url(device.id),
        json={"otpks": otpks(5)},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 200
    assert response.json()["otpk_count"] == 5
    assert OneTimePrekey.objects.filter(device=device).count() == 5


def test_re_uploading_a_key_id_is_an_idempotent_retry(http, active_user, device, bearer):
    headers = bearer(active_user, device)
    http.put(prekeys_url(device.id), json={"otpks": otpks(3)}, headers=headers)

    again = http.put(prekeys_url(device.id), json={"otpks": otpks(3)}, headers=headers)

    assert again.status_code == 200
    assert again.json()["otpk_count"] == 3


def test_a_duplicate_key_id_within_one_payload_is_a_400(
    http, active_user, device, bearer
):
    body = {
        "otpks": [{"key_id": 4, "pub": pubkey(b"a")}, {"key_id": 4, "pub": pubkey(b"b")}]
    }

    response = http.put(
        prekeys_url(device.id), json=body, headers=bearer(active_user, device)
    )

    assert response.status_code == 400


def test_the_signed_prekey_is_replaced_and_dated(http, active_user, device, bearer):
    """The server stores spk_pub/spk_sig and never verifies the signature; that is
    the client's job against ik_pub."""
    body = {"spk": {"spk_id": 77, "pub": pubkey(b"n"), "sig": pubkey(b"z")}}

    response = http.put(
        prekeys_url(device.id), json=body, headers=bearer(active_user, device)
    )

    assert response.status_code == 200
    device.refresh_from_db()
    assert device.spk_id == 77
    assert bytes(device.spk_pub) == base64.b64decode(pubkey(b"n"))
    assert bytes(device.spk_sig) == base64.b64decode(pubkey(b"z"))
    assert device.spk_updated_date is None  # retired by ADR-0024


def test_a_signed_prekey_missing_its_signature_is_rejected(
    http, active_user, device, bearer
):
    body = {"spk": {"spk_id": 1, "pub": pubkey()}}

    response = http.put(
        prekeys_url(device.id), json=body, headers=bearer(active_user, device)
    )

    assert response.status_code == 400


def test_replenishment_past_the_stored_cap_is_refused(http, active_user, device, bearer):
    """Without a stored cap, replenishment is an unbounded write primitive for any
    authenticated device."""
    stock_prekeys(device, MAX_STORED_OTPKS, start=1000)

    response = http.put(
        prekeys_url(device.id),
        json={"otpks": otpks(1)},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 409
    assert response.json()["code"] == "prekey_limit"
    assert OneTimePrekey.objects.filter(device=device).count() == MAX_STORED_OTPKS


def test_a_refused_replenishment_rotates_nothing(http, active_user, device, bearer):
    """The cap is checked before either write, so a device told "409, nothing
    stored" never finds its signed prekey rotated anyway."""
    stock_prekeys(device, MAX_STORED_OTPKS, start=1000)
    original_spk_id = device.spk_id
    body = {
        "spk": {"spk_id": 4242, "pub": pubkey(b"n"), "sig": pubkey(b"z")},
        "otpks": otpks(1),
    }

    response = http.put(
        prekeys_url(device.id), json=body, headers=bearer(active_user, device)
    )

    assert response.status_code == 409
    device.refresh_from_db()
    assert device.spk_id == original_spk_id


def test_the_count_endpoint_reports_the_pool(http, active_user, device, bearer):
    stock_prekeys(device, 12)

    response = http.get(
        f"{prekeys_url(device.id)}/count", headers=bearer(active_user, device)
    )

    assert response.json()["otpk_count"] == 12


@pytest.mark.parametrize(
    "method, suffix, body",
    [
        ("put", "", {"otpks": []}),
        ("get", "/count", None),
    ],
)
def test_a_device_cannot_touch_another_devices_prekeys(
    http, active_user, device, bearer, method, suffix, body
):
    """Token device_id must equal the path device, including a sibling device on the
    caller's own account."""
    sibling = make_device(active_user, registration_id=42)
    headers = bearer(active_user, device)
    url = f"{prekeys_url(sibling.id)}{suffix}"

    response = (
        getattr(http, method)(url, json=body, headers=headers)
        if body is not None
        else getattr(http, method)(url, headers=headers)
    )

    assert response.status_code == 403
    assert response.json()["code"] == "forbidden"


def test_a_device_cannot_touch_a_peers_prekeys(
    http, active_user, device, bearer, peer, peer_device
):
    response = http.put(
        prekeys_url(peer_device.id),
        json={"otpks": otpks(1)},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 403
    assert OneTimePrekey.objects.filter(device=peer_device).count() == 0


def test_unknown_fields_are_rejected(http, active_user, device, bearer):
    response = http.put(
        prekeys_url(device.id),
        json={"otpks": [], "private": "no"},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400


def test_an_empty_body_is_a_no_op(http, active_user, device, bearer):
    response = http.put(
        prekeys_url(device.id), json={}, headers=bearer(active_user, device)
    )

    assert response.status_code == 200
    assert response.json()["otpk_count"] == 0


def test_a_batch_that_lands_exactly_on_the_cap_is_accepted(
    http, active_user, device, bearer
):
    """The boundary either side of MAX_STORED_OTPKS: `stored + batch > cap` refuses,
    so a batch that lands exactly on the cap is the largest one that goes in."""
    stock_prekeys(device, MAX_STORED_OTPKS - 5, start=1000)
    headers = bearer(active_user, device)

    exact = http.put(prekeys_url(device.id), json={"otpks": otpks(5)}, headers=headers)
    one_more = http.put(
        prekeys_url(device.id), json={"otpks": otpks(1, start=50)}, headers=headers
    )

    assert exact.status_code == 200
    assert exact.json()["otpk_count"] == MAX_STORED_OTPKS
    assert one_more.status_code == 409
    assert OneTimePrekey.objects.filter(device=device).count() == MAX_STORED_OTPKS


def test_a_retry_of_a_batch_that_already_landed_can_be_refused_by_the_cap(
    http, active_user, device, bearer
):
    """The non-idempotency `devices/API.md` names: the cap is checked against the
    batch as sent, not against the keys it would actually add, so a client that
    retries a batch it already stored can be told 409 while nothing changes. The
    contract's own answer is that the client reads the count endpoint first."""
    stock_prekeys(device, MAX_STORED_OTPKS - 3, start=1000)
    headers = bearer(active_user, device)
    batch = {"otpks": otpks(3)}

    first = http.put(prekeys_url(device.id), json=batch, headers=headers)
    retry = http.put(prekeys_url(device.id), json=batch, headers=headers)

    assert first.status_code == 200
    assert retry.status_code == 409
    assert retry.json()["code"] == "prekey_limit"
    assert OneTimePrekey.objects.filter(device=device).count() == MAX_STORED_OTPKS
    counted = http.get(f"{prekeys_url(device.id)}/count", headers=headers)
    assert counted.json()["otpk_count"] == MAX_STORED_OTPKS


def test_a_re_upload_of_the_same_signed_bundle_stores_the_same_bytes(
    http, active_user, device, bearer
):
    """The other documented non-idempotency, in the case that makes it harmless:
    the signed prekey is replaced by whatever the retry carries, so re-sending the
    same bundle overwrites it with itself."""
    headers = bearer(active_user, device)
    body = {"spk": {"spk_id": 21, "pub": pubkey(b"n"), "sig": pubkey(b"z")}}
    http.put(prekeys_url(device.id), json=body, headers=headers)
    device.refresh_from_db()
    stored = (device.spk_id, bytes(device.spk_pub), bytes(device.spk_sig))

    again = http.put(prekeys_url(device.id), json=body, headers=headers)

    assert again.status_code == 200
    device.refresh_from_db()
    assert (device.spk_id, bytes(device.spk_pub), bytes(device.spk_sig)) == stored


def replenish_storm(new_http, headers, device_id, bodies):
    """Fire one replenishment per body at once, and collect what each was told."""
    start = threading.Barrier(len(bodies))
    answers, failures = [], []
    lock = threading.Lock()

    def replenish(body):
        try:
            connect_then_wait(start)
            response = new_http().put(prekeys_url(device_id), json=body, headers=headers)
            with lock:
                answers.append((response.status_code, response.json()))
        except Exception as exc:  # noqa: BLE001 - surfaced through `failures`
            with lock:
                failures.append(repr(exc))
        finally:
            connections.close_all()

    threads = [threading.Thread(target=replenish, args=(body,)) for body in bodies]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert failures == []
    return answers


def test_concurrent_replenishments_lose_no_prekey_and_double_count_none(
    new_http, active_user, device, bearer
):
    """Six devices' worth of traffic from one device at once, each batch disjoint.
    The device-row lock serialises them, so every key lands exactly once and the
    counts the callers are handed are the running total — no batch is counted twice
    and none is silently dropped."""
    batches = 6
    per_batch = 3
    bodies = [{"otpks": otpks(per_batch, start=100 * i)} for i in range(batches)]

    answers = replenish_storm(new_http, bearer(active_user, device), device.id, bodies)

    assert {status for status, _body in answers} == {200}
    assert sorted(body["otpk_count"] for _status, body in answers) == [
        per_batch * (i + 1) for i in range(batches)
    ]
    stored = OneTimePrekey.objects.filter(device=device)
    assert stored.count() == batches * per_batch
    assert set(stored.values_list("key_id", flat=True)) == {
        100 * i + n for i in range(batches) for n in range(per_batch)
    }


def test_concurrent_replenishments_of_one_batch_store_it_exactly_once(
    new_http, active_user, device, bearer
):
    """The retry storm a flapping connection produces. `ignore_conflicts` is what
    makes the repeat an idempotent retry rather than an IntegrityError, and the
    count every caller is handed is the truth."""
    body = {"otpks": otpks(4, start=70)}

    answers = replenish_storm(
        new_http, bearer(active_user, device), device.id, [body] * 6
    )

    assert {status for status, _body in answers} == {200}
    assert {body["otpk_count"] for _status, body in answers} == {4}
    assert OneTimePrekey.objects.filter(device=device).count() == 4


def test_concurrent_replenishments_cannot_pass_the_stored_cap(
    new_http, active_user, device, bearer
):
    """One free slot, four racers. Without the device-row lock each would read the
    same stored count and all four would insert."""
    stock_prekeys(device, MAX_STORED_OTPKS - 1, start=1000)
    bodies = [{"otpks": otpks(1, start=i)} for i in range(4)]

    answers = replenish_storm(new_http, bearer(active_user, device), device.id, bodies)

    statuses = [status for status, _body in answers]
    assert statuses.count(200) == 1
    assert statuses.count(409) == 3
    assert OneTimePrekey.objects.filter(device=device).count() == MAX_STORED_OTPKS
