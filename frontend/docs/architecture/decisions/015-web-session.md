# ADR-015: Web is online-session-first

- **Status:** Accepted in register (status gap: the Web client target and browser shell were subsequently removed under [ADR-033](033-android-release-target.md), [server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md), and commit `8236ca5b` on 2026-09-08)
- **Date:** Undocumented in the ADR register (introduced in commit `1b321da1`, 2026-07-24)
- **Related:** [ADR-004](004-rest-and-websocket.md), [ADR-032](032-rust-ffi.md), [ADR-033](033-android-release-target.md)

## Decision (Position)

Originally decided that if a **Web target** exists, it is **online-session-first** rather than promising Android-style background execution or offline push guarantees.

**Current reality (status gap):** While the ADR register table in [decisions.md](../../decisions.md) keeps `ADR-015` marked `Accepted`, **Android is now the sole target and there is no Web client or browser surface**:
- [ADR-033](033-android-release-target.md) (2026-07-28) deferred Web to post-v1.
- [server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md) (2026-09-05) removed the server's in-band WebSocket `auth` frame, Origin allowlist, and browser-only headers.
- Commit `8236ca5b` (2026-09-08) deleted the browser application shell (`frontend/web/index.html`, `frontend/web/protected_storage.js`, `frontend/web/drift_worker.js`, `frontend/web/sqlite3.wasm`, and `frontend/docs/platform-web.md`), and [Frontend instructions](../../../AGENTS.md) forbids reintroducing a browser target or `kIsWeb` branches.

## Rationale

Browser background execution cannot provide native-style delivery guarantees or AndroidKeyStore-equivalent secret protection.

## Constraints and Open Gates

- **Status discrepancy recorded as a gap:** `ADR-015` remains `Accepted` in [decisions.md](../../decisions.md) despite the deletion of the Web target (`8236ca5b`, ADR-069, [Frontend status](../../STATUS.md#platform-identity-and-content)).
- Any future Web target requires an explicit new client and server decision (reversing [server ADR-0020](../../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md)), plus the shared Rust/Wasm core and independent worker verification gates from [ADR-032](032-rust-ffi.md) and [ADR-033](033-android-release-target.md).

## Costs

- A browser build cannot connect to the current server (`/ws` requires an `Authorization` upgrade header that browser WebSockets cannot set).

## Reversal Trigger

An explicit product/architecture decision authorizing a browser target, accompanied by server WebSocket auth/CORS support and a reviewed Wasm cryptographic core.

## History, Amendments, and Supersession

- **2026-07-24 (`1b321da1`):** Original decision recorded in the initial ADR register (`Accepted`).
- **2026-07-28 (`7e550a63` / [ADR-033](033-android-release-target.md)):** Deferred Web to post-v1.
- **2026-09-05 – 2026-09-08 (`server ADR-0020`, `8236ca5b`, `8293c223` / ADR-069):** Server removed browser socket/CORS support and client deleted the Web shell and `frontend/docs/platform-web.md`.
