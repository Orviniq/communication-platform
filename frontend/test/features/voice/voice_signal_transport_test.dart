import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/application/voice_signal_transport.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_codec.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/signal_fakes.dart';

void main() {
  const selfUser = '00000000-0000-4000-8000-000000001000';
  const selfDevice = '00000000-0000-4000-8000-000000000900';
  const peerUser = '00000000-0000-4000-8000-000000001001';
  const otherUser = '00000000-0000-4000-8000-000000001002';

  late FakeSignalClock clock;
  late FakeSignalSocket socket;
  late FakeSignalSealer sealer;
  late FakeSignalOpener opener;
  late VoiceSignalTransport transport;

  VoiceSignalTransport build({VoiceSignalTimerPort? timer}) =>
      VoiceSignalTransport(
        currentUserId: selfUser,
        currentDeviceId: selfDevice,
        socket: socket,
        sealer: sealer,
        opener: opener,
        buckets: const FixedSignalBuckets(),
        clock: clock,
        timer: timer ?? FakeSignalTimer(clock),
      )..start();

  setUp(() {
    clock = FakeSignalClock();
    socket = FakeSignalSocket(clock);
    sealer = FakeSignalSealer();
    opener = FakeSignalOpener();
    transport = build();
  });

  tearDown(() async {
    await transport.dispose();
    await socket.close();
  });

  Future<List<VoiceSignalDelivery>> sendJoin(
    List<VoiceSignalTarget> targets, {
    Uint8List? joinId,
    int counter = 1,
  }) async {
    final result = await transport.send(
      roomId: filledBytes(32, 0x11),
      joinId: joinId ?? filledBytes(16, 0x22),
      counter: counter,
      body: const VoiceJoin(),
      targets: targets,
    );
    return (result as Success<List<VoiceSignalDelivery>>).value;
  }

  group('sending', () {
    test('seals once for each target and sends one frame to each', () async {
      final deliveries = await sendJoin([
        target(peerUser, 1),
        target(peerUser, 2),
      ]);

      expect(deliveries, everyElement(isA<VoiceSignalSent>()));
      expect(sealer.calls, hasLength(1));
      expect(socket.sent.map((frame) => frame.toDeviceId), [
        deviceId(1),
        deviceId(2),
      ]);
      expect(
        socket.sent.map((frame) => base64.decode(frame.blob).length),
        everyElement(1024),
      );
      final sealed = VoiceSignalCodec.decode(sealer.payloads.single);
      final header = (sealed as DecodedVoiceSignal).message.header;
      expect(header.senderUserId, protocolUuidBytes(selfUser));
      expect(header.senderDeviceId, protocolUuidBytes(selfDevice));
      expect(header.counter, 1);
      expect(header.createdMs, clock.now().millisecondsSinceEpoch);
    });

    test('an off-bucket frame never reaches the socket', () async {
      sealer = FakeSignalSealer(frameLength: 2048);
      await transport.dispose();
      transport = build();

      final deliveries = await sendJoin([target(peerUser, 1)]);

      expect(
        (deliveries.single as VoiceSignalNotSent).reason,
        VoiceSignalRefusal.offBucket,
      );
      expect(socket.sent, isEmpty);
    });

    test('a failed state commit sends nothing', () async {
      sealer.answer = (payload, targets) =>
          const Result.failure(StorageFailure(StorageFailureKind.unavailable));

      final deliveries = await sendJoin([
        target(peerUser, 1),
        target(peerUser, 2),
      ]);

      expect(
        deliveries.map((delivery) => (delivery as VoiceSignalNotSent).reason),
        [VoiceSignalRefusal.sealFailed, VoiceSignalRefusal.sealFailed],
      );
      expect(socket.sent, isEmpty);
      expect(sealer.calls, hasLength(1), reason: 'only a conflict is retried');
    });

    test(
      'a commit that lost a race is sealed once more from fresh state',
      () async {
        var attempts = 0;
        sealer.answer = (payload, targets) {
          attempts += 1;
          return attempts == 1
              ? const Result.failure(
                  ValidationFailure(ValidationFailureKind.conflict),
                )
              : Result.success([
                  for (final item in targets)
                    VoiceSealed(item, Uint8List(1024)),
                ]);
        };

        final deliveries = await sendJoin([target(peerUser, 1)]);

        expect(deliveries.single, isA<VoiceSignalSent>());
        expect(attempts, 2);
      },
    );

    test('a refusal names its reason, and the rest still go', () async {
      sealer.answer = (payload, targets) => Result.success([
        VoiceSealRefused(targets[0], VoiceSignalRefusal.noSession),
        VoiceSealed(targets[1], Uint8List(1024)),
      ]);

      final deliveries = await sendJoin([
        target(peerUser, 1),
        target(peerUser, 2),
      ]);

      expect(
        (deliveries[0] as VoiceSignalNotSent).reason,
        VoiceSignalRefusal.noSession,
      );
      expect(deliveries[1], isA<VoiceSignalSent>());
      expect(socket.sent.single.toDeviceId, deviceId(2));
    });

    test('a socket that is down is reported, and the frame is spent', () async {
      socket.connected = false;

      final deliveries = await sendJoin([target(peerUser, 1)]);

      expect(
        (deliveries.single as VoiceSignalNotSent).reason,
        VoiceSignalRefusal.socketUnavailable,
      );
    });

    test('a join seals at most 32 frames to one device', () async {
      final joinId = filledBytes(16, 0x31);
      for (var counter = 1; counter <= 32; counter += 1) {
        final sent = await sendJoin(
          [target(peerUser, 1)],
          joinId: joinId,
          counter: counter,
        );
        expect(sent.single, isA<VoiceSignalSent>());
      }

      final overBudget = await sendJoin(
        [target(peerUser, 1), target(peerUser, 2)],
        joinId: joinId,
        counter: 33,
      );
      expect(
        (overBudget[0] as VoiceSignalNotSent).reason,
        VoiceSignalRefusal.budgetExhausted,
      );
      expect(overBudget[1], isA<VoiceSignalSent>());
      expect(sealer.calls.last.map((item) => item.deviceId), [deviceId(2)]);

      final nextJoin = await sendJoin([target(peerUser, 1)]);
      expect(nextJoin.single, isA<VoiceSignalSent>(), reason: 'a new join');

      transport.forgetJoin(joinId);
      final forgotten = await sendJoin(
        [target(peerUser, 1)],
        joinId: joinId,
        counter: 34,
      );
      expect(forgotten.single, isA<VoiceSignalSent>());
    });

    test('refuses a message it cannot send to anybody', () async {
      final refused = <String, Future<Result<List<VoiceSignalDelivery>>>>{
        'this device': transport.send(
          roomId: filledBytes(32, 1),
          joinId: filledBytes(16, 2),
          counter: 1,
          body: const VoiceJoin(),
          targets: [
            const VoiceSignalTarget(userId: selfUser, deviceId: selfDevice),
          ],
        ),
        'one device twice': transport.send(
          roomId: filledBytes(32, 1),
          joinId: filledBytes(16, 2),
          counter: 1,
          body: const VoiceJoin(),
          targets: [target(peerUser, 1), target(otherUser, 1)],
        ),
        'nobody': transport.send(
          roomId: filledBytes(32, 1),
          joinId: filledBytes(16, 2),
          counter: 1,
          body: const VoiceJoin(),
          targets: const [],
        ),
        'a counter of zero': transport.send(
          roomId: filledBytes(32, 1),
          joinId: filledBytes(16, 2),
          counter: 0,
          body: const VoiceJoin(),
          targets: [target(peerUser, 1)],
        ),
        'more than a frame carries': transport.send(
          roomId: filledBytes(32, 1),
          joinId: filledBytes(16, 2),
          counter: 1,
          body: VoiceOffer(
            targetJoinId: filledBytes(16, 3),
            sdp: List.filled(17000, 'v').join(),
          ),
          targets: [target(peerUser, 1)],
        ),
      };
      for (final entry in refused.entries) {
        expect(
          (await entry.value as FailureResult<List<VoiceSignalDelivery>>)
              .failure,
          isA<ValidationFailure>(),
          reason: entry.key,
        );
      }
      expect(sealer.calls, isEmpty);
      expect(socket.sent, isEmpty);
    });
  });

  group('pacing', () {
    test('a ten-device join leaves at once', () async {
      final peers = [
        for (var number = 1; number <= 9; number += 1) target(peerUser, number),
      ];

      await sendJoin(peers);
      for (final _ in const [1, 2]) {
        await sendJoin(peers, counter: 2);
      }

      expect(socket.sent, hasLength(27));
      expect(
        socket.sent.map((frame) => frame.at).toSet(),
        {socket.sent.first.at},
        reason: '27 frames is inside the bucket of 32',
      );
    });

    test('the sender stays under 100 frames in any rolling second', () async {
      final peers = [
        for (var number = 1; number <= 9; number += 1) target(peerUser, number),
      ];
      final joins = [
        for (var join = 0; join < 4; join += 1) filledBytes(16, 0x40 + join),
      ];

      // 4 joins, 9 peers, 30 messages each way: 1,080 frames, far past what a
      // call produces, and all asked for at once.
      await Future.wait([
        for (final joinId in joins)
          for (var counter = 1; counter <= 30; counter += 1)
            sendJoin(peers, joinId: joinId, counter: counter),
      ]);

      expect(socket.sent, hasLength(1080));
      final times = socket.sent.map((frame) => frame.at).toList();
      var worst = 0;
      for (var first = 0; first < times.length; first += 1) {
        var last = first;
        while (last + 1 < times.length &&
            times[last + 1].difference(times[first]) <
                const Duration(seconds: 1)) {
          last += 1;
        }
        if (last - first + 1 > worst) {
          worst = last - first + 1;
        }
      }
      expect(worst, lessThan(100));
      expect(
        worst,
        lessThanOrEqualTo(32 + 24),
        reason: 'a bucket and a refill',
      );
      for (var index = 1; index < times.length; index += 1) {
        expect(
          times[index].isBefore(times[index - 1]),
          isFalse,
          reason: 'frames leave in the order they were sealed',
        );
      }
    });
  });

  group('receiving', () {
    test(
      'delivers a message from the device its session authenticated',
      () async {
        opener.openings[1] = opening(
          sender: 1,
          payload: joinPayload(sender: 1),
        );
        final received = transport.inbound.first;

        socket.deliver(blobOf(1));

        final signal = await received as ReceivedVoiceSignal;
        expect(signal.senderUserId, peerUser);
        expect(signal.senderDeviceId, deviceId(1));
        expect(signal.message.body, isA<VoiceJoin>());
        expect(opener.openings[1]!.commits, 1);
      },
    );

    test('an off-bucket blob is dropped before anything opens it', () async {
      final received = <InboundVoiceSignal>[];
      transport.inbound.listen(received.add);
      opener.openings[1] = opening(sender: 1, payload: joinPayload(sender: 1));

      for (final blob in [
        base64.encode(Uint8List(1023)..[0] = 1),
        base64.encode(Uint8List(2048)..[0] = 1),
        base64.encode(Uint8List(65536)..[0] = 1),
        base64.encode(Uint8List(1024)..[0] = 1).replaceAll('=', ''),
        'not base64 at all',
        '',
      ]) {
        socket.deliver(blob);
      }
      await settle();

      expect(opener.opened, isEmpty);
      expect(received, isEmpty);
    });

    test('a message whose header names another sender is refused', () async {
      // Device 3's session opened it, and it claims to come from device 1.
      opener.openings[1] = opening(sender: 3, payload: joinPayload(sender: 1));
      final received = <InboundVoiceSignal>[];
      transport.inbound.listen(received.add);

      socket.deliver(blobOf(1));
      await settle();

      expect(received, isEmpty);
      expect(
        opener.openings[1]!.commits,
        1,
        reason: 'it is the call\'s frame, so the ratchet step is kept',
      );
    });

    test('another channel\'s payload is left unopened', () async {
      opener.openings[1] = opening(
        sender: 1,
        payload: Uint8List.fromList(utf8.encode('CPVRV001 room control')),
      );
      final received = <InboundVoiceSignal>[];
      transport.inbound.listen(received.add);

      socket.deliver(blobOf(1));
      await settle();

      expect(received, isEmpty);
      expect(opener.openings[1]!.commits, 0);
    });

    test('a newer major version says who needs a newer build', () async {
      final payload = joinPayload(sender: 1)..[8] = 2;
      opener.openings[1] = opening(sender: 1, payload: payload);
      final received = transport.inbound.first;

      socket.deliver(blobOf(1));

      final signal = await received as UnsupportedVoiceSignal;
      expect(signal.version, 2);
      expect(signal.senderDeviceId, deviceId(1));
    });

    test('an unknown kind is ignored, and so is a malformed body', () async {
      opener.openings[1] = opening(
        sender: 1,
        payload: joinPayload(sender: 1)..[9] = 42,
      );
      opener.openings[2] = opening(
        sender: 1,
        payload: Uint8List.fromList([...joinPayload(sender: 1), 0x00]),
      );
      final received = <InboundVoiceSignal>[];
      transport.inbound.listen(received.add);

      socket.deliver(blobOf(1));
      socket.deliver(blobOf(2));
      await settle();

      expect(received, isEmpty);
    });

    test('a commit that fails delivers nothing', () async {
      opener.openings[1] = opening(
        sender: 1,
        payload: joinPayload(sender: 1),
        commitResult: const Result.failure(
          StorageFailure(StorageFailureKind.unavailable),
        ),
      );
      final received = <InboundVoiceSignal>[];
      transport.inbound.listen(received.add);

      socket.deliver(blobOf(1));
      await settle();

      expect(received, isEmpty);
    });

    test('past 256 waiting frames the oldest are dropped', () async {
      opener.gate = Completer<void>();
      for (var number = 0; number < 300; number += 1) {
        socket.deliver(blobOf(number & 0xff));
      }
      await settle();
      expect(opener.opened, hasLength(1), reason: 'the worker holds one');

      opener.gate!.complete();
      await settle();

      expect(opener.opened, hasLength(1 + 256));
      expect(opener.opened.skip(1).map((frame) => frame[0]), [
        for (var number = 44; number < 300; number += 1) number & 0xff,
      ]);
    });
  });
}

VoiceSignalTarget target(String userId, int device) =>
    VoiceSignalTarget(userId: userId, deviceId: deviceId(device));

String deviceId(int number) =>
    '00000000-0000-4000-8000-${number.toRadixString(16).padLeft(12, '0')}';

Uint8List filledBytes(int length, int value) =>
    Uint8List.fromList(List<int>.filled(length, value));

/// A frame the fake opener recognises by its first byte.
String blobOf(int marker) => base64.encode(Uint8List(1024)..[0] = marker);

FakeOpening opening({
  required int sender,
  required Uint8List payload,
  Result<void> commitResult = const Result.success(null),
}) => FakeOpening(
  senderUserId: '00000000-0000-4000-8000-000000001001',
  senderDeviceId: deviceId(sender),
  payload: payload,
  commitResult: commitResult,
);

Uint8List joinPayload({required int sender}) {
  final encoded = VoiceSignalCodec.encode(
    VoiceSignalMessage(
      header: VoiceSignalHeader(
        roomId: filledBytes(32, 0x11),
        joinId: filledBytes(16, 0x23),
        senderUserId: protocolUuidBytes('00000000-0000-4000-8000-000000001001'),
        senderDeviceId: protocolUuidBytes(deviceId(sender)),
        counter: 1,
        createdMs: 1759233600000,
      ),
      body: const VoiceJoin(),
    ),
  );
  return (encoded as Success<Uint8List>).value;
}

Future<void> settle() async {
  for (var turn = 0; turn < 20; turn += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
