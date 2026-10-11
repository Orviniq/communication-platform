import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/application_protocol_port.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/conversation_use_cases.dart';
import 'package:communication_platform/features/messaging/application/ports/attachment_sweep_port.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/messaging/infrastructure/drift_conversation_domain_repository.dart';
import 'package:communication_platform/features/messaging/infrastructure/pairwise_application_fanout_adapter.dart';
import 'package:communication_platform/features/messaging/infrastructure/pairwise_send_preparation_adapter.dart';
import 'package:communication_platform/features/messaging/presentation/chat_view_models.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_fanout_coordinator.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/drift_pairwise_transport_store.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/synchronization/infrastructure/drift_sync_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/local_send_harness.dart';

/// That the bubble is there before anything has been asked of the network.
///
/// The seam held open here is the authenticated device lookup — the first
/// network call a send used to make, and the one whose two round trips the user
/// was waiting behind. It is held with a completer rather than a delay, so the
/// assertions below are about ordering and not about timing: while this test
/// asserts, the fan-out is provably still inside that call.
void main() {
  late LocalDatabase database;
  late DriftPairwiseTransportStore transport;
  late _HeldLiveDevices liveDevices;
  late PairwiseFanoutCoordinator coordinator;
  late SendConversationEvents sender;

  setUp(() async {
    database = LocalDatabase(NativeDatabase.memory());
    transport = DriftPairwiseTransportStore(database);
    liveDevices = _HeldLiveDevices();
    coordinator = PairwiseFanoutCoordinator(
      store: transport,
      liveDevices: liveDevices,
      claims: _Claims(),
      crypto: _RecordingCrypto(),
      clock: const _Clock(),
    );
    sender = SendConversationEvents(
      repository: DriftConversationDomainRepository(database),
      protocol: _FixedProtocol(),
      fanout: PairwiseApplicationFanoutAdapter(coordinator),
      clock: const _Clock(),
      attachments: const _NoSweep(),
    );
    await seedDeviceState(database);
  });

  tearDown(() => database.close());

  test(
    'the row is on the timeline before a single device is resolved',
    () async {
      final repository = DriftConversationDomainRepository(database);

      final sent = await sender.sendText(
        currentUserId: localUserId,
        currentDeviceId: localDeviceId,
        target: const DirectConversationTarget(peerUserId),
        text: 'good morning',
      );

      // Not one lookup, and the send has already returned. There is no waiting
      // here at all: this is the state of the world at the moment the composer
      // hands back.
      expect(sent, isA<Success<SendMessageOutcome>>());
      expect(liveDevices.calls, isEmpty);
      expect(
        (sent as Success<SendMessageOutcome>).value.transportState,
        MessageTransportState.preparing,
      );

      final conversationId = protocolBytesToHex(sent.value.conversationId);
      final visible = await repository
          .watchMessages(
            currentUserId: localUserId,
            conversationId: conversationId,
            window: const NewestConversationMessages(80),
          )
          .first;
      expect(visible.messages, hasLength(1));
      expect(visible.messages.single.text, 'good morning');
      expect(
        visible.messages.single.transportState,
        MessageTransportState.preparing,
      );
      // And what the chat page would draw for it: the state the timeline has
      // always had a label for and never been given.
      expect(
        ChatDeliveryViewState.encrypting,
        _deliveryFor(visible.messages.single),
        reason: 'a message being sealed reads as encrypting',
      );

      // Now the fan-out, held inside its first network call.
      final owed = await DriftSyncStore(
        database,
      ).beginNextSendPreparation(now: DateTime.utc(2026));
      final work = (owed as Success<PendingSendPreparation?>).value!;
      final preparation = PairwiseSendPreparationAdapter(
        coordinator,
      ).prepare(work);
      await liveDevices.entered.future;

      final duringFanout = await repository
          .watchMessages(
            currentUserId: localUserId,
            conversationId: conversationId,
            window: const NewestConversationMessages(80),
          )
          .first;
      expect(duringFanout.messages.single.text, 'good morning');
      expect(
        duringFanout.messages.single.transportState,
        MessageTransportState.preparing,
      );
      expect(await database.select(database.outboxOperations).get(), isEmpty);

      liveDevices.release();
      expect(await preparation, isA<Success<void>>());

      final afterFanout = await repository
          .watchMessages(
            currentUserId: localUserId,
            conversationId: conversationId,
            window: const NewestConversationMessages(80),
          )
          .first;
      expect(
        afterFanout.messages.single.transportState,
        MessageTransportState.queued,
      );
      expect(
        await database.select(database.pendingSendPreparations).get(),
        isEmpty,
      );
      expect(
        await database.select(database.outboxOperations).get(),
        hasLength(1),
      );
    },
  );
}

ChatDeliveryViewState _deliveryFor(ConversationMessage message) =>
    switch (message.transportState) {
      MessageTransportState.preparing => ChatDeliveryViewState.encrypting,
      MessageTransportState.queued => ChatDeliveryViewState.queued,
      _ => ChatDeliveryViewState.localOnly,
    };

/// Resolves nothing until it is told to, and says when it was first asked.
final class _HeldLiveDevices implements PairwiseLiveDeviceResolverPort {
  final List<String> calls = [];
  final Completer<void> entered = Completer<void>();
  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }

  @override
  Future<Result<List<VerifiedPairwiseLiveDevice>>> resolveVerifiedLiveDevices(
    String userId,
  ) async {
    calls.add(userId);
    if (!entered.isCompleted) {
      entered.complete();
    }
    await _gate.future;
    return Result.success(_devicesOf(userId));
  }

  @override
  Future<Result<Map<String, List<VerifiedPairwiseLiveDevice>>>>
  resolveVerifiedLiveDevicesForUsers(List<String> userIds) async {
    calls.addAll(userIds);
    if (!entered.isCompleted) {
      entered.complete();
    }
    await _gate.future;
    return Result.success({
      for (final userId in userIds) userId: _devicesOf(userId),
    });
  }

  List<VerifiedPairwiseLiveDevice> _devicesOf(String userId) => [
    if (userId == peerUserId)
      _live(peerUserId, peerDeviceId, 1)
    else
      _live(localUserId, localDeviceId, 2),
  ];
}

VerifiedPairwiseLiveDevice _live(String userId, String deviceId, int seed) =>
    VerifiedPairwiseLiveDevice(
      userId: userId,
      device: PeerPublicDevice(
        deviceId: deviceId,
        identityPublic: seededBytes(seed, 64),
        registrationId: 0,
        bundleVersion: 1,
        crossSignature: seededBytes(seed + 1, 64),
      ),
      selfSigningPublic: seededBytes(seed + 2, 32),
    );

final class _RecordingCrypto implements PairwiseOutboundPreparationPort {
  @override
  Future<Result<PairwisePreparedOutbound>> prepareOutbound({
    required String currentDeviceId,
    required VerifiedPairwiseLiveDevice recipient,
    required Uint8List openedOpaquePayload,
    required int migrationUnixDay,
    required PairwisePreparationContext context,
    required VerifiedPairwiseClaim? claim,
  }) async => Result.success(
    PairwisePreparedOutbound(
      sessionId: seededBytes(7, 16),
      exactCiphertext: Uint8List(1024),
      nextOpaqueSessionState: seededBytes(8, 32),
      nextSkippedKeyCount: 0,
      disposition: PairwiseSessionDisposition.primaryBidirectional,
      repairState: PairwiseRepairState.ready,
    ),
  );
}

/// Claims exactly what it is asked for, and reports the live set it saw.
final class _Claims implements PairwiseSelectiveClaimPort {
  @override
  Future<Result<VerifiedPairwiseClaims>> claimVerifiedDevices({
    required String userId,
    required List<String> deviceIds,
  }) async {
    final device = _live(peerUserId, peerDeviceId, 1);
    return Result.success(
      VerifiedPairwiseClaims(
        liveDevices: [device],
        claims: {
          for (final deviceId in deviceIds)
            deviceId: VerifiedPairwiseClaim(
              device: device,
              bundle: ClaimedPrekeyBundle(
                deviceId: deviceId,
                registrationId: 1,
                identityPublic: seededBytes(1, 64),
                signedPrekeyId: 1,
                signedPrekeyPublic: seededBytes(2, 32),
                signedPrekeySignature: seededBytes(3, 64),
                crossSignature: seededBytes(4, 64),
                bundleVersion: 1,
                pqSignedPrekeyId: 2,
                pqSignedPrekeyPublic: seededBytes(5, 1184),
                pqSignedPrekeySignature: seededBytes(6, 64),
              ),
            ),
        },
      ),
    );
  }
}

/// A protocol that encodes deterministically and reaches nothing native.
final class _FixedProtocol implements ApplicationProtocolPort {
  int next = 40;

  @override
  Future<Result<Uint8List>> encode(ApplicationEventRecord event) async =>
      Result.success(seededBytes(96, 96));

  @override
  Future<Result<DecodedApplicationEvent>> decode(Uint8List bytes) async =>
      const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );

  @override
  Future<Result<Uint8List>> deriveDirectConversationId({
    required Uint8List firstUserId,
    required Uint8List secondUserId,
  }) async => Result.success(seededBytes(9, 32));

  @override
  Future<Result<Uint8List>> deriveSavedConversationId(Uint8List userId) async =>
      Result.success(seededBytes(11, 32));

  @override
  Future<Result<Uint8List>> generateEventId() async =>
      Result.success(seededBytes(next++, 16));
}

final class _Clock implements TimeSource {
  const _Clock();

  @override
  DateTime now() =>
      DateTime.fromMillisecondsSinceEpoch(1700000100000, isUtc: true);
}

final class _NoSweep implements AttachmentSweepPort {
  const _NoSweep();

  @override
  Future<void> sweepAfterDeletion() async {}
}
