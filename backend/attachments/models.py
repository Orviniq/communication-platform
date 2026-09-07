import base64
import os
import secrets

from django.conf import settings
from django.db import models


def _new_capability_id():
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()


class Attachment(models.Model):
    """Opaque encrypted bytes on disk. The unguessable id is the access capability,
    delivered to recipients inside end-to-end encrypted messages. No recipient or
    ACL data exists."""

    id = models.CharField(
        primary_key=True, max_length=43, default=_new_capability_id, editable=False
    )
    size = models.BigIntegerField()
    created_date = models.DateField(auto_now_add=True)

    def disk_path(self):
        return os.path.join(settings.ATTACHMENTS_ROOT, self.id[:2], self.id)
