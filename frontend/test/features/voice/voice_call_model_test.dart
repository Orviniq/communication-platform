import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the ceiling', () {
    String device(int index) =>
        '${(0xd0000000 + index).toRadixString(16)}-0000-4000-8000-000000000001';

    test('keeps the ten devices whose ids sort lowest', () {
      final eleven = [
        for (var index = 10; index >= 0; index -= 1) device(index),
      ];

      expect(VoiceCallCeiling.kept(eleven), {
        for (var index = 0; index < 10; index += 1) device(index),
      });
    });

    test('keeps everybody at ten or fewer', () {
      final ten = [for (var index = 0; index < 10; index += 1) device(index)];

      expect(VoiceCallCeiling.kept(ten), ten.toSet());
    });

    test('sorts an id spelled in capitals where its lowercase sorts', () {
      // Both ends compute the set from the ids alone (§N rule 3), so a
      // capitalized spelling must land where the lowercase one does.
      final ids = [
        for (var index = 0; index < 11; index += 1)
          index == 3 ? device(index).toUpperCase() : device(index),
      ];

      expect(VoiceCallCeiling.kept(ids), contains(device(3)));
      expect(VoiceCallCeiling.kept(ids), isNot(contains(device(10))));
    });
  });

  group('the retry schedule', () {
    test('waits 2, 4 and 8 seconds at the nominal jitter', () {
      expect(
        [
          for (var attempt = 0; attempt < 3; attempt += 1)
            VoiceRetrySchedule.waitAfter(attempt, 0.5),
        ],
        const [
          Duration(seconds: 2),
          Duration(seconds: 4),
          Duration(seconds: 8),
        ],
      );
      expect(VoiceRetrySchedule.attempts, 4);
      expect(VoiceRetrySchedule.answerWindow, const Duration(seconds: 6));
    });

    test('a peer is unreachable about twenty seconds after the first '
        'attempt', () {
      var total = VoiceRetrySchedule.answerWindow;
      for (var attempt = 0; attempt < 3; attempt += 1) {
        total += VoiceRetrySchedule.waitAfter(attempt, 0.5);
      }

      expect(total, const Duration(seconds: 20));
    });

    test('jitters each wait by at most 25 percent either way', () {
      expect(VoiceRetrySchedule.waitAfter(1, 0), const Duration(seconds: 3));
      expect(VoiceRetrySchedule.waitAfter(1, 1), const Duration(seconds: 5));
      expect(
        VoiceRetrySchedule.waitAfter(2, double.nan),
        const Duration(seconds: 8),
      );
      expect(
        VoiceRetrySchedule.waitAfter(0, 7),
        const Duration(milliseconds: 2500),
      );
      expect(() => VoiceRetrySchedule.waitAfter(3, 0.5), throwsRangeError);
    });
  });

  test('no string form names a device, an account, a room or a line of '
      'text', () {
    const userId = 'a0000001-0000-4000-8000-00000000a001';
    const deviceId = 'd0000001-0000-4000-8000-00000000d001';
    final participant = const VoiceCallParticipant(
      userId: userId,
      deviceId: deviceId,
      status: VoiceParticipantStatus.connected,
    );
    final entry = VoiceRoomTextEntry(
      senderUserId: userId,
      senderDeviceId: deviceId,
      text: 'meet at the north gate',
      at: DateTime.utc(2026, 10, 1),
      isOwn: false,
    );
    final state = VoiceCallState(
      phase: VoiceCallPhase.inCall,
      roomId: 'ab' * 32,
      participants: [participant],
      roomText: [entry],
    );

    for (final text in ['$participant', '$entry', '$state']) {
      for (final secret in [userId, deviceId, 'north gate', 'ab' * 32]) {
        expect(text.contains(secret), isFalse, reason: text);
      }
    }
  });
}
