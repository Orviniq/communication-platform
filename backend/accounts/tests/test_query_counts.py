"""Query-shape guards for the accounts routes.

Counted end to end through the composed application, so each number includes the
one query the authentication dependency makes: the device row joined to its
owner. `transaction=True` makes the transaction statements real BEGIN/COMMIT
rather than savepoints, and they are excluded here so the number is the database
work itself.

Every count is at or below what the REST Framework view cost. The login that
names a device reads that row and writes nothing, and the renewal that replaces
the refresh route costs the authentication query alone (ADR-0023).
"""

import base64

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext

from accounts.models import ProfileBlob, User
from conftest import PASSWORD
from core.buckets import PROFILE_BUCKETS

pytestmark = pytest.mark.django_db(transaction=True)

TRANSACTION_STATEMENTS = ("BEGIN", "COMMIT", "SAVEPOINT", "RELEASE", "ROLLBACK")

AUTH_QUERY = 1  # the device row, joined to its owner

REGISTER_URL = "/api/v1/auth/register"
LOGIN_URL = "/api/v1/auth/login"
RENEW_URL = "/api/v1/auth/renew"
LOGOUT_URL = "/api/v1/auth/logout"
ERASE_URL = "/api/v1/me"
DIRECTORY_URL = "/api/v1/users"
MY_PROFILE_URL = "/api/v1/me/profile"


def queries(context):
    return [
        query["sql"]
        for query in context.captured_queries
        if not query["sql"].startswith(TRANSACTION_STATEMENTS)
    ]


def counted(http, method, url, expected, **kwargs):
    with CaptureQueriesContext(connection) as context:
        response = http.request(method, url, **kwargs)
    sqls = queries(context)
    assert len(sqls) == expected, "\n".join(sqls)
    return response


def blob_of(nbytes):
    return base64.b64encode(b"\x07" * nbytes).decode()


def test_registration_is_one_insert(http):
    response = counted(
        http,
        "POST",
        REGISTER_URL,
        1,
        json={"username": "zed", "password": "a-sufficiently-long-passphrase"},
    )

    assert response.status_code == 201


def test_login_without_a_device_reads_the_account_once(http, active_user):
    """The one query is the account row. A caller with no device gets a
    register-scope token, which needs no device row at all."""
    response = counted(
        http, "POST", LOGIN_URL, 1, json={"username": "alice", "password": PASSWORD}
    )

    assert response.json()["scope"] == "register"


def test_login_with_a_device_reads_the_account_and_the_device(http, active_user, device):
    """The account row and the device row, and no write: a login mints a token at
    the generation the device already carries."""
    response = counted(
        http,
        "POST",
        LOGIN_URL,
        2,
        json={
            "username": "alice",
            "password": PASSWORD,
            "device_id": str(device.id),
        },
    )

    assert response.json()["scope"] == "full"


def test_a_renewal_is_the_authentication_query_and_nothing_else(
    http, active_user, device, bearer
):
    """Renewal runs once a session lifetime per device, and the requirement has
    already read the device row it needs. A second query here would mean the
    handler re-read a row the dependency handed it."""
    response = counted(
        http, "POST", RENEW_URL, AUTH_QUERY, headers=bearer(active_user, device)
    )

    assert response.status_code == 200


def test_logout_is_the_authentication_and_one_update(http, active_user, device, bearer):
    response = counted(
        http, "POST", LOGOUT_URL, AUTH_QUERY + 1, headers=bearer(active_user, device)
    )

    assert response.status_code == 204


@pytest.mark.parametrize("account_count", [1, 26])
def test_the_directory_is_constant_query(
    http, active_user, device, bearer, account_count
):
    for index in range(account_count - 1):
        User.objects.create_user(
            username=f"user{index:02d}", password=PASSWORD, is_active=True
        )

    response = counted(
        http, "GET", DIRECTORY_URL, AUTH_QUERY + 1, headers=bearer(active_user, device)
    )

    assert len(response.json()["users"]) == account_count


def test_reading_a_profile_is_one_lookup(http, active_user, device, bearer):
    ProfileBlob.objects.create(
        user=active_user, blob=b"\x01" * PROFILE_BUCKETS[0], version=1
    )

    counted(
        http,
        "GET",
        f"/api/v1/users/{active_user.id}/profile",
        AUTH_QUERY + 1,
        headers=bearer(active_user, device),
    )
    counted(
        http,
        "GET",
        MY_PROFILE_URL,
        AUTH_QUERY + 1,
        headers=bearer(active_user, device),
    )


def test_a_profile_write_reads_the_row_once(http, active_user, device, bearer):
    """The locked version check and the write must not each SELECT the row."""
    headers = bearer(active_user, device)
    http.put(
        MY_PROFILE_URL,
        json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": 1},
        headers=headers,
    )

    # the locked read, then the UPDATE
    response = counted(
        http,
        "PUT",
        MY_PROFILE_URL,
        AUTH_QUERY + 2,
        json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": 2},
        headers=headers,
    )

    assert response.status_code == 200


def test_a_taken_name_still_costs_exactly_one_insert(http):
    """The conflict is the unique index, not a probe: an existence check before
    the write would add a query here and still lose the race."""
    http.post(REGISTER_URL, json={"username": "zed", "password": PASSWORD})

    response = counted(
        http, "POST", REGISTER_URL, 1, json={"username": "zed", "password": PASSWORD}
    )

    assert response.status_code == 409
    assert response.json()["code"] == "username_taken"


def test_an_unknown_name_reads_the_account_table_once_and_writes_nothing(http):
    response = counted(
        http, "POST", LOGIN_URL, 1, json={"username": "ghost", "password": PASSWORD}
    )

    assert response.status_code == 401
    assert User.objects.count() == 0


def test_a_locked_name_reaches_the_database_not_at_all(http, active_user):
    """The cool-off is read from Redis before the account row is: a name under
    lock buys neither a query nor an Argon2 verification."""
    from core.lockout import FAILURE_THRESHOLD

    for _ in range(FAILURE_THRESHOLD):
        assert (
            http.post(
                LOGIN_URL, json={"username": "alice", "password": "the-wrong-one"}
            ).status_code
            == 401
        )

    response = counted(
        http, "POST", LOGIN_URL, 0, json={"username": "alice", "password": PASSWORD}
    )

    assert response.status_code == 429


def test_a_missing_profile_is_still_one_lookup(http, active_user, device, bearer):
    """The 404 must not cost a second query looking for the user behind it."""
    headers = bearer(active_user, device)

    mine = counted(http, "GET", MY_PROFILE_URL, AUTH_QUERY + 1, headers=headers)
    theirs = counted(
        http,
        "GET",
        f"/api/v1/users/{active_user.id}/profile",
        AUTH_QUERY + 1,
        headers=headers,
    )

    assert mine.status_code == theirs.status_code == 404


def test_a_first_profile_write_is_the_locked_read_and_one_insert(
    http, active_user, device, bearer
):
    """The create branch: `select_for_update` finds nothing, and the INSERT that
    follows must not be preceded by a second read of the same row."""
    response = counted(
        http,
        "PUT",
        MY_PROFILE_URL,
        AUTH_QUERY + 2,
        json={"blob": blob_of(PROFILE_BUCKETS[0]), "version": 1},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 200
    assert ProfileBlob.objects.count() == 1


# What `DELETE /api/v1/me` costs, statement by statement, at any device count:
# the credential read of the authentication dependency; the account's own name and
# hash in one `values_list`, because both are deferred on the instance the
# dependency hands over; the live device ids for the socket close; and then the
# fourteen statements Django's collector issues for the cascade — one probe for the
# devices it must walk, one probe for the account row, and twelve deletes. Every one
# of the deletes is a fast delete: no row of any of those tables is read into this
# process, so no ciphertext crosses the boundary.
#
# It was fifteen until `attachments.0002_drop_the_uploader_link`. The fifteenth was
# an `UPDATE` nulling `Attachment.uploader` on the rows this account had uploaded,
# and there is no column left for the collector to null.
ERASE_QUERIES = 14


@pytest.mark.parametrize("extra_devices", [0, 2])
def test_the_erasure_cascade_does_not_grow_with_the_device_count(
    http, active_user, device, bearer, extra_devices
):
    """The collector issues one delete for each table, not one for each device. A
    per-device cascade would be an unbounded statement count on the one route that
    is allowed to be slow and must still finish inside its deadline."""
    from devices.models import Device
    from messaging.models import QueuedEnvelope

    for index in range(extra_devices):
        extra = Device.objects.create(
            user=active_user,
            ik_pub=b"ik",
            spk_id=index + 2,
            spk_pub=b"spk",
            spk_sig=b"sig",
            registration_id=5000 + index,
        )
        QueuedEnvelope.objects.create(recipient_device=extra, seq=1, blob=b"\x00" * 1024)

    response = counted(
        http,
        "DELETE",
        ERASE_URL,
        AUTH_QUERY + 2 + ERASE_QUERIES,
        json={"password": PASSWORD},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 204


def test_a_wrong_password_costs_the_credential_read_and_nothing_else(
    http, active_user, device, bearer
):
    """The refusal happens before the collector is ever asked for anything: the
    authentication query, and the one read of the name and the hash."""
    response = counted(
        http,
        "DELETE",
        ERASE_URL,
        AUTH_QUERY + 1,
        json={"password": "not-the-password"},
        headers=bearer(active_user, device),
    )

    assert response.status_code == 401
