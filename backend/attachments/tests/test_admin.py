"""The attachments page of the panel, and the one destructive action on it.

`Attachment.id` is the bearer capability that downloads the bytes, so this page is
built so that the id never becomes visible text and never enters a URL. The
panel-wide half of that rule — the missing change form, the missing
`delete_selected`, the audit row that names no capability — is proven across every
page in `accounts/tests/test_admin.py`. What is proven here is the page's own
code: the three columns, the two labels, and each branch of `purge_attachments`.
"""

import pytest
from django.contrib import admin as django_admin
from django.contrib.admin.models import DELETION, LogEntry
from django.contrib.messages import get_messages
from django.urls import reverse

from accounts.models import User
from attachments.models import Attachment
from conftest import PASSWORD
from core.buckets import ATTACHMENT_BUCKETS

pytestmark = pytest.mark.django_db

SMALLEST = min(ATTACHMENT_BUCKETS)
CHANGELIST = "admin:attachments_attachment_changelist"


@pytest.fixture
def owner(client):
    operator = User.objects.create_superuser(username="owner", password=PASSWORD)
    client.force_login(operator)
    return operator


@pytest.fixture
def attachment(db, attachments_root):
    row = Attachment.objects.create(size=SMALLEST)
    stored = attachments_root / row.id[:2] / row.id
    stored.parent.mkdir(parents=True, exist_ok=True)
    stored.write_bytes(b"ciphertext")
    return row


@pytest.fixture
def page():
    return django_admin.site._registry[Attachment]


def purge_post(client, pks, confirmed=None):
    body = {"action": "purge_attachments", "index": "0", "_selected_action": list(pks)}
    if confirmed is not None:
        body["confirmed"] = confirmed
    return client.post(reverse(CHANGELIST), body)


def messages_of(response):
    return [str(message) for message in get_messages(response.wsgi_request)]


def test_the_changelist_shows_the_size_and_the_day_and_links_nowhere(page):
    """A link would put the capability in the address bar, the browser history and
    any bookmark, so the page has no link and no column that could carry one. The
    account column left with the uploader the row no longer names (ADR-0025)."""
    assert page.list_display == ("size_bucket", "created_date")
    assert page.list_display_links is None
    assert "id" not in page.list_display
    assert page.list_filter == ("created_date",)


def test_the_size_column_reads_as_the_bucket_the_operator_recognises(page, attachment):
    assert page.size_bucket(attachment) == "64 KiB"


def test_the_audit_label_names_the_size_and_the_day_and_never_the_capability(
    page, attachment
):
    """The audit row outlives the attachment, so what it holds is decided here."""
    label = page.panel_repr(attachment)

    assert label == f"64 KiB attachment of {attachment.created_date}"
    assert attachment.pk not in label


def test_the_page_is_the_list_and_never_one_row(page, attachment, client, owner):
    """Django asks with `obj=None` for the changelist and with the instance for the
    change form and the per-object delete view, so refusing the second removes
    every URL that would carry a capability."""
    request = client.get(reverse(CHANGELIST)).wsgi_request

    assert page.has_view_permission(request) is True
    assert page.has_view_permission(request, attachment) is False
    assert page.has_delete_permission(request) is True
    assert page.has_delete_permission(request, attachment) is False
    assert page.has_add_permission(request) is False
    assert page.has_change_permission(request, attachment) is False


def test_the_confirmation_states_the_count_and_the_bytes_and_deletes_nothing_yet(
    client, owner, attachment, attachments_root
):
    """The two numbers the operator is deciding on, and no identifier. Nothing has
    happened yet: the row and its bytes are still there."""
    second = Attachment.objects.create(size=SMALLEST)

    response = purge_post(client, [attachment.pk, second.pk])
    rendered = response.content.decode()

    assert response.status_code == 200
    assert "This deletes 2 attachments" in rendered
    assert "128.0 KiB of storage is freed" in rendered
    assert Attachment.objects.count() == 2
    assert (attachments_root / attachment.pk[:2] / attachment.pk).exists()


def test_a_confirmed_purge_reports_the_rows_and_the_files_it_removed(
    client, owner, attachment, attachments_root
):
    """One row, one file, and the message says so in the singular."""
    response = purge_post(client, [attachment.pk], confirmed="yes")

    assert messages_of(response) == ["1 attachment deleted (1 file removed)."]
    assert Attachment.objects.count() == 0
    assert not (attachments_root / attachment.pk[:2] / attachment.pk).exists()


def test_a_purge_of_several_reports_them_in_the_plural(
    client, owner, attachment, attachments_root
):
    second = Attachment.objects.create(size=SMALLEST)
    stored = attachments_root / second.id[:2] / second.id
    stored.parent.mkdir(parents=True, exist_ok=True)
    stored.write_bytes(b"ciphertext")

    response = purge_post(client, [attachment.pk, second.pk], confirmed="yes")

    assert messages_of(response) == ["2 attachments deleted (2 files removed)."]
    assert Attachment.objects.count() == 0


def test_a_purge_that_selected_nothing_says_so_and_touches_no_row(
    client, owner, attachment, attachments_root
):
    """The boundary the changelist can reach: a selection that names no live row —
    a row another tab already purged, or an id typed by hand. The action still
    runs, and it must report rather than claim a deletion of zero rows."""
    response = purge_post(client, ["no-such-capability"], confirmed="yes")

    assert messages_of(response) == ["Nothing to do: no attachment was selected."]
    assert Attachment.objects.count() == 1
    assert (attachments_root / attachment.pk[:2] / attachment.pk).exists()
    assert not LogEntry.objects.filter(action_flag=DELETION).exists()


def test_a_purge_whose_file_is_already_gone_still_clears_the_row(
    client, owner, attachment, attachments_root
):
    """The rare case a crash between the unlink and the delete leaves behind: the
    row still has to go, and the message counts the files honestly."""
    (attachments_root / attachment.pk[:2] / attachment.pk).unlink()

    response = purge_post(client, [attachment.pk], confirmed="yes")

    assert messages_of(response) == ["1 attachment deleted (0 files removed)."]
    assert Attachment.objects.count() == 0


# --- The same rule, read off the rendered page ------------------------------------
# Every assertion above is about the `ModelAdmin`: which columns it declares, which
# permissions it refuses, what its audit label says. Configuration is what the panel
# is built from, and it is not what the operator's browser receives. A column added
# to `list_display`, a `list_display_links` restored, or a template that echoes the
# primary key would each leave every test above green and put the bearer capability
# in front of the operator.
#
# The two pages that carry a per-row identifier at all are the changelist and the
# confirmation of the one bulk action, and on both the identifier is the value of the
# `_selected_action` input the action cannot run without. That is the whole of the
# posture, so the count is the assertion: exactly one occurrence, inside that input.

SELECTED = 'name="_selected_action" value="'


def occurrences(body, capability):
    return body.count(capability)


def test_the_rendered_changelist_carries_the_capability_only_as_the_action_token(
    client, owner, attachment
):
    """Not in a link, not in a column, not in the address bar — and once, because the
    row has to be selectable for the one action this page offers."""
    body = client.get(reverse(CHANGELIST)).content.decode()

    assert occurrences(body, attachment.id) == 1
    assert f"{SELECTED}{attachment.id}" in body
    # The capability is a URL-safe string, so a link carrying it would be a plain
    # substring of an `href`. Neither form appears.
    assert f'href="{attachment.id}' not in body
    assert f"/{attachment.id}" not in body


def test_the_rendered_purge_confirmation_carries_it_only_as_the_action_token(
    client, owner, attachment
):
    """The confirmation page is where the first draft of this panel leaked the
    capability, so it is asserted against the rendered body rather than against the
    template name."""
    body = purge_post(client, [attachment.pk]).content.decode()

    assert occurrences(body, attachment.id) == 1
    assert f"{SELECTED}{attachment.id}" in body
    assert f"/{attachment.id}" not in body


def test_the_operator_is_told_what_the_purge_removes_without_being_told_which(
    client, owner, attachment
):
    """The confirmation has to be specific enough to act on and vague enough to leak
    nothing: a count, a freed size and the consequence, never the capability."""
    body = purge_post(client, [attachment.pk]).content.decode()

    assert "This deletes 1 attachment and the bytes behind it" in body
    assert "64.0 KiB of storage is freed" in body
    assert "never be able to" in body  # the consequence, stated before the button
    # Everything but the action token: the prose names no capability at all.
    assert attachment.id not in body.replace(f"{SELECTED}{attachment.id}", "", 1)
