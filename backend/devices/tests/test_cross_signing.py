"""Cross-signing identity and device-signature relay.

Server-side halves only. The security property — a peer refusing to encrypt to an
unsigned device, or alarming on a changed master key — lives in the client and is
specified in CLIENT_CONTRACT.md; these tests prove the server relays the material
verbatim and never fakes, fills in, or smooths over any of it.
"""

import base64
import threading

import pytest
from django.db import connections

from devices.models import Device, UserIdentity
from devices.schemas import MAX_KEY_INT, PUBKEY_MAX, PUBKEY_MIN

from .conftest import DEVICES_URL, connect_then_wait, make_device, register_payload

pytestmark = pytest.mark.django_db(transaction=True)

IDENTITY_URL = "/api/v1/me/identity"


def peer_identity_url(user_id):
    return f"/api/v1/users/{user_id}/identity"


def peer_devices_url(user_id):
    return f"/api/v1/users/{user_id}/devices"


def claim_url(user_id):
    return f"/api/v1/users/{user_id}/keys/claim"


def b64key(seed=b"k"):
    return base64.b64encode((seed * 32)[:32]).decode()


def b64sig(seed=b"g"):
    return base64.b64encode((seed * 64)[:64]).decode()


def identity_payload(
    version=1, master=b"m", self_signing=b"s", user_signing=b"u", sig=b"g", **overrides
):
    payload = {
        "master_pub": b64key(master),
        "self_signing_pub": b64key(self_signing),
        "user_signing_pub": b64key(user_signing),
        "master_sig": b64sig(sig),
        "version": version,
    }
    payload.update(overrides)
    return payload


def test_a_published_identity_reads_back_byte_identical(
    http, active_user, device, bearer, peer, peer_device
):
    payload = identity_payload()
    headers = bearer(active_user, device)

    assert http.put(IDENTITY_URL, json=payload, headers=headers).status_code == 200

    body = http.get(
        peer_identity_url(active_user.id), headers=bearer(peer, peer_device)
    ).json()
    # `etag` is the one field the read adds that the write did not carry: it is
    # derived from the four key fields and the version, never stored.
    assert body.pop("etag").startswith('"')
    assert body == payload


def test_a_stale_or_equal_version_is_rejected_without_mutating_stored_bytes(
    http, active_user, device, bearer
):
    headers = bearer(active_user, device)
    http.put(IDENTITY_URL, json=identity_payload(version=2), headers=headers)

    for version in (2, 1):
        response = http.put(
            IDENTITY_URL,
            json=identity_payload(version=version, master=b"X"),
            headers=headers,
        )
        assert response.status_code == 409
        assert response.json()["code"] == "stale_version"

    identity = UserIdentity.objects.get(user=active_user)
    assert bytes(identity.master_pub) == b"m" * 32
    assert identity.version == 2


def test_an_unpublished_identity_is_a_404(http, active_user, device, bearer, peer):
    response = http.get(peer_identity_url(peer.id), headers=bearer(active_user, device))

    assert response.status_code == 404
    assert response.json()["code"] == "not_found"


def test_a_deactivated_users_identity_is_a_404(
    http, active_user, device, bearer, peer, peer_device
):
    http.put(IDENTITY_URL, json=identity_payload(), headers=bearer(peer, peer_device))
    peer.is_active = False
    peer.save(update_fields=["is_active"])

    assert (
        http.get(
            peer_identity_url(peer.id), headers=bearer(active_user, device)
        ).status_code
        == 404
    )


@pytest.mark.parametrize(
    "field, value",
    [
        ("master_pub", "not-base64!!"),
        ("master_sig", ""),
        ("master_sig", "AAAA"),  # decodes to 3 bytes, not 64
        ("version", -1),
        ("version", 2**40),
    ],
)
def test_malformed_identity_material_is_rejected(
    http, active_user, device, bearer, field, value
):
    response = http.put(
        IDENTITY_URL,
        json=identity_payload(**{field: value}),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400


def test_unknown_identity_fields_are_rejected(http, active_user, device, bearer):
    response = http.put(
        IDENTITY_URL,
        json=identity_payload(recovery_key="oops"),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400


def test_the_peer_list_and_claim_surface_the_cross_sig_verbatim(
    http, active_user, device, bearer, peer
):
    signed = make_device(
        peer, registration_id=700, cross_sig=b"\xc5" * 64, bundle_version=3
    )
    headers = bearer(active_user, device)
    expected = base64.b64encode(b"\xc5" * 64).decode()

    listed = http.get(peer_devices_url(peer.id), headers=headers).json()["devices"][0]
    claimed = http.post(claim_url(peer.id), json={}, headers=headers).json()["bundles"][0]

    for entry in (listed, claimed):
        assert entry["device_id"] == str(signed.id)
        assert entry["cross_sig"] == expected
        assert entry["bundle_version"] == 3


def test_an_unsigned_device_stays_visibly_unsigned_everywhere(
    http, active_user, device, bearer, peer, peer_device
):
    """Server-side half of "forged enrollment rejected": a device with no cross_sig
    (the state every device is in between registering and its follow-up
    cross-signing call, and the state a pre-cross-signing row was left in) must
    appear with cross_sig null in the list and the claim, and the DB column must
    be null — no code path may substitute, default, or synthesize a signature.
    The other half — a peer refusing to encrypt to an unsigned device — is client
    behaviour, belongs to CLIENT_CONTRACT.md, and is deliberately not simulated
    here."""
    legacy = make_device(peer, registration_id=701)  # pre-cross-signing row
    headers = bearer(active_user, device)

    listed = http.get(peer_devices_url(peer.id), headers=headers).json()["devices"]
    claimed = http.post(claim_url(peer.id), json={}, headers=headers).json()["bundles"]

    by_id = {entry["device_id"]: entry for entry in listed}
    assert by_id[str(legacy.id)]["cross_sig"] is None
    assert by_id[str(legacy.id)]["bundle_version"] == 0
    by_id = {entry["device_id"]: entry for entry in claimed}
    assert by_id[str(legacy.id)]["cross_sig"] is None
    legacy.refresh_from_db()
    assert legacy.cross_sig is None


def test_a_substituted_master_key_is_served_verbatim_not_smoothed_over(
    http, active_user, device, bearer, peer, peer_device
):
    """Server-side half of "substituted master key alarms": overwriting an identity
    with a different master_pub at a higher version must be returned exactly as
    stored, version incremented — the server does not merge, hide, or reconcile the
    change. The alarm itself (blocking the conversation pending re-verification) is
    client behaviour, specified in CLIENT_CONTRACT.md."""
    mine = bearer(active_user, device)
    http.put(IDENTITY_URL, json=identity_payload(version=1, master=b"A"), headers=mine)

    replaced = identity_payload(version=2, master=b"B", sig=b"h")
    assert http.put(IDENTITY_URL, json=replaced, headers=mine).status_code == 200

    body = http.get(
        peer_identity_url(active_user.id), headers=bearer(peer, peer_device)
    ).json()
    assert body["version"] == 2
    body.pop("etag")
    assert body == replaced


def test_a_prekey_replenish_can_refresh_the_cross_signature(
    http, active_user, device, bearer
):
    from .conftest import pubkey

    body = {
        "spk": {"spk_id": 9, "pub": pubkey(b"n"), "sig": pubkey(b"o")},
        "cross_sig": b64sig(b"f"),
        "bundle_version": 2,
    }

    response = http.put(
        f"{DEVICES_URL}/{device.id}/prekeys",
        json=body,
        headers=bearer(active_user, device),
    )

    assert response.status_code == 200
    device.refresh_from_db()
    assert device.spk_id == 9
    assert bytes(device.cross_sig) == b"f" * 64
    assert device.bundle_version == 2


def test_a_malformed_cross_sig_at_a_replenish_is_rejected(
    http, active_user, device, bearer
):
    """Length is checked where a cross_sig is actually accepted. Malformed-input
    guard only — the bytes themselves are never verified."""
    response = http.put(
        f"{DEVICES_URL}/{device.id}/prekeys",
        json={"cross_sig": "AAAA", "bundle_version": 1},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400
    device.refresh_from_db()
    assert device.cross_sig is None


@pytest.mark.parametrize("field", ["cross_sig", "bundle_version"])
def test_a_replenish_with_half_the_cross_signing_pair_is_rejected(
    http, active_user, device, bearer, field
):
    """The prekeys endpoint is where a device's first cross_sig arrives, so the
    same malformed-input guard applies: a signature stored against bundle_version
    0 is one peers must reject."""
    body = {"cross_sig": b64sig(b"f"), "bundle_version": 2}
    del body[field]

    response = http.put(
        f"{DEVICES_URL}/{device.id}/prekeys",
        json=body,
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400
    device.refresh_from_db()
    assert device.cross_sig is None
    assert device.bundle_version == 0


@pytest.mark.parametrize(
    "body",
    [
        {"cross_sig": None, "bundle_version": None},
        {"cross_sig": None, "bundle_version": None, "otpks": []},
    ],
    ids=["the pair alone", "the pair beside an empty replenishment"],
)
def test_a_replenish_that_sends_a_null_version_is_rejected(
    http, active_user, device, bearer, body
):
    """The other half of the guard above. `bundle_version` is declared optional so
    that "not sent" is expressible, but `Device.bundle_version` cannot hold null:
    a sent null reached the column and the route answered `500`. Both keys present
    and null passes the pairing check, which is exactly why the null needs a guard
    of its own."""
    response = http.put(
        f"{DEVICES_URL}/{device.id}/prekeys",
        json=body,
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"
    device.refresh_from_db()
    assert device.cross_sig is None
    assert device.bundle_version == 0


def test_a_replenish_may_still_retract_a_signature_against_a_new_version(
    http, active_user, device, bearer
):
    """The boundary the guard must not cross: `cross_sig` is nullable, so clearing
    the signature while naming the version it was cleared at is a legitimate write
    and still answers `200`."""
    device.cross_sig = b"\xc5" * 64
    device.bundle_version = 2
    device.save(update_fields=["cross_sig", "bundle_version"])

    response = http.put(
        f"{DEVICES_URL}/{device.id}/prekeys",
        json={"cross_sig": None, "bundle_version": 3},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 200
    device.refresh_from_db()
    assert device.cross_sig is None
    assert device.bundle_version == 3


def test_enrollment_can_cross_sign_the_device_id_the_server_assigned(
    http, active_user, register_bearer
):
    """The whole enrollment order, end to end, with no step the client cannot
    execute. `cross_sig` covers `device_id`, and only the 201 reveals it, so the
    first call goes out unsigned; the full-scope token it returns is what lets the
    device fetch its key backup for the self-signing key and then cross-sign the
    id it now knows. Before this, both halves of that dependency were required
    up front and the only way through was uploading signature-shaped garbage."""
    first = http.post(
        DEVICES_URL, json=register_payload(), headers=register_bearer(active_user)
    )
    assert first.status_code == 201
    device_id = first.json()["device_id"]
    full = {"Authorization": f"Bearer {first.json()['token']}"}

    # Signing happens here, over the assigned device_id — the client is not
    # guessing, and the server never sees the private half.
    signed = http.put(
        f"{DEVICES_URL}/{device_id}/prekeys",
        json={"cross_sig": b64sig(b"z"), "bundle_version": 1},
        headers=full,
    )

    assert signed.status_code == 200
    stored = Device.objects.get(id=device_id)
    assert bytes(stored.cross_sig) == b"z" * 64
    assert stored.bundle_version == 1


def publish_storm(new_http, headers, payloads):
    """Fire one identity publish per payload at once, and collect the answers."""
    start = threading.Barrier(len(payloads))
    answers, failures = [], []
    lock = threading.Lock()

    def publish(payload):
        try:
            connect_then_wait(start)
            response = new_http().put(IDENTITY_URL, json=payload, headers=headers)
            code = response.json()["code"] if response.content else None
            with lock:
                answers.append((payload["version"], response.status_code, code))
        except Exception as exc:  # noqa: BLE001 - surfaced through `failures`
            with lock:
                failures.append(repr(exc))
        finally:
            connections.close_all()

    threads = [threading.Thread(target=publish, args=(p,)) for p in payloads]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert failures == []
    return answers


def test_concurrent_first_publishes_settle_on_exactly_one_identity(
    new_http, active_user, device, bearer
):
    """The first publish is the one the version check cannot protect on its own:
    the identity row does not exist yet, so a lock on it would lock nothing and
    every racer would pass the check. The unit of work locks the account row
    instead, so exactly one of them wins and the losers are told the version they
    sent is stale."""
    seeds = [bytes([65 + i]) for i in range(6)]
    payloads = [identity_payload(version=1, master=seed) for seed in seeds]

    answers = publish_storm(new_http, bearer(active_user, device), payloads)

    statuses = [status for _version, status, _code in answers]
    assert statuses.count(200) == 1
    assert statuses.count(409) == len(seeds) - 1
    assert {code for _v, status, code in answers if status == 409} == {"stale_version"}
    assert UserIdentity.objects.count() == 1
    stored = UserIdentity.objects.get(user=active_user)
    assert stored.version == 1
    assert bytes(stored.master_pub) in {(seed * 32)[:32] for seed in seeds}


def test_concurrent_publishes_at_different_versions_keep_the_highest_accepted(
    new_http, active_user, device, bearer
):
    """Six racers, six versions. Whichever order they reach the lock in, the row
    that survives carries the highest version that was ever accepted, and every
    refusal is a stale one — never a lost update that leaves a lower version
    stored than a client was told had landed."""
    versions = [1, 2, 3, 4, 5, 6]
    payloads = [
        identity_payload(version=v, master=bytes([70 + v]), sig=bytes([80 + v]))
        for v in versions
    ]

    answers = publish_storm(new_http, bearer(active_user, device), payloads)

    accepted = [version for version, status, _code in answers if status == 200]
    assert accepted, "every concurrent publish was refused"
    assert {code for _v, status, code in answers if status == 409} <= {"stale_version"}
    stored = UserIdentity.objects.get(user=active_user)
    assert stored.version == max(accepted)
    assert bytes(stored.master_pub) == (bytes([70 + max(accepted)]) * 32)[:32]


def test_an_identity_first_published_at_version_zero_cannot_be_republished_there(
    http, active_user, device, bearer
):
    """The boundary of the version check: a first publish has nothing to compare
    against, so version 0 lands; the second one does, and `<=` refuses it. A client
    that starts its counter at 0 must move off it to publish again."""
    headers = bearer(active_user, device)

    first = http.put(IDENTITY_URL, json=identity_payload(version=0), headers=headers)
    again = http.put(
        IDENTITY_URL, json=identity_payload(version=0, master=b"X"), headers=headers
    )
    moved_on = http.put(
        IDENTITY_URL, json=identity_payload(version=1, master=b"Y"), headers=headers
    )

    assert first.status_code == 200
    assert again.status_code == 409
    assert moved_on.status_code == 200
    stored = UserIdentity.objects.get(user=active_user)
    assert stored.version == 1
    assert bytes(stored.master_pub) == b"Y" * 32


def test_the_version_column_takes_its_largest_value_and_refuses_one_past_it(
    http, active_user, device, bearer
):
    """`version` is a 32-bit column, so the schema bounds it: without the bound the
    larger integer reaches the column as a DataError, which is a 500 on input the
    schema exists to filter."""
    headers = bearer(active_user, device)

    at_ceiling = http.put(
        IDENTITY_URL, json=identity_payload(version=MAX_KEY_INT), headers=headers
    )
    past_it = http.put(
        IDENTITY_URL, json=identity_payload(version=MAX_KEY_INT + 1), headers=headers
    )

    assert at_ceiling.status_code == 200
    assert past_it.status_code == 400
    assert past_it.json()["code"] == "invalid_request"
    assert UserIdentity.objects.get(user=active_user).version == MAX_KEY_INT


@pytest.mark.parametrize("nbytes", [PUBKEY_MIN - 1, PUBKEY_MAX + 1])
def test_a_cross_signing_key_outside_the_sanity_bounds_is_refused(
    http, active_user, device, bearer, nbytes
):
    """Malformed-input guard, not verification: the bounds keep a wrong-sized value
    out of the column, and the bytes inside them are never parsed."""
    outsized = base64.b64encode(b"k" * nbytes).decode()

    response = http.put(
        IDENTITY_URL,
        json=identity_payload(master_pub=outsized),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400
    assert response.json()["detail"]["master_pub"] == ["bad key length"]
    assert not UserIdentity.objects.filter(user=active_user).exists()


@pytest.mark.parametrize("nbytes", [PUBKEY_MIN, PUBKEY_MAX])
def test_a_cross_signing_key_on_either_bound_is_stored_verbatim(
    http, active_user, device, bearer, peer, peer_device, nbytes
):
    """The other side of the same boundary, so the guard is shown to be a bound and
    not a rejection of everything."""
    sized = base64.b64encode(b"k" * nbytes).decode()

    response = http.put(
        IDENTITY_URL,
        json=identity_payload(master_pub=sized),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 200
    served = http.get(
        peer_identity_url(active_user.id), headers=bearer(peer, peer_device)
    ).json()
    assert served["master_pub"] == sized
