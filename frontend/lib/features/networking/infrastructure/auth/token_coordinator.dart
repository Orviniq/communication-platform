// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';

final class TokenCoordinator implements AccessTokenCoordinator {
  TokenCoordinator({
    required this.store,
    required this.renewExchange,
    required this.terminationHandler,
    required this.timeSource,
    this.logoutExchange,
    this.proactiveRenewalWindow = const Duration(minutes: 2),
    this.clockSkewAllowance = const Duration(seconds: 30),
  });

  final SessionTokenStore store;
  final RenewTokenExchange renewExchange;
  final LogoutTokenExchange? logoutExchange;
  final SessionTerminationHandler terminationHandler;
  final TimeSource timeSource;
  final Duration proactiveRenewalWindow;
  final Duration clockSkewAllowance;

  /// The one renewal in flight, so that N callers arriving inside the renewal
  /// window cost one call rather than N.
  ///
  /// It is no longer a safety property. Against this server a renewal writes
  /// nothing and moves no generation, so the race this guard was built for —
  /// two owners renewing at once, the loser presenting a token the winner had
  /// retired, and the session ending for both — cannot happen: two concurrent
  /// renewals simply produce two working tokens (ADR-0023). What remains is
  /// the saving, and the coordinator's own reentrancy below. Whether a
  /// coordinator is still the right shape for that is a later phase's
  /// decision, not this one's.
  Future<Result<AccessToken>>? _renewalInFlight;

  /// The token an in-flight renewal is presenting, and null when none is.
  ///
  /// The renewal is itself an authenticated request: the reviewed client asks
  /// this coordinator for the token to put in its `Authorization` header, and
  /// that question arrives *while* the renewal it belongs to is the flight in
  /// progress. Answering it with [_renewalInFlight] would deadlock — that
  /// future cannot complete until the request waiting on this answer is sent.
  /// The presented token is the terminating answer, and the honest one: a
  /// renewal happens before expiry, so the token in hand is live, and a
  /// concurrent caller handed it holds a token that works.
  AccessToken? _presentedToken;

  int _sessionGeneration = 0;

  @override
  Future<Result<AccessToken>> accessToken({bool forceRefresh = false}) async {
    final presented = _presentedToken;
    if (presented != null && !forceRefresh) {
      return Result.success(presented);
    }
    final tokens = await store.read();
    if (tokens == null) {
      return const Result.failure(
        AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
      );
    }
    final renewAt = tokens.accessToken.expiresAt.subtract(
      proactiveRenewalWindow + clockSkewAllowance,
    );
    if (!forceRefresh && timeSource.now().toUtc().isBefore(renewAt)) {
      return Result.success(tokens.accessToken);
    }
    if (tokens.accessToken.scope != SessionScope.full) {
      // A register token names no device, so there is no session to renew and
      // `POST /auth/renew` answers `403 scope_forbidden`. Its ten minutes are
      // the whole of its life: it is spent on `POST /me/devices`, which
      // answers the session token that replaces it.
      if (timeSource.now().toUtc().isBefore(
        tokens.accessToken.expiresAt.subtract(clockSkewAllowance),
      )) {
        return Result.success(tokens.accessToken);
      }
      await _terminate(SessionTerminationReason.expired);
      return const Result.failure(
        AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
      );
    }
    return _singleFlightRenewal(tokens.accessToken);
  }

  @override
  Future<Result<AccessToken>> recoverAfterUnauthorized(
    String rejectedToken,
  ) async {
    final presented = _presentedToken;
    if (presented != null && presented.value == rejectedToken) {
      // The renewal itself was refused. There is nothing to recover with: the
      // only token this coordinator holds is the one the server just rejected,
      // and asking for another is the call that is already failing. The
      // failure travels back to [_performRenewal], which ends the session.
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
    // Set before the first suspension, because the request this call is about
    // to make asks for it on its way out. See [_presentedToken].
    _presentedToken = presented;
    try {
      final result = await renewExchange.renew();
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
          final reason =
              failure is BackendFailure &&
                  failure.code == BackendFailureCode.tokenRevoked
              ? SessionTerminationReason.revoked
              : SessionTerminationReason.expired;
          await _terminate(reason);
          return Result.failure(failure);
      }
    } finally {
      _presentedToken = null;
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
      code: BackendFailureCode.invalidToken ||
          BackendFailureCode.tokenNotValid ||
          BackendFailureCode.tokenRevoked,
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
