# ADR-058: Objective fail-closed prerequisites for Piece 20 (voice rooms)

- **Status:** Superseded by [ADR-077](077-voice-mesh.md) (2026-09-20; status gap: the legacy register row in [decisions.md](../../decisions.md) still listed `Accepted` — recorded in [index](README.md)) — voice pivoted from MLS-keyed LiveKit SFU / SFrame to a pairwise-signalled, DTLS-SRTP relayed WebRTC mesh following [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) and [server ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md)
- **Date:** 2026-08-25 (explicitly recorded in register and full section; committed in `fab01f48`; superseded `2026-09-20`)
- **Amends:** [ADR-044](044-private-deployment.md) *Piece 20* section (replaces [ADR-044](044-private-deployment.md)'s prose "make a decision about which MLS exporter" prerequisite with seven objectively checkable conditions)
- **Superseded by:** [ADR-077](077-voice-mesh.md) (2026-09-20), recorded in [voice-and-realtime.md](../../voice-and-realtime.md#status)
- **Related:** [ADR-013](013-no-foreign-push.md), [ADR-017](017-independent-crypto-review.md), [ADR-023](023-voice-room-leave.md), [ADR-026](026-candidate-mls-suite.md), [ADR-036](036-beta-mls-track.md), [ADR-044](044-private-deployment.md), [ADR-051](051-sustained-delivery.md), [ADR-053](053-field-evidence-gate.md), [ADR-054](054-dependency-policy.md), [ADR-055](055-initial-artifact.md), [ADR-056](056-abi-evidence.md)

## Decision (Position)

Replaced [ADR-044](044-private-deployment.md)'s open-ended Piece 20 prerequisite ("decide which MLS exporter derives media keys") with **seven objectively checkable fail-closed conditions (`P1`–`P7`)**, granting neither exporter path, adding no code, dependency, or gate class, and recording an open framing-specification conflict:

1. **Seven mandatory fail-closed preconditions before Piece 20 could begin:**
   - **P1 — A granted media-key source:** An accepted, dated ADR naming exactly one MLS exporter and its grant terms, in one of two forms only: *(a) Production* (`GroupProductionGate.releaseAssertion.productionTransportEnabled == true`, requiring all seven `mls-profile.md` production gates, preserving the original prompt bar unchanged), or *(b) Closed-beta experimental* (experimental exporter, experimental voice only, under [ADR-036](036-beta-mls-track.md) disposable-state and [ADR-044](044-private-deployment.md) disclosure rules). **ADR-058 granted neither.**
   - **P2 — Reachable, domain-separated exporter:** The Rust core must export a room-media-key operation via `export_secret` domain-separated from `b"chat:v1:beta-group-export"`, listed in [build_rust_android.sh](../../../tool/build_rust_android.sh)'s export allowlist (at ADR-058, `mls_beta.rs:2108` returned only a SHA-256 `exporter_confirmation` digest for epoch-agreement comparison and exported zero key material across FFI).
   - **P3 — Same per-ABI stack permit as groups:** Under P1(b), voice must resolve through `GroupProductionGate.privateExperimentalPermit` ([ADR-056](056-abi-evidence.md)), withholding voice wherever groups were withheld (`armeabi-v7a`, `x86_64`) and prohibiting a second availability rule.
   - **P4 — Framing contract settled by decision:** The granting ADR must name the actual frame cipher, exact SDK version verified against, and whether RFC 9605 SFrame conformance is claimed, reconciling the framing conflict below.
   - **P5 — Admissible Android wire proof that the SFU cannot decrypt:** A real-hardware run record under `docs/validation/voice-media/` (following [ADR-053](053-field-evidence-gate.md)/[ADR-055](055-initial-artifact.md)/[ADR-056](056-abi-evidence.md) admissibility: never an emulator, strict `YYYY-MM-DD`, device-reported hardware/OS, full publish → SFU → subscribe path with SFU-side frames shown undecryptable when the key is withheld).
   - **P6 — Self-hosted runtime and pinned dependency:** Self-hosted LiveKit + TURN reachable from the provisioned origin (per [ADR-013](013-no-foreign-push.md)), and the client package (researched 2026-08-25 as `livekit_client` 2.11.0) added at an exact version to [dependency_policy_test.dart](../../../test/architecture/dependency_policy_test.dart) under [ADR-054](054-dependency-policy.md).
   - **P7 — Truthful tiering and FGS interaction:** Voice placed no higher than its weakest underlying layer (Experimental under P1(b)), updating `DeploymentDisclosure` and [deployment-and-release.md](../../deployment-and-release.md) mechanically ([ADR-052](052-accurate-capability-claims.md)), and deciding active-call foreground service interaction with [ADR-051](051-sustained-delivery.md)'s `specialUse` service up front.
2. **Resolution rule and zero speculative gate objects:**
   - Absence of evidence is refusal; partial satisfaction authorizes nothing; `/voice-rooms` remained `StructuralPlaceholderPage`.
   - No `VoiceMediaGate` class was created (forbidden speculative abstraction while unbuilt per [AGENTS.md](../../../AGENTS.md)); P1(a), P2, P3, and P6 already resolved fail-closed against `GroupProductionGate`, `GroupExperimentalGate`, `build_rust_android.sh`/`verify_release_apk.sh`, and `dependency_policy_test.dart`.
3. **Open framing conflict reported without silent reconciliation (2026-08-25):**
   - Historical `docs/voice-and-realtime.md` named RFC 9605 SFrame as *the* target contract; `docs/cryptographic-protocol.md` allowed "RFC 9605 SFrame **or** the LiveKit E2EE implementation after wire-level validation"; `backend/SECURITY.md` (moved under [ADR 0030](../../../../docs/architecture/decisions/0030-the-security-model-and-the-client-contract-move-under-docs.md) to `docs/security/SECURITY.md`; read-only) stated audio is SFrame-encrypted from a live MLS subgroup; while LiveKit's own documentation (read 2026-08-25) never mentioned RFC 9605 / SFrame and exposed `EncryptionType` as `kNone`, `kGcm`, `kCustom`.

**Supersession ([ADR-077](077-voice-mesh.md), 2026-09-20):** Because [server ADR-0001](../../../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md) eliminated MLS groups and [server ADR-0021](../../../../docs/architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md) rejected an SFU in favor of a relayed WebRTC mesh keyed endpoint-to-endpoint by DTLS-SRTP (with no application-level media key), ADR-077 superseded ADR-058's MLS exporter, SFrame, and LiveKit prerequisites completely ([voice-and-realtime.md](../../voice-and-realtime.md#status), [cryptographic-protocol.md](../../cryptographic-protocol.md#protocol-suite)).

## Rationale

- **Fixing four gaps in [ADR-044](044-private-deployment.md)'s re-scope:** (1) ADR-044 asked for a *decision* rather than checkable criteria; (2) [ADR-055](055-initial-artifact.md) and [ADR-056](056-abi-evidence.md) subsequently made the beta exporter unavailable on `armeabi-v7a` and `x86_64`; (3) `mls_beta.rs` returned only a SHA-256 confirmation digest, never raw exporter secret bytes; and (4) three documents disagreed on SFrame vs. LiveKit's built-in cipher.
- **Separating safety-bearing conditions from public-release registry gates:** Kept named key source, domain-separated FFI reachability, measured device stack, wire-proven framing, self-hosting, and honest disclosure; excluded externally blocked public-release gates (IANA `TBD2`, non-expiring primitive specs, conformant `TBD2` KEM provider, upstream vectors) and [ADR-017](017-independent-crypto-review.md) review from blocking *experimental* voice (matching [ADR-044](044-private-deployment.md)'s deployment-wide deferral) while preserving all seven gates intact in P1(a) for production.
- **Rejected alternatives:** Leaving ADR-044's incomplete prose unchanged (A); restoring prompt 20's unreachable production-only bar for experimental voice (B); granting the experimental exporter without deployment/wire proof (C); adding an empty `VoiceMediaGate` (D); editing only the gitignored `docs/implementation-prompts.md` (E).

## Constraints and Open Gates

- **Superseded:** All MLS/LiveKit/SFrame preconditions (`P1`–`P7`) were superseded by ADR-077's pairwise DTLS-SRTP WebRTC mesh ([voice-and-realtime.md](../../voice-and-realtime.md)).
- **Current voice gates:** Active voice implementation and remaining release gates (multi-device > 2, 10-device ceiling, v2 roles under `CLIENT_VOICE_ROLES.md`, 5-hour ICE/credential restart, TCP relay) are tracked in [STATUS.md](../../STATUS.md#presence-voice-and-delivery) and ADR-077 / ADR-078.
- **Documentation-only footprint at ADR-058 (`fab01f48`):** Touched zero Dart, Rust, Gradle, manifest, or backend files; kept `DeploymentDisclosure.revision` at 7; added no dependencies or symbols.

## Costs

- Required seven distinct pre-conditions (including self-hosted LiveKit/TURN and hardware wire captures) before any experimental voice work could start on the former MLS/SFU track, preventing premature or unverified SFrame claims.

## Reversal Trigger

Original triggers: satisfaction of `P1`–`P7`, production gate closure making P1(a) reachable, independent review ([ADR-017](017-independent-crypto-review.md)), ABI ledger changes, LiveKit encryption contract changes, or audience/threat-model expansion for live audio.

Current state: superseded on 2026-09-20 by ADR-077 when the voice architecture moved from an MLS-keyed SFU to a DTLS-SRTP WebRTC mesh.

## History, Amendments, and Supersession

- **2026-08-25 (`fab01f48`):** Recorded ADR-058 (`Accepted`), amending [ADR-044](044-private-deployment.md)'s *Piece 20* section with `P1`–`P7` and documenting the SFrame / LiveKit framing conflict without altering runtime code.
- **2026-09-13 (ADR-075) & 2026-09-20 (ADR-077):** Deleted the closed-beta MLS track and superseded ADR-058's MLS/SFrame/LiveKit prerequisites with pairwise-signalled DTLS-SRTP WebRTC voice over coturn.
