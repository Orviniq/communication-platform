import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/device_control_crypto_port.dart';
import 'package:communication_platform/core/application/ports/pairwise_session_crypto_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/protocol/pairwise_crypto_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/group_inbound_coordinator.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:communication_platform/features/synchronization/infrastructure/pairwise_opaque_envelope_inspector.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/application/room_inbound_coordinator.dart';

import 'application_event_harness.dart';
import 'local_send_harness.dart';
import 'volatile_pairwise_harness.dart';

/// One receiving device, its real inbox and pairwise stores, and the real
/// inspector, over the fake ratchet of [FakeRatchetCrypto] (ADR-093).
///
/// The peer sends direct messages: an initial envelope on a new session, then
/// regular envelopes on it. Whether the peer is verified is a switch.
final class HeldInboundHarness {
  HeldInboundHarness._(this.device, this.clock)
    : sync = DriftSyncStore(device.database),
      senders = InboundSenders(),
      crypto = CountingRatchet(FakeRatchetCrypto()),
      protocol = DecodedEvents();

  static Future<HeldInboundHarness> open(TimeSource clock) async =>
      HeldInboundHarness._(
        await VolatileDevice.open(userId: localUserId, deviceId: localDeviceId),
        clock,
      );

  static final session = Uint8List.fromList(List<int>.filled(16, 0x5e));
  static final peerIdentity = Uint8List.fromList(List<int>.filled(64, 0x42));

  final VolatileDevice device;
  final TimeSource clock;
  final DriftSyncStore sync;
  final InboundSenders senders;
  final CountingRatchet crypto;
  final DecodedEvents protocol;

  late final PairwiseOpaqueEnvelopeInspector inspector =
      PairwiseOpaqueEnvelopeInspector(
        localDeviceId: localDeviceId,
        store: device.store,
        liveDevices: senders,
        crypto: crypto,
        applicationProtocol: protocol,
        deviceControlCrypto: const _Unused(),
        conversationResolver: const DirectConversations(),
        currentUserId: localUserId,
        clock: clock,
        groupInbound: GroupInboundCoordinator(
          repository: const _UnusedGroups(),
          crypto: const _UnusedGroups(),
          liveDevices: const _UnusedGroups(),
          clock: clock,
          localUserId: localUserId,
        ),
        roomInbound: RoomInboundCoordinator(
          repository: const _UnusedRooms(),
          crypto: const _UnusedRooms(),
          liveDevices: const _UnusedRooms(),
          clock: clock,
          localUserId: localUserId,
        ),
        heldSessions: sync,
      );

  /// The peer's [index]th direct message, as its opened payload.
  Uint8List message(int index) {
    final commit = applicationCommit(
      eventId: sequentialId(index),
      kind: ApplicationEventKind.messageCreate,
      senderUser: peerUserId,
      senderDevice: peerDeviceId,
      counter: index,
      body: MessageCreateBody(
        messageId: sequentialId(1000 + index),
        text: 'message $index',
      ),
    );
    final inner = Uint8List.fromList([0xd1, ...sequentialId(index)]);
    protocol.events[protocolBytesToHex(inner)] = SupportedApplicationEvent(
      event: commit.event,
      canonicalBytes: commit.canonicalBytes,
    );
    return inner;
  }

  /// The session's first envelope, carrying message [index].
  Uint8List initial(
    int index, {
    int registrationId = 7,
    Uint8List? identity,
    String senderDeviceId = peerDeviceId,
    bool repairReplacement = false,
  }) => FakeRatchetCrypto.initialEnvelope(
    sessionId: session,
    senderUserId: peerUserId,
    senderDeviceId: senderDeviceId,
    senderIdentityPublic: identity ?? peerIdentity,
    recipientDeviceId: localDeviceId,
    inner: message(index),
    registrationId: registrationId,
    repairReplacement: repairReplacement,
  );

  /// A later envelope of the session, carrying message [index] as its
  /// [messageNumber]th.
  Uint8List followUp(int index, {required int messageNumber}) =>
      FakeRatchetCrypto.regularEnvelope(
        sessionId: session,
        messageNumber: messageNumber,
        recipientDeviceId: localDeviceId,
        inner: message(index),
      );

  Future<void> close() => device.close();
}

/// The peer's public device, and whether this account has verified it.
final class InboundSenders implements PairwiseLiveDeviceResolverPort {
  bool verified = false;
  Failure? failure;
  final List<String> inboundCalls = [];
  final List<String> verifiedCalls = [];

  PeerPublicDevice get device => PeerPublicDevice(
    deviceId: peerDeviceId,
    identityPublic: HeldInboundHarness.peerIdentity,
    registrationId: 7,
    bundleVersion: 1,
    crossSignature: Uint8List(64),
  );

  List<VerifiedPairwiseLiveDevice> _verified(String userId) => [
    VerifiedPairwiseLiveDevice(
      userId: userId,
      device: device,
      selfSigningPublic: Uint8List(32),
    ),
  ];

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async {
    verifiedCalls.add(userId);
    if (failure case final failure?) {
      return Result.failure(failure);
    }
    if (!verified) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    return Result.success(_verified(userId));
  }

  @override
  Future<Result<Map<String, List<VerifiedPairwiseLiveDevice>>>>
  resolveVerifiedLiveDevicesForUsers(List<String> userIds) =>
      throw UnimplementedError();

  @override
  Future<Result<InboundSenderResolution>> resolveInboundSender(
    String userId,
  ) async {
    inboundCalls.add(userId);
    if (failure case final failure?) {
      return Result.failure(failure);
    }
    return Result.success(
      verified
          ? VerifiedInboundSender(_verified(userId))
          : UnverifiedInboundSender(userId: userId, devices: [device]),
    );
  }
}

/// The fake ratchet, with every acceptance counted.
final class CountingRatchet implements PairwiseSessionCryptoPort {
  CountingRatchet(this.inner);

  final FakeRatchetCrypto inner;
  int accepted = 0;

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
  }) {
    accepted += 1;
    return inner.acceptVerifiedInitial(
      deviceState: deviceState,
      unixDay: unixDay,
      recipientDeviceId: recipientDeviceId,
      envelope: envelope,
      probe: probe,
      authenticatedSenderDevice: authenticatedSenderDevice,
      otherSessionsSkippedKeys: otherSessionsSkippedKeys,
      existingPrimarySession: existingPrimarySession,
      replacedSession: replacedSession,
    );
  }

  @override
  Future<Result<PairwisePublicHeaderInspection>> inspectPublicHeader({
    required Uint8List envelope,
  }) => inner.inspectPublicHeader(envelope: envelope);

  @override
  Future<Result<PairwiseInitialSenderProjection>> probeInitial({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List recipientDeviceId,
    required Uint8List envelope,
  }) => inner.probeInitial(
    deviceState: deviceState,
    unixDay: unixDay,
    recipientDeviceId: recipientDeviceId,
    envelope: envelope,
  );

  @override
  Future<Result<PairwiseRatchetDecryptResult>> decrypt({
    required Uint8List deviceState,
    required int unixDay,
    required Uint8List recipientDeviceId,
    required PairwiseSessionState session,
    required Uint8List envelope,
    required int otherSessionsSkippedKeys,
  }) => inner.decrypt(
    deviceState: deviceState,
    unixDay: unixDay,
    recipientDeviceId: recipientDeviceId,
    session: session,
    envelope: envelope,
    otherSessionsSkippedKeys: otherSessionsSkippedKeys,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Decodes the payloads [HeldInboundHarness.message] made.
final class DecodedEvents implements ApplicationProtocolPort {
  final Map<String, SupportedApplicationEvent> events = {};

  @override
  Future<Result<DecodedApplicationEvent>> decode(Uint8List bytes) async {
    final event = events[protocolBytesToHex(bytes)];
    return event == null
        ? const Result.failure(
            SecurityFailure(SecurityFailureKind.unauthenticatedInput),
          )
        : Result.success(event);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Every event names the direct conversation with its sender.
final class DirectConversations implements ApplicationConversationResolverPort {
  const DirectConversations();

  @override
  Future<Result<ResolvedApplicationConversation>> resolve({
    required ApplicationEventRecord event,
    required String currentUserId,
  }) async => const Result.success(
    ResolvedApplicationConversation(
      kind: ConversationKind.direct,
      peerUserId: peerUserId,
    ),
  );
}

/// Every port a direct message never reaches.
final class _Unused implements DeviceControlCryptoPort {
  const _Unused();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _UnusedGroups
    implements
        GroupRepositoryPort,
        GroupControlCryptoPort,
        GroupLiveDeviceResolverPort {
  const _UnusedGroups();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _UnusedRooms
    implements
        RoomRepositoryPort,
        RoomControlCryptoPort,
        RoomLiveDeviceResolverPort {
  const _UnusedRooms();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
