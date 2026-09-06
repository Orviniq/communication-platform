"""The attachments page: what is on the disk, and how to free it.

`Attachment.id` is not an identifier, it is a capability: `GET
/api/v1/attachments/{id}` hands the bytes to any live token that presents it, and
the id is the only gate. ADR-0011 says the panel shows no token, so this page is
built so that the id never becomes visible text and never enters a URL:

* no id column, and `list_display_links = None`, so no row links anywhere;
* no change form at all — `has_view_permission` refuses an object — because that
  URL would *be* the capability, and would then sit in the address bar, the browser
  history and any bookmark;
* the audit row names the attachment by its size and its day, never by `str()`,
  which would be the id.

What survives is `LogEntry.object_id`, which Django's own contract requires. By the
time that row is written the row and its file are gone, so the value it holds is a
capability that opens nothing. `backend/SECURITY.md` records it with its retention.
"""

from django.contrib import admin, messages
from django.contrib.admin import helpers
from django.db.models import Sum
from django.template.response import TemplateResponse
from django.urls import reverse
from django.utils.translation import gettext_lazy as _
from django.utils.translation import ngettext
from unfold.decorators import display

from attachments.models import Attachment
from attachments.services import purge
from core.panel import PanelModelAdmin, size_label, storage_label


@admin.register(Attachment)
class AttachmentAdmin(PanelModelAdmin):
    """A list and one destructive action, and nothing that names a row."""

    list_display = ("size_bucket", "created_date")
    list_display_links = None
    list_filter = ("created_date",)
    ordering = ("-created_date",)
    date_hierarchy = "created_date"
    actions = ("purge_attachments",)
    purge_confirmation_template = "admin/attachments/attachment/purge_confirmation.html"

    @display(description=_("Size"), ordering="size")
    def size_bucket(self, obj):
        return size_label(obj.size)

    def has_view_permission(self, request, obj=None):
        """The list, never one row.

        Django asks with `obj=None` for the changelist and with the instance for the
        change form, so refusing the second is what removes the only page whose URL
        would carry a capability.
        """
        return super().has_view_permission(request, obj) and obj is None

    def has_delete_permission(self, request, obj=None):
        """The bulk action, never the per-object delete view.

        That view's confirmation page renders `str(obj)` too, and its URL carries
        the capability, so it is refused for the same reason the change form is.
        """
        return super().has_view_permission(request, None) and obj is None

    def get_actions(self, request):
        """Django's `delete_selected` leaves.

        Its confirmation page lists `str(obj)` for every selected row, which for
        this model is the capability id in visible text. `purge_attachments` does
        the same job and states the same consequence without naming a row.
        """
        actions = super().get_actions(request)
        actions.pop("delete_selected", None)
        return actions

    def panel_repr(self, obj):
        return f"{size_label(obj.size)} attachment of {obj.created_date}"

    @admin.action(
        description=_("Delete the selected attachments and their files"),
        permissions=["delete"],
    )
    def purge_attachments(self, request, queryset):
        """Confirm, then delete the rows and unlink the bytes.

        The consequence the confirmation states is the count and the bytes freed —
        the two numbers the operator is deciding on — and no identifier.
        """
        if request.POST.get("confirmed") != "yes":
            total = queryset.aggregate(total=Sum("size"))["total"] or 0
            return TemplateResponse(
                request,
                self.purge_confirmation_template,
                {
                    **self.admin_site.each_context(request),
                    "title": _("Delete these attachments?"),
                    "count": queryset.count(),
                    "freed": storage_label(total),
                    "opts": self.opts,
                    "cancel_url": reverse(
                        f"admin:{self.opts.app_label}_{self.opts.model_name}_changelist"
                    ),
                    "action_checkbox_name": helpers.ACTION_CHECKBOX_NAME,
                    "selected": [str(pk) for pk in queryset.values_list("pk", flat=True)],
                },
            )

        deleted, removed_files = purge(queryset, audit=self._audit_purge(request))
        if deleted:
            rows_word = ngettext("attachment deleted", "attachments deleted", deleted)
            files_word = ngettext("file removed", "files removed", removed_files)
            messages.success(
                request,
                f"{deleted} {rows_word} ({removed_files} {files_word}).",
            )
        else:
            messages.info(request, _("Nothing to do: no attachment was selected."))
        return None

    def _audit_purge(self, request):
        return lambda objects: self.log_deletions(request, objects)
