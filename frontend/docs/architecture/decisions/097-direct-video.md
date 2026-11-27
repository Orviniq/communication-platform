# ADR-097: Send and receive video in direct chats as a typed file attachment

- **Status:** Accepted (2026-10-19); proposed 2026-10-19
- **Date:** 2026-10-19 (explicitly recorded in register and full section; implemented on `frontend-dm-video` in `593fdbaa`, `ab8eef03`, `370e3ad6`, PR #89 `62d02fe1`)
- **Amends:** [ADR-089](089-direct-attachments.md) (adds video sending/receiving in direct chats and Saved Messages; D1 keeping groups attachment-free stands)
- **Related:** [ADR-089](089-direct-attachments.md), [ATTACHMENTS.md](../../contracts/ATTACHMENTS.md), [SCREENS.md](../../ui/SCREENS.md)

## Decision (Position)

Enabled sending and receiving video files in direct chats and Saved Messages without modifying the encrypted descriptor wire format, adding media dependencies, or generating thumbnails:

1. **V1 — Accept the 64 MiB server ceiling:** Accepted the largest attachment bucket plaintext limit of 67,091,366 bytes (~63.98 MiB) without server changes.
2. **V2 — Photo picker offers pictures and videos ([AttachmentChannel.kt](../../../android/app/src/main/kotlin/com/example/communication_platform/AttachmentChannel.kt)):**
   - Renamed the attachment sheet's Photo option to **Photo or video** (**عکس یا ویدیو**) ([attachment_sheet.dart](../../../lib/features/attachments/presentation/attachment_sheet.dart)).
   - On API 33+ and API 30–32 with R extension ≥ 2, `photoIntent()` launches `MediaStore.ACTION_PICK_IMAGES` with no type filter so both images and videos appear; on earlier devices it launches `ACTION_GET_CONTENT` with `*/*` and `EXTRA_MIME_TYPES` of `image/*` and `video/*`.
   - Videos are copied byte-for-byte with zero re-encoding.
3. **V3 — Travel as `file` media kind:** Encrypted descriptors continue using `mediaKind: file` with the video's real MIME type and no dimensions, keeping authenticated metadata unchanged for all receivers.
4. **V4 — Synchronized four-type video allowlist:**
   - Added `video/mp4`, `video/webm`, `video/3gpp`, and `video/quicktime` identically across all three lists: `safeMimeType` ([attachment_model.dart](../../../lib/features/attachments/domain/attachment_model.dart)), `EncryptedAttachmentDescriptor` ([attachment_crypto_model.dart](../../../lib/core/protocol/attachment_crypto_model.dart)), and `safeShareMime` / `VIDEO_TYPES` ([AttachmentChannel.kt](../../../android/app/src/main/kotlin/com/example/communication_platform/AttachmentChannel.kt)).
   - The Dart picker adapter accepts a `file` result from a Photo pick only when its MIME type is one of those four (never from a Camera pick). An unlisted video from the photo picker is rejected as an unsupported image offering File; an unlisted video picked via File travels as `application/octet-stream`.
5. **V5 — Video tile and external player ([chat_attachment_tiles.dart](../../../lib/features/messaging/presentation/chat_attachment_tiles.dart)):**
   - A `file` attachment with a video MIME type renders a video icon alongside file name, size, and transfer state, with screen-reader label `"Encrypted video"`.
   - Opening hands the verified private-cache file to the system player via the existing Open action (`ACTION_VIEW`); no in-app player, thumbnail, or inline playback is built.
6. **V6–V7 — Oversize refusal and group scope:** Over-limit videos use the existing largest-size error message (`"This file is too large to send. The largest file is {size}."`); group chats remain unable to send attachments ([ADR-089](089-direct-attachments.md) D1).

## Rationale

- Field testing on 2026-10-17 failed to send videos because `photoIntent()` requested `image/*` only, while picking via File mapped video MIME types to `application/octet-stream` at both sender (`safeMimeType`) and recipient (`EncryptedAttachmentDescriptor` / `safeShareMime`).
- Rejecting a new `video` media kind avoids a wire-format change; rejecting embedded thumbnails avoids inflating pairwise message copies into larger envelope buckets ([ADR-089](089-direct-attachments.md)); rejecting re-encoding/trimming and an in-app player avoids native/third-party media dependencies.

## Constraints and Open Gates

- **Scope:** Changed `AttachmentChannel.kt`, `attachment_model.dart`, `attachment_crypto_model.dart`, attachment adapter/tile/sheet UI, and localized strings; changed no wire format, event kind, cryptographic construction, Rust core, dependency, Android permission, manifest, disclosure text, database schema, server route, or `backend/` file.
- **Verification:** Covered by host unit, widget, and architecture tests: [attachment_mime_allowlist_test.dart](../../../test/features/attachments/attachment_mime_allowlist_test.dart), [method_channel_attachment_platform_test.dart](../../../test/features/attachments/method_channel_attachment_platform_test.dart), [chat_attachment_tiles_test.dart](../../../test/widget/chat_attachment_tiles_test.dart), and [attachment_platform_policy_test.dart](../../../test/architecture/attachment_platform_policy_test.dart) (which enforces exact equality of the Kotlin and Dart allowlists and picker intents, verified by mutation).
- **Left open / not verified:** No physical-device run of 20 MiB / 60 MiB / 100 MiB video transfers or system-player handoff; `android/app/src/test` does not exist so the Kotlin video copy path is covered only by source inspection in `attachment_platform_policy_test.dart`.

## Costs

- Four 63.98 MiB videos exhaust the 256 MiB daily upload allowance.
- The server's 120-second upload timeout requires ~4.5 Mbit/s sustained uplink for a 64 MiB video; uploads run one at a time in memory and are lost on process death.
- Video tiles show no thumbnail or inline preview, and playback relies on an installed system player supporting the MIME type.

## Reversal Trigger

Reopen for thumbnail generation, video compression/re-encoding, durable upload queues, in-app playback, additional video MIME types, or group attachments.

## History, Amendments, and Supersession

- **2026-10-19 (`593fdbaa`, `ab8eef03`, `370e3ad6`, PR #89 `62d02fe1`):** Proposed, implemented, and accepted ADR-097 amending [ADR-089](089-direct-attachments.md) for direct-chat and Saved Messages video attachments.
