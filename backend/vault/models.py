from django.db import models

from core.buckets import BACKUP_BUCKETS
from core.fields import OpaqueBlobField


class KeyBackup(models.Model):
    """The recovery-secret-encrypted backup of the account's cross-signing private
    keys and identity material. The server stores it and can never open it; no
    server-side secret verification exists anywhere. Message history is not in
    here and not on the server at all — it moves between devices client-to-client
    on enrollment."""

    user = models.OneToOneField(
        "accounts.User",
        on_delete=models.CASCADE,
        primary_key=True,
        related_name="keybackup",
    )
    blob = OpaqueBlobField(bucket_set=BACKUP_BUCKETS)
    version = models.PositiveIntegerField(default=0)
    # Retired by ADR-0024 with the activity dates. Nothing reads it and nothing
    # writes it; the column stays until run 08 drops it, because a column leaves
    # in two steps and this is the first.
    updated_date = models.DateField(null=True)
