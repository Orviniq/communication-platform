// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';

final class TokenCoordinator implements AccessTokenCoordinator {
  TokenCoordinator({
    required this.store,
    required this.renewExchange,
    required this.terminationHandler,
    required this.timeSource,
    this.logoutExchange,
    this.proactiveRenewalWindow = const Duration(minutes: 2),
    this.clockSkewAllowance = const Duration(seconds: 30),
    this.earlyRenewalRetryInterval = const Duration(minutes: 1),
  });

  final SessionTokenStore store;
  final RenewTokenExchange renewExchange;
  final LogoutTokenExchange? logoutExchange;
  final SessionTerminationHandler terminationHandler;
  final TimeSource timeSource;

  /// With [clockSkewAllowance], the final stretch of a session token's life,
  /// in which a request waits for the renewal instead of going out with the
  /// token in hand. Renewal begins long before it, at half the token's
  /// lifetime; this is where a renewal that has still not landed stops being
  /// one that can wait (ADR-085).
  final Duration proactiveRenewalWindow;
  final Duration clockSkewAllowance;

  /// How long an early renewal that failed leaves the next one alone.
  ///
  /// The token in hand stays good meanwhile, so this only sets how often a
  /// device with no way to the server spends a request finding that out. A
  /// minute also outlasts a refusal from the `accounts` scope, which counts
  /// calls in a minute.
  final Duration earlyRenewalRetryInterval;

  /// The lifetime assumed for a token restored without one, from a row written
  /// before the lifetime was stored beside the token: `SESSION_TOKEN_DAYS` as
  /// this build states it, the deployment default of 30 (server ADR-0023).
  ///
  /// It is not the published value because this coordinator is built before
  /// the configuration is read, and outside the scope that follows it. The
  /// assumption lasts one token: the renewal it times answers a token whose
  /// own lifetime is stored.
  static final _assumedLifetime = Duration(
    days: ServerConfig.fallback.sessionTokenDays,
  );

  /// The one renewal in flight, so that N callers that find the token due cost
  /// one call rather than N: in the early stretch they start no renewal of
  /// their own while it runs, and in the final window they wait for it.
  ///
  /// It is a contention control and not a safety property (ADR-083). Against
  /// this server a renewal writes nothing and moves no generation, so the race
  /// this guard was built for — two owners renewing at once, the loser
  /// presenting a token the winner had retired, and the session ending for
  /// both — cannot happen: two concurrent renewals simply produce two working
  /// tokens (ADR-0023). What it still saves is the requests: one
  /// `POST /auth/renew`, one write of the session row and one new token, where
  /// every caller in the window would otherwise make its own against the
  /// `accounts` scope the peer reads share.
  Future<Result<AccessToken>>? _renewalInFlight;

  /// Marks the work of one renewal, so that a question asked from inside it is
  /// answered rather than joined.
  ///
  /// The renewal is itself an authenticated request: the reviewed client asks
  /// this coordinator for the token to put in its `Authorization` header, and
  /// that question arrives *while* the renewal it belongs to is the flight in
  /// progress. Answering it with [_renewalInFlight] would deadlock — that
  /// future cannot complete until the request waiting on this answer is sent.
  /// The presented token is the terminating answer, and the correct one: it is
  /// the token this renewal exists to present.
  ///
  /// The zone is what keeps the answer to that question from reaching anybody
  /// else. A caller outside the renewal is in no such trouble: in the final
  /// window it joins the flight and waits for the new token, and before that it
  /// is answered the token in hand, which is still good.
  static const _renewalMarker = #tokenCoordinatorRenewal;

  int _sessionGeneration = 0;

  /// Until when no early renewal starts, after one that failed.
  DateTime? _earlyRenewalPausedUntil;

  /// The token to send now, renewed when it is due.
  ///
  /// `POST /auth/renew` sits behind the verifier every authenticated route
  /// uses, so a token past its `exp` is refused there as `401 invalid_token`
  /// and the session ends. A device can go days without a request, so a
  /// session token is renewed from half its lifetime, while any request can
  /// still do it (ADR-085):
  ///
  /// - **Before half its lifetime** it is answered as it is.
  /// - **From half its lifetime** the first caller starts one renewal and every
  ///   caller is answered the token in hand, which is still good. Nobody waits
  ///   for that renewal, and one that fails without ending the session is
  ///   tried again [earlyRenewalRetryInterval] later.
  /// - **In the final [proactiveRenewalWindow] plus [clockSkewAllowance]**, and
  ///   whenever [forceRefresh] asks, the caller waits for the renewal and is
  ///   answered what it answers.
  ///
  /// A register token is never renewed.
  @override
  Future<Result<AccessToken>> accessToken({bool forceRefresh = false}) async {
    final presenting = Zone.current[_renewalMarker];
    if (presenting is AccessToken) {
      return Result.success(presenting);
    }
    final tokens = await store.read();
    if (tokens == null) {
      return const Result.failure(
        AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
      );
    }
    final token = tokens.accessToken;
    final now = timeSource.now().toUtc();
    if (token.scope != SessionScope.full) {
      // A register token names no device, so there is no session to renew and
      // `POST /auth/renew` answers `403 scope_forbidden`. Its ten minutes are
      // the whole of its life: it is spent on `POST /me/devices`, which
      // answers the session token that replaces it.
      if (now.isBefore(token.expiresAt.subtract(clockSkewAllowance))) {
        return Result.success(token);
      }
      await _terminate(SessionTerminationReason.expired);
      return const Result.failure(
        AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
      );
    }
    final renewBy = token.expiresAt.subtract(
      proactiveRenewalWindow + clockSkewAllowance,
    );
    if (forceRefresh || !now.isBefore(renewBy)) {
      return _singleFlightRenewal(token);
    }
    final renewFrom = token.expiresAt.subtract(
      (token.lifetime ?? _assumedLifetime) ~/ 2,
    );
    if (!now.isBefore(renewFrom)) {
      _startEarlyRenewal(token, now);
    }
    return Result.success(token);
  }

  @override
  Future<Result<AccessToken>> recoverAfterUnauthorized(
    String rejectedToken,
  ) async {
    if (Zone.current[_renewalMarker] is AccessToken) {
      // The renewal's own request was refused. There is nothing to recover
      // with: the only token this coordinator holds is the one the server just
      // rejected, and asking for another is the call that is already failing.
      // The refusal travels back to [_performRenewal], which ends the session.
      return const Result.failure(
        AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
      );
    }
    final current = await store.read();
    if (current == null) {
      return const Result.failure(
        AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
      );
    }
    if (current.accessToken.value != rejectedToken) {
      return Result.success(current.accessToken);
    }
    return accessToken(forceRefresh: true);
  }

  /// Starts a renewal of [held] that no caller waits for, unless one is in
  /// flight already or the last early one failed under
  /// [earlyRenewalRetryInterval] ago.
  void _startEarlyRenewal(AccessToken held, DateTime now) {
    final pausedUntil = _earlyRenewalPausedUntil;
    if (_renewalInFlight != null ||
        (pausedUntil != null && now.isBefore(pausedUntil))) {
      return;
    }
    unawaited(_renewEarly(held));
  }

  Future<void> _renewEarly(AccessToken held) async {
    var renewed = false;
    try {
      final result = await _singleFlightRenewal(held);
      renewed = result is Success<AccessToken>;
    } on Object {
      // No caller waits on this renewal, so a throw here would reach nobody.
      // The token in hand is still good; the pause below is all it changes.
    }
    _earlyRenewalPausedUntil = renewed
        ? null
        : timeSource.now().toUtc().add(earlyRenewalRetryInterval);
  }

  Future<Result<AccessToken>> _singleFlightRenewal(AccessToken presented) {
    final existing = _renewalInFlight;
    if (existing != null) {
      return existing;
    }
    final renewal = _performRenewal(presented, _sessionGeneration);
    _renewalInFlight = renewal;
    return renewal.whenComplete(() {
      if (identical(_renewalInFlight, renewal)) {
        _renewalInFlight = null;
      }
    });
  }

  Future<Result<AccessToken>> _performRenewal(
    AccessToken presented,
    int generation,
  ) async {
    // The request this call is about to make asks for the token on its way
    // out, and the marker is how that question is answered. See
    // [_renewalMarker].
    final result = await runZoned(
      renewExchange.renew,
      zoneValues: <Object?, Object?>{_renewalMarker: presented},
    );
    switch (result) {
      case Success(value: final renewed):
        if (generation != _sessionGeneration) {
          return const Result.failure(
            AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
          );
        }
        // `/auth/renew` answers a token and its lifetime and nothing else,
        // so the value decoded from it carries no `userId`, `deviceId` or
        // `username`. Replacing the durable record with it verbatim erased
        // the identity the session is bound to, and the next restore read
        // that back as a null user and reported a malformed server response
        // - signing the account out on the first cold start after a renewal,
        // with a durable session that was still perfectly valid. A renewal
        // changes the credential, never whose credential it is.
        final identity = await store.read();
        await store.replace(
          SessionTokens(
            accessToken: renewed.accessToken,
            userId: renewed.userId ?? identity?.userId,
            deviceId: renewed.deviceId ?? identity?.deviceId,
            username: renewed.username ?? identity?.username,
          ),
        );
        return Result.success(renewed.accessToken);
      case FailureResult(failure: final failure):
        if (!_endsSession(failure)) {
          return Result.failure(failure);
        }
        if (generation != _sessionGeneration) {
          // Whatever moved the generation ends the session, so this refusal
          // ends nothing more. The renewal's own request is an ordinary
          // authenticated one: on `token_revoked` the reviewed client has
          // called [handleRevocation] before this failure arrives. A logout
          // that lands while the renewal is out moves it as well.
          return Result.failure(failure);
        }
        final reason =
            failure is BackendFailure &&
                failure.code == BackendFailureCode.tokenRevoked
            ? SessionTerminationReason.revoked
            : SessionTerminationReason.expired;
        await _terminate(reason);
        return Result.failure(failure);
    }
  }

  /// Whether this failure means the session is over.
  ///
  /// It is the plain reading now. Nothing but a logout, a device revocation or
  /// a deactivated account ends a token before its own `exp`, so a refused
  /// token is a refused session rather than possibly the debris of a race:
  /// there is no rotation left to have lost.
  bool _endsSession(Failure failure) => switch (failure) {
    BackendFailure(
      code: BackendFailureCode.invalidToken || BackendFailureCode.tokenRevoked,
    ) =>
      true,
    AuthenticationFailure(kind: AuthenticationFailureKind.sessionExpired) =>
      true,
    _ => false,
  };

  @override
  Future<void> logout() async {
    _sessionGeneration += 1;
    final tokens = await store.read();
    try {
      if (tokens != null && tokens.accessToken.value.isNotEmpty) {
        await logoutExchange?.revoke(accessToken: tokens.accessToken.value);
      }
    } on Object {
      // Local logout and wipe are mandatory even when the server is unreachable.
    } finally {
      await _terminate(SessionTerminationReason.logout);
    }
  }

  @override
  Future<void> handleRevocation() {
    _sessionGeneration += 1;
    return _terminate(SessionTerminationReason.revoked);
  }

  Future<void> _terminate(SessionTerminationReason reason) async {
    if (reason != SessionTerminationReason.logout &&
        reason != SessionTerminationReason.revoked) {
      _sessionGeneration += 1;
    }
    await store.clear();
    await terminationHandler.terminate(reason);
  }
}
