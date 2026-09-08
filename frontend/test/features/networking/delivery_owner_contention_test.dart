@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/infrastructure/secure_session_token_adapter.dart';
import 'package:communication_platform/features/local_storage/application/ports/local_storage_ports.dart';
import 'package:communication_platform/features/local_storage/domain/local_storage_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/local_storage_runtime.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/auth/token_coordinator.dart';
import 'package:drift/drift.dart' show DatabaseConnection, QueryExecutor;
import 'package:drift/isolate.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two real delivery owners, in two real isolates, contending over one real
/// shared durable store.
///
/// This is the verification ADR-050 rests on, and nothing about it is a
/// simulation. The topology is the artifact's own: two Dart root isolates in one
/// process, one SQLite file behind one drift database server isolate — which is
/// exactly what `shareAcrossIsolates: true` produces on a device, because a
/// Flutter process has one Dart VM and `IsolateNameServer` is owned by it. The
/// contenders build the real [SecureSessionTokenAdapter] on the real
/// [SecureLocalStorageRuntime] over that shared connection, and drive the real
/// [TokenCoordinator]. Only two things are stood in for: the Keystore, which a
/// host has none of, and the server, which is a port rather than a socket — and
/// that server enforces the rule the real one enforces since ADR-0023, which is
/// the opposite of the rule this file was first written against: **a renewal
/// retires nothing**, so presenting one token twice answers twice and both
/// answers work.
///
/// What that changes is the subject. The race is still arranged here, exactly
/// as before, because it still happens — two owners do reach the renewal
/// window together. What is checked is that it no longer *costs* anything:
/// there is no loser to repair, no row to arbitrate over, and no interleaving
/// in which a user who did nothing is signed out.
///
/// What is *not* covered here is the exclusion mechanism itself. That lives on
/// the application's main looper in Kotlin, and no Dart test can drive it; see
/// `test/architecture/background_delivery_policy_test.dart` for what is pinned
/// about it, and ADR-050 for what rests on argument rather than on a test run.
void main() {
  late Directory directory;
  late File databaseFile;
  late _DatabaseServer server;
  SecureSessionTokenAdapter? verifier;

  setUp(() async {
    verifier = null;
    directory = await Directory.systemTemp.createTemp('delivery-owner-');
    databaseFile = File('${directory.path}/shared.sqlite');
    server = await _DatabaseServer.start(databaseFile.path);
  });

  tearDown(() async {
    await server.shutdown();
    if (directory.existsSync()) {
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows keeps a handle on a file the database isolate has only just
        // released. The directory is under the system temporary root and the
        // test has already made its assertions.
      }
    }
  });

  // One verification adapter for the whole test, on its own connection to the
  // shared server. A second `LocalDatabase` in one isolate is a drift warning
  // and says nothing this test is about.
  Future<SecureSessionTokenAdapter> observer() async => verifier ??=
      SecureSessionTokenAdapter(_runtimeOn(await server.connect()));

  Future<SessionTokens?> durableSession() async =>
      (await observer()).readDurable();

  Future<void> seed() async => (await observer()).replace(_tokens('token-0'));

  group('two owners renewing one session', () {
    for (final firstToBeServed in const [0, 1]) {
      test(
        'owner $firstToBeServed served first: both keep working tokens',
        () async {
          await seed();
          final backend = _Backend(rendezvous: 2, serveFirst: firstToBeServed);
          addTearDown(backend.close);

          final owners = await Future.wait([
            _Owner.start(0, server.connectPort, backend.port),
            _Owner.start(1, server.connectPort, backend.port),
          ]);
          addTearDown(() => Future.wait(owners.map((owner) => owner.stop())));

          backend.beginRound();
          final reports = await Future.wait(
            owners.map((owner) => owner.renew()),
          );

          // Both contenders presented `token-0`. That is the contention, and
          // it is real: the backend saw one token twice and answered the
          // second presentation the way the deployed backend answers it.
          expect(
            backend.presentations,
            ['token-0', 'token-0'],
            reason: 'both owners genuinely raced the same durable row',
          );
          expect(
            backend.rejections,
            0,
            reason: 'nothing was retired, so there was nothing to refuse',
          );

          // Neither owner ended a session, and neither had to repair one.
          for (final report in reports) {
            expect(report.terminations, isEmpty, reason: report.toString());
            expect(
              report.accessToken,
              isNotNull,
              reason: 'every owner ends with a token it can use: $report',
            );
          }
          expect(
            reports.map((report) => report.accessToken).toSet(),
            hasLength(2),
            reason: 'two renewals are two tokens, and both of them work',
          );

          // The shared row holds one live session, whose token is one of the
          // two just issued. Which one is whichever write landed last, and it
          // does not matter: the other owner holds a token that still works.
          final durable = await durableSession();
          expect(durable, isNotNull);
          expect(backend.issued, contains(durable!.accessToken.value));
        },
      );
    }

    test('repeated rapid contention costs nothing every time', () async {
      await seed();
      // Eight rounds, alternating which owner the backend serves first, with
      // both owners forced into flight together on every one of them. One
      // clean race proves very little; a mechanism that only usually holds
      // shows up here.
      final backend = _Backend(rendezvous: 2, serveFirst: 0);
      addTearDown(backend.close);

      final owners = await Future.wait([
        _Owner.start(0, server.connectPort, backend.port),
        _Owner.start(1, server.connectPort, backend.port),
      ]);
      addTearDown(() => Future.wait(owners.map((owner) => owner.stop())));

      for (var round = 0; round < 8; round += 1) {
        backend.beginRound(serveFirst: round.isEven ? 0 : 1);
        final reports = await Future.wait(owners.map((owner) => owner.renew()));
        for (final report in reports) {
          expect(report.terminations, isEmpty, reason: 'round $round: $report');
          expect(report.accessToken, isNotNull, reason: 'round $round');
        }
      }

      expect(
        backend.rejections,
        0,
        reason:
            'sustained contention is not a failure mode any more: an owner '
            'that starts a round holding a token the other has renewed past '
            'presents a token that is still perfectly good',
      );
      expect(backend.presentations, hasLength(16));
      expect(
        backend.issued,
        contains((await durableSession())?.accessToken.value),
      );
    });

    test('an owner killed mid-renewal leaves nothing behind', () async {
      await seed();
      // A contender that stops existing without ever getting to clean up,
      // killed while the server is holding its request, which is the widest
      // window it has. Nothing it held was durable, so there is nothing to
      // expire and nothing to reclaim - and the surviving owner must carry on
      // immediately, not after a lease times out.
      final backend = _Backend(rendezvous: 2, serveFirst: 1);
      addTearDown(backend.close);

      final doomed = await _Owner.start(0, server.connectPort, backend.port);
      final survivor = await _Owner.start(1, server.connectPort, backend.port);
      addTearDown(survivor.stop);

      backend.beginRound();
      unawaited(doomed.renew().then((_) {}, onError: (Object _) {}));
      final survivorRenewal = survivor.renew();
      await backend.awaitRendezvous();
      await doomed.kill();

      final report = await survivorRenewal;
      expect(report.terminations, isEmpty, reason: report.toString());
      expect(report.accessToken, isNotNull);

      // A brand-new owner starting afterwards finds a usable session, with no
      // wait and no repair. This is what "never wedges delivery permanently"
      // means when it is checked rather than argued.
      final replacement = await _Owner.start(
        2,
        server.connectPort,
        backend.port,
      );
      addTearDown(replacement.stop);
      final after = await replacement.renew();
      expect(after.terminations, isEmpty, reason: after.toString());
      expect(after.accessToken, isNotNull);
      expect(
        backend.issued,
        contains((await durableSession())?.accessToken.value),
      );
    });

    test('an owner that dies before it persists costs nothing', () async {
      await seed();
      // The one interleaving that used to be unrepairable. The owner the
      // server served obtained a replacement and stopped existing before it
      // could write it down, so that token is lost - and losing it costs
      // nothing now, because obtaining it retired none of the others. The
      // survivor renews the same token it was already holding and carries on.
      final backend = _Backend(rendezvous: 2, serveFirst: 0);
      addTearDown(backend.close);

      final doomed = await _Owner.start(0, server.connectPort, backend.port);
      final survivor = await _Owner.start(1, server.connectPort, backend.port);
      addTearDown(survivor.stop);

      backend.beginRound();
      unawaited(doomed.renew().then((_) {}, onError: (Object _) {}));
      final survivorRenewal = survivor.renew();
      await backend.awaitRendezvous();
      // Killed after its request is queued and before anything it is given can
      // reach the shared row.
      await doomed.kill();

      final report = await survivorRenewal;
      expect(
        report.accessToken,
        isNotNull,
        reason: 'a token nobody wrote down is not a session anybody lost',
      );
      expect(report.terminations, isEmpty, reason: report.toString());
      expect(await durableSession(), isNotNull);
    });

    test('one owner alone pays nothing for the other one existing', () async {
      await seed();
      // The normal case, which is no contention at all: one presentation, one
      // answer, one write.
      final backend = _Backend(rendezvous: 1, serveFirst: 0);
      addTearDown(backend.close);

      final owner = await _Owner.start(0, server.connectPort, backend.port);
      addTearDown(owner.stop);

      final report = await owner.renew();

      expect(report.accessToken, isNotNull);
      expect(report.terminations, isEmpty);
      expect(backend.presentations, ['token-0']);
      expect(backend.rejections, 0);
    });

    test('a session the server really ended still ends', () async {
      await seed();
      // A device whose token generation was bumped, or that was revoked,
      // answers `token_revoked` - the one answer that still ends a session
      // before its own expiry. It ends it on the first try, with no second
      // request.
      final backend = _Backend(rendezvous: 1, serveFirst: 0)..revoke('token-0');
      addTearDown(backend.close);

      final owner = await _Owner.start(0, server.connectPort, backend.port);
      addTearDown(owner.stop);

      final report = await owner.renew();

      expect(report.accessToken, isNull);
      expect(report.terminations, ['revoked']);
      expect(
        backend.presentations,
        hasLength(1),
        reason: 'a revoked device is not repaired by presenting another token',
      );

      expect(
        await durableSession(),
        isNull,
        reason: 'the session really is over',
      );
    });
  });
}

// ---------------------------------------------------------------------------
// The shared durable store: one file, one connection, one server isolate.
// ---------------------------------------------------------------------------

final class _DatabaseServer {
  _DatabaseServer._(this.connectPort, this._isolate, this._ready);

  static Future<_DatabaseServer> start(String path) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_databaseServerEntrypoint, (
      path: path,
      reply: ready.sendPort,
    ));
    final connectPort = await ready.first as SendPort;
    return _DatabaseServer._(connectPort, isolate, ready);
  }

  final SendPort connectPort;
  final Isolate _isolate;
  final ReceivePort _ready;
  final List<DatabaseConnection> _connections = [];

  Future<DatabaseConnection> connect() async {
    final connection = await DriftIsolate.fromConnectPort(
      connectPort,
    ).connect();
    _connections.add(connection);
    return connection;
  }

  Future<void> shutdown() async {
    for (final connection in _connections) {
      try {
        await connection.close();
      } on Object {
        // Already gone; the isolate is killed below either way.
      }
    }
    _connections.clear();
    _ready.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

void _databaseServerEntrypoint(({String path, SendPort reply}) message) {
  final port = ReceivePort();
  final server = DriftIsolate.inCurrent(
    () => NativeDatabase(File(message.path)),
    port: port,
    killIsolateWhenDone: true,
  );
  message.reply.send(server.connectPort);
}

// ---------------------------------------------------------------------------
// The backend: renewal that retires nothing, and a rendezvous so the
// contention is arranged rather than hoped for.
// ---------------------------------------------------------------------------

/// Emulates `POST /api/v1/auth/renew` as `backend/accounts/API.md` documents
/// it: nothing is written and no generation moves, so a token may be presented
/// again and again and every answer is another working token. The one refusal
/// left is `token_revoked`, for a device or an account that is gone.
final class _Backend {
  _Backend({required this.rendezvous, required int serveFirst})
    // ignore: prefer_initializing_formals
    : _serveFirst = serveFirst {
    _incoming.listen(_onRequest);
  }

  /// How many presentations must be queued before any of them is answered.
  /// Two is what makes both contenders hold the same token at the same instant
  /// rather than merely close together.
  final int rendezvous;

  final ReceivePort _incoming = ReceivePort();
  final List<({int owner, String token, SendPort reply})> _waiting = [];
  final List<String> presentations = [];
  final List<String> issued = [];
  Completer<void>? _rendezvousReached;
  int _serveFirst;
  int _counter = 0;
  int rejections = 0;
  bool _holding = false;

  SendPort get port => _incoming.sendPort;

  /// Starts holding presentations again, so that the next [rendezvous] of them
  /// are in flight together.
  void beginRound({int? serveFirst}) {
    _holding = true;
    if (serveFirst != null) {
      _serveFirst = serveFirst;
    }
  }

  /// Completes once enough presentations are queued that releasing them is a
  /// genuine race rather than a sequence.
  Future<void> awaitRendezvous() {
    if (!_holding || _waiting.length >= rendezvous) {
      return Future.value();
    }
    return (_rendezvousReached ??= Completer<void>()).future;
  }

  void close() => _incoming.close();

  void _onRequest(Object? message) {
    final request = message! as List<Object?>;
    _waiting.add((
      owner: request[0]! as int,
      token: request[1]! as String,
      reply: request[2]! as SendPort,
    ));
    if (_holding && _waiting.length < rendezvous) {
      return;
    }
    if (_holding) {
      _holding = false;
      _rendezvousReached?.complete();
      _rendezvousReached = null;
    }
    _release();
  }

  /// Answers everything queued, starting with the owner this round is meant to
  /// serve first. Both orderings are therefore chosen rather than observed.
  void _release() {
    var first = true;
    while (_waiting.isNotEmpty) {
      var index = 0;
      if (first) {
        final chosen = _waiting.indexWhere((held) => held.owner == _serveFirst);
        index = chosen == -1 ? 0 : chosen;
        first = false;
      }
      _answer(_waiting.removeAt(index));
    }
  }

  void _answer(({int owner, String token, SendPort reply}) request) {
    presentations.add(request.token);
    if (_revoked.contains(request.token)) {
      rejections += 1;
      request.reply.send(const ['revoked']);
      return;
    }
    _counter += 1;
    final renewed = 'token-$_counter';
    issued.add(renewed);
    request.reply.send(['ok', renewed]);
  }

  /// Tokens the server treats as belonging to a device it has revoked, which
  /// is the only answer left that ends a session before its own expiry.
  final Set<String> _revoked = {};

  void revoke(String token) => _revoked.add(token);
}

// ---------------------------------------------------------------------------
// One delivery owner, in its own isolate.
// ---------------------------------------------------------------------------

final class _OwnerReport {
  const _OwnerReport({required this.accessToken, required this.terminations});

  final String? accessToken;
  final List<String> terminations;

  @override
  String toString() => 'access=$accessToken terminations=$terminations';
}

final class _Owner {
  _Owner._(this._isolate, this._commands, this._replies);

  static Future<_Owner> start(
    int id,
    SendPort database,
    SendPort backend,
  ) async {
    final replies = ReceivePort();
    final stream = replies.asBroadcastStream();
    final isolate = await Isolate.spawn(_ownerEntrypoint, (
      id: id,
      database: database,
      backend: backend,
      reply: replies.sendPort,
    ));
    final commands = await stream.first as SendPort;
    return _Owner._(isolate, commands, stream);
  }

  final Isolate _isolate;
  final SendPort _commands;
  final Stream<Object?> _replies;

  Future<_OwnerReport> renew() async {
    final answer = _replies.first;
    _commands.send('renew');
    final message = await answer as List<Object?>;
    return _OwnerReport(
      accessToken: message[0] as String?,
      terminations: (message[1]! as List<Object?>).cast<String>(),
    );
  }

  /// Stops this owner the way the platform stops one: without warning, and
  /// without any chance to release anything.
  Future<void> kill() async {
    _isolate.kill(priority: Isolate.immediate);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Future<void> stop() async {
    _isolate.kill(priority: Isolate.immediate);
  }
}

Future<void> _ownerEntrypoint(
  ({int id, SendPort database, SendPort backend, SendPort reply}) message,
) async {
  final commands = ReceivePort();
  final connection = await DriftIsolate.fromConnectPort(
    message.database,
  ).connect();
  final store = SecureSessionTokenAdapter(_runtimeOn(connection));
  final terminations = <String>[];
  final exchange = _PortRenewExchange(message.id, message.backend);
  final coordinator = TokenCoordinator(
    store: store,
    renewExchange: exchange,
    terminationHandler: _RecordingTermination(terminations),
    timeSource: const _RealClock(),
  );
  exchange.coordinator = coordinator;

  message.reply.send(commands.sendPort);
  await for (final _ in commands) {
    terminations.clear();
    final result = await coordinator.accessToken();
    message.reply.send([
      switch (result) {
        Success(value: final token) => token.value,
        FailureResult() => null,
      },
      List<String>.of(terminations),
    ]);
  }
}

SecureLocalStorageRuntime _runtimeOn(QueryExecutor executor) =>
    SecureLocalStorageRuntime(
      protectedStorage: const _HostKeystore(),
      cleanup: const _NoCleanup(),
      executorFactory: (_) => executor,
    );

SessionTokens _tokens(String token) => SessionTokens(
  accessToken: AccessToken(
    value: token,
    // Already run out, which is the lever this harness renews on demand with.
    // A real session token lives thirty days; an owner asked for one that has
    // aged out renews on the spot, which is what puts two of them in the
    // window together on command.
    expiresAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    scope: SessionScope.full,
  ),
  userId: '11111111-1111-4111-8111-111111111111',
  deviceId: '22222222-2222-4222-8222-222222222222',
  username: 'contender',
);

/// Asks the coordinator for the token to present, which is what the reviewed
/// client does for an `AuthenticationRequirement.full` request — and the
/// renewal is one.
final class _PortRenewExchange implements RenewTokenExchange {
  _PortRenewExchange(this.owner, this._backend);

  final int owner;
  final SendPort _backend;
  late final AccessTokenCoordinator coordinator;

  @override
  Future<Result<SessionTokens>> renew() async {
    final header = await coordinator.accessToken();
    if (header case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final presented = (header as Success<AccessToken>).value.value;
    final answer = ReceivePort();
    _backend.send([owner, presented, answer.sendPort]);
    final reply = (await answer.first)! as List<Object?>;
    answer.close();
    return switch (reply[0]) {
      'ok' => Result.success(_tokens(reply[1]! as String)),
      'revoked' => const Result.failure(
        BackendFailure(BackendFailureCode.tokenRevoked),
      ),
      _ => const Result.failure(
        BackendFailure(BackendFailureCode.invalidToken),
      ),
    };
  }
}

final class _RecordingTermination implements SessionTerminationHandler {
  const _RecordingTermination(this._observed);

  final List<String> _observed;

  @override
  Future<void> terminate(SessionTerminationReason reason) async =>
      _observed.add(reason.name);
}

final class _RealClock implements TimeSource {
  const _RealClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

final class _HostKeystore implements PlatformProtectedStoragePort {
  const _HostKeystore();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<PlatformStorageUnlock> loadOrCreateStorageKey() async =>
      PlatformStorageUnlock(
        status: PlatformStorageKeyStatus.ready,
        protection: PlatformStorageProtection.software,
        databaseKey: Uint8List(32),
      );

  @override
  Future<void> destroyWrappingKey() async {}
}

final class _NoCleanup implements LocalArtifactCleanupPort {
  const _NoCleanup();

  @override
  Future<CleanupReport> cleanupBounded({required int maximumEntries}) async =>
      const CleanupReport(removedEntries: 0, hasMore: false);

  @override
  Future<void> erasePersistentArtifacts() async {}

  @override
  Future<void> clearVolatilePlaintext() async {}
}
