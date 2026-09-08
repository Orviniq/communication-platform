import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/config/group_production_gate.dart';
import 'package:communication_platform/app/config/runtime_abi_native.dart';
import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/attachment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/crypto_core_port.dart';
import 'package:communication_platform/core/application/ports/device_control_crypto_port.dart';
import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/application/ports/pairwise_crypto_port.dart';
import 'package:communication_platform/core/application/ports/pairwise_session_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/infrastructure/diagnostics/network_diagnostics.dart';
import 'package:communication_platform/shared/infrastructure/crypto/crypto_core_runtime.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/pairwise_session_crypto.dart';
import 'package:communication_platform/shared/infrastructure/crypto/platform_crypto_core_native.dart';
import 'package:communication_platform/shared/infrastructure/crypto/unsupported_enrollment_crypto.dart';
import 'package:communication_platform/shared/infrastructure/time/system_time_source.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Dependency descriptors are immutable. Their instances are owned by ProviderScope,
/// which lets tests and app roots provide isolated overrides without global mutation.
final timeSourceProvider = Provider<TimeSource>(
  (ref) => const SystemTimeSource(),
);

final appEnvironmentProvider = Provider<AppEnvironment>(
  (ref) => AppEnvironment.development,
);

/// Which packaged native library this process actually loaded, or null when
/// the artifact packages none for this target.
///
/// One APK carries `arm64-v8a`, `armeabi-v7a` and `x86_64`, and the installer
/// chooses; this is how the application finds out which one it got. It is a
/// fact about the running artifact, not a setting — the answer is fixed by the
/// AOT snapshot the platform selected and there is nothing to select at
/// runtime.
///
/// It is a provider so the platform read stays behind one seam rather than
/// being called from a config class or a screen, and so a test can pin an ABI
/// it is not running on. ADR-056 uses it to decide whether the closed-beta group
/// surface has been measured on *this* processor.
final runtimeAbiProvider = Provider<GroupMlsFieldCell?>(
  (ref) => currentGroupMlsAbiCell(),
);

/// The one place request outcomes are counted, for the whole process.
///
/// It is a provider so that both entry points take the *same* recorder from
/// `ApplicationRuntime` — a second one beside it would describe half the
/// traffic and read as a working transport in a report written to explain a
/// broken one. The default instance exists so that a test scope and a screen
/// harness have somewhere to write; nothing durable is created either way.
final networkDiagnosticsProvider = Provider<RecordingNetworkDiagnostics>(
  (ref) => RecordingNetworkDiagnostics(),
);

typedef CryptoCoreFactory = CryptoCorePort Function();

final cryptoCoreFactoryProvider = Provider<CryptoCoreFactory>(
  (ref) =>
      () => createPlatformCryptoCore(),
);

final cryptoCoreProvider = Provider<CryptoCorePort>((ref) {
  final cryptoCore = ref.watch(cryptoCoreFactoryProvider)();
  ref.onDispose(() {
    unawaited(cryptoCore.close());
  });
  return cryptoCore;
});

final enrollmentCryptoProvider = Provider<EnrollmentCryptoPort>((ref) {
  final cryptoCore = ref.watch(cryptoCoreProvider);
  return cryptoCore is EnrollmentCryptoPort
      ? cryptoCore as EnrollmentCryptoPort
      : const UnsupportedEnrollmentCrypto();
});

final identityCryptoProvider = Provider<IdentityCryptoPort>((ref) {
  final cryptoCore = ref.watch(cryptoCoreProvider);
  return cryptoCore is IdentityCryptoPort
      ? cryptoCore as IdentityCryptoPort
      : const UnsupportedIdentityCrypto();
});

final pairwiseCryptoProvider = Provider<PairwiseCryptoPort>((ref) {
  final cryptoCore = ref.watch(cryptoCoreProvider);
  return cryptoCore is PairwiseCryptoPort
      ? cryptoCore as PairwiseCryptoPort
      : const UnsupportedCryptoCore();
});

final pairwiseSessionCryptoProvider = Provider<PairwiseSessionCryptoPort>(
  (ref) => NativePairwiseSessionCrypto(ref.watch(pairwiseCryptoProvider)),
);

final applicationProtocolProvider = Provider<ApplicationProtocolPort>((ref) {
  final cryptoCore = ref.watch(cryptoCoreProvider);
  return cryptoCore is ApplicationProtocolPort
      ? cryptoCore as ApplicationProtocolPort
      : const UnsupportedCryptoCore();
});

final deviceControlCryptoProvider = Provider<DeviceControlCryptoPort>((ref) {
  final cryptoCore = ref.watch(cryptoCoreProvider);
  return cryptoCore is DeviceControlCryptoPort
      ? cryptoCore as DeviceControlCryptoPort
      : const UnsupportedCryptoCore();
});

final attachmentCryptoProvider = Provider<AttachmentCryptoPort>((ref) {
  final cryptoCore = ref.watch(cryptoCoreProvider);
  return cryptoCore is AttachmentCryptoPort
      ? cryptoCore as AttachmentCryptoPort
      : const UnsupportedCryptoCore();
});

final class UnsupportedIdentityCrypto implements IdentityCryptoPort {
  const UnsupportedIdentityCrypto();

  Future<Result<T>> _unsupported<T>() async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );

  @override
  Future<Result<UserSigningAttestation>> attestPeerMaster({
    required IdentityKeyPackage localIdentity,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
  }) => _unsupported();
  @override
  Future<Result<PeerDeviceLogInspection>> inspectPeerDeviceLog({
    required Uint8List userId,
    required Uint8List selfSigningPublic,
    required List<PeerPublicDevice> liveDevices,
    required bool requireCurrentLiveSet,
    required Uint8List record,
  }) => _unsupported();
  @override
  Future<Result<SafetyFingerprint>> safetyFingerprint({
    required Uint8List localUserId,
    required Uint8List localMasterPublic,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
  }) => _unsupported();
  @override
  Future<Result<void>> verifyClaimedBundle({
    required Uint8List userId,
    required Uint8List deviceId,
    required Uint8List selfSigningPublic,
    required ClaimedPrekeyBundle bundle,
  }) => _unsupported();
  @override
  Future<Result<void>> verifyIdentity({
    required Uint8List userId,
    required PeerIdentityPublic identity,
  }) => _unsupported();
  @override
  Future<Result<void>> verifyUserAttestation({
    required Uint8List signerUserId,
    required Uint8List signerUserSigningPublic,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
    required UserSigningAttestation attestation,
  }) => _unsupported();
}
