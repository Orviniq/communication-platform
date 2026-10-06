# Attachments

## Security model

The server stores an encrypted, exactly bucket-padded byte stream under an unguessable
capability ID. The attachment key, original name, MIME type, dimensions, checksum, and
caption exist only inside end-to-end encrypted message content.

Possession of the capability permits any authenticated full-scope account to download
the ciphertext, so capability IDs are treated as secrets and never logged, included in
analytics, copied into diagnostics, or exposed in notification previews.

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
authenticated by the surrounding DM/MLS message.

If upload succeeds but message send fails, retain the outbox operation until backend TTL
or explicit local cancellation. The backend has no delete endpoint, so UI does not claim
immediate server deletion of abandoned uploads.

## Receive pipeline

1. Validate the descriptor and bucket before allocating.
2. Download ciphertext as a stream; development direct-to-Daphne empty-body behavior is
   not treated as a valid production download. A download of the two largest buckets
   that stops part-way is taken up where it stopped (see *Resuming a download*).
3. Verify and decrypt each secretstream chunk before exposing it.
4. Stop and delete temporary output on any authentication, length, or final-tag failure.
5. Verify authenticated declared length and metadata.
6. Render only through safe, platform-owned decoders with bounded dimensions/resources.

Never open active content directly in the application origin. Web downloads use safe
blob URLs, download disposition, a strict allowlist for inline image/audio formats, and
timely URL revocation. Android shares files through a scoped content URI, not a raw path.

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
cache directory as any temporary file of a killed process does.

A development client that talks to the application directly cannot test this. The range
is nginx's work, from the internal location the download redirects to; the application
answers `200` with an empty body and does nothing with `Range`.

## Caching

- Ciphertext may use a bounded cache keyed by a local hash of the capability.
- Decrypted previews/files use the shortest practical lifetime and never Android shared
  external storage.
- Logout, revocation, delete-for-me, or cache eviction removes decrypted artifacts.
- Image thumbnails are generated locally, encrypted in persistent storage, and stripped
  of unnecessary metadata such as EXIF location by default.

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
