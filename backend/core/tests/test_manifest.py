import re

from django.apps import apps
from django.conf import settings
from django.test import SimpleTestCase

from core.fields import OpaqueBlobField

# Column names that would mean the server had grown a plaintext store, key material,
# or a conversation graph. None of these may ever exist on any model.
FORBIDDEN_FIELD_NAMES = frozenset(
    {
        "plaintext",
        "content",
        "message_text",
        "body",
        "private_key",
        "secret_key",
        "session_key",
        "sender",
        "sender_id",
        "recipient_id",
        "members",
        "membership",
        "roster",
        "password_plain",
    }
)

# `password` holds an Argon2id hash: auth material, not a content key. It is
# legitimate on the user model and nowhere else.
PASSWORD_ALLOWED_ON = frozenset({"accounts.User"})

# The framework tables are audited once and accepted. Django's `session_key` is an
# opaque session identifier used only by the admin (the API is token-only) and is
# not key material. Nothing else gets an exemption.
AUDITED_FRAMEWORK_COLUMNS = frozenset(
    {
        "sessions.Session.session_key",
    }
)

# Public halves of client keypairs are explicitly fine to store and are not bucketed
# ciphertext, so they stay plain BinaryFields.
PUBLIC_KEY_SUFFIXES = ("_pub", "_sig")


def columns(model):
    """Concrete columns and m2m fields; reverse accessors are not columns."""
    for field in model._meta.get_fields():
        if field.auto_created and not field.concrete:
            continue
        yield field


def label_of(model):
    return f"{model._meta.app_label}.{model.__name__}"


def blob_fields():
    for model in apps.get_models():
        for field in columns(model):
            name = field.name
            if name.endswith(PUBLIC_KEY_SUFFIXES):
                continue
            if name == "blob" or name.endswith("_blob"):
                yield label_of(model), field


class FieldManifestTests(SimpleTestCase):
    """The field-manifest guard. It introspects every registered model and fails loudly
    if a later phase introduces a column this architecture forbids."""

    def test_no_model_declares_a_forbidden_column(self):
        offenders = []
        for model in apps.get_models():
            label = label_of(model)
            for field in columns(model):
                name = field.name
                if f"{label}.{name}" in AUDITED_FRAMEWORK_COLUMNS:
                    continue
                if name in FORBIDDEN_FIELD_NAMES:
                    offenders.append(f"{label}.{name}")
                elif name == "password" and label not in PASSWORD_ALLOWED_ON:
                    offenders.append(f"{label}.{name}")

        self.assertEqual(
            offenders,
            [],
            "Forbidden columns found; this server stores no plaintext, no key "
            f"material, and no conversation graph: {offenders}",
        )

    def test_every_ciphertext_field_is_a_bucketed_opaque_blob(self):
        problems = []
        for label, field in blob_fields():
            if not isinstance(field, OpaqueBlobField):
                problems.append(
                    f"{label}.{field.name} is {type(field).__name__}, "
                    "expected OpaqueBlobField"
                )
            elif not field.bucket_set:
                problems.append(f"{label}.{field.name} has an empty bucket_set")

        self.assertEqual(
            problems,
            [],
            f"Every stored blob must be exact-bucket-validated: {problems}",
        )

    def test_no_model_holds_a_token_at_rest(self):
        """A token table is a per-device login record at rest, which is why
        revocation lives in two counters on the device row instead. No model may
        store a token, a JTI, or a blacklist entry."""
        offenders = [
            f"{label_of(model)}.{field.name}"
            for model in apps.get_models()
            for field in columns(model)
            if field.name in {"token", "jti", "blacklisted_at", "outstanding_token"}
        ]

        self.assertEqual(offenders, [], f"a token reached the schema: {offenders}")

    def test_guard_actually_sees_the_known_ciphertext_fields(self):
        # Without this the two checks above would pass vacuously if introspection broke.
        found = {f"{label}.{field.name}" for label, field in blob_fields()}

        self.assertIn("accounts.ProfileBlob.blob", found)
        self.assertIn("devices.Device.label_blob", found)


# The test-only toolchain. None of it may reach the serving process: `hypothesis`
# generates inputs and `pytest-cov` traces every line executed, and a production
# module that imported either would carry a test dependency into the offline install
# of ADR-0012 and a tracer into a request path. `pytest-xdist` and `execnet`, its
# only dependency, spread the suite over worker processes and have no business in a
# serving one either.
TEST_ONLY_PACKAGES = frozenset({"hypothesis", "pytest-cov", "pytest-xdist", "execnet"})
# The other two the suite runs on, named here because the same rule covers them.
TEST_ONLY_IMPORTS = frozenset(
    {"hypothesis", "pytest", "pytest_cov", "coverage", "xdist", "execnet"}
)

PINNED = re.compile(r"^([A-Za-z0-9._-]+)==([^\s\\]+)", re.M)
IMPORTS = re.compile(r"^\s*(?:from|import)\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)


def requirement_records(path):
    """`name -> the whole record`, with each pin's continuation lines joined.

    A pin and the hashes that belong to it are one logical line broken with
    backslashes, so the hashes of a package can only be read by rejoining them.
    """
    text = path.read_text().replace("\\\n", " ")
    records = {}
    for line in text.splitlines():
        pin = PINNED.match(line.strip())
        if pin:
            records[pin.group(1).lower()] = line
    return records


def production_modules():
    """Every module that ships, which is everything but the suite and its harness.

    Migrations are included: they run on the deployment host, against the
    database, with whatever the production environment has installed.
    """
    base = settings.BASE_DIR
    for path in base.rglob("*.py"):
        parts = path.relative_to(base).parts
        if parts[0] in {".venv", "vendor"} or "tests" in parts:
            continue
        if path.name == "conftest.py":
            continue
        yield path


class DependencyManifestTests(SimpleTestCase):
    """The other manifest: what is installed, where it is pinned, and what may
    import it. `ops/audit/offline_rehearsal.sh` proves the files install with no
    network; this proves they say the right thing before they are installed."""

    def dev(self):
        return requirement_records(settings.BASE_DIR / "requirements" / "dev.txt")

    def prod(self):
        return requirement_records(settings.BASE_DIR / "requirements" / "prod.txt")

    def test_the_property_and_coverage_tools_are_pinned_for_development_only(self):
        """`dev.txt` installs `prod.txt` too, so a package in the wrong file is
        one that lands on the VPS with no reader ever noticing."""
        development, production = self.dev(), self.prod()

        for name in sorted(TEST_ONLY_PACKAGES):
            with self.subTest(name=name):
                self.assertIn(name, development)
                self.assertNotIn(name, production)

    def test_every_pinned_dependency_of_both_files_carries_its_hashes(self):
        """Invariant 8. `--require-hashes` makes pip refuse an unhashed pin, but
        that failure happens on the host during an install rather than here."""
        unhashed = [
            f"{path.name}: {name}"
            for path in (
                settings.BASE_DIR / "requirements" / "prod.txt",
                settings.BASE_DIR / "requirements" / "dev.txt",
            )
            for name, record in requirement_records(path).items()
            if "--hash=sha256:" not in record
        ]

        self.assertEqual(unhashed, [])

    def test_the_manifest_reader_actually_found_the_pins(self):
        """Anti-vacuity: a parser that returned nothing would pass both checks
        above in silence."""
        self.assertGreater(len(self.prod()), 20)
        self.assertIn("django", self.prod())
        self.assertIn("pytest", self.dev())

    def test_no_module_that_ships_imports_a_package_only_the_suite_installs(self):
        """A generator, a fixture library and a line tracer belong to the suite.
        Reaching one from a shipped module would make the deployment's install of
        `prod.txt` incomplete — and `manage.py check` would say nothing until the
        first request touched the module."""
        offenders = []
        for path in production_modules():
            imported = set(IMPORTS.findall(path.read_text()))
            for name in sorted(imported & TEST_ONLY_IMPORTS):
                offenders.append(f"{path.relative_to(settings.BASE_DIR)}: {name}")

        self.assertEqual(offenders, [])

    def test_the_import_scan_actually_read_the_shipped_tree(self):
        """The same anti-vacuity: the scan must be walking real modules, and it
        must not be walking the suite it deliberately excludes."""
        scanned = {
            str(path.relative_to(settings.BASE_DIR)) for path in production_modules()
        }

        self.assertIn("core/fields.py", scanned)
        self.assertIn("config/settings/base.py", scanned)
        self.assertIn("messaging/migrations/0001_initial.py", scanned)
        self.assertNotIn("conftest.py", scanned)
        self.assertNotIn("core/tests/test_manifest.py", scanned)
