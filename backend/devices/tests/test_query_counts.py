"""Query-shape guards for the device routes.

These lock in the shape: the list routes must stay constant-query however many
devices an account has, and a claim must stay one bounded set of queries per
target device, never one per stored prekey.

Counted end to end through the composed application, so each number includes the
one query the authentication dependency makes: the device row joined to its
owner. `transaction=True` makes the transaction statements real BEGIN/COMMIT
rather than savepoints, and they are excluded here so the number is the database
work itself.
"""

import uuid

import pytest
from django.conf import settings
from django.db import connection
from django.test.utils import CaptureQueriesContext

from accounts.models import User
from devices.models import DeviceLogRecord

from .conftest import (
    DEVICES_URL,
    PASSWORD,
    label_blob,
    make_device,
    pubkey,
    publish_identity,
    register_payload,
    stock_prekeys,
)
from .test_cross_signing import identity_payload

pytestmark = pytest.mark.django_db(transaction=True)

TRANSACTION_STATEMENTS = ("BEGIN", "COMMIT", "SAVEPOINT", "RELEASE", "ROLLBACK")

AUTH_QUERY = 1  # the device row, joined to its owner
# Live device ids + the device-log head (an ETag input since the log landed).
# Constant: neither scales with the device count or the log length.
ETAG_QUERIES = 2
LIST_QUERY = 1
# The target set, then one locked select per device, then one delete for every
# key the call consumed — hoisted out of the loop, so it is one query whatever
# the target count.
CLAIM_TARGETS_QUERY = 1
CLAIM_DELETE_QUERY = 1


def counted(http, method, url, expected, **kwargs):
    with CaptureQueriesContext(connection) as context:
        response = http.request(method, url, **kwargs)
    sqls = [
        query["sql"]
        for query in context.captured_queries
        if not query["sql"].startswith(TRANSACTION_STATEMENTS)
    ]
    assert len(sqls) == expected, "\n".join(sqls)
    return response


def peer_url(user_id):
    return f"/api/v1/users/{user_id}/devices"


def claim_url(user_id):
    return f"/api/v1/users/{user_id}/keys/claim"


PEERS_URL = "/api/v1/peers"
# The accounts that exist and are active, their live devices, their identities and
# their log heads. Four statements, none of which scales with the number of peers
# named: the ids go in as one `IN` list and the log heads come back through one
# `DISTINCT ON`.
PEER_STATE_QUERIES = 4


@pytest.mark.parametrize("device_count", [1, 5, 10])
def test_the_own_device_list_is_constant_query(
    http, active_user, device, bearer, device_count
):
    for i in range(device_count - 1):
        make_device(active_user, registration_id=400 + i)

    response = counted(
        http,
        "GET",
        DEVICES_URL,
        AUTH_QUERY + ETAG_QUERIES + LIST_QUERY,
        headers=bearer(active_user, device),
    )

    assert len(response.json()["devices"]) == device_count


@pytest.mark.parametrize("device_count", [1, 5, 10])
def test_the_peer_device_list_is_constant_query(
    http, active_user, device, bearer, peer, peer_device, device_count
):
    for i in range(device_count - 1):
        make_device(peer, registration_id=500 + i)

    response = counted(
        http,
        "GET",
        peer_url(peer.id),
        AUTH_QUERY + ETAG_QUERIES + LIST_QUERY,
        headers=bearer(active_user, device),
    )

    assert len(response.json()["devices"]) == device_count


def test_a_304_skips_the_list_query_entirely(http, active_user, device, bearer):
    headers = bearer(active_user, device)
    etag = http.get(DEVICES_URL, headers=headers).headers["etag"]

    response = counted(
        http,
        "GET",
        DEVICES_URL,
        AUTH_QUERY + ETAG_QUERIES,
        headers={**headers, "If-None-Match": etag},
    )

    assert response.status_code == 304


@pytest.mark.parametrize("pool_size", [1, 20, 200])
def test_a_claim_does_not_scale_with_the_prekey_pool(
    http, active_user, device, bearer, peer, peer_device, pool_size
):
    """The N+1 that would matter most: claiming must cost the same whether the
    device stores one prekey or two hundred."""
    stock_prekeys(peer_device, pool_size)

    response = counted(
        http,
        "POST",
        claim_url(peer.id),
        AUTH_QUERY + CLAIM_TARGETS_QUERY + 1 + CLAIM_DELETE_QUERY,
        json={},
        headers=bearer(active_user, device),
    )

    assert "otpk" in response.json()["bundles"][0]


@pytest.mark.parametrize("device_count", [1, 3, 6])
def test_a_claim_costs_one_locked_select_per_target_and_one_delete_for_the_batch(
    http, active_user, device, bearer, peer, peer_device, device_count
):
    """The response is a bundle per device, so the per-device locked select is
    inherent; what must not happen is a query per prekey, a second lookup per
    device, or a delete per key."""
    for i in range(device_count - 1):
        stock_prekeys(make_device(peer, registration_id=600 + i), 2)
    stock_prekeys(peer_device, 2)

    response = counted(
        http,
        "POST",
        claim_url(peer.id),
        AUTH_QUERY + CLAIM_TARGETS_QUERY + device_count + CLAIM_DELETE_QUERY,
        json={},
        headers=bearer(active_user, device),
    )

    assert len(response.json()["bundles"]) == device_count


def test_an_exhausted_pool_costs_one_query_less(
    http, active_user, device, bearer, peer, peer_device
):
    """No prekey to delete, so the delete never runs."""
    response = counted(
        http,
        "POST",
        claim_url(peer.id),
        AUTH_QUERY + CLAIM_TARGETS_QUERY + 1,
        json={},
        headers=bearer(active_user, device),
    )

    assert "otpk" not in response.json()["bundles"][0]


@pytest.mark.parametrize("log_length", [0, 5, 60])
def test_the_device_list_stays_constant_query_as_the_log_grows(
    http, active_user, device, bearer, log_length
):
    """The ETag reads only the head record, so a longer log must not add queries
    (or the ETag becomes a per-poll scan of the whole log)."""
    DeviceLogRecord.objects.bulk_create(
        [
            DeviceLogRecord(user=active_user, seq=i, blob=b"r" * 256)
            for i in range(log_length)
        ]
    )

    response = counted(
        http,
        "GET",
        DEVICES_URL,
        AUTH_QUERY + ETAG_QUERIES + LIST_QUERY,
        headers=bearer(active_user, device),
    )

    expected_head = log_length - 1 if log_length else None
    assert response.json()["log_head_seq"] == expected_head


def test_cross_signing_fields_ride_the_existing_queries(
    http, active_user, device, bearer, peer, peer_device
):
    """cross_sig and bundle_version are columns on the rows the list and claim
    already fetch, so surfacing them must not add a query."""
    peer_device.cross_sig = b"\xc5" * 64
    peer_device.bundle_version = 4
    peer_device.save(update_fields=["cross_sig", "bundle_version"])
    stock_prekeys(peer_device, 1)
    headers = bearer(active_user, device)

    listed = counted(
        http,
        "GET",
        peer_url(peer.id),
        AUTH_QUERY + ETAG_QUERIES + LIST_QUERY,
        headers=headers,
    )
    claimed = counted(
        http,
        "POST",
        claim_url(peer.id),
        AUTH_QUERY + CLAIM_TARGETS_QUERY + 1 + CLAIM_DELETE_QUERY,
        json={},
        headers=headers,
    )

    assert listed.json()["devices"][0]["cross_sig"] is not None
    assert claimed.json()["bundles"][0]["bundle_version"] == 4


@pytest.mark.parametrize("pool_size", [0, 50, 199])
def test_replenishment_is_constant_query(http, active_user, device, bearer, pool_size):
    """The cap check must not walk the stored pool."""
    stock_prekeys(device, pool_size, start=1000)

    # device lock, cap count, bulk insert, recount
    response = counted(
        http,
        "PUT",
        f"{DEVICES_URL}/{device.id}/prekeys",
        AUTH_QUERY + 4,
        json={"otpks": [{"key_id": 1, "pub": pubkey()}]},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 200


def test_registration_is_constant_query_whatever_the_payload(
    http, active_user, device, bearer
):
    """200 prekeys go in as one bulk insert, not 200."""
    publish_identity(active_user)

    # user lock, cap count, identity-exists check, device insert, otpk bulk. The
    # issued pair writes nothing: no token table exists.
    response = counted(
        http,
        "POST",
        DEVICES_URL,
        AUTH_QUERY + 5,
        json=register_payload(otpks=200),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 201


def test_the_device_log_page_is_two_queries_however_long_the_log(
    http, active_user, device, bearer, peer, peer_device
):
    """The page and its head, and nothing per record."""
    DeviceLogRecord.objects.bulk_create(
        [DeviceLogRecord(user=peer, seq=i, blob=b"r" * 256) for i in range(120)]
    )

    response = counted(
        http,
        "GET",
        f"/api/v1/users/{peer.id}/devicelog?limit=100",
        AUTH_QUERY + 2,
        headers=bearer(active_user, device),
    )

    assert len(response.json()["records"]) == 100


def test_a_log_append_is_constant_query_whatever_the_batch(
    http, active_user, device, bearer
):
    """50 records go in as one bulk insert, not 50."""
    from .test_device_log import log_blob

    # user lock, head probe, bulk insert
    response = counted(
        http,
        "POST",
        "/api/v1/me/devicelog",
        AUTH_QUERY + 3,
        json={"records": [{"blob": log_blob()} for _ in range(50)]},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 201


def test_the_prekey_count_is_one_query_per_pool(http, active_user, device, bearer):
    stock_prekeys(device, 30)

    response = counted(
        http,
        "GET",
        f"{DEVICES_URL}/{device.id}/prekeys/count",
        AUTH_QUERY + 2,
        headers=bearer(active_user, device),
    )

    assert response.json()["otpk_count"] == 30


def test_revocation_is_constant_query(http, active_user, device, bearer):
    """The cascade is four statements over the device, whatever it holds."""
    doomed = make_device(active_user, registration_id=8080)
    stock_prekeys(doomed, 20)

    # locked select, the row update, the two prekey deletes, the mailbox delete
    response = counted(
        http,
        "DELETE",
        f"{DEVICES_URL}/{doomed.id}",
        AUTH_QUERY + 5,
        headers=bearer(active_user, device),
    )

    assert response.status_code == 204


def test_the_peer_identity_is_one_query(
    http, active_user, device, bearer, peer, peer_device
):
    from devices.models import UserIdentity

    UserIdentity.objects.create(
        user=peer,
        master_pub=b"m" * 32,
        self_signing_pub=b"s" * 32,
        user_signing_pub=b"u" * 32,
        master_sig=b"g" * 64,
        version=1,
    )

    response = counted(
        http,
        "GET",
        f"/api/v1/users/{peer.id}/identity",
        AUTH_QUERY + 1,
        headers=bearer(active_user, device),
    )

    assert response.json()["version"] == 1


def test_relabelling_a_device_is_one_update(http, active_user, device, bearer):
    """The ownership predicate rides in the UPDATE's WHERE clause, so a device of
    another account is never loaded and the route never costs a read first."""
    response = counted(
        http,
        "PUT",
        f"{DEVICES_URL}/{device.id}",
        AUTH_QUERY + 1,
        json={"label_blob": label_blob()},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 200


def test_publishing_an_identity_is_constant_query(http, active_user, device, bearer):
    """The owner lock, the version probe, and the upsert — the same three whether
    the identity exists yet or not, because the probe reads the version without
    dragging the key material back with it."""
    headers = bearer(active_user, device)

    # first publish: owner lock, version probe, the upsert's own SELECT and INSERT
    counted(
        http,
        "PUT",
        "/api/v1/me/identity",
        AUTH_QUERY + 4,
        json=identity_payload(version=1),
        headers=headers,
    )
    # second: the same shape, with an UPDATE where the INSERT was
    response = counted(
        http,
        "PUT",
        "/api/v1/me/identity",
        AUTH_QUERY + 4,
        json=identity_payload(version=2),
        headers=headers,
    )

    assert response.status_code == 200


def test_a_peer_list_304_skips_the_list_query_entirely(
    http, active_user, device, bearer, peer, peer_device
):
    """The cheap poll, on the route peers actually poll: the tag is computed from
    two constant queries and the list is never touched."""
    headers = bearer(active_user, device)
    etag = http.get(peer_url(peer.id), headers=headers).headers["etag"]

    response = counted(
        http,
        "GET",
        peer_url(peer.id),
        AUTH_QUERY + ETAG_QUERIES,
        headers={**headers, "If-None-Match": etag},
    )

    assert response.status_code == 304


def test_a_claim_that_selects_no_device_costs_nothing_beyond_the_lookup(
    http, active_user, device, bearer, peer, peer_device
):
    """An explicit empty `device_ids` asks for no devices, so there is no locked
    select and no delete: the cost of asking for nothing must not be the cost of
    asking for everything."""
    stock_prekeys(peer_device, 5)

    response = counted(
        http,
        "POST",
        claim_url(peer.id),
        AUTH_QUERY,
        json={"device_ids": []},
        headers=bearer(active_user, device),
    )

    assert response.json()["bundles"] == []


@pytest.mark.parametrize("query", ["", "?after=10&limit=5", "?after=abc&limit=zzz"])
def test_the_device_log_page_costs_two_queries_whatever_the_cursor(
    http, active_user, device, bearer, peer, query
):
    """The page and its head, and nothing per record — including on the junk cursor
    that falls back to the start of the log and therefore reads the most rows."""
    DeviceLogRecord.objects.bulk_create(
        [DeviceLogRecord(user=peer, seq=i, blob=b"r" * 256) for i in range(40)]
    )

    response = counted(
        http,
        "GET",
        f"/api/v1/users/{peer.id}/devicelog{query}",
        AUTH_QUERY + 2,
        headers=bearer(active_user, device),
    )

    assert response.status_code == 200


def test_an_unpublished_identity_costs_one_query(http, active_user, device, bearer, peer):
    """The 404 path must not cost more than the hit: an existence probe followed by
    a fetch would double the cost of the most common answer for a new account."""
    response = counted(
        http,
        "GET",
        f"/api/v1/users/{peer.id}/identity",
        AUTH_QUERY + 1,
        headers=bearer(active_user, device),
    )

    assert response.status_code == 404


def test_pq_material_at_registration_adds_exactly_one_insert(
    http, active_user, device, bearer
):
    """The PQ pool is a second bulk insert, not a second insert per key."""
    from .test_pq_prekeys import pq_otpks, pq_spk

    publish_identity(active_user)

    # user lock, cap count, identity check, device insert, otpk bulk, pq otpk bulk
    response = counted(
        http,
        "POST",
        DEVICES_URL,
        AUTH_QUERY + 6,
        json=register_payload(otpks=50, pq_spk=pq_spk(), pq_otpks=pq_otpks(50)),
        headers=bearer(active_user, device),
    )

    assert response.status_code == 201


@pytest.mark.parametrize("peer_count", [1, 5, 32, 64])
def test_the_peer_state_route_is_constant_query_in_the_number_of_peers(
    http, active_user, device, bearer, peer_count
):
    """The whole reason the route exists. The per-user reads it replaces cost three
    round trips for each recipient — 150 for a 50-member group — and this must cost
    the same four statements at one peer and at sixty-four.
    """
    peers = [
        User.objects.create_user(username=f"peer{i}", password=PASSWORD, is_active=True)
        for i in range(peer_count)
    ]
    for i, target in enumerate(peers):
        make_device(target, registration_id=2000 + i)
        publish_identity(target)
        DeviceLogRecord.objects.create(user=target, seq=0, blob=b"r" * 256)

    response = counted(
        http,
        "POST",
        PEERS_URL,
        AUTH_QUERY + PEER_STATE_QUERIES,
        json={"peers": [{"user_id": str(target.id)} for target in peers]},
        headers=bearer(active_user, device),
    )

    assert len(response.json()["peers"]) == peer_count


@pytest.mark.parametrize("device_count", [1, 5, 10])
def test_the_peer_state_route_is_constant_query_in_the_devices_of_one_peer(
    http, active_user, device, bearer, peer, peer_device, device_count
):
    """The other axis. One peer with ten devices must cost what one peer with one
    device costs, or a client sending to a well-equipped account pays for it."""
    for i in range(device_count - 1):
        make_device(peer, registration_id=2100 + i)

    response = counted(
        http,
        "POST",
        PEERS_URL,
        AUTH_QUERY + PEER_STATE_QUERIES,
        json={"peers": [{"user_id": str(peer.id)}]},
        headers=bearer(active_user, device),
    )

    assert len(response.json()["peers"][0]["devices"]) == device_count


@pytest.mark.parametrize("log_length", [0, 5, 60])
def test_the_peer_state_route_reads_only_the_head_of_the_log(
    http, active_user, device, bearer, peer, peer_device, log_length
):
    """`DISTINCT ON` takes one record per user, so a longer log must not add a
    query — or the tag becomes a scan of the whole log on every poll."""
    DeviceLogRecord.objects.bulk_create(
        [DeviceLogRecord(user=peer, seq=i, blob=b"r" * 256) for i in range(log_length)]
    )

    response = counted(
        http,
        "POST",
        PEERS_URL,
        AUTH_QUERY + PEER_STATE_QUERIES,
        json={"peers": [{"user_id": str(peer.id)}]},
        headers=bearer(active_user, device),
    )

    expected_head = log_length - 1 if log_length else None
    assert response.json()["peers"][0]["log_head_seq"] == expected_head


def test_a_peer_state_call_that_names_only_unknown_users_stops_at_the_lookup(
    http, active_user, device, bearer
):
    """Django resolves an `__in` against an empty set without going to the
    database, so a call naming nobody who exists costs the one account query and
    stops there."""
    response = counted(
        http,
        "POST",
        PEERS_URL,
        AUTH_QUERY + 1,
        json={"peers": [{"user_id": str(uuid.uuid4())} for _ in range(8)]},
        headers=bearer(active_user, device),
    )

    assert response.json() == {"peers": []}


def test_an_unchanged_peer_costs_the_same_queries_and_less_body(
    http, active_user, device, bearer, peer, peer_device
):
    """The tag is computed from what the route serves, so an `unchanged` answer
    reads exactly what a full one reads. What it saves is the body — which is the
    identity and every device of every recipient, on every send."""
    publish_identity(peer)
    headers = bearer(active_user, device)
    body = {"peers": [{"user_id": str(peer.id)}]}
    full = http.post(PEERS_URL, json=body, headers=headers)
    etag = full.json()["peers"][0]["etag"]

    unchanged = counted(
        http,
        "POST",
        PEERS_URL,
        AUTH_QUERY + PEER_STATE_QUERIES,
        json={"peers": [{"user_id": str(peer.id), "etag": etag}]},
        headers=headers,
    )

    assert unchanged.json()["peers"][0]["unchanged"] is True
    assert len(unchanged.content) < len(full.content)


def test_the_conditional_identity_read_costs_the_one_query_a_200_costs(
    http, active_user, device, bearer, peer, peer_device
):
    """The tag is derived from the row, not stored beside it, so there is nothing
    cheaper to read first. The saving is the body, and this records that the query
    count is not part of it."""
    publish_identity(peer)
    headers = bearer(active_user, device)
    url = f"/api/v1/users/{peer.id}/identity"
    etag = http.get(url, headers=headers).headers["ETag"]

    response = counted(
        http,
        "GET",
        url,
        AUTH_QUERY + 1,
        headers={**headers, "If-None-Match": etag},
    )

    assert response.status_code == 304


def test_the_limits_route_reads_no_row_at_all(http, active_user, device, bearer):
    """Every value it serves is a setting or a module constant, so the only query
    it may cost is the one the authentication dependency makes."""
    response = counted(
        http, "GET", "/api/v1/config", AUTH_QUERY, headers=bearer(active_user, device)
    )

    assert response.json()["envelope_ttl_days"] == settings.ENVELOPE_TTL_DAYS
