"""What the three messaging routes are wired to, what they do with a body they
cannot use, and what they answer when the machinery below them fails.

One rule holds across the whole surface: a malformed request is a `400` carrying
the error envelope, and never a `500`. Every body here is authenticated input, so
the matrix is not about anonymous exposure — it is about the mailbox: a shape the
route cannot parse must not become a server error the client retries for ever,
and a refusal must never carry the payload back, because the payload is
ciphertext and the identifier is a device.

`limit` is the exception that proves the rule. It is the one parameter of this
app declared as a string rather than an integer, because the route it rides on is
the one a client polls: declared as an integer, a stale client sending anything
this server dislikes would be locked out of its own mailbox by a `400`. So every
value it can carry answers `200` with a documented clamp, and this file holds the
table.

`transaction=True` because the ORM bracket of `api.orm.run_unit` closes the
connection around every unit of work, which under a wrapping test transaction
would sever the connection the test itself holds.
"""

import base64
import logging
import uuid

import pytest
from django.db import DatabaseError
from hypothesis import given, settings
from hypothesis import strategies as st
from redis.exceptions import ConnectionError as RedisConnectionError

from api.app import wrap
from config.asgi import api_application, application
from conftest import AsgiClient
from messaging import routes
from messaging.models import QueuedEnvelope
from messaging.schemas import (
    MAX_ACK_IDS,
    MAX_BLOB_CHARS,
    MAX_DRAIN_LIMIT,
    MAX_SEND_BATCH,
    AckOut,
    DrainOut,
    SendOut,
)
from ops.audit.log_silence import capture_all_logging
from realtime import bus

from .conftest import SMALLEST_BUCKET, envelope_blob
from .test_push import Listener

pytestmark = pytest.mark.django_db(transaction=True)

SEND_URL = "/api/v1/envelopes"
DRAIN_URL = "/api/v1/me/envelopes"
ACK_URL = "/api/v1/me/envelopes/ack"

# Every messaging route that reads a body, and a body each one accepts.
BODY_ROUTES = [
    ("POST", SEND_URL),
    ("POST", ACK_URL),
]

NOT_OBJECTS = [[], ["messages"], "a string", 5, 1.5, True, None]

MALFORMED_RAW = [
    (b"", "application/json"),
    (b"{", "application/json"),
    (b"not json at all", "application/json"),
    (b'{"messages": }', "application/json"),
    (b"messages=1&ids=2", "text/plain"),
]

# Every control character a JSON string can carry, NUL first. None of them may
# reach a column, and none of them may reach a traceback either.
CONTROL_CHARACTERS = ["\x00", "\n", "\r", "\t", "\x1b", "\x7f"]


def envelope_body(response, code):
    body = response.json()
    assert set(body) == {"code", "detail"}, body
    assert body["code"] == code, body
    return body


def enqueue(device, count, start=1):
    return [
        QueuedEnvelope.objects.create(
            recipient_device=device, seq=start + i, blob=bytes([97 + i]) * SMALLEST_BUCKET
        )
        for i in range(count)
    ]


@pytest.fixture
def headers(active_user, device, bearer):
    return bearer(active_user, device)


@pytest.fixture
def target(bob_devices):
    """A live mailbox belonging to somebody else, which is the ordinary case."""
    return bob_devices[0]


@pytest.fixture
def item(target):
    def build(**overrides):
        body = {"device_id": str(target.id), "blob": envelope_blob()}
        body.update(overrides)
        return body

    return build


@pytest.fixture
def unmasked_http():
    """A client that renders the `500` body instead of re-raising it.

    `reraise=True` is the shared fixture's default and it stays there: an
    unhandled failure reaching the test is what keeps a `500` from being mistaken
    for a passing request. This is the one thing that default hides, and the body
    of a server error is a published contract like any other.
    """
    return AsgiClient(application, api_application, reraise=False)


class TestTheRouteTable:
    """What each handler declares, read off the router rather than a response.

    `core/tests/test_route_table.py` walks the whole surface for the requirement
    and the throttle scope. What is left, and what belongs to this app, is the
    rest of the declaration: the status a success carries, the model that renders
    it, and the vocabulary of refusals a client is told to branch on.
    """

    @pytest.fixture
    def declared(self):
        return {
            (sorted(route.methods)[0], route.path): route
            for route in routes.router.routes
        }

    def test_a_send_is_accepted_rather_than_created_or_merely_ok(self, declared):
        """`202` and not `201`: the queue rows exist, but delivery has not
        happened and no resource address comes back for the client to fetch."""
        assert declared[("POST", "/envelopes")].status_code == 202

    @pytest.mark.parametrize(
        "method, path, model",
        [
            ("POST", "/envelopes", SendOut),
            ("GET", "/me/envelopes", DrainOut),
            ("POST", "/me/envelopes/ack", AckOut),
        ],
    )
    def test_each_route_renders_through_the_model_that_bounds_its_answer(
        self, declared, method, path, model
    ):
        """The response model is what keeps a handler from returning a dictionary
        with a field nobody declared — a sender, a recipient, an uploader."""
        assert declared[(method, path)].response_model is model

    @pytest.mark.parametrize(
        "method, path",
        [("POST", "/envelopes"), ("GET", "/me/envelopes"), ("POST", "/me/envelopes/ack")],
    )
    def test_every_route_resolves_the_principal_before_it_counts_the_request(
        self, declared, method, path
    ):
        """The limiter keys on the account, so a limiter resolved first would
        count every authenticated caller against their own address instead."""
        names = [
            dependency.dependency.__name__
            for dependency in declared[(method, path)].dependencies
        ]

        assert names == ["require_full_device", "rate_limit_envelopes"]

    @pytest.mark.parametrize(
        "method, path, statuses",
        [
            ("POST", "/envelopes", {400, 401, 403, 413, 429, 500, 503}),
            ("GET", "/me/envelopes", {401, 403, 429, 500, 503}),
            ("POST", "/me/envelopes/ack", {400, 401, 403, 413, 429, 500, 503}),
        ],
    )
    def test_each_route_publishes_every_status_it_can_answer(
        self, declared, method, path, statuses
    ):
        """The drain reads no body, so it declares no `400` and no `413`: a
        generated client that branched on either would be branching on an answer
        this route cannot give."""
        assert set(declared[(method, path)].responses) == statuses


class TestBodiesThatAreNotObjects:
    @pytest.mark.parametrize("method, url", BODY_ROUTES)
    @pytest.mark.parametrize("body", NOT_OBJECTS)
    def test_a_body_that_is_not_an_object_is_an_invalid_request(
        self, http, headers, method, url, body
    ):
        response = http.request(method, url, headers=headers, json=body)

        assert response.status_code == 400
        envelope_body(response, "invalid_request")
        assert QueuedEnvelope.objects.count() == 0

    @pytest.mark.parametrize("method, url", BODY_ROUTES)
    @pytest.mark.parametrize("raw, content_type", MALFORMED_RAW)
    def test_a_body_that_is_not_json_is_an_invalid_request(
        self, http, headers, method, url, raw, content_type
    ):
        response = http.request(
            method, url, headers={**headers, "content-type": content_type}, content=raw
        )

        assert response.status_code == 400
        envelope_body(response, "invalid_request")

    @pytest.mark.parametrize("method, url", BODY_ROUTES)
    def test_a_malformed_body_on_a_mailbox_route_is_still_a_401(self, http, method, url):
        """Authentication is resolved before the body is read, so an anonymous
        caller learns nothing about the shape of a body it may not send."""
        response = http.request(method, url, json=[])

        assert response.status_code == 401
        envelope_body(response, "unauthenticated")


class TestWrongTypesAndUnknownFields:
    @pytest.mark.parametrize(
        "url, payload",
        [
            (SEND_URL, {"messages": {}}),
            (SEND_URL, {"messages": "not-a-list"}),
            (SEND_URL, {"messages": 5}),
            (SEND_URL, {"messages": None}),
            (SEND_URL, {}),
            (ACK_URL, {"ids": "not-a-list"}),
            (ACK_URL, {"ids": 5}),
            (ACK_URL, {"ids": {}}),
            (ACK_URL, {"ids": None}),
        ],
    )
    def test_a_field_of_the_wrong_type_is_refused_without_a_server_error(
        self, http, headers, url, payload
    ):
        response = http.post(url, json=payload, headers=headers)

        assert response.status_code == 400
        envelope_body(response, "invalid_request")

    @pytest.mark.parametrize("field", ["device_id", "blob"])
    def test_an_item_missing_a_field_names_the_field_and_its_index(
        self, http, headers, item, field
    ):
        body = item()
        body.pop(field)

        response = http.post(SEND_URL, json={"messages": [item(), body]}, headers=headers)

        assert response.status_code == 400
        assert set(envelope_body(response, "invalid_request")["detail"]) == {
            f"messages.1.{field}"
        }
        assert QueuedEnvelope.objects.count() == 0

    @pytest.mark.parametrize(
        "url, payload",
        [
            (SEND_URL, {"messages": [], "sender": "alice"}),
            (ACK_URL, {"ids": [], "device_id": "alice"}),
        ],
    )
    def test_an_unknown_field_beside_the_body_is_refused(
        self, http, headers, url, payload
    ):
        response = http.post(url, json=payload, headers=headers)

        assert response.status_code == 400
        envelope_body(response, "invalid_request")

    def test_an_unknown_field_inside_an_item_is_refused(self, http, headers, item):
        """A `sender` key quietly dropped would read to a client author as a field
        this server honours, and the whole design is that it does not."""
        response = http.post(
            SEND_URL, json={"messages": [item(sender="alice")]}, headers=headers
        )

        assert response.status_code == 400
        envelope_body(response, "invalid_request")
        assert QueuedEnvelope.objects.count() == 0

    def test_an_unknown_query_parameter_on_the_drain_is_ignored_rather_than_refused(
        self, http, headers, device
    ):
        """The drain declares one parameter; a client that adds another — a cache
        buster, a tracing tag — must still reach its mailbox."""
        enqueue(device, 1)

        response = http.get(f"{DRAIN_URL}?limit=1&cursor=abc", headers=headers)

        assert response.status_code == 200
        assert len(response.json()["envelopes"]) == 1


class TestTheBatchBounds:
    def test_a_batch_of_none_is_refused_before_anything_is_written(self, http, headers):
        response = http.post(SEND_URL, json={"messages": []}, headers=headers)

        assert response.status_code == 400
        assert set(envelope_body(response, "invalid_request")["detail"]) == {"messages"}
        assert QueuedEnvelope.objects.count() == 0

    def test_the_largest_batch_the_contract_publishes_is_accepted_whole(
        self, http, headers, item, target
    ):
        """256 items, which is what a client fanning one message out to a large
        group sends: the boundary has to be inside the cap, not one short of it."""
        response = http.post(
            SEND_URL,
            json={"messages": [item() for _ in range(MAX_SEND_BATCH)]},
            headers=headers,
        )

        assert response.status_code == 202
        assert response.json()["accepted"] == MAX_SEND_BATCH
        assert (
            QueuedEnvelope.objects.filter(recipient_device_id=target.id).count()
            == MAX_SEND_BATCH
        )

    def test_one_item_more_is_refused_and_queues_none_of_it(
        self, http, headers, item, target
    ):
        response = http.post(
            SEND_URL,
            json={"messages": [item() for _ in range(MAX_SEND_BATCH + 1)]},
            headers=headers,
        )

        assert response.status_code == 400
        assert set(envelope_body(response, "invalid_request")["detail"]) == {"messages"}
        assert QueuedEnvelope.objects.count() == 0

    def test_the_same_device_named_twice_in_one_batch_gets_two_rows(
        self, http, headers, item, target
    ):
        """Duplicate ids are legal input, not a refusal: the client encrypts once
        per message, so two items for one device are two messages."""
        response = http.post(
            SEND_URL, json={"messages": [item(), item()]}, headers=headers
        )

        assert response.status_code == 202
        assert response.json()["accepted"] == 2
        assert sorted(
            QueuedEnvelope.objects.filter(recipient_device_id=target.id).values_list(
                "seq", flat=True
            )
        ) == [1, 2]


class TestTheAckBounds:
    def test_an_empty_ack_list_deletes_nothing_and_is_not_a_refusal(
        self, http, headers, device
    ):
        enqueue(device, 1)

        response = http.post(ACK_URL, json={"ids": []}, headers=headers)

        assert response.status_code == 200
        assert response.json() == {"deleted": 0}
        assert QueuedEnvelope.objects.count() == 1

    def test_the_largest_ack_the_contract_publishes_is_accepted(
        self, http, headers, device
    ):
        rows = enqueue(device, 3)
        ids = [str(row.id) for row in rows] + [
            str(uuid.uuid4()) for _ in range(MAX_ACK_IDS - 3)
        ]

        response = http.post(ACK_URL, json={"ids": ids}, headers=headers)

        assert response.status_code == 200
        assert response.json() == {"deleted": 3}

    def test_one_id_more_is_refused_and_deletes_nothing(self, http, headers, device):
        rows = enqueue(device, 1)
        ids = [str(rows[0].id)] + [str(uuid.uuid4()) for _ in range(MAX_ACK_IDS)]

        response = http.post(ACK_URL, json={"ids": ids}, headers=headers)

        assert response.status_code == 400
        assert set(envelope_body(response, "invalid_request")["detail"]) == {"ids"}
        assert QueuedEnvelope.objects.count() == 1

    def test_one_id_named_twice_in_one_ack_is_counted_once(self, http, headers, device):
        """The count reports rows and not arguments, so a client that retried
        inside its own batch is told what actually left the mailbox."""
        row = enqueue(device, 1)[0]

        response = http.post(
            ACK_URL, json={"ids": [str(row.id), str(row.id)]}, headers=headers
        )

        assert response.json() == {"deleted": 1}
        assert QueuedEnvelope.objects.count() == 0


class TestBlobsThatAreNotPayloads:
    def test_the_longest_blob_the_field_admits_is_still_bucket_checked(
        self, http, headers, item
    ):
        """The cap is base64 headroom over the largest bucket, never a second
        bucket: what it admits still has to land on an exact length."""
        blob = base64.b64encode(b"\x11" * 262152).decode()

        response = http.post(
            SEND_URL, json={"messages": [item(blob=blob)]}, headers=headers
        )

        assert len(blob) == MAX_BLOB_CHARS
        assert response.status_code == 400
        assert envelope_body(response, "bad_bucket")["detail"] == "Invalid payload."
        assert blob not in response.text

    def test_one_character_more_is_refused_before_the_decode(self, http, headers, item):
        """Without the cap the string reaches `b64decode`, which allocates three
        quarters of whatever it was given before deciding anything at all."""
        blob = "A" * (MAX_BLOB_CHARS + 1)

        response = http.post(
            SEND_URL, json={"messages": [item(blob=blob)]}, headers=headers
        )

        assert response.status_code == 400
        assert set(envelope_body(response, "invalid_request")["detail"]) == {
            "messages.0.blob"
        }
        assert blob not in response.text

    @pytest.mark.parametrize(
        "size", [1, SMALLEST_BUCKET - 1, SMALLEST_BUCKET + 1, 262144 + 1]
    )
    def test_an_off_bucket_length_is_a_bad_bucket_that_echoes_nothing(
        self, http, headers, item, size
    ):
        blob = base64.b64encode(b"\xab" * size).decode()

        response = http.post(
            SEND_URL, json={"messages": [item(blob=blob)]}, headers=headers
        )

        assert response.status_code == 400
        envelope_body(response, "bad_bucket")
        assert blob not in response.text
        assert str(size) not in response.text
        assert QueuedEnvelope.objects.count() == 0

    @pytest.mark.parametrize(
        "blob",
        [
            "definitely not base64 !!",
            "q83vEjRWeJ",
            "_" * 1368,
            "=" * 1368,
            "AAAA\nAAAA",
        ],
    )
    def test_a_blob_that_is_not_strict_base64_is_a_bad_bucket(
        self, http, headers, item, blob
    ):
        response = http.post(
            SEND_URL, json={"messages": [item(blob=blob)]}, headers=headers
        )

        assert response.status_code == 400
        envelope_body(response, "bad_bucket")
        assert blob not in response.text

    def test_an_empty_blob_is_a_validation_error_naming_its_field(
        self, http, headers, item
    ):
        response = http.post(
            SEND_URL, json={"messages": [item(blob="")]}, headers=headers
        )

        assert response.status_code == 400
        assert set(envelope_body(response, "invalid_request")["detail"]) == {
            "messages.0.blob"
        }


class TestDeviceIdsThatAreNotIdentifiers:
    @pytest.mark.parametrize(
        "device_id",
        [
            "not-a-uuid",
            "",
            5,
            1.5,
            None,
            ["one"],
            {},
            "../../etc/passwd",
            "x" * 10_000,
            "00000000-0000-0000-0000-00000000000",
        ],
    )
    def test_a_device_id_that_is_not_a_uuid_is_an_invalid_request(
        self, http, headers, item, device_id
    ):
        """Unparsed, these reach a uuid column and raise where nothing below the
        route turns them into anything but a server error."""
        response = http.post(
            SEND_URL, json={"messages": [item(device_id=device_id)]}, headers=headers
        )

        assert response.status_code == 400
        assert set(envelope_body(response, "invalid_request")["detail"]) == {
            "messages.0.device_id"
        }
        assert QueuedEnvelope.objects.count() == 0

    @pytest.mark.parametrize("spelling", ["braced", "urn", "hex"])
    def test_an_alternative_uuid_spelling_reaches_the_same_mailbox(
        self, http, headers, item, target, spelling
    ):
        """The lax parse takes every spelling Python does, and they all normalise
        to one value — so no spelling opens a second mailbox of its own, and a
        client that writes braces is not silently talking to nobody."""
        written = {
            "braced": f"{{{target.id}}}",
            "urn": f"urn:uuid:{target.id}",
            "hex": target.id.hex,
        }[spelling]

        response = http.post(
            SEND_URL, json={"messages": [item(device_id=written)]}, headers=headers
        )

        assert response.status_code == 202
        assert response.json() == {
            "accepted": 1,
            "stale_devices": [],
            "full_devices": [],
        }
        assert QueuedEnvelope.objects.filter(recipient_device_id=target.id).count() == 1

    @pytest.mark.parametrize(
        "ids", [["abc"], [123], [None], [{}], [[]], ["../../etc/passwd"], [""]]
    )
    def test_an_ack_id_that_is_not_a_uuid_is_an_invalid_request(
        self, http, headers, device, ids
    ):
        enqueue(device, 1)

        response = http.post(ACK_URL, json={"ids": ids}, headers=headers)

        assert response.status_code == 400
        assert set(envelope_body(response, "invalid_request")["detail"]) == {"ids.0"}
        assert QueuedEnvelope.objects.count() == 1


class TestControlCharacters:
    @pytest.mark.parametrize("character", CONTROL_CHARACTERS)
    def test_a_control_character_in_a_device_id_is_a_400_and_never_a_500(
        self, http, headers, item, target, character
    ):
        """NUL is the one that matters most: PostgreSQL text carries none, so an
        identifier that reached a statement with one in it would be refused by
        psycopg rather than matching no row."""
        written = f"{target.id}"[:-1] + character

        response = http.post(
            SEND_URL, json={"messages": [item(device_id=written)]}, headers=headers
        )

        assert response.status_code == 400
        envelope_body(response, "invalid_request")
        assert QueuedEnvelope.objects.count() == 0

    @pytest.mark.parametrize("character", CONTROL_CHARACTERS)
    def test_a_control_character_in_a_blob_is_a_bad_bucket_that_echoes_nothing(
        self, http, headers, item, character
    ):
        blob = envelope_blob()[:-1] + character

        response = http.post(
            SEND_URL, json={"messages": [item(blob=blob)]}, headers=headers
        )

        assert response.status_code == 400
        envelope_body(response, "bad_bucket")
        assert character not in response.text
        assert QueuedEnvelope.objects.count() == 0

    @pytest.mark.parametrize("character", CONTROL_CHARACTERS)
    def test_a_control_character_in_an_ack_id_is_a_400_and_never_a_500(
        self, http, headers, device, character
    ):
        row = enqueue(device, 1)[0]

        response = http.post(
            ACK_URL, json={"ids": [f"{row.id}"[:-1] + character]}, headers=headers
        )

        assert response.status_code == 400
        envelope_body(response, "invalid_request")
        assert QueuedEnvelope.objects.count() == 1

    @pytest.mark.parametrize("character", CONTROL_CHARACTERS)
    def test_a_control_character_in_the_page_size_still_drains_the_mailbox(
        self, http, headers, device, character
    ):
        """The parameter never refuses, so a byte no number can hold is the cap
        rather than a client locked out of its own queue."""
        enqueue(device, 3)

        response = http.get(DRAIN_URL, params={"limit": character}, headers=headers)

        assert response.status_code == 200
        assert len(response.json()["envelopes"]) == 3


class TestThePageSizeParameter:
    @pytest.mark.parametrize(
        "raw, drained",
        [
            ("abc", 3),
            ("", 3),
            ("-5", 1),
            ("0", 1),
            ("1", 1),
            ("100", 3),
            ("101", 3),
            ("9" * 10_000, 3),
        ],
    )
    def test_every_documented_page_size_answers_200_with_its_clamp(
        self, http, headers, device, raw, drained
    ):
        """The whole table in one place. A `400` on any row of it would be a
        client that cannot drain, and a `500` would be one that retries for ever
        — which on this route is the difference between a stalled mailbox and a
        working one."""
        enqueue(device, 3)

        response = http.get(DRAIN_URL, params={"limit": raw}, headers=headers)

        assert response.status_code == 200
        assert len(response.json()["envelopes"]) == drained

    def test_a_page_size_at_the_cap_still_reports_a_further_page(
        self, http, headers, device
    ):
        """The boundary from the other side: a mailbox larger than the cap pages
        rather than truncating in silence."""
        enqueue(device, MAX_DRAIN_LIMIT + 1)

        response = http.get(
            DRAIN_URL, params={"limit": str(MAX_DRAIN_LIMIT)}, headers=headers
        )

        body = response.json()
        assert len(body["envelopes"]) == MAX_DRAIN_LIMIT
        assert body["has_more"] is True

    def test_the_parameter_repeated_is_read_once_rather_than_refused(
        self, http, headers, device
    ):
        """A duplicate query key is legal input a parser has to settle; this one
        keeps the first, and either answer is a 200."""
        enqueue(device, 3)

        response = http.get(f"{DRAIN_URL}?limit=1&limit=2", headers=headers)

        assert response.status_code == 200
        assert len(response.json()["envelopes"]) in (1, 2)


class TestRoutingRefusals:
    @pytest.mark.parametrize(
        "method, url, allowed",
        [("GET", SEND_URL, "POST"), ("POST", DRAIN_URL, "GET"), ("GET", ACK_URL, "POST")],
    )
    def test_a_method_the_route_does_not_serve_is_a_405_with_an_allow_header(
        self, http, headers, method, url, allowed
    ):
        response = http.request(method, url, headers=headers)

        assert response.status_code == 405
        envelope_body(response, "method_not_allowed")
        assert allowed in response.headers["allow"]

    @pytest.mark.parametrize("url", [f"{SEND_URL}/", f"{DRAIN_URL}/", f"{ACK_URL}/"])
    def test_a_trailing_slash_is_a_refusal_and_never_a_redirect(self, http, headers, url):
        """A redirect would rebuild an absolute address out of the scope path and
        drop whatever prefix the proxy stripped."""
        response = http.post(url, json={}, headers=headers)

        assert response.status_code == 404
        envelope_body(response, "not_found")

    def test_the_drain_ignores_a_body_it_was_never_meant_to_read(
        self, http, headers, device
    ):
        enqueue(device, 1)

        response = http.request("GET", DRAIN_URL, headers=headers, json=[1, 2, 3])

        assert response.status_code == 200
        assert len(response.json()["envelopes"]) == 1


class TestTheBodyCap:
    """The one refusal these routes publish that no body they accept can reach.

    All three take the batch limits class, whose cap is `BODY_CAP_BATCH_BYTES` — 70
    MiB, the size nginx admits, which is far above anything these schemas can
    produce. So the cap is shrunk rather than met: `api.app.build_limits` reads the
    settings once, when the middleware stack is wrapped, so a smaller stack is built
    around the same application instead of seventy megabytes being sent to the real
    one. `BodyCap` counts the body as the server delivers it, never off
    `Content-Length`, which is why an understated header cannot get past it either.
    """

    CAP = 64

    @pytest.fixture
    def capped_http(self, settings):
        settings.BODY_CAP_BATCH_BYTES = self.CAP
        return AsgiClient(wrap(api_application), api_application)

    def test_a_send_above_the_cap_is_413_and_queues_nothing(
        self, capped_http, http, headers, item
    ):
        body = {"messages": [item()]}

        response = capped_http.post(SEND_URL, json=body, headers=headers)

        assert response.status_code == 413
        envelope_body(response, "payload_too_large")
        # Refused before the route ran, not after: the same body through the real
        # stack is accepted, so the only thing that changed is the cap.
        assert QueuedEnvelope.objects.count() == 0
        assert http.post(SEND_URL, json=body, headers=headers).status_code == 202
        assert QueuedEnvelope.objects.count() == 1

    def test_an_ack_above_the_cap_is_413_and_deletes_nothing(
        self, capped_http, http, headers, device
    ):
        queued = enqueue(device, 4)
        body = {"ids": [str(row.id) for row in queued]}

        response = capped_http.post(ACK_URL, json=body, headers=headers)

        assert response.status_code == 413
        envelope_body(response, "payload_too_large")
        assert QueuedEnvelope.objects.count() == 4
        assert http.post(ACK_URL, json=body, headers=headers).json() == {"deleted": 4}

    def test_a_body_at_the_cap_is_not_refused(self, capped_http, headers):
        """The boundary is `>`, so the largest body the cap admits is the cap
        itself. An empty ack list is the one valid body small enough to sit under
        sixty-four bytes."""
        body = b'{"ids": []}'.ljust(self.CAP)

        response = capped_http.post(
            ACK_URL,
            content=body,
            headers={**headers, "Content-Type": "application/json"},
        )

        assert response.status_code == 200
        assert response.json() == {"deleted": 0}


class TestGeneratedBodies:
    """Whatever a client sends, the answer is one of the documented ones.

    The three tests below draw bodies rather than listing them, and each asserts
    the properties that have to hold for every body at once: the status is one
    the route publishes, an error carries the envelope and nothing else, and no
    refusal hands the generated value back.

    Two deliberate narrowings. Junk strings are drawn at eight characters and up,
    because Pydantic's message for a malformed identifier quotes the offending
    character — `messaging/API.md` publishes that message as part of the contract
    — so a single drawn character legitimately appears in a refusal while the
    value never may. And the echo rule is asserted on refusals: a `202` names the
    ids the batch could not reach, which is the client's own input coming back by
    design, so a success is held instead to the documented shape with every id it
    names drawn from the ids the body itself carried.
    """

    JUNK = st.text(min_size=8, max_size=16)

    @pytest.fixture
    def mailbox(self, device):
        """Three envelopes, written once for the whole run. A `@given` body
        re-enters per example, so a row created inside it would collide with the
        sequence number the previous example already used."""
        return enqueue(device, 3)

    def ack_bodies(self, live_id):
        identifiers = st.one_of(
            st.just(live_id),
            st.uuids().map(str),
            self.JUNK,
            st.integers(),
            st.none(),
            st.booleans(),
        )
        return st.fixed_dictionaries({"ids": st.lists(identifiers, max_size=5)})

    def send_bodies(self, live_id):
        blobs = st.one_of(
            st.just(envelope_blob()),
            st.text(alphabet="ABCDEFGH+/=", min_size=8, max_size=32),
            self.JUNK,
            st.integers(),
            st.none(),
        )
        device_ids = st.one_of(
            st.just(live_id),
            st.uuids().map(str),
            self.JUNK,
            st.integers(),
            st.none(),
        )
        items = st.fixed_dictionaries({"device_id": device_ids, "blob": blobs})
        return st.fixed_dictionaries({"messages": st.lists(items, max_size=3)})

    @staticmethod
    def drawn_strings(body):
        """Every string the example put into the request, flattened."""
        found = []
        stack = [body]
        while stack:
            current = stack.pop()
            if isinstance(current, dict):
                stack.extend(current.values())
            elif isinstance(current, list):
                stack.extend(current)
            elif isinstance(current, str) and current:
                found.append(current)
        return found

    @settings(max_examples=40)
    @given(data=st.data())
    def test_no_send_body_reaches_an_undocumented_status_or_comes_back_echoed(
        self, http, headers, target, data
    ):
        body = data.draw(self.send_bodies(str(target.id)))

        response = http.post(SEND_URL, json=body, headers=headers)

        assert response.status_code in (202, 400)
        if response.status_code == 400:
            refusal = response.json()
            assert set(refusal) == {"code", "detail"}
            assert refusal["code"] in ("invalid_request", "bad_bucket")
            for drawn in self.drawn_strings(body):
                assert drawn not in response.text
            return
        answer = response.json()
        assert set(answer) == {"accepted", "stale_devices", "full_devices"}
        # A 202 means every item parsed, so every id it names is a spelling of an
        # id this body carried — the route invents none of its own.
        named = set(answer["stale_devices"]) | set(answer["full_devices"])
        assert named <= {str(uuid.UUID(one["device_id"])) for one in body["messages"]}

    @settings(max_examples=40)
    @given(data=st.data())
    def test_no_ack_body_reaches_an_undocumented_status_or_comes_back_echoed(
        self, http, headers, mailbox, data
    ):
        body = data.draw(self.ack_bodies(str(mailbox[0].id)))

        response = http.post(ACK_URL, json=body, headers=headers)

        assert response.status_code in (200, 400)
        if response.status_code == 400:
            envelope_body(response, "invalid_request")
        else:
            assert set(response.json()) == {"deleted"}
        for drawn in self.drawn_strings(body):
            assert drawn not in response.text

    @settings(max_examples=40)
    @given(
        limit=st.one_of(
            st.integers(min_value=-1000, max_value=1000).map(str),
            st.text(min_size=8, max_size=16),
        )
    )
    def test_no_page_size_reaches_anything_but_a_drained_mailbox(
        self, http, headers, mailbox, limit
    ):
        response = http.get(DRAIN_URL, params={"limit": limit}, headers=headers)

        assert response.status_code == 200
        body = response.json()
        assert set(body) == {"envelopes", "has_more", "pruned_through"}
        assert 1 <= len(body["envelopes"]) <= len(mailbox)
        # The echo rule holds for the values the answer could not have produced on
        # its own: a page size of `"0"` is also the digit in `pruned_through`.
        if not set(limit) <= set("0123456789-"):
            assert limit not in response.text


class TestTheMachineryBelowTheRoute:
    """What each route answers when something under it is gone.

    Three different failures, three different answers, and the difference is the
    point: a bus that is down must not fail a send whose rows are committed, a
    limiter that cannot count must refuse, and a database error must render an
    envelope that names nothing at all.
    """

    def test_a_dead_bus_still_commits_the_rows_and_still_answers_202(
        self, http, headers, target, bob, bearer, monkeypatch, settings
    ):
        """The rows are the source of truth and they are already committed, so a
        publish failure must not 500 — the client would retry and duplicate every
        envelope in the batch.

        Only the bus is broken. Redis itself stays up, because the limiter on this
        route fails closed and would answer 503 before the send ever ran.
        """

        class Unreachable:
            def pipeline(self, *_args, **_kwargs):
                raise RedisConnectionError("the bus is unreachable")

        with Listener(settings.REDIS_URL, bus.device_topic(target.id)) as subscriber:
            monkeypatch.setattr(bus, "get_client", lambda: Unreachable())

            response = http.post(
                SEND_URL,
                json={
                    "messages": [
                        {"device_id": str(target.id), "blob": envelope_blob(b"z")}
                    ]
                },
                headers=headers,
            )

            assert response.status_code == 202
            assert subscriber.received_nothing()

        drained = http.get(DRAIN_URL, headers=bearer(bob, target))
        assert [one["seq"] for one in drained.json()["envelopes"]] == [1]
        assert QueuedEnvelope.objects.filter(recipient_device_id=target.id).count() == 1

    @pytest.mark.parametrize(
        "method, url, payload",
        [
            ("POST", SEND_URL, {"messages": []}),
            ("GET", DRAIN_URL, None),
            ("POST", ACK_URL, {"ids": []}),
        ],
    )
    def test_a_limiter_that_cannot_count_refuses_before_the_route_runs(
        self, http, headers, monkeypatch, method, url, payload
    ):
        """A control whose whole purpose is to refuse traffic must not open the
        door when its store is down, and it must refuse before the body is even
        parsed — the send body here would otherwise be a 400."""

        class Unreachable:
            def pipeline(self, transaction=False):
                raise RedisConnectionError("refused")

        monkeypatch.setattr("api.ratelimit.get_client", lambda: Unreachable())

        response = http.request(method, url, headers=headers, json=payload)

        assert response.status_code == 503
        assert envelope_body(response, "unavailable")["detail"] == (
            "The service is temporarily unavailable."
        )

    def test_a_database_error_inside_the_unit_renders_an_envelope_that_names_nothing(
        self, unmasked_http, headers, device, monkeypatch
    ):
        """A database error carries the statement that raised it, and the
        statements of this app carry envelope ids — so a traceback or a `detail`
        built from the exception would put a mailbox into the response body and
        into the journal at once.

        The client here renders the `500` rather than re-raising it, which is the
        only way to read the body a real client would be given.
        """
        row = enqueue(device, 1)[0]
        statement = f"DELETE FROM messaging_queuedenvelope WHERE id = '{row.id}'"
        canary = "messaging-routes-capture-canary"

        def refuse(*_args, **_kwargs):
            raise DatabaseError(statement)

        monkeypatch.setattr(QueuedEnvelope.objects, "filter", refuse)

        with capture_all_logging() as lines:
            logging.getLogger("messaging.tests.canary").debug(canary)
            response = unmasked_http.post(
                ACK_URL, json={"ids": [str(row.id)]}, headers=headers
            )

        assert response.status_code == 500
        assert response.json() == {"code": "server_error", "detail": "Internal error."}
        assert "Traceback" not in response.text
        assert statement not in response.text
        assert str(row.id) not in response.text
        # Guards the loop below: an empty capture would pass it vacuously.
        assert any(canary in line for line in lines)
        for line in lines:
            assert str(row.id) not in line
            assert str(device.id) not in line
            assert "DELETE FROM" not in line
