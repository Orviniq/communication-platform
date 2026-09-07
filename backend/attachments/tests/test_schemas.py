"""The one outbound model of the attachment surface.

Two fields leave this process for a stored blob, and the model is what holds the
line: the row also carries a stored day, and a response that named it would put a
account behind every capability. There is no inbound model — the upload body is
multipart, parsed under limits Pydantic has no say over — and that absence is
asserted here too, because a model added later would be a second parse of a body
this route deliberately reads once.
"""

import inspect

import pytest
from pydantic import BaseModel, ValidationError

from attachments import schemas
from attachments.schemas import AttachmentOut
from core.buckets import ATTACHMENT_BUCKETS

SMALLEST = min(ATTACHMENT_BUCKETS)
CAPABILITY = "Xk3vT9qLm2WnPzR8sYb4cJdF6hA1gE5uV7iO0wQtN_M"


def test_the_stored_blob_is_described_by_its_capability_and_its_length():
    body = AttachmentOut(attachment_id=CAPABILITY, size=SMALLEST)

    assert body.model_dump() == {"attachment_id": CAPABILITY, "size": SMALLEST}


def test_nothing_the_row_also_carries_survives_into_the_body():
    """The stored day and the path on disk are on the row the route holds, and a
    model that let an unknown key through would publish the first and hand out the
    second."""
    body = AttachmentOut.model_validate(
        {
            "attachment_id": CAPABILITY,
            "size": SMALLEST,
            "created_date": "2026-09-06",
            "disk_path": "/srv/chat/media/Xk/Xk3v",
        }
    )

    assert set(body.model_dump()) == {"attachment_id", "size"}


@pytest.mark.parametrize(
    "payload",
    [
        {"size": SMALLEST},
        {"attachment_id": CAPABILITY},
        {"attachment_id": CAPABILITY, "size": "not a number"},
        {"attachment_id": None, "size": SMALLEST},
    ],
)
def test_a_body_the_route_could_not_have_produced_is_refused(payload):
    with pytest.raises(ValidationError):
        AttachmentOut(**payload)


def test_the_largest_bucket_survives_the_model_unrounded():
    """The boundary a narrower integer type would silently clamp."""
    largest = max(ATTACHMENT_BUCKETS)

    assert AttachmentOut(attachment_id=CAPABILITY, size=largest).size == largest


def test_the_module_declares_no_inbound_model():
    """The rare case this file exists to catch: a later `AttachmentIn` would mean
    the body is parsed a second time, which spools a 64 MiB attachment twice."""
    declared = {
        name
        for name, member in inspect.getmembers(schemas, inspect.isclass)
        if issubclass(member, BaseModel) and member is not BaseModel
    }

    assert declared == {"AttachmentOut"}
