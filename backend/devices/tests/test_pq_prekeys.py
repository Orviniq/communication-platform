"""Hybrid post-quantum prekey storage and claim.

Server-side halves only: the server stores and serves ML-KEM-768 material as
opaque bytes. The hybrid guarantee itself — refusing or flagging a session when a
bundle carries no PQ material — is client behaviour and lives in
CLIENT_CONTRACT.md; the adversarial test here proves the server never fakes that
material into existence.
"""

import base64
import threading

import pytest
from django.db import connections

from devices.models import PqOneTimePrekey
from devices.schemas import MAX_STORED_PQ_OTPKS, PQ_PUBKEY_LEN

from .conftest import (
    DEVICES_URL,
    connect_then_wait,
    make_device,
    pq_pubkey,
    pubkey,
    publish_identity,
    register_payload,
    stock_pq_prekeys,
)

pytestmark = pytest.mark.django_db(transaction=True)

CONCURRENT_CLAIMS = 12


def claim_url(user_id):
    return f"/api/v1/users/{user_id}/keys/claim"


def b64sig(seed=b"g"):
    return base64.b64encode((seed * 64)[:64]).decode()


def pq_spk(seed=b"P", spk_id=41):
    return {"spk_id": spk_id, "pub": pq_pubkey(seed), "sig": b64sig(seed)}


def test_pq_material_round_trips_byte_identically(
    http, active_user, device, bearer, peer, peer_device
):
    publish_identity(peer)
    payload = register_payload(
        pq_spk=pq_spk(b"E"), pq_otpks=[{"key_id": 7, "pub": pq_pubkey(b"O")}]
    )
    registered = http.post(
        DEVICES_URL, json=payload, headers=bearer(peer, peer_device)
    ).json()

    bundles = http.post(
        claim_url(peer.id),
        json={"device_ids": [registered["device_id"]]},
        headers=bearer(active_user, device),
    ).json()["bundles"]

    bundle = bundles[0]
    assert bundle["pq_spk_id"] == 41
    assert bundle["pq_spk_pub"] == pq_pubkey(b"E")
    assert bundle["pq_spk_sig"] == b64sig(b"E")
    assert bundle["pq_otpk"] == {"key_id": 7, "pub": pq_pubkey(b"O")}


def test_a_claimed_pq_otpk_is_deleted_and_never_reserved(
    http, active_user, device, bearer, peer, peer_device
):
    peer_device.pq_spk_id = 1
    peer_device.pq_spk_pub = b"E" * PQ_PUBKEY_LEN
    peer_device.pq_spk_sig = b"s" * 64
    peer_device.save()
    stock_pq_prekeys(peer_device, 1, start=30)
    headers = bearer(active_user, device)

    first = http.post(claim_url(peer.id), json={}, headers=headers).json()
    second = http.post(claim_url(peer.id), json={}, headers=headers).json()

    assert first["bundles"][0]["pq_otpk"]["key_id"] == 30
    assert "pq_otpk" not in second["bundles"][0]
    assert second["bundles"][0]["pq_spk_id"] == 1  # signed prekey still served
    assert PqOneTimePrekey.objects.filter(device=peer_device).count() == 0


@pytest.mark.parametrize("nbytes", [PQ_PUBKEY_LEN - 1, PQ_PUBKEY_LEN + 1, 32, 0])
def test_a_wrong_length_pq_key_is_a_400_not_a_500(
    http, active_user, device, bearer, nbytes
):
    bad = base64.b64encode(b"x" * nbytes).decode()
    payload = register_payload(pq_otpks=[{"key_id": 1, "pub": bad}])

    response = http.post(DEVICES_URL, json=payload, headers=bearer(active_user, device))

    assert response.status_code == 400


def test_a_wrong_length_pq_spk_is_a_400_not_a_500(http, active_user, device, bearer):
    payload = register_payload(pq_spk={"spk_id": 1, "pub": pubkey(), "sig": b64sig()})

    response = http.post(DEVICES_URL, json=payload, headers=bearer(active_user, device))

    assert response.status_code == 400


def test_exceeding_the_pq_cap_is_a_409_and_rotates_nothing(
    http, active_user, device, bearer
):
    """The ordering hazard the replenish comment describes: the cap check must run
    before the signed-prekey write, or a device told "409, nothing stored" would
    have had its PQ signed prekey rotated anyway."""
    stock_pq_prekeys(device, MAX_STORED_PQ_OTPKS)
    body = {
        "pq_spk": pq_spk(b"N", spk_id=99),
        "pq_otpks": [{"key_id": 5000, "pub": pq_pubkey(b"z")}],
    }

    response = http.put(
        f"{DEVICES_URL}/{device.id}/prekeys",
        json=body,
        headers=bearer(active_user, device),
    )

    assert response.status_code == 409
    assert response.json()["code"] == "prekey_limit"
    device.refresh_from_db()
    assert device.pq_spk_id is None  # the 409 stored and rotated nothing
    assert PqOneTimePrekey.objects.filter(device=device).count() == MAX_STORED_PQ_OTPKS


def test_replenish_stores_pq_material_and_the_count_endpoint_reports_it(
    http, active_user, device, bearer
):
    headers = bearer(active_user, device)
    body = {
        "pq_spk": pq_spk(b"R", spk_id=8),
        "pq_otpks": [{"key_id": i, "pub": pq_pubkey(bytes([65 + i]))} for i in range(3)],
    }

    assert (
        http.put(
            f"{DEVICES_URL}/{device.id}/prekeys", json=body, headers=headers
        ).status_code
        == 200
    )

    device.refresh_from_db()
    assert device.pq_spk_id == 8
    assert bytes(device.pq_spk_pub) == (b"R" * PQ_PUBKEY_LEN)[:PQ_PUBKEY_LEN]
    counts = http.get(f"{DEVICES_URL}/{device.id}/prekeys/count", headers=headers).json()
    assert counts["pq_otpk_count"] == 3


def test_a_classical_only_bundle_omits_the_pq_fields_entirely(
    http, active_user, device, bearer, peer, peer_device
):
    """Server-side half of "PQ hybrid downgrade blocked": a device with no PQ
    material yields a bundle with the PQ fields absent — not null, not empty, not
    zero-filled — so a classical-only bundle is visibly classical-only. There is no
    code path that substitutes classical material into a PQ field. The other half —
    the client refusing or flagging a classical-only session — is client behaviour
    and belongs to CLIENT_CONTRACT.md, deliberately not simulated here."""
    stock_pq_prekeys(peer_device, 1)  # orphaned PQ OTPKs without a pq_spk

    bundle = http.post(
        claim_url(peer.id), json={}, headers=bearer(active_user, device)
    ).json()["bundles"][0]

    assert "pq_spk_id" not in bundle
    assert "pq_spk_pub" not in bundle
    assert "pq_spk_sig" not in bundle
    assert "pq_otpk" not in bundle
    # And the orphaned one-time key was not burned for a classical-only bundle.
    assert PqOneTimePrekey.objects.filter(device=peer_device).count() == 1


def test_one_pq_prekey_is_handed_to_at_most_one_concurrent_claimant(
    new_http, active_user, device, bearer, peer
):
    """Mirror of test_claim_race.py for the PQ pool: real committed transactions
    racing over `SELECT ... FOR UPDATE SKIP LOCKED` and a delete."""
    owner_device = make_device(
        peer,
        registration_id=2,
        pq_spk_id=1,
        pq_spk_pub=b"E" * PQ_PUBKEY_LEN,
        pq_spk_sig=b"s" * 64,
    )
    stock_pq_prekeys(owner_device, 1, start=77)
    headers = bearer(active_user, device)
    start = threading.Barrier(CONCURRENT_CLAIMS)
    received, failures = [], []
    lock = threading.Lock()

    def claim():
        try:
            connect_then_wait(start)
            response = new_http().post(claim_url(peer.id), json={}, headers=headers)
            if response.status_code != 200:
                with lock:
                    failures.append(response.status_code)
                return
            bundle = response.json()["bundles"][0]
            if "pq_otpk" in bundle:
                with lock:
                    received.append(bundle["pq_otpk"]["key_id"])
        except Exception as exc:  # noqa: BLE001 - surfaced through `failures`
            with lock:
                failures.append(repr(exc))
        finally:
            connections.close_all()

    threads = [threading.Thread(target=claim) for _ in range(CONCURRENT_CLAIMS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert failures == []
    assert received == [77], f"the single PQ OTPK went to {len(received)} claimants"
    assert PqOneTimePrekey.objects.filter(device=owner_device).count() == 0


def prekeys_url(device_id):
    return f"{DEVICES_URL}/{device_id}/prekeys"


def pq_otpks(count, start=0):
    return [
        {"key_id": start + i, "pub": pq_pubkey(bytes([65 + (i % 26)]))}
        for i in range(count)
    ]


def test_a_pq_batch_that_lands_exactly_on_the_cap_is_accepted(
    http, active_user, device, bearer
):
    """The boundary either side of MAX_STORED_PQ_OTPKS. The cap is a storage budget
    — 100 × 1184 B per device — so the batch that reaches it exactly is the largest
    one that may go in."""
    stock_pq_prekeys(device, MAX_STORED_PQ_OTPKS - 3, start=1000)
    headers = bearer(active_user, device)

    exact = http.put(
        prekeys_url(device.id), json={"pq_otpks": pq_otpks(3)}, headers=headers
    )
    one_more = http.put(
        prekeys_url(device.id),
        json={"pq_otpks": pq_otpks(1, start=50)},
        headers=headers,
    )

    assert exact.status_code == 200
    assert one_more.status_code == 409
    assert one_more.json()["code"] == "prekey_limit"
    counts = http.get(f"{prekeys_url(device.id)}/count", headers=headers).json()
    assert counts["pq_otpk_count"] == MAX_STORED_PQ_OTPKS


def test_re_uploading_a_pq_key_id_is_an_idempotent_retry(
    http, active_user, device, bearer
):
    """Same stance as the classical pool: a key_id the device already stores is
    ignored rather than rejected, so a retry after a lost response stores nothing
    twice."""
    headers = bearer(active_user, device)
    body = {"pq_otpks": pq_otpks(3, start=20)}
    http.put(prekeys_url(device.id), json=body, headers=headers)

    again = http.put(prekeys_url(device.id), json=body, headers=headers)

    assert again.status_code == 200
    assert PqOneTimePrekey.objects.filter(device=device).count() == 3


def test_rotating_the_pq_signed_prekey_replaces_it_whole(
    http, active_user, device, bearer, peer, peer_device
):
    """The rotation a client performs periodically: the stored bytes are replaced
    whole and peers claim the new key with no step in between. Nothing records that
    it happened — ADR-0024 retired the date this used to move, and
    `devices.0003_drop_the_retired_columns` dropped the column."""
    headers = bearer(active_user, device)
    http.put(
        prekeys_url(device.id), json={"pq_spk": pq_spk(b"F", spk_id=1)}, headers=headers
    )

    rotated = http.put(
        prekeys_url(device.id), json={"pq_spk": pq_spk(b"G", spk_id=2)}, headers=headers
    )

    assert rotated.status_code == 200
    device.refresh_from_db()
    assert device.pq_spk_id == 2
    assert bytes(device.pq_spk_pub) == (b"G" * PQ_PUBKEY_LEN)
    claimed = http.post(
        claim_url(active_user.id),
        json={"device_ids": [str(device.id)]},
        headers=bearer(peer, peer_device),
    ).json()["bundles"][0]
    assert claimed["pq_spk_id"] == 2
    assert claimed["pq_spk_pub"] == pq_pubkey(b"G")


@pytest.mark.parametrize("nbytes", [63, 65, 0])
def test_a_pq_signed_prekey_signature_of_the_wrong_length_is_refused(
    http, active_user, device, bearer, nbytes
):
    """Ed25519 signatures are fixed-size, so an exact check rejects nothing a real
    client would send. A malformed-input guard: the signature itself is stored and
    relayed, never verified."""
    body = {
        "pq_spk": {
            "spk_id": 3,
            "pub": pq_pubkey(b"H"),
            "sig": base64.b64encode(b"s" * nbytes).decode(),
        }
    }

    response = http.put(
        prekeys_url(device.id), json=body, headers=bearer(active_user, device)
    )

    assert response.status_code == 400
    assert response.json()["detail"]["pq_spk.sig"] == ["bad signature length"]
    device.refresh_from_db()
    assert device.pq_spk_id is None


def test_a_device_that_uploads_pq_material_late_serves_a_hybrid_bundle_afterwards(
    http, active_user, device, bearer, peer, peer_device
):
    """The upgrade path: a device registered classical-only becomes hybrid when it
    replenishes, and nothing has to be re-registered for peers to see it."""
    headers = bearer(active_user, device)
    before = http.post(
        claim_url(active_user.id),
        json={"device_ids": [str(device.id)]},
        headers=bearer(peer, peer_device),
    ).json()["bundles"][0]

    http.put(
        prekeys_url(device.id),
        json={"pq_spk": pq_spk(b"J", spk_id=7), "pq_otpks": pq_otpks(1, start=3)},
        headers=headers,
    )

    after = http.post(
        claim_url(active_user.id),
        json={"device_ids": [str(device.id)]},
        headers=bearer(peer, peer_device),
    ).json()["bundles"][0]
    assert "pq_spk_pub" not in before
    assert after["pq_spk_id"] == 7
    assert after["pq_otpk"]["key_id"] == 3
    assert PqOneTimePrekey.objects.filter(device=device).count() == 0
