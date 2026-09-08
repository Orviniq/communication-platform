import 'dart:async';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/infrastructure/secure_session_token_adapter.dart';
import 'package:communication_platform/features/local_storage/infrastructure/local_storage_runtime.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';

final class AuthenticationLifecycleBus implements AuthenticationLifecyclePort {
  final StreamController<AuthenticationTermination> _controller =
      StreamController<AuthenticationTermination>.broadcast(sync: true);

  @override
  Stream<AuthenticationTermination> get terminations => _controller.stream;

  void emit(AuthenticationTermination termination) {
    if (!_controller.isClosed) {
      _controller.add(termination);
    }
  }

  Future<void> close() => _controller.close();
}

final class LocalAuthenticationTerminationHandler
    implements SessionTerminationHandler {
  const LocalAuthenticationTerminationHandler({
    required this.runtime,
    required this.lifecycle,
  });

  final SecureLocalStorageRuntime runtime;
  final AuthenticationLifecycleBus lifecycle;

  @override
  Future<void> terminate(SessionTerminationReason reason) async {
    switch (reason) {
      case SessionTerminationReason.logout:
        await runtime.wipeForLogout();
        lifecycle.emit(AuthenticationTermination.logout);
      case SessionTerminationReason.revoked:
        await runtime.wipeForRemoteRevocation();
        lifecycle.emit(AuthenticationTermination.revoked);
      case SessionTerminationReason.expired:
        lifecycle.emit(AuthenticationTermination.expired);
    }
  }
}

final class CoordinatedAuthenticationSession
    implements AuthenticationSessionPort {
  const CoordinatedAuthenticationSession({
    required this.tokens,
    required this.coordinator,
    required this.runtime,
  });

  final SecureSessionTokenAdapter tokens;
  final AccessTokenCoordinator coordinator;
  final SecureLocalStorageRuntime runtime;

  @override
  Future<LoginHint> readLoginHint() => tokens.readLoginHint();

  @override
  Future<Result<AccountSessionBoundary>> acceptLogin({
    required String username,
    required AccountSessionGrant grant,
    required bool replacedKnownDevice,
  }) async {
    try {
      if (replacedKnownDevice) {
        await tokens.clear();
        await runtime.wipeForSelfRevocation();
        tokens.clearMemory();
      }
      final sessionTokens = SessionTokens(
        accessToken: AccessToken(
          value: grant.accessToken,
          expiresAt: grant.accessExpiresAt,
          scope: _networkScope(grant.scope),
        ),
        userId: grant.userId,
        deviceId: grant.deviceId,
        username: username,
      );
      await tokens.replace(sessionTokens);
      if (grant.scope == AccountSessionScope.register) {
        await tokens.writeLoginHint(LoginHint(username: username));
      }
      return Result.success(
        AccountSessionBoundary(
          userId: grant.userId,
          deviceId: grant.deviceId,
          scope: grant.scope,
          offline: false,
          securitySetupComplete:
              grant.scope == AccountSessionScope.full &&
              await tokens.hasCompletedSecureSetup(),
        ),
      );
    } on Object {
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  @override
  Future<Result<AccountSessionBoundary>> restore() async {
    try {
      return await _restore();
    } on Object {
      // The restore screen has no button and no timeout, so a throw escaping
      // this method does not surface as an error: the caller starts it with
      // `unawaited`, the controller stays in `restoring` forever, and the
      // router holds the spinner over an application that is otherwise
      // reachable. Reporting the failure sends the user to sign-in, which they
      // can act on. `acceptLogin` above already fails closed the same way.
      return const Result.failure(
        StorageFailure(StorageFailureKind.unavailable),
      );
    }
  }

  Future<Result<AccountSessionBoundary>> _restore() async {
    final before = await tokens.read();
    if (before == null ||
        before.accessToken.scope != SessionScope.full ||
        before.userId == null ||
        before.deviceId == null) {
      return const Result.failure(
        AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
      );
    }
    final result = await coordinator.accessToken();
    switch (result) {
      case Success():
        final current = await tokens.read();
        if (current?.userId == null || current?.deviceId == null) {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.malformedServerResponse),
          );
        }
        return Result.success(
          AccountSessionBoundary(
            userId: current!.userId!,
            deviceId: current.deviceId,
            scope: AccountSessionScope.full,
            offline: false,
            securitySetupComplete: await tokens.hasCompletedSecureSetup(),
          ),
        );
      case FailureResult(failure: final failure):
        if (failure is TransportFailure && await tokens.hasUsableIdentity()) {
          return Result.success(
            AccountSessionBoundary(
              userId: before.userId!,
              deviceId: before.deviceId,
              scope: AccountSessionScope.full,
              offline: true,
              securitySetupComplete: await tokens.hasCompletedSecureSetup(),
            ),
          );
        }
        return Result.failure(failure);
    }
  }

  @override
  Future<void> logout() => coordinator.logout();

  @override
  Future<void> forgetErasedAccount() async {
    // Dropping the token first is what makes the logout below local. The
    // coordinator sends `POST /auth/logout` only when the store still holds a
    // token to revoke, so clearing it leaves exactly the rest of a logout: the
    // session generation advances, the wipe runs, and the termination that
    // lands the user on sign-in is emitted with `logout` rather than
    // `revoked`. The token is already dead — the account it named is gone.
    await tokens.clear();
    tokens.clearMemory();
    await coordinator.logout();
  }

  SessionScope _networkScope(AccountSessionScope scope) => switch (scope) {
    AccountSessionScope.register => SessionScope.register,
    AccountSessionScope.full => SessionScope.full,
  };
}
