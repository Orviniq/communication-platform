# attachments API

The encrypted blob store. A client encrypts a file, pads it to an exact attachment
bucket (65536, 262144, 1048576, 4194304, 16777216, or 67108864 bytes), uploads the
raw bytes, and receives an unguessable capability id. The id, together with the
decryption material, travels to recipients inside end-to-end encrypted messages; the
server keeps no recipient list and no ACL — possession of the id is the access
control. Both paths are under `/api/v1`, require `Authorization: Bearer` with `full`
scope, and share the `attachments` throttle scope (default 60/min). Every error body
is the `{code, detail}` envelope defined in `core/API.md`.

## Upload an attachment

**Method:** `POST`
**Path:** `/api/v1/attachments`

Multipart upload of one already-encrypted, already-padded file under the field name
`blob`. The byte size must equal one attachment bucket exactly; the server checks
nothing else about the content.

Nothing on the stored row names the account that uploaded it. What bounds an upload
instead is two things the row does not carry: the account's allowance for the current
UTC day (`attachment_daily_bytes` in `GET /api/v1/config`, default 256 MiB), and the
free space of the server's attachment storage. The allowance is charged before the
bytes are written and given back whenever the upload fails after that, so a refused
or failed upload spends nothing. It resets at 00:00 UTC and carries nothing forward:
an account that uploads nothing today has the same allowance tomorrow.

Stored attachments expire after a server-side TTL (default 30 days), so recipients
should fetch promptly.

The body must carry exactly one part, and that part must be a file part named `blob`.
A second part of any kind, a non-file field, or a body that is not multipart is
refused. The body cap of this route is the largest attachment bucket plus 8 KiB of
multipart wrapper (`MULTIPART_OVERHEAD_BYTES`); a larger body is `413
payload_too_large`.

**Retry semantics.** Not idempotent: a retry after a lost response stores the bytes a
second time under a second capability id, and both ids remain fetchable until the
attachment TTL prunes them. Nothing links the two, because nothing links an
attachment to a message. The client discards the id it never received; the duplicate
is charged against the day's allowance like any other upload.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |
| `Content-Type` | yes | `multipart/form-data` |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| — | | | none |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

Multipart form with a single file part named `blob` containing the padded ciphertext
bytes.

**Responses**

### Stored — `201 Created`

```json
{ "attachment_id": "Xk3vT9qLm2WnPzR8sYb4cJdF6hA1gE5uV7iO0wQtN_M", "size": 65536 }
```

The id is 43 characters of URL-safe base64 (256 random bits).

### Malformed body — `400 Bad Request`

```json
{
  "code": "invalid_request",
  "detail": { "blob": ["Expected one multipart file part named `blob`."] }
}
```

Returned when the body is not multipart, carries no `blob` file part, or carries any
other part beside it.

### Off-bucket size — `400 Bad Request`

```json
{ "code": "bad_bucket", "detail": "Invalid payload." }
```

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Body above the route cap — `413 Payload Too Large`

```json
{ "code": "payload_too_large", "detail": "Request body is too large." }
```

### The day's allowance is spent — `413 Payload Too Large`

```json
{ "code": "quota_exceeded", "detail": "The day's upload allowance is spent." }
```

Branch on `code`: both refusals are `413`. Nothing was stored and nothing was
charged, so retrying this upload before 00:00 UTC answers the same way. A client
that has an attachment to send should hold it and retry after the day turns, or send
a smaller bucket if the remainder of the allowance fits one.

### Storage is full — `503 Service Unavailable`

```json
{ "code": "storage_full", "detail": "Attachment storage is full." }
```

The server's attachment storage is below `ATTACH_MIN_FREE_BYTES` of free space. It
is not the account's allowance and not this request's fault: no allowance was spent
and nothing was written. Treat it as retry later, with backoff, and distinguish it
from `unavailable` only if the message to the user differs — the operator has to free
space before it clears.

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `attachments`, default 60/min per account, shared by the upload and the
download. `Retry-After` carries the seconds to wait.

## Download an attachment

**Method:** `GET`
**Path:** `/api/v1/attachments/{attachment_id}`

Fetches the stored bytes by capability id. Any authenticated full-scope user with the
id may fetch it; a per-recipient ACL would rebuild the conversation graph the schema
avoids. The server authorizes the request and answers with an empty body plus an
`X-Accel-Redirect` header; nginx then streams the file from an internal location. The
response is marked non-cacheable and non-renderable, since the bytes are ciphertext.

Behind the deployed nginx the client simply receives the bytes. Talking to the
application directly (development), the body is empty, the redirect header is
visible, and a `Range` does nothing — the process that would honour it is not there.

**Resuming.** Behind the deployed nginx a download honours a `Range` request. The
application never sees it: it answers `200` with an empty body and the redirect
header, and nginx's static handler serves the range from the internal location. A
full response therefore carries `Accept-Ranges: bytes`, an `ETag` and a
`Last-Modified`, and `Range: bytes=<first>-<last>` answers `206 Partial Content` with
`Content-Range: bytes <first>-<last>/<total>` and exactly those bytes. `If-Range` with
the `ETag` from the first response is what makes a resume safe: an attachment is
immutable and the id is never reused, so the tag can only fail to match after the
retention sweep deleted the object, and the answer is then the whole body rather than
bytes from another file.

The chunk format is unaffected: an attachment is a fixed 66-byte header followed by
64 KiB secretstream chunks, padded to a bucket, so any byte offset a client resumes
from is one it already knows. The bucket-length rule is unchanged too — what a client
must end up with is exactly one bucket, however many responses it took to collect it.

Resuming is client work that has not been done. The shipped download path requires
`200` and refuses anything but a full bucket in one response, so it declines a `206`
today; `../../CLIENT_WORK.md` carries what changes.

**Headers**

| Header | Required | Value |
|---|---|---|
| `Authorization` | yes | `Bearer <session token>` |
| `Range` | no | `bytes=<first>-<last>`, to resume. Honoured by nginx, never by the application |
| `If-Range` | no | The `ETag` of the earlier response, so a resume that cannot be satisfied returns the whole body instead of the wrong bytes |

**Path parameters**

| Name | Type | Required | Description |
|---|---|---|---|
| `attachment_id` | string | yes | 43-character capability id from the upload response |

**Query parameters**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| — | | | | none |

**Request body**

None.

**Retry semantics.** Safe to repeat: the route writes nothing and the capability is not
consumed by reading it. The bytes stay reachable until the operator deletes the
attachment or `ATTACH_TTL_DAYS` expires it, after which every call answers
`404 not_found` — so a retry that starts answering `404` has met the end of the object's
life, not a transient failure.

**Responses**

### Served — `200 OK`

Empty body with:

```
Content-Type: application/octet-stream
Cache-Control: private, no-store
X-Accel-Redirect: /_protected_attachments/Xk/Xk3vT9qLm2WnPzR8sYb4cJdF6hA1gE5uV7iO0wQtN_M
```

nginx replaces the empty body with the file bytes and adds `Accept-Ranges: bytes`,
`Content-Length`, an `ETag` and a `Last-Modified` of its own.

The answer to a `Range` this route never produces itself is under **Resuming** above:
nginx serves it from the internal location as `206 Partial Content` with a
`Content-Range`, and an unsatisfiable range as its own `416` with no envelope,
because no route of this API produced either. Neither is in `backend/openapi.json`
for that reason — the generated document describes what these routes answer.

### Unknown id — `404 Not Found`

```json
{ "code": "not_found", "detail": "No such attachment." }
```

Also returned after the attachment's TTL pruned it. An id of any shape that names no
row answers this; the id is never parsed or validated beyond the row lookup.

### Register-scope token — `403 Forbidden`

```json
{ "code": "scope_forbidden", "detail": "This token cannot access this endpoint." }
```

### Rate limited — `429 Too Many Requests`

```json
{ "code": "throttled", "detail": "Request was throttled." }
```

Scope `attachments`, default 60/min per account, shared by the upload and the
download. `Retry-After` carries the seconds to wait.
