import 'package:communication_platform/core/application/use_case.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';

final class AuthenticationUseCases {
  const AuthenticationUseCases({
    required this.register,
    required this.login,
    required this.restore,
    required this.logout,
    required this.erase,
    required this.lifecycle,
  });

  final RegisterAccount register;
  final LoginAccount login;
  final RestoreAccountSession restore;
  final LogoutAccount logout;
  final EraseAccount erase;
  final AuthenticationLifecyclePort lifecycle;
}

final class RegisterAccountInput {
  const RegisterAccountInput({required this.username, required this.password});

  final String username;
  final String password;
}

final class LoginAccountInput {
  const LoginAccountInput({required this.username, required this.password});

  final String username;
  final String password;
}

final class EraseAccountInput {
  const EraseAccountInput({required this.password});

  final String password;
}

final class RegisterAccount
    implements UseCase<AccountRegistration, RegisterAccountInput> {
  const RegisterAccount(this.repository, {this.enrollmentMarker});

  final AccountAuthenticationRepository repository;
  final NewAccountEnrollmentMarkerPort? enrollmentMarker;

  Future<Result<AccountRegistration>> call({
    required String username,
    required String password,
  }) => execute(RegisterAccountInput(username: username, password: password));

  @override
  Future<Result<AccountRegistration>> execute(
    RegisterAccountInput input,
  ) async {
    final username = input.username;
    final password = input.password;
    final normalized = AuthenticationInputPolicy.normalizeUsername(username);
    if (!AuthenticationInputPolicy.isUsernameValid(normalized) ||
        !AuthenticationInputPolicy.isPasswordValid(password)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final result = await repository.register(
      username: normalized,
      password: password,
    );
    if (result case Success(value: final registration)) {
      final marker = enrollmentMarker;
      if (marker != null) {
        final marked = await marker.markNewAccount(userId: registration.userId);
        if (marked case FailureResult(failure: final failure)) {
          return Result.failure(failure);
        }
      }
    }
    return result;
  }
}

final class LoginAccount
    implements UseCase<AccountSessionBoundary, LoginAccountInput> {
  const LoginAccount(this.repository, this.session);

  final AccountAuthenticationRepository repository;
  final AuthenticationSessionPort session;

  Future<Result<AccountSessionBoundary>> call({
    required String username,
    required String password,
  }) => execute(LoginAccountInput(username: username, password: password));

  @override
  Future<Result<AccountSessionBoundary>> execute(
    LoginAccountInput input,
  ) async {
    final username = input.username;
    final password = input.password;
    final normalized = AuthenticationInputPolicy.normalizeUsername(username);
    if (!AuthenticationInputPolicy.isUsernameValid(normalized) ||
        !AuthenticationInputPolicy.isPasswordValid(password)) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }

    final hint = await session.readLoginHint();
    final deviceId = hint.appliesTo(normalized) ? hint.deviceId : null;
    final result = await repository.login(
      username: normalized,
      password: password,
      deviceId: deviceId,
    );
    switch (result) {
      case FailureResult(failure: final failure):
        return Result.failure(failure);
      case Success(value: final grant):
        return session.acceptLogin(
          username: normalized,
          grant: grant,
          replacedKnownDevice:
              deviceId != null && grant.scope == AccountSessionScope.register,
        );
    }
  }
}

final class RestoreAccountSession
    implements UseCase<AccountSessionBoundary, NoInput> {
  const RestoreAccountSession(this.session);

  final AuthenticationSessionPort session;

  Future<Result<AccountSessionBoundary>> call() => session.restore();

  @override
  Future<Result<AccountSessionBoundary>> execute(NoInput input) => call();
}

/// Erases the account this session belongs to, and takes the session with it.
///
/// The four answers the route documents are mapped here rather than in the
/// screen, so the screen never reads a `code` and never reads a `detail`. Two
/// of them are the same outcome: a `204` and the `401 token_revoked` that a
/// retry of a lost answer gets both mean the account is gone.
final class EraseAccount
    implements UseCase<AccountErasureOutcome, EraseAccountInput> {
  EraseAccount(this.repository, this.session);

  /// The wrong passwords that lock the username for fifteen minutes, on this
  /// route and on `POST /api/v1/auth/login` alike. The server counts; this is
  /// carried out so wording can warn before the last try, and gates nothing.
  static const int attemptAllowance = 5;

  final AccountAuthenticationRepository repository;
  final AuthenticationSessionPort session;

  /// Wrong passwords sent since the server last showed the counting window
  /// closed. A count, never the password: nothing here retains what was typed.
  int _wrongPasswords = 0;

  Future<Result<AccountErasureOutcome>> call({required String password}) =>
      execute(EraseAccountInput(password: password));

  @override
  Future<Result<AccountErasureOutcome>> execute(EraseAccountInput input) async {
    final password = input.password;
    if (password.isEmpty ||
        password.length > AuthenticationInputPolicy.maximumPasswordLength) {
      // Deliberately not `AuthenticationInputPolicy.isPasswordValid`. That is
      // the rule this client applies when a password is *created*, and an
      // account whose password predates it must still be able to leave.
      // Refused here is only what the route cannot accept — and refusing it
      // locally spends none of the five tries the username has.
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }

    final result = await repository.eraseAccount(password: password);
    switch (result) {
      case Success():
      case FailureResult(
        failure: BackendFailure(code: BackendFailureCode.tokenRevoked),
      ):
        return _erased();
      case FailureResult(
        failure: BackendFailure(code: BackendFailureCode.invalidCredentials),
      ):
        _wrongPasswords += 1;
        return Result.success(
          AccountErasurePasswordRejected(
            attemptsUsed: _wrongPasswords,
            attemptsAllowed: attemptAllowance,
          ),
        );
      case FailureResult(
        failure: BackendFailure(
          code: BackendFailureCode.throttled,
          retryAfter: final retryAfter,
        ),
      ):
        // The window this client was counting against is over: either the
        // lock has just consumed the whole allowance, or the limit that
        // refused was the account's ordinary one and the tally was never
        // about it. Either way the next window starts fresh.
        _wrongPasswords = 0;
        return Result.success(AccountErasureLocked(retryAfter: retryAfter));
      case FailureResult(failure: final failure):
        return Result.failure(failure);
    }
  }

  Future<Result<AccountErasureOutcome>> _erased() async {
    _wrongPasswords = 0;
    await session.forgetErasedAccount();
    return const Result.success(AccountErased());
  }
}

final class LogoutAccount implements UseCase<void, NoInput> {
  const LogoutAccount(this.session);

  final AuthenticationSessionPort session;

  Future<void> call() => session.logout();

  @override
  Future<Result<void>> execute(NoInput input) async {
    await call();
    return const Result.success(null);
  }
}
