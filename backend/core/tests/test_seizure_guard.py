"""Repo-wide seizure/graph guard: the durable regression check.

Iterates every concrete model in the app registry and fails loudly if any model, in
any app, present or future, grows a plaintext column, key material, or a conversation
graph. `core/tests/test_manifest.py` is the narrower field manifest; this guard is
the stricter superset. Both stay: each is self-contained, so weakening one cannot
silently weaken the other.

The checks are pure module-level functions returning offender lists so they can be
driven outside this file (test_success_criteria.py, and break-the-guard proofs that
register a canary model and assert the function flags it).
"""

from unittest import mock

from django.apps import apps
from django.db import models
from django.db.models import BinaryField
from django.test import SimpleTestCase
from django.test.utils import isolate_apps

from accounts.models import User
from core.fields import OpaqueBlobField

# Column names that would mean plaintext content, key material, or a stored graph.
# Checked against both the field name and its column attname, so an FK spelled
# `sender` cannot hide behind `sender_id`.
FORBIDDEN_FIELD_NAMES = frozenset(
    {
        "plaintext",
        "content",
        "message_text",
        "body",
        "private_key",
        "secret_key",
        "session_key",
        "media_key",
        "room_key",
        "dtls_key",
        "srtp_key",
        "sender",
        "sender_id",
        "recipient_id",
        "recipients",
        "members",
        "membership",
        "roster",
        "group_members",
        "password_plain",
    }
)

# `password` holds an Argon2id hash: auth material, never a content key.
PASSWORD_ALLOWED_ON = frozenset({"accounts.User"})

# The framework tables are audited once. Django's `session_key` is the opaque id of
# an admin-only session (the API is token-auth), not key material. Nothing else is
# exempt, and a test below pins this set so it cannot quietly grow.
AUDITED_FRAMEWORK_COLUMNS = frozenset(
    {
        "sessions.Session.session_key",
    }
)

# This project's own apps: the tables a seizure of this backend would yield.
APP_LABELS = frozenset(
    {
        "accounts",
        "devices",
        "vault",
        "messaging",
        "attachments",
        "core",
        "realtime",
    }
)

# Public halves of client keypairs are stored as plain BinaryFields: suffixed
# `_pub`/`_sig`, plus OneTimePrekey's bare `pub`.
PUBLIC_KEY_SUFFIXES = ("_pub", "_sig")
PUBLIC_KEY_NAMES = frozenset({"pub"})


def _label(model):
    return f"{model._meta.app_label}.{model.__name__}"


def _concrete_fields(model):
    """Declared columns and m2m fields; reverse accessors are not columns."""
    for field in model._meta.get_fields():
        if field.auto_created and not field.concrete:
            continue
        yield field


def forbidden_column_offenders():
    """No model may declare a plaintext/key/graph column."""
    offenders = []
    for model in apps.get_models():
        label = _label(model)
        for field in _concrete_fields(model):
            names = {field.name, getattr(field, "attname", field.name)}
            if any(f"{label}.{n}" in AUDITED_FRAMEWORK_COLUMNS for n in names):
                continue
            if names & FORBIDDEN_FIELD_NAMES:
                offenders.append(f"{label}.{field.name}")
            elif "password" in names and label not in PASSWORD_ALLOWED_ON:
                offenders.append(f"{label}.{field.name}")
    return offenders


def unbucketed_blob_offenders():
    """Every ciphertext field (`blob` / `*_blob`) is an OpaqueBlobField with a
    non-empty bucket_set; public-key byte fields may stay plain BinaryFields."""
    offenders = []
    for model in apps.get_models():
        for field in _concrete_fields(model):
            name = field.name
            if name.endswith(PUBLIC_KEY_SUFFIXES) or name in PUBLIC_KEY_NAMES:
                continue
            if name == "blob" or name.endswith("_blob"):
                if not isinstance(field, OpaqueBlobField):
                    offenders.append(f"{_label(model)}.{name}: {type(field).__name__}")
                elif not field.bucket_set:
                    offenders.append(f"{_label(model)}.{name}: empty bucket_set")
    return offenders


def raw_binary_offenders():
    """Belt-and-braces for this project's own tables: a BinaryField that is neither a
    declared public key nor an OpaqueBlobField is an unvalidated byte store, the
    exact shape a future plaintext/key column would take while dodging the name
    checks."""
    offenders = []
    for model in apps.get_models():
        if model._meta.app_label not in APP_LABELS:
            continue
        for field in _concrete_fields(model):
            if not isinstance(field, BinaryField):
                continue
            if isinstance(field, OpaqueBlobField):
                continue
            name = field.name
            if name.endswith(PUBLIC_KEY_SUFFIXES) or name in PUBLIC_KEY_NAMES:
                continue
            offenders.append(f"{_label(model)}.{name}")
    return offenders


def envelope_graph_offenders():
    """The envelope's only relation is to a recipient device: no sender in any
    spelling, structurally (sealed sender at rest)."""
    from messaging.models import QueuedEnvelope

    offenders = []
    fks = []
    for field in _concrete_fields(QueuedEnvelope):
        if "sender" in field.name or "sender" in getattr(field, "attname", ""):
            offenders.append(f"messaging.QueuedEnvelope.{field.name} mentions a sender")
        if field.is_relation:
            fks.append(field)
    if [
        f"{fk.related_model._meta.app_label}.{fk.related_model.__name__}" for fk in fks
    ] != ["devices.Device"]:
        offenders.append(
            "messaging.QueuedEnvelope must have exactly one relation, to devices.Device; "
            f"found {[fk.name for fk in fks]}"
        )
    return offenders


def dual_user_fk_offenders():
    """Outside `accounts`, no table may hold two references to users: the shape that
    would encode a sender-recipient pair at rest. history/keybackup/attachment each
    reference only their owner/uploader."""
    from accounts.models import User

    offenders = []
    for model in apps.get_models():
        if model._meta.app_label == "accounts":
            continue
        user_fks = [
            f.name
            for f in _concrete_fields(model)
            if f.is_relation and f.related_model is User
        ]
        if len(user_fks) > 1:
            offenders.append(f"{_label(model)}: {user_fks}")
    return offenders


class SeizureGuardTests(SimpleTestCase):
    """One test per invariant."""

    def test_no_model_declares_a_plaintext_key_or_graph_column(self):
        self.assertEqual(
            forbidden_column_offenders(),
            [],
            "A model grew a column this architecture forbids",
        )

    def test_every_ciphertext_field_is_an_exact_bucket_opaque_blob(self):
        self.assertEqual(
            unbucketed_blob_offenders(),
            [],
            "Every stored blob must be OpaqueBlobField with buckets",
        )

    def test_no_app_table_holds_unclassified_binary_data(self):
        self.assertEqual(
            raw_binary_offenders(),
            [],
            "A raw BinaryField outside the public-key set appeared",
        )

    def test_envelopes_have_no_sender_and_route_only_to_a_device(self):
        self.assertEqual(
            envelope_graph_offenders(), [], "Sealed sender at rest was broken"
        )

    def test_no_table_outside_accounts_references_users_twice(self):
        self.assertEqual(
            dual_user_fk_offenders(), [], "A sender-recipient-shaped table appeared"
        )

    def test_the_framework_exemption_list_cannot_quietly_grow(self):
        self.assertEqual(
            AUDITED_FRAMEWORK_COLUMNS,
            {"sessions.Session.session_key"},
            "Every new exemption needs an audit entry and review here",
        )

    def test_the_guard_actually_sees_this_schema(self):
        # Anti-vacuity: introspection must be walking the real registry. If any known
        # table or ciphertext column stops being visible, the guard itself is broken.
        seen = {_label(m) for m in apps.get_models()}
        self.assertLessEqual(
            {
                "accounts.User",
                "accounts.ProfileBlob",
                "devices.Device",
                "devices.OneTimePrekey",
                "devices.PqOneTimePrekey",
                "devices.DeviceLogRecord",
                "devices.UserIdentity",
                "vault.KeyBackup",
                "messaging.QueuedEnvelope",
                "attachments.Attachment",
            },
            seen,
        )
        blob_names = {
            f"{_label(m)}.{f.name}"
            for m in apps.get_models()
            for f in _concrete_fields(m)
            if isinstance(f, OpaqueBlobField)
        }
        self.assertLessEqual(
            {
                "accounts.ProfileBlob.blob",
                "devices.Device.label_blob",
                "devices.DeviceLogRecord.blob",
                "vault.KeyBackup.blob",
                "messaging.QueuedEnvelope.blob",
            },
            blob_names,
        )


# State the threat model keeps in Redis and nowhere else (invariant 7). A column
# with one of these names is a login record, a presence record or a rate counter
# at rest — each of them a thing a seizure of the disk would yield.
VOLATILE_ONLY_NAMES = frozenset(
    {
        "failed_attempts",
        "failure_count",
        "login_attempts",
        "attempt_count",
        "lockout",
        "locked_until",
        "cooloff_until",
        "rate_limit",
        "throttle",
        "presence",
        "last_seen",
        "online",
        "signal",
        "ice_candidate",
    }
)


def volatile_state_offenders():
    """No model may persist the state that lives in Redis by rule."""
    return [
        f"{_label(model)}.{field.name}"
        for model in apps.get_models()
        if model._meta.app_label in APP_LABELS
        for field in _concrete_fields(model)
        if field.name in VOLATILE_ONLY_NAMES
    ]


class VolatileStateGuardTests(SimpleTestCase):
    def test_no_table_holds_lockout_presence_or_rate_state(self):
        """The lockout counts in Redis and the rate counters live in Redis —
        because a table of either is a record of who was where and when, kept past
        the moment it mattered."""
        self.assertEqual(
            volatile_state_offenders(),
            [],
            "state that must stay volatile reached the schema",
        )


class GuardCanaryTests(SimpleTestCase):
    """Break-the-guard proofs.

    Every audit above returns `[]` today, which is exactly what a broken
    introspection would return too: a typo in `_concrete_fields`, a rename in
    Django's `_meta` API, or a registry that came back empty would leave this file
    green while proving nothing. These register a model that violates one rule and
    assert the audit names it.

    The canaries are declared in an isolated app registry, so nothing is added to
    the real one, and the audits are pointed at that registry for the length of the
    check. `related_name="+"` on the foreign keys keeps the real `User` class from
    growing a reverse accessor to a model that exists for three lines.
    """

    def audited(self, audit, *models):
        stub = type("Registry", (), {"get_models": staticmethod(lambda: list(models))})
        with mock.patch(f"{__name__}.apps", stub):
            return audit()

    def test_a_plaintext_column_is_named(self):
        with isolate_apps("core"):

            class Canary(models.Model):
                plaintext = models.TextField()

                class Meta:
                    app_label = "core"

            self.assertEqual(
                self.audited(forbidden_column_offenders, Canary),
                ["core.Canary.plaintext"],
            )

    def test_a_sender_hidden_behind_its_column_name_is_named(self):
        """The audit checks `attname` as well as `name`, so a foreign key spelled
        `sender` cannot pass as `sender_id`."""
        with isolate_apps("core"):

            class Canary(models.Model):
                sender = models.ForeignKey(
                    User, on_delete=models.CASCADE, related_name="+"
                )

                class Meta:
                    app_label = "core"

            self.assertEqual(
                self.audited(forbidden_column_offenders, Canary), ["core.Canary.sender"]
            )

    def test_a_password_column_outside_the_user_model_is_named(self):
        with isolate_apps("core"):

            class Canary(models.Model):
                password = models.CharField(max_length=128)

                class Meta:
                    app_label = "core"

            self.assertEqual(
                self.audited(forbidden_column_offenders, Canary), ["core.Canary.password"]
            )

    def test_a_ciphertext_column_that_is_not_an_opaque_blob_is_named(self):
        with isolate_apps("core"):

            class Canary(models.Model):
                message_blob = models.BinaryField()

                class Meta:
                    app_label = "core"

            self.assertEqual(
                self.audited(unbucketed_blob_offenders, Canary),
                ["core.Canary.message_blob: BinaryField"],
            )

    def test_an_opaque_blob_that_lost_its_buckets_is_named(self):
        """The shape a refactor produces: the right field class, and nothing left
        deciding what length the payload may be."""
        with isolate_apps("core"):

            class Canary(models.Model):
                blob = OpaqueBlobField(bucket_set=[])

                class Meta:
                    app_label = "core"

            self.assertEqual(
                self.audited(unbucketed_blob_offenders, Canary),
                ["core.Canary.blob: empty bucket_set"],
            )

    def test_an_unclassified_byte_store_is_named_even_when_it_is_not_called_a_blob(self):
        """The exact shape a future plaintext column would take while dodging every
        name check."""
        with isolate_apps("core"):

            class Canary(models.Model):
                payload = models.BinaryField()

                class Meta:
                    app_label = "core"

            self.assertEqual(
                self.audited(raw_binary_offenders, Canary), ["core.Canary.payload"]
            )

    def test_a_declared_public_key_is_not_mistaken_for_one(self):
        """The other half of the canary: the audit has to stay quiet about the
        fields it is meant to allow, or a green run means nothing either."""
        with isolate_apps("core"):

            class Canary(models.Model):
                ik_pub = models.BinaryField()
                spk_sig = models.BinaryField()
                pub = models.BinaryField()

                class Meta:
                    app_label = "core"

            self.assertEqual(self.audited(raw_binary_offenders, Canary), [])
            self.assertEqual(self.audited(unbucketed_blob_offenders, Canary), [])

    def test_a_table_that_references_two_users_is_named(self):
        """The sender-recipient pair at rest, in the one shape that carries no
        forbidden column name at all."""
        with isolate_apps("core"):

            class Canary(models.Model):
                owner = models.ForeignKey(
                    User, on_delete=models.CASCADE, related_name="+"
                )
                peer = models.ForeignKey(User, on_delete=models.CASCADE, related_name="+")

                class Meta:
                    app_label = "core"

            self.assertEqual(
                self.audited(dual_user_fk_offenders, Canary),
                ["core.Canary: ['owner', 'peer']"],
            )

    def test_a_volatile_state_column_is_named(self):
        with isolate_apps("core"):

            class Canary(models.Model):
                failed_attempts = models.IntegerField()

                class Meta:
                    app_label = "core"

            self.assertEqual(
                self.audited(volatile_state_offenders, Canary),
                ["core.Canary.failed_attempts"],
            )
