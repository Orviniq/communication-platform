"""The accounts page: activate, deactivate, set a password, revoke every device.

Registration is a client call, so the panel never adds an account and never deletes
one — an account with no rows left is a database operation, not an operator task.
What the operator does here is the four things above plus the staff flag.
"""

from django import forms
from django.contrib import admin, messages
from django.contrib.admin.models import CHANGE
from django.db import transaction
from django.shortcuts import redirect
from django.urls import reverse
from django.utils.translation import gettext_lazy as _
from django.utils.translation import ngettext
from unfold.decorators import action, display
from unfold.forms import BaseDialogForm
from unfold.widgets import UnfoldAdminPasswordWidget

from accounts.models import User
from core.panel import PanelModelAdmin, audit
from devices.models import Device
from devices.services import revoke as revoke_device
from realtime.bus import close_device_sockets


class AccountForm(forms.ModelForm):
    """The two editable values, under names an operator reads.

    Django takes a field's label from its `verbose_name`, and these two fields
    declare none, so the change form would otherwise be headed "Is active" and
    "Is staff" — column names in front of a person.
    """

    class Meta:
        model = User
        fields = ("is_active", "is_staff")
        labels = {
            "is_active": _("Activated"),
            "is_staff": _("Opens this panel"),
        }
        help_texts = {
            "is_active": _("An account that is not activated cannot sign in."),
            "is_staff": _(
                "Only the owner account can actually use the panel; a staff account "
                "that is not the owner sees nothing here."
            ),
        }


class SetPasswordForm(BaseDialogForm):
    """The dialog behind the set-password action.

    The change form carries no password widget at all (ADR-0011): a hash on screen
    is a hash in a screenshot, and the stock widget's only other control is a link
    to a second page. Validation is Django's own configured validator set, so the
    panel and the client registration path agree on what a password must be.
    """

    password = forms.CharField(
        label=_("New password"),
        strip=False,
        widget=UnfoldAdminPasswordWidget(attrs={"autocomplete": "new-password"}),
    )
    confirm = forms.CharField(
        label=_("Repeat the new password"),
        strip=False,
        widget=UnfoldAdminPasswordWidget(attrs={"autocomplete": "new-password"}),
    )

    def clean(self):
        from django.contrib.auth.password_validation import validate_password

        cleaned = super().clean()
        password, confirm = cleaned.get("password"), cleaned.get("confirm")
        if password and confirm and password != confirm:
            raise forms.ValidationError(_("The two passwords do not match."))
        if password:
            validate_password(password, User.objects.filter(pk=self.object_id).first())
        return cleaned


def _close_sockets_of(user_ids):
    """Drop the live sockets of every unrevoked device of these accounts.

    Deactivation and revocation both have to reach the socket as well as the
    database: a REST call re-reads `is_active` every time, but a WebSocket
    authenticated once at connect would keep relaying volatile signals until it
    happened to drop.
    """
    device_ids = list(
        Device.objects.filter(
            user_id__in=user_ids, revoked_date__isnull=True
        ).values_list("id", flat=True)
    )
    for device_id in device_ids:
        close_device_sockets(device_id)


@admin.register(User)
class AccountAdmin(PanelModelAdmin):
    """One row for each person who can sign in."""

    list_display = ("username", "state", "panel_access", "created_date")
    list_filter = ("is_active", "is_staff", "created_date")
    search_fields = ("username",)
    ordering = ("username",)
    date_hierarchy = "created_date"
    form = AccountForm
    # `password` is absent on purpose, and so is every permission relation: one
    # role means `groups` and `user_permissions` administer nothing.
    fields = (
        "username",
        "is_active",
        "is_staff",
        "created_date",
        "last_login",
        "live_devices",
    )
    readonly_fields = ("username", "created_date", "last_login", "live_devices")
    actions = ("activate_accounts", "deactivate_accounts", "revoke_all_devices")
    actions_detail = ("set_password",)

    @display(
        description=_("State"),
        ordering="is_active",
        label={"active": "success", "pending": "warning"},
    )
    def state(self, obj):
        return (
            ("active", _("Active"))
            if obj.is_active
            else ("pending", _("Awaiting activation"))
        )

    @display(description=_("Opens this panel"), boolean=True, ordering="is_staff")
    def panel_access(self, obj):
        """`is_staff` is a column name. What it means to the operator is whether the
        account can reach this back office at all."""
        return obj.is_staff

    @display(description=_("Live devices"))
    def live_devices(self, obj):
        return Device.objects.filter(user=obj, revoked_date__isnull=True).count()

    def has_change_permission(self, request, obj=None):
        # The staff flag and the activation state are the two editable values.
        return self.has_view_permission(request, obj)

    def panel_repr(self, obj):
        return obj.get_username()

    def save_model(self, request, obj, form, change):
        """Django writes the audit row for a change-form save itself; the socket
        close is what it does not know about."""
        deactivated = change and not obj.is_active and "is_active" in form.changed_data
        with transaction.atomic():
            super().save_model(request, obj, form, change)
            if deactivated:
                transaction.on_commit(lambda: _close_sockets_of([obj.pk]))

    @admin.action(description=_("Activate the selected accounts"), permissions=["change"])
    def activate_accounts(self, request, queryset):
        with transaction.atomic():
            accounts = list(queryset.filter(is_active=False))
            queryset.filter(is_active=False).update(is_active=True)
            count = audit(
                request, accounts, CHANGE, _("Activated."), repr_of=self.panel_repr
            )
        self._say(request, count, _("account activated."), _("accounts activated."))

    @admin.action(
        description=_("Deactivate the selected accounts"), permissions=["change"]
    )
    def deactivate_accounts(self, request, queryset):
        with transaction.atomic():
            accounts = list(queryset.filter(is_active=True))
            ids = [account.pk for account in accounts]
            queryset.filter(is_active=True).update(is_active=False)
            count = audit(
                request, accounts, CHANGE, _("Deactivated."), repr_of=self.panel_repr
            )
            # After the commit: the sockets must close against committed state, and
            # a bus that is down must not roll the deactivation back.
            transaction.on_commit(lambda: _close_sockets_of(ids))
        self._say(request, count, _("account deactivated."), _("accounts deactivated."))

    @admin.action(
        description=_("Revoke every device of the selected accounts"),
        permissions=["change"],
    )
    def revoke_all_devices(self, request, queryset):
        """Every live device of the account, through the service function the API's
        own revocation calls. One write path, one set of consequences."""
        revoked = 0
        for account in queryset:
            device_ids = list(
                Device.objects.filter(
                    user=account, revoked_date__isnull=True
                ).values_list("id", flat=True)
            )
            for device_id in device_ids:
                revoke_device(account.pk, device_id)
                transaction.on_commit(
                    lambda device_id=device_id: close_device_sockets(device_id)
                )
            if device_ids:
                revoked += len(device_ids)
                audit(
                    request,
                    [account],
                    CHANGE,
                    _("Revoked every device of this account."),
                    repr_of=self.panel_repr,
                )
        self._say(request, revoked, _("device revoked."), _("devices revoked."))

    @action(
        description=_("Set a new password"),
        permissions=["change"],
        url_path="set-password",
        dialog={
            "title": _("Set a new password"),
            "description": _(
                "The account keeps its messages and its devices. Only the sign-in "
                "password changes."
            ),
            # The class itself: django-unfold 0.105.0 calls `dialog["form_class"]`
            # directly and imports no dotted path here.
            "form_class": SetPasswordForm,
            "form_submit_text": _("Set the password"),
        },
    )
    def set_password(self, request, form, object_id):
        """`permissions=["change"]` is not decoration: without it the generated URL
        is gated only by `is_staff`, because that is all `AdminSite.admin_view`
        checks (django-unfold 0.105.0)."""
        account = User.objects.get(pk=object_id)
        with transaction.atomic():
            account.set_password(form.cleaned_data["password"])
            account.save(update_fields=["password"])
            audit(
                request,
                [account],
                CHANGE,
                _("Set a new password."),
                repr_of=self.panel_repr,
            )
        messages.success(request, _("The password was changed."))
        # The return value is the response: `AdminSite.admin_view` wraps it in
        # `never_cache`, which dereferences it, so `None` is a 500.
        return redirect(reverse("admin:accounts_user_change", args=[account.pk]))

    def _say(self, request, count, singular, plural):
        if count:
            messages.success(request, f"{count} {ngettext(singular, plural, count)}")
        else:
            messages.info(request, _("Nothing to do: no selected row needed the change."))
