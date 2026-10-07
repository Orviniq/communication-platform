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

  group('renewal from half the lifetime (ADR-085)', () {
    // A session token as `SESSION_TOKEN_DAYS` issues it by default.
    const lifetime = Duration(days: 30);
    final issuedAt = DateTime.utc(2026, 10, 1, 12);
    final expiresAt = issuedAt.add(lifetime);

    test(
      'a device idle through a token’s final minutes keeps its session',
      () async {
        // The defect. Renewal began two and a half minutes before expiry,
        // and the route refuses a token past its `exp`, so a device that
        // made no request in those minutes was signed out by its next one.
        final clock = MutableTimeSource(issuedAt);
        final server = ExpiringRenewServer(clock, lifetime: lifetime);
        final store = MemoryTokenStore(server.issue());
        final termination = RecordingTerminationHandler();
        final coordinator = TokenCoordinator(
          store: store,
          renewExchange: server,
          terminationHandler: termination,
          timeSource: clock,
        );
        server.coordinator = coordinator;

        // A request on the first day, one on the twentieth, then nothing
        // until a day after the first token's thirtieth.
        for (final day in const [1, 20, 31]) {
          clock.value = issuedAt.add(Duration(days: day));
          final result = await coordinator.accessToken();
          await Future<void>.delayed(Duration.zero);
          expect(result, isA<Success<AccessToken>>(), reason: 'day $day');
        }

        expect(termination.reasons, isEmpty);
        expect(server.refused, isEmpty);
        expect(server.issued, hasLength(2), reason: 'a login and a renewal');
        expect(store.current?.accessToken.value, server.issued.last);
      },
    );

    test(
      'a token past half its lifetime is renewed behind the request',
      () async {
        final now = issuedAt.add(const Duration(days: 16));
        final store = MemoryTokenStore(
          session('old-token', expiresAt, lifetime: lifetime),
        );
        final exchange = ControlledRenewExchange();
        final termination = RecordingTerminationHandler();
        final coordinator = TokenCoordinator(
          store: store,
          renewExchange: exchange,
          terminationHandler: termination,
          timeSource: FixedTimeSource(now),
        );

        // Fourteen days from expiry the token in hand is good, so the request
        // goes out with it rather than after the renewal it started.
        final result = await coordinator.accessToken();
        expect((result as Success<AccessToken>).value.value, 'old-token');
        expect(exchange.calls, 1);

        exchange.completer.complete(
          Result.success(
            session('new-token', now.add(lifetime), lifetime: lifetime),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(store.current?.accessToken.value, 'new-token');
        final next = await coordinator.accessToken();
        expect((next as Success<AccessToken>).value.value, 'new-token');
        expect(exchange.calls, 1, reason: 'the new token is not due');
        expect(termination.reasons, isEmpty);
      },
    );

    test('a token short of half its lifetime is answered as it is', () async {
      final store = MemoryTokenStore(
        session('old-token', expiresAt, lifetime: lifetime),
      );
      final exchange = ControlledRenewExchange();
      final coordinator = TokenCoordinator(
        store: store,
        renewExchange: exchange,
        terminationHandler: RecordingTerminationHandler(),
        timeSource: FixedTimeSource(issuedAt.add(const Duration(days: 14))),
      );

      final result = await coordinator.accessToken();

      expect((result as Success<AccessToken>).value.value, 'old-token');
      expect(exchange.calls, 0);
    });

    test('the half is of the token’s own lifetime', () async {
      // A deployment that issues ten-day tokens. Six days left is not due,
      // although it would be under the thirty-day default.
      const tenDays = Duration(days: 10);
      final clock = MutableTimeSource(issuedAt.add(const Duration(days: 4)));
      final exchange = ControlledRenewExchange();
      final coordinator = TokenCoordinator(
        store: MemoryTokenStore(
          session('old-token', issuedAt.add(tenDays), lifetime: tenDays),
        ),
        renewExchange: exchange,
        terminationHandler: RecordingTerminationHandler(),
        timeSource: clock,
      );

      await coordinator.accessToken();
      expect(exchange.calls, 0);

      clock.value = issuedAt.add(const Duration(days: 6));
      await coordinator.accessToken();
      expect(exchange.calls, 1);
    });

    test('a token restored without a lifetime is given the default', () async {
      // A row written before the lifetime was stored. Thirty days is
      // `SESSION_TOKEN_DAYS` as this build states it.
      final clock = MutableTimeSource(
        expiresAt.subtract(const Duration(days: 16)),
      );
      final exchange = ControlledRenewExchange();
      final coordinator = TokenCoordinator(
        store: MemoryTokenStore(session('old-token', expiresAt)),
        renewExchange: exchange,
        terminationHandler: RecordingTerminationHandler(),
        timeSource: clock,
      );

      await coordinator.accessToken();
      expect(exchange.calls, 0);

      clock.value = expiresAt.subtract(const Duration(days: 14));
      await coordinator.accessToken();
      expect(exchange.calls, 1);
    });

    test('every caller past half its lifetime shares one renewal', () async {
      final now = issuedAt.add(const Duration(days: 20));
      final store = MemoryTokenStore(
        session('old-token', expiresAt, lifetime: lifetime),
      );
      final exchange = ControlledRenewExchange();
      final coordinator = TokenCoordinator(
        store: store,
        renewExchange: exchange,
        terminationHandler: RecordingTerminationHandler(),
        timeSource: FixedTimeSource(now),
      );

      final results = await Future.wait(
        List.generate(20, (_) => coordinator.accessToken()),
      );

      // Nobody waited for the renewal, and it was started once.
      expect(
        results.map((result) => (result as Success<AccessToken>).value.value),
        everyElement('old-token'),
      );
      expect(exchange.calls, 1);

      exchange.completer.complete(
        Result.success(
          session('new-token', now.add(lifetime), lifetime: lifetime),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(store.replacements, 1);
      expect(store.current?.accessToken.value, 'new-token');
    });

    test('an early renewal that fails keeps the token and waits', () async {
      final clock = MutableTimeSource(issuedAt.add(const Duration(days: 20)));
      final store = MemoryTokenStore(
        session('old-token', expiresAt, lifetime: lifetime),
      );
      final exchange = CountingRenewExchange(
        const Result.failure(TransportFailure(TransportFailureKind.offline)),
      );
      final termination = RecordingTerminationHandler();
      final coordinator = TokenCoordinator(
        store: store,
        renewExchange: exchange,
        terminationHandler: termination,
        timeSource: clock,
      );

      final first = await coordinator.accessToken();
      await Future<void>.delayed(Duration.zero);
      expect((first as Success<AccessToken>).value.value, 'old-token');
      expect(exchange.calls, 1);

      // Ten days from expiry the token still carries every request, and the
      // next attempt waits out the retry interval.
      clock.value = clock.value.add(const Duration(seconds: 59));
      final second = await coordinator.accessToken();
      await Future<void>.delayed(Duration.zero);
      expect((second as Success<AccessToken>).value.value, 'old-token');
      expect(exchange.calls, 1);

      clock.value = clock.value.add(const Duration(seconds: 1));
      await coordinator.accessToken();
      await Future<void>.delayed(Duration.zero);
      expect(exchange.calls, 2);

      expect(store.current?.accessToken.value, 'old-token');
      expect(store.replacements, 0);
      expect(termination.reasons, isEmpty);
    });

    test('an early renewal the server refuses ends the session', () async {
      // The route re-checks the device and the account, so a refusal ten
      // days before expiry is the session ending, not a token wearing out.
      final store = MemoryTokenStore(
        session('old-token', expiresAt, lifetime: lifetime),
      );
      final termination = RecordingTerminationHandler();
      final coordinator = TokenCoordinator(
        store: store,
        renewExchange: const ImmediateRenewExchange(
          Result.failure(BackendFailure(BackendFailureCode.invalidToken)),
        ),
        terminationHandler: termination,
        timeSource: FixedTimeSource(issuedAt.add(const Duration(days: 20))),
      );

      await coordinator.accessToken();
      await Future<void>.delayed(Duration.zero);

      expect(store.current, isNull);
      expect(termination.reasons, [SessionTerminationReason.expired]);
      expect(
        await coordinator.accessToken(),
        isA<FailureResult<AccessToken>>(),
      );
    });

    test(
      'the early renewal presents the token in hand instead of deadlocking',
      () async {
        final now = issuedAt.add(const Duration(days: 20));
        final store = MemoryTokenStore(
          session('old-token', expiresAt, lifetime: lifetime),
        );
        final exchange = ReentrantRenewExchange(
          Result.success(
            session('new-token', now.add(lifetime), lifetime: lifetime),
          ),
        );
        final coordinator = TokenCoordinator(
          store: store,
          renewExchange: exchange,
          terminationHandler: RecordingTerminationHandler(),
          timeSource: FixedTimeSource(now),
        );
        exchange.coordinator = coordinator;

        final result = await coordinator.accessToken();
        await Future<void>.delayed(Duration.zero);

        expect((result as Success<AccessToken>).value.value, 'old-token');
        expect(exchange.presented, ['old-token']);
        expect(store.current?.accessToken.value, 'new-token');
      },
    );

    test('a register token past half its lifetime is never renewed', () async {
      const tenMinutes = Duration(minutes: 10);
      final exchange = ControlledRenewExchange();
      final termination = RecordingTerminationHandler();
      final coordinator = TokenCoordinator(
        store: MemoryTokenStore(
          SessionTokens(
            accessToken: AccessToken(
              value: 'register-token',
              expiresAt: issuedAt.add(tenMinutes),
              scope: SessionScope.register,
              lifetime: tenMinutes,
            ),
          ),
        ),
        renewExchange: exchange,
        terminationHandler: termination,
        timeSource: FixedTimeSource(issuedAt.add(const Duration(minutes: 6))),
      );

      final result = await coordinator.accessToken();
      await Future<void>.delayed(Duration.zero);

      expect((result as Success<AccessToken>).value.value, 'register-token');
      expect(exchange.calls, 0);
      expect(termination.reasons, isEmpty);
    });
  });
}

final class FixedTimeSource implements TimeSource {
  const FixedTimeSource(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}

final class MutableTimeSource implements TimeSource {
  MutableTimeSource(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}

final class MemoryTokenStore implements SessionTokenStore {
  MemoryTokenStore(this.current);

  SessionTokens? current;
  int replacements = 0;

  @override
  Future<void> clear() async {
    current = null;
  }

  @override
  Future<SessionTokens?> read() async => current;

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

final class CountingRenewExchange implements RenewTokenExchange {
  CountingRenewExchange(this.result);

  final Result<SessionTokens> result;
  int calls = 0;

  @override
  Future<Result<SessionTokens>> renew() async {
    calls += 1;
    return result;
  }
}

/// `POST /auth/renew` against the clock: it issues tokens of [lifetime], and
/// refuses one past its expiry as `401 invalid_token`, because the route sits
/// behind the verifier every authenticated route uses.
final class ExpiringRenewServer implements RenewTokenExchange {
  ExpiringRenewServer(this.clock, {required this.lifetime});

  final MutableTimeSource clock;
  final Duration lifetime;
  final List<String> issued = [];
  final List<String> refused = [];
  final Map<String, DateTime> _expiries = {};
  late final AccessTokenCoordinator coordinator;

  SessionTokens issue() {
    final value = 'token-${issued.length}';
    final expiresAt = clock.now().add(lifetime);
    _expiries[value] = expiresAt;
    issued.add(value);
    return session(value, expiresAt, lifetime: lifetime);
  }

  @override
  Future<Result<SessionTokens>> renew() async {
    final header = await coordinator.accessToken();
    final presented = (header as Success<AccessToken>).value.value;
    if (!clock.now().isBefore(_expiries[presented]!)) {
      refused.add(presented);
      return const Result.failure(
        BackendFailure(BackendFailureCode.invalidToken),
      );
    }
    return Result.success(issue());
  }
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

SessionTokens session(String token, DateTime expiresAt, {Duration? lifetime}) =>
    SessionTokens(
      accessToken: AccessToken(
        value: token,
        expiresAt: expiresAt,
        scope: SessionScope.full,
        lifetime: lifetime,
      ),
    );
