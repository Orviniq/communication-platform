import 'dart:async';

import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/authentication_use_cases.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';

/// One authenticated session, faked, for every screen test that needs the
/// application to be signed in without a server behind it.
///
/// Shared rather than repeated: the settings surfaces and the authentication
/// screens both need a composed `AuthenticationUseCases`, and two harnesses
/// would be two descriptions of the same contract that could drift apart.
final class AuthenticationHarness {
  AuthenticationHarness({
    Result<AccountSessionGrant>? loginResult,
    Result<AccountRegistration>? registrationResult,
  }) : repository = WidgetAuthenticationRepository(
         loginResult:
             loginResult ??
             Result.success(
               AccountSessionGrant(
                 accessToken: 'register-access',
                 accessExpiresAt: DateTime.utc(2026, 7, 28, 12),
                 userId: userId,
                 scope: AccountSessionScope.register,
               ),
             ),
         registrationResult:
             registrationResult ??
             const Result.success(AccountRegistration(userId: userId)),
       ),
       session = WidgetAuthenticationSession(),
       lifecycle = WidgetLifecycle() {
    useCases = AuthenticationUseCases(
      register: RegisterAccount(repository),
      login: LoginAccount(repository, session),
      restore: RestoreAccountSession(session),
      logout: LogoutAccount(session),
      erase: EraseAccount(repository, session),
      lifecycle: lifecycle,
    );
  }

  final WidgetAuthenticationRepository repository;
  final WidgetAuthenticationSession session;
  final WidgetLifecycle lifecycle;
  late final AuthenticationUseCases useCases;

  Future<void> close() => lifecycle.close();
}

const userId = '6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10';

final class WidgetAuthenticationRepository
    implements AccountAuthenticationRepository {
  WidgetAuthenticationRepository({
    required this.loginResult,
    required this.registrationResult,
  });

  final Result<AccountSessionGrant> loginResult;
  final Result<AccountRegistration> registrationResult;
  int loginCalls = 0;
  int registerCalls = 0;
  int eraseCalls = 0;
  String? lastUsername;

  @override
  Future<Result<void>> eraseAccount({required String password}) async {
    eraseCalls += 1;
    return const Result.success(null);
  }

  @override
  Future<Result<AccountSessionGrant>> login({
    required String username,
    required String password,
    String? deviceId,
  }) async {
    loginCalls += 1;
    lastUsername = username;
    return loginResult;
  }

  @override
  Future<Result<AccountRegistration>> register({
    required String username,
    required String password,
  }) async {
    registerCalls += 1;
    lastUsername = username;
    return registrationResult;
  }
}

final class WidgetAuthenticationSession implements AuthenticationSessionPort {
  @override
  Future<Result<AccountSessionBoundary>> acceptLogin({
    required String username,
    required AccountSessionGrant grant,
    required bool replacedKnownDevice,
  }) async => Result.success(
    AccountSessionBoundary(
      userId: grant.userId,
      deviceId: grant.deviceId,
      scope: grant.scope,
      offline: false,
    ),
  );

  @override
  Future<LoginHint> readLoginHint() async => const LoginHint();

  @override
  Future<Result<AccountSessionBoundary>> restore() async =>
      const Result.failure(
        AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
      );

  @override
  Future<void> logout() async {}

  @override
  Future<void> forgetErasedAccount() async {
    forgotErasedAccount = true;
  }

  bool forgotErasedAccount = false;
}

final class WidgetLifecycle implements AuthenticationLifecyclePort {
  final StreamController<AuthenticationTermination> _controller =
      StreamController<AuthenticationTermination>.broadcast();

  @override
  Stream<AuthenticationTermination> get terminations => _controller.stream;

  Future<void> close() => _controller.close();
}
