import 'package:communication_platform/features/voice/application/voice_candidate_batcher.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/signal_fakes.dart';

void main() {
  late HeldSignalTimer timer;
  // Each batch as its candidate lines, with ` end` when it ends the
  // negotiation.
  late List<String> batches;
  late VoiceCandidateBatcher batcher;

  setUp(() {
    timer = HeldSignalTimer();
    batches = [];
    batcher = VoiceCandidateBatcher(
      timer: timer,
      flush: (candidates, {required end}) async {
        batches.add(
          '[${candidates.map((item) => item.candidate).join(',')}]'
          '${end ? ' end' : ''}',
        );
      },
    );
  });

  test('gathering that completes first sends one batch, with end', () async {
    batcher
      ..add(candidate('a'))
      ..add(candidate('b'));

    await batcher.complete();
    timer.releaseAll();
    await settle();

    expect(batches, ['[a,b] end']);
  });

  test('500 ms after the first candidate the batch goes without end, and '
      'completion ends the negotiation', () async {
    batcher
      ..add(candidate('a'))
      ..add(candidate('b'));
    expect(timer.pending, [const Duration(milliseconds: 500)]);

    timer.releaseAll();
    await settle();
    batcher.add(candidate('c'));
    await batcher.complete();
    timer.releaseAll();
    await settle();

    expect(batches, ['[a,b]', '[c] end']);
  });

  test('completion with nothing held sends end alone', () async {
    batcher.add(candidate('a'));
    timer.releaseAll();
    await settle();

    await batcher.complete();

    expect(batches, ['[a]', '[] end']);
  });

  test('more than eight go as consecutive batches, end on the last', () async {
    for (var index = 0; index < 11; index += 1) {
      batcher.add(candidate('$index'));
    }

    await batcher.complete();

    expect(batches, ['[0,1,2,3,4,5,6,7]', '[8,9,10] end']);
  });

  test('an ICE restart is a negotiation of its own', () async {
    batcher.add(candidate('old'));
    batcher.restart();
    timer.releaseAll();
    await settle();
    expect(batches, isEmpty, reason: 'what the restart superseded is dropped');

    batcher.add(candidate('new'));
    await batcher.complete();
    batcher.add(candidate('late'));
    timer.releaseAll();
    await settle();

    expect(batches, ['[new] end']);
  });
}

VoiceIceCandidate candidate(String line) =>
    VoiceIceCandidate(candidate: line, mid: '0', mline: 0);

Future<void> settle() async {
  for (var turn = 0; turn < 10; turn += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
