"""The two properties of the upload path that the request shape alone cannot show:
the bytes never cross the process whole, and the day's allowance holds under
concurrency.
"""

import os
import threading

import pytest
from django.db import connection, connections

from attachments import routes
from attachments.models import Attachment
from core.buckets import ATTACHMENT_BUCKETS

UPLOAD_URL = "/api/v1/attachments"
SMALLEST = min(ATTACHMENT_BUCKETS)
CONCURRENT_UPLOADS = 6


class RecordingSource:
    """A spooled part that reports how much of it was asked for at a time."""

    def __init__(self, data):
        self._data = data
        self._at = 0
        self.requested = []

    def read(self, size):
        self.requested.append(size)
        chunk = self._data[self._at : self._at + size]
        self._at += len(chunk)
        return chunk


def test_the_copy_reads_the_part_one_bounded_chunk_at_a_time(tmp_path):
    """A whole-file read would hold one attachment in memory for each concurrent
    upload, and the largest bucket is 64 MiB on a 1 GB host."""
    payload = bytes(range(256)) * (routes.CHUNK_BYTES * 3 // 256 + 1)
    source = RecordingSource(payload)
    path = str(tmp_path / "ab" / "abcdef")

    routes._spool_to_disk(source, path)

    assert open(path, "rb").read() == payload
    # Every read was bounded, and it took more than one of them to finish.
    assert set(source.requested) == {routes.CHUNK_BYTES}
    assert len(source.requested) > 2


def test_the_spool_threshold_is_the_copy_chunk():
    """Starlette's own default is 1 MiB, which is three of the six attachment
    buckets held whole in memory before the copy ever starts."""
    assert routes._SingleFileParser.spool_max_size == routes.CHUNK_BYTES


@pytest.mark.django_db(transaction=True)
def test_concurrent_uploads_never_overshoot_the_days_allowance(
    new_http, active_user, device, bearer, settings, attachments_root
):
    """The reservation is one `INCRBY`, which is atomic and returns the value it
    produced. A read-then-write instead would be this race: every thread reads the
    same count, every thread passes, and the account spends past its allowance."""
    settings.ATTACH_DAILY_BYTES = SMALLEST * 2
    headers = bearer(active_user, device)
    start = threading.Barrier(CONCURRENT_UPLOADS)
    statuses, failures = [], []
    lock = threading.Lock()

    def upload():
        try:
            # Open this thread's connection before the barrier: setup costs more
            # than the transaction the guard is about, so threads released
            # together would otherwise reach the row one at a time.
            connection.ensure_connection()
            start.wait(timeout=10)
            response = new_http().post(
                UPLOAD_URL, files={"blob": ("blob", b"\x01" * SMALLEST)}, headers=headers
            )
            with lock:
                statuses.append(response.status_code)
        except Exception as exc:  # noqa: BLE001 - surfaced through `failures`
            with lock:
                failures.append(repr(exc))
        finally:
            connections.close_all()

    threads = [threading.Thread(target=upload) for _ in range(CONCURRENT_UPLOADS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert failures == []
    assert sorted(statuses) == [201, 201] + [413] * (CONCURRENT_UPLOADS - 2)
    stored = Attachment.objects.all()
    assert stored.count() == 2
    assert sum(row.size for row in stored) <= settings.ATTACH_DAILY_BYTES
    # The refused uploads left no bytes behind either.
    assert len([p for p in attachments_root.rglob("*") if p.is_file()]) == 2


def test_the_copy_creates_the_shard_directory_the_capability_names(tmp_path):
    """Every stored file sits under a two-character shard of its own id, and the
    upload is the only thing that ever creates those directories."""
    path = str(tmp_path / "Xk" / "Xk3vT9qLm2WnPzR8sYb4cJdF6hA1gE5uV7iO0wQtN_M")

    routes._spool_to_disk(RecordingSource(b"ciphertext"), path)

    assert (tmp_path / "Xk").is_dir()
    assert open(path, "rb").read() == b"ciphertext"


def test_a_second_file_lands_in_a_shard_that_already_exists(tmp_path):
    """`exist_ok`: two capabilities sharing a prefix is the common case at any
    volume, and the second upload must not fail on the directory the first made."""
    first = str(tmp_path / "Xk" / "Xk3v")
    second = str(tmp_path / "Xk" / "XkZZ")

    routes._spool_to_disk(RecordingSource(b"one"), first)
    routes._spool_to_disk(RecordingSource(b"two"), second)

    assert open(second, "rb").read() == b"two"
    assert sorted(p.name for p in (tmp_path / "Xk").iterdir()) == ["Xk3v", "XkZZ"]


def test_a_payload_that_ends_exactly_on_a_chunk_boundary_is_copied_whole(tmp_path):
    """The boundary of the copy loop: the last full read is followed by an empty
    one, which is what ends the walrus loop rather than a short read."""
    payload = b"\xa5" * (routes.CHUNK_BYTES * 2)
    source = RecordingSource(payload)
    path = str(tmp_path / "ab" / "abcdef")

    routes._spool_to_disk(source, path)

    assert open(path, "rb").read() == payload
    # Two full chunks, then the empty read that ends the loop.
    assert len(source.requested) == 3


def test_an_empty_part_leaves_an_empty_file_rather_than_no_file(tmp_path):
    """The rare case the bucket check refuses before it ever reaches here. The copy
    itself still has to be total: a missing file would strand a row that names it."""
    path = str(tmp_path / "ab" / "abcdef")

    routes._spool_to_disk(RecordingSource(b""), path)

    assert open(path, "rb").read() == b""


def test_the_discard_removes_the_bytes_a_refused_upload_wrote(tmp_path):
    """What a failed row write calls: the file is written before the row exists, so
    the bytes have to be dropped by hand when the insert does not happen."""
    path = str(tmp_path / "ab" / "abcdef")
    routes._spool_to_disk(RecordingSource(b"ciphertext"), path)

    routes._discard(path)

    assert not os.path.exists(path)


def test_discarding_a_path_that_is_already_gone_is_not_an_error(tmp_path):
    """`missing_ok`: the discard runs on every failure of the row write, including
    the ones that happen before anything was written."""
    path = str(tmp_path / "ab" / "abcdef")

    routes._discard(path)

    assert not os.path.exists(path)
    assert not (tmp_path / "ab").exists()
