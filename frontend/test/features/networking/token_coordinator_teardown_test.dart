import 'dart:async';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/auth/token_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two teardowns that overlap are one teardown.
///
/// Erasing an account closes each socket of the account with `4003`, which the
/// gateway answers with `handleRevocation()`, and the erase itself then ends in
/// `logout()`. Both wipe the device and both tell the application the session
/// is over, so run together they wiped twice and terminated twice. The first
/// reason is the one the application is told.
void main() {
  late _GatedStore store;
  late _RecordingTermination termination;
  late TokenCoordinator coordinator;

  setUp(() {
    store = _GatedStore();
    termination = _RecordingTermination();
    coordinator = TokenCoordinator(
      store: store,
      renewExchange: const _NoRenewal(),
      terminationHandler: termination,
      timeSource: const _Clock(),
    );
  });

  test(
    'a revocation during a logout wipes once and ends as a logout',
    () async {
      store.gateNextClear();

      final logout = coordinator.logout();
      await store.clearEntered;
      final revocation = coordinator.handleRevocation();
      store.releaseClear();
      await Future.wait([logout, revocation]);

      expect(store.clears, 1);
      expect(termination.reasons, [SessionTerminationReason.logout]);
    },
  );

  test('a logout during a revocation wipes once and ends as revoked', () async {
    store.gateNextClear();

    final revocation = coordinator.handleRevocation();
    await store.clearEntered;
    final logout = coordinator.logout();
    store.releaseClear();
    await Future.wait([revocation, logout]);

    expect(store.clears, 1);
    expect(termination.reasons, [SessionTerminationReason.revoked]);
  });

  test('a teardown after the first has finished runs on its own', () async {
    await coordinator.handleRevocation();
    await coordinator.logout();

    expect(store.clears, 2);
    expect(termination.reasons, [
      SessionTerminationReason.revoked,
      SessionTerminationReason.logout,
    ]);
  });
}

final class _GatedStore implements SessionTokenStore {
  int clears = 0;
  Completer<void> _release = Completer<void>();
  Completer<void> _entered = Completer<void>();
  bool _gateNext = false;

  Future<void> get clearEntered => _entered.future;

  void gateNextClear() {
    _release = Completer<void>();
    _entered = Completer<void>();
    _gateNext = true;
  }

  void releaseClear() => _release.complete();

  @override
  Future<SessionTokens?> read() async => SessionTokens(
    accessToken: AccessToken(
      value: 'access-token-value',
      expiresAt: DateTime.utc(2100),
      scope: SessionScope.full,
    ),
  );

  @override
  Future<void> replace(SessionTokens tokens) async {}

  @override
  Future<void> clear() async {
    clears += 1;
    if (_gateNext) {
      _gateNext = false;
      _entered.complete();
      await _release.future;
    }
  }
}

final class _RecordingTermination implements SessionTerminationHandler {
  final List<SessionTerminationReason> reasons = [];

  @override
  Future<void> terminate(SessionTerminationReason reason) async =>
      reasons.add(reason);
}

final class _NoRenewal implements RenewTokenExchange {
  const _NoRenewal();

  @override
  Future<Result<SessionTokens>> renew() => throw StateError('no renewal here');
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() => DateTime.utc(2026, 10, 17, 12);
}
