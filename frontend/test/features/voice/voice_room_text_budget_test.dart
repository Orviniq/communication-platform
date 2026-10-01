import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/domain/voice_room_text_budget.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_codec.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// The composer's limit: no line may need a frame larger than the largest
/// bucket the deployment publishes (`voice-signalling-v1.md`, Sizes, and what
/// fits a bucket).
void main() {
  const published = {1024, 4096, 16384};

  test('one frame carries the largest bucket under a regular header', () {
    expect(VoiceRoomTextBudget.maximumPayloadBytes(published), 16302);
    expect(VoiceRoomTextBudget.maximumPayloadBytes({1024, 4096}), 4014);
    expect(VoiceRoomTextBudget.maximumPayloadBytes({4096, 1024}), 4014);
    expect(VoiceRoomTextBudget.maximumPayloadBytes({1024}), 942);
    expect(VoiceRoomTextBudget.maximumPayloadBytes(const <int>{}), 0);
    expect(VoiceRoomTextBudget.maximumPayloadBytes({64}), 0);
    expect(
      VoiceRoomTextBudget.maximumPayloadBytes({65536}),
      VoiceSignalCodec.maximumPayloadBytes,
      reason: 'never more than the codec takes',
    );
  });

  test('under the record\'s buckets the record\'s own cap is the limit', () {
    expect(
      VoiceRoomTextBudget.check('x' * 2000, published),
      isA<VoiceRoomTextSendable>(),
    );
    expect(
      VoiceRoomTextBudget.check('x' * 2182, published),
      isA<VoiceRoomTextTooLong>().having(
        (tooLong) => tooLong.excessScalars,
        'excessScalars',
        182,
      ),
    );
    // Four bytes each: exactly the 8,000-byte cap, and still 2,000 scalars.
    final faces = '\u{1F600}' * 2000;
    expect(utf8.encode(faces), hasLength(8000));
    expect(
      VoiceRoomTextBudget.check(faces, published),
      isA<VoiceRoomTextSendable>(),
    );
    expect(
      VoiceRoomTextBudget.check('${faces}a', published),
      isA<VoiceRoomTextTooLong>().having(
        (tooLong) => tooLong.excessScalars,
        'excessScalars',
        1,
      ),
    );
  });

  test('a deployment with smaller buckets gets a smaller limit, measured by '
      'the codec', () {
    for (final buckets in const [
      {1024, 4096},
      {1024},
    ]) {
      final limit = VoiceRoomTextBudget.maximumPayloadBytes(buckets);
      // Two bytes each, so the record's caps are far away.
      final line = 'س' * 2000;
      final check = VoiceRoomTextBudget.check(line, buckets);
      expect(check, isA<VoiceRoomTextTooLong>(), reason: '$buckets');
      final excess = (check as VoiceRoomTextTooLong).excessScalars;
      final kept = 'س' * (2000 - excess);
      final oneMore = 'س' * (2001 - excess);

      expect(
        VoiceRoomTextBudget.check(kept, buckets),
        isA<VoiceRoomTextSendable>(),
      );
      expect(
        VoiceRoomTextBudget.check(oneMore, buckets),
        isA<VoiceRoomTextTooLong>().having(
          (tooLong) => tooLong.excessScalars,
          'excessScalars',
          1,
        ),
      );
      // The longest line it allows, sealed with an ordinary header, fits the
      // largest bucket the deployment publishes.
      expect(_encodedLength(kept), lessThanOrEqualTo(limit));
    }
  });

  test('a line with nothing to read, or no UTF-8 form, is not sent', () {
    expect(VoiceRoomTextBudget.check('', published), isA<VoiceRoomTextEmpty>());
    expect(
      VoiceRoomTextBudget.check('  \n ', published),
      isA<VoiceRoomTextEmpty>(),
    );
    expect(
      VoiceRoomTextBudget.check('hi \uD800 there', published),
      isA<VoiceRoomTextUnsendable>(),
    );
    expect(
      VoiceRoomTextBudget.check('hi', const <int>{}),
      isA<VoiceRoomTextTooLong>(),
    );
  });
}

int _encodedLength(String text) {
  final encoded = VoiceSignalCodec.encode(
    VoiceSignalMessage(
      header: VoiceSignalHeader(
        roomId: Uint8List(VoiceSignalLimits.roomIdBytes),
        joinId: Uint8List(VoiceSignalLimits.joinIdBytes),
        senderUserId: Uint8List(VoiceSignalLimits.uuidBytes),
        senderDeviceId: Uint8List(VoiceSignalLimits.uuidBytes),
        counter: 7,
        createdMs: DateTime.utc(2026, 10, 1).millisecondsSinceEpoch,
      ),
      body: VoiceRoomText(text),
    ),
  );
  return (encoded as Success<Uint8List>).value.length;
}
