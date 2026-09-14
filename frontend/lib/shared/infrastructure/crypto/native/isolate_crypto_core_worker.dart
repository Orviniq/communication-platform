import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/attachment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/enrollment_crypto_port.dart';
import 'package:communication_platform/core/application/ports/identity_crypto_port.dart';
import 'package:communication_platform/core/protocol/attachment_crypto_model.dart';
import 'package:communication_platform/core/protocol/crypto_core_model.dart';
import 'package:communication_platform/core/protocol/enrollment_crypto_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/shared/infrastructure/crypto/crypto_core_runtime.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/application_protocol_ffi.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/application_protocol_native_session.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/attachment_crypto_ffi.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/attachment_crypto_native_session.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/crypto_core_ffi.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/crypto_core_native_session.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/enrollment_crypto_ffi.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/enrollment_crypto_native_session.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/identity_crypto_ffi.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/identity_crypto_native_session.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/pairwise_crypto_ffi.dart';
import 'package:communication_platform/shared/infrastructure/crypto/native/pairwise_crypto_native_session.dart';

const int _handshakeReady = 0;
const int _handshakeFailed = 1;
const int _operationCapabilities = 1;
const int _operationSelfTest = 2;
const int _operationClose = 3;
const int _operationPrepareDevice = 4;
const int _operationPrepareFirstIdentity = 5;
const int _operationRestoreIdentity = 6;
const int _operationSanitizeIdentity = 7;
const int _operationCrossSignDevice = 8;
const int _operationCreateDeviceLog = 9;
const int _operationInspectDeviceLog = 10;
const int _operationVerifyIdentity = 11;
const int _operationVerifyClaimedBundle = 12;
const int _operationInspectPeerDeviceLog = 13;
const int _operationSafetyFingerprint = 14;
const int _operationAttestPeerMaster = 15;
const int _operationVerifyUserAttestation = 16;
const int _operationPairwise = 17;
const int _operationApplicationProtocol = 18;
const int _operationAttachment = 19;
const int _operationRotateRecoverySecret = 21;
const int _attachmentCreate = 1;
const int _attachmentPush = 2;
const int _attachmentPullCreate = 3;
const int _attachmentPullChunk = 4;
const int _attachmentClose = 5;
const int _attachmentRandom = 6;
const int _replySuccess = 0;
const int _replyFailure = 1;
const int _failureCryptoCore = 1;
const int _failureUnsupportedProtocol = 2;
const int _failureSecurity = 3;

/// Owns the native library and all native calls in one dedicated isolate.
final class IsolateCryptoCoreWorker
    implements
        CryptoCoreWorker,
        EnrollmentCryptoWorker,
        IdentityCryptoWorker,
        PairwiseCryptoWorker,
        ApplicationProtocolWorker,
        AttachmentCryptoWorker {
  bool _closed = false;
  Future<_CryptoWorkerState?>? _stateFuture;
  Future<void>? _closeFuture;
  final Set<Future<void>> _inFlight = <Future<void>>{};

  @override
  Future<Result<CryptoCoreCapabilities>> capabilities() {
    return _guarded<CryptoCoreCapabilities>(() async {
      final reply = await _request(_operationCapabilities);
      return _decodeCapabilitiesReply(reply);
    });
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closed = true;
    final closing = _closeAfterInFlight();
    _closeFuture = closing;
    return closing;
  }

  @override
  Future<Result<void>> selfTest() {
    return _guarded<void>(() async {
      final reply = await _request(_operationSelfTest);
      return _decodeSelfTestReply(reply);
    });
  }

  @override
  Future<Result<AttachmentCryptoPushSession>> createPush({
    required int plaintextSize,
    required int bucketSize,
    required Uint8List metadata,
  }) => _guarded(() async {
    final reply = await _request(_operationAttachment, <Object?>[
      _attachmentCreate,
      plaintextSize,
      bucketSize,
      metadata,
    ]);
    return _decodeAttachmentPushReply(reply);
  });

  @override
  Future<Result<Uint8List>> pushChunk({
    required AttachmentCryptoPushSession session,
    required Uint8List plaintext,
    required bool finalChunk,
  }) => _guarded(() async {
    final reply = await _request(_operationAttachment, <Object?>[
      _attachmentPush,
      session.handle,
      plaintext,
      finalChunk,
    ]);
    return _decodeBytesReply(reply);
  });

  @override
  Future<Result<AttachmentCryptoPullSession>> createPull({
    required Uint8List key,
    required Uint8List header,
    required Uint8List secretstreamHeader,
    required Uint8List metadata,
  }) => _guarded(() async {
    final reply = await _request(_operationAttachment, <Object?>[
      _attachmentPullCreate,
      key,
      header,
      secretstreamHeader,
      metadata,
    ]);
    return _decodeAttachmentPullReply(reply);
  });

  @override
  Future<Result<AttachmentDecryptedChunk>> pullChunk({
    required AttachmentCryptoPullSession session,
    required Uint8List ciphertext,
  }) => _guarded(() async {
    final reply = await _request(_operationAttachment, <Object?>[
      _attachmentPullChunk,
      session.handle,
      ciphertext,
    ]);
    final result = _decodeBytesReply(reply);
    return result.fold(
      onSuccess: (bytes) {
        if (bytes.isEmpty) {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.malformedServerResponse),
          );
        }
        return Result.success(
          AttachmentDecryptedChunk(
            finalChunk: bytes[0] == 1,
            plaintext: bytes.sublist(1),
          ),
        );
      },
      onFailure: Result.failure,
    );
  });

  @override
  Future<Result<void>> closeSession({
    required int handle,
    bool abort = false,
  }) => _guarded(() async {
    final reply = await _request(_operationAttachment, <Object?>[
      _attachmentClose,
      handle,
      abort,
    ]);
    return _decodeVoidReply(reply);
  });

  @override
  Future<Result<Uint8List>> randomBytes(int length) => _guarded(() async {
    final reply = await _request(_operationAttachment, <Object?>[
      _attachmentRandom,
      length,
    ]);
    return _decodeBytesReply(reply);
  });

  Result<AttachmentCryptoPushSession> _decodeAttachmentPushReply(
    Object? rawReply,
  ) {
    if (rawReply is! List<Object?>) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final reply = rawReply;
    if (reply.length != 8 || reply[0] != _replySuccess) {
      return reply.isNotEmpty && reply[0] == _replyFailure
          ? Result.failure(_decodeFailureReply(reply))
          : const Result.failure(
              SecurityFailure(SecurityFailureKind.malformedServerResponse),
            );
    }
    try {
      return Result.success(
        AttachmentCryptoPushSession(
          handle: reply[1]! as int,
          key: _bytesArgument(reply, 2),
          header: _bytesArgument(reply, 3),
          secretstreamHeader: _bytesArgument(reply, 4),
          plaintextSize: reply[5]! as int,
          streamSize: reply[6]! as int,
          bucketSize: reply[7]! as int,
        ),
      );
    } on Object {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
  }

  Result<AttachmentCryptoPullSession> _decodeAttachmentPullReply(
    Object? rawReply,
  ) {
    if (rawReply is! List<Object?>) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.malformedServerResponse),
      );
    }
    final reply = rawReply;
    if (reply.length == 2 && reply[0] == _replySuccess && reply[1] is int) {
      return Result.success(AttachmentCryptoPullSession(reply[1]! as int));
    }
    return reply.isNotEmpty && reply[0] == _replyFailure
        ? Result.failure(_decodeFailureReply(reply))
        : const Result.failure(
            SecurityFailure(SecurityFailureKind.malformedServerResponse),
          );
  }

  @override
  Future<Result<DeviceKeyPackage>> prepareDevice({required Uint8List userId}) =>
      _guarded(() async {
        final reply = await _request(_operationPrepareDevice, <Object?>[
          userId,
        ]);
        return _decodePackageReply<DeviceKeyPackage>(
          reply,
          DeviceKeyPackage.fromNative,
        );
      });

  @override
  Future<Result<IdentityKeyPackage>> prepareFirstIdentity({
    required Uint8List userId,
  }) => _guarded(() async {
    final reply = await _request(_operationPrepareFirstIdentity, <Object?>[
      userId,
    ]);
    return _decodePackageReply<IdentityKeyPackage>(
      reply,
      IdentityKeyPackage.fromNative,
    );
  });

  @override
  Future<Result<IdentityKeyPackage>> restoreIdentity({
    required Uint8List userId,
    required Uint8List recoverySecret,
    required Uint8List backup,
  }) => _guarded(() async {
    final reply = await _request(_operationRestoreIdentity, <Object?>[
      userId,
      recoverySecret,
      backup,
    ]);
    recoverySecret.fillRange(0, recoverySecret.length, 0);
    return _decodePackageReply<IdentityKeyPackage>(
      reply,
      IdentityKeyPackage.fromNative,
    );
  });

  @override
  Future<Result<IdentityKeyPackage>> sanitizeIdentity({
    required IdentityKeyPackage package,
  }) => _guarded(() async {
    final reply = await _request(_operationSanitizeIdentity, <Object?>[
      package.opaqueBytes,
    ]);
    return _decodePackageReply<IdentityKeyPackage>(
      reply,
      IdentityKeyPackage.fromNative,
    );
  });

  @override
  Future<Result<IdentityKeyPackage>> rotateRecoverySecret({
    required IdentityKeyPackage package,
  }) => _guarded(() async {
    final reply = await _request(_operationRotateRecoverySecret, <Object?>[
      package.opaqueBytes,
    ]);
    return _decodePackageReply<IdentityKeyPackage>(
      reply,
      IdentityKeyPackage.fromNative,
    );
  });

  @override
  Future<Result<Uint8List>> crossSignDevice({
    required DeviceKeyPackage device,
    required IdentityKeyPackage identity,
    required Uint8List deviceId,
    required int bundleVersion,
  }) => _guarded(() async {
    final reply = await _request(_operationCrossSignDevice, <Object?>[
      device.opaqueBytes,
      identity.opaqueBytes,
      deviceId,
      bundleVersion,
    ]);
    return _decodeBytesReply(reply);
  });

  @override
  Future<Result<Uint8List>> createDeviceLogRecord({
    required IdentityKeyPackage identity,
    required Uint8List userId,
    required int sequence,
    required Uint8List previousHash,
    required Uint8List canonicalLiveSet,
    required int identityVersion,
    required int coarseUnixDay,
  }) => _guarded(() async {
    final reply = await _request(_operationCreateDeviceLog, <Object?>[
      identity.opaqueBytes,
      userId,
      sequence,
      previousHash,
      canonicalLiveSet,
      identityVersion,
      coarseUnixDay,
    ]);
    return _decodeBytesReply(reply);
  });

  @override
  Future<Result<DeviceLogInspection>> inspectDeviceLogRecord({
    required IdentityKeyPackage identity,
    required Uint8List userId,
    required Uint8List record,
  }) => _guarded(() async {
    final reply = await _request(_operationInspectDeviceLog, <Object?>[
      identity.opaqueBytes,
      userId,
      record,
    ]);
    final bytesResult = _decodeBytesReply(reply);
    return bytesResult.fold(
      onSuccess: (bytes) {
        try {
          return Result.success(DeviceLogInspection.fromNative(bytes));
        } on Object {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.malformedServerResponse),
          );
        }
      },
      onFailure: Result.failure,
    );
  });

  @override
  Future<Result<void>> verifyIdentity({
    required Uint8List userId,
    required PeerIdentityPublic identity,
  }) => _guarded(() async {
    final reply = await _request(_operationVerifyIdentity, <Object?>[
      userId,
      identity.masterPublic,
      identity.selfSigningPublic,
      identity.userSigningPublic,
      identity.masterSignature,
      identity.version,
    ]);
    return _decodeVoidReply(reply);
  });

  @override
  Future<Result<void>> verifyClaimedBundle({
    required Uint8List userId,
    required Uint8List deviceId,
    required Uint8List selfSigningPublic,
    required ClaimedPrekeyBundle bundle,
  }) => _guarded(() async {
    final reply = await _request(_operationVerifyClaimedBundle, <Object?>[
      userId,
      deviceId,
      selfSigningPublic,
      bundle.deviceId,
      bundle.registrationId,
      bundle.identityPublic,
      bundle.signedPrekeyId,
      bundle.signedPrekeyPublic,
      bundle.signedPrekeySignature,
      bundle.crossSignature,
      bundle.bundleVersion,
      bundle.pqSignedPrekeyId,
      bundle.pqSignedPrekeyPublic,
      bundle.pqSignedPrekeySignature,
      bundle.oneTimePrekeyId,
      bundle.oneTimePrekeyPublic,
      bundle.pqOneTimePrekeyId,
      bundle.pqOneTimePrekeyPublic,
    ]);
    return _decodeVoidReply(reply);
  });

  @override
  Future<Result<PeerDeviceLogInspection>> inspectPeerDeviceLog({
    required Uint8List userId,
    required Uint8List selfSigningPublic,
    required List<PeerPublicDevice> liveDevices,
    required bool requireCurrentLiveSet,
    required Uint8List record,
  }) => _guarded(() async {
    final reply = await _request(_operationInspectPeerDeviceLog, <Object?>[
      userId,
      selfSigningPublic,
      requireCurrentLiveSet,
      <Object?>[
        for (final device in liveDevices)
          <Object?>[
            device.deviceId,
            device.identityPublic,
            device.registrationId,
            device.crossSignature,
            device.bundleVersion,
          ],
      ],
      record,
    ]);
    return _decodeBytesReply(reply).fold(
      onSuccess: (bytes) {
        try {
          return Result.success(PeerDeviceLogInspection.fromNative(bytes));
        } on Object {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.malformedServerResponse),
          );
        }
      },
      onFailure: Result.failure,
    );
  });

  @override
  Future<Result<SafetyFingerprint>> safetyFingerprint({
    required Uint8List localUserId,
    required Uint8List localMasterPublic,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
  }) => _guarded(() async {
    final reply = await _request(_operationSafetyFingerprint, <Object?>[
      localUserId,
      localMasterPublic,
      peerUserId,
      peerMasterPublic,
    ]);
    return _decodeBytesReply(reply).fold(
      onSuccess: (bytes) {
        try {
          return Result.success(SafetyFingerprint(bytes));
        } on Object {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.malformedServerResponse),
          );
        }
      },
      onFailure: Result.failure,
    );
  });

  @override
  Future<Result<UserSigningAttestation>> attestPeerMaster({
    required IdentityKeyPackage localIdentity,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
  }) => _guarded(() async {
    final reply = await _request(_operationAttestPeerMaster, <Object?>[
      localIdentity.opaqueBytes,
      peerUserId,
      peerMasterPublic,
    ]);
    return _decodeBytesReply(reply).fold(
      onSuccess: (bytes) {
        try {
          return Result.success(UserSigningAttestation(bytes));
        } on Object {
          return const Result.failure(
            SecurityFailure(SecurityFailureKind.malformedServerResponse),
          );
        }
      },
      onFailure: Result.failure,
    );
  });

  @override
  Future<Result<void>> verifyUserAttestation({
    required Uint8List signerUserId,
    required Uint8List signerUserSigningPublic,
    required Uint8List peerUserId,
    required Uint8List peerMasterPublic,
    required UserSigningAttestation attestation,
  }) => _guarded(() async {
    final reply = await _request(_operationVerifyUserAttestation, <Object?>[
      signerUserId,
      signerUserSigningPublic,
      peerUserId,
      peerMasterPublic,
      attestation.signature,
    ]);
    return _decodeVoidReply(reply);
  });

  @override
  Future<Result<PairwiseCryptoResponse>> pairwiseOperation({
    required PairwiseCryptoOperation operation,
    required Uint8List payload,
  }) => _guarded(() async {
    final reply = await _request(_operationPairwise, <Object?>[
      operation.wireValue,
      payload,
    ]);
    return _decodePairwiseReply(reply, operation);
  });

  @override
  Future<Result<Uint8List>> applicationOperation({
    required int operation,
    required Uint8List payload,
  }) => _guarded(() async {
    final reply = await _request(_operationApplicationProtocol, <Object?>[
      operation,
      payload,
    ]);
    return _decodeBytesReply(reply);
  });

  Future<Result<T>> _guarded<T>(Future<Result<T>> Function() operation) {
    if (_closed) {
      return Future<Result<T>>.value(
        Result<T>.failure(
          CryptoCoreFailure(CryptoCoreFailureCode.stateViolation),
        ),
      );
    }
    final completion = Completer<void>();
    final marker = completion.future;
    _inFlight.add(marker);
    return _runGuarded(operation, completion, marker);
  }

  Future<Result<T>> _runGuarded<T>(
    Future<Result<T>> Function() operation,
    Completer<void> completion,
    Future<void> marker,
  ) async {
    try {
      return await operation();
    } on Object {
      return Result<T>.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    } finally {
      _inFlight.remove(marker);
      completion.complete();
    }
  }

  Future<Object?> _request(
    int operation, [
    List<Object?> args = const [],
  ]) async {
    final state = await _ensureState();
    if (state == null) {
      return null;
    }
    final replyPort = ReceivePort();
    try {
      state.commandPort.send(<Object?>[operation, replyPort.sendPort, ...args]);
      return await replyPort.first.timeout(
        const Duration(seconds: 60),
        onTimeout: () => null,
      );
    } finally {
      replyPort.close();
    }
  }

  Future<_CryptoWorkerState?> _ensureState() {
    if (_closed) {
      return Future<_CryptoWorkerState?>.value();
    }
    return _stateFuture ??= _startWorker();
  }

  Future<_CryptoWorkerState?> _startWorker() async {
    final bootstrapPort = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<SendPort>(
        _cryptoCoreWorkerEntrypoint,
        bootstrapPort.sendPort,
        debugName: 'communication-crypto-core-v1',
      );
      final handshake = await bootstrapPort.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => const <Object?>[_handshakeFailed],
      );
      if (handshake is List<Object?> &&
          handshake.length == 2 &&
          handshake[0] == _handshakeReady &&
          handshake[1] is SendPort) {
        return _CryptoWorkerState(
          isolate: isolate,
          commandPort: handshake[1]! as SendPort,
        );
      }
      isolate.kill(priority: Isolate.immediate);
      return null;
    } on Object {
      isolate?.kill(priority: Isolate.immediate);
      return null;
    } finally {
      bootstrapPort.close();
    }
  }

  Future<void> _closeAfterInFlight() async {
    await Future.wait<void>(_inFlight.toList(growable: false));
    final stateFuture = _stateFuture;
    if (stateFuture == null) {
      return;
    }
    final state = await stateFuture;
    if (state == null) {
      return;
    }
    final replyPort = ReceivePort();
    try {
      state.commandPort.send(<Object?>[_operationClose, replyPort.sendPort]);
      await replyPort.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
    } on Object {
      // Shutdown remains best-effort; no exception details cross the boundary.
    } finally {
      replyPort.close();
      state.isolate.kill(priority: Isolate.immediate);
    }
  }

  @override
  String toString() => 'IsolateCryptoCoreWorker(<redacted>)';
}

final class _CryptoWorkerState {
  const _CryptoWorkerState({required this.isolate, required this.commandPort});

  final Isolate isolate;
  final SendPort commandPort;

  @override
  String toString() => '_CryptoWorkerState(<redacted>)';
}

@pragma('vm:entry-point')
void _cryptoCoreWorkerEntrypoint(SendPort bootstrapPort) {
  unawaited(_runCryptoCoreWorker(bootstrapPort));
}

Future<void> _runCryptoCoreWorker(SendPort bootstrapPort) async {
  final commandPort = ReceivePort();
  late final CryptoCoreNativeSession session;
  late final EnrollmentCryptoNativeSession enrollmentSession;
  late final IdentityCryptoNativeSession identitySession;
  late final PairwiseCryptoNativeSession pairwiseSession;
  late final ApplicationProtocolNativeSession applicationSession;
  late final AttachmentCryptoNativeSession attachmentSession;
  try {
    session = CryptoCoreNativeSession(
      api: DynamicCryptoCoreNativeApi.openAndroid(),
    );
    enrollmentSession = EnrollmentCryptoNativeSession(
      api: DynamicEnrollmentCryptoNativeApi.openAndroid(),
    );
    identitySession = IdentityCryptoNativeSession(
      api: DynamicIdentityCryptoNativeApi.openAndroid(),
    );
    pairwiseSession = PairwiseCryptoNativeSession(
      api: DynamicPairwiseCryptoNativeApi.openAndroid(),
    );
    applicationSession = ApplicationProtocolNativeSession(
      api: DynamicApplicationProtocolNativeApi.openAndroid(),
    );
    attachmentSession = AttachmentCryptoNativeSession(
      api: DynamicAttachmentCryptoNativeApi.openAndroid(),
    );
  } on Object {
    bootstrapPort.send(const <Object?>[_handshakeFailed]);
    commandPort.close();
    return;
  }

  bootstrapPort.send(<Object?>[_handshakeReady, commandPort.sendPort]);
  try {
    await for (final Object? message in commandPort) {
      if (message is! List<Object?> || message.length < 2) {
        if (message is List<Object?> &&
            message.length >= 2 &&
            message[1] is SendPort) {
          (message[1]! as SendPort).send(
            _encodeFailureReply(
              const SecurityFailure(
                SecurityFailureKind.malformedServerResponse,
              ),
            ),
          );
        }
        continue;
      }
      final operation = message[0];
      final replyPort = message[1];
      if (operation is! int || replyPort is! SendPort) {
        continue;
      }
      try {
        switch (operation) {
          case _operationCapabilities:
            replyPort.send(_encodeCapabilitiesReply(session.capabilities()));
            continue;
          case _operationSelfTest:
            replyPort.send(_encodeSelfTestReply(session.selfTest()));
            continue;
          case _operationPrepareDevice:
            replyPort.send(
              _encodePackageReply(
                enrollmentSession.prepareDevice(_bytesArgument(message, 2)),
              ),
            );
            continue;
          case _operationPrepareFirstIdentity:
            replyPort.send(
              _encodePackageReply(
                enrollmentSession.prepareFirstIdentity(
                  _bytesArgument(message, 2),
                ),
              ),
            );
            continue;
          case _operationRestoreIdentity:
            replyPort.send(
              _encodePackageReply(
                enrollmentSession.restoreIdentity(
                  _bytesArgument(message, 2),
                  _bytesArgument(message, 3),
                  _bytesArgument(message, 4),
                ),
              ),
            );
            continue;
          case _operationSanitizeIdentity:
            replyPort.send(
              _encodePackageReply(
                enrollmentSession.sanitizeIdentity(
                  IdentityKeyPackage.fromNative(_bytesArgument(message, 2)),
                ),
              ),
            );
            continue;
          case _operationRotateRecoverySecret:
            replyPort.send(
              _encodePackageReply(
                enrollmentSession.rotateRecoverySecret(
                  IdentityKeyPackage.fromNative(_bytesArgument(message, 2)),
                ),
              ),
            );
            continue;
          case _operationCrossSignDevice:
            replyPort.send(
              _encodeBytesReply(_crossSignInWorker(enrollmentSession, message)),
            );
            continue;
          case _operationCreateDeviceLog:
            replyPort.send(
              _encodeBytesReply(_createLogInWorker(enrollmentSession, message)),
            );
            continue;
          case _operationInspectDeviceLog:
            replyPort.send(
              _encodeInspectionReply(
                _inspectLogInWorker(enrollmentSession, message),
              ),
            );
            continue;
          case _operationVerifyIdentity:
            replyPort.send(
              _encodeVoidReply(
                _verifyIdentityInWorker(identitySession, message),
              ),
            );
            continue;
          case _operationVerifyClaimedBundle:
            replyPort.send(
              _encodeVoidReply(_verifyBundleInWorker(identitySession, message)),
            );
            continue;
          case _operationInspectPeerDeviceLog:
            replyPort.send(
              _encodePeerInspectionReply(
                _inspectPeerLogInWorker(identitySession, message),
              ),
            );
            continue;
          case _operationSafetyFingerprint:
            replyPort.send(
              _encodeSafetyReply(_safetyInWorker(identitySession, message)),
            );
            continue;
          case _operationAttestPeerMaster:
            replyPort.send(
              _encodeAttestationReply(
                _attestInWorker(identitySession, message),
              ),
            );
            continue;
          case _operationVerifyUserAttestation:
            replyPort.send(
              _encodeVoidReply(
                _verifyAttestationInWorker(identitySession, message),
              ),
            );
            continue;
          case _operationPairwise:
            replyPort.send(
              _encodePairwiseReply(_pairwiseInWorker(pairwiseSession, message)),
            );
            continue;
          case _operationApplicationProtocol:
            replyPort.send(
              _encodeBytesReply(
                _applicationInWorker(applicationSession, message),
              ),
            );
            continue;
          case _operationAttachment:
            replyPort.send(
              await _attachmentInWorker(attachmentSession, message),
            );
            continue;
          case _operationClose:
            replyPort.send(const <Object?>[_replySuccess]);
            commandPort.close();
            return;
          default:
            replyPort.send(
              _encodeFailureReply(
                const SecurityFailure(SecurityFailureKind.policyBlocked),
              ),
            );
            continue;
        }
      } on Object {
        replyPort.send(
          _encodeFailureReply(
            const SecurityFailure(SecurityFailureKind.policyBlocked),
          ),
        );
      }
    }
  } on Object {
    // All observable failures are converted to payload-free replies above.
  } finally {
    commandPort.close();
  }
}

Uint8List _bytesArgument(List<Object?> message, int index) {
  final value = message.length > index ? message[index] : null;
  if (value is! Uint8List) {
    throw const FormatException();
  }
  return value;
}

Result<Uint8List> _crossSignInWorker(
  EnrollmentCryptoNativeSession session,
  List<Object?> message,
) {
  final version = message.length > 5 ? message[5] : null;
  if (version is! int) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
  final deviceResult = _decodePackageReply(<Object?>[
    _replySuccess,
    _bytesArgument(message, 2),
  ], DeviceKeyPackage.fromNative);
  final identityResult = _decodePackageReply(<Object?>[
    _replySuccess,
    _bytesArgument(message, 3),
  ], IdentityKeyPackage.fromNative);
  return deviceResult.fold(
    onSuccess: (device) => identityResult.fold(
      onSuccess: (identity) => session.crossSignDevice(
        device,
        identity,
        _bytesArgument(message, 4),
        version,
      ),
      onFailure: Result.failure,
    ),
    onFailure: Result.failure,
  );
}

Result<Uint8List> _createLogInWorker(
  EnrollmentCryptoNativeSession session,
  List<Object?> message,
) {
  final sequence = message.length > 4 ? message[4] : null;
  final identityVersion = message.length > 7 ? message[7] : null;
  final coarseDay = message.length > 8 ? message[8] : null;
  if (sequence is! int || identityVersion is! int || coarseDay is! int) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
  final identityResult = _decodePackageReply(<Object?>[
    _replySuccess,
    _bytesArgument(message, 2),
  ], IdentityKeyPackage.fromNative);
  return identityResult.fold(
    onSuccess: (identity) => session.createDeviceLogRecord(
      identity: identity,
      userId: _bytesArgument(message, 3),
      sequence: sequence,
      previousHash: _bytesArgument(message, 5),
      canonicalLiveSet: _bytesArgument(message, 6),
      identityVersion: identityVersion,
      coarseUnixDay: coarseDay,
    ),
    onFailure: Result.failure,
  );
}

Result<DeviceLogInspection> _inspectLogInWorker(
  EnrollmentCryptoNativeSession session,
  List<Object?> message,
) {
  final identityResult = _decodePackageReply(<Object?>[
    _replySuccess,
    _bytesArgument(message, 2),
  ], IdentityKeyPackage.fromNative);
  return identityResult.fold(
    onSuccess: (identity) => session.inspectDeviceLogRecord(
      identity: identity,
      userId: _bytesArgument(message, 3),
      record: _bytesArgument(message, 4),
    ),
    onFailure: Result.failure,
  );
}

Result<void> _verifyIdentityInWorker(
  IdentityCryptoNativeSession session,
  List<Object?> message,
) {
  final version = message.length > 7 ? message[7] : null;
  if (version is! int) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
  try {
    return session.verifyIdentity(
      _bytesArgument(message, 2),
      PeerIdentityPublic(
        masterPublic: _bytesArgument(message, 3),
        selfSigningPublic: _bytesArgument(message, 4),
        userSigningPublic: _bytesArgument(message, 5),
        masterSignature: _bytesArgument(message, 6),
        version: version,
      ),
    );
  } on Object {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
}

Result<void> _verifyBundleInWorker(
  IdentityCryptoNativeSession session,
  List<Object?> message,
) {
  try {
    return session.verifyClaimedBundle(
      userId: _bytesArgument(message, 2),
      deviceId: _bytesArgument(message, 3),
      selfSigningPublic: _bytesArgument(message, 4),
      bundle: ClaimedPrekeyBundle(
        deviceId: message[5]! as String,
        registrationId: message[6]! as int,
        identityPublic: _bytesArgument(message, 7),
        signedPrekeyId: message[8]! as int,
        signedPrekeyPublic: _bytesArgument(message, 9),
        signedPrekeySignature: _bytesArgument(message, 10),
        crossSignature: _bytesArgument(message, 11),
        bundleVersion: message[12]! as int,
        pqSignedPrekeyId: message[13] as int?,
        pqSignedPrekeyPublic: message[14] as Uint8List?,
        pqSignedPrekeySignature: message[15] as Uint8List?,
        oneTimePrekeyId: message[16] as int?,
        oneTimePrekeyPublic: message[17] as Uint8List?,
        pqOneTimePrekeyId: message[18] as int?,
        pqOneTimePrekeyPublic: message[19] as Uint8List?,
      ),
    );
  } on Object {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
}

Result<PeerDeviceLogInspection> _inspectPeerLogInWorker(
  IdentityCryptoNativeSession session,
  List<Object?> message,
) {
  try {
    final requireCurrentLiveSet = message[4]! as bool;
    final encoded = message[5]! as List<Object?>;
    final devices = <PeerPublicDevice>[];
    for (final value in encoded) {
      final fields = value! as List<Object?>;
      devices.add(
        PeerPublicDevice(
          deviceId: fields[0]! as String,
          identityPublic: fields[1]! as Uint8List,
          registrationId: fields[2]! as int,
          crossSignature: fields[3] as Uint8List?,
          bundleVersion: fields[4] as int?,
        ),
      );
    }
    return session.inspectPeerDeviceLog(
      userId: _bytesArgument(message, 2),
      selfSigningPublic: _bytesArgument(message, 3),
      liveDevices: devices,
      requireCurrentLiveSet: requireCurrentLiveSet,
      record: _bytesArgument(message, 6),
    );
  } on Object {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
}

Result<SafetyFingerprint> _safetyInWorker(
  IdentityCryptoNativeSession session,
  List<Object?> message,
) => session.safetyFingerprint(
  localUserId: _bytesArgument(message, 2),
  localMasterPublic: _bytesArgument(message, 3),
  peerUserId: _bytesArgument(message, 4),
  peerMasterPublic: _bytesArgument(message, 5),
);

Result<UserSigningAttestation> _attestInWorker(
  IdentityCryptoNativeSession session,
  List<Object?> message,
) {
  try {
    return session.attestPeerMaster(
      localIdentity: IdentityKeyPackage.fromNative(_bytesArgument(message, 2)),
      peerUserId: _bytesArgument(message, 3),
      peerMasterPublic: _bytesArgument(message, 4),
    );
  } on Object {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
}

Result<void> _verifyAttestationInWorker(
  IdentityCryptoNativeSession session,
  List<Object?> message,
) {
  try {
    return session.verifyUserAttestation(
      signerUserId: _bytesArgument(message, 2),
      signerUserSigningPublic: _bytesArgument(message, 3),
      peerUserId: _bytesArgument(message, 4),
      peerMasterPublic: _bytesArgument(message, 5),
      attestation: UserSigningAttestation(_bytesArgument(message, 6)),
    );
  } on Object {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
}

Result<PairwiseCryptoResponse> _pairwiseInWorker(
  PairwiseCryptoNativeSession session,
  List<Object?> message,
) {
  final wireOperation = message.length > 2 ? message[2] : null;
  if (wireOperation is! int) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
  PairwiseCryptoOperation? operation;
  for (final candidate in PairwiseCryptoOperation.values) {
    if (candidate.wireValue == wireOperation) {
      operation = candidate;
      break;
    }
  }
  if (operation == null) {
    return const Result.failure(
      UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.version),
    );
  }
  return session.operation(operation, _bytesArgument(message, 3));
}

Result<Uint8List> _applicationInWorker(
  ApplicationProtocolNativeSession session,
  List<Object?> message,
) {
  final operation = message.length > 2 ? message[2] : null;
  if (operation is! int || operation < 1 || operation > 5) {
    return const Result.failure(
      UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.version),
    );
  }
  return session.operation(operation, _bytesArgument(message, 3));
}

Future<List<Object?>> _attachmentInWorker(
  AttachmentCryptoNativeSession session,
  List<Object?> message,
) async {
  final operation = message.length > 2 ? message[2] : null;
  if (operation is! int || operation < 1 || operation > 6) {
    return _encodeFailureReply(
      const UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.version),
    );
  }
  try {
    switch (operation) {
      case _attachmentCreate:
        final result = await session.createPush(
          plaintextSize: message[3]! as int,
          bucketSize: message[4]! as int,
          metadata: _bytesArgument(message, 5),
        );
        return result.fold<List<Object?>>(
          onSuccess: (value) => <Object?>[
            _replySuccess,
            value.handle,
            value.key,
            value.header,
            value.secretstreamHeader,
            value.plaintextSize,
            value.streamSize,
            value.bucketSize,
          ],
          onFailure: _encodeFailureReply,
        );
      case _attachmentPush:
        final result = await session.pushChunk(
          session: AttachmentCryptoPushSession.handleOnly(message[3]! as int),
          plaintext: _bytesArgument(message, 4),
          finalChunk: message[5] == true,
        );
        return _encodeBytesReply(result);
      case _attachmentPullCreate:
        final result = await session.createPull(
          key: _bytesArgument(message, 3),
          header: _bytesArgument(message, 4),
          secretstreamHeader: _bytesArgument(message, 5),
          metadata: _bytesArgument(message, 6),
        );
        return result.fold<List<Object?>>(
          onSuccess: (value) => <Object?>[_replySuccess, value.handle],
          onFailure: _encodeFailureReply,
        );
      case _attachmentPullChunk:
        final result = await session.pullChunk(
          session: AttachmentCryptoPullSession(message[3]! as int),
          ciphertext: _bytesArgument(message, 4),
        );
        return result.fold<List<Object?>>(
          onSuccess: (value) => <Object?>[
            _replySuccess,
            Uint8List.fromList([value.finalChunk ? 1 : 0, ...value.plaintext]),
          ],
          onFailure: _encodeFailureReply,
        );
      case _attachmentClose:
        return _encodeVoidReply(
          await session.closeSession(
            handle: message[3]! as int,
            abort: message[4] == true,
          ),
        );
      case _attachmentRandom:
        return _encodeBytesReply(await session.randomBytes(message[3]! as int));
    }
  } on Object {
    return _encodeFailureReply(
      const SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
  return _encodeFailureReply(
    const UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.version),
  );
}

List<Object?> _encodeCapabilitiesReply(Result<CryptoCoreCapabilities> result) {
  return result.fold(
    onSuccess: (capabilities) => <Object?>[
      _replySuccess,
      capabilities.abiVersion,
      capabilities.featureBits,
      capabilities.maxInputBytes,
      capabilities.maxCborDepth,
      capabilities.maxCborItems,
    ],
    onFailure: _encodeFailureReply,
  );
}

List<Object?> _encodeSelfTestReply(Result<void> result) {
  return result.fold(
    onSuccess: (_) => const <Object?>[_replySuccess],
    onFailure: _encodeFailureReply,
  );
}

List<Object?> _encodePackageReply<T>(Result<T> result) => result.fold(
  onSuccess: (value) => <Object?>[
    _replySuccess,
    switch (value) {
      DeviceKeyPackage(:final opaqueBytes) => opaqueBytes,
      IdentityKeyPackage(:final opaqueBytes) => opaqueBytes,
      _ => throw StateError('Unsupported enrollment package'),
    },
  ],
  onFailure: _encodeFailureReply,
);

List<Object?> _encodeBytesReply(Result<Uint8List> result) => result.fold(
  onSuccess: (bytes) => <Object?>[_replySuccess, bytes],
  onFailure: _encodeFailureReply,
);

List<Object?> _encodeInspectionReply(Result<DeviceLogInspection> result) =>
    result.fold(
      onSuccess: (inspection) => <Object?>[
        _replySuccess,
        inspection.toNative(),
      ],
      onFailure: _encodeFailureReply,
    );

List<Object?> _encodeVoidReply(Result<void> result) => result.fold(
  onSuccess: (_) => const <Object?>[_replySuccess],
  onFailure: _encodeFailureReply,
);

List<Object?> _encodePeerInspectionReply(
  Result<PeerDeviceLogInspection> result,
) => result.fold(
  onSuccess: (value) {
    final bytes = Uint8List(108);
    ByteData.sublistView(bytes)
      ..setUint64(0, value.sequence)
      ..setUint32(104, value.identityVersion);
    bytes
      ..setRange(8, 40, value.previousHash)
      ..setRange(40, 72, value.recordHash)
      ..setRange(72, 104, value.liveDeviceSetHash);
    return <Object?>[_replySuccess, bytes];
  },
  onFailure: _encodeFailureReply,
);

List<Object?> _encodeSafetyReply(Result<SafetyFingerprint> result) =>
    result.fold(
      onSuccess: (value) => <Object?>[_replySuccess, value.digest],
      onFailure: _encodeFailureReply,
    );

List<Object?> _encodeAttestationReply(Result<UserSigningAttestation> result) =>
    result.fold(
      onSuccess: (value) => <Object?>[_replySuccess, value.signature],
      onFailure: _encodeFailureReply,
    );

List<Object?> _encodePairwiseReply(Result<PairwiseCryptoResponse> result) =>
    result.fold(
      onSuccess: (value) => <Object?>[
        _replySuccess,
        value.operation.wireValue,
        value.outcome.index,
        value.body,
      ],
      onFailure: _encodeFailureReply,
    );

Result<PairwiseCryptoResponse> _decodePairwiseReply(
  Object? reply,
  PairwiseCryptoOperation expectedOperation,
) {
  if (reply is! List<Object?> || reply.isEmpty) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  }
  if (reply[0] == _replyFailure) {
    return Result.failure(_decodeFailureReply(reply));
  }
  if (reply.length != 4 ||
      reply[0] != _replySuccess ||
      reply[1] != expectedOperation.wireValue ||
      reply[2] is! int ||
      reply[3] is! Uint8List) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
  final outcome = reply[2]! as int;
  if (outcome < 0 || outcome >= PairwiseCryptoOutcome.values.length) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
  return Result.success(
    PairwiseCryptoResponse(
      operation: expectedOperation,
      outcome: PairwiseCryptoOutcome.values[outcome],
      body: reply[3]! as Uint8List,
    ),
  );
}

Result<void> _decodeVoidReply(Object? reply) {
  if (reply is! List<Object?> || reply.isEmpty) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  }
  if (reply[0] == _replyFailure) {
    return Result.failure(_decodeFailureReply(reply));
  }
  return reply.length == 1 && reply[0] == _replySuccess
      ? const Result.success(null)
      : const Result.failure(
          SecurityFailure(SecurityFailureKind.malformedServerResponse),
        );
}

Result<T> _decodePackageReply<T>(Object? reply, T Function(Uint8List) decoder) {
  final bytesResult = _decodeBytesReply(reply);
  return bytesResult.fold(
    onSuccess: (bytes) {
      try {
        return Result.success(decoder(bytes));
      } on Object {
        return const Result.failure(
          SecurityFailure(SecurityFailureKind.malformedServerResponse),
        );
      }
    },
    onFailure: Result.failure,
  );
}

Result<Uint8List> _decodeBytesReply(Object? reply) {
  if (reply is! List<Object?> || reply.isEmpty) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  }
  if (reply[0] == _replyFailure) {
    return Result.failure(_decodeFailureReply(reply));
  }
  if (reply.length != 2 ||
      reply[0] != _replySuccess ||
      reply[1] is! Uint8List) {
    return const Result.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
  return Result.success(Uint8List.fromList(reply[1]! as Uint8List));
}

List<Object?> _encodeFailureReply(Failure failure) {
  return switch (failure) {
    CryptoCoreFailure(:final code) => <Object?>[
      _replyFailure,
      _failureCryptoCore,
      code.wireValue,
    ],
    UnsupportedProtocolFailure(:final kind) => <Object?>[
      _replyFailure,
      _failureUnsupportedProtocol,
      kind.index,
    ],
    SecurityFailure(:final kind) => <Object?>[
      _replyFailure,
      _failureSecurity,
      kind.index,
    ],
    _ => <Object?>[
      _replyFailure,
      _failureSecurity,
      SecurityFailureKind.policyBlocked.index,
    ],
  };
}

Result<CryptoCoreCapabilities> _decodeCapabilitiesReply(Object? reply) {
  if (reply is! List<Object?> || reply.isEmpty) {
    return const Result<CryptoCoreCapabilities>.failure(
      SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  }
  if (reply[0] == _replyFailure) {
    return Result<CryptoCoreCapabilities>.failure(_decodeFailureReply(reply));
  }
  if (reply.length != 6 ||
      reply[0] != _replySuccess ||
      reply[1] is! int ||
      reply[2] is! int ||
      reply[3] is! int ||
      reply[4] is! int ||
      reply[5] is! int) {
    return const Result<CryptoCoreCapabilities>.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
  final capabilities = CryptoCoreCapabilities(
    abiVersion: reply[1]! as int,
    featureBits: reply[2]! as int,
    maxInputBytes: reply[3]! as int,
    maxCborDepth: reply[4]! as int,
    maxCborItems: reply[5]! as int,
  );
  if (capabilities.abiVersion != CryptoCoreProtocolV1.abiVersion ||
      capabilities.featureBits < 0 ||
      capabilities.maxInputBytes <= 0 ||
      capabilities.maxCborDepth <= 0 ||
      capabilities.maxCborItems <= 0 ||
      !capabilities.supportsRequiredFoundation) {
    return const Result<CryptoCoreCapabilities>.failure(
      SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  }
  return Result<CryptoCoreCapabilities>.success(capabilities);
}

Result<void> _decodeSelfTestReply(Object? reply) {
  if (reply is! List<Object?> || reply.isEmpty) {
    return const Result<void>.failure(
      SecurityFailure(SecurityFailureKind.policyBlocked),
    );
  }
  if (reply[0] == _replyFailure) {
    return Result<void>.failure(_decodeFailureReply(reply));
  }
  if (reply.length != 1 || reply[0] != _replySuccess) {
    return const Result<void>.failure(
      SecurityFailure(SecurityFailureKind.malformedServerResponse),
    );
  }
  return const Result<void>.success(null);
}

Failure _decodeFailureReply(List<Object?> reply) {
  if (reply.length != 3 || reply[1] is! int || reply[2] is! int) {
    return const SecurityFailure(SecurityFailureKind.malformedServerResponse);
  }
  final failureKind = reply[1]! as int;
  final detail = reply[2]! as int;
  switch (failureKind) {
    case _failureCryptoCore:
      final code = CryptoCoreFailureCode.fromWireValue(detail);
      return code == null
          ? const SecurityFailure(SecurityFailureKind.policyBlocked)
          : CryptoCoreFailure(code);
    case _failureUnsupportedProtocol:
      if (detail >= 0 &&
          detail < UnsupportedProtocolFailureKind.values.length) {
        return UnsupportedProtocolFailure(
          UnsupportedProtocolFailureKind.values[detail],
        );
      }
      break;
    case _failureSecurity:
      if (detail >= 0 && detail < SecurityFailureKind.values.length) {
        return SecurityFailure(SecurityFailureKind.values[detail]);
      }
      break;
  }
  return const SecurityFailure(SecurityFailureKind.policyBlocked);
}
