import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/dependencies/sync_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_providers.dart';
import 'package:communication_platform/app/dependencies/voice_screen_providers.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/synchronization/domain/sync_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the voice screens read beside the room and the call: the mirror the
/// shell follows, whether voice may be offered, and whether the signalling's
/// connection is up.
void main() {
  const roomId =
      'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00';
  const peer = VoiceCallParticipant(
    userId: 'a0000001-0000-4000-8000-00000000a001',
    deviceId: 'd0000001-0000-4000-8000-00000000d001',
    status: VoiceParticipantStatus.connected,
  );

  ServerConfig limits({required bool voiceConfigured}) => ServerConfig(
    envelopeTtlDays: 7,
    attachmentTtlDays: 30,
    attachmentDailyBytes: 268435456,
    mailboxMaxBytes: 33554432,
    maxDevicesPerUser: 10,
    maxDeviceLogRecords: 10000,
    sessionTokenDays: 30,
    sendBatchMax: 256,
    ackMax: 200,
    drainPageMax: 100,
    claimMax: 100,
    envelopeBuckets: const {1024, 4096, 16384, 65536, 262144},
    attachmentBuckets: const {65536, 262144, 1048576},
    signalBuckets: const {1024, 4096, 16384},
    voiceConfigured: voiceConfigured,
    fromDeployment: true,
  );

  test('the mirror follows the call, and a 503 latches for the process', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final mirror = container.read(voiceCallMirrorProvider.notifier);

    expect(container.read(voiceCallMirrorProvider).roomId, isNull);

    mirror.follow(
      VoiceCallState(
        phase: VoiceCallPhase.inCall,
        roomId: roomId,
        participants: [peer],
        muted: true,
      ),
    );
    var call = container.read(voiceCallMirrorProvider);
    expect(call.roomId, roomId);
    expect(call.devices, 2);
    expect(call.muted, isTrue);

    mirror.follow(
      VoiceCallState(
        phase: VoiceCallPhase.ended,
        roomId: roomId,
        endReason: VoiceCallEndReason.left,
      ),
    );
    call = container.read(voiceCallMirrorProvider);
    expect(call.roomId, isNull);
    expect(call.devices, 0);
    expect(call.muted, isFalse);
    expect(call.voiceRefusedByServer, isFalse);

    mirror
      ..follow(
        VoiceCallState(
          phase: VoiceCallPhase.ended,
          roomId: roomId,
          endReason: VoiceCallEndReason.voiceUnavailable,
        ),
      )
      ..follow(VoiceCallState.idle());
    expect(
      container.read(voiceCallMirrorProvider).voiceRefusedByServer,
      isTrue,
      reason: 'no retry can fill an empty relay list',
    );
  });

  test('voice is offered only while the deployment serves it and no join '
      'has met 503', () {
    for (final configured in [true, false]) {
      final container = ProviderContainer(
        overrides: [
          publishedLimitsProvider.overrideWithValue(
            limits(voiceConfigured: configured),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(voiceAvailabilityProvider), configured);

      container
          .read(voiceCallMirrorProvider.notifier)
          .follow(
            VoiceCallState(
              phase: VoiceCallPhase.ended,
              roomId: roomId,
              endReason: VoiceCallEndReason.voiceUnavailable,
            ),
          );
      expect(container.read(voiceAvailabilityProvider), isFalse);
    }
  });

  test('the signalling counts as up only while the delivery session is online '
      'or draining', () async {
    for (final phase in SyncConnectionPhase.values) {
      final container = ProviderContainer(
        overrides: [
          syncProjectionProvider.overrideWith(
            (ref) => Stream.value(
              SyncProjection(
                connectionPhase: phase,
                queueGapState: QueueGapState.clear,
                highestContiguousAcknowledgedSequence: 0,
                prunedThrough: 0,
                inboxDepth: 0,
                outboxDepth: 0,
                nextRetryAt: null,
                lastSuccessfulSyncAt: null,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final listened = container.listen(
        voiceSignallingConnectedProvider,
        (_, _) {},
      );
      addTearDown(listened.close);
      await container.read(syncProjectionProvider.future);

      expect(
        container.read(voiceSignallingConnectedProvider),
        phase == SyncConnectionPhase.online ||
            phase == SyncConnectionPhase.draining,
        reason: phase.name,
      );
    }
  });
}
