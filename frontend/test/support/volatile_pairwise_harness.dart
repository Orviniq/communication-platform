import 'package:communication_platform/core/application/ports/pairwise_session_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_opener.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_sealer.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/pairwise/infrastructure/native_pairwise_outbound_preparation.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// A stand-in for the native pairwise core, shared by every device of a test.
///
/// It keeps the shape the Dart side depends on and none of the cryptography:
/// an `EnvelopeV1` of one allowed bucket, a regular header naming its session
/// and message number, an initial header carrying its sender in the clear
/// where the real one seals it, the recipient device bound into the
/// ciphertext region where the real one binds it into the AEAD, a message
/// number that cannot be opened twice, and a skipped-key count that crosses
/// the bound. The real core is tested in Rust; this tests what Dart does with
/// it.
///
/// A session's opaque state is its send count, its receive count and its
/// remote device id.
final class FakeRatchetCrypto implements PairwiseSessionCryptoPort {
  static const buckets = [1024, 4096, 16384, 65536, 262144];
  static const regularHeaderBytes = 58;

  /// The regular header, then the sender's user, device and identity key,
  /// its registration id and bundle version, and two one-time prekey ids.
  static const initialHeaderBytes = regularHeaderBytes + 16 + 16 + 64 + 16;
  static const _flagInitial = 0x01;
  static const _flagRepairReplacement = 0x08;
  static const _absentPrekey = 0xffffffff;

  int encryptCalls = 0;
  int decryptCalls = 0;
  int initiateCalls = 0;

  /// The payload of a repair request, as the durable path would carry it.
  static final repairControl = Uint8List.fromList('CPRRV001'.codeUnits);

  /// The state a session begins with on either side.
  static Uint8List sessionState({
    required String remoteDeviceId,
    int sendCount = 0,
    int receiveCount = 0,
  }) => Uint8List.fromList([
    ..._u32(sendCount),
    ..._u32(receiveCount),
    ...protocolUuidBytes(remoteDeviceId),
  ]);

  /// A regular envelope as a peer holding [sessionId] would send it.
  static Uint8List regularEnvelope({
    required Uint8List sessionId,
    required int messageNumber,
    required String recipientDeviceId,
    required Uint8List inner,
  }) => _envelope(
    header: _regularHeader(sessionId, messageNumber),
    recipientDeviceId: recipientDeviceId,
    inner: inner,
  );

  /// An initial envelope from [senderDeviceId], naming its sender where the
  /// real header seals it.
  static Uint8List initialEnvelope({
    required Uint8List sessionId,
    required String senderUserId,
    required String senderDeviceId,
    required Uint8List senderIdentityPublic,
    required String recipientDeviceId,
    required Uint8List inner,
    int registrationId = 7,
    int bundleVersion = 1,
    int? oneTimePrekeyId,
    int? pqOneTimePrekeyId,
    bool repairReplacement = false,
  }) => _envelope(
    header: [
      1,
      _flagInitial | (repairReplacement ? _flagRepairReplacement : 0),
      ...sessionId,
      ...List<int>.filled(32, 0),
      ..._u32(0),
      ..._u32(0),
      ...protocolUuidBytes(senderUserId),
      ...protocolUuidBytes(senderDeviceId),
      ...senderIdentityPublic,
      ..._u32(registrationId),
      ..._u32(bundleVersion),
      ..._u32(oneTimePrekeyId ?? _absentPrekey),
      ..._u32(pqOneTimePrekeyId ?? _absentPrekey),
    ],
    recipientDeviceId: recipientDeviceId,
    inner: inner,
  );

  @override
  Future<Result<PairwisePublicHeaderInspection>> inspectPublicHeader({
    required Uint8List envelope,
  }) async {
    final parsed = _Parsed.of(envelope);
    if (parsed == null) {
      return _refused(CryptoCoreFailureCode.malformedInput);
    }
    return Result.success(
      PairwisePublicHeaderInspection(
        kind: parsed.initial
            ? PairwisePublicEnvelopeKind.initial
            : PairwisePublicEnvelopeKind.regular,
        sessionId: parsed.sessionId,
      ),
    );
  }

  @override
  Future<Result<PreparedPairwiseEnvelope>> encrypt({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List recipientDeviceId,
    required PairwiseSessionState session,
    required Uint8List innerPayload,
    required int otherSessionsSkippedKeys,
  }) async {
    encryptCalls += 1;
    final state = _State.of(session.opaqueState);
    if (state == null || !_same(state.remoteDevice, recipientDeviceId)) {
      return _refused(CryptoCoreFailureCode.stateViolation);
    }
    final envelope = _envelope(
      header: _regularHeader(session.sessionId, state.sendCount),
      recipientDeviceId: protocolUuidString(recipientDeviceId),
      inner: innerPayload,
    );
    if (envelope.length > buckets.last) {
      return _refused(CryptoCoreFailureCode.inputTooLarge);
    }
    return Result.success(
      PreparedPairwiseEnvelope(
        ciphertext: envelope,
        nextSession: PairwiseSessionState(
          sessionId: session.sessionId,
          opaqueState: state.copyWith(sendCount: state.sendCount + 1).bytes,
          skippedKeyCount: session.skippedKeyCount,
        ),
      ),
    );
  }

  @override
  Future<Result<PairwiseRatchetDecryptResult>> decrypt({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List recipientDeviceId,
    required PairwiseSessionState session,
    required Uint8List envelope,
    required int otherSessionsSkippedKeys,
  }) async {
    decryptCalls += 1;
    final parsed = _Parsed.of(envelope);
    final state = _State.of(session.opaqueState);
    if (parsed == null ||
        parsed.initial ||
        state == null ||
        !_same(parsed.sessionId, session.sessionId) ||
        !_same(parsed.recipientDevice, recipientDeviceId)) {
      return _refused(CryptoCoreFailureCode.authenticationFailed);
    }
    if (parsed.messageNumber < state.receiveCount) {
      // Behind the chain with no retained key: a replay.
      return _refused(CryptoCoreFailureCode.authenticationFailed);
    }
    final skipped =
        session.skippedKeyCount + parsed.messageNumber - state.receiveCount;
    if (skipped > PairwiseTransportV1.maximumSkippedKeysPerSession ||
        otherSessionsSkippedKeys + skipped >
            PairwiseTransportV1.maximumSkippedKeysPerAccount) {
      return Result.success(
        PairwiseRatchetRepairRequired(sessionId: session.sessionId),
      );
    }
    return Result.success(
      PairwiseRatchetDecryption(
        nextSession: PairwiseSessionState(
          sessionId: session.sessionId,
          opaqueState: state
              .copyWith(receiveCount: parsed.messageNumber + 1)
              .bytes,
          skippedKeyCount: skipped,
        ),
        openedPayload: parsed.inner,
        replayMarker: parsed.replayMarker,
        payloadKind: _startsWith(parsed.inner, repairControl)
            ? PairwiseOpenedPayloadKind.authenticatedRepairControl
            : PairwiseOpenedPayloadKind.opaque,
      ),
    );
  }

  @override
  Future<Result<PairwiseInitialSenderProjection>> probeInitial({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List recipientDeviceId,
    required Uint8List envelope,
  }) async {
    final parsed = _Parsed.of(envelope);
    if (parsed == null ||
        !parsed.initial ||
        !_same(parsed.recipientDevice, recipientDeviceId)) {
      return _refused(CryptoCoreFailureCode.authenticationFailed);
    }
    return Result.success(
      PairwiseInitialSenderProjection(
        senderUserId: parsed.senderUser!,
        senderDeviceId: parsed.senderDevice!,
        senderIdentityPublic: parsed.senderIdentity!,
        senderRegistrationId: parsed.registrationId!,
        senderBundleVersion: parsed.bundleVersion!,
        opaqueProbe: Uint8List(32),
        replacedSessionId: parsed.repairReplacement
            ? Uint8List.fromList(List.filled(16, 0xee))
            : null,
      ),
    );
  }

  @override
  Future<Result<AcceptedPairwiseInitial>> acceptVerifiedInitial({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List recipientDeviceId,
    required Uint8List envelope,
    required PairwiseInitialSenderProjection probe,
    required PeerPublicDevice authenticatedSenderDevice,
    required int otherSessionsSkippedKeys,
    PairwiseSessionState? existingPrimarySession,
    PairwiseSessionState? replacedSession,
  }) async {
    final parsed = _Parsed.of(envelope);
    if (parsed == null ||
        !parsed.initial ||
        !_same(parsed.recipientDevice, recipientDeviceId) ||
        !_same(
          parsed.senderIdentity!,
          authenticatedSenderDevice.identityPublic,
        )) {
      return _refused(CryptoCoreFailureCode.authenticationFailed);
    }
    if (existingPrimarySession != null) {
      // The real core allows this only for a session this device initiated;
      // the fake never initiates, so a second initial is refused.
      return _refused(CryptoCoreFailureCode.stateViolation);
    }
    return Result.success(
      AcceptedPairwiseInitial(
        nextDeviceState: Uint8List.fromList([...deviceState, 0x01]),
        nextSession: PairwiseSessionState(
          sessionId: parsed.sessionId,
          opaqueState: sessionState(
            remoteDeviceId: protocolUuidString(parsed.senderDevice!),
            receiveCount: 1,
          ),
          skippedKeyCount: 0,
        ),
        senderUserId: parsed.senderUser!,
        senderDeviceId: parsed.senderDevice!,
        openedPayload: parsed.inner,
        replayMarker: parsed.replayMarker,
        disposition: PairwiseSessionDisposition.primary,
        referencedSignedPrekeyId: 1,
        referencedPqSignedPrekeyId: 2,
        consumedOneTimePrekeyId: parsed.oneTimePrekeyId,
        consumedPqOneTimePrekeyId: parsed.pqOneTimePrekeyId,
      ),
    );
  }

  @override
  Future<Result<PreparedPairwiseEnvelope>> createAuthenticatedRepairRequest({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List recipientDeviceId,
    required PairwiseSessionState session,
    required int otherSessionsSkippedKeys,
  }) async {
    final state = _State.of(session.opaqueState)!;
    return Result.success(
      PreparedPairwiseEnvelope(
        ciphertext: _envelope(
          header: _regularHeader(session.sessionId, state.sendCount),
          recipientDeviceId: protocolUuidString(recipientDeviceId),
          inner: repairControl,
        ),
        nextSession: PairwiseSessionState(
          sessionId: session.sessionId,
          opaqueState: state.copyWith(sendCount: state.sendCount + 1).bytes,
          skippedKeyCount: session.skippedKeyCount,
        ),
      ),
    );
  }

  @override
  Future<Result<PairwiseInitiationResult>> initiate({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List senderDeviceId,
    required Uint8List recipientUserId,
    required Uint8List recipientDeviceId,
    required Uint8List recipientSelfSigningPublic,
    required ClaimedPrekeyBundle verifiedBundle,
    required Uint8List innerPayload,
    required int otherSessionsSkippedKeys,
    Uint8List? repairAuthorization,
  }) async {
    initiateCalls += 1;
    return _refused(CryptoCoreFailureCode.unsupportedOperation);
  }

  @override
  Future<Result<AuthenticatedRepairAuthorization>>
  consumeAuthenticatedRepairRequest({
    required Uint8List deviceState,
    required int unixDay,
    required PairwiseSessionState session,
  }) async => _refused(CryptoCoreFailureCode.unsupportedOperation);

  static Result<T> _refused<T>(CryptoCoreFailureCode code) =>
      Result.failure(CryptoCoreFailure(code));

  static List<int> _regularHeader(Uint8List sessionId, int messageNumber) => [
    1,
    0,
    ...sessionId,
    ...List<int>.filled(32, 0),
    ..._u32(0),
    ..._u32(messageNumber),
  ];

  static Uint8List _envelope({
    required List<int> header,
    required String recipientDeviceId,
    required List<int> inner,
  }) {
    final minimum = 4 + header.length + 16 + 4 + inner.length;
    final bucket = buckets.firstWhere(
      (value) => value >= minimum,
      orElse: () => minimum,
    );
    return Uint8List.fromList([
      1,
      1,
      header.length >> 8,
      header.length & 0xff,
      ...header,
      ...protocolUuidBytes(recipientDeviceId),
      ..._u32(inner.length),
      ...inner,
      ...List<int>.filled(bucket - minimum, 0),
    ]);
  }
}

final class _State {
  const _State(this.sendCount, this.receiveCount, this.remoteDevice);

  final int sendCount;
  final int receiveCount;
  final Uint8List remoteDevice;

  static _State? of(Uint8List bytes) {
    if (bytes.length != 24) {
      return null;
    }
    return _State(
      _readU32(bytes, 0),
      _readU32(bytes, 4),
      Uint8List.sublistView(bytes, 8, 24),
    );
  }

  _State copyWith({int? sendCount, int? receiveCount}) => _State(
    sendCount ?? this.sendCount,
    receiveCount ?? this.receiveCount,
    remoteDevice,
  );

  Uint8List get bytes => Uint8List.fromList([
    ..._u32(sendCount),
    ..._u32(receiveCount),
    ...remoteDevice,
  ]);
}

final class _Parsed {
  _Parsed({
    required this.initial,
    required this.repairReplacement,
    required this.sessionId,
    required this.messageNumber,
    required this.recipientDevice,
    required this.inner,
    required this.replayMarker,
    this.senderUser,
    this.senderDevice,
    this.senderIdentity,
    this.registrationId,
    this.bundleVersion,
    this.oneTimePrekeyId,
    this.pqOneTimePrekeyId,
  });

  final bool initial;
  final bool repairReplacement;
  final Uint8List sessionId;
  final int messageNumber;
  final Uint8List recipientDevice;
  final Uint8List inner;
  final Uint8List replayMarker;
  final Uint8List? senderUser;
  final Uint8List? senderDevice;
  final Uint8List? senderIdentity;
  final int? registrationId;
  final int? bundleVersion;
  final int? oneTimePrekeyId;
  final int? pqOneTimePrekeyId;

  static _Parsed? of(Uint8List envelope) {
    if (!FakeRatchetCrypto.buckets.contains(envelope.length) ||
        envelope[0] != 1 ||
        envelope[1] != 1) {
      return null;
    }
    final headerLength = (envelope[2] << 8) | envelope[3];
    final flags = envelope[5];
    final initial = flags & FakeRatchetCrypto._flagInitial != 0;
    if (headerLength !=
        (initial
            ? FakeRatchetCrypto.initialHeaderBytes
            : FakeRatchetCrypto.regularHeaderBytes)) {
      return null;
    }
    final header = Uint8List.sublistView(envelope, 4, 4 + headerLength);
    final body = 4 + headerLength;
    final innerLength = _readU32(envelope, body + 16);
    if (body + 20 + innerLength > envelope.length) {
      return null;
    }
    int? optional(int value) =>
        value == FakeRatchetCrypto._absentPrekey ? null : value;
    return _Parsed(
      initial: initial,
      repairReplacement: flags & FakeRatchetCrypto._flagRepairReplacement != 0,
      sessionId: Uint8List.fromList(header.sublist(2, 18)),
      messageNumber: _readU32(header, 54),
      recipientDevice: Uint8List.fromList(envelope.sublist(body, body + 16)),
      inner: Uint8List.fromList(
        envelope.sublist(body + 20, body + 20 + innerLength),
      ),
      replayMarker: Uint8List.fromList([
        ...header.sublist(2, 18),
        ..._u32(_readU32(header, 54)),
        ...List<int>.filled(12, 0xaa),
      ]),
      senderUser: initial ? Uint8List.fromList(header.sublist(58, 74)) : null,
      senderDevice: initial ? Uint8List.fromList(header.sublist(74, 90)) : null,
      senderIdentity: initial
          ? Uint8List.fromList(header.sublist(90, 154))
          : null,
      registrationId: initial ? _readU32(header, 154) : null,
      bundleVersion: initial ? _readU32(header, 158) : null,
      oneTimePrekeyId: initial ? optional(_readU32(header, 162)) : null,
      pqOneTimePrekeyId: initial ? optional(_readU32(header, 166)) : null,
    );
  }
}

/// Every account's authenticated live devices, answered from a map, or a
/// failure for an account named in [failures].
final class FakeLiveDevices implements PairwiseLiveDeviceResolverPort {
  FakeLiveDevices(this.devices, {Map<String, Failure>? failures})
    : failures = failures ?? {};

  final Map<String, List<VerifiedPairwiseLiveDevice>> devices;
  final Map<String, Failure> failures;
  final calls = <String>[];

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async {
    calls.add(userId);
    final failure = failures[userId];
    if (failure != null) {
      return Result.failure(failure);
    }
    return Result.success(devices[userId] ?? const []);
  }
}

final class FixedTime implements TimeSource {
  FixedTime([DateTime? now]) : _now = now ?? DateTime.utc(2026, 9, 30, 12);

  DateTime _now;

  @override
  DateTime now() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}

/// One device of a test: its own database, its own store, and the sealer and
/// opener built over them the way the application builds them.
final class VolatileDevice {
  VolatileDevice._({
    required this.userId,
    required this.deviceId,
    required this.database,
    required this.store,
  });

  static Future<VolatileDevice> open({
    required String userId,
    required String deviceId,
  }) async {
    final database = LocalDatabase(NativeDatabase.memory());
    await database
        .into(database.secureSecrets)
        .insert(
          SecureSecretsCompanion.insert(
            secretId: 'current-device-key-state-v1',
            kind: 0,
            wrappedCiphertextOrOpaqueHandle: Uint8List.fromList([1, 2, 3, 4]),
            formatVersion: 2,
          ),
        );
    return VolatileDevice._(
      userId: userId,
      deviceId: deviceId,
      database: database,
      store: DriftPairwiseTransportStore(database),
    );
  }

  final String userId;
  final String deviceId;
  final LocalDatabase database;
  final DriftPairwiseTransportStore store;

  PairwiseVolatileSealer sealer({
    required FakeRatchetCrypto crypto,
    required PairwiseLiveDeviceResolverPort liveDevices,
    TimeSource? clock,
  }) => PairwiseVolatileSealer(
    store: store,
    volatileStore: store,
    liveDevices: liveDevices,
    crypto: NativePairwiseOutboundPreparation(crypto),
    clock: clock ?? FixedTime(),
  );

  PairwiseVolatileOpener opener({
    required FakeRatchetCrypto crypto,
    required PairwiseLiveDeviceResolverPort liveDevices,
    TimeSource? clock,
  }) => PairwiseVolatileOpener(
    localDeviceId: deviceId,
    store: store,
    volatileStore: store,
    liveDevices: liveDevices,
    crypto: crypto,
    clock: clock ?? FixedTime(),
  );

  /// A ready primary session with [peer] under [sessionId], at revision 1.
  Future<void> holdSession({
    required String peerUserId,
    required String peerDeviceId,
    required Uint8List sessionId,
    int sendCount = 0,
    int receiveCount = 0,
    int stateVersion = 1,
    int repairState = 0,
  }) => database
      .into(database.pairwiseSessions)
      .insert(
        PairwiseSessionsCompanion.insert(
          localDeviceId: deviceId,
          remoteUserId: Value(peerUserId),
          remoteDeviceId: peerDeviceId,
          sessionId: Value(sessionId),
          opaqueCryptoStateHandle: FakeRatchetCrypto.sessionState(
            remoteDeviceId: peerDeviceId,
            sendCount: sendCount,
            receiveCount: receiveCount,
          ),
          stateVersion: stateVersion,
          repairState: Value(repairState),
        ),
      );

  Future<PairwiseSession?> sessionWith(String peerDeviceId) => (database.select(
    database.pairwiseSessions,
  )..where((row) => row.remoteDeviceId.equals(peerDeviceId))).getSingleOrNull();

  Future<void> close() => database.close();
}

/// A live device record for [deviceId], signed, with an identity key made of
/// [identity].
VerifiedPairwiseLiveDevice liveDevice(
  String userId,
  String deviceId, {
  int identity = 0x50,
}) => VerifiedPairwiseLiveDevice(
  userId: userId,
  device: PeerPublicDevice(
    deviceId: deviceId,
    identityPublic: Uint8List.fromList(List.filled(64, identity)),
    registrationId: 7,
    bundleVersion: 1,
    crossSignature: Uint8List.fromList(List.filled(64, 0x5c)),
  ),
  selfSigningPublic: Uint8List.fromList(List.filled(32, 0x5d)),
);

String testUuid(int value) =>
    '00000000-0000-4000-8000-${value.toRadixString(16).padLeft(12, '0')}';

Uint8List filled(int length, int value) =>
    Uint8List.fromList(List<int>.filled(length, value & 0xff));

List<int> _u32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

int _readU32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

bool _startsWith(List<int> bytes, List<int> prefix) =>
    bytes.length >= prefix.length &&
    _same(bytes.sublist(0, prefix.length), prefix);
