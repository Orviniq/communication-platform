"""The synchronous units of work behind the attachment routes."""

import os

from django.conf import settings

from api.errors import ApiError
from attachments.models import Attachment

NOT_FOUND = "No such attachment."


def disk_space():
    """The bytes still writable under `ATTACHMENTS_ROOT`, and the filesystem's size.

    `f_bavail` rather than `f_bfree`: the blocks a filesystem holds back for root
    are not space this service account can use, and a guard that counted them
    would admit the upload that fills the disk.

    The directory is created here because it is the first thing the upload path
    touches and the copy needs it anyway; without that a deployment whose root
    does not exist yet would read as a filesystem that is not there.
    """
    os.makedirs(settings.ATTACHMENTS_ROOT, exist_ok=True)
    stats = os.statvfs(settings.ATTACHMENTS_ROOT)
    return stats.f_bavail * stats.f_frsize, stats.f_blocks * stats.f_frsize


def record(attachment):
    """Insert the row for bytes that are already on disk.

    One statement and no lock. The charge is taken before the bytes are written,
    in Redis (`attachments/allowance.py`), so the aggregate over the account's own
    rows that used to run here left with `Attachment.uploader` — and with it the
    only column that said whose bytes these are (ADR-0025).

    The bytes reach the disk first, which is the order that keeps a failed write
    off the download path: no row exists for a file that was never finished. The
    other order would publish a capability id for bytes that are not there.
    """
    attachment.save()


def locate(attachment_id):
    """The capability id, read back from the row that holds it.

    Only the id: the response must name nobody and there is nothing else on the
    row a caller may have. A missing row and a pruned one are the same answer.

    A NUL byte is the third: PostgreSQL text carries none, so psycopg refuses the
    statement rather than returning no row, and the route raised instead of
    answering without this (AR-10). A capability id is base64url of 32 random
    bytes, so no stored id can hold one — an id carrying it is an id nobody has,
    which is the answer below. This is a malformed-input guard, never a control:
    the unguessable id is the whole access check.
    """
    if "\x00" in attachment_id:
        raise ApiError(404, "not_found", NOT_FOUND)
    stored = Attachment.objects.filter(id=attachment_id).only("id").first()
    if stored is None:
        raise ApiError(404, "not_found", NOT_FOUND)
    return stored.id


def purge(attachments, audit=None):
    """Delete these attachment rows and unlink their bytes.

    The one write path that removes an attachment. `manage.py prune` calls it for
    the retention sweep and the admin panel calls it for the operator's own
    deletion, so the order below is the order both get.

    Unlink before deleting the row: a crash in between leaves a row whose bytes are
    already gone, which the next pass clears. Dropping the row first would strand
    the file, since cleanup only ever walks rows.

    `audit` is called once, with the rows that are about to go, before the delete.
    The retention sweep passes none — a scheduled expiry is not an administrative
    act and no operator performed it.
    """
    doomed = []
    removed_files = 0
    for attachment in attachments:
        try:
            os.remove(attachment.disk_path())
            removed_files += 1
        except FileNotFoundError:
            pass  # already gone; the row still needs clearing
        except OSError:
            # One unreadable file must not stop the sweep. The rows go in a single
            # pass below, so an escaping error would stall retention entirely.
            continue
        doomed.append(attachment)
    if audit is not None and doomed:
        audit(doomed)
    deleted, _ = Attachment.objects.filter(
        id__in=[attachment.id for attachment in doomed]
    ).delete()
    return deleted, removed_files
