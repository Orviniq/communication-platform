# ADR-033: Version 1 ships Android only; Web is post-v1

- **Status:** Accepted (reinforced by [server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md) and commit `8236ca5b`, which removed the preserved Web shell)
- **Date:** 2026-07-28 (explicitly recorded in register; committed in `7e550a63`)
- **Related:** [ADR-004](004-rest-and-websocket.md), [ADR-013](013-no-foreign-push.md), [ADR-015](015-web-session.md), [ADR-032](032-rust-ffi.md)

## Decision (Position)

**Version 1 targets Android only**, distributed as a directly signed APK; any **Web target is deferred to post-v1**.

1. Pieces 08 onward implement Android protocol, storage, delivery, and UI behavior without waiting for Wasm compilation, browser workers, or Android/Web parity.
2. Any future Web release requires an explicit new approval, compatible server support, the same reviewed Rust core, encodings, and vectors, and an independently verified browser worker boundary.

## Rationale

Keeps the first release on the verified Android trust and delivery boundary (`dart:io` private CA, AndroidKeyStore-wrapped SQLCipher, `JobScheduler`/foreground services) without delaying or weakening it for browser storage/worker limitations.

## Constraints and Open Gates

- Codified in [Frontend instructions](../../../AGENTS.md) and [Frontend status](../../STATUS.md#platform-identity-and-content).
- **Post-v1 Web foundation change:** Although `7e550a63` initially preserved a fail-closed Web scaffold, [server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md) (2026-09-05) subsequently removed all browser-only server surfaces (`/ws` in-band `auth` frame, Origin allowlist, CORS/browser headers), and commit `8236ca5b` (2026-09-08) deleted `frontend/web/*` and `frontend/docs/platform-web.md`. [Frontend instructions](../../../AGENTS.md) now forbids reintroducing a browser target or `kIsWeb` branches without an explicit new decision.
- Open gate: Android v1 release acceptance gates (independent crypto review, contract compliance, physical-device verification) remain tracked in [Frontend status](../../STATUS.md).

## Costs

- No browser client is available in v1; adding Web later now requires both client work and server contract changes (re-introducing WebSocket auth/CORS support).

## Reversal Trigger

An explicit product/architecture decision to support a browser client, paired with server support under [server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md)'s flip trigger and full Wasm/worker security verification.

## History, Amendments, and Supersession

- **2026-07-28 (`7e550a63`):** Original decision added to the register (`Accepted`).
- **2026-09-05 – 2026-09-08 ([server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md), `8236ca5b`, ADR-069):** Server and client removed the remaining Web scaffold and socket auth frame.
- No supersession.
