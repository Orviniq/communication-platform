"""The OpenAPI document of this surface, and what each route declares into it.

Every error body of this API is the envelope of `api/errors.py`. A route names
the codes it can answer; `errors()` groups them by status and gives each status
the envelope schema, so the generated document carries the same vocabulary
`core/API.md` publishes for the client rather than a bare list of numbers.

`core/tests/test_openapi.py` is the gate. FastAPI has no counterpart to a
generator warning: a route that declares nothing reaches the document as an
empty schema, in silence. That file walks the document instead and fails a route
whose declared set is missing what its own dependencies imply.
"""

from fastapi.openapi.utils import get_openapi
from pydantic import BaseModel


class ErrorOut(BaseModel):
    """The error envelope. `detail` is a string on every code but
    `invalid_request`, where it maps a field path to the messages that failed."""

    code: str
    detail: str | dict[str, list[str]]


# Every code of the vocabulary, and the status that carries it. `core/API.md`
# publishes the same table. `device_scope_required` is reserved rather than
# reachable — no route declares a requirement that could raise it — so it is not
# here; the table in `core/API.md` records why it stays in the vocabulary.
VOCABULARY = {
    "invalid_request": 400,
    "bad_bucket": 400,
    "identity_required": 400,
    "unauthenticated": 401,
    "invalid_token": 401,
    "token_revoked": 401,
    "invalid_credentials": 401,
    "account_inactive": 403,
    "scope_forbidden": 403,
    "forbidden": 403,
    "not_found": 404,
    "username_taken": 409,
    "stale_version": 409,
    "device_limit": 409,
    "prekey_limit": 409,
    "devicelog_limit": 409,
    "payload_too_large": 413,
    "quota_exceeded": 413,
    "throttled": 429,
    "server_error": 500,
    "unavailable": 503,
    "storage_full": 503,
    "voice_unconfigured": 503,
}

# Every route answers these two whatever it declares: an unhandled failure, and
# the request deadline of `api/middleware.py`. Added by `errors()` rather than
# repeated on thirty-two routes, so no route can be the one that forgets them.
UNIVERSAL = ("server_error", "unavailable")

# The codes a route answers because of the authentication requirement it
# declares, rather than because of anything in its own body or service.
FULL_DEVICE = ("unauthenticated", "invalid_token", "token_revoked", "scope_forbidden")
REGISTER_OR_FULL = ("unauthenticated", "invalid_token", "token_revoked")

# The three refusals this surface answers before it has chosen a route — an
# unknown `Host`, a path no route serves, and a method a route does not carry —
# belong to no operation and so appear on none. `core/API.md` carries them.

# FastAPI declares this status with a shape of its own on every route that takes
# a parameter, because that is what its default validation handler answers.
INJECTED_VALIDATION_STATUS = "422"
INJECTED_VALIDATION_COMPONENTS = ("HTTPValidationError", "ValidationError")


def errors(*codes):
    """The `responses` of a route: one envelope entry for each status its codes
    reach, described by the codes themselves so a client can find what to branch
    on without leaving the document."""
    by_status = {}
    for code in (*codes, *UNIVERSAL):
        by_status.setdefault(VOCABULARY[code], []).append(code)
    return {
        status: {
            "model": ErrorOut,
            "description": ", ".join(f"`{code}`" for code in reached),
        }
        for status, reached in by_status.items()
    }


def operation_id(route):
    """The identifier a generated client turns into a method name.

    The handler name, which is unique across this surface. FastAPI's own
    derivation builds the identifier from the name, the path and one method
    taken from an unordered set, so it moves when a path moves and collides on a
    route that declares two methods.
    """
    return route.name


def document(app):
    """The generated document, with the validation response FastAPI adds removed.

    ADR-0007 replaced FastAPI's validation handler: a validation failure on this
    surface is `400 invalid_request` with the envelope above, and `422` is never
    used. Left in, the document would publish a status no route returns and a
    body shape no client will ever receive — and every gate below it would pass,
    because both are well-formed.
    """
    generated = get_openapi(
        title=app.title,
        version=app.version,
        openapi_version=app.openapi_version,
        description=app.description,
        routes=app.routes,
        webhooks=app.webhooks.routes,
        tags=app.openapi_tags,
        servers=app.servers,
        separate_input_output_schemas=app.separate_input_output_schemas,
    )
    for operations in generated["paths"].values():
        for operation in operations.values():
            operation.get("responses", {}).pop(INJECTED_VALIDATION_STATUS, None)
    schemas = generated.get("components", {}).get("schemas", {})
    for name in INJECTED_VALIDATION_COMPONENTS:
        schemas.pop(name, None)
    return generated


def install(app):
    """Make `document` the application's own generator, so the `/docs` route in
    development, `manage.py openapi` and the drift gate all read one document."""

    def openapi():
        if app.openapi_schema is None:
            app.openapi_schema = document(app)
        return app.openapi_schema

    app.openapi = openapi
