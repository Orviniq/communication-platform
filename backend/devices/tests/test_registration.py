import base64

import pytest

from core.buckets import LABEL_BUCKETS
from devices.models import Device, OneTimePrekey
from devices.schemas import MAX_KEY_INT

from .conftest import (
    DEVICES_URL,
    cross_sig_b64,
    label_blob,
    make_device,
    pubkey,
    publish_identity,
    register_payload,
)

pytestmark = pytest.mark.django_db(transaction=True)


def test_a_register_scope_token_registers_a_device_and_gets_a_session_token(
    http, active_user, register_bearer, settings
):
    """The register-scope token from login exists only to reach this endpoint."""
    response = http.post(
        DEVICES_URL, json=register_payload(otpks=3), headers=register_bearer(active_user)
    )

    assert response.status_code == 201
    body = response.json()
    assert set(body) == {"device_id", "token", "expires_in", "scope"}
    assert body["scope"] == "full"
    assert body["expires_in"] == settings.SESSION_TOKEN_DAYS * 86400
    device = Device.objects.get(id=body["device_id"])
    assert device.user_id == active_user.id
    assert OneTimePrekey.objects.filter(device=device).count() == 3
    # The issued token is genuinely full scope: it reaches an endpoint the register
    # token could not.
    assert (
        http.get(
            DEVICES_URL, headers={"Authorization": f"Bearer {body['token']}"}
        ).status_code
        == 200
    )


def test_a_full_scope_token_may_also_register_another_device(
    http, active_user, device, bearer
):
    publish_identity(active_user)
    response = http.post(
        DEVICES_URL, json=register_payload(), headers=bearer(active_user, device)
    )

    assert response.status_code == 201
    assert Device.objects.filter(user=active_user).count() == 2


def test_the_label_blob_is_stored_when_supplied(http, active_user, bearer, device):
    publish_identity(active_user)
    response = http.post(
        DEVICES_URL,
        json=register_payload(label_blob=label_blob()),
        headers=bearer(active_user, device),
    )

    stored = Device.objects.get(id=response.json()["device_id"]).label_blob
    assert stored is not None


def test_the_eleventh_live_device_is_refused(http, active_user, bearer, settings):
    for i in range(settings.MAX_DEVICES_PER_USER):
        make_device(active_user, registration_id=100 + i)
    first = Device.objects.filter(user=active_user).first()

    response = http.post(
        DEVICES_URL, json=register_payload(), headers=bearer(active_user, first)
    )

    assert response.status_code == 409
    assert response.json()["code"] == "device_limit"
    assert (
        Device.objects.filter(user=active_user).count() == settings.MAX_DEVICES_PER_USER
    )


def test_revoked_devices_do_not_count_against_the_cap(
    http, active_user, bearer, settings
):
    from django.utils import timezone

    publish_identity(active_user)
    live = make_device(active_user, registration_id=1)
    for i in range(settings.MAX_DEVICES_PER_USER + 4):
        make_device(
            active_user, registration_id=200 + i, revoked_date=timezone.now().date()
        )

    response = http.post(
        DEVICES_URL, json=register_payload(), headers=bearer(active_user, live)
    )

    assert response.status_code == 201


def test_a_duplicate_key_id_in_the_payload_is_a_400_not_a_500(
    http, active_user, device, bearer
):
    """`unique (device, key_id)` turns a repeated key_id into an IntegrityError from
    bulk_create unless the schema rejects it first."""
    payload = register_payload(otpks=0)
    payload["otpks"] = [
        {"key_id": 7, "pub": pubkey(b"a")},
        {"key_id": 7, "pub": pubkey(b"b")},
    ]

    response = http.post(DEVICES_URL, json=payload, headers=bearer(active_user, device))

    assert response.status_code == 400
    assert Device.objects.filter(user=active_user).count() == 1  # nothing committed


def test_an_out_of_range_key_id_is_a_400_not_a_500(http, active_user, device, bearer):
    """PositiveIntegerField is a 32-bit column; a larger value reaches it as a
    DataError."""
    payload = register_payload(otpks=0)
    payload["otpks"] = [{"key_id": 2**40, "pub": pubkey()}]

    response = http.post(DEVICES_URL, json=payload, headers=bearer(active_user, device))

    assert response.status_code == 400


@pytest.mark.parametrize(
    "field, value",
    [
        ("ik_pub", "not-base64!!"),
        ("spk_pub", ""),
        ("ik_pub", pubkey()[:8]),  # decodes, but far under PUBKEY_MIN
        ("registration_id", -1),
        ("spk_id", 2**40),
    ],
)
def test_malformed_key_material_is_rejected(
    http, active_user, device, bearer, field, value
):
    response = http.post(
        DEVICES_URL,
        json=register_payload(**{field: value}),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400


def test_a_malformed_key_names_the_field_it_failed_on(http, active_user, device, bearer):
    """The decode runs inside its own field, so the path a client reads points at
    the item that failed rather than at the whole body."""
    payload = register_payload(otpks=0)
    payload["otpks"] = [
        {"key_id": 1, "pub": pubkey()},
        {"key_id": 2, "pub": "not-base64!!"},
    ]

    response = http.post(DEVICES_URL, json=payload, headers=bearer(active_user, device))

    body = response.json()
    assert body["code"] == "invalid_request"
    assert body["detail"] == {"otpks.1.pub": ["invalid base64"]}


def test_a_label_blob_outside_its_bucket_is_rejected_without_echoing_it(
    http, active_user, device, bearer
):
    off_bucket = base64.b64encode(b"x" * 300).decode()

    response = http.post(
        DEVICES_URL,
        json=register_payload(label_blob=off_bucket),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400
    assert response.json()["code"] == "bad_bucket"
    assert off_bucket not in response.text


def test_unknown_fields_are_rejected(http, active_user, device, bearer):
    response = http.post(
        DEVICES_URL,
        json=register_payload(private_key="oops"),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400


def test_more_than_two_hundred_otpks_are_rejected(http, active_user, device, bearer):
    response = http.post(
        DEVICES_URL,
        json=register_payload(otpks=201),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 400


def test_an_anonymous_registration_is_rejected(http):
    assert http.post(DEVICES_URL, json=register_payload()).status_code == 401


def test_registration_leaves_the_device_never_cross_signed(
    http, active_user, register_bearer
):
    """The enrollment order the client can actually execute: the signed bundle
    covers `device_id`, which this request mints, so no first call can carry a
    valid cross_sig. The row is therefore born in the null/0 "never cross-signed"
    state peers already refuse, and nothing substitutes or synthesizes a value."""
    response = http.post(
        DEVICES_URL, json=register_payload(), headers=register_bearer(active_user)
    )

    assert response.status_code == 201
    stored = Device.objects.get(id=response.json()["device_id"])
    assert stored.cross_sig is None
    assert stored.bundle_version == 0


@pytest.mark.parametrize(
    "extra",
    [
        {"cross_sig": cross_sig_b64()},
        {"bundle_version": 1},
        # The payload a client written against the old contract sends: both must be
        # named in the error, not just the first one found.
        {"cross_sig": cross_sig_b64(), "bundle_version": 1},
    ],
)
def test_registration_refuses_the_cross_signing_fields_with_a_pointer(
    http, active_user, register_bearer, extra
):
    """No valid value exists for either field here, so the endpoint refuses both
    rather than storing bytes that can only be wrong — and the error names the
    endpoint that does accept them, since "Extra inputs are not permitted" on a
    field that was mandatory until recently reads like a version mismatch.

    Not a security control: peers must reject unverifiable devices on their own,
    and a modified server would accept anything. It stops a client from believing
    it cross-signed a device it did not."""
    payload = register_payload()
    payload.update(extra)

    response = http.post(DEVICES_URL, json=payload, headers=register_bearer(active_user))

    assert response.status_code == 400
    detail = response.json()["detail"]
    for field in extra:
        assert "prekeys" in str(detail[field]), (
            f"{field} not pointed at the right endpoint"
        )
    assert Device.objects.filter(user=active_user).count() == 0


def test_a_second_device_requires_a_published_identity(http, active_user, device, bearer):
    """Same completeness-check framing: past the first device, an account with no
    published identity registering another device can only be a mis-sequenced
    client, so it is told so instead of producing an unverifiable device."""
    response = http.post(
        DEVICES_URL, json=register_payload(), headers=bearer(active_user, device)
    )

    assert response.status_code == 400
    assert response.json()["code"] == "identity_required"
    assert Device.objects.filter(user=active_user).count() == 1


def test_the_first_device_is_exempt_from_the_identity_precondition(
    http, active_user, register_bearer
):
    """The bootstrap exemption: a fresh account's register-scope token reaches
    only this endpoint, so it cannot have published an identity yet. The client
    publishes immediately after with the full token issued here."""
    response = http.post(
        DEVICES_URL, json=register_payload(), headers=register_bearer(active_user)
    )

    assert response.status_code == 201


def test_exactly_two_hundred_prekeys_are_accepted(http, active_user, device, bearer):
    """The boundary either side of MAX_OTPKS: 201 is refused above, so 200 is the
    largest batch a device can arrive with."""
    publish_identity(active_user)

    response = http.post(
        DEVICES_URL, json=register_payload(otpks=200), headers=bearer(active_user, device)
    )

    assert response.status_code == 201
    assert (
        OneTimePrekey.objects.filter(device_id=response.json()["device_id"]).count()
        == 200
    )


@pytest.mark.parametrize("registration_id", [0, MAX_KEY_INT])
def test_a_registration_id_on_either_bound_of_the_column_is_stored(
    http, active_user, device, bearer, peer, peer_device, registration_id
):
    """`registration_id` is a 32-bit column and the value is opaque: the schema
    bounds it so the column never sees a DataError, and stores whatever fits."""
    publish_identity(active_user)

    response = http.post(
        DEVICES_URL,
        json=register_payload(registration_id=registration_id),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 201
    stored = Device.objects.get(id=response.json()["device_id"])
    assert stored.registration_id == registration_id


@pytest.mark.parametrize("size", LABEL_BUCKETS)
def test_a_label_at_either_bucket_size_round_trips_byte_identically(
    http, active_user, device, bearer, size
):
    """Both buckets are legal lengths, and the label is ciphertext: it comes back
    exactly as it went in, with no re-encoding in between."""
    publish_identity(active_user)
    blob = base64.b64encode(bytes(range(256)) * (size // 256)).decode()

    registered = http.post(
        DEVICES_URL,
        json=register_payload(label_blob=blob),
        headers=bearer(active_user, device),
    )

    assert registered.status_code == 201
    stored = Device.objects.get(id=registered.json()["device_id"])
    assert bytes(stored.label_blob) == base64.b64decode(blob)
    listed = http.get(DEVICES_URL, headers=bearer(active_user, device)).json()
    labels = [entry["label_blob"] for entry in listed["devices"] if entry["label_blob"]]
    assert labels == [blob]


def test_the_issued_token_is_bound_to_the_new_device_and_no_other(
    http, active_user, device, bearer
):
    """The token the 201 carries is what the client cross-signs with, so it must
    reach the new device's own prekeys route and be refused on a sibling's."""
    publish_identity(active_user)
    registered = http.post(
        DEVICES_URL, json=register_payload(), headers=bearer(active_user, device)
    ).json()
    issued = {"Authorization": f"Bearer {registered['token']}"}

    own = http.get(
        f"{DEVICES_URL}/{registered['device_id']}/prekeys/count", headers=issued
    )
    sibling = http.get(f"{DEVICES_URL}/{device.id}/prekeys/count", headers=issued)

    assert own.status_code == 200
    assert own.json() == {"otpk_count": 1, "pq_otpk_count": 0}  # the one it arrived with
    assert sibling.status_code == 403
    assert sibling.json()["code"] == "forbidden"


def test_a_registration_that_carries_pq_material_but_no_prekeys_is_accepted(
    http, active_user, device, bearer
):
    """The two optional halves are independent: a device may arrive with a PQ signed
    prekey and an empty classical pool, and neither absence stands in for the
    other."""
    from .test_pq_prekeys import pq_spk

    publish_identity(active_user)
    payload = register_payload(otpks=0, pq_spk=pq_spk(b"W", spk_id=5))

    response = http.post(DEVICES_URL, json=payload, headers=bearer(active_user, device))

    assert response.status_code == 201
    stored = Device.objects.get(id=response.json()["device_id"])
    assert stored.pq_spk_id == 5
    assert stored.pq_spk_updated_date is not None
    assert OneTimePrekey.objects.filter(device=stored).count() == 0
