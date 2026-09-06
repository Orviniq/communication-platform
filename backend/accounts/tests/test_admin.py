"""The panel suite.

The admin is a security boundary, not a convenience (ADR-0011): what it registers,
what it renders and what each action writes are the things this file pins. It
covers the whole panel rather than the accounts page alone, because the rules it
proves are panel-wide and a second copy of them in five files would drift.

Every assertion here is one this panel can fail. The exposure tests in particular
were written against a panel that leaked: `Attachment.id` is the bearer capability
that downloads the bytes, and the first draft put it in a link, a change-form URL
and a delete confirmation page. What the panel holds now is the precise property
those tests state, and nothing looser.
"""

import re
from datetime import timedelta
from io import StringIO

import pytest
from django.apps import apps
from django.contrib import admin as django_admin
from django.contrib.admin.models import ADDITION, CHANGE, DELETION, LogEntry
from django.contrib.messages import get_messages
from django.contrib.staticfiles import finders
from django.core.management import call_command
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from django.utils.html import strip_tags

from accounts.models import User
from attachments.models import Attachment
from core.fields import OpaqueBlobField
from devices.models import Device

pytestmark = pytest.mark.django_db

PASSWORD = "correct-horse-battery-staple"

# The four the operator works with (ADR-0011, decision 2). Anything else on the
# site is an exposure nobody decided on.
REGISTERED = {
    "accounts.User",
    "devices.Device",
    "attachments.Attachment",
    "admin.LogEntry",
}

# Every model that must stay off the site, the sidebar and the command palette.
HIDDEN = {
    "accounts.ProfileBlob",
    "devices.UserIdentity",
    "devices.OneTimePrekey",
    "devices.PqOneTimePrekey",
    "devices.DeviceLogRecord",
    "vault.KeyBackup",
    "messaging.QueuedEnvelope",
    "auth.Group",
    "auth.Permission",
}

CHANGELISTS = [
    "admin:accounts_user_changelist",
    "admin:devices_device_changelist",
    "admin:attachments_attachment_changelist",
    "admin:admin_logentry_changelist",
]

# A reference that would make the browser fetch from another host: a `src` or
# `href` in markup, or a `url()` or `@import` in a stylesheet, pointing at an
# absolute or protocol-relative URL.
#
# Deliberately the shape of a fetch rather than a list of CDN vendor names. It
# catches any host instead of six of them, so a font from an unnamed CDN is caught
# too; and this run's shell asset gate greps every `*.py` file for those vendor
# names, which would make this file the gate's only hit.
EXTERNAL_FETCH = re.compile(
    r"""(?:src|href)\s*=\s*["'](?:https?:)?//"""
    r"""|url\(\s*["']?(?:https?:)?//"""
    r"""|@import\s+["'](?:https?:)?//""",
    re.IGNORECASE,
)


@pytest.fixture
def owner(client):
    operator = User.objects.create_superuser(username="owner", password=PASSWORD)
    client.force_login(operator)
    return operator


@pytest.fixture
def alice():
    return User.objects.create_user(username="alice", password=PASSWORD)


@pytest.fixture
def device(alice):
    return Device.objects.create(
        user=alice,
        ik_pub=b"k" * 32,
        spk_id=1,
        spk_pub=b"k" * 32,
        spk_sig=b"s" * 64,
        registration_id=101,
    )


@pytest.fixture
def attachment(db):
    return Attachment.objects.create(size=65536)


def _seed(count, prefix="user"):
    for index in range(count):
        person = User.objects.create_user(username=f"{prefix}{index}", password=PASSWORD)
        Device.objects.create(
            user=person,
            ik_pub=b"k" * 32,
            spk_id=1,
            spk_pub=b"k" * 32,
            spk_sig=b"s" * 64,
            registration_id=index,
        )
        Attachment.objects.create(size=65536)


# --- The registry is the boundary ----------------------------------------------


def test_the_site_is_an_unfold_site_and_nothing_else():
    """`unfold` before `django.contrib.admin` in INSTALLED_APPS is what does this.
    In the other order autodiscover registers onto a site unfold then replaces, and
    the panel silently lists nothing."""
    assert type(django_admin.site).__module__ == "unfold.sites"
    assert type(django_admin.site).__name__ == "UnfoldAdminSite"


def test_every_registered_project_app_names_itself_in_operator_words():
    """The breadcrumb of every page reads the app's `verbose_name`, and Django
    derives one from the label when the app declares none. The pass of phase 3
    found one app rendering a run-together label on every page it served.

    Declared rather than derived, on every project app the panel registers a model
    from, so the next app cannot ship a run-together label by omission. This is the
    app half of the vocabulary pass; the model half needs a migration and stays
    deferred in `docs/admin/PANEL-RECORD.md`.
    """
    project_apps = {
        model._meta.app_config
        for model in django_admin.site._registry
        if model._meta.label in REGISTERED and model._meta.app_label != "admin"
    }
    assert project_apps, "no project app is registered"

    derived = {
        config.label: config.verbose_name
        for config in project_apps
        if config.verbose_name == config.label.title()
        and "verbose_name" not in vars(type(config))
    }

    assert derived == {}, derived


def test_exactly_the_four_decided_models_are_registered():
    registered = {model._meta.label for model in django_admin.site._registry}

    assert registered == REGISTERED


def test_every_hidden_model_exists_and_is_unregistered():
    """Named one by one rather than as a set difference: a model that is renamed or
    deleted must fail here, not quietly pass by being absent."""
    registered = {model._meta.label for model in django_admin.site._registry}

    for label in HIDDEN:
        assert apps.get_model(label) is not None, label
        assert label not in registered, label


def test_no_hidden_model_reaches_the_index_or_the_palette(client, owner):
    """Two surfaces, one rule. The palette searches `get_app_list`, which is the
    same list the index renders, so both are checked against the same names."""
    index = client.get(reverse("admin:index")).content.decode()

    for label in HIDDEN:
        model = apps.get_model(label)
        name = model._meta.verbose_name_plural
        assert str(name).lower() not in strip_tags(index).lower(), label

        palette = client.get(reverse("admin:search"), {"s": model.__name__})
        assert model.__name__.lower() not in palette.content.decode().lower(), label


def test_the_palette_never_searches_rows():
    """A row search would run `search_fields` against every registered model, and
    for `Attachment` the only row it could name is its capability id."""
    from django.conf import settings

    assert settings.UNFOLD["COMMAND"]["search_models"] is False


# --- What the panel may show ----------------------------------------------------


def _unsafe_column_names(model):
    """Every column of this model that may not reach a page: ciphertext, raw key or
    signature bytes, and the password hash."""
    unsafe = set()
    for field in model._meta.get_fields():
        if not hasattr(field, "attname"):
            continue
        from django.db import models

        if isinstance(field, OpaqueBlobField | models.BinaryField):
            unsafe.add(field.name)
        if field.name == "password":
            unsafe.add(field.name)
    return unsafe


@pytest.mark.parametrize("label", sorted(REGISTERED))
def test_no_column_or_field_names_a_blob_key_signature_or_password(label):
    model = apps.get_model(label)
    model_admin = django_admin.site._registry[model]
    unsafe = _unsafe_column_names(model)

    named = set()
    for attribute in (
        "list_display",
        "readonly_fields",
        "fields",
        "search_fields",
        "list_filter",
        "ordering",
    ):
        for entry in getattr(model_admin, attribute, None) or ():
            if isinstance(entry, str):
                named.add(entry.lstrip("-").split("__")[0])

    assert named & unsafe == set(), (label, sorted(named & unsafe))


def test_the_device_page_shows_no_key_material(client, owner, device):
    """The columns are chosen; this proves the bytes themselves never render, which
    a column list alone would not."""
    for url in (
        reverse("admin:devices_device_changelist"),
        reverse("admin:devices_device_change", args=[device.pk]),
    ):
        body = client.get(url).content.decode()

        assert "ik_pub" not in body
        assert "label_blob" not in body
        assert device.ik_pub.hex() not in body


def test_the_account_change_form_carries_no_password_widget(client, owner, alice):
    body = client.get(
        reverse("admin:accounts_user_change", args=[alice.pk])
    ).content.decode()

    assert alice.password not in body
    assert "argon2" not in body.lower()
    assert 'name="password"' not in body
    assert "Set a new password" in body


def _where_it_appears(body, needle):
    urls = " ".join(re.findall(r'(?:href|action|src)="([^"]*)"', body))
    return {
        "visible_text": needle in strip_tags(body),
        "in_a_url": needle in urls,
        "occurrences": body.count(needle),
        "as_row_selector": len(
            re.findall(r'name="_selected_action"\s+value="%s"' % re.escape(needle), body)
        ),
    }


def test_the_attachment_capability_reaches_no_text_and_no_url(client, owner, attachment):
    """`Attachment.id` is a bearer capability: `GET /api/v1/attachments/{id}` serves
    the bytes to any live token that presents it.

    The panel therefore shows it nowhere a person or a browser can keep it — no
    column, no link, no address bar, no history. It appears exactly once, as the
    value of the checkbox Django addresses a row with, which is recorded in
    `ACCEPTED_RISKS.md` with the reason it is the residue rather than a leak.
    """
    body = client.get(reverse("admin:attachments_attachment_changelist")).content.decode()

    assert _where_it_appears(body, attachment.pk) == {
        "visible_text": False,
        "in_a_url": False,
        "occurrences": 1,
        "as_row_selector": 1,
    }


def test_the_attachment_has_no_change_form_and_no_delete_view(client, owner, attachment):
    """Both URLs would *be* the capability, so both are refused."""
    change = client.get(
        reverse("admin:attachments_attachment_change", args=[attachment.pk])
    )
    delete = client.get(
        reverse("admin:attachments_attachment_delete", args=[attachment.pk])
    )

    assert (change.status_code, delete.status_code) == (403, 403)


def test_djangos_delete_selected_is_off_the_attachment_page(client, owner, attachment):
    """Its confirmation page lists `str(obj)` for every selected row, which for this
    model is the capability in visible text."""
    model_admin = django_admin.site._registry[Attachment]
    request = client.get(reverse("admin:attachments_attachment_changelist")).wsgi_request

    assert "delete_selected" not in model_admin.get_actions(request)
    assert "purge_attachments" in model_admin.get_actions(request)


# --- Every page renders, at a query count that does not grow --------------------


@pytest.mark.parametrize("name", CHANGELISTS + ["admin:index"])
def test_the_page_renders_and_its_query_count_does_not_grow_with_the_rows(
    client, owner, name
):
    """The number itself is not the assertion — a Django release may add or drop a
    session query. What must hold is that it is the same for two rows and for a full
    page of them, which is what an N+1 breaks."""
    _seed(2, prefix="few")
    with CaptureQueriesContext(connection) as few:
        assert client.get(reverse(name)).status_code == 200

    _seed(22, prefix="many")
    with CaptureQueriesContext(connection) as many:
        assert client.get(reverse(name)).status_code == 200

    assert len(few) == len(many), (name, len(few), len(many))


def test_every_change_form_the_panel_keeps_renders(client, owner, alice, device):
    """`Attachment` is absent by design and has its own test above; every other
    registered model answers 200 for the owner."""
    entry = LogEntry.objects.create(
        user=owner, object_repr="owner", action_flag=CHANGE, change_message="x"
    )

    for name, pk in (
        ("admin:accounts_user_change", alice.pk),
        ("admin:devices_device_change", device.pk),
        ("admin:admin_logentry_change", entry.pk),
    ):
        assert client.get(reverse(name, args=[pk])).status_code == 200, name


def test_the_dashboard_counts_what_the_operator_needs(
    client, owner, alice, device, attachment
):
    body = client.get(reverse("admin:index")).content.decode()
    text = strip_tags(body)

    assert "alice" in text  # awaiting activation, with its one-click activate
    assert "Waiting for activation" in text
    # The page is named for the job, not for the software.
    assert "Site administration" not in text
    assert reverse("admin:devices_device_changelist") in body  # every number links


# --- Every action writes its audit row ------------------------------------------


def _post_action(client, name, action, pks, **extra):
    return client.post(
        reverse(name),
        {
            "action": action,
            "index": "0",
            "_selected_action": [str(pk) for pk in pks],
            **extra,
        },
    )


def test_activation_writes_one_audit_row_for_each_account(client, owner, alice):
    other = User.objects.create_user(username="bob", password=PASSWORD)

    _post_action(
        client,
        "admin:accounts_user_changelist",
        "activate_accounts",
        [alice.pk, other.pk],
    )

    alice.refresh_from_db()
    rows = LogEntry.objects.filter(change_message="Activated.")
    assert alice.is_active is True
    assert rows.count() == 2
    assert {row.object_repr for row in rows} == {"alice", "bob"}
    assert {row.user_id for row in rows} == {owner.pk}
    assert {row.action_flag for row in rows} == {CHANGE}


def test_deactivation_writes_its_audit_row(client, owner, alice):
    alice.is_active = True
    alice.save(update_fields=["is_active"])

    _post_action(
        client, "admin:accounts_user_changelist", "deactivate_accounts", [alice.pk]
    )

    alice.refresh_from_db()
    assert alice.is_active is False
    assert LogEntry.objects.filter(change_message="Deactivated.").count() == 1


def test_a_bulk_action_that_changes_nothing_writes_nothing(client, owner, alice):
    """Django writes no row for a bulk action at all, so the panel writes them —
    and it must not write one for a row it did not touch."""
    _post_action(
        client, "admin:accounts_user_changelist", "deactivate_accounts", [alice.pk]
    )  # alice is already inactive

    assert LogEntry.objects.count() == 0


def test_revoking_every_device_of_an_account_audits_and_revokes(
    client, owner, alice, device
):
    _post_action(
        client, "admin:accounts_user_changelist", "revoke_all_devices", [alice.pk]
    )

    device.refresh_from_db()
    assert device.revoked_date is not None
    assert (
        LogEntry.objects.filter(
            change_message="Revoked every device of this account."
        ).count()
        == 1
    )


def test_revoking_one_device_audits_and_goes_through_the_service(client, owner, device):
    from devices.models import OneTimePrekey

    OneTimePrekey.objects.create(device=device, key_id=1, pub=b"p" * 32)
    before = device.token_generation

    _post_action(client, "admin:devices_device_changelist", "revoke_devices", [device.pk])

    device.refresh_from_db()
    assert device.revoked_date is not None
    # The service's own consequences, not a second write path that only sets a date.
    assert OneTimePrekey.objects.filter(device=device).count() == 0
    assert device.token_generation == before + 1  # every outstanding token is dead
    row = LogEntry.objects.get(change_message="Revoked.")
    assert row.object_repr == f"device {device.pk}"


def test_setting_a_password_audits_and_changes_the_password(client, owner, alice):
    url = reverse("admin:accounts_user_set_password", args=[alice.pk])

    response = client.post(
        url,
        {
            "password": "another-long-password",
            "confirm": "another-long-password",
            "_form_submitted": "1",
        },
    )

    alice.refresh_from_db()
    assert response.status_code in (200, 302)
    assert alice.check_password("another-long-password")
    assert LogEntry.objects.filter(change_message="Set a new password.").count() == 1


def test_the_set_password_url_refuses_a_staff_account_that_is_not_the_owner(
    client, alice
):
    """django-unfold 0.105.0 gates a detail action's URL on `is_staff` alone unless
    the action carries `permissions=`. Every action in this panel carries it, and
    this is the test that would catch one that stopped."""
    staff = User.objects.create_user(
        username="staff", password=PASSWORD, is_staff=True, is_active=True
    )
    client.force_login(staff)

    response = client.post(
        reverse("admin:accounts_user_set_password", args=[alice.pk]),
        {
            "password": "another-long-password",
            "confirm": "another-long-password",
            "_form_submitted": "1",
        },
    )

    alice.refresh_from_db()
    assert response.status_code == 403
    assert alice.check_password(PASSWORD)


def test_a_change_form_save_writes_djangos_own_audit_row(client, owner, alice):
    client.post(
        reverse("admin:accounts_user_change", args=[alice.pk]),
        {"is_active": "on", "is_staff": "on"},
    )

    alice.refresh_from_db()
    assert alice.is_staff is True
    assert LogEntry.objects.filter(object_id=str(alice.pk), action_flag=CHANGE).exists()


def test_purging_an_attachment_deletes_the_file_and_audits_without_the_capability(
    client, owner, attachment, tmp_path, settings
):
    settings.ATTACHMENTS_ROOT = str(tmp_path)
    stored = tmp_path / attachment.pk[:2] / attachment.pk
    stored.parent.mkdir(parents=True)
    stored.write_bytes(b"ciphertext")

    url = reverse("admin:attachments_attachment_changelist")
    confirmation = _post_action(
        client,
        "admin:attachments_attachment_changelist",
        "purge_attachments",
        [attachment.pk],
    )
    assert confirmation.status_code == 200
    assert (
        _where_it_appears(confirmation.content.decode(), attachment.pk)["visible_text"]
        is False
    )

    client.post(
        url,
        {
            "action": "purge_attachments",
            "index": "0",
            "_selected_action": [attachment.pk],
            "confirmed": "yes",
        },
    )

    assert Attachment.objects.count() == 0
    assert not stored.exists()
    row = LogEntry.objects.get(action_flag=DELETION)
    assert attachment.pk not in row.object_repr
    assert row.object_repr == f"64 KiB attachment of {attachment.created_date}"


def test_the_audit_log_never_shows_the_object_id_column(
    client, owner, attachment, tmp_path, settings
):
    """`LogEntry.object_id` holds a spent attachment capability. The row is Django's
    contract; showing it is not."""
    settings.ATTACHMENTS_ROOT = str(tmp_path)
    client.post(
        reverse("admin:attachments_attachment_changelist"),
        {
            "action": "purge_attachments",
            "index": "0",
            "_selected_action": [attachment.pk],
            "confirmed": "yes",
        },
    )

    body = client.get(reverse("admin:admin_logentry_changelist")).content.decode()

    assert attachment.pk not in body
    model_admin = django_admin.site._registry[LogEntry]
    assert "object_id" not in model_admin.list_display
    assert "object_id" not in model_admin.search_fields
    assert "object_id" not in model_admin.fields


# --- The socket close ------------------------------------------------------------


def test_deactivation_publishes_the_socket_close_after_the_commit(
    client, owner, alice, device, django_capture_on_commit_callbacks, monkeypatch
):
    """The close must run on committed state and must not be able to roll the
    deactivation back, which is what `on_commit` buys. The end-to-end proof that the
    socket actually drops is `realtime/tests/test_revoke_close.py`."""
    alice.is_active = True
    alice.save(update_fields=["is_active"])
    closed = []
    monkeypatch.setattr("accounts.admin.close_device_sockets", closed.append)

    with django_capture_on_commit_callbacks(execute=True) as callbacks:
        _post_action(
            client, "admin:accounts_user_changelist", "deactivate_accounts", [alice.pk]
        )

    assert len(callbacks) == 1
    assert closed == [device.pk]


def test_revocation_publishes_the_socket_close_after_the_commit(
    client, owner, device, django_capture_on_commit_callbacks, monkeypatch
):
    closed = []
    monkeypatch.setattr("devices.admin.close_device_sockets", closed.append)

    with django_capture_on_commit_callbacks(execute=True):
        _post_action(
            client, "admin:devices_device_changelist", "revoke_devices", [device.pk]
        )

    assert closed == [device.pk]


# --- The role model -------------------------------------------------------------


def test_a_staff_account_that_is_not_the_owner_sees_an_empty_panel(
    client, alice, device, attachment
):
    """Two mechanisms have to hold, so both are checked. The sidebar is a static tree
    that renders whatever it holds until each item carries a `permission`, and the
    dashboard callback runs on every index render.
    """
    staff = User.objects.create_user(
        username="staff", password=PASSWORD, is_staff=True, is_active=True
    )
    client.force_login(staff)

    index = client.get(reverse("admin:index"))

    assert index.status_code == 200
    for label in REGISTERED:
        assert (
            reverse(
                f"admin:{apps.get_model(label)._meta.app_label}_"
                f"{apps.get_model(label)._meta.model_name}_changelist"
            )
            not in index.content.decode()
        ), label


def test_the_dashboard_reads_nothing_for_an_account_that_is_not_the_owner(
    client, alice, device, attachment
):
    """The context, not just the page. A template guard alone would leave the counts
    and the pending usernames sitting in the context of a page the wrong person is
    looking at, one template edit away from rendering."""
    staff = User.objects.create_user(
        username="staff", password=PASSWORD, is_staff=True, is_active=True
    )
    client.force_login(staff)

    context = client.get(reverse("admin:index")).context

    assert context["is_owner"] is False
    for leaked in (
        "pending_accounts",
        "active_accounts",
        "live_devices",
        "storage_used",
    ):
        assert leaked not in context, leaked


@pytest.mark.parametrize("name", CHANGELISTS)
def test_a_staff_account_that_is_not_the_owner_gets_the_designed_403(client, name):
    staff = User.objects.create_user(
        username="staff", password=PASSWORD, is_staff=True, is_active=True
    )
    client.force_login(staff)

    response = client.get(reverse(name))

    assert response.status_code == 403
    # The project's `templates/403.html`, not Django's bare plain-text page.
    assert "This back office has one operator" in response.content.decode()


# --- Hardening -------------------------------------------------------------------


def test_the_session_is_bounded_at_eight_hours_and_at_browser_close(client, owner):
    from django.conf import settings

    assert settings.SESSION_COOKIE_AGE == 8 * 60 * 60
    assert settings.SESSION_EXPIRE_AT_BROWSER_CLOSE is True

    client.get(reverse("admin:index"))
    cookie = client.cookies[settings.SESSION_COOKIE_NAME]
    # Neither `Max-Age` nor `Expires` is set, so the cookie dies with the browser.
    assert not cookie["max-age"]
    assert not cookie["expires"]
    # The record on the server still carries the eight-hour ceiling.
    assert client.session.get_expiry_age() == 8 * 60 * 60


def test_signing_in_lands_on_the_dashboard(client):
    """django-unfold 0.105.0's login template drops the hidden `next` field Django's
    own carries, so without `LOGIN_REDIRECT_URL` a sign-in lands on
    `/accounts/profile/` — which this deployment answers with the API's `not_found`
    envelope. The first thing the operator ever does must not be a 404."""
    User.objects.create_superuser(username="owner", password=PASSWORD)

    response = client.post(
        reverse("admin:login"), {"username": "owner", "password": PASSWORD}
    )

    assert response.status_code == 302
    assert response["Location"] == reverse("admin:index")


def test_a_repeated_failed_login_locks_the_name(client):
    from core.lockout import FAILURE_THRESHOLD

    User.objects.create_superuser(username="owner", password=PASSWORD)
    url = reverse("admin:login")

    for _ in range(FAILURE_THRESHOLD):
        client.post(url, {"username": "owner", "password": "wrong"})

    # The right password now, and it is still refused.
    response = client.post(url, {"username": "owner", "password": PASSWORD})

    assert response.status_code == 200
    assert "Too many sign-in attempts" in response.content.decode()
    assert "_auth_user_id" not in client.session


def test_a_locked_name_never_reaches_the_password_hash(client, monkeypatch):
    """The refusal happens in the form's `clean()`, before `authenticate()`. An
    attacker must not be able to spend this server's Argon2 budget on a name that is
    already locked."""
    from core.lockout import FAILURE_THRESHOLD

    User.objects.create_superuser(username="owner", password=PASSWORD)
    url = reverse("admin:login")
    for _ in range(FAILURE_THRESHOLD):
        client.post(url, {"username": "owner", "password": "wrong"})

    called = []
    monkeypatch.setattr(
        "django.contrib.auth.forms.authenticate",
        lambda *args, **kwargs: called.append(1),
    )
    client.post(url, {"username": "owner", "password": PASSWORD})

    assert called == []


def test_the_lock_lifts_for_a_different_name(client):
    from core.lockout import FAILURE_THRESHOLD

    User.objects.create_superuser(username="owner", password=PASSWORD)
    User.objects.create_superuser(username="second", password=PASSWORD)
    url = reverse("admin:login")
    for _ in range(FAILURE_THRESHOLD):
        client.post(url, {"username": "owner", "password": "wrong"})

    client.post(url, {"username": "second", "password": PASSWORD})

    assert "_auth_user_id" in client.session


def test_a_successful_login_forgets_the_earlier_failures(client):
    from core.lockout import FAILURE_THRESHOLD

    User.objects.create_superuser(username="owner", password=PASSWORD)
    url = reverse("admin:login")
    for _ in range(FAILURE_THRESHOLD - 1):
        client.post(url, {"username": "owner", "password": "wrong"})

    client.post(url, {"username": "owner", "password": PASSWORD})
    client.logout()
    for _ in range(FAILURE_THRESHOLD - 1):
        client.post(url, {"username": "owner", "password": "wrong"})
    response = client.post(url, {"username": "owner", "password": PASSWORD})

    assert response.status_code == 302
    assert "_auth_user_id" in client.session


def test_the_lockout_writes_no_database_row(client):
    """The state lives in Redis and nowhere else (invariant 7). A failed-attempt
    table would be a login record at rest."""
    from core.lockout import FAILURE_THRESHOLD

    User.objects.create_superuser(username="owner", password=PASSWORD)
    with CaptureQueriesContext(connection) as queries:
        for _ in range(FAILURE_THRESHOLD + 1):
            client.post(reverse("admin:login"), {"username": "owner", "password": "x"})

    assert not [q for q in queries.captured_queries if "INSERT" in q["sql"].upper()]


def test_the_lockout_refuses_when_redis_cannot_be_read(client, monkeypatch):
    """Fails closed, like the rate limiter (ADR-0010): a control whose purpose is to
    refuse cannot answer "allow" when it does not know."""
    import redis

    User.objects.create_superuser(username="owner", password=PASSWORD)

    class Unreachable:
        def ttl(self, *args, **kwargs):
            raise redis.ConnectionError("redis is down")

    monkeypatch.setattr("core.lockout._redis", lambda: Unreachable())
    response = client.post(
        reverse("admin:login"), {"username": "owner", "password": PASSWORD}
    )

    assert response.status_code == 200
    assert "_auth_user_id" not in client.session


# Set by `detonate` when a planted Redis value is deserialized as a Python object.
DETONATED = []


def detonate():
    DETONATED.append(True)


class Detonator:
    """A pickle whose unpickling calls `detonate`, the shape of a payload that a
    writer of the Redis instance would plant under a key this process reads."""

    def __reduce__(self):
        return (detonate, ())


def test_a_value_planted_in_redis_is_never_deserialized(client):
    """The lockout reads Redis on every sign-in attempt, under a key an outside
    party can compute from the submitted name. Django's own Redis cache backend
    unpickles every value it reads, so a writer of the instance — Redis listens on
    loopback of a shared host — would run code in this process the moment the
    operator's name was tried. The state is read as bytes and never as an object.

    Planted under both spellings: the raw key this module reads, and the
    `:1:`-prefixed key the cache framework would read, so a return to
    `django.core.cache` fails here.
    """
    import pickle

    import redis
    from django.conf import settings

    from core.lockout import ADMIN, _key

    DETONATED.clear()
    payload = pickle.dumps(Detonator())
    store = redis.Redis.from_url(settings.REDIS_URL)
    try:
        for key in (_key(ADMIN, "lock", "owner"), f":1:{_key(ADMIN, 'lock', 'owner')}"):
            store.set(key, payload, ex=60)
        response = client.post(
            reverse("admin:login"), {"username": "owner", "password": PASSWORD}
        )
    finally:
        store.close()

    assert DETONATED == []
    # The planted bytes were read: a non-empty value under the lock key is a lock.
    assert response.status_code == 200
    assert "Too many sign-in attempts" in response.content.decode()


# --- Assets ----------------------------------------------------------------------


def test_no_template_or_collected_asset_fetches_from_another_host():
    """Every asset the panel renders with is served by this deployment. A font from
    a CDN would be a runtime call to a third party on the one surface the operator
    uses during a shutdown (ADR-0011, decision 9).

    Both halves of what ships: the project's own templates, and the whole tree
    `collectstatic` would copy. The staticfiles finders walk exactly that tree, so
    this proves the collected result without writing one to disk.

    Matching the shape of a fetch is also what lets the licence-comment URLs
    django-unfold ships inside its bundled JavaScript pass while a real
    `<link href="https://...">` would not.
    """
    from django.conf import settings

    offenders = []

    for template_dir in settings.TEMPLATES[0]["DIRS"]:
        for path in template_dir.rglob("*.html"):
            if EXTERNAL_FETCH.search(path.read_text()):
                offenders.append(str(path))

    scanned = 0
    for finder in finders.get_finders():
        for path, storage in finder.list([]):
            # Markup and stylesheets are where a page declares what to load, and
            # they are what a CDN font or theme would arrive through. Bundled
            # third-party JavaScript is excluded on purpose: Django's own
            # `admin/js/vendor/xregexp/xregexp.js` carries `<a href="http://...">`
            # inside a documentation comment, which is a string in a comment and not
            # a fetch. This run's shell gate sweeps every file, JavaScript included,
            # for the CDN vendor names.
            if not path.endswith((".css", ".html", ".svg")):
                continue
            scanned += 1
            with storage.open(path) as handle:
                if EXTERNAL_FETCH.search(handle.read().decode("utf-8", "replace")):
                    offenders.append(path)

    assert offenders == []
    # Without this, the assertion above passes just as well on an empty walk.
    assert scanned > 10, scanned


def test_collectstatic_can_run():
    """Gate 8 of this run, and the step the panel's CSS and fonts depend on: without
    it nginx serves an empty `static_root` and the panel renders unstyled.

    The count is asserted rather than the absence of an exception. A finder
    configuration that resolved to nothing would raise nothing either, and the panel
    would render unstyled exactly as if the step had never run — which is the failure
    this is here to catch."""
    out = StringIO()
    call_command("collectstatic", "--noinput", "--dry-run", verbosity=1, stdout=out)

    assert "0 static files" not in out.getvalue(), out.getvalue()
    assert "unfold" in out.getvalue().lower() or "static files" in out.getvalue()


# --- Retention -------------------------------------------------------------------


def test_the_maintenance_command_deletes_only_audit_rows_past_their_window(owner):
    from django.conf import settings

    old = LogEntry.objects.create(
        user=owner, object_repr="old", action_flag=ADDITION, change_message="x"
    )
    recent = LogEntry.objects.create(
        user=owner, object_repr="recent", action_flag=ADDITION, change_message="x"
    )
    LogEntry.objects.filter(pk=old.pk).update(
        action_time=timezone.now()
        - timedelta(days=settings.ADMIN_AUDIT_RETENTION_DAYS + 1)
    )
    LogEntry.objects.filter(pk=recent.pk).update(
        action_time=timezone.now()
        - timedelta(days=settings.ADMIN_AUDIT_RETENTION_DAYS - 1)
    )

    call_command("prune", verbosity=0)

    assert list(LogEntry.objects.values_list("pk", flat=True)) == [recent.pk]


def test_the_retention_window_is_configured_and_documented():
    from django.conf import settings

    assert settings.ADMIN_AUDIT_RETENTION_DAYS == 30
    assert (
        "ADMIN_AUDIT_RETENTION_DAYS" in (settings.BASE_DIR / ".env.example").read_text()
    )


# --- The set-password dialog -----------------------------------------------------


def test_the_set_password_dialog_refuses_two_that_do_not_match(client, owner, alice):
    """A mistyped confirmation must leave the account exactly as it was: the
    operator is the only one who can undo a password they did not mean to set."""
    response = client.post(
        reverse("admin:accounts_user_set_password", args=[alice.pk]),
        {
            "password": "another-long-password",
            "confirm": "a-different-long-password",
            "_form_submitted": "1",
        },
    )

    alice.refresh_from_db()
    assert response.status_code == 200
    assert alice.check_password(PASSWORD)
    assert LogEntry.objects.filter(change_message="Set a new password.").count() == 0


def test_the_set_password_dialog_holds_the_same_rules_as_registration(
    client, owner, alice
):
    """The dialog runs Django's configured validators, so the panel cannot set a
    password the client registration path would have refused."""
    response = client.post(
        reverse("admin:accounts_user_set_password", args=[alice.pk]),
        {"password": "short", "confirm": "short", "_form_submitted": "1"},
    )

    alice.refresh_from_db()
    assert response.status_code == 200
    assert alice.check_password(PASSWORD)
    assert LogEntry.objects.count() == 0


def test_the_set_password_dialog_refuses_an_empty_submission(client, owner, alice):
    """The field is required, so a submission with nothing in it is the form
    saying so — not a password of zero length reaching the validators."""
    response = client.post(
        reverse("admin:accounts_user_set_password", args=[alice.pk]),
        {"password": "", "confirm": "", "_form_submitted": "1"},
    )

    alice.refresh_from_db()
    assert response.status_code == 200
    assert alice.check_password(PASSWORD)
    assert LogEntry.objects.count() == 0


# --- The change form -------------------------------------------------------------


def test_deactivating_on_the_change_form_closes_the_sockets_after_the_commit(
    client, owner, alice, device, django_capture_on_commit_callbacks, monkeypatch
):
    """The bulk action is not the only way to deactivate an account: the change
    form is, and a socket authenticated once at connect would otherwise keep
    relaying until it happened to drop."""
    alice.is_active = True
    alice.save(update_fields=["is_active"])
    closed = []
    monkeypatch.setattr("accounts.admin.close_device_sockets", closed.append)

    with django_capture_on_commit_callbacks(execute=True) as callbacks:
        response = client.post(reverse("admin:accounts_user_change", args=[alice.pk]), {})

    alice.refresh_from_db()
    assert response.status_code == 302
    assert alice.is_active is False
    assert len(callbacks) == 1
    assert closed == [device.pk]


def test_activating_on_the_change_form_closes_nothing(
    client, owner, alice, device, django_capture_on_commit_callbacks, monkeypatch
):
    """The other side of the same branch: a save that switches activation on has
    no session to end."""
    closed = []
    monkeypatch.setattr("accounts.admin.close_device_sockets", closed.append)

    with django_capture_on_commit_callbacks(execute=True) as callbacks:
        client.post(
            reverse("admin:accounts_user_change", args=[alice.pk]), {"is_active": "on"}
        )

    alice.refresh_from_db()
    assert alice.is_active is True
    assert callbacks == []
    assert closed == []


# --- An action with nothing to do ------------------------------------------------


def test_revoking_the_devices_of_an_account_that_has_none_writes_nothing(
    client, owner, alice
):
    """An action that changed nothing must say so rather than claim a revocation:
    an audit row for work that never happened is a false record."""
    response = _post_action(
        client, "admin:accounts_user_changelist", "revoke_all_devices", [alice.pk]
    )

    assert response.status_code == 302
    assert LogEntry.objects.count() == 0
    assert [str(message) for message in get_messages(response.wsgi_request)] == [
        "Nothing to do: no selected row needed the change."
    ]


def test_revoking_the_devices_of_one_account_leaves_another_accounts_alone(
    client, owner, alice, device
):
    other = User.objects.create_user(username="carol", password=PASSWORD)
    theirs = Device.objects.create(
        user=other,
        ik_pub=b"k" * 32,
        spk_id=1,
        spk_pub=b"k" * 32,
        spk_sig=b"s" * 64,
        registration_id=202,
    )

    _post_action(
        client, "admin:accounts_user_changelist", "revoke_all_devices", [alice.pk]
    )

    device.refresh_from_db()
    theirs.refresh_from_db()
    assert device.revoked_date is not None
    assert theirs.revoked_date is None
