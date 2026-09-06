"""The shared parts of the admin panel: the base model admin, the audit writer,
the display helpers, and the dashboard.

The panel is a support surface for one operator, and the set of things it may show
is a security boundary rather than a convenience (ADR-0011). Two rules hold across
every page below:

* Nothing renders a ciphertext blob, a key, a signature, a password hash or a
  token. `Attachment.id` is a token — it is the bearer capability that fetches the
  bytes — so it never becomes a column, a link, a search field or an audit label.
* Every administrative act writes one `LogEntry` row for each object it touched,
  including the bulk actions Django itself would log nothing for.
"""

from django.contrib.admin.models import CHANGE, DELETION, LogEntry
from django.contrib.contenttypes.models import ContentType
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from unfold.admin import ModelAdmin

# Ordered smallest first; `core/buckets.py` holds the same list, and an upload is
# refused unless its length is exactly one of them.
_SIZE_LABELS = (
    (65536, "64 KiB"),
    (262144, "256 KiB"),
    (1048576, "1 MiB"),
    (4194304, "4 MiB"),
    (16777216, "16 MiB"),
    (67108864, "64 MiB"),
)


def size_label(nbytes):
    """The stored length as the bucket an operator recognises.

    Every stored length is already one of the buckets, so this is a rename rather
    than a rounding. An unknown value can only mean the bucket set moved, and
    naming the raw byte count is the honest answer then.
    """
    for size, label in _SIZE_LABELS:
        if nbytes == size:
            return label
    return f"{nbytes} B"


def storage_label(nbytes):
    """Total bytes as one short human string, for the dashboard."""
    for unit in ("B", "KiB", "MiB", "GiB"):
        if nbytes < 1024 or unit == "GiB":
            return f"{nbytes:.0f} {unit}" if unit == "B" else f"{nbytes:.1f} {unit}"
        nbytes /= 1024


def audit_day():
    """Midnight UTC of the day an administrative act happened on.

    `LogEntry.action_time` is Django's own second-granularity column, and the
    schema of a contributed application is not this project's to change — so the
    coarsening happens at the write instead. Every row this panel produces carries
    the day and nothing finer (ADR-0025), which is what the seizure yield in
    `backend/SECURITY.md` states: the log says what the operator did and on which
    day, and never at which minute.
    """
    return timezone.now().replace(hour=0, minute=0, second=0, microsecond=0)


def audit(request, objects, action_flag, summary, repr_of=str):
    """One `LogEntry` row for each object an administrative act touched.

    Django writes these itself for a change-form save and for a delete, and writes
    nothing at all for a bulk action — so every action in this panel calls this
    instead of relying on the framework.

    `repr_of` names the object in the operator's language. It is a hook rather
    than `str(obj)` because `str(Attachment)` is the capability id, and the audit
    log outlives the row it describes.
    """
    rows = list(objects)
    if not rows:
        return 0
    content_type = ContentType.objects.get_for_model(rows[0], for_concrete_model=False)
    day = audit_day()
    LogEntry.objects.bulk_create(
        [
            LogEntry(
                user_id=request.user.pk,
                content_type_id=content_type.pk,
                object_id=obj.pk,
                object_repr=repr_of(obj)[:200],
                action_flag=action_flag,
                change_message=summary,
                action_time=day,
            )
            for obj in rows
        ]
    )
    return len(rows)


class PanelModelAdmin(ModelAdmin):
    """The defaults every registered model takes.

    Denial is the default on all four write permissions: a page that mutates
    something is opted into by the class that owns it, so a model registered later
    without thought is read-only rather than editable. Read is superuser-only,
    which is the whole role model (ADR-0011): a staff account that is not the owner
    gets an index with nothing on it.
    """

    list_per_page = 25
    list_filter_submit = True
    warn_unsaved_form = True

    def panel_repr(self, obj):
        """How the audit log names this object. Never a blob, a key or a token."""
        return str(obj)

    def has_module_permission(self, request):
        # Also what keeps a model out of the command palette: the palette searches
        # `get_app_list`, and this is the hook that decides what that list holds.
        return is_owner(request)

    def has_view_permission(self, request, obj=None):
        return is_owner(request)

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def log_change(self, request, obj, message):
        """The change-form save, routed through `audit`.

        Django's own implementation calls `LogEntry.objects.log_actions`, which
        stamps `action_time` from the model default — the second the save
        happened. Every row this panel writes carries the day instead, and this
        was the one write path the framework still owned. Confirmed against
        django-unfold 0.105.0: `log_change`, `log_deletions` and `log_addition`
        all come from Django's own `ModelAdmin`, so nothing in the theme shadows
        this override.
        """
        return audit(request, [obj], CHANGE, message, repr_of=self.panel_repr)

    def log_deletions(self, request, queryset):
        """Django's own delete paths, routed through `panel_repr`.

        The framework writes `str(obj)` here, which for an attachment is its
        capability id. Overriding one method covers the bulk action, the
        single-object delete view and anything either grows into.
        """
        return audit(
            request,
            queryset,
            DELETION,
            _("Deleted from the panel."),
            repr_of=self.panel_repr,
        )


def is_owner(request):
    """The whole role model: one superuser owner (ADR-0011).

    Public because `UNFOLD["SIDEBAR"]` names it as a dotted path. The sidebar tree
    is a static list of links that renders whatever it holds, so without a
    `permission` on each item a staff account that is not the owner would see the
    full navigation and a 403 behind every entry.
    """
    return request.user.is_active and request.user.is_superuser


def dashboard(request, context):
    """The first page after login, as five numbers and the accounts still waiting.

    Nothing is read at all for an account that is not the owner. For the owner,
    each number is one query and no number is a per-row lookup, because this is the
    page every login lands on. The pending list is the same query as its own count,
    and it carries the rows the one-click activation posts back.
    """
    from django.db.models import Sum
    from django.urls import reverse

    from accounts.models import User
    from attachments.models import Attachment
    from attachments.services import disk_space
    from devices.models import Device

    # `AdminSite.index_title` is "Site administration", which names the software
    # rather than the job. The callback runs after `index()` sets it, so this is the
    # place it can be replaced.
    context["title"] = _("Overview")
    context["is_owner"] = is_owner(request)
    if not context["is_owner"]:
        # A staff account that is not the owner gets an empty panel (ADR-0011), and
        # this page is part of the panel: the counts and the pending usernames are
        # exactly what it must not see. The callback runs for every index render, so
        # the check belongs here rather than in the template alone.
        return context

    pending = list(User.objects.filter(is_active=False).order_by("created_date", "id"))
    active_accounts = User.objects.filter(is_active=True).count()
    live_devices = Device.objects.filter(revoked_date__isnull=True).count()
    stored = Attachment.objects.aggregate(total=Sum("size"))["total"] or 0
    # The filesystem is the ceiling now that no account carries a lifetime quota
    # (ADR-0025): what stops an upload is `ATTACH_MIN_FREE_BYTES` of free space, so
    # the number the operator has to watch is how full the disk is rather than how
    # much of a per-account allowance is spent.
    free, capacity = disk_space()

    context.update(
        {
            "pending_accounts": pending,
            "pending_count": len(pending),
            "active_accounts": active_accounts,
            # Every number on the page is a link to the list behind it, and the
            # pending form posts its activation to the accounts changelist, which is
            # the one place the action and its audit row live.
            "accounts_url": reverse("admin:accounts_user_changelist"),
            "devices_url": reverse("admin:devices_device_changelist"),
            "attachments_url": reverse("admin:attachments_attachment_changelist"),
            "live_devices": live_devices,
            "storage_used": storage_label(stored),
            "storage_free": storage_label(free),
            "storage_percent": round((capacity - free) * 100 / capacity, 1)
            if capacity
            else 0,
        }
    )
    return context
