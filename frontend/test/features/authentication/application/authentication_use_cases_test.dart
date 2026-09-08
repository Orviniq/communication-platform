import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/authentication_use_cases.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('account authentication use cases', () {
    test(
      'registration normalizes locally without probing username existence',
      () async {
        final repository = RecordingAuthenticationRepository();
        final useCase = RegisterAccount(repository);

        final result = await useCase(
          username: '  ALIce_7 ',
          password: 'correct horse battery staple',
        );

        expect(result, isA<Success<AccountRegistration>>());
        expect(repository.registerCalls, 1);
        expect(repository.lastUsername, 'alice_7');
        expect(repository.loginCalls, 0);
      },
    );

    test(
      'invalid local input returns feedback without contacting backend',
      () async {
        final repository = RecordingAuthenticationRepository();
        final useCase = RegisterAccount(repository);

        final result = await useCase(username: 'a!', password: 'short');

        expect(
          (result as FailureResult<AccountRegistration>).failure,
          isA<ValidationFailure>(),
        );
        expect(repository.registerCalls, 0);
        expect(repository.loginCalls, 0);
      },
    );

    test(
      'login supplies a remembered device only for the same username',
      () async {
        final repository = RecordingAuthenticationRepository(
          loginResult: Result.success(fullGrant),
        );
        final session = RecordingAuthenticationSession(
          hint: const LoginHint(username: 'alice', deviceId: deviceId),
        );
        final useCase = LoginAccount(repository, session);

        final result = await useCase(
          username: 'ALICE',
          password: 'correct horse battery staple',
        );

        expect(result, isA<Success<AccountSessionBoundary>>());
        expect(repository.lastDeviceId, deviceId);
        expect(session.acceptCalls, 1);
        expect(session.replacedKnownDevice, isFalse);

        await useCase(
          username: 'bob',
          password: 'correct horse battery staple',
        );
        expect(repository.lastDeviceId, isNull);
      },
    );

    test(
      'register-scope response marks a formerly known device for reset',
      () async {
        final repository = RecordingAuthenticationRepository(
          loginResult: Result.success(registerGrant),
        );
        final session = RecordingAuthenticationSession(
          hint: const LoginHint(username: 'alice', deviceId: deviceId),
        );

        await LoginAccount(repository, session)(
          username: 'alice',
          password: 'correct horse battery staple',
        );

        expect(session.replacedKnownDevice, isTrue);
      },
    );
  });
}

const userId = '6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10';
const deviceId = '9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611';

final fullGrant = AccountSessionGrant(
  accessToken: 'access',
  accessExpiresAt: DateTime.utc(2026, 7, 28, 12),
  userId: userId,
  deviceId: deviceId,
  scope: AccountSessionScope.full,
);

final registerGrant = AccountSessionGrant(
  accessToken: 'register-access',
  accessExpiresAt: DateTime.utc(2026, 7, 28, 12),
  userId: userId,
  scope: AccountSessionScope.register,
);

final class RecordingAuthenticationRepository
    implements AccountAuthenticationRepository {
  RecordingAuthenticationRepository({Result<AccountSessionGrant>? loginResult})
    : loginResult =
          loginResult ??
          Result.success(
            AccountSessionGrant(
              accessToken: 'register-access',
              accessExpiresAt: DateTime.utc(2026, 7, 28, 12),
              userId: userId,
              scope: AccountSessionScope.register,
            ),
          );

  final Result<AccountSessionGrant> loginResult;
  int registerCalls = 0;
  int loginCalls = 0;
  String? lastUsername;
  String? lastDeviceId;

  @override
  Future<Result<AccountSessionGrant>> login({
    required String username,
    required String password,
    String? deviceId,
  }) async {
    loginCalls += 1;
    lastUsername = username;
    lastDeviceId = deviceId;
    return loginResult;
  }

  @override
  Future<Result<AccountRegistration>> register({
    required String username,
    required String password,
  }) async {
    registerCalls += 1;
    lastUsername = username;
    return const Result.success(AccountRegistration(userId: userId));
  }
}

final class RecordingAuthenticationSession
    implements AuthenticationSessionPort {
  RecordingAuthenticationSession({this.hint = const LoginHint()});

  final LoginHint hint;
  int acceptCalls = 0;
  bool? replacedKnownDevice;

  @override
  Future<Result<AccountSessionBoundary>> acceptLogin({
    required String username,
    required AccountSessionGrant grant,
    required bool replacedKnownDevice,
  }) async {
    acceptCalls += 1;
    this.replacedKnownDevice = replacedKnownDevice;
    return Result.success(
      AccountSessionBoundary(
        userId: grant.userId,
        deviceId: grant.deviceId,
        scope: grant.scope,
        offline: false,
      ),
    );
  }

  @override
  Future<LoginHint> readLoginHint() async => hint;

  @override
  Future<Result<AccountSessionBoundary>> restore() async =>
      const Result.failure(
        AuthenticationFailure(AuthenticationFailureKind.sessionExpired),
      );

  @override
  Future<void> logout() async {}
}
