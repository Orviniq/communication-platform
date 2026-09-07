"""The synchronous units of work behind the attachment routes, called directly.

Each function here is one transaction or one sweep, and what it leaves behind is a
row, a file, or a raised `ApiError`. Driving them without a request is what makes
the disk half observable at the point the unit commits it: the purge order is
about a file and a row that must never disagree, and a `purge` that met an
unreadable file has to keep sweeping.

The day's allowance is not here. It is counted in Redis rather than in a row
(`attachments/allowance.py`), and `test_allowance.py` drives it.

The same paths as they look through the HTTP surface are in `test_attachments.py`
and `test_routes.py`.
"""

import os

import pytest

from accounts.models import User
from api.errors import ApiError
from attachments import services
from attachments.models import Attachment
from core.buckets import ATTACHMENT_BUCKETS

pytestmark = pytest.mark.django_db

SMALLEST = min(ATTACHMENT_BUCKETS)


def refusal(exc_info):
    """The three parts of a refusal a client can see."""
    error = exc_info.value
    return error.status_code, error.code, error.detail


def stored_file(attachment, payload=b"ciphertext"):
    """The bytes on disk for a row, written the way the upload route writes them."""
    path = attachment.disk_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as out:
        out.write(payload)
    return path


class TestRecord:
    def test_the_row_lands_naming_nobody(self):
        """The insert carries a size and a capability id and no account: the
        column that used to say whose bytes these are is written by nothing
        (ADR-0025)."""
        attachment = Attachment(size=SMALLEST)

        services.record(attachment)

        stored = Attachment.objects.get(id=attachment.id)
        assert stored.size == SMALLEST
        assert [f.name for f in stored._meta.concrete_fields] == [
            "id",
            "size",
            "created_date",
        ]


class TestDiskSpace:
    def test_it_reports_free_space_inside_the_filesystem_it_measures(self):
        """The two numbers are the guard's whole input: free must be positive on a
        writable temporary directory, and never larger than the filesystem."""
        free, capacity = services.disk_space()

        assert 0 < free <= capacity

    def test_a_root_that_does_not_exist_yet_is_created_rather_than_raising(
        self, settings, tmp_path
    ):
        """The upload path calls this before it copies anything, so a deployment
        whose attachment root has never been written to must measure the
        filesystem rather than answer that there is none."""
        settings.ATTACHMENTS_ROOT = tmp_path / "never-created"

        free, _capacity = services.disk_space()

        assert free > 0
        assert (tmp_path / "never-created").is_dir()


class TestLocate:
    def test_a_stored_capability_reads_back_as_itself(self, active_user):
        attachment = Attachment.objects.create(size=SMALLEST)

        assert services.locate(attachment.id) == attachment.id

    def test_an_id_that_names_no_row_is_a_404(self):
        with pytest.raises(ApiError) as exc_info:
            services.locate("a" * 43)

        assert refusal(exc_info) == (404, "not_found", services.NOT_FOUND)

    def test_a_pruned_attachment_answers_the_same_404_as_one_that_never_existed(
        self, active_user
    ):
        """A distinguishable answer would turn the download into an oracle for
        which capabilities were ever issued."""
        attachment = Attachment.objects.create(size=SMALLEST)
        Attachment.objects.filter(id=attachment.id).delete()

        with pytest.raises(ApiError) as gone:
            services.locate(attachment.id)
        with pytest.raises(ApiError) as never:
            services.locate("b" * 43)

        assert refusal(gone) == refusal(never) == (404, "not_found", services.NOT_FOUND)

    def test_a_nul_byte_is_refused_before_it_reaches_the_database(
        self, django_assert_num_queries
    ):
        """PostgreSQL text carries no NUL, so psycopg refuses the statement rather
        than returning no row (AR-10). The guard is ahead of the query, which is
        what makes it an answer instead of a 500."""
        with django_assert_num_queries(0), pytest.raises(ApiError) as exc_info:
            services.locate("a\x00b")

        assert refusal(exc_info) == (404, "not_found", services.NOT_FOUND)


class TestPurge:
    def test_the_rows_and_their_bytes_both_go(self, active_user, attachments_root):
        rows = [Attachment.objects.create(size=SMALLEST) for _ in range(2)]
        paths = [stored_file(row) for row in rows]

        deleted, removed_files = services.purge(rows)

        assert (deleted, removed_files) == (2, 2)
        assert Attachment.objects.count() == 0
        assert [os.path.exists(path) for path in paths] == [False, False]

    def test_a_file_that_is_already_gone_still_clears_its_row(self, active_user):
        """The rare case a crash between the unlink and the delete leaves behind,
        and the case the next retention pass has to be able to finish."""
        attachment = Attachment.objects.create(size=SMALLEST)

        deleted, removed_files = services.purge([attachment])

        assert (deleted, removed_files) == (1, 0)
        assert Attachment.objects.count() == 0

    def test_a_file_that_refuses_to_unlink_keeps_its_row_and_does_not_stop_the_sweep(
        self, active_user, attachments_root, monkeypatch
    ):
        """An escaping error here would stall retention entirely: the rows go in one
        pass at the end, so the whole batch would come back unswept for ever."""
        stuck = Attachment.objects.create(size=SMALLEST)
        rest = [Attachment.objects.create(size=SMALLEST) for _ in range(2)]
        stuck_path = stored_file(stuck)
        paths = [stored_file(row) for row in rest]
        real_remove = os.remove

        def refuse_one(path, *args, **kwargs):
            if path == stuck_path:
                raise OSError(13, "Permission denied")
            return real_remove(path, *args, **kwargs)

        monkeypatch.setattr(services.os, "remove", refuse_one)

        deleted, removed_files = services.purge([stuck] + rest)

        assert (deleted, removed_files) == (2, 2)
        assert list(Attachment.objects.values_list("id", flat=True)) == [stuck.id]
        assert os.path.exists(stuck_path)
        assert [os.path.exists(path) for path in paths] == [False, False]

    def test_the_audit_hook_is_handed_the_rows_that_are_about_to_go_exactly_once(
        self, active_user, attachments_root
    ):
        """The panel's own deletion audits what it removed. Handed the rows before
        the delete, because afterwards there is nothing left to name."""
        rows = [Attachment.objects.create(size=SMALLEST) for _ in range(3)]
        for row in rows:
            stored_file(row)
        seen = []

        services.purge(rows, audit=lambda objects: seen.append([o.id for o in objects]))

        assert seen == [[row.id for row in rows]]

    def test_the_audit_hook_never_names_a_row_the_sweep_did_not_take(
        self, active_user, attachments_root, monkeypatch
    ):
        """A row whose file refused to unlink keeps its row, so auditing it would
        record a deletion that did not happen."""
        kept = Attachment.objects.create(size=SMALLEST)
        taken = Attachment.objects.create(size=SMALLEST)
        kept_path = stored_file(kept)
        stored_file(taken)
        real_remove = os.remove

        def refuse_kept(path, *args, **kwargs):
            if path == kept_path:
                raise OSError(13, "Permission denied")
            return real_remove(path, *args, **kwargs)

        monkeypatch.setattr(services.os, "remove", refuse_kept)
        seen = []

        services.purge([kept, taken], audit=lambda objects: seen.append(list(objects)))

        assert seen == [[taken]]

    def test_the_audit_hook_is_not_called_when_nothing_survives_the_unlink_step(
        self, active_user, attachments_root, monkeypatch
    ):
        """Every file refused: no row goes, so no administrative act happened and
        the log must stay empty."""
        rows = [Attachment.objects.create(size=SMALLEST) for _ in range(2)]
        for row in rows:
            stored_file(row)

        def refuse_everything(path, *args, **kwargs):
            raise OSError(13, "Permission denied")

        monkeypatch.setattr(services.os, "remove", refuse_everything)
        seen = []

        deleted, removed_files = services.purge(rows, audit=seen.append)

        assert (deleted, removed_files) == (0, 0)
        assert seen == []
        assert Attachment.objects.count() == 2

    def test_an_empty_sweep_writes_nothing_and_calls_nobody(self):
        """The boundary the retention command reaches on every quiet day."""
        seen = []

        deleted, removed_files = services.purge([], audit=seen.append)

        assert (deleted, removed_files) == (0, 0)
        assert seen == []

    def test_a_purge_leaves_every_account_alone(self, active_user, attachments_root):
        """The sweep removes storage, never people. Nothing on the row points at an
        account any more, and this is the assertion that the delete stays that
        way."""
        attachment = Attachment.objects.create(size=SMALLEST)
        stored_file(attachment)

        services.purge([attachment])

        assert User.objects.filter(pk=active_user.pk).exists()
