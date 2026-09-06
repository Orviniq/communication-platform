"""What a socket's bind waits for while a send holds its device row.

The seam decision behind this file is ADR-0005: a WebSocket scope enters no
`ThreadSensitiveContext`, so every socket's ORM unit runs on the one
process-wide thread-sensitive executor thread. That makes any wait inside a
gateway unit a wait for every socket in the worker, not for one of them.

`send` locks each live target device with `SELECT ... FOR UPDATE` and holds it to
commit (ADR-0017), and the device a send is delivering to is the device most
likely to be reconnecting. ADR-0024 removed the activity stamp the bind used to
write, so the bind is now a plain read of that row and takes no lock at all. This
file measures that rather than assuming it: a bind that grew a write back would
queue behind the send exactly as the stamp did.
"""

import threading
import time

import pytest
from django.db import connections, transaction
from django.test.utils import CaptureQueriesContext

from api.auth import issue_session
from devices.models import Device
from realtime.auth import _authenticate_session

pytestmark = pytest.mark.django_db(transaction=True)

# Long enough to measure against a wait of microseconds, short enough that a
# regression costs one second rather than a hung suite.
HOLD_SECONDS = 1.0
# The wait that says the bind queued behind the lock rather than passing it.
BLOCKED_SECONDS = HOLD_SECONDS / 2

WRITE_STATEMENTS = ("INSERT", "UPDATE", "DELETE")


class Sender:
    """A thread holding the lock `send` holds, in the statement `send` uses."""

    def __init__(self, device_id):
        self.device_id = device_id
        self.holding = threading.Event()
        self.release = threading.Event()
        self._thread = threading.Thread(target=self._hold)

    def _hold(self):
        try:
            with transaction.atomic():
                list(
                    Device.objects.select_for_update()
                    .filter(id=self.device_id)
                    .order_by("id")
                )
                self.holding.set()
                self.release.wait(HOLD_SECONDS * 2)
        finally:
            connections.close_all()

    def __enter__(self):
        self._thread.start()
        assert self.holding.wait(HOLD_SECONDS * 2), "the sender never took the lock"
        return self

    def __exit__(self, *_exc):
        self.release.set()
        self._thread.join(HOLD_SECONDS * 2)


def elapsed(call):
    began = time.perf_counter()
    call()
    return time.perf_counter() - began


def test_a_bind_on_a_device_a_send_is_locking_does_not_queue_behind_it(
    active_user, device
):
    """A `SELECT` without `FOR UPDATE` reads the row a `FOR UPDATE` holds, because
    PostgreSQL's readers do not block on writers. Before ADR-0024 the bind followed
    that read with an `UPDATE` of the same row and waited out the send — on the one
    thread every socket of the worker shares."""
    token, _expires_in = issue_session(active_user, device)

    with Sender(device.id):
        waited = elapsed(lambda: _authenticate_session(token))

    assert waited < BLOCKED_SECONDS, f"the bind queued behind the send for {waited:.3f}s"


def test_a_bind_writes_no_row(active_user, device):
    """The structural half of the test above. The bind is one read and nothing
    else: a write of any kind would be a row lock, and a row lock on the device is
    the wait the file exists to keep out."""
    token, _expires_in = issue_session(active_user, device)

    with CaptureQueriesContext(connections["default"]) as context:
        assert _authenticate_session(token) is not None

    written = [
        query["sql"]
        for query in context.captured_queries
        if query["sql"].upper().lstrip().startswith(WRITE_STATEMENTS)
    ]
    assert written == []
