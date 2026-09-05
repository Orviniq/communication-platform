"""Key-backup writes race under the owner-row lock.

`TransactionTestCase` because the guarantee rests on a real committed row lock
racing other transactions, which a wrapping test transaction would hide. (The
same-owner append race that used to live here moved with the append pattern to
devices/tests/test_device_log.py when server-side history was removed.)
"""

import base64
import threading

from django.db import connection, connections, transaction
from django.test import TransactionTestCase

from accounts.models import User
from api.auth import issue_session
from config.asgi import api_application, application
from conftest import AsgiClient, flush_redis
from vault.models import KeyBackup

from .conftest import KEYBACKUP_URL, PASSWORD, backup_blob, make_device

RACE_ROUNDS = 20


class KeyBackupVersionRaceTests(TransactionTestCase):
    """A concurrent first key-backup upload must not let a lower version win.

    The owner-row lock makes this deterministic: whichever write commits first sets
    the version, and the other either sees it and 409s (lower) or applies over it
    (higher), so the stored version is always the maximum. Without the lock both
    writes read version=None and the lower one can clobber the higher."""

    def setUp(self):
        self.owner = User.objects.create_user(
            username="alice", password=PASSWORD, is_active=True
        )
        access_low, _ = issue_session(self.owner, make_device(self.owner, 1))
        access_high, _ = issue_session(self.owner, make_device(self.owner, 2))
        self.low = {"Authorization": f"Bearer {access_low}"}
        self.high = {"Authorization": f"Bearer {access_high}"}
        self.status_lock = threading.Lock()
        flush_redis()  # a shared limiter store would otherwise bleed across rounds

    def test_concurrent_first_write_never_lets_the_lower_version_win(self):
        high_blob = backup_blob(b"H")
        expected_high = base64.b64decode(high_blob)
        for _ in range(RACE_ROUNDS):
            KeyBackup.objects.filter(
                user_id=self.owner.id
            ).delete()  # force a first write
            barrier = threading.Barrier(2)

            def put(headers, version, blob):
                # One client per thread: each call runs on its own event loop, and
                # the ORM work lands on the thread that made the call.
                client = AsgiClient(application, api_application)
                try:
                    # Open this thread's connection before the barrier. Connection
                    # setup costs more than the transaction the race is about, and
                    # CONN_MAX_AGE is 0, so threads released together would otherwise
                    # reach the owner row one at a time on a slow runner.
                    connection.ensure_connection()
                    barrier.wait(timeout=10)
                    client.put(
                        "/api/v1/me/keybackup",
                        json={"blob": blob, "version": version},
                        headers=headers,
                    )
                finally:
                    connections.close_all()

            threads = [
                threading.Thread(target=put, args=(self.low, 1, backup_blob(b"L"))),
                threading.Thread(target=put, args=(self.high, 5, high_blob)),
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=30)

            key_backup = KeyBackup.objects.get(user_id=self.owner.id)
            self.assertEqual(key_backup.version, 5)
            self.assertEqual(bytes(key_backup.blob), expected_high)

    def racing_put(self, headers, version, blob, barrier, statuses, label):
        """A thread that fires one PUT the moment every racer has a connection."""
        lock = self.status_lock

        def run():
            # One client per thread: each call runs on its own event loop, and the
            # ORM work lands on the thread that made the call.
            client = AsgiClient(application, api_application)
            try:
                connection.ensure_connection()
                barrier.wait(timeout=10)
                response = client.put(
                    KEYBACKUP_URL,
                    json={"blob": blob, "version": version},
                    headers=headers,
                )
                with lock:
                    statuses[label] = response.status_code
            finally:
                connections.close_all()

        return threading.Thread(target=run)

    def test_concurrent_first_writes_settle_on_one_row_and_answer_both_clients(self):
        """The end state both racers can observe: one row, the higher version in
        it, and two answers that agree about what happened. The higher write is
        always applied — it either wins the row outright or lands on top of the
        lower one — so its `200` is not a coin toss."""
        statuses = {}
        barrier = threading.Barrier(2)
        threads = [
            self.racing_put(self.low, 1, backup_blob(b"L"), barrier, statuses, "low"),
            self.racing_put(self.high, 5, backup_blob(b"H"), barrier, statuses, "high"),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)

        self.assertEqual(KeyBackup.objects.filter(user_id=self.owner.id).count(), 1)
        stored = KeyBackup.objects.get(user_id=self.owner.id)
        self.assertEqual(stored.version, 5)
        self.assertEqual(bytes(stored.blob), base64.b64decode(backup_blob(b"H")))
        self.assertEqual(statuses["high"], 200)
        self.assertIn(statuses["low"], (200, 409))

    def test_two_writers_bumping_the_same_version_leave_exactly_one_winner(self):
        """The concurrent-bump path of the replay rule: both devices read version
        3 and both offer 4. One of them is applying a change the other never saw,
        so exactly one may be accepted, and the stored blob must be that one's."""
        KeyBackup.objects.create(
            user_id=self.owner.id, blob=base64.b64decode(backup_blob(b"O")), version=3
        )
        blobs = {"first": backup_blob(b"1"), "second": backup_blob(b"2")}
        statuses = {}
        barrier = threading.Barrier(2)
        threads = [
            self.racing_put(headers, 4, blobs[label], barrier, statuses, label)
            for label, headers in (("first", self.low), ("second", self.high))
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)

        self.assertEqual(sorted(statuses.values()), [200, 409])
        winner = next(label for label, code in statuses.items() if code == 200)
        stored = KeyBackup.objects.get(user_id=self.owner.id)
        self.assertEqual(stored.version, 4)
        self.assertEqual(bytes(stored.blob), base64.b64decode(blobs[winner]))

    def test_two_accounts_writing_at_once_do_not_collide(self):
        """The lock is on the owner row, so it may serialise one account's writers
        and no one else's. Both accounts must be stored, each with its own bytes."""
        other = User.objects.create_user(
            username="bob", password=PASSWORD, is_active=True
        )
        access, _ = issue_session(other, make_device(other, 3))
        statuses = {}
        barrier = threading.Barrier(2)
        threads = [
            self.racing_put(self.low, 1, backup_blob(b"A"), barrier, statuses, "alice"),
            self.racing_put(
                {"Authorization": f"Bearer {access}"},
                1,
                backup_blob(b"B"),
                barrier,
                statuses,
                "bob",
            ),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)

        self.assertEqual(statuses, {"alice": 200, "bob": 200})
        self.assertEqual(
            bytes(KeyBackup.objects.get(user_id=self.owner.id).blob),
            base64.b64decode(backup_blob(b"A")),
        )
        self.assertEqual(
            bytes(KeyBackup.objects.get(user_id=other.id).blob),
            base64.b64decode(backup_blob(b"B")),
        )

    def test_a_write_waits_for_the_owner_row_before_it_touches_the_backup(self):
        """Guards the guard, from the lock's side. The test thread holds the very
        row the unit of work locks; a writer that took no lock would sail past and
        insert while it is held. Observing that it inserts nothing, and then
        finishes the moment the lock is released, is what proves the lock is
        real."""
        answer = {}
        running = threading.Event()

        def put():
            client = AsgiClient(application, api_application)
            try:
                connection.ensure_connection()
                running.set()
                answer["status"] = client.put(
                    KEYBACKUP_URL,
                    json={"blob": backup_blob(b"W"), "version": 2},
                    headers=self.high,
                ).status_code
            finally:
                connections.close_all()

        writer = threading.Thread(target=put)
        with transaction.atomic():
            User.objects.select_for_update().filter(id=self.owner.id).only("id").first()
            writer.start()
            running.wait(timeout=10)
            writer.join(timeout=0.5)  # bounded: the writer must still be blocked
            self.assertTrue(writer.is_alive(), "the write did not wait for the owner")
            self.assertEqual(KeyBackup.objects.filter(user_id=self.owner.id).count(), 0)

        writer.join(timeout=30)
        self.assertEqual(answer.get("status"), 200)
        self.assertEqual(KeyBackup.objects.get(user_id=self.owner.id).version, 2)

    def test_an_unlocked_read_then_write_loses_the_higher_version(self):
        """Guards the guard, from the race's side. This is the unit of work with
        the owner lock taken out: two transactions read the missing row, then
        write in the other order. The check alone cannot see a version that was
        not committed when it read, so the lower write lands last and the higher
        key backup is gone — which is the data loss the lock exists to stop."""
        both_read = threading.Barrier(2)
        higher_committed = threading.Event()

        def unlocked_write(version, blob, after_the_other):
            try:
                connection.ensure_connection()
                with transaction.atomic():
                    current = (
                        KeyBackup.objects.filter(user_id=self.owner.id)
                        .values_list("version", flat=True)
                        .first()
                    )  # no owner lock: both readers see nothing stored
                    both_read.wait(timeout=10)
                    if after_the_other:
                        higher_committed.wait(timeout=10)
                    if current is not None and version <= current:
                        return
                    KeyBackup.objects.update_or_create(
                        user_id=self.owner.id,
                        defaults={"blob": base64.b64decode(blob), "version": version},
                    )
                if not after_the_other:
                    higher_committed.set()
            finally:
                connections.close_all()

        threads = [
            threading.Thread(target=unlocked_write, args=(5, backup_blob(b"H"), False)),
            threading.Thread(target=unlocked_write, args=(1, backup_blob(b"L"), True)),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)

        stored = KeyBackup.objects.get(user_id=self.owner.id)
        self.assertEqual(
            stored.version,
            1,
            "the unguarded read-then-write kept the higher version, so the "
            "owner-row lock is not what the tests above are proving",
        )
        self.assertEqual(bytes(stored.blob), base64.b64decode(backup_blob(b"L")))
