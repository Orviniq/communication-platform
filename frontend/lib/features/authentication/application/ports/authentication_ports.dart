import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';

abstract interface class AccountAuthenticationRepository implements Port {
  Future<Result<AccountRegistration>> register({
    required String username,
    required String password,
  });

  Future<Result<AccountSessionGrant>> login({
    required String username,
    required String password,
    String? deviceId,
  });

  /// `DELETE /api/v1/me`, the one irreversible route this API has.
  ///
  /// The password is an argument because a session token lives thirty days and
  /// nothing detects its theft, so the irreversible act asks for the secret a
  /// stolen token does not carry. It reaches the request body and is retained
  /// nowhere: not stored, not cached, not logged.
  Future<Result<void>> eraseAccount({required String password});
}

abstract interface class AuthenticationSessionPort implements Port {
  Future<LoginHint> readLoginHint();

  Future<Result<AccountSessionBoundary>> acceptLogin({
    required String username,
    required AccountSessionGrant grant,
    required bool replacedKnownDevice,
  });

  Future<Result<AccountSessionBoundary>> restore();

  Future<void> logout();

  /// Ends the session the way [logout] ends it — the same wipe, the same
  /// termination, the same landing on the sign-in screen — without the
  /// `POST /api/v1/auth/logout` that [logout] sends first.
  ///
  /// For the one case where the token is known to be dead before the call is
  /// made: the account it named has just been erased. Presenting it would
  /// answer `401 token_revoked`, and the transport treats that as a remote
  /// revocation — telling the user their session was revoked, which is not
  /// what happened.
  Future<void> forgetErasedAccount();
}

enum AuthenticationTermination { logout, revoked, expired }

abstract interface class AuthenticationLifecyclePort implements Port {
  Stream<AuthenticationTermination> get terminations;
}

abstract interface class NewAccountEnrollmentMarkerPort implements Port {
  Future<Result<void>> markNewAccount({required String userId});
}
