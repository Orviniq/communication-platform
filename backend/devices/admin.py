"""The devices page: which devices an account has, and revocation for one of them.

A device row is mostly key material — an identity key, a signed prekey, two
signatures, a post-quantum pair — and a label that is ciphertext. None of it
reaches this page. What the operator needs to answer "I lost my phone" is the
account, the day the device was added, whether it is still live, and a button. The
server records no activity day (ADR-0024), so the panel shows none.
"""

from django.contrib import admin, messages
from django.contrib.admin.models import CHANGE
from django.db import transaction
from django.utils.translation import gettext_lazy as _
from django.utils.translation import ngettext
from unfold.decorators import display

from core.panel import PanelModelAdmin, audit
from devices.models import Device
from devices.services import revoke as revoke_device
from realtime.bus import close_device_sockets


class RevokedFilter(admin.SimpleListFilter):
    """`revoked_date` read as the two words the operator thinks in.

    Django's own filter for a nullable date offers "Has date" and "No date", which
    describes the column rather than the device.
    """

    title = _("state")
    parameter_name = "state"

    def lookups(self, request, model_admin):
        return (("live", _("Live")), ("revoked", _("Revoked")))

    def queryset(self, request, queryset):
        if self.value() == "live":
            return queryset.filter(revoked_date__isnull=True)
        if self.value() == "revoked":
            return queryset.filter(revoked_date__isnull=False)
        return queryset


@admin.register(Device)
class DeviceAdmin(PanelModelAdmin):
    """Read-only, plus one action.

    Nothing on a device is editable from here: the label is ciphertext the client
    owns, and every other column is key material the server never interprets.
    """

    list_display = ("id", "account", "state", "created_date", "revoked_date")
    list_display_links = ("id",)
    list_filter = (RevokedFilter, "created_date", "user")
    search_fields = ("user__username",)
    ordering = ("user__username", "-created_date")
    date_hierarchy = "created_date"
    fields = ("id", "account", "state", "created_date", "revoked_date")
    readonly_fields = fields
    # The account column would otherwise be one query for each row.
    list_select_related = ("user",)
    actions = ("revoke_devices",)

    @display(description=_("Account"), ordering="user__username")
    def account(self, obj):
        return obj.user.get_username()

    @display(
        description=_("State"),
        ordering="revoked_date",
        label={"live": "success", "revoked": "danger"},
    )
    def state(self, obj):
        if obj.revoked_date is None:
            return ("live", _("Live"))
        return ("revoked", _("Revoked"))

    def has_delete_permission(self, request, obj=None):
        # A device row is deleted by nothing: revocation is the operation, and it
        # keeps the row so the account can still see that the device existed.
        return False

    def panel_repr(self, obj):
        return f"device {obj.pk}"

    @admin.action(description=_("Revoke the selected devices"), permissions=["change"])
    def revoke_devices(self, request, queryset):
        """Through `devices.services.revoke`, which is the same function the API's
        own revocation calls: one write path, so the tokens, the one-time key
        material and the mailbox all go exactly as they do for a client."""
        revoked = 0
        with transaction.atomic():
            for device in queryset.filter(revoked_date__isnull=True).select_related(
                "user"
            ):
                revoke_device(device.user_id, device.pk)
                audit(
                    request,
                    [device],
                    CHANGE,
                    _("Revoked."),
                    repr_of=self.panel_repr,
                )
                # After the commit, on committed state, and never inside the unit:
                # a bus that is down must not roll the revocation back.
                transaction.on_commit(
                    lambda device_id=device.pk: close_device_sockets(device_id)
                )
                revoked += 1
        if revoked:
            messages.success(
                request,
                f"{revoked} {ngettext('device revoked.', 'devices revoked.', revoked)}",
            )
        else:
            messages.info(
                request, _("Nothing to do: every selected device was already revoked.")
            )

    def has_change_permission(self, request, obj=None):
        """The revoke action needs a change permission to be offered at all, and
        `PanelModelAdmin` denies it by default. Nothing on the form is editable —
        `fields` is entirely read-only — so this grants the action, not the form."""
        return self.has_view_permission(request, obj)
