import 'dart:typed_data';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/devices/application/device_enrollment_coordinator.dart';
import 'package:communication_platform/features/devices/application/ports/device_enrollment_ports.dart';
import 'package:communication_platform/features/devices/domain/device_enrollment_model.dart';
import 'package:communication_platform/features/devices/presentation/device_enrollment_controller.dart';
import 'package:communication_platform/features/devices/presentation/device_enrollment_page.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sensitiveCalls = <MethodCall>[];

  setUp(() {
    sensitiveCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('communication_platform/protected_storage'),
          (call) async {
            sensitiveCalls.add(call);
            return null;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('communication_platform/protected_storage'),
          null,
        );
  });

  testWidgets(
    'first device shows the secret and requires explicit confirmation',
    (tester) async {
      final journal = _journal(
        phase: EnrollmentPhase.recoverySecret,
        flow: EnrollmentFlow.firstDevice,
        identity: IdentityKeyPackage.fromNative(_identityBytes(display: true)),
      );
      await _pump(tester, journal);

      expect(
        find.byKey(const ValueKey('recovery-secret-value')),
        findsOneWidget,
      );
      expect(find.textContaining('RECOVERY'), findsOneWidget);
      expect(
        sensitiveCalls,
        contains(
          isA<MethodCall>()
              .having((call) => call.method, 'method', 'setSensitiveScreen')
              .having(
                (call) => (call.arguments as Map<Object?, Object?>)['enabled'],
                'enabled',
                isTrue,
              ),
        ),
      );
      expect(
        tester
            .widget<AppButton>(
              find.byKey(const ValueKey('recovery-secret-continue')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('recovery-secret-saved')));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.ensureVisible(
        find.byKey(const ValueKey('recovery-secret-continue')),
      );
      await tester.tap(find.byKey(const ValueKey('recovery-secret-continue')));
      await tester.pump(const Duration(milliseconds: 150));

      expect(
        find.byKey(const ValueKey('recovery-confirmation-step')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('recovery-secret-value')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('recovery-back')));
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        find.byKey(const ValueKey('recovery-secret-value')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'later-device wrong secret clears the field and remains withheld',
    (tester) async {
      final journal = _journal(
        phase: EnrollmentPhase.awaitingRecoverySecret,
        flow: EnrollmentFlow.laterDevice,
        backup: Uint8List(4096),
      );
      await _pump(tester, journal);

      await tester.enterText(
        find.byKey(const ValueKey('recovery-secret-input')),
        'not the secret',
      );
      await tester.pump();
      expect(
        tester
            .widget<AppButton>(
              find.byKey(const ValueKey('restore-identity-submit')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('restore-identity-submit')));
      await tester.pumpAndSettle();

      final editable = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('recovery-secret-input')),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.controller.text, isEmpty);
      expect(
        find.textContaining('could not unlock this identity backup'),
        findsOneWidget,
      );
      final state = tester.container().read(deviceEnrollmentControllerProvider);
      expect(state.isMessagingWithheld, isTrue);
    },
  );

  testWidgets('mandatory notice states the recovery and history boundary', (
    tester,
  ) async {
    await _pump(
      tester,
      _journal(
        phase: EnrollmentPhase.securityNotice,
        flow: EnrollmentFlow.laterDevice,
        identity: IdentityKeyPackage.fromNative(_identityBytes(display: false)),
      ),
    );

    expect(
      find.byKey(const ValueKey('mandatory-security-notice')),
      findsOneWidget,
    );
    expect(find.text('Identity recovered'), findsOneWidget);
    expect(
      find.textContaining('No message history was restored'),
      findsOneWidget,
    );
    expect(find.text('What it DOES protect'), findsOneWidget);
    expect(find.text('What it does NOT protect'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('deployment-disclosure')),
      findsNothing,
      reason: 'the development flavor is never handed to anyone',
    );
  });

  testWidgets(
    'the private experimental gate discloses the build before it can be accepted',
    (tester) async {
      await _pump(
        tester,
        _journal(
          phase: EnrollmentPhase.securityNotice,
          flow: EnrollmentFlow.firstDevice,
          identity: IdentityKeyPackage.fromNative(
            _identityBytes(display: false),
          ),
        ),
        environment: AppEnvironment.beta,
      );

      // Every point ADR-045 requires is on the one screen the user has to
      // pass, and the acknowledgement is what passes it.
      expect(
        find.byKey(const ValueKey('deployment-disclosure')),
        findsOneWidget,
      );
      expect(find.text('What this build is'), findsOneWidget);
      for (final fragment in const [
        'Nobody outside the project has reviewed',
        'fifteen minutes apart at best',
        'stored only on this phone',
        'never restores messages',
        'experimental encryption that is not finished',
        'not built yet',
        'already trust each other',
      ]) {
        expect(
          find.textContaining(fragment),
          findsOneWidget,
          reason: 'the disclosure omits: \$fragment',
        );
      }
      expect(
        tester
            .widget<AppButton>(
              find.byKey(const ValueKey('accept-security-notice')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );
}

const userId = '6f0c2f5e-8a41-4c9e-9a34-1f3d8f2b7c10';

Future<void> _pump(
  WidgetTester tester,
  EnrollmentJournal journal, {
  AppEnvironment environment = AppEnvironment.development,
}) async {
  final store = _WidgetStore(journal);
  final coordinator = DeviceEnrollmentCoordinator(
    repository: const _UnusedRepository(),
    store: store,
    crypto: const _WrongSecretCrypto(),
    clock: const _FixedClock(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceEnrollmentCoordinatorProvider.overrideWithValue(coordinator),
        appEnvironmentProvider.overrideWithValue(environment),
        // The statement is rendered from the limits in force. This harness
        // opens no database, so it states what a first enrollment states:
        // this build's own constants, and therefore no retention number.
        publishedLimitsProvider.overrideWithValue(ServerConfig.fallback),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
        home: const DeviceEnrollmentPage(userId: userId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

EnrollmentJournal _journal({
  required EnrollmentPhase phase,
  required EnrollmentFlow flow,
  IdentityKeyPackage? identity,
  Uint8List? backup,
}) {
  final device = DeviceKeyPackage.fromNative(_deviceBytes());
  return EnrollmentJournal(
    userId: userId,
    flow: flow,
    phase: phase,
    fingerprint: device.public.fingerprint,
    devicePackage: device,
    deviceId: '9f1c6a2e-3b7d-4e0f-8c15-2a77d4b9e611',
    identityPackage: identity,
    backup: backup,
  );
}

final class _WidgetStore implements EnrollmentJournalStore {
  _WidgetStore(this.journal);

  EnrollmentJournal journal;

  @override
  Future<Result<EnrollmentJournal?>> read({required String userId}) async =>
      Result.success(journal);

  @override
  Future<Result<void>> update(EnrollmentJournal journal) async {
    this.journal = journal;
    return const Result.success(null);
  }

  @override
  Future<Result<void>> persistPrepared(EnrollmentJournal journal) =>
      update(journal);

  @override
  Future<Result<void>> persistRegistrationResult({
    required EnrollmentJournal journal,
    required DeviceRegistrationResponse response,
  }) => update(journal);

  @override
  Future<Result<void>> clear({required String userId}) async =>
      const Result.success(null);

  @override
  Future<Result<void>> markNewAccount({required String userId}) async =>
      const Result.success(null);

  @override
  Future<Result<bool>> isNewAccount({required String userId}) async =>
      Result.success(journal.flow == EnrollmentFlow.firstDevice);

  @override
  Future<Result<String?>> currentFullSessionDeviceId() async =>
      Result.success(journal.deviceId);

  @override
  Future<Result<IdentityKeyPackage?>> readCompletedIdentity() async =>
      Result.success(journal.identityPackage);
}

final class _WrongSecretCrypto implements EnrollmentCryptoPort {
  const _WrongSecretCrypto();

  @override
  Future<Result<IdentityKeyPackage>> restoreIdentity({
    required Uint8List userId,
    required Uint8List recoverySecret,
    required Uint8List backup,
  }) async => const Result.failure(
    CryptoCoreFailure(CryptoCoreFailureCode.authenticationFailed),
  );

  @override
  Future<Result<DeviceKeyPackage>> prepareDevice({required Uint8List userId}) =>
      throw UnimplementedError();

  @override
  Future<Result<IdentityKeyPackage>> rotateRecoverySecret({
    required IdentityKeyPackage package,
  }) => throw UnimplementedError();

  @override
  Future<Result<IdentityKeyPackage>> prepareFirstIdentity({
    required Uint8List userId,
  }) => throw UnimplementedError();

  @override
  Future<Result<IdentityKeyPackage>> sanitizeIdentity({
    required IdentityKeyPackage package,
  }) => throw UnimplementedError();

  @override
  Future<Result<Uint8List>> crossSignDevice({
    required DeviceKeyPackage device,
    required IdentityKeyPackage identity,
    required Uint8List deviceId,
    required int bundleVersion,
  }) => throw UnimplementedError();

  @override
  Future<Result<Uint8List>> createDeviceLogRecord({
    required IdentityKeyPackage identity,
    required Uint8List userId,
    required int sequence,
    required Uint8List previousHash,
    required Uint8List canonicalLiveSet,
    required int identityVersion,
    required int coarseUnixDay,
  }) => throw UnimplementedError();

  @override
  Future<Result<DeviceLogInspection>> inspectDeviceLogRecord({
    required IdentityKeyPackage identity,
    required Uint8List userId,
    required Uint8List record,
  }) => throw UnimplementedError();
}

final class _FixedClock implements TimeSource {
  const _FixedClock();

  @override
  DateTime now() => DateTime.utc(2026);
}

final class _UnusedRepository implements DeviceEnrollmentRepository {
  const _UnusedRepository();

  Never _unused() => throw UnimplementedError();

  @override
  Future<Result<DeviceRegistrationResponse>> registerDevice({
    required String userId,
    required DeviceRegistrationPublic public,
  }) => _unused();

  @override
  Future<Result<void>> publishIdentity({required PublishedIdentity identity}) =>
      _unused();

  @override
  Future<Result<PublishedIdentity>> fetchIdentity({required String userId}) =>
      _unused();

  @override
  Future<Result<void>> finishPrekeys({
    required String deviceId,
    required Uint8List crossSignature,
    required int bundleVersion,
  }) => _unused();

  @override
  Future<Result<KeyBackup>> fetchBackup() => _unused();

  @override
  Future<Result<void>> uploadBackup({
    required Uint8List blob,
    required int version,
  }) => _unused();

  @override
  Future<Result<PublicDeviceList>> fetchPublicDevices({
    required String userId,
  }) => _unused();

  @override
  Future<Result<DeviceLogPage>> fetchDeviceLog({
    required String userId,
    int? after,
  }) => _unused();

  @override
  Future<Result<DeviceLogAppendResult>> appendDeviceLog({
    required Uint8List record,
  }) => _unused();

  @override
  Future<Result<void>> revokeDevice({required String deviceId}) => _unused();
}

Uint8List _deviceBytes() {
  final bytes = BytesBuilder()
    ..add('CPDVV001'.codeUnits)
    ..add(_uuidBytes(userId));
  _u32(bytes, 1);
  _u32(bytes, 1);
  _u32(bytes, 1);
  _u16(bytes, 1);
  _u16(bytes, 1);
  bytes
    ..add(Uint8List.fromList(List<int>.filled(64, 1)))
    ..add(Uint8List.fromList(List<int>.filled(32, 2)))
    ..add(Uint8List.fromList(List<int>.filled(64, 3)))
    ..add(Uint8List.fromList(List<int>.filled(1184, 4)))
    ..add(Uint8List.fromList(List<int>.filled(64, 5)))
    ..add(Uint8List.fromList(List<int>.filled(32, 6)));
  _u32(bytes, 1);
  bytes.add(Uint8List.fromList(List<int>.filled(32, 7)));
  _u32(bytes, 1);
  bytes
    ..add(Uint8List.fromList(List<int>.filled(1184, 8)))
    ..addByte(9);
  return bytes.takeBytes();
}

Uint8List _identityBytes({required bool display}) {
  final recovery = display
      ? Uint8List.fromList('RECOVERY-SECRET'.codeUnits)
      : Uint8List(0);
  final backup = display ? Uint8List(4096) : Uint8List(0);
  final bytes = BytesBuilder()
    ..add('CPIDV001'.codeUnits)
    ..addByte(display ? 3 : 0)
    ..add(_uuidBytes(userId))
    ..add(Uint8List.fromList(List<int>.filled(32, 11)))
    ..add(Uint8List.fromList(List<int>.filled(32, 12)))
    ..add(Uint8List.fromList(List<int>.filled(32, 13)))
    ..add(Uint8List.fromList(List<int>.filled(64, 14)));
  _u16(bytes, recovery.length);
  _u32(bytes, backup.length);
  bytes
    ..add(Uint8List(96))
    ..add(recovery)
    ..add(backup);
  return bytes.takeBytes();
}

Uint8List _uuidBytes(String value) {
  final compact = value.replaceAll('-', '');
  return Uint8List.fromList([
    for (var index = 0; index < compact.length; index += 2)
      int.parse(compact.substring(index, index + 2), radix: 16),
  ]);
}

void _u16(BytesBuilder bytes, int value) {
  bytes.add((ByteData(2)..setUint16(0, value)).buffer.asUint8List());
}

void _u32(BytesBuilder bytes, int value) {
  bytes.add((ByteData(4)..setUint32(0, value)).buffer.asUint8List());
}
