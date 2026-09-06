"""The row behind a stored blob: a capability for an id, a shard for a path.

`Attachment.id` is not an identifier, it is the bearer capability that fetches the
bytes, so its generator and its column width are load-bearing rather than
cosmetic. What the row must never carry — a recipient, an ACL, a key — is pinned
in `test_attachments.py`; what it does carry is pinned here.
"""

import base64
import os

import pytest

from accounts.models import User
from attachments.models import Attachment, _new_capability_id
from core.buckets import ATTACHMENT_BUCKETS

pytestmark = pytest.mark.django_db

SMALLEST = min(ATTACHMENT_BUCKETS)
# base64url of 32 random bytes, unpadded: the alphabet a capability may hold.
ALPHABET = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")


def test_a_fresh_row_carries_43_characters_of_url_safe_capability():
    attachment = Attachment.objects.create(size=SMALLEST)

    assert len(attachment.id) == 43
    assert set(attachment.id) <= ALPHABET
    # 43 unpadded characters decode to the 32 random bytes they were made from,
    # which is the 256 bits that make the id unguessable.
    assert len(base64.urlsafe_b64decode(attachment.id + "=")) == 32


def test_the_column_is_exactly_as_wide_as_the_capability_it_stores():
    """43 is the boundary: one character narrower truncates a capability into a
    prefix that no download can ever match, one wider admits a value the generator
    cannot produce."""
    field = Attachment._meta.get_field("id")

    assert (field.max_length, field.primary_key, field.editable) == (43, True, False)
    assert len(_new_capability_id()) == field.max_length


def test_no_two_generated_capabilities_collide():
    """Nothing serialises the generator and nothing retries a clash: the id is the
    primary key, so a repeat would be an insert failure on a live upload."""
    generated = {_new_capability_id() for _ in range(500)}

    assert len(generated) == 500


def test_the_disk_path_shards_on_the_capability_and_stays_under_the_root(
    attachments_root,
):
    """One directory of every stored file is a directory listing nobody can page.
    The shard comes off the server-generated id, so no request value steers it."""
    attachment = Attachment.objects.create(size=SMALLEST)

    path = attachment.disk_path()

    assert path == os.path.join(str(attachments_root), attachment.id[:2], attachment.id)
    assert os.path.commonpath([path, str(attachments_root)]) == str(attachments_root)


def test_the_path_follows_the_configured_root_rather_than_a_value_baked_at_import(
    settings, tmp_path
):
    """The deployment points `ATTACHMENTS_ROOT` at its own volume, and a path read
    once at import would keep writing into the directory the tests use."""
    attachment = Attachment.objects.create(size=SMALLEST)
    settings.ATTACHMENTS_ROOT = tmp_path / "somewhere-else"

    assert attachment.disk_path().startswith(str(tmp_path / "somewhere-else"))


def test_a_removed_account_leaves_its_attachments_fetchable(active_user):
    """The capability travelled to recipients inside their messages, so erasing the
    account that uploaded the bytes must not break their download. Nothing on the
    row names an account since `attachments.0002_drop_the_uploader_link`, so no
    cascade can reach it — this is what proves the row survives the delete rather
    than the `SET_NULL` that used to."""
    attachment = Attachment.objects.create(size=SMALLEST)

    User.objects.filter(pk=active_user.pk).delete()

    attachment.refresh_from_db()
    assert Attachment.objects.filter(id=attachment.id).exists()


def test_the_largest_bucket_round_trips_through_the_size_column():
    """The boundary the column has to hold: the biggest bucket a client may
    upload, read back as the integer it was stored as."""
    largest = max(ATTACHMENT_BUCKETS)

    attachment = Attachment.objects.create(size=largest)

    assert Attachment.objects.get(id=attachment.id).size == largest


def test_no_relation_reaches_an_attachment_from_an_account(active_user):
    """`user.attachments` was the accessor the lifetime quota and the panel column
    read. ADR-0025 removed both and run 08 dropped the column, so an account has no
    path to a stored file: the only handle on one is the capability id a recipient
    was given inside an end-to-end encrypted message."""
    Attachment.objects.create(size=SMALLEST)

    assert not hasattr(active_user, "attachments")
    assert [f.name for f in Attachment._meta.get_fields() if f.is_relation] == []
