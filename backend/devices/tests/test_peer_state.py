"""`POST /api/v1/peers`, and the conditional read that came with it.

Two properties carry the route. The first is that it serves the *same bytes* the
two per-user reads serve: a client that already verifies those answers must verify
these without changing a line, so every assertion about identity and device bodies
here is an equality against the per-user route rather than a restatement of the
shape. The second is the tag: it changes exactly when the identity, the live device
set, a bundle version or the log head changes, and never otherwise — a tag that
moved for anything else would cost a full answer on every poll, and one that failed
to move would leave a sender encrypting to a device that is gone.
"""

import base64
import uuid

import pytest

from accounts.models import User
from devices.models import DeviceLogRecord, UserIdentity
from devices.schemas import MAX_PEERS

from .conftest import PASSWORD, make_device, stock_prekeys

pytestmark = pytest.mark.django_db(transaction=True)

PEERS_URL = "/api/v1/peers"


def identity_url(user_id):
    return f"/api/v1/users/{user_id}/identity"


def devices_url(user_id):
    return f"/api/v1/users/{user_id}/devices"


def publish(user, version=1, master=b"m"):
    UserIdentity.objects.update_or_create(
        user=user,
        defaults={
            "master_pub": (master * 32)[:32],
            "self_signing_pub": b"s" * 32,
            "user_signing_pub": b"u" * 32,
            "master_sig": b"g" * 64,
            "version": version,
        },
    )


def ask(http, headers, *users, **tags):
    """One call for `users`, carrying the tag recorded in `tags` for each of them."""
    body = {
        "peers": [
            {"user_id": str(user.id), **({"etag": tags[str(user.id)]} if tags else {})}
            for user in users
        ]
    }
    return http.post(PEERS_URL, json=body, headers=headers)


def one(http, headers, user, etag=None):
    item = {"user_id": str(user.id)}
    if etag is not None:
        item["etag"] = etag
    response = http.post(PEERS_URL, json={"peers": [item]}, headers=headers)
    assert response.status_code == 200, response.text
    return response.json()["peers"][0]


# --- What it serves ---------------------------------------------------------------


def test_the_answer_is_the_two_per_user_reads_byte_for_byte(
    http, active_user, device, bearer, peer, peer_device
):
    """The whole promise of the route: a client that verifies the per-user answers
    verifies these without change. Compared against the live routes rather than
    against a copy of their shape, so a change to either surface that did not reach
    the other fails here."""
    publish(peer)
    headers = bearer(active_user, device)

    item = one(http, headers, peer)
    identity = http.get(identity_url(peer.id), headers=headers).json()
    listed = http.get(devices_url(peer.id), headers=headers).json()

    assert item["identity"] == identity
    assert item["devices"] == listed["devices"]
    assert item["log_head_seq"] == listed["log_head_seq"]


def test_a_user_with_no_published_identity_carries_a_null_one(
    http, active_user, device, bearer, peer, peer_device
):
    """`null`, not an omitted key and not an empty object: a peer with devices and
    no identity chain must be visibly unverifiable, which is the same thing the
    per-user route says with its 404."""
    headers = bearer(active_user, device)

    item = one(http, headers, peer)

    assert item["identity"] is None
    assert http.get(identity_url(peer.id), headers=headers).status_code == 404
    assert [entry["device_id"] for entry in item["devices"]] == [str(peer_device.id)]


def test_a_user_with_no_live_device_carries_an_empty_list(
    http, active_user, device, bearer, peer, peer_device
):
    publish(peer)
    http.delete(f"/api/v1/me/devices/{peer_device.id}", headers=bearer(peer, peer_device))
    headers = bearer(active_user, device)

    item = one(http, headers, peer)

    assert item["devices"] == []
    assert item["identity"]["version"] == 1
    assert item["log_head_seq"] is None


def test_an_unsigned_device_stays_visibly_unsigned(
    http, active_user, device, bearer, peer, peer_device
):
    signed = make_device(
        peer, registration_id=900, cross_sig=b"\xc5" * 64, bundle_version=3
    )
    headers = bearer(active_user, device)

    by_id = {entry["device_id"]: entry for entry in one(http, headers, peer)["devices"]}

    assert by_id[str(peer_device.id)]["cross_sig"] is None
    assert by_id[str(peer_device.id)]["bundle_version"] == 0
    assert by_id[str(signed.id)]["cross_sig"] == base64.b64encode(b"\xc5" * 64).decode()


def test_the_log_head_is_the_highest_seq_of_that_user(
    http, active_user, device, bearer, peer, peer_device
):
    DeviceLogRecord.objects.bulk_create(
        [DeviceLogRecord(user=peer, seq=i, blob=b"r" * 256) for i in range(7)]
    )

    item = one(http, bearer(active_user, device), peer)

    assert item["log_head_seq"] == 6


# --- Who appears --------------------------------------------------------------------


def test_items_come_back_in_request_order(http, active_user, device, bearer, peer):
    third = User.objects.create_user(username="third", password=PASSWORD, is_active=True)
    headers = bearer(active_user, device)

    forward = ask(http, headers, peer, third, active_user).json()["peers"]
    backward = ask(http, headers, active_user, third, peer).json()["peers"]

    assert [item["user_id"] for item in forward] == [
        str(peer.id),
        str(third.id),
        str(active_user.id),
    ]
    assert [item["user_id"] for item in backward] == [
        str(active_user.id),
        str(third.id),
        str(peer.id),
    ]


@pytest.mark.parametrize("state", ["unknown", "inactive"])
def test_a_user_who_should_not_be_read_is_omitted_rather_than_refused(
    http, active_user, device, bearer, peer, peer_device, state
):
    """An id nobody holds and an id belonging to a deactivated account answer the
    same way, which is what keeps the route from being a membership oracle: a
    caller cannot tell a username that never existed from one the operator turned
    off."""
    publish(peer)
    if state == "inactive":
        target = peer
        peer.is_active = False
        peer.save(update_fields=["is_active"])
    else:
        target = User(id=uuid.uuid4())
    headers = bearer(active_user, device)

    response = http.post(
        PEERS_URL,
        json={"peers": [{"user_id": str(target.id)}, {"user_id": str(active_user.id)}]},
        headers=headers,
    )

    assert response.status_code == 200
    assert [item["user_id"] for item in response.json()["peers"]] == [str(active_user.id)]


def test_every_requested_peer_missing_is_an_empty_list_not_an_error(
    http, active_user, device, bearer
):
    response = http.post(
        PEERS_URL,
        json={"peers": [{"user_id": str(uuid.uuid4())}]},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 200
    assert response.json() == {"peers": []}


def test_a_repeated_id_is_answered_once_for_each_entry(
    http, active_user, device, bearer, peer, peer_device
):
    """Each entry carries its own tag, so each is decided on its own. One stale and
    one current tag for the same peer must therefore answer differently."""
    publish(peer)
    headers = bearer(active_user, device)
    current = one(http, headers, peer)["etag"]

    peers = http.post(
        PEERS_URL,
        json={
            "peers": [
                {"user_id": str(peer.id), "etag": current},
                {"user_id": str(peer.id), "etag": '"not-the-current-tag"'},
            ]
        },
        headers=headers,
    ).json()["peers"]

    assert [item.get("unchanged") for item in peers] == [True, None]


# --- The tag -------------------------------------------------------------------------


def test_a_matching_tag_answers_three_fields_and_no_body(
    http, active_user, device, bearer, peer, peer_device
):
    publish(peer)
    headers = bearer(active_user, device)
    first = one(http, headers, peer)

    again = one(http, headers, peer, etag=first["etag"])

    assert again == {"user_id": str(peer.id), "etag": first["etag"], "unchanged": True}


def test_a_tag_from_another_peer_is_simply_a_full_answer(
    http, active_user, device, bearer, peer, peer_device
):
    """The tag is compared, never trusted: a value that names nothing costs the
    caller a body and never an error."""
    publish(peer)
    headers = bearer(active_user, device)

    item = one(http, headers, peer, etag=one(http, headers, active_user)["etag"])

    assert "unchanged" not in item
    assert item["identity"]["version"] == 1


@pytest.mark.parametrize(
    "change",
    ["identity", "device added", "device revoked", "bundle version", "log appended"],
)
def test_the_tag_moves_for_each_input_it_covers(
    http, active_user, device, bearer, peer, peer_device, change
):
    """ADR-0024 names four inputs. Each one is moved here on its own, because a tag
    that misses any of them leaves a sender encrypting against state it has been
    told is current."""
    publish(peer)
    headers = bearer(active_user, device)
    before = one(http, headers, peer)["etag"]

    if change == "identity":
        publish(peer, version=2, master=b"z")
    elif change == "device added":
        make_device(peer, registration_id=901)
    elif change == "device revoked":
        http.delete(
            f"/api/v1/me/devices/{peer_device.id}", headers=bearer(peer, peer_device)
        )
    elif change == "bundle version":
        peer_device.bundle_version += 1
        peer_device.save(update_fields=["bundle_version"])
    else:
        DeviceLogRecord.objects.create(user=peer, seq=0, blob=b"r" * 256)

    assert one(http, headers, peer)["etag"] != before


@pytest.mark.parametrize(
    "change", ["prekey claimed", "label changed", "own device added"]
)
def test_the_tag_holds_for_a_change_it_does_not_cover(
    http, active_user, device, bearer, peer, peer_device, change
):
    """The other half. A tag that moved on anything the route does not serve would
    make the conditional read worthless: every poll would cost a full answer."""
    publish(peer)
    headers = bearer(active_user, device)
    before = one(http, headers, peer)["etag"]

    if change == "prekey claimed":
        stock_prekeys(peer_device, 2)
        http.post(f"/api/v1/users/{peer.id}/keys/claim", json={}, headers=headers)
    elif change == "label changed":
        http.put(
            f"/api/v1/me/devices/{peer_device.id}",
            json={"label_blob": base64.b64encode(b"L" * 256).decode()},
            headers=bearer(peer, peer_device),
        )
    else:
        make_device(active_user, registration_id=902)

    assert one(http, headers, peer)["etag"] == before


def test_the_route_mints_its_own_tag_and_not_the_device_list_one(
    http, active_user, device, bearer, peer, peer_device
):
    """It has to be its own: the device-list tag covers the live id set and the log
    head, and this one covers the identity and every bundle version as well. A
    client that sent one where the other belongs would sit on a `304` through an
    identity rotation."""
    publish(peer)
    headers = bearer(active_user, device)
    listed = http.get(devices_url(peer.id), headers=headers)

    item = one(http, headers, peer, etag=listed.headers["etag"])

    assert item["etag"] != listed.headers["etag"]
    assert "unchanged" not in item


def test_a_bundle_version_bump_moves_this_tag_where_the_device_list_tag_stands_still(
    http, active_user, device, bearer, peer, peer_device
):
    """The one difference between the two tags, pinned rather than described. The
    device list hashes the live id set, so a re-signed bundle leaves it unchanged;
    this route serves `bundle_version`, so it must not."""
    publish(peer)
    headers = bearer(active_user, device)
    device_tag = http.get(devices_url(peer.id), headers=headers).headers["etag"]
    peer_tag = one(http, headers, peer)["etag"]

    peer_device.bundle_version += 1
    peer_device.cross_sig = b"\xc5" * 64
    peer_device.save(update_fields=["bundle_version", "cross_sig"])

    assert http.get(devices_url(peer.id), headers=headers).headers["etag"] == device_tag
    assert one(http, headers, peer)["etag"] != peer_tag


# --- The body it accepts --------------------------------------------------------------


@pytest.mark.parametrize(
    "body",
    [
        pytest.param({"peers": []}, id="empty list"),
        pytest.param({"peers": [{"user_id": "not-a-uuid"}]}, id="malformed id"),
        pytest.param({"peers": [{}]}, id="item with no id"),
        pytest.param({"peers": [{"user_id": str(uuid.uuid4()), "n": 1}]}, id="extra key"),
        pytest.param({"users": []}, id="wrong field name"),
        pytest.param({}, id="no body field"),
        pytest.param(
            {"peers": [{"user_id": str(uuid.uuid4()), "etag": "e" * 65}]},
            id="tag past the bound",
        ),
    ],
)
def test_a_body_the_contract_does_not_admit_is_a_400(
    http, active_user, device, bearer, body
):
    response = http.post(PEERS_URL, json=body, headers=bearer(active_user, device))

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_the_batch_stops_at_its_published_ceiling(http, active_user, device, bearer):
    headers = bearer(active_user, device)
    ids = [{"user_id": str(uuid.uuid4())} for _ in range(MAX_PEERS + 1)]

    assert (
        http.post(PEERS_URL, json={"peers": ids[:-1]}, headers=headers).status_code == 200
    )
    over = http.post(PEERS_URL, json={"peers": ids}, headers=headers)

    assert over.status_code == 400
    assert over.json()["code"] == "invalid_request"


def test_the_route_writes_nothing(http, active_user, device, bearer, peer, peer_device):
    """The retry paragraph is a contract, and this is what makes it true. A claim
    consumes a prekey; this route reads the same rows and must consume nothing."""
    publish(peer)
    stock_prekeys(peer_device, 3)
    headers = bearer(active_user, device)

    one(http, headers, peer)
    one(http, headers, peer)

    assert peer_device.onetime_prekeys.count() == 3
    assert UserIdentity.objects.get(user=peer).version == 1


# --- The conditional identity read ----------------------------------------------------


def test_the_identity_read_carries_a_tag_in_the_header_and_the_body(
    http, active_user, device, bearer, peer, peer_device
):
    publish(peer)

    response = http.get(identity_url(peer.id), headers=bearer(active_user, device))

    assert response.headers["ETag"] == response.json()["etag"]
    assert response.json()["etag"].startswith('"')


def test_the_identity_read_answers_304_to_its_own_tag(
    http, active_user, device, bearer, peer, peer_device
):
    publish(peer)
    headers = bearer(active_user, device)
    etag = http.get(identity_url(peer.id), headers=headers).headers["ETag"]

    unchanged = http.get(
        identity_url(peer.id), headers={**headers, "If-None-Match": etag}
    )

    assert unchanged.status_code == 304
    assert unchanged.content == b""


@pytest.mark.parametrize("field", ["master", "version"])
def test_the_identity_tag_moves_when_the_bytes_or_the_version_move(
    http, active_user, device, bearer, peer, peer_device, field
):
    publish(peer, version=1, master=b"m")
    headers = bearer(active_user, device)
    before = http.get(identity_url(peer.id), headers=headers).headers["ETag"]

    if field == "master":
        publish(peer, version=1, master=b"z")
    else:
        publish(peer, version=2, master=b"m")

    after = http.get(identity_url(peer.id), headers=headers)
    assert after.headers["ETag"] != before
    assert after.status_code == 200


def test_a_stale_identity_tag_gets_the_new_bytes_rather_than_a_304(
    http, active_user, device, bearer, peer, peer_device
):
    """The substitution alarm depends on this: a peer polling with the tag of a
    master key that has since been replaced must be handed the replacement, never
    told that nothing changed."""
    publish(peer, version=1, master=b"A")
    headers = bearer(active_user, device)
    stale = http.get(identity_url(peer.id), headers=headers).headers["ETag"]
    publish(peer, version=2, master=b"B")

    response = http.get(
        identity_url(peer.id), headers={**headers, "If-None-Match": stale}
    )

    assert response.status_code == 200
    assert response.json()["master_pub"] == base64.b64encode(b"B" * 32).decode()


def test_an_absent_identity_is_still_a_404_whatever_tag_is_offered(
    http, active_user, device, bearer, peer
):
    """There is no tag for a row that does not exist, so a conditional read of an
    unpublished identity cannot answer `304`."""
    response = http.get(
        identity_url(peer.id),
        headers={**bearer(active_user, device), "If-None-Match": '"anything"'},
    )

    assert response.status_code == 404
    assert response.json()["code"] == "not_found"


def test_the_identity_tag_is_not_the_peer_state_tag(
    http, active_user, device, bearer, peer, peer_device
):
    """Two tags in one answer, and they are for different routes. A client that
    sent the identity's tag as the peer tag would be told nothing changed while a
    device was being added."""
    publish(peer)
    headers = bearer(active_user, device)

    item = one(http, headers, peer)

    assert item["identity"]["etag"] != item["etag"]
    assert (
        http.get(identity_url(peer.id), headers=headers).headers["ETag"]
        == item["identity"]["etag"]
    )


def test_a_device_change_moves_the_peer_tag_and_not_the_identity_tag(
    http, active_user, device, bearer, peer, peer_device
):
    publish(peer)
    headers = bearer(active_user, device)
    before = one(http, headers, peer)

    make_device(peer, registration_id=903)

    after = one(http, headers, peer)
    assert after["etag"] != before["etag"]
    assert after["identity"]["etag"] == before["identity"]["etag"]
