import 'dart:typed_data';

/// Frozen Android v1 native pairwise-operation registry.
///
/// Dart treats the operation payload and returned state as opaque. The reviewed Rust
/// core owns all cryptographic framing, key derivation, authentication, and secret
/// state parsing.
enum PairwiseCryptoOperation {
  upgradeDeviceState(1),
  prepareReplenishment(2),
  commitPendingUpload(3),
  prepareSignedPrekeyRotation(4),
  pruneRetainedSignedPrekeys(5),
  initiate(10),
  probeInitial(11),
  acceptVerifiedInitial(12),
  ratchetEncrypt(13),
  ratchetDecrypt(14),
  createAuthenticatedRepairRequest(15),
  consumeAuthenticatedRepairRequest(16),
  inspectPublicHeader(17),
  sealGroupControl(18),
  openGroupControl(19);

  const PairwiseCryptoOperation(this.wireValue);

  final int wireValue;
}

enum PairwiseCryptoOutcome { ok, repairRequired }

/// Strictly authenticated native result. [body] excludes the native response prefix.
final class PairwiseCryptoResponse {
  PairwiseCryptoResponse({
    required this.operation,
    required this.outcome,
    required Uint8List body,
  }) : body = Uint8List.fromList(body);

  final PairwiseCryptoOperation operation;
  final PairwiseCryptoOutcome outcome;
  final Uint8List body;

  bool get mutatesState => outcome == PairwiseCryptoOutcome.ok;

  @override
  String toString() =>
      'PairwiseCryptoResponse(operation: ${operation.name}, '
      'outcome: ${outcome.name}, body: <redacted>)';
}

abstract final class PairwiseTransportV1 {
  static const int protocolVersion = 1;
  static const int suite = 1;
  static const String purpose = 'pairwise-transport-v1';
  static const int maximumSkippedKeysPerSession = 2000;
  static const int maximumSkippedKeysPerAccount = 20000;
  static const Set<int> envelopeBuckets = {1024, 4096, 16384, 65536, 262144};
}

enum PairwisePublicEnvelopeKind { regular, initial }

/// Untrusted native-parsed routing hint. Decrypt/probe must still authenticate it.
final class PairwisePublicHeaderInspection {
  PairwisePublicHeaderInspection({
    required this.kind,
    required Uint8List sessionId,
  }) : sessionId = _copyExact(sessionId, 16);

  final PairwisePublicEnvelopeKind kind;
  final Uint8List sessionId;
}

/// Durable authenticated Double Ratchet state. Its bytes stay opaque to Dart.
final class PairwiseSessionState {
  PairwiseSessionState({
    required Uint8List sessionId,
    required Uint8List opaqueState,
    required this.skippedKeyCount,
  }) : sessionId = _copyExact(sessionId, 16),
       opaqueState = _copyBounded(opaqueState) {
    if (skippedKeyCount < 0 ||
        skippedKeyCount > PairwiseTransportV1.maximumSkippedKeysPerSession) {
      throw const PairwiseCryptoFormatException();
    }
  }

  final Uint8List sessionId;
  final Uint8List opaqueState;
  final int skippedKeyCount;

  @override
  String toString() => 'PairwiseSessionState(<redacted>)';
}

/// Prepared send result. This exact ciphertext must be durably reused on retry.
final class PreparedPairwiseEnvelope {
  PreparedPairwiseEnvelope({
    required Uint8List ciphertext,
    required this.nextSession,
  }) : ciphertext = _copyEnvelope(ciphertext);

  final Uint8List ciphertext;
  final PairwiseSessionState nextSession;

  @override
  String toString() => 'PreparedPairwiseEnvelope(<redacted>)';
}

/// Public sender projection returned by the side-effect-free initial probe.
final class PairwiseInitialSenderProjection {
  PairwiseInitialSenderProjection({
    required Uint8List senderUserId,
    required Uint8List senderDeviceId,
    required Uint8List senderIdentityPublic,
    required this.senderRegistrationId,
    required this.senderBundleVersion,
    required Uint8List opaqueProbe,
    Uint8List? replacedSessionId,
  }) : senderUserId = _copyExact(senderUserId, 16),
       senderDeviceId = _copyExact(senderDeviceId, 16),
       senderIdentityPublic = _copyExact(senderIdentityPublic, 64),
       opaqueProbe = _copyExact(opaqueProbe, 32),
       replacedSessionId = replacedSessionId == null
           ? null
           : _copyExact(replacedSessionId, 16) {
    if (senderRegistrationId < 0 ||
        senderRegistrationId > 0xffffffff ||
        senderBundleVersion <= 0 ||
        senderBundleVersion > 0xffffffff) {
      throw const PairwiseCryptoFormatException();
    }
  }

  final Uint8List senderUserId;
  final Uint8List senderDeviceId;
  final Uint8List senderIdentityPublic;
  final int senderRegistrationId;
  final int senderBundleVersion;
  final Uint8List opaqueProbe;
  final Uint8List? replacedSessionId;

  bool get isRepairReplacement => replacedSessionId != null;

  @override
  String toString() => 'PairwiseInitialSenderProjection(<redacted>)';
}

sealed class PairwiseReceiveResult {
  const PairwiseReceiveResult();
}

final class PairwiseReceiveSuccess extends PairwiseReceiveResult {
  PairwiseReceiveSuccess({
    required this.nextSession,
    required Uint8List openedPayload,
    required Uint8List replayMarker,
    Uint8List? nextDeviceState,
    this.consumedOneTimePrekeyId,
    this.consumedPqOneTimePrekeyId,
  }) : openedPayload = Uint8List.fromList(openedPayload),
       replayMarker = _copyBounded(replayMarker),
       nextDeviceState = nextDeviceState == null
           ? null
           : _copyBounded(nextDeviceState) {
    if (!_validOptionalKeyId(consumedOneTimePrekeyId) ||
        !_validOptionalKeyId(consumedPqOneTimePrekeyId)) {
      throw const PairwiseCryptoFormatException();
    }
  }

  final PairwiseSessionState nextSession;
  final Uint8List openedPayload;
  final Uint8List replayMarker;
  final Uint8List? nextDeviceState;
  final int? consumedOneTimePrekeyId;
  final int? consumedPqOneTimePrekeyId;

  @override
  String toString() => 'PairwiseReceiveSuccess(<redacted>)';
}

/// Native bound crossing. No ratchet/device state may be committed for this result.
final class PairwiseRepairRequired extends PairwiseReceiveResult {
  PairwiseRepairRequired({required Uint8List sessionId})
    : sessionId = _copyExact(sessionId, 16);

  final Uint8List sessionId;

  @override
  String toString() => 'PairwiseRepairRequired(<redacted>)';
}

enum SimultaneousInitiationPriority { smallerInitiator, largerInitiator }

enum PairwiseSessionDisposition { primary, receiveOnlyAlternate }

enum PairwiseOpenedPayloadKind { opaque, authenticatedRepairControl }

final class PairwiseInitiationResult {
  const PairwiseInitiationResult({
    required this.prepared,
    required this.priority,
  });

  final PreparedPairwiseEnvelope prepared;
  final SimultaneousInitiationPriority priority;
}

final class AcceptedPairwiseInitial {
  AcceptedPairwiseInitial({
    required Uint8List nextDeviceState,
    required this.nextSession,
    required Uint8List senderUserId,
    required Uint8List senderDeviceId,
    required Uint8List openedPayload,
    required Uint8List replayMarker,
    required this.disposition,
    required this.referencedSignedPrekeyId,
    required this.referencedPqSignedPrekeyId,
    this.consumedOneTimePrekeyId,
    this.consumedPqOneTimePrekeyId,
    Uint8List? replacedSessionId,
    this.updatedExistingSession,
  }) : nextDeviceState = _copyBounded(nextDeviceState),
       senderUserId = _copyExact(senderUserId, 16),
       senderDeviceId = _copyExact(senderDeviceId, 16),
       openedPayload = Uint8List.fromList(openedPayload),
       replayMarker = _copyExact(replayMarker, 32),
       replacedSessionId = replacedSessionId == null
           ? null
           : _copyExact(replacedSessionId, 16) {
    if (!_validOptionalKeyId(consumedOneTimePrekeyId) ||
        !_validOptionalKeyId(consumedPqOneTimePrekeyId) ||
        !_validRequiredKeyId(referencedSignedPrekeyId) ||
        !_validRequiredKeyId(referencedPqSignedPrekeyId)) {
      throw const PairwiseCryptoFormatException();
    }
  }

  final Uint8List nextDeviceState;
  final PairwiseSessionState nextSession;
  final Uint8List senderUserId;
  final Uint8List senderDeviceId;
  final Uint8List openedPayload;
  final Uint8List replayMarker;
  final PairwiseSessionDisposition disposition;
  final int referencedSignedPrekeyId;
  final int referencedPqSignedPrekeyId;
  final int? consumedOneTimePrekeyId;
  final int? consumedPqOneTimePrekeyId;
  final Uint8List? replacedSessionId;
  final PairwiseSessionState? updatedExistingSession;

  @override
  String toString() => 'AcceptedPairwiseInitial(<redacted>)';
}

sealed class PairwiseRatchetDecryptResult {
  const PairwiseRatchetDecryptResult();
}

final class PairwiseRatchetDecryption extends PairwiseRatchetDecryptResult {
  PairwiseRatchetDecryption({
    required this.nextSession,
    required Uint8List openedPayload,
    required Uint8List replayMarker,
    required this.payloadKind,
    this.referencedSignedPrekeyId,
    this.referencedPqSignedPrekeyId,
  }) : openedPayload = Uint8List.fromList(openedPayload),
       replayMarker = _copyExact(replayMarker, 32) {
    if (!_validOptionalKeyId(referencedSignedPrekeyId) ||
        !_validOptionalKeyId(referencedPqSignedPrekeyId) ||
        (referencedSignedPrekeyId == null) !=
            (referencedPqSignedPrekeyId == null)) {
      throw const PairwiseCryptoFormatException();
    }
  }

  final PairwiseSessionState nextSession;
  final Uint8List openedPayload;
  final Uint8List replayMarker;
  final PairwiseOpenedPayloadKind payloadKind;
  final int? referencedSignedPrekeyId;
  final int? referencedPqSignedPrekeyId;

  @override
  String toString() => 'PairwiseRatchetDecryption(<redacted>)';
}

final class PairwiseRatchetRepairRequired extends PairwiseRatchetDecryptResult {
  PairwiseRatchetRepairRequired({required Uint8List sessionId})
    : sessionId = _copyExact(sessionId, 16);

  final Uint8List sessionId;

  @override
  String toString() => 'PairwiseRatchetRepairRequired(<redacted>)';
}

final class AuthenticatedRepairAuthorization {
  AuthenticatedRepairAuthorization({
    required this.nextSession,
    required Uint8List authorization,
  }) : authorization = _copyExact(authorization, 88);

  final PairwiseSessionState nextSession;
  final Uint8List authorization;

  @override
  String toString() => 'AuthenticatedRepairAuthorization(<redacted>)';
}

final class PairwiseCryptoFormatException implements Exception {
  const PairwiseCryptoFormatException();
}

Uint8List _copyExact(Uint8List value, int expectedLength) {
  if (value.length != expectedLength) {
    throw const PairwiseCryptoFormatException();
  }
  return Uint8List.fromList(value);
}

Uint8List _copyBounded(Uint8List value) {
  if (value.isEmpty || value.length > 2 * 1024 * 1024) {
    throw const PairwiseCryptoFormatException();
  }
  return Uint8List.fromList(value);
}

Uint8List _copyEnvelope(Uint8List value) {
  if (!PairwiseTransportV1.envelopeBuckets.contains(value.length)) {
    throw const PairwiseCryptoFormatException();
  }
  return Uint8List.fromList(value);
}

bool _validOptionalKeyId(int? value) =>
    value == null || _validRequiredKeyId(value);

bool _validRequiredKeyId(int value) => value >= 0 && value <= 0x7fffffff;
