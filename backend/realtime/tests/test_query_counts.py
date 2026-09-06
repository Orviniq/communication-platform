"""Pins the query count of every DB touch the gateway can make.

Each unit of work is measured as the synchronous function it is, not through the
`async` wrapper beside it: the async boundary is exercised by the live socket
tests, and `run_unit`'s `close_old_connections` bracket would sever this test's
own transaction under CONN_MAX_AGE=0 — Django closes a connection whose
autocommit flag disagrees with its settings, which inside pytest-django's atomic
block is every connection, and the reopen then fails with "Cannot open a new
connection in an atomic block".

The relay route is the exception, and it is measured through the composed
application, because it has no unit of work to measure: its own database cost is
zero and the claim is about the whole call."""

import uuid

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext

from api.auth import issue_register_scope, issue_session
from core.buckets import ENVELOPE_BUCKETS
from messaging.models import QueuedEnvelope
from realtime.auth import _authenticate_session, _delete_envelopes

pytestmark = pytest.mark.django_db

TXN_BOOKKEEPING = ("BEGIN", "COMMIT", "SAVEPOINT", "RELEASE SAVEPOINT")

RELAY_URL = "/api/v1/me/relay"
# The device row joined to its owner, which every authenticated route pays.
AUTH_QUERY = 1
# An obvious test value. No process outside this suite reads it, and nothing this
# test asserts depends on what it is.
TEST_TURN_SECRET = "turn-secret-for-tests-only-not-a-deployment-value"


def _count(unit, *args):
    with CaptureQueriesContext(connection) as ctx:
        unit(*args)
    return [q["sql"] for q in ctx.captured_queries]


def test_authenticate_session_is_one_joined_query(active_user, device):
    """Device and user in one SELECT via select_related: the socket's auth is one
    query cheaper than REST's two-step lookup."""
    access, _ = issue_session(active_user, device)

    queries = _count(_authenticate_session, access)

    assert len(queries) == 1
    assert "JOIN" in queries[0]


def test_ack_delete_is_one_statement(active_user, device):
    """One DELETE regardless of ack size (fast-delete path; the BEGIN/COMMIT pair is
    Django's own atomic wrapper, not extra round-trip work)."""
    rows = QueuedEnvelope.objects.bulk_create(
        [
            QueuedEnvelope(
                recipient_device=device, seq=i + 1, blob=b"e" * min(ENVELOPE_BUCKETS)
            )
            for i in range(200)
        ]
    )

    queries = _count(_delete_envelopes, device.id, [r.id for r in rows])

    deletes = [q for q in queries if q.startswith("DELETE")]
    assert len(deletes) == 1
    assert all(
        q.startswith(TXN_BOOKKEEPING) for q in queries if not q.startswith("DELETE")
    )
    assert QueuedEnvelope.objects.filter(recipient_device=device).count() == 0


def test_a_bind_costs_the_token_check_and_nothing_else(active_user, device):
    """The whole database cost of bringing a socket up: one joined read to verify
    the token, and no second statement since ADR-0024 removed the activity stamp.
    Nothing here may grow with the mailbox or the account's device count, because it
    runs on every reconnect of every client."""
    access, _ = issue_session(active_user, device)

    queries = _count(_authenticate_session, access)

    assert len(queries) == 1


def test_a_token_that_fails_verification_costs_no_query_at_all(db):
    """Signature and expiry are settled in memory, before anything is looked up. A
    flood of garbage tokens against `/ws` is otherwise a flood of device lookups on
    the one thread every socket of the worker shares."""
    assert _count(_authenticate_session, "not-a-jwt") == []


def test_a_register_scope_token_never_reaches_the_device_row(active_user):
    """Scope is checked before the lookup, so the endpoint a register token does
    not open costs it nothing to be refused from — and the refusal cannot be timed
    against a device row that may or may not exist."""
    token, _expires_in = issue_register_scope(active_user)

    assert _count(_authenticate_session, token) == []


def test_an_ack_naming_rows_that_are_not_there_is_still_one_statement(device):
    """Ids outside this device's mailbox match nothing, which is the documented
    answer for a duplicate ack and for an id from another device. It must not
    become a lookup for each id."""
    queries = _count(_delete_envelopes, device.id, [uuid.uuid4() for _ in range(50)])

    deletes = [q for q in queries if q.startswith("DELETE")]
    assert len(deletes) == 1
    assert all(
        q.startswith(TXN_BOOKKEEPING) for q in queries if not q.startswith("DELETE")
    )


@pytest.mark.django_db(transaction=True)
def test_the_relay_route_costs_the_authentication_query_and_nothing_more(
    http, active_user, device, bearer, settings
):
    """A relay credential is computed from a shared secret, never stored, so the
    route reads no row and writes none. A query appearing here would mean somebody
    gave the relay a table — an issued-credential row, a per-device counter — and
    with it a record of who placed a call and when, which is the one thing the voice
    design exists to avoid holding.

    This is the one measurement in the file taken end to end rather than against a
    synchronous unit, because the route has no unit to take: its whole database cost
    belongs to the authentication dependency, and only the composed application
    shows that the handler adds nothing to it. `transaction=True` for the same
    reason `devices/tests/test_query_counts.py` needs it — `api/orm.py` closes the
    connection around every unit of work, which under a wrapping test transaction
    would sever the connection the test itself holds — and the transaction
    statements are excluded so the number is the database work itself.
    """
    settings.TURN_URLS = ["turn:relay.invalid:3478?transport=udp"]
    settings.TURN_STATIC_AUTH_SECRET = TEST_TURN_SECRET

    with CaptureQueriesContext(connection) as ctx:
        response = http.post(RELAY_URL, headers=bearer(active_user, device))

    sqls = [
        q["sql"] for q in ctx.captured_queries if not q["sql"].startswith(TXN_BOOKKEEPING)
    ]
    assert response.status_code == 200
    assert len(sqls) == AUTH_QUERY, "\n".join(sqls)
