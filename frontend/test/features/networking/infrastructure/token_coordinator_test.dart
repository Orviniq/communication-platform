import 'dart:async';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/auth/token_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('proactive concurrent renewals call the route exactly once', () async {
    final store = MemoryTokenStore(
      session('old-token', DateTime.utc(2026, 7, 27, 12, 1)),
    );
    final exchange = ControlledRenewExchange();
    final termination = RecordingTerminationHandler();
    final coordinator = TokenCoordinator(
      store: store,
      renewExchange: exchange,
      terminationHandler: termination,
      timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
    );

    final requests = List.generate(20, (_) => coordinator.accessToken());
    await Future<void>.delayed(Duration.zero);
    expect(exchange.calls, 1);
    exchange.completer.complete(
      Result.success(session('new-token', DateTime.utc(2026, 7, 27, 13))),
    );
    final results = await Future.wait(requests);

    expect(results, everyElement(isA<Success<AccessToken>>()));
    expect(
      results.map((result) => (result as Success<AccessToken>).value.value),
      everyElement('new-token'),
    );
    expect(store.replacements, 1);
    expect(store.current?.accessToken.value, 'new-token');
    expect(termination.reasons, isEmpty);
  });

  test('the renewal presents its own token instead of deadlocking', () async {
    // The renewal is an authenticated request like any other: the reviewed
    // client asks this coordinator for the header token while the renewal is
    // the flight in progress. Handing back the flight would wait on the
    // request that is waiting on the answer.
    final store = MemoryTokenStore(
      session('old-token', DateTime.utc(2026, 7, 27, 12, 1)),
    );
    final exchange = ReentrantRenewExchange(
      Result.success(session('new-token', DateTime.utc(2026, 7, 27, 13))),
    );
    final coordinator = TokenCoordinator(
      store: store,
      renewExchange: exchange,
      terminationHandler: RecordingTerminationHandler(),
      timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
    );
    exchange.coordinator = coordinator;

    final result = await coordinator.accessToken();

    expect((result as Success<AccessToken>).value.value, 'new-token');
    expect(
      exchange.presented,
      ['old-token'],
      reason: 'the header carries the token the renewal was started with',
    );
  });

  test('a refused renewal ends the session rather than recovering', () async {
    // `DioRestClient` answers a 401 by asking the coordinator to recover the
    // rejected token before it gives up on the request. Inside the renewal
    // that question has no answer but the refusal itself.
    final store = MemoryTokenStore(
      session('stale-token', DateTime.utc(2026, 7, 27, 12, 1)),
    );
    final termination = RecordingTerminationHandler();
    final exchange = UnauthorizedRenewExchange();
    final coordinator = TokenCoordinator(
      store: store,
      renewExchange: exchange,
      terminationHandler: termination,
      timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
    );
    exchange.coordinator = coordinator;

    final result = await coordinator.accessToken();

    expect(result, isA<FailureResult<AccessToken>>());
    expect(exchange.recoveries, [isA<FailureResult<AccessToken>>()]);
    expect(store.current, isNull);
    expect(termination.reasons, [SessionTerminationReason.expired]);
  });

  test(
    'unauthorized request reuses a token a renewal already stored',
    () async {
      final store = MemoryTokenStore(
        session('new-token', DateTime.utc(2026, 7, 27, 13)),
      );
      final exchange = ControlledRenewExchange();
      final coordinator = TokenCoordinator(
        store: store,
        renewExchange: exchange,
        terminationHandler: RecordingTerminationHandler(),
        timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
      );

      final result = await coordinator.recoverAfterUnauthorized('old-token');
      expect((result as Success<AccessToken>).value.value, 'new-token');
      expect(exchange.calls, 0);
    },
  );

  test('a revoked device clears and terminates the local session', () async {
    final store = MemoryTokenStore(
      session('old-token', DateTime.utc(2026, 7, 27, 11)),
    );
    final termination = RecordingTerminationHandler();
    final exchange = ImmediateRenewExchange(
      const Result.failure(BackendFailure(BackendFailureCode.tokenRevoked)),
    );
    final coordinator = TokenCoordinator(
      store: store,
      renewExchange: exchange,
      terminationHandler: termination,
      timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
    );

    final result = await coordinator.accessToken();
    expect(result, isA<FailureResult<AccessToken>>());
    expect(store.current, isNull);
    expect(termination.reasons, [SessionTerminationReason.revoked]);
  });

  test('an offline renewal keeps the session it could not renew', () async {
    // Nothing retires the token in hand, so a renewal that never reached the
    // server leaves a session that is still good until its own expiry.
    final store = MemoryTokenStore(
      session('old-token', DateTime.utc(2026, 7, 27, 12, 1)),
    );
    final termination = RecordingTerminationHandler();
    final coordinator = TokenCoordinator(
      store: store,
      renewExchange: const ImmediateRenewExchange(
        Result.failure(TransportFailure(TransportFailureKind.offline)),
      ),
      terminationHandler: termination,
      timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
    );

    final result = await coordinator.accessToken();

    expect(
      (result as FailureResult<AccessToken>).failure,
      isA<TransportFailure>(),
    );
    expect(store.current?.accessToken.value, 'old-token');
    expect(termination.reasons, isEmpty);
  });

  test('logout wipes locally even when remote logout fails', () async {
    final store = MemoryTokenStore(
      session('old-token', DateTime.utc(2026, 7, 27, 13)),
    );
    final termination = RecordingTerminationHandler();
    final logout = ThrowingLogoutExchange();
    final coordinator = TokenCoordinator(
      store: store,
      renewExchange: ImmediateRenewExchange(
        Result.success(session('unused', DateTime.utc(2026, 7, 27, 14))),
      ),
      logoutExchange: logout,
      terminationHandler: termination,
      timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
    );

    await coordinator.logout();
    expect(logout.presented, ['old-token']);
    expect(store.current, isNull);
    expect(termination.reasons, [SessionTerminationReason.logout]);
  });

  test(
    'a renewal completing after logout cannot resurrect the session',
    () async {
      final store = MemoryTokenStore(
        session('old-token', DateTime.utc(2026, 7, 27, 11)),
      );
      final exchange = ControlledRenewExchange();
      final coordinator = TokenCoordinator(
        store: store,
        renewExchange: exchange,
        terminationHandler: RecordingTerminationHandler(),
        timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
      );

      final renewal = coordinator.accessToken();
      await Future<void>.delayed(Duration.zero);
      await coordinator.logout();
      exchange.completer.complete(
        Result.success(session('late-token', DateTime.utc(2026, 7, 27, 13))),
      );

      expect(await renewal, isA<FailureResult<AccessToken>>());
      expect(store.current, isNull);
      expect(store.replacements, 0);
    },
  );

  test('register-scope token cannot renew and expires closed', () async {
    // `POST /auth/renew` answers `403 scope_forbidden` to a register token,
    // which names no device and so has no session to renew.
    final store = MemoryTokenStore(
      SessionTokens(
        accessToken: AccessToken(
          value: 'register-token',
          expiresAt: DateTime.utc(2026, 7, 27, 11),
          scope: SessionScope.register,
        ),
      ),
    );
    final termination = RecordingTerminationHandler();
    final exchange = ControlledRenewExchange();
    final coordinator = TokenCoordinator(
      store: store,
      renewExchange: exchange,
      terminationHandler: termination,
      timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
    );

    final result = await coordinator.accessToken();
    expect(result, isA<FailureResult<AccessToken>>());
    expect(exchange.calls, 0);
    expect(termination.reasons, [SessionTerminationReason.expired]);
  });

  test('a register token still live is answered, never renewed', () async {
    final store = MemoryTokenStore(
      SessionTokens(
        accessToken: AccessToken(
          value: 'register-token',
          expiresAt: DateTime.utc(2026, 7, 27, 12, 1),
          scope: SessionScope.register,
        ),
      ),
    );
    final termination = RecordingTerminationHandler();
    final exchange = ControlledRenewExchange();
    final coordinator = TokenCoordinator(
      store: store,
      renewExchange: exchange,
      terminationHandler: termination,
      timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
    );

    // Inside the proactive window, where a session token would renew.
    final result = await coordinator.accessToken();
    expect((result as Success<AccessToken>).value.value, 'register-token');
    expect(exchange.calls, 0);
    expect(termination.reasons, isEmpty);
  });

  test('a renewal keeps the identity the session is bound to', () async {
    final store = MemoryTokenStore(
      SessionTokens(
        accessToken: AccessToken(
          value: 'old-token',
          expiresAt: DateTime.utc(2026, 7, 27, 12, 1),
          scope: SessionScope.full,
        ),
        userId: 'a3f1c8d2-0b57-4e6a-9c31-77d2e4b8f015',
        deviceId: '5e2b9a41-6c73-4d8f-b210-9a4c6f3d7e88',
        username: 'test2',
      ),
    );
    final exchange = ControlledRenewExchange();
    final coordinator = TokenCoordinator(
      store: store,
      renewExchange: exchange,
      terminationHandler: RecordingTerminationHandler(),
      timeSource: FixedTimeSource(DateTime.utc(2026, 7, 27, 12)),
    );

    final request = coordinator.accessToken();
    await Future<void>.delayed(Duration.zero);
    // `/auth/renew` answers a token and its lifetime and no identity at all,
    // which is what `session()` models.
    exchange.completer.complete(
      Result.success(session('new-token', DateTime.utc(2026, 7, 27, 13))),
    );
    await request;

    // Persisting the response verbatim erased these, and the next cold-start
    // restore read the null user back as a malformed server response and
    // signed the account out while its session was still valid.
    expect(store.current?.userId, 'a3f1c8d2-0b57-4e6a-9c31-77d2e4b8f015');
    expect(store.current?.deviceId, '5e2b9a41-6c73-4d8f-b210-9a4c6f3d7e88');
    expect(store.current?.username, 'test2');
    expect(store.current?.accessToken.value, 'new-token');
  });
}

final class FixedTimeSource implements TimeSource {
  const FixedTimeSource(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}

final class MemoryTokenStore implements SessionTokenStore {
  MemoryTokenStore(this.current);

  SessionTokens? current;
  int replacements = 0;
  int durableReads = 0;

  @override
  Future<void> clear() async {
    current = null;
  }

  @override
  Future<SessionTokens?> read() async => current;

  @override
  Future<SessionTokens?> readDurable() async {
    durableReads += 1;
    return current;
  }

  @override
  Future<void> replace(SessionTokens tokens) async {
    current = tokens;
    replacements += 1;
  }
}

final class ControlledRenewExchange implements RenewTokenExchange {
  final Completer<Result<SessionTokens>> completer = Completer();
  int calls = 0;

  @override
  Future<Result<SessionTokens>> renew() {
    calls += 1;
    return completer.future;
  }
}

final class ImmediateRenewExchange implements RenewTokenExchange {
  const ImmediateRenewExchange(this.result);

  final Result<SessionTokens> result;

  @override
  Future<Result<SessionTokens>> renew() async => result;
}

/// Asks the coordinator for a header token the way `DioRestClient` does for
/// [AuthenticationRequirement.full], from inside the renewal.
final class ReentrantRenewExchange implements RenewTokenExchange {
  ReentrantRenewExchange(this.result);

  final Result<SessionTokens> result;
  final List<String> presented = [];
  late final AccessTokenCoordinator coordinator;

  @override
  Future<Result<SessionTokens>> renew() async {
    final header = await coordinator.accessToken();
    presented.add((header as Success<AccessToken>).value.value);
    return result;
  }
}

/// The same, for a request the server then refuses.
final class UnauthorizedRenewExchange implements RenewTokenExchange {
  final List<Result<AccessToken>> recoveries = [];
  late final AccessTokenCoordinator coordinator;

  @override
  Future<Result<SessionTokens>> renew() async {
    final header = await coordinator.accessToken();
    final presented = (header as Success<AccessToken>).value.value;
    recoveries.add(await coordinator.recoverAfterUnauthorized(presented));
    return const Result.failure(
      BackendFailure(BackendFailureCode.invalidToken),
    );
  }
}

final class RecordingTerminationHandler implements SessionTerminationHandler {
  final List<SessionTerminationReason> reasons = [];

  @override
  Future<void> terminate(SessionTerminationReason reason) async {
    reasons.add(reason);
  }
}

final class ThrowingLogoutExchange implements LogoutTokenExchange {
  final List<String> presented = [];

  @override
  Future<void> revoke({required String accessToken}) {
    presented.add(accessToken);
    throw StateError('offline');
  }
}

SessionTokens session(String token, DateTime expiresAt) => SessionTokens(
  accessToken: AccessToken(
    value: token,
    expiresAt: expiresAt,
    scope: SessionScope.full,
  ),
);
