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

  group('account erasure', () {
    test('a 204 clears the local store the way a logout does', () async {
      final repository = RecordingAuthenticationRepository();
      final session = RecordingAuthenticationSession();

      final result = await EraseAccount(repository, session)(
        password: 'correct horse battery staple',
      );

      expect(result, isA<Success<AccountErasureOutcome>>());
      expect(
        (result as Success<AccountErasureOutcome>).value,
        isA<AccountErased>(),
      );
      expect(repository.eraseCalls, 1);
      expect(session.forgetCalls, 1);
      // The token this call presented is already dead, so the client must not
      // present it again to `POST /auth/logout`.
      expect(session.logoutCalls, 0);
    });

    test('a wrong password leaves the session and counts the try', () async {
      final repository = RecordingAuthenticationRepository(
        eraseResults: const [
          Result<void>.failure(
            BackendFailure(BackendFailureCode.invalidCredentials),
          ),
        ],
      );
      final session = RecordingAuthenticationSession();
      final useCase = EraseAccount(repository, session);

      final first = await useCase(password: 'wrong password one');
      final second = await useCase(password: 'wrong password two');

      final rejected = (second as Success<AccountErasureOutcome>).value;
      expect(
        (first as Success<AccountErasureOutcome>).value,
        isA<AccountErasurePasswordRejected>().having(
          (outcome) => outcome.attemptsUsed,
          'attemptsUsed',
          1,
        ),
      );
      expect(
        rejected,
        isA<AccountErasurePasswordRejected>()
            .having((outcome) => outcome.attemptsUsed, 'attemptsUsed', 2)
            .having(
              (outcome) => outcome.attemptsAllowed,
              'attemptsAllowed',
              EraseAccount.attemptAllowance,
            )
            .having(
              (outcome) => outcome.attemptsRemaining,
              'attemptsRemaining',
              EraseAccount.attemptAllowance - 2,
            ),
      );
      expect(session.forgetCalls, 0);
    });

    test('a retry answered token_revoked is the erasure that landed', () async {
      final repository = RecordingAuthenticationRepository(
        eraseResults: const [
          Result<void>.failure(BackendFailure(BackendFailureCode.tokenRevoked)),
        ],
      );
      final session = RecordingAuthenticationSession();

      final result = await EraseAccount(repository, session)(
        password: 'correct horse battery staple',
      );

      expect(
        (result as Success<AccountErasureOutcome>).value,
        isA<AccountErased>(),
      );
      expect(session.forgetCalls, 1);
    });

    test('a cool-off reports the wait and resets the tally', () async {
      final repository = RecordingAuthenticationRepository(
        eraseResults: const [
          Result<void>.failure(
            BackendFailure(BackendFailureCode.invalidCredentials),
          ),
          Result<void>.failure(
            BackendFailure(
              BackendFailureCode.rateLimited,
              retryAfter: Duration(minutes: 15),
            ),
          ),
          Result<void>.failure(
            BackendFailure(BackendFailureCode.invalidCredentials),
          ),
        ],
      );
      final session = RecordingAuthenticationSession();
      final useCase = EraseAccount(repository, session);

      await useCase(password: 'wrong password one');
      final locked = await useCase(password: 'wrong password two');
      final afterWait = await useCase(password: 'wrong password three');

      expect(
        (locked as Success<AccountErasureOutcome>).value,
        isA<AccountErasureLocked>().having(
          (outcome) => outcome.retryAfter,
          'retryAfter',
          const Duration(minutes: 15),
        ),
      );
      expect(
        (afterWait as Success<AccountErasureOutcome>).value,
        isA<AccountErasurePasswordRejected>().having(
          (outcome) => outcome.attemptsUsed,
          'attemptsUsed',
          1,
        ),
      );
      expect(session.forgetCalls, 0);
    });

    test('an empty password never reaches the route', () async {
      final repository = RecordingAuthenticationRepository();
      final session = RecordingAuthenticationSession();

      final result = await EraseAccount(repository, session)(password: '');

      expect(
        (result as FailureResult<AccountErasureOutcome>).failure,
        isA<ValidationFailure>(),
      );
      expect(repository.eraseCalls, 0);
      expect(session.forgetCalls, 0);
    });

    test(
      'a password shorter than the register policy still reaches the route',
      () async {
        // The ten-character rule is what this client applies when a password
        // is created. An older account must still be able to leave.
        final repository = RecordingAuthenticationRepository();
        final session = RecordingAuthenticationSession();

        final result = await EraseAccount(repository, session)(
          password: 'short',
        );

        expect(
          (result as Success<AccountErasureOutcome>).value,
          isA<AccountErased>(),
        );
        expect(repository.eraseCalls, 1);
      },
    );

    test('an answer outside the four stays a failure', () async {
      final repository = RecordingAuthenticationRepository(
        eraseResults: const [
          Result<void>.failure(TransportFailure(TransportFailureKind.offline)),
        ],
      );
      final session = RecordingAuthenticationSession();

      final result = await EraseAccount(repository, session)(
        password: 'correct horse battery staple',
      );

      expect(
        (result as FailureResult<AccountErasureOutcome>).failure,
        isA<TransportFailure>(),
      );
      expect(session.forgetCalls, 0);
    });
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
  RecordingAuthenticationRepository({
    Result<AccountSessionGrant>? loginResult,
    this.eraseResults = const [Result<void>.success(null)],
  }) : loginResult =
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

  /// One answer per erase call, in order; the last one repeats.
  final List<Result<void>> eraseResults;
  int registerCalls = 0;
  int loginCalls = 0;
  int eraseCalls = 0;
  String? lastUsername;
  String? lastDeviceId;

  @override
  Future<Result<void>> eraseAccount({required String password}) async {
    final answer = eraseResults[eraseCalls.clamp(0, eraseResults.length - 1)];
    eraseCalls += 1;
    return answer;
  }

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
  Future<void> logout() async {
    logoutCalls += 1;
  }

  @override
  Future<void> forgetErasedAccount() async {
    forgetCalls += 1;
  }

  int logoutCalls = 0;
  int forgetCalls = 0;
}
