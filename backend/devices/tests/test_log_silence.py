"""Nothing on the device or key-distribution paths logs an identifier or key material.

The capture replaces every handler, so the configured `ScrubFilter` never runs on
what it collects. That is deliberate, and it is why `caplog` is not used here: the
filter mutates the record in place on the console handler, so any capture that
runs after it grades the scrubber rather than the code. The scrubber is a
backstop; what these tests assert is that nothing is emitted in the first place,
and `core/tests/test_scrub.py` covers the filter itself.
"""

import base64
import logging

import pytest
from django.test import override_settings

from ops.audit.log_silence import capture_all_logging

from .conftest import (
    DEVICES_URL,
    label_blob,
    make_device,
    pubkey,
    publish_identity,
    register_payload,
    stock_prekeys,
)

pytestmark = pytest.mark.django_db(transaction=True)


def test_the_whole_device_lifecycle_emits_no_identifier_or_key(
    http, active_user, device, bearer, peer, peer_device
):
    publish_identity(active_user)  # registration past the first device needs one
    stock_prekeys(peer_device, 2)
    headers = bearer(active_user, device)
    payload = register_payload(otpks=2, label_blob=label_blob())

    with capture_all_logging() as lines:
        registered = http.post(DEVICES_URL, json=payload, headers=headers)
        new_id = registered.json()["device_id"]
        http.get(DEVICES_URL, headers=headers)
        http.get(f"/api/v1/users/{peer.id}/devices", headers=headers)
        claim = http.post(f"/api/v1/users/{peer.id}/keys/claim", json={}, headers=headers)
        http.put(
            f"{DEVICES_URL}/{device.id}/prekeys",
            json={"otpks": [{"key_id": 42, "pub": pubkey(b"r")}]},
            headers=headers,
        )
        http.delete(f"{DEVICES_URL}/{new_id}", headers=headers)

    assert registered.status_code == 201
    bundle = claim.json()["bundles"][0]
    forbidden = {
        "registered device id": new_id,
        "calling device id": str(device.id),
        "peer device id": str(peer_device.id),
        "caller user id": str(active_user.id),
        "peer user id": str(peer.id),
        "uploaded identity key": payload["ik_pub"],
        "uploaded label blob": payload["label_blob"],
        "claimed identity key": bundle["ik_pub"],
        "claimed one-time prekey": bundle["otpk"]["pub"],
        "issued session token": registered.json()["token"],
    }
    for line in lines:
        for label, secret in forbidden.items():
            assert secret not in line, f"{label} leaked into a log line"


def test_rejected_input_is_not_echoed_into_the_logs(
    http, active_user, device, bearer, register_bearer, peer_device
):
    """The bad-bucket and forbidden paths must not log what they refused."""
    headers = bearer(active_user, device)
    off_bucket = base64.b64encode(b"q" * 77).decode()

    with capture_all_logging() as lines:
        rejected = http.post(
            DEVICES_URL, json=register_payload(label_blob=off_bucket), headers=headers
        )
        forbidden = http.get(
            f"{DEVICES_URL}/{peer_device.id}/prekeys/count", headers=headers
        )
        scoped_out = http.get(DEVICES_URL, headers=register_bearer(active_user))

    assert rejected.status_code == 400
    assert forbidden.status_code == 403
    assert scoped_out.status_code == 403
    for line in lines:
        assert off_bucket not in line
        assert str(peer_device.id) not in line
        assert str(active_user.id) not in line


def test_the_capture_is_live_and_unscrubbed(active_user):
    """Guards the guards above. A clean request logs nothing at all, so a loop over
    an empty list would pass no matter what the code emitted; and a capture that
    ran behind the console handler would read `[ID]` where the leak was, and pass
    for the second wrong reason."""
    planted = make_device(active_user, registration_id=4321)

    with capture_all_logging() as lines:
        logging.getLogger("devices.tests.canary").debug("device %s", planted.id)

    assert any(str(planted.id) in line for line in lines)


def test_the_identity_and_device_log_paths_emit_no_identifier_or_blob(
    http, active_user, device, bearer, peer, peer_device
):
    """The routes the first test does not walk: publishing and reading a
    cross-signing identity, appending to the device-list log and paging it back.
    Every one of them carries an account id in its path or key material in its
    body, and none of that may reach a line."""
    mine = bearer(active_user, device)
    theirs = bearer(peer, peer_device)
    master = base64.b64encode(b"m" * 32).decode()
    identity = {
        "master_pub": master,
        "self_signing_pub": base64.b64encode(b"s" * 32).decode(),
        "user_signing_pub": base64.b64encode(b"u" * 32).decode(),
        "master_sig": base64.b64encode(b"g" * 64).decode(),
        "version": 1,
    }
    record = base64.b64encode(b"R" * 256).decode()

    with capture_all_logging() as lines:
        published = http.put("/api/v1/me/identity", json=identity, headers=mine)
        appended = http.post(
            "/api/v1/me/devicelog", json={"records": [{"blob": record}]}, headers=mine
        )
        http.get(f"/api/v1/users/{active_user.id}/identity", headers=theirs)
        http.get(f"/api/v1/users/{active_user.id}/devicelog?after=0", headers=theirs)

    assert published.status_code == 200
    assert appended.status_code == 201
    forbidden = {
        "caller user id": str(active_user.id),
        "peer user id": str(peer.id),
        "master key": master,
        "log record": record,
    }
    for line in lines:
        for label, secret in forbidden.items():
            assert secret not in line, f"{label} reached a log line"


def test_every_refusal_on_these_paths_is_logged_without_its_input(
    http, active_user, device, bearer, settings
):
    """The four `409`s of this app, which are the answers most likely to be logged
    for diagnosis: a stale identity version, a full account, a full prekey pool and
    a full device log. A refusal that named the account or echoed the payload would
    put in a log line exactly what the refusal kept out of the database."""
    from devices.schemas import MAX_STORED_OTPKS

    headers = bearer(active_user, device)
    publish_identity(active_user, version=5)
    stock_prekeys(device, MAX_STORED_OTPKS, start=1000)
    for index in range(settings.MAX_DEVICES_PER_USER):
        make_device(active_user, registration_id=700 + index)
    master = base64.b64encode(b"z" * 32).decode()
    record = base64.b64encode(b"Z" * 256).decode()

    with capture_all_logging() as lines:
        stale = http.put(
            "/api/v1/me/identity",
            json={
                "master_pub": master,
                "self_signing_pub": master,
                "user_signing_pub": master,
                "master_sig": base64.b64encode(b"g" * 64).decode(),
                "version": 1,
            },
            headers=headers,
        )
        too_many = http.post(DEVICES_URL, json=register_payload(), headers=headers)
        full_pool = http.put(
            f"{DEVICES_URL}/{device.id}/prekeys",
            json={"otpks": [{"key_id": 1, "pub": pubkey(b"r")}]},
            headers=headers,
        )
        with override_settings(MAX_DEVICELOG_RECORDS=0):
            full_log = http.post(
                "/api/v1/me/devicelog",
                json={"records": [{"blob": record}]},
                headers=headers,
            )

    assert [stale.status_code, too_many.status_code] == [409, 409]
    assert [full_pool.status_code, full_log.status_code] == [409, 409]
    assert {response.json()["code"] for response in (stale, too_many)} == {
        "stale_version",
        "device_limit",
    }
    for line in lines:
        for secret in (str(active_user.id), str(device.id), master, record):
            assert secret not in line
