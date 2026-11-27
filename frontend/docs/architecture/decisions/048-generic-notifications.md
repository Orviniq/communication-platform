# ADR-048: Sender-neutral aggregate message notifications reconciled from committed state

- **Status:** Accepted (`settingsNotificationsOn` claim corrected by [ADR-052](052-accurate-capability-claims.md) on 2026-08-23; mark-read-on-screen follow-up closed by [ADR-073](073-visible-read.md) on 2026-09-10; group unread/read receipts addressed by [ADR-090](090-group-timeline.md) and [ADR-091](091-group-receipts.md); background service permissions added under [ADR-049](049-background-catch-up.md), [ADR-051](051-sustained-delivery.md), and [ADR-078](078-media-package.md))
- **Date:** 2026-08-21 (explicitly recorded in register and full section; committed in `fac9013c`)
- **Amends:** [ADR-046](046-layered-delivery.md) Layer 3 (follow-up step 2) and [ADR-045](045-maturity-disclosure.md) `foregroundDeliveryOnly` (disclosure revision 1 → 2)
- **Related:** [ADR-002](002-drift-source-of-truth.md), [ADR-045](045-maturity-disclosure.md), [ADR-046](046-layered-delivery.md), [ADR-047](047-networking-composition.md)

## Decision (Position)

Implements [ADR-046](046-layered-delivery.md) Layer 3 while amending three of its sketched details on code and platform evidence:

1. **One aggregate, sender-neutral notification (amending ADR-046's bounded-individual-plus-summary sketch):**
   - Posts a single notification (`CHANNEL_ID = "messages"`, constant `TAG = "message-alert"`, `ID = 1`) whose entire content is localized `New message` or `New messages` — no sender, conversation, preview text, count, or timestamp (`setShowWhen(false)`).
   - Uses `VISIBILITY_PRIVATE` with an identical `setPublicVersion` so lock screens and Android 15+ screen sharing display the exact chosen sentence rather than an uncontextual system redaction.
   - Tapping uses `getLaunchIntentForPackage` wrapped in `PendingIntent.FLAG_IMMUTABLE` with `setAutoCancel(true)` and **no** destination, extra, or identifier, forcing normal routing guards on open.
   - Rejects `MessagingStyle` and long-lived conversation shortcuts to avoid publishing per-contact identifiers to `system_server` and the launcher.
2. **Reconciliation of committed durable state, not `PostInboxCommitWorkPort` emission:**
   - [ReconcileMessageAlerts](../../../lib/features/notifications/application/reconcile_message_alerts.dart) observes a Drift stream over `messages` and `conversations` (which Drift 2.34.2 dispatches strictly after `COMMIT`: `Transaction.complete()` precedes `disposeChildStreams()`).
   - Composed via `MessageAlertController` (`lib/app/dependencies/message_alerts.dart`) at the application root beside (not inside) `MessageDeliveryController`, so backlogs reconcile even if a delivery session fails to compose.
   - Each pass reads unread, non-deleted, non-withdrawn, non-Saved-Messages rows, subtracts muted conversations and the currently visible conversation, announces if any un-alerted rows survive, and withdraws if none survive (and the read did not hit the 256-row page bound). First session pass assumes an alert may exist from a prior process so read-elsewhere messages withdraw cleanly.
3. **Boolean `messages.alerted` marker (schema 12), not `notified_at`:**
   - Written *after* successful platform post (choosing a rare duplicate alert on crash over silent loss), and preserved across projection rebuilds via `insertOnConflictUpdate` companions that omit `alerted` (matching `starred`).
   - Deliberate silence (muted or on screen) still marks `alerted = true` so those rows never alert later; platform refusal (missing permission/unavailable presenter) spends nothing so granting permission later announces the backlog.
4. **"On screen" conjunction (`VisibleConversationRegistry`):** Requires a mounted chat route **and** foregrounded application (`isForeground`), treating unreported initial lifecycle state at launch as foreground ([ADR-047](047-networking-composition.md)).
5. **Permission prompt and Settings surface:**
   - Requests `POST_NOTIFICATIONS` automatically at most once at the point of use (first un-alertable waiting message while foregrounded), guarded by a durable preference marker in `local_preferences` and Android's `shouldShowRequestPermissionRationale` so an automatic prompt can never trigger permanent second-refusal denial.
   - Settings displays live OS status (on, off, or unavailable) and offers one action that requests permission and falls back to system app notification settings when prompting is blocked.
6. **Zero third-party dependencies; policy-free Kotlin:**
   - Uses `androidx.core:core:1.16.0` (already declared for `FileProvider`) via app-owned [MessageAlertChannel.kt](../../../android/app/src/main/kotlin/com/example/communication_platform/MessageAlertChannel.kt) (refactored from `MainActivity` to `Context`-bound in ADR-049) rather than `flutter_local_notifications` 22.3.0. Kotlin holds no message/conversation identifiers or policy; all decisions live in Dart and are host-tested.
   - Added `POST_NOTIFICATIONS` and `VIBRATE` only (no FGS/boot/exact-alarm/SMS permissions at this stage).
7. **Disclosure update:** Moved `DeploymentDisclosure` from revision 1 → 2 (`foregroundDeliveryOnly` updated to note alerts work only while running, making written handover re-delivery release-blocking).

## Rationale

- With sender-neutral text, N individual notifications would be N identical copies that only leak per-message/per-conversation IDs to `system_server`/notification listeners and hit Android's undocumented ~50-per-package notification cap and OEM grouping quirks.
- Emitting from `PostInboxCommitWorkPort` cannot *withdraw* alerts when messages are read locally, read on another device, withdrawn by sender, or muted; reconciling from committed Drift state handles announcement and withdrawal with one rule.
- Nothing in the design reads a notification timestamp, so `messages.alerted` avoids wall-clock skew reasoning.
- `ChatConversationView` originally marked read only once in `initState` and `DriftGroupRepository.commitMessageInsideTransaction` set no group unread state; ADR-048 accounted for both rather than silently alerting on-screen direct messages.

## Constraints and Open Gates

- **Policy tests ([message_alert_policy_test.dart](../../../test/architecture/message_alert_policy_test.dart)):** Enforce frozen `CHANNEL_ID = "messages"`, `VISIBILITY_PRIVATE`, `setPublicVersion`, `setShowWhen(false)`, `getLaunchIntentForPackage` + `FLAG_IMMUTABLE`, absence of `MessagingStyle`/`setShortcutId`/message fields in Kotlin, no `flutter_local_notifications` dependency, and no transport imports in `reconcile_message_alerts.dart`. (The manifest permission test was later updated in ADR-049/ADR-051/ADR-078 as `RECEIVE_BOOT_COMPLETED`, `specialUse`, and `microphone` services were legitimately added.)
- **Resolved follow-ups:**
  - *Follow-up 4 (mark-read while on screen):* Closed by ADR-073 (2026-09-10), which switched direct mark-read to `VisibleConversationRegistry` and arrival re-evaluation.
  - *Follow-up 3 (group unread state):* Addressed later by ADR-090 and ADR-091 (group read state and read receipts).
  - *Revisit condition 1 (Layer 1 & 2):* Layer 1 shipped in ADR-049 and Layer 2 in ADR-051 without changing the alert reconciler (`VisibleConversationPort.isForeground` kept background runs from firing the activity prompt).
- **Still open / unverified:**
  - *Device verification (Follow-up 1):* The Kotlin notification rendering (status-bar icon `ic_message_alert`, lock-screen/screen-sharing redaction, vibration, Android 13+ permission dialog, and Persian channel/alert strings) was unmeasured on real hardware at ADR-048 and remains part of physical-device validation ([STATUS.md](../../STATUS.md)).
  - *Message preview opt-in & in-app foreground alert (Follow-ups 5–6):* Remain unbuilt; sender-neutral text is the only alert mode.
  - *Written disclosure handover (Follow-up 2):* Superseded into the current release-blocking revision-11 handover obligation ([STATUS.md](../../STATUS.md#artifact-and-release-acceptance)).

## Costs

- No per-sender or per-conversation preview or deep link from the shade (user must open the app and unlock to see who wrote).
- A refusal triggered from Settings is not written to `local_preferences`, leaving at most one possible automatic prompt if Android's rationale flag is false after a Settings refusal.
- Until ADR-049/ADR-051 shipped, alerts only functioned while the process remained alive (`settingsNotificationsOn` still claimed this until corrected by ADR-052).

## Reversal Trigger

Reopen if the threat model changes from a small private threat-conscious group to allow opt-in notification previews (requiring reviewed bilingual lock-screen warnings), if Android changes `POST_NOTIFICATIONS`/`NotificationChannel`/`setPublicVersion` semantics, if voice-call notifications interact unexpectedly, or if device-matrix testing contradicts assumed platform behavior.

## History, Amendments, and Supersession

- **2026-08-21 (`fac9013c`):** Recorded ADR-048 (`Accepted`), implementing Layer 3, amending [ADR-046](046-layered-delivery.md) and [ADR-045](045-maturity-disclosure.md) (disclosure rev 1 → 2).
- **2026-08-21 (ADR-049):** Moved `MessageAlertChannel` from `MainActivity` to `Context`-bound class so headless catch-up can reconcile alerts.
- **2026-08-23 (ADR-052):** Corrected `settingsNotificationsOn` string, which still falsely claimed alerts only worked while running after ADR-049/ADR-051 shipped.
- **2026-09-10 (ADR-073):** Closed follow-up 4 (messages arriving while conversation is on screen now mark read immediately via `VisibleConversationRegistry`).
