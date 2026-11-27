# ADR-057: Piece 21 remainders — shared local search, settings surface set, recovery rotation, and typed diagnostics export

- **Status:** Accepted (chat-list search later extended by `/chats/search` under [ADR-087](087-chat-status.md); `chat_pages.dart` and `group_pages.dart` later split into per-screen files; conversation search scope subsequently narrowed to the loaded keyset window when pagination landed in [ADR-062](062-timeline-window.md) per [LOCAL-DATA.md](../LOCAL-DATA.md#search))
- **Date:** 2026-08-25 (explicitly recorded in register and full section; implemented in `d344d8aa`)
- **Amends:** [ADR-044](044-private-deployment.md) Absent tier (removes appearance settings and notes local search was never absent; moves Absent tier to voice rooms, file attachments, profile publishing, shared media); [LOCAL-DATA.md](../LOCAL-DATA.md#search) and `implementation-checklist.md` (corrects "Android encrypted index" claim)
- **Related:** [ADR-012](012-local-search.md), [ADR-016](016-english-and-persian.md), [ADR-030](030-recovery-key-material.md), [ADR-044](044-private-deployment.md), [ADR-045](045-maturity-disclosure.md), [ADR-052](052-accurate-capability-claims.md), [ADR-053](053-field-evidence-gate.md), [ADR-055](055-initial-artifact.md)

## Decision (Position)

Audited the remaining Piece 21 items (local search, Settings surfaces, and diagnostics export) directly against the composed artifact and implemented what was actually missing:

1. **No separate encrypted search index ([LOCAL-DATA.md](../LOCAL-DATA.md#search)):**
   - Corrected `implementation-checklist.md` ("Pending Android encrypted index", wrong in both halves since [ADR-052](052-accurate-capability-claims.md)) and [LOCAL-DATA.md](../LOCAL-DATA.md#search) (which had originated the phrase repeated into prompt 21 without any ADR behind [ADR-012](012-local-search.md)'s local-only rule).
   - Because `messages` already stores decrypted message projections inside Keystore-wrapped SQLCipher, building a second FTS/index copy was rejected (duplicates every message body, expands wipe surface and migration corruption risk for zero benefit at this scale).
2. **One shared in-conversation search surface ([conversation_search.dart](../../../lib/features/messaging/presentation/conversation_search.dart)):**
   - Unified direct, saved, and group conversation search onto `showConversationSearch` over `ChatMessageViewModel` with a pure filter function so scope notice, empty states, jump behavior, and the previously silent 30-result cap (now displayed on screen when hit) cannot drift.
   - Added search to group chat (`GroupChatPage`) and replaced Group Info's permanently disabled (`onPressed: null`) "Search this chat" button with navigation to the conversation where messages live.
3. **Settings surface set, Appearance, and Log out ([settings_page.dart](../../../lib/features/settings/presentation/settings_page.dart), [appearance_page.dart](../../../lib/features/settings/presentation/appearance_page.dart), [security_settings_page.dart](../../../lib/features/settings/presentation/security_settings_page.dart), [about_page.dart](../../../lib/features/settings/presentation/about_page.dart)):**
   - Added profile header, Saved Messages, Security & recovery, Appearance (replacing `StructuralPlaceholderPage` on `/settings/appearance`), About (using `BuildIdentity.version` matched to `pubspec.yaml`), and Log out (disclosing full local wipe, zero server history, and identity-only recovery before confirmation).
   - Appearance exposes only client-side theme and language, stored in encrypted `local_preferences` (`DriftAppearancePreferenceStore`, wiped on logout; write failures explicitly reported as non-persistent); high contrast is omitted so Android/`MaterialApp` owns it without conflict.
4. **Recovery-secret replacement (`cp_crypto_v1_rotate_recovery_secret` in [enrollment.rs](../../../native/crypto_core/src/enrollment.rs), [rotate_recovery_secret.dart](../../../lib/features/devices/application/rotate_recovery_secret.dart), [recovery_rotation_page.dart](../../../lib/features/settings/presentation/recovery_rotation_page.dart)):**
   - Added `cp_crypto_v1_rotate_recovery_secret` (added to [build_rust_android.sh](../../../tool/build_rust_android.sh) allowlist) to parse the existing identity package, draw fresh entropy, and re-wrap the **unchanged** cross-signing identity via `encode_recovery_secret` + `encrypt_backup` (byte-identical except recovery/backup fields, avoiding `prepare_first_identity` which would silently invalidate every peer attestation and cross-signature).
   - Enforced strict server-first ordering: the new secret is displayed **only** after the server accepts the higher backup version; every refusal reports that the current secret still works; local private keys stay untouched so crashes cannot desynchronize device and backup.
   - Route enables `FLAG_SECURE` while mounted and copies only via the expiring clipboard path (`SensitiveScreenControl`), refusing to fall back to standard non-clearing `Clipboard.setData` ([settings_and_diagnostics_policy_test.dart](../../../test/architecture/settings_and_diagnostics_policy_test.dart)).
5. **Type-safe, non-persisted diagnostics export ([diagnostics_report.dart](../../../lib/features/diagnostics/domain/diagnostics_report.dart), [network_diagnostics.dart](../../../lib/features/networking/infrastructure/diagnostics/network_diagnostics.dart), [diagnostics_page.dart](../../../lib/features/diagnostics/presentation/diagnostics_page.dart)):**
   - Replaced `NoopNetworkDiagnostics` with `O(1)` in-memory `RecordingNetworkDiagnostics` owned by `ApplicationRuntime` (shared across foreground and headless isolates, deliberately **never persisted** so it leaves no usage-time log on disk).
   - Enforced redaction by type: `DiagnosticsReport` holds `DiagnosticField` enum keys and `DiagnosticValue` subclasses constructible only from booleans, enums, bounded integers, or compile-time constants; numeric counts export as magnitude buckets (`0`, `1-9`, `10-99`, `100-999`, `1000+`), timestamps export at hour granularity, and screen display equals the copied locale-independent ASCII text byte-for-byte via clipboard only (no `FileProvider`/`ACTION_SEND`).
   - Call sites of `DiagnosticValue.constant(` are enumerated in [settings_and_diagnostics_policy_test.dart](../../../test/architecture/settings_and_diagnostics_policy_test.dart), and `diagnostics_report.dart` has zero imports and zero network access.
6. **Audit fixes across existing Settings/Chat surfaces:**
   - Wired direct-conversation "Clear history" (previously a no-op `Navigator.pop`) to a typed intent behind a clear local-only consequence dialog.
   - Localized [linked_devices_page.dart](../../../lib/features/devices/presentation/linked_devices_page.dart) in English and Persian, replaced raw error printing with reviewed copy, rendered `Last active` as the UTC calendar day instead of `.toLocal()`, and replaced the broken "Add device" button (which routed to non-existent `/devices/enroll`) with the §16.1 instruction explaining how enrollment starts on the new device.

## Rationale

- **Artifact audit over checklist assumptions:** Four claimed surfaces (`GroupChatView` search, "Clear history", Linked Devices localization/route, diagnostics) were broken, no-op, or unbuilt in the actual artifact despite checklist/prompt framing.
- **Type-level redaction over review:** Preventing `DiagnosticsReport` from holding runtime strings guarantees no plaintext, credential, key, token, device label, or server origin can leak into a support paste by construction, with the lone constant-string constructor policed by [settings_and_diagnostics_policy_test.dart](../../../test/architecture/settings_and_diagnostics_policy_test.dart).
- **Clipboard-only export & zero-fallback secure copy:** Sending diagnostics via `ACTION_SEND` + `FileProvider` creates disk files and delegates recipient selection to Android intents; falling back to unexpiring `Clipboard.setData` for recovery secrets violates threat-model secret hygiene.

## Constraints and Open Gates

- **Pinned architecture assertions ([settings_and_diagnostics_policy_test.dart](../../../test/architecture/settings_and_diagnostics_policy_test.dart)):** Pins `DiagnosticValue.constant(` call sites, zero imports in `diagnostics_report.dart`, zero network symbols in `lib/features/diagnostics`, `DiagnosticsReport.formatVersion` / `DiagnosticField.values` length, `BuildIdentity.version == pubspec.yaml`, absence of `StructuralPlaceholderPage` under `/settings`, `FLAG_SECURE` + expiring clipboard on `RecoveryRotationPage`, and SQLCipher `local_preferences` storage for appearance.
- **No production gate or disclosure bump:** Added zero Dart/Android dependencies, zero permissions, and zero manifest components; added one native symbol (`cp_crypto_v1_rotate_recovery_secret`); left `DeploymentDisclosure.revision` unchanged (voice rooms, file attachments, and profile publishing remained unbuilt at revision 7).
- **Unverified by host tests at ADR-057:** Live-backend 409 stale-version recovery rotation conflict (covered via fakes), physical-device rendering of diagnostics/recovery screens, actual `FLAG_SECURE` screenshot blocking and clipboard expiration on hardware, and user comprehension of the new copy.

## Costs

- Rotating the recovery secret requires server connectivity and strict backup-version advancement before display.
- In-memory-only `NetworkDiagnostics` counters reset on process exit, trading cross-restart continuity for avoiding a durable usage-time log.
- Any new field added to `DiagnosticsReport` or new `DiagnosticValue.constant(` call site requires an explicit update to [settings_and_diagnostics_policy_test.dart](../../../test/architecture/settings_and_diagnostics_policy_test.dart).

## Reversal Trigger

Reopen if conversation lengths outgrow in-memory filtering of the loaded window (requiring an on-disk encrypted index), if a backend diagnostics format change requires bumping `DiagnosticsReport.formatVersion`, or if hardware checks reveal `FLAG_SECURE` or expiring-clipboard regressions.

## History, Amendments, and Supersession

- **2026-08-25 (`d344d8aa`):** Recorded ADR-057 (`Accepted`), completing Settings, Appearance, About, recovery-secret rotation (`cp_crypto_v1_rotate_recovery_secret`), typed diagnostics export, unified `showConversationSearch`, and Linked Devices / Clear history audit fixes.
- **2026-08-27 (ADR-062):** Bounded `watchMessages` to a cursor-anchored keyset window, updating [local-data-model.md](https://github.com/Orviniq/communication-platform/blob/5776e98a61565bda1e8f6942eca877e1bf951f6f/frontend/docs/local-data-model.md#search) so in-conversation search operates over the loaded window and jumps load out-of-window messages first.
- **2026-10-09 (ADR-087):** Added dedicated `/chats/search` full-history chat search alongside in-conversation search.
