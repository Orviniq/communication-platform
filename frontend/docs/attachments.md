# Attachments

## Security model

The server stores an encrypted, exactly bucket-padded byte stream under an unguessable
capability ID. The attachment key, original name, MIME type, dimensions, checksum, and
caption exist only inside end-to-end encrypted message content.

Possession of the capability permits any authenticated full-scope account to download
the ciphertext, so capability IDs are treated as secrets and never logged, included in
analytics, copied into diagnostics, or exposed in notification previews.

## Phase 1: direct chats (ADR-089)

*Proposed 2026-10-10; built over five prompts on `frontend-dm-attachments`.* Attachments work
in a direct chat and in Saved Messages. A group chat gets none in this phase: its paperclip opens
the attachment sheet with the "not built" notice. The rules below are binding client behaviour;
ADR-089 holds the reasons, the rejected alternatives and the Android sources.

1. **Pickers.** No picker package. The application's own Android code
   (`AttachmentChannel.kt`) starts system intents: the photo picker,
   `MediaStore.ACTION_PICK_IMAGES`, on API 33 and later and on API 30 to 32 with R extension 2
   or more, else `Intent.ACTION_GET_CONTENT` with `image/*`; `Intent.ACTION_OPEN_DOCUMENT` with
   `*/*` for a file; `MediaStore.ACTION_IMAGE_CAPTURE` into a `FileProvider` URI in the private
   cache for the camera. The application asks for no permission and declares no `CAMERA`
   permission, because a declared and refused one makes the capture intent fail with a
   `SecurityException`.
2. **Copy.** The chosen content is copied on a worker thread into
   `secure_attachment_cache/outgoing/<random id>/<safe name>`, counting the bytes, and the copy
   stops at the byte limit Dart gives: the largest plaintext that fits the largest bucket both the
   deployment and the crypto protocol hold (`attachmentPlaintextLimit`). The name and the size
   come from `OpenableColumns` and the type from the content resolver; the declared size is never
   what lets a copy through. Dart does not trust the type: `safeMimeType` decides it, and
   `safeAttachmentName` the name.
3. **Photo processing.** Photo and Camera re-encode the picture: the EXIF orientation is applied
   once, the longest side is at most 2048 px and the picture is never enlarged, it is drawn on
   opaque white, and it is written as a JPEG of quality 82 with no metadata, which removes the
   location and the camera data. A GIF stays unchanged. File sends the exact bytes. A picture the
   device cannot decode is refused, with the advice to send it as a file.
4. **Send.** One attachment per message. A preview step shows the picture or the file name, the
   size, the upload size, today's remainder and a caption of at most 1,024 characters; the
   descriptor's authenticated metadata stays at or below 4,096 bytes. Send starts an upload job.
   The jobs live in memory and one upload runs at a time: a job encrypts, uploads, then calls
   `sendAttachments`, which commits the message, and the outgoing copy becomes this device's
   cached copy. A tray above the composer shows each job with Cancel, Retry and Discard. A process
   death drops the jobs, so in this phase the retention *Send pipeline* asks for below holds for
   the life of the process only; the durable queue that would carry it across a restart is
   deferred.
5. **Allowance.** An upload whose bucket is larger than today's remainder is refused before a
   byte is sent. The preview step states the remainder, and a `quota_exceeded` refusal states when
   the UTC day turns, in local time.
6. **Receive.** A received attachment shows as "not downloaded", with its name and its size. A
   tap downloads it, one download at a time, then verifies and decrypts it. A ready picture shows
   inline, decoded at a bounded size; a ready file or picture opens a details sheet with Open, Save
   and Share. No download starts without a tap.
7. **Open, Save and Share.** The native side accepts only a regular file whose canonical path is
   inside `secure_attachment_cache/plain/`, applies its MIME allowlist, and refuses anything else.
8. **Cache.** Decrypted files go to `secure_attachment_cache/plain/<random id>/<safe name>`. The
   `attachments` row holds the random id and an expiry. An entry expires 7 days after its last
   open, the cache holds at most 256 MiB and evicts the least recently opened entry first, and an
   evicted, expired or missing entry returns to "not downloaded". The native wipe deletes the
   private cache at logout and at revocation.
9. **Persisted states.** Of the values 0 to 8 the CHECK of `attachments.transfer_state` allows,
   the client persists only `queued` (meaning "not downloaded"), `ready` and `expired`. Each other
   state lives in memory. The schema does not change.
10. **Projection.** An attachment row keeps its state, its cache id and its expiry when its
    message is written again. The rows go when the message is deleted for everyone or for me, or
    when an id leaves the message. A message with an attachment and no caption shows the file name
    as its Chats list preview.

Not in this phase: group chats, the Shared media screens, thumbnails, automatic download, a
durable upload queue and video.

## Send pipeline

1. User selects a file through a platform picker.
2. Copy/read it through a bounded stream; do not trust extension or declared MIME.
3. Enforce product plaintext limits before encryption.
4. Generate a random 256-bit attachment key.
5. Encrypt with libsodium `secretstream_xchacha20poly1305` using fixed plaintext chunks
   and a final tag.
6. Construct an authenticated encrypted-file header containing protocol version and
   format metadata needed for streaming verification.
7. Add CSPRNG padding so the final uploaded bytes equal the smallest backend attachment
   bucket: 64 KiB, 256 KiB, 1 MiB, 4 MiB, 16 MiB, or 64 MiB.
8. Upload as the single multipart field `blob`.
9. Store the returned capability and size only in protected local state.
10. Send an encrypted attachment descriptor to recipients.

The encrypted descriptor contains capability ID, key, secretstream header, real encrypted
length, plaintext size, media metadata, safe display name, and optional thumbnail. It is
authenticated by the surrounding pairwise message.

If upload succeeds but message send fails, retain the outbox operation until backend TTL
or explicit local cancellation. The backend has no delete endpoint, so UI does not claim
immediate server deletion of abandoned uploads.

## Receive pipeline

*Corrected 2026-10-07 (server ADR-0020):* this section said Web downloads used blob URLs,
a download disposition, an allowlist of inline image and audio formats, and timely URL
revocation. There is no Web client: the server serves no browser surface, and the
client's web target was removed on 2026-09-08 (`implementation-checklist.md`, The web
target).

1. Validate the descriptor and bucket before allocating.
2. Download ciphertext as a stream; development direct-to-Daphne empty-body behavior is
   not treated as a valid production download. A download of the two largest buckets
   that stops part-way is taken up where it stopped (see *Resuming a download*).
3. Verify and decrypt each secretstream chunk before exposing it.
4. Stop and delete temporary output on any authentication, length, or final-tag failure.
5. Verify authenticated declared length and metadata.
6. Render only through safe, platform-owned decoders with bounded dimensions/resources.

Never open active content directly in the application origin. Android shares files
through a scoped content URI, not a raw path.

## Resuming a download

Implemented 2026-10-07 (ADR-083), on the behaviour the
[attachments API](../../backend/attachments/API.md) documents under **Resuming**. A
download of the two largest buckets, 16 MiB and 64 MiB, takes up where it stopped. Below
them a download starts again from zero: the largest of the rest is 4 MiB, a quarter of the
smallest bucket that resumes, and costs less to fetch again than the bookkeeping costs to
keep.

- **The call.** When a partial file exists for the capability, the request carries
  `Range: bytes=<bytes already written>-` and `If-Range: <ETag of the first answer>`. Only
  a strong tag is kept, because RFC 9110 forbids a weak one in `If-Range`, so an answer
  without one can be downloaded and not resumed.
- **The status.** `206` is accepted beside `200`, and only as an exact continuation:
  `Content-Range: bytes <offset>-<bucket - 1>/<bucket>`. A `200` in answer to a range is the
  whole object, so the partial file is emptied and the answer written from its first byte.
- **The length.** Bytes are counted from the resume offset, and what ends on disk is
  exactly one bucket, however many answers it took to collect.
- **The partial file.** It is kept only while the tag matches. An answer under another tag
  means the retention sweep deleted the object, so the partial file is deleted and the
  attachment reported gone, as a `404` reports it. The file is kept after a dropped
  connection, a cancellation or a refusal, and deleted after a `404`, a `416`, an answer
  that breaks the range or length rule, or a failed write.

The record of a partial download names a capability, so it lives in the transport's memory
and nowhere else: one at a time, replaced by the next download that stops, and lost with the
process. A restart therefore downloads from zero, and the file it leaves stays in the private
cache directory until the first sweep of the next process deletes it, as it deletes every
temporary file of a killed process (see *Caching*).

A development client that talks to the application directly cannot test this. The range
is nginx's work, from the internal location the download redirects to; the application
answers `200` with an empty body and does nothing with `Range`.

## Caching

*Built 2026-10-10 (ADR-089 D8, D9, D10, prompt 2 of the phase). The table, the projection and
the sweeps are in [Local data model](local-data-model.md#attachment-rows-and-decrypted-files).*

- **Where.** Every attachment file lives under `secure_attachment_cache` in the application's
  cache directory, never in shared external storage. The native wipe deletes that directory at
  logout and at revocation. When the platform names no such directory, attachments are not
  available; there is no fallback directory.
- **Layout.** `plain/<cache id>/<safe name>` holds one decrypted, verified file;
  `outgoing/<id>/<safe name>` holds a copy the picker made; `<cache id>.tmp` at the top level
  is a temporary file of encryption or download. A cache id is 32 random lowercase
  hexadecimal characters, so no path holds a capability, and no temporary name holds a display
  name. The safe name is `safeAttachmentName` cut to 255 bytes of UTF-8.
- **Ownership.** `AttachmentFileCache` adopts an outgoing copy after its message is sent, or a
  decrypted temporary file after its download is verified, by moving it under a new cache id,
  and records the cache id and an expiry in the attachment's row in the same step.
- **Bounds.** An entry expires 7 days after its last open; `plain/` holds at most 256 MiB and
  evicts the least recently opened entry first. An evicted, expired or missing entry returns
  to "not downloaded", and a second download fetches it again while the server keeps it.
- **Deletion.** Deleting a message for me or for everyone, or clearing a conversation, deletes
  its attachment rows, and the sweep that follows deletes the files. A message a peer deletes
  for everyone loses its rows at once and its file at the next sweep.
- **Ciphertext.** No ciphertext is cached. A partial download of the two largest buckets is
  kept for a resume within the process (see *Resuming a download*), and the first sweep of the
  next process deletes what a killed one left.
- **Thumbnails.** None are made in this phase (ADR-089, rejected alternatives).

The outgoing copies a sweep keeps are the ones the send flow names as live. A copy the picker
is still writing is not yet one of them, so the send flow must count an open pick as well, or
keep a sweep from running while one is open.

## UI states

Queued, encrypting, uploading, sending, downloading, verifying, ready, expired, cancelled,
quota exceeded, unsupported, corrupt, and failed/retry are distinct. Progress avoids
revealing filenames/content outside the unlocked app. Users are told that server
attachments normally expire after 30 days and should be downloaded promptly.

## Limits and testing

- Reject content that cannot fit the largest bucket after encryption overhead.
- Fuzz headers, chunk boundaries, truncation, reordered chunks, duplicate final tags,
  oversized dimensions, decompression bombs, and malicious filenames.
- Test cancellation/process death at every pipeline stage.
- Test constant bucket sizing and ensure temporary plaintext never survives failure.

## API reference

- [Attachments API](../../backend/attachments/API.md)
