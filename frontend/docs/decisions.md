# Architecture decisions

The frontend architecture decision records have moved to [architecture/decisions/README.md](architecture/decisions/README.md), with one file per ADR (`001`–`101`) under `frontend/docs/architecture/decisions/`.

- Historical server ADRs ([0021](../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md), [0023](../../docs/architecture/decisions/0023-one-device-bound-session-token.md), [0024](../../docs/architecture/decisions/0024-peer-state-published-limits-and-no-activity-dates.md), [0027](../../docs/architecture/decisions/0027-the-serving-origin-moves-and-a-pin-moves-with-it.md)) and dated validation records ([production-release build 2](validation/production-release/2026-09-14-build-2/README.md), [voice-mesh 2026-10-05](validation/voice-mesh/2026-10-05/README.md)) remain readable through this pointer.
- Non-ADR notes previously at the bottom of this file (`Dependency opinion` and `Decisions that do not block development`) are mapped under [Disposition of Legacy Non-ADR Sections](architecture/decisions/README.md#disposition-of-legacy-non-adr-sections).

<!-- Compatibility fragment anchors preserved from the single-file register -->
<a id="adr-101-in-full--presence-reads-stale-peers-and-the-goodbye-never-waits-for-the-network-2026-11-13"></a>
<a id="adr-100-in-full--presence-follows-the-socket-and-answers-a-new-watcher-at-once-2026-11-13"></a>
<a id="adr-099-in-full--typing-sessions-end-with-the-message-and-start-at-once-2026-11-13"></a>
<a id="adr-098-in-full--typing-and-online-status-over-volatile-signals-2026-10-19"></a>
<a id="adr-097-in-full--a-direct-chat-sends-a-video-as-a-file-with-a-video-type-2026-10-19"></a>
<a id="adr-096-in-full--leaving-deletes-the-group-from-the-phone-and-roles-decide-who-changes-a-message-2026-10-19"></a>
<a id="adr-095-in-full--prekey-maintenance-runs-at-the-end-of-a-healthy-delivery-cycle-2026-10-18"></a>
<a id="adr-094-in-full--offer-receiving-while-closed-in-production-as-best-effort-2026-10-18"></a>
<a id="adr-093-in-full--hold-a-first-message-from-an-unverified-sender-2026-10-17"></a>
<a id="adr-092-in-full--the-whole-application-blocks-screen-capture-2026-10-17"></a>
<a id="adr-091-in-full--a-group-message-is-read-when-one-member-reads-it-and-its-sender-sees-who-2026-10-14"></a>
<a id="adr-090-in-full--a-group-reads-its-messages-as-a-direct-chat-does-2026-10-14"></a>
<a id="adr-089-in-full--a-direct-chat-sends-a-file-through-the-systems-own-pickers-2026-10-10"></a>
<a id="adr-088-in-full--a-group-send-keeps-the-composer-and-its-bubble-shows-no-copy-count-2026-10-09"></a>
<a id="adr-087-in-full--the-engines-status-is-the-chats-titles-search-is-a-page-and-the-connection-strip-is-gone-2026-10-09"></a>
<a id="adr-086-in-full--the-tab-bar-and-the-rail-belong-to-the-tab-roots-and-every-page-above-one-covers-them-2026-10-08"></a>
<a id="adr-085-in-full--a-session-token-is-renewed-from-half-its-life-not-in-its-last-minutes-2026-10-07"></a>
<a id="adr-084-in-full--a-device-the-log-does-not-cover-yet-is-pending-not-a-fork-2026-10-07"></a>
<a id="adr-083-in-full--a-download-takes-up-where-it-stopped-and-the-single-flight-is-kept-for-what-it-saves-2026-10-07"></a>
<a id="adr-082-in-full--every-send-asks-and-the-identity-read-is-conditional-2026-10-06"></a>
<a id="adr-081-in-full--an-unsigned-peer-device-as-the-server-lists-it-2026-10-06"></a>
<a id="adr-080-in-full--a-fan-out-verified-in-one-call-2026-10-06"></a>
<a id="adr-079-in-full--a-call-on-two-devices-and-the-two-things-it-took-2026-10-05"></a>
<a id="adr-078-in-full--the-media-package-what-it-links-and-the-three-permissions-a-call-asks-for-2026-09-28"></a>
<a id="adr-077-in-full--voice-is-a-mesh-of-pairwise-calls-and-the-room-is-one-more-thing-the-clients-agree-on-2026-09-20"></a>
<a id="adr-076-in-full--production-gets-a-key-and-the-first-install-is-the-part-that-cannot-be-taken-back-2026-09-14"></a>
<a id="adr-075-in-full--a-group-is-pairwise-and-the-screen-says-what-that-costs-2026-09-13"></a>
<a id="adr-070-in-full--leaving-and-the-sentence-that-makes-the-offer-honest-2026-09-08"></a>
<a id="adr-068-in-full--one-session-token-and-the-three-breaks-that-hid-behind-the-pair-2026-09-08"></a>
<a id="adr-067-in-full--the-origin-moves-and-the-one-thing-that-moved-with-it-2026-09-07"></a>
<a id="adr-066-in-full--the-timeline-is-app-owned-and-the-first-thing-owning-it-costs-is-the-bidi-2026-08-30"></a>
<a id="adr-065-in-full--the-cycle-asks-once-and-gossip-goes-behind-the-message-2026-08-28"></a>
<a id="adr-064-in-full--the-chat-screen-costs-what-changed-on-it-2026-08-28"></a>
<a id="adr-063-in-full--an-event-costs-the-message-it-is-about-not-the-conversation-it-is-in-2026-08-27"></a>
<a id="adr-062-in-full--the-timeline-reads-a-window-and-the-database-has-indexes-2026-08-27"></a>
<a id="adr-061-in-full--the-message-goes-on-the-screen-before-it-goes-on-the-network-2026-08-27"></a>
<a id="adr-060-in-full--what-a-delivery-cycle-owes-the-message-the-user-just-sent-2026-08-26"></a>
<a id="adr-059-in-full--the-chat-pages-emoji-surface-and-what-it-costs-2026-08-25"></a>
<a id="adr-058-in-full--what-piece-20-is-actually-waiting-for-2026-08-25"></a>
<a id="adr-057-in-full--the-remainder-of-piece-21-as-measured-2026-08-25"></a>
<a id="adr-056-in-full--the-first-measurement-and-what-it-opens-2026-08-24"></a>
<a id="adr-055-in-full--what-the-first-artifact-hands-a-user-2026-08-24"></a>
<a id="adr-054-in-full--what-the-delivery-and-notification-path-takes-from-outside-and-what-it-writes-2026-08-24"></a>
<a id="adr-053-in-full--whether-receiving-while-the-application-is-not-in-use-actually-works-2026-08-23"></a>
<a id="adr-052-in-full--making-what-the-application-says-about-itself-true-2026-08-23"></a>
<a id="adr-051-in-full--receiving-while-the-application-is-not-in-use-2026-08-22"></a>
<a id="adr-050-in-full--guaranteeing-that-one-part-of-the-application-drives-delivery-2026-08-22"></a>
<a id="adr-049-in-full--what-makes-a-backgrounded-client-take-delivery-2026-08-21"></a>
<a id="adr-048-in-full--how-the-user-finds-out-a-message-arrived-2026-08-21"></a>
<a id="adr-046-in-full--how-a-backgrounded-android-client-learns-a-message-arrived-2026-08-21"></a>
<a id="adr-045-in-full--what-the-application-tells-its-users-about-itself-2026-08-20"></a>
<a id="adr-044-in-full--the-initial-private-deployment-2026-08-20"></a>
<a id="adr-041-in-full--same-revision-fork-ordering-2026-08-17"></a>
<a id="adr-040-in-full--closed-beta-hybrid-kem-2026-08-17"></a>
<a id="dependency-opinion"></a>
<a id="decisions-that-do-not-block-development"></a>
