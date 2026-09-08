import 'dart:convert';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/infrastructure/coordinated_authentication_session.dart';
import 'package:communication_platform/features/authentication/infrastructure/secure_session_token_adapter.dart';
import 'package:communication_platform/features/local_storage/application/ports/local_storage_ports.dart';
import 'package:communication_platform/features/local_storage/domain/local_storage_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/local_storage/infrastructure/local_storage_runtime.dart';
import 'package:communication_platform/features/networking/application/ports/token_ports.dart';
import 'package:communication_platform/features/networking/domain/session_tokens.dart';
import 'package:communication_platform/features/networking/infrastructure/auth/token_coordinator.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('secure session token adapter', () {
    late TestStorageHarness harness;

    setUp(() {
      harness = TestStorageHarness();
    });

    tearDown(() async {
      await harness.runtime.close();
    });

    test('persists the session token and restores it ready to use', () async {
      final adapter = SecureSessionTokenAdapter(harness.runtime);
      await adapter.replace(fullTokens());
      final database =
          (await harness.runtime.open() as Success<LocalDatabase>).value;
      final row = await database.select(database.accountSessions).getSingle();
      final metadata = utf8.decode(row.tokenMetadataCiphertext);

      expect(metadata, contains('session-secret'));

      final restarted = SecureSessionTokenAdapter(harness.runtime);
      final restored = await restarted.read();
      // Not a placeholder: nothing rotates, so the restored token is the one
      // the next request presents rather than an expired stand-in whose only
      // job was to force a rotation first.
      expect(restored?.accessToken.value, 'session-secret');
      expect(restored?.accessToken.expiresAt, DateTime.utc(2026, 7, 28, 11));
      expect(restored?.accessToken.scope, SessionScope.full);
      expect(restored?.userId, userId);
      expect(restored?.deviceId, deviceId);
    });

    test(
      'a row written as a token pair is unreadable and is deleted',
      () async {
        final adapter = SecureSessionTokenAdapter(harness.runtime);
        await adapter.replace(fullTokens());
        final database =
            (await harness.runtime.open() as Success<LocalDatabase>).value;
        // What a build before ADR-0023 wrote: the refresh half of a pair, under
        // the same format version. It has no readable shape here, so the guard
        // deletes it and the account signs in once more.
        await database
            .update(database.accountSessions)
            .write(
              AccountSessionsCompanion(
                tokenMetadataCiphertext: Value(
                  Uint8List.fromList(
                    utf8.encode(
                      jsonEncode(<String, Object?>{
                        'version': 1,
                        'refresh': 'refresh-secret',
                      }),
                    ),
                  ),
                ),
              ),
            );

        final restarted = SecureSessionTokenAdapter(harness.runtime);
        expect(await restarted.read(), isNull);
        expect(
          await database.select(database.accountSessions).getSingleOrNull(),
          isNull,
        );
      },
    );

    test(
      'register-scope access is memory-only and has no durable session row',
      () async {
        final adapter = SecureSessionTokenAdapter(harness.runtime);
        await adapter.replace(
          SessionTokens(
            accessToken: AccessToken(
              value: 'register-secret',
              expiresAt: DateTime.utc(2026, 7, 28, 13),
              scope: SessionScope.register,
            ),
            userId: userId,
            username: 'alice',
          ),
        );
        final database =
            (await harness.runtime.open() as Success<LocalDatabase>).value;

        expect((await adapter.read())?.accessToken.value, 'register-secret');
        expect(
          await database.select(database.accountSessions).getSingleOrNull(),
          isNull,
        );
        expect(await SecureSessionTokenAdapter(harness.runtime).read(), isNull);
      },
    );

    test(
      'offline restore is allowed only with a usable local identity',
      () async {
        final adapter = SecureSessionTokenAdapter(harness.runtime);
        await adapter.replace(fullTokens());
        adapter.clearMemory();
        final database =
            (await harness.runtime.open() as Success<LocalDatabase>).value;
        await database
            .into(database.accountIdentities)
            .insert(
              AccountIdentitiesCompanion.insert(
                verifiedPublicStateCiphertext: Uint8List.fromList([1, 2, 3]),
                recoveryStatus: 0,
              ),
            );
        final lifecycle = AuthenticationLifecycleBus();
        final coordinator = TokenCoordinator(
          store: adapter,
          renewExchange: const FixedRenewExchange(
            Result.failure(TransportFailure(TransportFailureKind.offline)),
          ),
          terminationHandler: LocalAuthenticationTerminationHandler(
            runtime: harness.runtime,
            lifecycle: lifecycle,
          ),
          timeSource: const FixedTimeSource(),
        );
        final session = CoordinatedAuthenticationSession(
          tokens: adapter,
          coordinator: coordinator,
          runtime: harness.runtime,
        );

        final result = await session.restore();

        expect(
          (result as Success<AccountSessionBoundary>).value.offline,
          isTrue,
        );
        expect(result.value.securitySetupComplete, isFalse);
        expect(harness.cleanup.erased, isFalse);
        await lifecycle.close();
      },
    );

    test(
      'revoked refresh wipes local artifacts and emits revocation',
      () async {
        final adapter = SecureSessionTokenAdapter(harness.runtime);
        await adapter.replace(fullTokens());
        adapter.clearMemory();
        final lifecycle = AuthenticationLifecycleBus();
        final termination = expectLater(
          lifecycle.terminations,
          emits(AuthenticationTermination.revoked),
        );
        final coordinator = TokenCoordinator(
          store: adapter,
          renewExchange: const FixedRenewExchange(
            Result.failure(BackendFailure(BackendFailureCode.tokenRevoked)),
          ),
          terminationHandler: LocalAuthenticationTerminationHandler(
            runtime: harness.runtime,
            lifecycle: lifecycle,
          ),
          timeSource: const FixedTimeSource(),
        );
        final session = CoordinatedAuthenticationSession(
          tokens: adapter,
          coordinator: coordinator,
          runtime: harness.runtime,
        );

        final result = await session.restore();

        expect(result, isA<FailureResult<AccountSessionBoundary>>());
        await termination;
        expect(harness.protectedStorage.destroyed, isTrue);
        expect(harness.cleanup.erased, isTrue);
        await lifecycle.close();
      },
    );

    test(
      'another account’s enrollment row neither throws nor answers for this one',
      () async {
        final adapter = SecureSessionTokenAdapter(harness.runtime);
        await adapter.replace(fullTokens());
        final database =
            (await harness.runtime.open() as Success<LocalDatabase>).value;
        await database
            .into(database.accountIdentities)
            .insert(
              AccountIdentitiesCompanion.insert(
                singletonId: const Value(1),
                verifiedPublicStateCiphertext: Uint8List.fromList([1, 2, 3]),
                recoveryStatus: 4,
              ),
            );
        // Two rows: `enrollment_intent` is keyed by user id, so any install
        // where a second account ever reached enrollment holds more than one.
        // Reading it unscoped threw `Bad state: Too many elements` out of
        // `restore`, which the router rendered as a permanent restore spinner.
        await database
            .into(database.enrollmentIntents)
            .insert(enrollmentIntent(otherUserId));
        await database
            .into(database.enrollmentIntents)
            .insert(enrollmentIntent(thirdUserId));

        expect(await adapter.hasCompletedSecureSetup(), isTrue);

        await database
            .into(database.enrollmentIntents)
            .insert(enrollmentIntent(userId));

        expect(await adapter.hasCompletedSecureSetup(), isFalse);
      },
    );

    test('a throwing restore is reported, never left pending', () async {
      final adapter = SecureSessionTokenAdapter(harness.runtime);
      await adapter.replace(fullTokens());
      final session = CoordinatedAuthenticationSession(
        tokens: adapter,
        coordinator: const ThrowingAccessTokenCoordinator(),
        runtime: harness.runtime,
      );

      final result = await session.restore();

      // The call site starts this with `unawaited`, so a throw would surface
      // nowhere and strand the controller in `restoring` for good.
      expect(result, isA<FailureResult<AccountSessionBoundary>>());
      expect(
        (result as FailureResult<AccountSessionBoundary>).failure,
        isA<StorageFailure>(),
      );
    });
  });
}

const userId = '6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10';
const deviceId = '9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611';
const otherUserId = '1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d';
const thirdUserId = '2c3d4e5f-6071-4b8c-9dae-1f2a3b4c5d6e';

EnrollmentIntentsCompanion enrollmentIntent(String owner) =>
    EnrollmentIntentsCompanion.insert(
      userId: owner,
      flow: 0,
      phase: 0,
      fingerprint: Uint8List.fromList([4, 5, 6]),
      deviceState: Uint8List.fromList([7, 8, 9]),
    );

SessionTokens fullTokens() => SessionTokens(
  accessToken: AccessToken(
    value: 'session-secret',
    expiresAt: DateTime.utc(2026, 7, 28, 11),
    scope: SessionScope.full,
  ),
  userId: userId,
  deviceId: deviceId,
  username: 'alice',
);

final class TestStorageHarness {
  TestStorageHarness() {
    protectedStorage = FakeProtectedStorage();
    cleanup = FakeCleanup();
    runtime = SecureLocalStorageRuntime(
      protectedStorage: protectedStorage,
      cleanup: cleanup,
      executorFactory: (_) => NativeDatabase.memory(),
    );
  }

  late final FakeProtectedStorage protectedStorage;
  late final FakeCleanup cleanup;
  late final SecureLocalStorageRuntime runtime;
}

final class FakeProtectedStorage implements PlatformProtectedStoragePort {
  bool destroyed = false;

  @override
  Future<void> destroyWrappingKey() async {
    destroyed = true;
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<PlatformStorageUnlock> loadOrCreateStorageKey() async =>
      PlatformStorageUnlock(
        status: PlatformStorageKeyStatus.ready,
        protection: PlatformStorageProtection.software,
        databaseKey: Uint8List(32),
      );
}

final class FakeCleanup implements LocalArtifactCleanupPort {
  bool erased = false;

  @override
  Future<CleanupReport> cleanupBounded({required int maximumEntries}) async =>
      const CleanupReport(removedEntries: 0, hasMore: false);

  @override
  Future<void> clearVolatilePlaintext() async {}

  @override
  Future<void> erasePersistentArtifacts() async {
    erased = true;
  }
}

final class FixedRenewExchange implements RenewTokenExchange {
  const FixedRenewExchange(this.result);

  final Result<SessionTokens> result;

  @override
  Future<Result<SessionTokens>> renew() async => result;
}

final class FixedTimeSource implements TimeSource {
  const FixedTimeSource();

  @override
  DateTime now() => DateTime.utc(2026, 7, 28, 12);
}

final class ThrowingAccessTokenCoordinator implements AccessTokenCoordinator {
  const ThrowingAccessTokenCoordinator();

  @override
  Future<Result<AccessToken>> accessToken({bool forceRefresh = false}) async =>
      throw StateError('storage went away mid-restore');

  @override
  Future<Result<AccessToken>> recoverAfterUnauthorized(String rejectedToken) =>
      accessToken();

  @override
  Future<void> logout() async {}

  @override
  Future<void> handleRevocation() async {}
}
