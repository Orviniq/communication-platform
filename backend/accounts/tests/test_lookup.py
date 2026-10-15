"""`POST /api/v1/users/lookup` and the setting that hides an account from it.

The route that replaced the directory (ADR-0028). What it must hold, each asserted
here rather than claimed:

* one account by its exact name, after lowercasing, and nothing about it but its
  id and its name;
* an unknown name, an inactive account and an account whose owner turned
  discoverability off answer alike — the same status, the same body, the same
  headers, the same statement and the same index pages;
* the name never travels in the path or a query string;
* the `lookup` scope, separate from `accounts` and spent by every outcome;
* the setting reaches the lookup and nothing addressed by a `user_id`.
"""

import json
import re

import pytest
from django.conf import settings as django_settings
from django.db import connection
from django.test.utils import CaptureQueriesContext

from accounts.models import ProfileBlob, User
from core.buckets import PROFILE_BUCKETS
from core.management.commands.openapi import ARTEFACT
from devices.models import Device

# transaction=True because the ORM bracket of `api.orm.run_unit` closes the
# connection around every unit of work, which under a wrapping test transaction
# would sever the connection the test itself holds.
pytestmark = pytest.mark.django_db(transaction=True)

LOOKUP_URL = "/api/v1/users/lookup"
DISCOVERABILITY_URL = "/api/v1/me/discoverability"
MY_PROFILE_URL = "/api/v1/me/profile"
NOT_FOUND = {"code": "not_found", "detail": "No account can be found by that name."}
# Nothing listens on port 1, so the limiter's first command raises `RedisError`.
DEAD_REDIS = "redis://127.0.0.1:1/0"


@pytest.fixture
def headers(active_user, device, bearer):
    return bearer(active_user, device)


@pytest.fixture
def hidden_three(db):
    """One account in each state the route must not tell apart from a name nobody
    holds: awaiting activation, and activated with discoverability off."""
    User.objects.create_user(username="pending")
    User.objects.create_user(username="hidden", is_active=True, discoverable=False)
    return ("nobody", "pending", "hidden")


def look_up(http, headers, name):
    return http.post(LOOKUP_URL, headers=headers, json={"username": name})


def store_value_of(keys, values, wanted):
    return dict(zip(keys, values))[wanted]


def device_of(user, registration_id):
    return Device.objects.create(
        user=user,
        ik_pub=b"ik",
        spk_id=1,
        spk_pub=b"spk",
        spk_sig=b"sig",
        registration_id=registration_id,
    )


class TestTheAnswer:
    def test_an_exact_name_answers_the_id_and_the_name_and_nothing_else(
        self, http, headers, bob
    ):
        response = look_up(http, headers, "bob")

        assert response.status_code == 200
        assert response.json() == {"user_id": str(bob.id), "username": "bob"}

    def test_the_name_is_lowercased_before_it_is_looked_up(self, http, headers, bob):
        """The account table holds names lowercased, so `BoB` is `bob` here exactly
        as it is at registration."""
        response = look_up(http, headers, "BoB")

        assert response.json() == {"user_id": str(bob.id), "username": "bob"}

    @pytest.mark.parametrize("name", ["bobb", "abob", "bo_", "b_b", "bob_"])
    def test_a_near_name_finds_nothing(self, http, headers, bob, name):
        """No prefix, no substring and no fuzzy match. `b_b` is the case a `LIKE`
        would answer: `_` is a wildcard there and a character here."""
        response = look_up(http, headers, name)

        assert (response.status_code, response.json()) == (404, NOT_FOUND)

    def test_the_caller_finds_itself_only_while_it_is_discoverable(
        self, http, headers, active_user
    ):
        """The setting is the owner's own and the route has no exception for the
        owner, so the client can show a user what everybody else now gets."""
        found = look_up(http, headers, "alice")
        http.put(DISCOVERABILITY_URL, headers=headers, json={"discoverable": False})

        hidden = look_up(http, headers, "alice")

        assert found.json()["user_id"] == str(active_user.id)
        assert (hidden.status_code, hidden.json()) == (404, NOT_FOUND)

    def test_a_lookup_writes_nothing(self, http, headers, bob):
        with CaptureQueriesContext(connection) as context:
            look_up(http, headers, "bob")
            look_up(http, headers, "nobody")

        statements = [query["sql"].split(None, 1)[0] for query in context]
        assert set(statements) <= {"SELECT", "BEGIN", "COMMIT"}, statements


class TestTheThreeCasesAreOneAnswer:
    def test_status_body_and_headers_are_identical(self, http, headers, hidden_three):
        responses = [look_up(http, headers, name) for name in hidden_three]

        assert {response.status_code for response in responses} == {404}
        assert [response.json() for response in responses] == [NOT_FOUND] * 3
        assert len({response.content for response in responses}) == 1
        assert (
            len({tuple(sorted(response.headers.items())) for response in responses}) == 1
        )

    def test_each_is_the_same_statement_with_a_different_name_in_it(
        self, http, headers, hidden_three
    ):
        """One statement shape for all three, so nothing in the query that ran
        says which case it was. The filter is in the `WHERE` rather than in
        Python, which is what makes this hold."""
        shapes = []
        for name in hidden_three:
            with CaptureQueriesContext(connection) as context:
                look_up(http, headers, name)
            [lookup] = [
                query["sql"]
                for query in context
                if query["sql"].startswith("SELECT")
                and "devices_device" not in query["sql"]
            ]
            assert f"'{name}'" in lookup
            shapes.append(lookup.replace(f"'{name}'", "'?'"))

        assert len(set(shapes)) == 1, shapes

    def test_a_deactivated_account_answers_exactly_as_one_never_activated(
        self, http, headers, bob
    ):
        """The operator's deactivation reaches the lookup on the next call, and a
        deactivated name is indistinguishable from a name nobody holds."""
        found = look_up(http, headers, "bob")
        User.objects.filter(pk=bob.pk).update(is_active=False)

        deactivated = look_up(http, headers, "bob")
        unknown = look_up(http, headers, "nobody")

        assert found.status_code == 200
        assert (deactivated.status_code, deactivated.content) == (404, unknown.content)


# Enough rows that the planner reads an index rather than scanning the table — it
# switches between 200 and 400 rows (measured, ADR-0028) — and few enough that
# seeding and analysing them costs well under a second.
INDEXED_ROWS = 1000


def seed_accounts(count):
    """`count` accounts in one statement: every fifth awaiting activation, every
    seventh active and hidden, the rest findable. Plain SQL, because a thousand
    `create_user` calls would be a thousand round trips for rows no assertion
    reads one at a time."""
    with connection.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO accounts_user
                (id, password, is_superuser, username, is_active, is_staff,
                 created_date, discoverable)
            SELECT gen_random_uuid(), '!', false, 'seed' || lpad(n::text, 5, '0'),
                   n %% 5 <> 0, false, CURRENT_DATE, n %% 7 <> 0
            FROM generate_series(1, %s) AS n
            """,
            [count],
        )
        cursor.execute("ANALYZE accounts_user")


def plan_of(sql):
    with connection.cursor() as cursor:
        cursor.execute(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql}")
        return cursor.fetchone()[0][0]["Plan"]


def scan_node(plan):
    while "Index Name" not in plan and "Plans" in plan:
        plan = plan["Plans"][0]
    return plan


def the_lookup_statement(http, headers, name):
    with CaptureQueriesContext(connection) as context:
        look_up(http, headers, name)
    [lookup] = [
        query["sql"]
        for query in context
        if query["sql"].startswith("SELECT") and "devices_device" not in query["sql"]
    ]
    return lookup


class TestTheIndexIsRead:
    """Index use confirmed rather than assumed: the statement the route actually
    ran, re-run under `EXPLAIN ANALYZE` at a row count where the planner reads an
    index."""

    @pytest.fixture
    def seeded(self, active_user):
        seed_accounts(INDEXED_ROWS)
        # seed00010: inactive. seed00014: active and hidden. seed00012: findable.
        assert User.objects.get(username="seed00010").is_active is False
        assert User.objects.get(username="seed00014").discoverable is False
        return {
            "found": "seed00012",
            "unknown": "seed00011x",
            "inactive": "seed00010",
            "hidden": "seed00014",
        }

    def test_every_lookup_reads_the_findable_name_index(self, http, headers, seeded):
        for case, name in seeded.items():
            node = scan_node(plan_of(the_lookup_statement(http, headers, name)))

            assert node["Node Type"] in ("Index Scan", "Index Only Scan"), case
            assert node["Index Name"] == "ix_user_findable_name", case

    def test_the_three_hidden_cases_read_the_same_pages_and_no_row(
        self, http, headers, seeded
    ):
        """A miss in the partial index for every one of them: no heap row is
        fetched and filtered out, which is what the unique index on `username`
        would have done for the two names that exist."""
        work = {}
        for case in ("unknown", "inactive", "hidden"):
            node = scan_node(plan_of(the_lookup_statement(http, headers, seeded[case])))
            assert node["Actual Rows"] == 0, case
            assert node.get("Rows Removed by Filter", 0) == 0, case
            assert "Filter" not in node, case
            work[case] = node["Shared Hit Blocks"] + node["Shared Read Blocks"]

        assert len(set(work.values())) == 1, work


class TestTheNameStaysOutOfTheAddress:
    def test_the_operation_declares_no_path_or_query_parameter(self):
        document = json.loads(
            (django_settings.BASE_DIR / ARTEFACT).read_text(encoding="utf-8")
        )
        operation = document["paths"][LOOKUP_URL]["post"]

        assert operation.get("parameters", []) == []
        assert set(document["paths"][LOOKUP_URL]) == {"post"}
        assert operation["requestBody"]["required"] is True

    def test_no_operation_of_the_surface_takes_a_name_in_its_address(self):
        """The whole document, not only this route: a later route that puts a
        username in a path or a query string is a name in every log in front of
        this process."""
        document = json.loads(
            (django_settings.BASE_DIR / ARTEFACT).read_text(encoding="utf-8")
        )
        addressed = {
            (path, method, parameter["name"])
            for path, methods in document["paths"].items()
            for method, operation in methods.items()
            for parameter in operation.get("parameters", [])
            if parameter["in"] in ("path", "query")
            and re.search("name|user(?!_id)", parameter["name"])
        }

        assert addressed == set()

    def test_a_name_in_the_query_string_is_not_read(self, http, headers, bob):
        response = http.post(f"{LOOKUP_URL}?username=bob", headers=headers, json={})

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"

    def test_there_is_no_read_by_get(self, http, headers):
        response = http.get(LOOKUP_URL, headers=headers)

        assert response.status_code == 405


class TestRefusals:
    @pytest.mark.parametrize(
        "body",
        [
            {},
            {"username": "ab"},
            {"username": "a" * 33},
            {"username": "bad name"},
            {"username": "bad\x00name"},
            {"username": 7},
            {"username": None},
            {"username": "bob", "fuzzy": True},
        ],
        ids=[
            "missing",
            "too short",
            "too long",
            "a space",
            "a NUL byte",
            "not a string",
            "null",
            "an extra field",
        ],
    )
    def test_a_name_no_account_could_hold_is_an_invalid_request(
        self, http, headers, body
    ):
        """A `400` tells the caller the rule registration already publishes and
        nothing about any account; the NUL byte would otherwise reach psycopg,
        which refuses the statement rather than finding no row."""
        response = http.post(LOOKUP_URL, headers=headers, json=body)

        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"
        for value in body.values():
            if isinstance(value, str) and len(value) > 2:
                assert value not in response.text

    def test_a_register_token_is_refused(self, http, active_user, register_bearer):
        response = look_up(http, register_bearer(active_user), "alice")

        assert response.status_code == 403
        assert response.json()["code"] == "scope_forbidden"

    def test_no_token_is_refused(self, http):
        response = http.post(LOOKUP_URL, json={"username": "alice"})

        assert response.status_code == 401


class TestTheSettingReachesTheLookup:
    def test_turning_it_off_hides_the_name_and_turning_it_on_shows_it(
        self, http, headers, bob, bearer
    ):
        bobs = bearer(bob, device_of(bob, 2))

        off = http.put(DISCOVERABILITY_URL, headers=bobs, json={"discoverable": False})
        while_off = look_up(http, headers, "bob")
        on = http.put(DISCOVERABILITY_URL, headers=bobs, json={"discoverable": True})
        while_on = look_up(http, headers, "bob")

        assert (off.status_code, off.json()) == (200, {"discoverable": False})
        assert (while_off.status_code, while_off.json()) == (404, NOT_FOUND)
        assert (on.status_code, on.json()) == (200, {"discoverable": True})
        assert while_on.json()["user_id"] == str(bob.id)


class TestTheSettingReachesNothingAddressedByAnId:
    """The honest limit the documents state: hiding a name hides the name. A
    caller who already holds the `user_id` — from a group it shares, say — still
    reaches every route addressed by one."""

    def test_a_hidden_accounts_profile_is_still_served_by_its_id(
        self, http, headers, bob
    ):
        ProfileBlob.objects.create(user=bob, blob=b"\x01" * PROFILE_BUCKETS[0], version=2)
        User.objects.filter(pk=bob.pk).update(discoverable=False)

        by_name = look_up(http, headers, "bob")
        by_id = http.get(f"/api/v1/users/{bob.id}/profile", headers=headers)

        assert by_name.status_code == 404
        assert by_id.status_code == 200

    def test_a_hidden_accounts_devices_are_still_listed_by_its_id(
        self, http, headers, bob
    ):
        device_of(bob, 3)
        User.objects.filter(pk=bob.pk).update(discoverable=False)

        response = http.get(f"/api/v1/users/{bob.id}/devices", headers=headers)

        assert response.status_code == 200
        assert len(response.json()["devices"]) == 1


class TestTheLookupScope:
    def test_the_lookup_spends_its_own_scope_and_not_the_accounts_one(
        self, http, headers, settings, one_rate_limit_window
    ):
        settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "lookup": "1/min"}

        served = look_up(http, headers, "nobody")
        refused = look_up(http, headers, "nobody")
        elsewhere = http.get(DISCOVERABILITY_URL, headers=headers)

        assert served.status_code == 404
        assert refused.status_code == 429
        assert refused.json() == {"code": "throttled", "detail": "Request was throttled."}
        assert 0 < int(refused.headers["retry-after"]) <= 60
        assert elsewhere.status_code == 200

    def test_a_spent_accounts_scope_leaves_the_lookup_alone(
        self, http, headers, settings, bob, one_rate_limit_window
    ):
        settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "accounts": "1/min"}
        http.get(DISCOVERABILITY_URL, headers=headers)

        assert http.get(DISCOVERABILITY_URL, headers=headers).status_code == 429
        assert look_up(http, headers, "bob").status_code == 200

    @pytest.mark.parametrize(
        "spend",
        [
            pytest.param({"username": "bob"}, id="a found name"),
            pytest.param({"username": "nobody"}, id="an unknown name"),
            pytest.param({"username": "pending"}, id="an inactive name"),
            pytest.param({"username": "x"}, id="a refused name"),
            pytest.param({"unexpected": True}, id="a refused body"),
        ],
    )
    def test_every_outcome_spends_the_scope(
        self, http, headers, settings, bob, spend, one_rate_limit_window
    ):
        """Counted before the body is validated, so a guesser cannot probe for
        free by sending something the route refuses."""
        User.objects.create_user(username="pending")
        settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "lookup": "1/min"}
        http.post(LOOKUP_URL, headers=headers, json=spend)

        assert look_up(http, headers, "bob").status_code == 429

    def test_the_scope_follows_the_account_across_its_devices(
        self, http, active_user, device, bearer, settings, one_rate_limit_window
    ):
        """Counted per account, so a second device is not a second budget."""
        settings.THROTTLE_RATES = {**settings.THROTTLE_RATES, "lookup": "1/min"}
        second = device_of(active_user, 4)

        look_up(http, bearer(active_user, device), "nobody")

        assert look_up(http, bearer(active_user, second), "nobody").status_code == 429

    def test_the_one_trace_a_lookup_leaves_is_a_count_for_the_account_and_the_day(
        self, http, active_user, headers, settings, bob
    ):
        """What `backend/SECURITY.md` says a lookup records, exactly: one Redis key
        naming the asking account and the UTC day, holding a count, expiring with
        the day's window — and the name looked up in no key and no value."""
        import time

        import redis

        day = int(time.time()) // 86400
        look_up(http, headers, "bob")
        look_up(http, headers, "nobody_at_all")

        store = redis.Redis.from_url(settings.REDIS_URL)
        try:
            keys = [key.decode() for key in store.keys("*")]
            values = [store.get(key) for key in keys]
            ttls = [store.ttl(key) for key in keys if key.startswith("ratelimit:lookup:")]
        finally:
            store.close()

        lookup_keys = [key for key in keys if key.startswith("ratelimit:lookup:")]
        assert lookup_keys in (
            [f"ratelimit:lookup:user:{active_user.id}:{day}"],
            [f"ratelimit:lookup:user:{active_user.id}:{day + 1}"],
        )
        assert store_value_of(keys, values, lookup_keys[0]) == b"2"
        assert all(0 < ttl <= 86400 for ttl in ttls)
        for text in [*keys, *(value.decode() for value in values if value)]:
            assert "bob" not in text and "nobody_at_all" not in text, text

    def test_an_unreachable_counter_store_refuses_rather_than_answers(
        self, http, headers, settings, bob
    ):
        """Fails closed (ADR-0010): the scope is the whole of what stands between a
        session and a dictionary, so an outage of its store is an outage of the
        route and never an unmetered one."""
        settings.REDIS_URL = DEAD_REDIS

        response = look_up(http, headers, "bob")

        assert response.status_code == 503
        assert response.json()["code"] == "unavailable"
        assert "bob" not in response.text
