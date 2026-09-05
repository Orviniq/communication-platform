"""The revocation cascade.

One removal must cut the device off completely: its tokens, its mailbox, its
published key material, its presence in peers' device lists, and the ETag siblings
poll.
"""

import base64

import pytest

from api.auth import issue_session
from core.buckets import ENVELOPE_BUCKETS
from devices.models import Device, OneTimePrekey, PqOneTimePrekey
from messaging.models import QueuedEnvelope

from .conftest import (
    DEVICES_URL,
    label_blob,
    make_device,
    stock_pq_prekeys,
    stock_prekeys,
)

pytestmark = pytest.mark.django_db(transaction=True)


def access_headers(access):
    return {"Authorization": f"Bearer {access}"}


@pytest.fixture
def doomed(active_user):
    """A fully-provisioned second device, about to be revoked."""
    device = make_device(active_user, registration_id=8080)
    stock_prekeys(device, 4)
    stock_pq_prekeys(device, 4)
    QueuedEnvelope.objects.bulk_create(
        [
            QueuedEnvelope(
                recipient_device=device, seq=i + 1, blob=b"c" * min(ENVELOPE_BUCKETS)
            )
            for i in range(5)
        ]
    )
    return device


def test_revocation_returns_204_and_marks_the_row(
    http, active_user, device, bearer, doomed
):
    response = http.delete(
        f"{DEVICES_URL}/{doomed.id}", headers=bearer(active_user, device)
    )

    assert response.status_code == 204
    doomed.refresh_from_db()
    assert doomed.revoked_date is not None


def test_the_revoked_devices_session_token_is_rejected(
    http, active_user, device, bearer, doomed
):
    """(a) `token_generation` is bumped, so the authentication dependency refuses
    every outstanding token for it."""
    access, _expires_in = issue_session(active_user, doomed)
    assert http.get(DEVICES_URL, headers=access_headers(access)).status_code == 200

    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=bearer(active_user, device))

    response = http.get(DEVICES_URL, headers=access_headers(access))
    assert response.status_code == 401
    assert response.json()["code"] == "token_revoked"


def test_the_revoked_device_cannot_renew_its_token(
    http, active_user, device, bearer, doomed
):
    """(b) Renewal re-checks the device through the same requirement, so it
    cannot mint a token that outlives the revocation."""
    access, _expires_in = issue_session(active_user, doomed)

    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=bearer(active_user, device))

    response = http.post("/api/v1/auth/renew", headers=access_headers(access))
    assert response.status_code == 401
    assert response.json()["code"] == "token_revoked"


def test_the_queue_and_prekeys_are_deleted(http, active_user, device, bearer, doomed):
    """(c) Nothing of the device's data survives the revoke: classical and PQ
    one-time prekeys and the mailbox, all purged in the one revocation transaction
    (FS/PCS: no key material of a removed device may remain claimable)."""
    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=bearer(active_user, device))

    assert OneTimePrekey.objects.filter(device=doomed).count() == 0
    assert PqOneTimePrekey.objects.filter(device=doomed).count() == 0
    assert QueuedEnvelope.objects.filter(recipient_device=doomed).count() == 0


def test_a_revoked_devices_material_is_never_served_to_claimants(
    http, active_user, device, bearer, doomed, peer, peer_device
):
    """The claim side of the same property: after the revoke, a claim against the
    account neither returns the revoked device nor hands out any of its one-time
    material (classical or PQ)."""
    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=bearer(active_user, device))

    bundles = http.post(
        f"/api/v1/users/{active_user.id}/keys/claim",
        json={},
        headers=bearer(peer, peer_device),
    ).json()["bundles"]

    assert str(doomed.id) not in {b["device_id"] for b in bundles}


def test_the_revoked_device_leaves_the_peer_list(
    http, active_user, device, bearer, doomed, peer, peer_device
):
    """(d) Peers stop seeing it, so they stop encrypting to it."""
    peer_headers = bearer(peer, peer_device)
    url = f"/api/v1/users/{active_user.id}/devices"
    assert str(doomed.id) in {
        d["device_id"] for d in http.get(url, headers=peer_headers).json()["devices"]
    }

    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=bearer(active_user, device))

    assert str(doomed.id) not in {
        d["device_id"] for d in http.get(url, headers=peer_headers).json()["devices"]
    }


def test_the_device_list_etag_changes(
    http, active_user, device, bearer, doomed, peer, peer_device
):
    """(e) Both the owner's siblings and peers notice on their next poll."""
    own_headers = bearer(active_user, device)
    peer_headers = bearer(peer, peer_device)
    peer_url = f"/api/v1/users/{active_user.id}/devices"
    own_before = http.get(DEVICES_URL, headers=own_headers).headers["etag"]
    peer_before = http.get(peer_url, headers=peer_headers).headers["etag"]

    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=own_headers)

    assert http.get(DEVICES_URL, headers=own_headers).headers["etag"] != own_before
    assert http.get(peer_url, headers=peer_headers).headers["etag"] != peer_before


def test_a_sibling_device_is_untouched(http, active_user, device, bearer, doomed):
    """The cascade is scoped to one device, not the account."""
    stock_prekeys(device, 2, start=500)
    survivor_access, _ = issue_session(active_user, device)

    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=bearer(active_user, device))

    assert (
        http.get(DEVICES_URL, headers=access_headers(survivor_access)).status_code == 200
    )
    assert OneTimePrekey.objects.filter(device=device).count() == 2


def test_revoking_twice_is_a_404(http, active_user, device, bearer, doomed):
    headers = bearer(active_user, device)
    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=headers)

    assert http.delete(f"{DEVICES_URL}/{doomed.id}", headers=headers).status_code == 404


def test_a_user_cannot_revoke_another_users_device(
    http, active_user, device, bearer, peer, peer_device
):
    response = http.delete(
        f"{DEVICES_URL}/{peer_device.id}", headers=bearer(active_user, device)
    )

    assert response.status_code == 404  # not 403: the device's existence is not confirmed
    peer_device.refresh_from_db()
    assert peer_device.revoked_date is None


def test_a_revoked_device_cannot_be_relabelled(http, active_user, device, bearer, doomed):
    headers = bearer(active_user, device)
    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=headers)

    response = http.put(
        f"{DEVICES_URL}/{doomed.id}", json={"label_blob": label_blob()}, headers=headers
    )

    assert response.status_code == 404


def test_relabelling_a_live_device_works(http, active_user, device, bearer):
    """Guards the guard above: the 404 is about revocation, not a broken PUT."""
    response = http.put(
        f"{DEVICES_URL}/{device.id}",
        json={"label_blob": label_blob()},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 200
    assert Device.objects.get(id=device.id).label_blob is not None


def test_the_device_list_log_survives_a_revocation(
    http, active_user, device, bearer, doomed, peer, peer_device
):
    """The log is the account's, not the device's, and it is append-only: a client
    records the removal *in* it (CLIENT_CONTRACT.md §J), so a revocation that pruned
    the log would erase the evidence peers compare heads over."""
    from core.buckets import DEVICELOG_BUCKETS

    blob = base64.b64encode(b"R" * min(DEVICELOG_BUCKETS)).decode()
    headers = bearer(active_user, device)
    http.post("/api/v1/me/devicelog", json={"records": [{"blob": blob}]}, headers=headers)

    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=headers)

    page = http.get(
        f"/api/v1/users/{active_user.id}/devicelog", headers=bearer(peer, peer_device)
    ).json()
    assert [record["blob"] for record in page["records"]] == [blob]
    assert page["head_seq"] == 0


def test_the_accounts_identity_survives_a_revocation(
    http, active_user, device, bearer, doomed, peer, peer_device
):
    """Cross-signing identity belongs to the account. Revoking one device must not
    make its peers treat every other device as unverifiable."""
    from .conftest import publish_identity

    publish_identity(active_user, version=3)

    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=bearer(active_user, device))

    served = http.get(
        f"/api/v1/users/{active_user.id}/identity", headers=bearer(peer, peer_device)
    )
    assert served.status_code == 200
    assert served.json()["version"] == 3


def test_revoking_a_device_id_that_never_existed_is_the_same_404(
    http, active_user, device, bearer
):
    """A well-formed id for no device answers exactly as an id from another account
    does, so a 404 never confirms that a device exists."""
    import uuid as uuid_module

    response = http.delete(
        f"{DEVICES_URL}/{uuid_module.uuid4()}", headers=bearer(active_user, device)
    )

    assert response.status_code == 404
    assert response.json()["code"] == "not_found"


def test_a_revoked_device_cannot_replenish_its_own_prekeys(
    http, active_user, device, bearer, doomed
):
    """The token generation bump reaches every route the device had, not just the
    list: a revoked device must not be able to refill the pool the revocation just
    emptied."""
    access, _expires_in = issue_session(active_user, doomed)
    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=bearer(active_user, device))

    response = http.put(
        f"{DEVICES_URL}/{doomed.id}/prekeys",
        json={"otpks": [{"key_id": 1, "pub": base64.b64encode(b"k" * 32).decode()}]},
        headers=access_headers(access),
    )

    assert response.status_code == 401
    assert response.json()["code"] == "token_revoked"
    assert OneTimePrekey.objects.filter(device=doomed).count() == 0


def test_a_revoked_device_is_gone_from_its_owners_own_list_too(
    http, active_user, device, bearer, doomed
):
    """The owner's view and the peers' view agree, so a client's own device table
    does not keep offering a device it can no longer reach."""
    headers = bearer(active_user, device)

    http.delete(f"{DEVICES_URL}/{doomed.id}", headers=headers)

    listed = http.get(DEVICES_URL, headers=headers).json()["devices"]
    assert str(doomed.id) not in {entry["device_id"] for entry in listed}
    assert str(device.id) in {entry["device_id"] for entry in listed}
