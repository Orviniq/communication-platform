"""The shared parts of the panel, called directly.

`accounts/tests/test_admin.py` drives the pages an operator clicks;
`core/tests/test_panel_through_the_seam.py` drives one of them through the
middleware in front of Django. This file is the layer under both: the two label
formatters, the audit writer every action calls instead of trusting the framework,
the one-line role model, the deny-by-default permissions a model inherits by being
registered at all, and the dashboard's arithmetic — including the division it must
not perform.
"""

import pytest
from django.contrib import admin as django_admin
from django.contrib.admin.models import ADDITION, CHANGE, DELETION, LogEntry
from django.contrib.auth.models import AnonymousUser
from django.contrib.contenttypes.models import ContentType
from django.test import RequestFactory
from django.utils import timezone

from accounts.models import User
from attachments.models import Attachment
from core.buckets import ATTACHMENT_BUCKETS
from core.panel import (
    PanelModelAdmin,
    audit,
    dashboard,
    is_owner,
    size_label,
    storage_label,
)
from devices.models import Device

pytestmark = pytest.mark.django_db

PASSWORD = "correct-horse-battery-staple"


def request_for(user):
    request = RequestFactory().get("/")
    request.user = user
    return request


@pytest.fixture
def owner():
    return User.objects.create_superuser(username="owner", password=PASSWORD)


@pytest.fixture
def panel_admin():
    """The base class as a registered model admin sees it. `LogEntry` is the model
    it is registered against in production, so the instance is a real one."""
    return PanelModelAdmin(LogEntry, django_admin.site)


class TestSizeLabel:
    @pytest.mark.parametrize("nbytes", ATTACHMENT_BUCKETS)
    def test_every_bucket_has_a_label_the_operator_reads(self, nbytes):
        """Every stored length is already one of the buckets, so this is a rename
        rather than a rounding."""
        assert size_label(nbytes) in {
            "64 KiB",
            "256 KiB",
            "1 MiB",
            "4 MiB",
            "16 MiB",
            "64 MiB",
        }

    def test_the_labels_are_the_bucket_set_in_order(self):
        assert [size_label(size) for size in sorted(ATTACHMENT_BUCKETS)] == [
            "64 KiB",
            "256 KiB",
            "1 MiB",
            "4 MiB",
            "16 MiB",
            "64 MiB",
        ]

    @pytest.mark.parametrize("nbytes", [0, 1, 65535, 65537, 99999999])
    def test_a_length_outside_the_bucket_set_is_named_in_bytes(self, nbytes):
        """An unknown value can only mean the bucket set moved, and the raw count
        is the honest answer then — not the nearest label, which would tell the
        operator a row is something it is not."""
        assert size_label(nbytes) == f"{nbytes} B"


class TestStorageLabel:
    @pytest.mark.parametrize(
        "nbytes, expected",
        [
            (0, "0 B"),
            (1023, "1023 B"),
            (1024, "1.0 KiB"),
            (1536, "1.5 KiB"),
            (1024**2, "1.0 MiB"),
            (1024**3, "1.0 GiB"),
        ],
    )
    def test_a_total_is_one_short_string(self, nbytes, expected):
        assert storage_label(nbytes) == expected

    def test_the_unit_changes_exactly_at_the_boundary(self):
        """1023 bytes is bytes and 1024 is a kibibyte: the loop's `< 1024` is what
        decides, and an off-by-one there mislabels every quota on the page."""
        assert storage_label(1023).endswith(" B")
        assert storage_label(1024).endswith(" KiB")

    def test_a_total_above_the_largest_unit_stays_in_that_unit(self):
        """The rare case: the loop has nowhere left to go, so a petabyte is named
        in gibibytes rather than falling off the end and returning `None`."""
        assert storage_label(1024**4) == "1024.0 GiB"


class TestAudit:
    def test_one_row_is_written_for_each_object_touched(self, owner):
        """Django writes these itself for a change-form save and for a delete, and
        writes nothing at all for a bulk action — so every action calls this."""
        accounts = [
            User.objects.create_user(username=f"user{n}", password=PASSWORD)
            for n in range(3)
        ]

        written = audit(request_for(owner), accounts, CHANGE, "Activated.")

        assert written == 3
        rows = LogEntry.objects.filter(action_flag=CHANGE)
        assert rows.count() == 3
        assert set(rows.values_list("object_id", flat=True)) == {
            str(account.pk) for account in accounts
        }
        assert {row.change_message for row in rows} == {"Activated."}
        assert {row.user_id for row in rows} == {owner.pk}

    def test_an_action_that_touched_nothing_writes_nothing(self, owner):
        """The boundary an empty selection reaches. Reading the content type off
        the first row would be an `IndexError` here."""
        written = audit(request_for(owner), User.objects.none(), CHANGE, "Activated.")

        assert written == 0
        assert LogEntry.objects.count() == 0

    def test_the_object_is_named_by_the_hook_and_never_by_str(self, owner):
        """`str(Attachment)` is the capability id that downloads the bytes, and the
        audit log outlives the row it describes."""
        attachment = Attachment.objects.create(size=65536)

        audit(
            request_for(owner),
            [attachment],
            DELETION,
            "Purged.",
            repr_of=lambda obj: f"attachment of {obj.size} bytes",
        )

        row = LogEntry.objects.get()
        assert row.object_repr == "attachment of 65536 bytes"
        assert attachment.id not in row.object_repr

    def test_a_long_name_is_truncated_to_the_column(self, owner):
        """`object_repr` is 200 characters wide, and a name longer than that is a
        database error in the middle of an action that already ran."""
        audit(
            request_for(owner), [owner], DELETION, "Deleted.", repr_of=lambda _: "x" * 500
        )

        assert len(LogEntry.objects.get().object_repr) == 200

    def test_the_row_names_the_model_that_was_touched(self, owner):
        audit(request_for(owner), [owner], ADDITION, "Created.")

        row = LogEntry.objects.get()
        assert row.content_type_id == ContentType.objects.get_for_model(User).pk

    def test_the_row_carries_the_day_of_the_act_and_never_the_second(self, owner):
        """`LogEntry.action_time` is Django's own second-granularity column, and
        the schema of a contributed application is not this project's to change —
        so the coarsening is at the write. Two acts on one day are not orderable
        from the log, which is what `backend/SECURITY.md` states (ADR-0025)."""
        audit(request_for(owner), [owner], CHANGE, "Activated.")

        stamped = LogEntry.objects.get().action_time

        assert stamped == timezone.now().replace(
            hour=0, minute=0, second=0, microsecond=0
        )

    def test_two_acts_on_one_day_carry_the_same_stamp(self, owner):
        """The property the coarsening exists for. Two rows a minute apart that
        differed by a minute would put the operator's working pattern in the log."""
        audit(request_for(owner), [owner], CHANGE, "Activated.")
        audit(request_for(owner), [owner], CHANGE, "Deactivated.")

        assert len(set(LogEntry.objects.values_list("action_time", flat=True))) == 1


class TestIsOwner:
    def test_the_active_superuser_is_the_owner(self, owner):
        assert is_owner(request_for(owner)) is True

    def test_a_staff_account_that_is_not_a_superuser_is_not(self):
        staff = User.objects.create_user(
            username="helper", password=PASSWORD, is_active=True, is_staff=True
        )

        assert is_owner(request_for(staff)) is False

    def test_a_deactivated_superuser_is_not(self):
        """Deactivation is how the operator removes access, and it has to remove
        this one too."""
        retired = User.objects.create_superuser(username="was-owner", password=PASSWORD)
        retired.is_active = False

        assert is_owner(request_for(retired)) is False

    def test_an_anonymous_visitor_is_not(self):
        """The sidebar names this by dotted path, and it is rendered before the
        login redirect has necessarily happened."""
        assert is_owner(request_for(AnonymousUser())) is False


class TestPanelModelAdminDefaults:
    """Denial on all four writes is the default a model takes by being registered:
    a page that mutates something is opted into by the class that owns it."""

    def test_no_registered_model_may_be_added_changed_or_deleted_by_default(
        self, panel_admin, owner
    ):
        request = request_for(owner)

        assert panel_admin.has_add_permission(request) is False
        assert panel_admin.has_change_permission(request) is False
        assert panel_admin.has_delete_permission(request) is False

    def test_reading_is_the_owner_and_nobody_else(self, panel_admin, owner):
        staff = User.objects.create_user(
            username="helper", password=PASSWORD, is_active=True, is_staff=True
        )

        assert panel_admin.has_view_permission(request_for(owner)) is True
        assert panel_admin.has_module_permission(request_for(owner)) is True
        assert panel_admin.has_view_permission(request_for(staff)) is False
        assert panel_admin.has_module_permission(request_for(staff)) is False

    def test_a_delete_through_the_framework_is_audited_by_the_panel(
        self, panel_admin, owner
    ):
        """Django's own delete paths write `str(obj)` for the label. Overriding
        `log_deletions` covers the bulk action, the single-object delete view and
        anything either grows into."""
        stored = [
            Attachment.objects.create(size=min(ATTACHMENT_BUCKETS)) for _ in range(2)
        ]

        written = panel_admin.log_deletions(
            request_for(owner),
            Attachment.objects.filter(pk__in=[item.pk for item in stored]),
        )

        assert written == 2
        assert LogEntry.objects.filter(action_flag=DELETION).count() == 2

    def test_a_change_form_save_is_audited_by_the_panel_at_day_granularity(
        self, panel_admin, owner
    ):
        """The one write path the framework still owned. Django's `log_change`
        calls `LogEntry.objects.log_actions`, which stamps `action_time` from the
        model default — the second the save happened."""
        written = panel_admin.log_change(request_for(owner), owner, "Changed.")

        row = LogEntry.objects.get(action_flag=CHANGE)
        assert written == 1
        assert row.object_repr == panel_admin.panel_repr(owner)
        assert row.action_time == timezone.now().replace(
            hour=0, minute=0, second=0, microsecond=0
        )

    def test_the_default_label_of_an_object_is_its_own_string(self, panel_admin, owner):
        """`panel_repr` is the hook a page overrides where `str(obj)` would be a
        capability; the base answer is the plain string."""
        assert panel_admin.panel_repr(owner) == str(owner)


class TestDashboard:
    def test_an_account_that_is_not_the_owner_is_told_nothing(self):
        """Not a smaller page: the counts and the pending usernames are exactly
        what a staff account that is not the owner must not see."""
        staff = User.objects.create_user(
            username="helper", password=PASSWORD, is_active=True, is_staff=True
        )

        context = dashboard(request_for(staff), {})

        assert context == {"title": "Overview", "is_owner": False}

    def test_the_owner_gets_every_number_and_the_pending_list(self, owner):
        waiting = User.objects.create_user(username="waiting", password=PASSWORD)
        Device.objects.create(
            user=owner,
            ik_pub=b"ik",
            spk_id=1,
            spk_pub=b"spk",
            spk_sig=b"sig",
            registration_id=1,
        )
        Device.objects.create(
            user=owner,
            ik_pub=b"ik",
            spk_id=2,
            spk_pub=b"spk",
            spk_sig=b"sig",
            registration_id=2,
            revoked_date="2026-01-01",
        )

        context = dashboard(request_for(owner), {})

        assert context["is_owner"] is True
        assert context["pending_count"] == 1
        assert [account.pk for account in context["pending_accounts"]] == [waiting.pk]
        assert context["active_accounts"] == 1
        assert context["live_devices"] == 1  # the revoked one is not live

    def test_the_storage_card_reads_the_disk_rather_than_a_per_account_quota(self, owner):
        """No account carries a lifetime quota any more (ADR-0025), so the number
        the operator watches is how full the filesystem is: that is what
        `ATTACH_MIN_FREE_BYTES` refuses uploads against."""
        Attachment.objects.create(size=500)

        context = dashboard(request_for(owner), {})

        assert context["storage_used"] == "500 B"
        assert context["storage_free"].endswith(("KiB", "MiB", "GiB"))
        assert 0 <= context["storage_percent"] <= 100

    def test_a_filesystem_of_zero_bytes_reports_zero_rather_than_dividing_by_it(
        self, owner, monkeypatch
    ):
        """The boundary the page would crash on. `statvfs` reports zero blocks for
        some pseudo-filesystems, and the first page after every sign-in must not be
        a `ZeroDivisionError`."""
        monkeypatch.setattr("attachments.services.disk_space", lambda: (0, 0))

        context = dashboard(request_for(owner), {})

        assert context["storage_percent"] == 0
        assert context["storage_free"] == "0 B"

    def test_every_number_is_a_link_to_the_list_behind_it(self, owner):
        context = dashboard(request_for(owner), {})

        for key in ("accounts_url", "devices_url", "attachments_url"):
            assert context[key].endswith("/"), key
        assert context["accounts_url"] != context["devices_url"]

    def test_the_page_reads_nothing_at_all_for_a_visitor(self, django_assert_num_queries):
        """An anonymous request reaches the callback before the login redirect on
        some paths, and a query per render would be a way to load the database
        without signing in."""
        with django_assert_num_queries(0):
            context = dashboard(request_for(AnonymousUser()), {})

        assert context["is_owner"] is False
