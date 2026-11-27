# ADR-089: Direct-chat file attachments via system Android pickers and private cache

- **Status:** Accepted (2026-10-11); proposed 2026-10-10; amended for video by [ADR-097](097-direct-video.md) (2026-10-19)
- **Date:** 2026-10-11 accepted, 2026-10-10 proposed (PR #73 `c4e53bc3`, commits `a6bd1b79`–`ce24d5b0`; Rust descriptor codec tests and decoder fixes added 2026-10-12 in `1c2434f8`, `e4cab3c9`, `445cc513`, PR #74 `f3353959`)
- **Amended by:** [ADR-097](097-direct-video.md) (2026-10-19, adds video sending/receiving in direct chats and Saved Messages)
- **Related:** [ADR-045](045-maturity-disclosure.md), [ADR-075](075-pairwise-groups.md), [ADR-083](083-resumable-download.md), [ADR-097](097-direct-video.md), [ATTACHMENTS.md](../../contracts/ATTACHMENTS.md), [ANDROID.md](../ANDROID.md), [SCREENS.md](../../ui/SCREENS.md), [LOCAL-DATA.md](../LOCAL-DATA.md), [RELEASE.md](../../runbooks/RELEASE.md), [attachments API](../../../../backend/attachments/API.md)

## Decision (Position)

Composed the existing encrypted attachment library (`5cfcd8c`, 2026-08-01) for direct chats and Saved Messages without adding third-party picker/image plugins, permissions, or schema migrations:

1. **D1 — Scope:** Attachments send and receive in direct chats and Saved Messages only; group chats keep the paperclip disabled with the `"not built"` sheet (`attachmentsNotBuiltNotice`), and Shared media screens stay unbuilt.
2. **D2 — Permissionless system pickers via app-owned Android intents ([AttachmentChannel.kt](../../../android/app/src/main/kotlin/com/example/communication_platform/AttachmentChannel.kt)):**
   - Photo: `MediaStore.ACTION_PICK_IMAGES` on API 33+ and API 30–32 where `SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2`, else `Intent.ACTION_GET_CONTENT` (`image/*`, `CATEGORY_OPENABLE`).
   - File: `Intent.ACTION_OPEN_DOCUMENT` (`*/*`).
   - Camera: `MediaStore.ACTION_IMAGE_CAPTURE` writing to a `FileProvider` URI in private cache (`EXTRA_OUTPUT` + `ClipData` grants). Declares no `CAMERA` permission (declaring an ungranted `CAMERA` permission causes `SecurityException`) and no `<queries>` element (`ActivityNotFoundException` caught instead).
   - Rejected `image_picker` / `file_picker` packages to avoid external dependencies and plugin review.
3. **D3 — Bounded private-cache copy:** Copies picked content on a single process-wide worker thread into `secure_attachment_cache/outgoing/<32-hex>/<safe name>`, aborting above `attachmentPlaintextLimit(largestBucket)` (65,429 B for 64 KiB up to 67,091,366 B for 64 MiB), reading display name/size from `OpenableColumns` and type from `ContentResolver.getType` while normalizing names and types in Dart via `safeAttachmentName` and `safeMimeType` ([attachment_model.dart](../../../lib/features/attachments/domain/attachment_model.dart)).
4. **D4 — On-device photo processing (metadata stripping):** Photo and Camera picks (except `image/gif`, sent unchanged) are re-encoded on-device to JPEG quality 82 on an opaque white background, scaled to longest side ≤ 2048 px (never enlarged), with EXIF orientation applied once (`ImageDecoder` `ALLOCATOR_SOFTWARE` on API 28+, `BitmapFactory` + `ExifInterface` on API < 28), stripping EXIF/location/camera metadata and deleting the unprocessed copy. Unreadable/oversized GIFs (> 8192 px) fail with `unsupportedImage`. File sends exact bytes.
5. **D5 — One attachment per message, preview, and single in-memory upload queue:**
   - Preview sheet ([attachment_preview_sheet.dart](../../../lib/features/attachments/presentation/attachment_preview_sheet.dart)) shows image/file name, original size, padded upload bucket size, today's remaining allowance, and a caption field capped at 1,024 Unicode scalar values (`AppScalarLimitFormatter` in [app_scalar_limit.dart](../../../lib/app/design_system/components/app_scalar_limit.dart)) with authenticated descriptor metadata ≤ 4,096 bytes and safe descriptor name truncated to 128 UTF-8 bytes ([attachment_upload_model.dart](../../../lib/features/attachments/domain/attachment_upload_model.dart)).
   - Upload jobs ([AttachmentUploads](../../../lib/features/attachments/application/attachment_uploads.dart)) run one at a time in memory (encrypt → upload → `SendConversationEvents.sendAttachments`), promote the outgoing file into the local cache on commit, and display a tray above the composer with Cancel, Retry, and Discard. Process death drops in-memory jobs (durable upload queue deferred).
6. **D6 — Local allowance gate:** Refuses uploads locally before starting when the target bucket exceeds today's remaining allowance, shows remaining allowance in preview, and translates `quota_exceeded` to local time for the next UTC midnight reset.
7. **D7 — Tap-to-download receive flow ([AttachmentDownloads](../../../lib/features/attachments/application/attachment_downloads.dart), [chat_attachment_tiles.dart](../../../lib/features/messaging/presentation/chat_attachment_tiles.dart)):**
   - Received attachments start as `"not downloaded"`, download one at a time on tap (no automatic downloads), distinguish download failures (*failed*, retryable) from verification/decryption failures (*damaged*, not retried by tap), allow cancellation during verification as well as waiting/downloading, render ready images inline at bounded size, and open a details sheet with Open (`ACTION_VIEW`), Save (`ACTION_CREATE_DOCUMENT`), and Share (`AttachmentFileActions` in [attachment_file_actions.dart](../../../lib/features/attachments/application/attachment_file_actions.dart)). `DioAttachmentTransport` also maps `500` → `server_error` and `503` → `unavailable` (closing the gap noted in [ADR-083](083-resumable-download.md)).
8. **D8 — Private cache retention and eviction ([AttachmentFileCache](../../../lib/features/attachments/infrastructure/attachment_file_cache.dart)):**
   - Verified decrypted files move to `secure_attachment_cache/plain/<random id>/<safe name>`, tracked on the `attachments` row with an expiry **7 days after last open** (inline thumbnail/preview viewing does not extend expiry), bounded to **256 MiB** total by evicting the earliest-expiring entry first, and wiped by native logout/revocation cleanup (removed fallback to OS temp directory in [attachment_storage.dart](../../../lib/features/attachments/infrastructure/attachment_storage.dart)). Open/Save/Share refuse any canonical path outside `plain/`.
9. **D9 — Persisted states without schema change ([DriftAttachmentLocalState](../../../lib/features/attachments/infrastructure/drift_attachment_local_state.dart)):**
   - Reused existing `attachments.transfer_state` CHECK constraint (0–8) without bumping schema version: only `queued` ("not downloaded"), `ready`, and `expired` are persisted; transient transfer states stay in memory.
10. **D10 — Projection preservation and timeline reactivity:**
    - `_writeAttachments` in [drift_application_event_projector.dart](../../../lib/features/messaging/infrastructure/drift_application_event_projector.dart) preserves local state, cache ID, and expiry across message re-folds (reactions, pins, edits, receipts), removes rows on delete or removed capability, triggers timeline re-projection when attachment rows alone change, and uses the file name as Chats-list preview when caption is empty. Note: because `attachments` is keyed by capability, forwarding the same capability on the same device re-associates that row with the latest message as `"not downloaded"`.
11. **D11 — Retry and forward:**
    - `retrySend` re-arms durable send without falling back to caption-only text; forwarding offers attachment messages even without a caption and sends descriptors + caption to targets without copying server ciphertext (server TTL remains original upload's).
12. **D12 — Provisioned transport trust:**
    - `NetworkingFoundation.attachmentTransport` builds `DioAttachmentTransport` on the provisioned private-CA `SecurityContext` and shared `TokenCoordinator`; no default platform trust is permitted. Both upload/download queues bind `attachmentSessionActiveProvider` via the provider container so logout cancels in-flight transfers even when no chat screen is open.
13. **D13 — Disclosure deferred to owner revision:**
    - Changed neither `DeploymentDisclosure` text nor its revision; updated `attachmentsNotBuiltNotice` copy to state that group chats cannot send files yet while direct chats and Saved Messages can. Direct-chat attachments make revision 9's `disclosureUnbuiltSurfaces` point stale until the owner updates and re-presents the disclosure (release-blocking before distribution).
14. **D14 — Privacy and redaction:**
    - Never logs capabilities, keys, file names, paths, URIs, MIME types, sizes, or content (`print`/`debugPrint`/`log`/`developer.log` banned in `lib/features/attachments/`); redacted `toString()` overrides where fields hold sensitive values.

## Rationale

- Commit `5cfcd8c` already built and tested the streaming Rust AEAD attachment crypto (`attachment.rs`), bucket padding, transport, and resumable downloads ([ADR-083](083-resumable-download.md)), leaving attachments unbuilt solely for lack of composition and platform pickers.
- Using Android system intents avoids adding and auditing third-party picker/image plugins and avoids requesting `CAMERA` or storage permissions while stripping photo metadata on-device and keeping decrypted bytes inside the native-wiped private cache.
- Rejecting descriptors with embedded thumbnails avoids inflating pairwise message copies into larger envelope buckets (up to 256 KiB).

## Constraints and Open Gates

- **Scope:** Added `AttachmentChannel.kt`, `MainActivity.kt` `onActivityResult` forwarding, `AttachmentPlatformPort` / `MethodChannelAttachmentPlatform`, cache/transfer/queue/UI composition under `lib/features/attachments/` and `lib/app/dependencies/attachment_providers.dart`, and `AppScalarLimitFormatter`; changed no DB schema, wire format, protocol, dependency, Android permission, disclosure text/revision, or `backend/` file.
- **Verification:**
  - Host suite at branch head: 2,152 of 2,153 tests passed (the sole failure was pre-existing CRLF sensitivity in `background_delivery_policy_test.dart`), including 235 attachment tests across 20 files — notably [direct_chat_attachment_end_to_end_test.dart](../../../test/features/attachments/direct_chat_attachment_end_to_end_test.dart) (fake server enforcing bucket sizes, 43-char IDs, strong `ETag`, reaction re-fold preservation, delete-for-me sweep, expiry), [attachment_redaction_test.dart](../../../test/features/attachments/attachment_redaction_test.dart), [attachment_boundary_test.dart](../../../test/architecture/attachment_boundary_test.dart), [attachment_platform_policy_test.dart](../../../test/architecture/attachment_platform_policy_test.dart), and 9 targeted mutation checks.
  - **2026-10-12 Rust descriptor codec follow-up (`1c2434f8`, `e4cab3c9`, `445cc513`, PR #74 `f3353959`):** Added 6 round-trip/validation tests in [application.rs](../../../native/crypto_core/src/application.rs) (all 84 `cargo test --locked` crate tests passed) and fixed decoders accepting `< 43`-character capabilities or empty `5: []` attachment lists without changing encoder output.
- **Left open / not verified:**
  - No physical-device run of Android pickers, camera capture, re-encoding, Open, Save, or Share.
  - No live server/nginx run (notably range requests for resumed downloads).
  - Unbuilt surfaces: group attachments, Shared media screens, thumbnails, automatic download, durable upload queue, and `DeploymentDisclosure` revision bump (release-blocking before distribution).
  - Pre-existing direct `FileProvider` manifest declaration (`5cfcd8c`) flagged by Android docs as a subclassing follow-up.

## Costs

- In-progress uploads do not survive process death; an interrupted photo capture during process death is also lost.
- Evicted or 7-day-expired decrypted files require re-downloading while server ciphertext remains (default 30 days) and become unrecoverable afterward.
- On API 30–32 devices lacking R Extensions ≥ 2, photo selection falls back to `ACTION_GET_CONTENT` (the GMS Play Services photo-picker backport is not used per [ADR-013](013-no-foreign-push.md)).
- Caption limit counts Unicode scalar values (matching protocol enforcement), which can cut before 1,024 visible grapheme clusters when multi-scalar emoji are used.

## Reversal Trigger

Reopen for video support (done in ADR-097), group attachments, Shared media screens, durable upload queues, thumbnails, automatic downloads, or switching Android `FileProvider` to a subclass.

## History, Amendments, and Supersession

- **2026-10-10 – 2026-10-11 (`e22f94e1`, `a6bd1b79`–`ce24d5b0`, PR #73 `c4e53bc3`):** Proposed and accepted ADR-089 composing direct-chat and Saved Messages attachments across Android intents, private cache, upload/download queues, and UI.
- **2026-10-12 (`1c2434f8`, `e4cab3c9`, `445cc513`, PR #74 `f3353959`):** Added 6 Rust attachment-descriptor codec tests and tightened decoder rejection of short capabilities and empty attachment lists.
- **2026-10-19 (ADR-097):** Amended ADR-089 to allow sending and receiving video files in direct chats and Saved Messages.
