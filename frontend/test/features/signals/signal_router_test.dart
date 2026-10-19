import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/signal_ports.dart';
import 'package:communication_platform/core/application/signal_router.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:flutter_test/flutter_test.dart';

import '../voice/support/signal_fakes.dart';

/// ADR-098 D1: one reader opens each inbound `signal` frame once and routes
/// it by its magic.
void main() {
  const peer = '00000000-0000-4000-8000-000000001001';

  late FakeSignalClock clock;
  late FakeSignalSocket socket;
  late CountingOpener opener;
  late SignalRouter router;
  late List<RoutedSignal> voice;
  late List<RoutedSignal> presence;
  late List<SignalHeard> heard;

  setUp(() {
    clock = FakeSignalClock();
    socket = FakeSignalSocket(clock);
    opener = CountingOpener();
    router = SignalRouter(
      socket: socket,
      opener: opener,
      buckets: const FixedSignalBuckets(),
    )..start();
    voice = [];
    presence = [];
    heard = [];
    router.channel(SignalChannel.voice).listen(voice.add);
    router.channel(SignalChannel.presence).listen(presence.add);
    router.heard.listen(heard.add);
  });

  tearDown(() async {
    await router.dispose();
    await socket.close();
  });

  FakeOpening opensAs(int marker, String payload, {int device = 1}) =>
      opener.openings[marker] = FakeOpening(
        senderUserId: peer,
        senderDeviceId: deviceId(device),
        payload: Uint8List.fromList(utf8.encode(payload)),
      );

  test('a CPVSV001 reaches voice and a CPPSV001 presence, each committed and '
      'each opened once', () async {
    final call = opensAs(1, 'CPVSV001 a call');
    final typing = opensAs(2, 'CPPSV001 typing', device: 2);

    socket
      ..deliver(blobOf(1))
      ..deliver(blobOf(2));
    await settle();

    expect(opener.opens, {1: 1, 2: 1});
    expect(call.commits, 1);
    expect(typing.commits, 1);
    expect(voice.map((signal) => utf8.decode(signal.payload)), [
      'CPVSV001 a call',
    ]);
    expect(presence.map((signal) => utf8.decode(signal.payload)), [
      'CPPSV001 typing',
    ]);
    expect(presence.single.senderDeviceId, deviceId(2));
    expect(
      heard.map((sender) => sender.deviceId),
      [deviceId(1), deviceId(2)],
      reason: 'the ledger hears every committed frame, on either channel',
    );
  });

  test('an unknown magic is not committed and reaches nobody', () async {
    final room = opensAs(1, 'CPVRV001 room control');
    final event = opensAs(2, '\xa9 a durable event');

    socket
      ..deliver(blobOf(1))
      ..deliver(blobOf(2));
    await settle();

    expect(opener.opens, {1: 1, 2: 1});
    expect(room.commits, 0);
    expect(event.commits, 0);
    expect(voice, isEmpty);
    expect(presence, isEmpty);
    expect(heard, isEmpty);
  });

  test('a malformed or unknown-kind CPPSV001 is still committed', () async {
    final malformed = opensAs(1, 'CPPSV001');
    final unknownKind = opensAs(2, 'CPPSV001\x01\x63 a later kind');

    socket
      ..deliver(blobOf(1))
      ..deliver(blobOf(2));
    await settle();

    expect(malformed.commits, 1);
    expect(unknownKind.commits, 1);
    expect(presence, hasLength(2), reason: 'presence decides what it means');
  });

  test('a channel this router does not route is left uncommitted', () async {
    final voiceOnly = SignalRouter(
      socket: socket,
      opener: opener,
      buckets: const FixedSignalBuckets(),
      channels: const {SignalChannel.voice},
    )..start();
    addTearDown(voiceOnly.dispose);
    await router.stop();
    final typing = opensAs(1, 'CPPSV001 typing');

    socket.deliver(blobOf(1));
    await settle();

    expect(typing.commits, 0);
  });

  test('arrival order holds across channels', () async {
    for (var marker = 1; marker <= 6; marker += 1) {
      opensAs(marker, marker.isOdd ? 'CPVSV001 $marker' : 'CPPSV001 $marker');
    }
    final order = <String>[];
    router
        .channel(SignalChannel.voice)
        .listen((signal) => order.add(utf8.decode(signal.payload)));
    router
        .channel(SignalChannel.presence)
        .listen((signal) => order.add(utf8.decode(signal.payload)));

    for (var marker = 1; marker <= 6; marker += 1) {
      socket.deliver(blobOf(marker));
    }
    await settle();

    expect(order, [
      for (var marker = 1; marker <= 6; marker += 1)
        marker.isOdd ? 'CPVSV001 $marker' : 'CPPSV001 $marker',
    ]);
  });

  test('a commit that lost a race is opened once more from fresh state, and '
      'only once', () async {
    final conflicted = opensAs(1, 'CPPSV001 typing')
      ..commitAnswers.addAll([
        const Result.failure(ValidationFailure(ValidationFailureKind.conflict)),
      ]);
    final twice = opensAs(2, 'CPPSV001 typing')
      ..commitAnswers.addAll([
        const Result.failure(ValidationFailure(ValidationFailureKind.conflict)),
        const Result.failure(ValidationFailure(ValidationFailureKind.conflict)),
      ]);

    socket
      ..deliver(blobOf(1))
      ..deliver(blobOf(2));
    await settle();

    expect(opener.opens, {1: 2, 2: 2});
    expect(conflicted.commits, 2);
    expect(twice.commits, 2);
    expect(presence, hasLength(1), reason: 'the second gave up');
  });

  test('past 256 waiting blobs the oldest are dropped', () async {
    opener.gate = Completer<void>();
    for (var number = 0; number < 300; number += 1) {
      opensAs(number & 0xff, 'CPPSV001 $number');
      socket.deliver(blobOf(number & 0xff));
    }
    await settle();
    expect(opener.opened, hasLength(1), reason: 'the worker holds one');

    opener.gate!.complete();
    await settle();

    expect(SignalRouter.inboundQueueCapacity, 256);
    expect(opener.opened, hasLength(1 + 256));
    expect(opener.opened.skip(1).map((frame) => frame[0]), [
      for (var number = 44; number < 300; number += 1) number & 0xff,
    ]);
  });

  test('an off-bucket blob is dropped before anything opens it', () async {
    opensAs(1, 'CPPSV001 typing');

    for (final blob in [
      base64.encode(Uint8List(1023)..[0] = 1),
      base64.encode(Uint8List(2048)..[0] = 1),
      base64.encode(Uint8List(1024)..[0] = 1).replaceAll('=', ''),
      'not base64 at all',
      '',
    ]) {
      socket.deliver(blob);
    }
    await settle();

    expect(opener.opened, isEmpty);
  });

  test('opens and seals take turns', () async {
    opener.gate = Completer<void>();
    opensAs(1, 'CPPSV001 typing');
    socket.deliver(blobOf(1));
    await settle();

    var sealed = false;
    final seal = router.exclusively(() async => sealed = true);
    await settle();
    expect(sealed, isFalse, reason: 'an open is running');

    opener.gate!.complete();
    await seal;
    expect(sealed, isTrue);
  });

  test('a stopped router reads nothing until it starts again', () async {
    opensAs(1, 'CPPSV001 typing');
    await router.stop();

    socket.deliver(blobOf(1));
    await settle();
    expect(opener.opened, isEmpty);

    router.start();
    socket.deliver(blobOf(1));
    await settle();
    expect(presence, hasLength(1));
  });
}

String deviceId(int number) =>
    '00000000-0000-4000-8000-${number.toRadixString(16).padLeft(12, '0')}';

String blobOf(int marker) => base64.encode(Uint8List(1024)..[0] = marker);

Future<void> settle() async {
  for (var turn = 0; turn < 20; turn += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Counts every open of each frame, by its first byte, and answers commits
/// from [FakeOpening.commitAnswers] in turn.
final class CountingOpener implements SignalOpenPort {
  final openings = <int, FakeOpening>{};
  final opens = <int, int>{};
  final opened = <Uint8List>[];
  Completer<void>? gate;

  @override
  Future<Result<SignalOpening>> open(Uint8List frame) async {
    opened.add(frame);
    opens[frame[0]] = (opens[frame[0]] ?? 0) + 1;
    final held = gate;
    if (held != null) {
      await held.future;
    }
    final opening = openings[frame[0]];
    if (opening == null) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    return Result.success(opening);
  }
}

final class FakeOpening implements SignalOpening {
  FakeOpening({
    required this.senderUserId,
    required this.senderDeviceId,
    required this.payload,
  });

  @override
  final String senderUserId;
  @override
  final String senderDeviceId;
  @override
  final Uint8List payload;
  final commitAnswers = <Result<void>>[];
  var commits = 0;

  @override
  Future<Result<void>> commit() async {
    commits += 1;
    return commitAnswers.isEmpty
        ? const Result.success(null)
        : commitAnswers.removeAt(0);
  }
}
