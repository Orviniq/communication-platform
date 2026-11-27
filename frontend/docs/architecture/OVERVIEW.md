# Architecture

See the [Android platform contract](ANDROID.md) for platform boundaries, the
[local data model](LOCAL-DATA.md) for durable state and migrations, and the
[synchronization engine](SYNC.md) for delivery and recovery. The
[frontend ADR index](decisions/README.md) records the governing decisions.

## Decision

Use **Modular Feature-First Clean Architecture with an Offline-First, Event-Driven
Core**.

The architecture separates product features from transport, storage, cryptography, and
platform code while forcing all durable state changes through one transactional data
path.

## Dependency rule

Dependencies point inward:

1. Presentation depends on application use cases and immutable view state.
2. Application use cases depend on domain types and ports.
3. Infrastructure implements ports for REST, WebSocket, database, crypto, files, audio,
   secure storage, background work, and clocks.
4. Domain and protocol code never import Flutter widgets, Dio, Drift, Forui, Flyer Chat,
   or platform plugins.

Cross-feature communication uses typed application commands/events, not direct provider
lookups or database writes.

## Runtime data flow

```text
REST / WebSocket / user action
             |
             v
   protocol validation + decryption
             |
             v
      one Drift transaction
             |
             +--> domain rows
             +--> inbox/outbox state
             +--> sync checkpoints
             |
             v
      Riverpod database streams
             |
             v
       app-owned UI widgets
             |
             +--> Forui shell/components
             +--> app-owned timeline adapter and builders
```

Widgets read a single projection. A send first commits the logical message and
its owed preparation to Drift. A later delivery cycle seals and persists the
per-device outbox rows before sending them. Network acceptance updates transport
state, and receipt events update delivery state. Incoming envelopes are
acknowledged after their disposition is persisted. See [outgoing preparation](SYNC.md#owed-send-preparations)
and [incoming envelopes](SYNC.md#incoming-durable-envelopes).

## Feature boundaries

Feature modules correspond to product capabilities: bootstrap, authentication, devices,
contacts/profiles, conversations, messaging, groups, attachments, search, voice rooms,
identity recovery/device-to-device history transfer, settings, and shared shell/design
system.

Features own their use cases and presentation. Shared domain concepts live in narrowly
scoped core packages. A generic `utils` dumping ground is prohibited.

## Source layout and composition

The package must make product capabilities visible first and keep Clean Architecture
layers inside each capability:

```text
lib/
  app/                         root widget, bootstrap, config, routing, DI composition
  core/                        framework-free cross-feature policy contracts only
    application/              command, event, use-case, and port conventions
    domain/                   shared entity/value-object primitives
    protocol/                 framework-free protocol values and validation
    result/                   sealed result and safe failure classifications
  features/
    <feature>/
      domain/                 feature-owned entities, values, and rules
      application/
        use_cases/             commands/queries coordinating domain behavior
        ports/                 repository/gateway interfaces required by use cases
      infrastructure/         local, remote, crypto, and platform port adapters
      presentation/           Riverpod controllers, immutable state, and widgets
  shared/
    infrastructure/           only cross-feature technical adapters
    presentation/             app-owned reusable presentation primitives
  l10n/                       Flutter localization input/generated support files
  main*.dart                  environment entry points
```

Folders are created only when a numbered piece adds real code. `core` must not collect
feature business concepts, and `shared` must not become a generic dumping ground.
Feature-owned repository interfaces live in that feature's `application/ports`; their
Drift/Dio/platform implementations live in the same feature's `infrastructure` layer.
A feature cannot import another feature's infrastructure.

`lib/app/dependencies` is the Riverpod composition root and is the only place allowed
to select concrete adapters. Provider declarations are immutable descriptors;
ProviderScope owns instances and test overrides. The app root may import features and
infrastructure to compose them, but dependencies inside a feature point toward its
application and domain layers.

The offline-first path keeps a repository adapter as the single mutation boundary:
remote input and user commands are validated, applied to the local source of truth, and
then observed as immutable projections. Typed application events describe completed
facts; durable events are committed before projections publish them. Riverpod manages
lifecycle and observation but never owns the durable record.

Expected failures use the sealed `Result`/`Failure` model. Failures carry only stable
categories and reviewed reason codes, never raw backend messages or exception text.
Presentation maps those codes to localized copy. A source-boundary test guards core and
feature policy imports against Flutter, Dio, Drift, Forui, Flyer Chat, platform plugins,
and every other outer package. A source-layout test requires the four top-level
architecture boundaries and the recognized layer names inside every feature.

## State management

- Riverpod provides dependency injection, lifecycle, commands, and projections of Drift
  streams.
- Providers do not become an alternative database.
- Durable state is not kept only in a notifier.
- UI-only transient state such as focus, selection, and animation MAY stay in widgets or
  short-lived providers.
- Authentication and connection state are explicit state machines.

## UI boundary

Forui supplies tokens and application-shell primitives behind app-owned components.
The virtualized message surface is supplied only through the timeline adapter, whatever
implements it. Custom builders own the exclusive visual design for bubbles, grouping,
replies, status, attachments, system events, and composer.

A package's models and controllers may only ever be adapters, never domain models or the
source of truth. If the required pagination, anchoring, RTL, accessibility, or media
performance spike fails, only the timeline adapter is replaced with a custom sliver
implementation.

Piece 15 exercised that replacement clause: the then-pinned Flyer 2.11.1 update path
requires a mutable `ChatController`, so the production `ChatTimelineAdapter` is an
app-owned reversed sliver with explicit reading-anchor restoration. Drift-backed
projections remain the source of truth. **ADR-054 (2026-08-24) finished that decision**:
`flutter_chat_core` and `flutter_chat_ui` were still declared in `pubspec.yaml` and
imported by no file in `lib/`, so they were removed and ADR-007 is superseded. The
boundary itself is unchanged, and is what would make a future adapter swap possible. The adapter and all builders receive immutable view models
and emit typed intents; they cannot reach cryptography, APIs, Drift, or synchronization.

## Platform boundary

Android is the only target. The Web shell, adapters and CI build were removed under
[server ADR-0020](../../../docs/architecture/decisions/0020-one-android-client-and-no-browser-surface.md).
See [platform status](../STATUS.md#platform-identity-and-content).

- Android uses encrypted SQLite and Android Keystore wrapping.
- Active-app messaging uses the socket and authoritative REST drain. The persisted
  `JobScheduler` job supplies deferred catch-up. The opt-in messaging service uses
  `specialUse`, and an active voice call uses a separate `microphone` foreground service.
  See [delivery status](../STATUS.md#presence-voice-and-delivery).

No platform-specific conditional is allowed inside domain or protocol logic.

## Failure policy

- Expected failures are typed results, not strings parsed in widgets.
- Malformed or unauthenticated protocol input is quarantined and never partially applied.
- Unknown future event kinds are retained as unsupported records without crashing.
- Security failures fail closed.
- A mailbox `pruned_through` gap queues state recovery for active groups and voice
  rooms while the client continues draining. Groups withhold sends and changes
  while waiting, and rooms withhold joins and changes. The client has no direct-chat
  gap UI. See [queue-gap recovery](SYNC.md#queue-gap-recovery).
- Network failures preserve outbox work and surface honest connection state.

## Source references

- [Flutter architecture guide](https://docs.flutter.dev/app-architecture/guide)
- [Flutter architecture case-study package structure](https://docs.flutter.dev/app-architecture/case-study)
- [Flutter offline-first guidance](https://docs.flutter.dev/app-architecture/design-patterns/offline-first)
- [Clean Architecture dependency rule](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Riverpod ProviderScope/ProviderContainer](https://riverpod.dev/docs/concepts2/containers)
- [Flyer Chat customization](https://flyer.chat/docs/flutter/getting-started/customisation/)
  — retained as the reference for the boundary the timeline adapter preserves; the
  packages themselves are no longer declared (ADR-054).
