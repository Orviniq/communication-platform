"""The per-app `API.md` files, held to the code and to the generated document.

These files are the human half of the contract: the retry semantics, the bucket
rules and the close codes are things a schema cannot carry, so a client author
reads them and nothing compares them to the routes. This file is that comparison.

The shape it reads is the shape the files already use.

- A route section is an `##` heading whose body carries a `**Method:**` line and
  a `**Path:**` line, each naming its values in backticks.
- A response is a `###` heading inside that section whose text names a status in
  backticks. A trailing parenthesised verb — `(PUT)` — restricts it to that
  method; without one it belongs to every method of the section.
- The throttle scope is a line beginning ``Scope `name` ``.
- The retry semantics of a route is a `**Retry semantics.**` paragraph.

Four statuses are not required per route, because a route inherits them from the
requirement it declares, from the request deadline and from the unhandled-failure
handler rather than from anything of its own: `core/API.md` carries their bodies
once for the whole surface. A route may still name one — `403 forbidden` is
route-specific — but may never name a status the code cannot answer.
"""

import json
import re
from collections import Counter

import pytest
from django.conf import settings

from core import buckets
from core.management.commands.openapi import ARTEFACT
from core.tests.test_route_table import LIMITER_PREFIX, served

REFERENCES = sorted(settings.BASE_DIR.glob("*/API.md"))

SECTION = re.compile(r"^##\s+(?!#)(.*)$", re.M)
METHOD_LINE = re.compile(r"^\*\*Method:\*\*\s*(.+)$", re.M)
PATH_LINE = re.compile(r"^\*\*Path:\*\*\s*(.+)$", re.M)
RESPONSE = re.compile(r"^###\s+.*?`(\d{3})[^`]*`(.*)$", re.M)
SCOPE = re.compile(r"^Scope `([a-z]+)`", re.M)
RETRY = re.compile(r"^\*\*Retry semantics\.\*\*", re.M)
BACKTICKED = re.compile(r"`([^`]+)`")
VERB = re.compile(r"\b(GET|POST|PUT|DELETE)\b")

# The refusals a route answers because of what it declares rather than what it
# does. `core/API.md` carries each body once.
INHERITED = {"401", "403", "500", "503"}

BUCKET_SETS = {
    "ENVELOPE_BUCKETS": buckets.ENVELOPE_BUCKETS,
    "PROFILE_BUCKETS": buckets.PROFILE_BUCKETS,
    "LABEL_BUCKETS": buckets.LABEL_BUCKETS,
    "DEVICELOG_BUCKETS": buckets.DEVICELOG_BUCKETS,
    "BACKUP_BUCKETS": buckets.BACKUP_BUCKETS,
    "ATTACHMENT_BUCKETS": buckets.ATTACHMENT_BUCKETS,
    "SIGNAL_BUCKETS": buckets.SIGNAL_BUCKETS,
}


def document():
    return json.loads((settings.BASE_DIR / ARTEFACT).read_text(encoding="utf-8"))


def documented_statuses():
    """(method, path) -> the statuses its `API.md` section publishes."""
    table = {}
    for method, path, body in sections():
        published = set()
        for status, tail in RESPONSE.findall(body):
            named = VERB.findall(tail.upper())
            if not named or method in named:
                published.add(status)
        table[(method, path)] = published
    return table


def sections():
    """(method, path, the body of the section that documents it)."""
    found = []
    for reference in REFERENCES:
        parts = SECTION.split(reference.read_text(encoding="utf-8"))
        # A preamble, then a heading and a body for each section after it.
        for body in parts[2::2]:
            methods, paths = METHOD_LINE.search(body), PATH_LINE.search(body)
            if not (methods and paths):
                continue
            for method in BACKTICKED.findall(methods.group(1)):
                for path in BACKTICKED.findall(paths.group(1)):
                    found.append((method.upper(), path, body))
    return found


def route_scopes():
    """(method, path) -> the throttle scope the code counts it against."""
    return {
        route: {
            name.removeprefix(LIMITER_PREFIX)
            for name in names
            if name.startswith(LIMITER_PREFIX)
        }
        for route, names in served().items()
    }


ROUTES = sorted(document()["paths"])
OPERATIONS = {
    (method.upper(), path): operation
    for path, methods in document()["paths"].items()
    for method, operation in methods.items()
}


def test_every_route_of_the_document_has_a_section():
    assert set(OPERATIONS) - set(documented_statuses()) == set()


def test_no_section_documents_a_route_the_surface_does_not_serve():
    assert set(documented_statuses()) - set(OPERATIONS) == set()


@pytest.mark.parametrize("route", sorted(OPERATIONS))
def test_every_route_publishes_the_statuses_it_can_answer(route):
    """Everything but the four a route inherits. A status the reference omits is
    one a client meets for the first time in production."""
    published = documented_statuses()[route]
    answerable = set(OPERATIONS[route]["responses"])

    assert answerable - INHERITED - published == set(), route


@pytest.mark.parametrize("route", sorted(OPERATIONS))
def test_no_route_publishes_a_status_the_code_cannot_answer(route):
    published = documented_statuses()[route]
    answerable = set(OPERATIONS[route]["responses"])

    assert published - answerable == set(), route


@pytest.mark.parametrize("route", sorted(OPERATIONS))
def test_every_route_names_the_throttle_scope_it_counts_against(route):
    """The scope, not just the rate: two routes on one scope share a counter, and
    a client that pages one is throttled on the other."""
    body = next(body for method, path, body in sections() if (method, path) == route)

    assert set(SCOPE.findall(body)) == route_scopes()[route], route


@pytest.mark.parametrize("route", sorted(OPERATIONS))
def test_every_route_documents_what_a_retry_does(route):
    """ADR-0007 refuses an idempotency store, because a stored response for a send
    would link a sender to its recipients at rest. The retry semantics are what
    stands in its place, and they are contract rather than commentary.

    Every route, not only the mutating ones the ADR names. A client writing a
    retry policy reads one paragraph per route or it reads none, and "this route
    is a read" is a fact about the route that only the route can state: the method
    does not carry it.
    """
    body = next(body for method, path, body in sections() if (method, path) == route)

    assert RETRY.search(body) is not None, route


@pytest.mark.parametrize("name", sorted(BUCKET_SETS))
def test_core_publishes_every_bucket_set_that_exists(name):
    """An off-bucket payload is a `400 bad_bucket` with no echo, so the sizes are
    the only way a client learns what to pad to."""
    table = (settings.BASE_DIR / "core" / "API.md").read_text(encoding="utf-8")
    row = next(
        (line for line in table.splitlines() if line.startswith(f"| `{name}`")), None
    )
    assert row is not None, name

    published = [int(value.replace(",", "")) for value in re.findall(r"\d[\d,]*", row)]

    assert published == BUCKET_SETS[name], name


# `core/API.md` opens with the vocabulary table: one row per error code, with the
# status that carries it. `| 400 | `invalid_request` | … |`
VOCABULARY_ROW = re.compile(r"^\|\s*(\d{3})\s*\|\s*`([a-z_]+)`\s*\|", re.M)
# The two codes the table publishes that no *operation* declares, for two
# different reasons. `device_scope_required` is reserved: `core/API.md` records
# that it belongs to a route whose requirement does not supply a device-bound
# token, and every route now takes one that does. `method_not_allowed` is answered
# before the surface has chosen a route at all, so it belongs to no operation and
# `api/schema.py` therefore does not carry it.
RESERVED = "device_scope_required"
PRE_ROUTE = "method_not_allowed"
# How `api/schema.py` writes a code into a response description: "`code`, `code`".
DESCRIBED_CODE = re.compile(r"`([a-z_]+)`")


def published_vocabulary():
    table = (settings.BASE_DIR / "core" / "API.md").read_text(encoding="utf-8")
    return {code: int(status) for status, code in VOCABULARY_ROW.findall(table)}


def test_the_published_vocabulary_is_the_one_the_code_carries():
    """A client branches on `code`, so the table is the contract and not a
    summary of it. A code the surface can answer and the table omits is one a
    client meets for the first time in production; a code the table carries and
    the surface cannot answer is one a client writes a branch for and never
    reaches."""
    from api.schema import VOCABULARY

    assert set(published_vocabulary()) == set(VOCABULARY) | {RESERVED, PRE_ROUTE}


@pytest.mark.parametrize(
    "code", sorted(set(published_vocabulary()) - {RESERVED, PRE_ROUTE})
)
def test_every_published_code_carries_the_status_the_code_assigns_it(code):
    """The status is half the contract: a client that retries on `503` and gives
    up on `500` needs the row to say which one a code arrives with.

    The two codes above are excluded from the list rather than skipped inside the
    test: neither is in `VOCABULARY` at all, so there is nothing to compare them
    against, and the test above is what holds them to the table."""
    from api.schema import VOCABULARY

    assert published_vocabulary()[code] == VOCABULARY[code]


def test_the_pre_route_refusal_is_the_one_the_router_answers():
    """`method_not_allowed` belongs to no operation because it is answered before
    one is chosen, so the only place it can be pinned is the handler that renders
    it — and `Allow` is the one thing a client can recover from."""
    from api.errors import _ROUTING_REFUSALS

    assert _ROUTING_REFUSALS[405][0] == PRE_ROUTE
    assert published_vocabulary()[PRE_ROUTE] == 405


def test_the_reserved_code_is_raised_by_nothing_that_ships():
    """`core/API.md` says `device_scope_required` belongs to a route that needs a
    device-bound token where the requirement does not supply one, and that no
    route returns it today. A raise site would make that sentence false — and the
    document would publish a status for it nowhere."""
    raising = [
        str(path.relative_to(settings.BASE_DIR))
        for path in settings.BASE_DIR.rglob("*.py")
        if path.relative_to(settings.BASE_DIR).parts[0] not in {".venv", "vendor"}
        and "tests" not in path.relative_to(settings.BASE_DIR).parts
        and f'"{RESERVED}"' in path.read_text()
    ]

    assert raising == []


def test_every_code_the_document_describes_is_in_the_published_table():
    """`api/schema.py` writes the codes of a route into the description of each
    status it declares, so the document already names them — and a code that
    reached the document without reaching the table is one nobody documented."""
    described = set()
    for operation in OPERATIONS.values():
        for status, response in operation["responses"].items():
            if int(status) >= 400:
                described |= set(DESCRIBED_CODE.findall(response["description"]))

    assert described - set(published_vocabulary()) == set()
    assert len(described) > 5


# --- The one prose count of the surface, held to the surface -----------------------
# `API_CHANGES.md` closes with "What the client can build against now", which is the
# section a client author reads first. It states the shape of the surface in numbers,
# and a number in prose is the thing in this repository most likely to rot: nothing
# regenerates it, and a route added or removed leaves it describing a server that no
# longer exists. Every figure it carries is derived below from the artefact and the
# route table, so the section fails with the change rather than after it.

CHANGES = "API_CHANGES.md"
SECTION_HEADING = "## What the client can build against now"


def build_against_section():
    """The text of that section, from its heading to the next `##`."""
    text = (settings.BASE_DIR.parent / CHANGES).read_text(encoding="utf-8")
    start = text.index(SECTION_HEADING)
    tail = text[start + len(SECTION_HEADING) :]
    end = tail.find("\n## ")
    return tail if end == -1 else tail[:end]


def test_the_section_the_client_reads_first_counts_the_surface_it_describes():
    """Operations, paths, and the per-app split, against the generated document."""
    doc = document()
    operations = [
        (method, path, body)
        for path, item in doc["paths"].items()
        for method, body in item.items()
    ]
    by_tag = Counter(tag for _m, _p, body in operations for tag in body.get("tags", []))
    section = build_against_section()

    assert f"**{len(operations)} operations over {len(doc['paths'])}" in section
    for tag, count in by_tag.items():
        row = f"backend/{tag}/API.md) | {count} |"
        assert row in section, f"{tag} serves {count} operations; the table disagrees"
    assert len(by_tag) == len(
        [line for line in section.splitlines() if line.startswith("| [`")]
    )


def test_the_section_counts_the_methods_and_the_statuses_the_document_declares():
    """The two sentences under the table. A status published by a different number of
    operations than the sentence claims is a client planning for the wrong branches."""
    doc = document()
    operations = [
        body for item in doc["paths"].values() for _method, body in item.items()
    ]
    methods = Counter(method.upper() for item in doc["paths"].values() for method in item)
    statuses = Counter(
        status for body in operations for status in body.get("responses", {})
    )
    section = build_against_section()

    ordered = ", ".join(
        f"{count} `{method}`" for method, count in sorted(methods.items())
    )
    # "13 `GET`, 12 `POST`, 5 `PUT` and 2 `DELETE`" — the same pairs, last one joined
    # by "and", so the assertion is on the pairs rather than on the punctuation.
    for pair in ordered.split(", "):
        assert pair in section, pair
    for status in ("400", "413", "404", "409"):
        assert f"{statuses[status]} declare `{status}`" in section or (
            f"{statuses[status]} `{status}`" in section
        ), f"`{status}` is declared by {statuses[status]} operations"


def test_the_section_counts_the_three_authentication_requirements():
    """Anonymous, register-scope, and session-bound. A client reads this to know how
    many doors exist before it has a token at all."""
    from core.tests.test_route_table import ANONYMOUS, EXPECTED, REGISTER_OR_FULL

    requirements = Counter(requirement for requirement, _scope in EXPECTED.values())
    section = build_against_section()

    assert f"**{requirements[ANONYMOUS]} of the {len(EXPECTED)} take no" in section
    assert requirements[REGISTER_OR_FULL] == 1
    full = len(EXPECTED) - requirements[ANONYMOUS] - requirements[REGISTER_OR_FULL]
    assert f"**The other {full} take a session token" in section
