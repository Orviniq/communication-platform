import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/pairwise/application/pairwise_volatile_sealer.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_volatile_store.dart';
import 'package:communication_platform/features/pairwise/domain/pairwise_model.dart';
import 'package:communication_platform/features/pairwise/infrastructure/native_pairwise_outbound_preparation.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/application/voice_signal_transport.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_codec.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';
import 'package:communication_platform/features/voice/infrastructure/pairwise_voice_signal_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/volatile_pairwise_harness.dart';
import 'support/signal_fakes.dart';

/// Two faked devices, each with its own database, store, sealer, opener and
/// transport, joined by a relay that behaves as the server does: it hands a
/// frame to the device it names if that device is connected, and drops
/// everything else without a word.
void main() {
  final aliceUser = testUuid(3001);
  final aliceDevice = testUuid(801);
  final bobUser = testUuid(3002);
  final bobDevice = testUuid(802);
  final malloryUser = testUuid(3003);
  final malloryDevice = testUuid(803);
  final aliceBob = filled(16, 0xab);
  final malloryBob = filled(16, 0xcb);

  late FakeRatchetCrypto crypto;
  late FakeLiveDevices liveDevices;
  late FakeSignalClock clock;
  late FakeRelay relay;
  late VolatileDevice alice;
  late VolatileDevice bob;
  late VolatileDevice mallory;
  final transports = <VoiceSignalTransport>[];

  VoiceSignalTransport transportFor(
    VolatileDevice device, {
    PairwiseVolatileStore? volatileStore,
    Set<int> buckets = const {1024, 4096, 16384},
  }) {
    final transport = VoiceSignalTransport(
      currentUserId: device.userId,
      currentDeviceId: device.deviceId,
      socket: relay.socketFor(device.deviceId),
      sealer: PairwiseVoiceSignalSeal(
        sealer: PairwiseVolatileSealer(
          store: device.store,
          volatileStore: volatileStore ?? device.store,
          liveDevices: liveDevices,
          crypto: NativePairwiseOutboundPreparation(crypto),
          clock: FixedTime(),
        ),
        currentUserId: device.userId,
        currentDeviceId: device.deviceId,
      ),
      opener: PairwiseVoiceSignalOpen(
        device.opener(crypto: crypto, liveDevices: liveDevices),
      ),
      buckets: FixedSignalBuckets(buckets),
      clock: clock,
      timer: FakeSignalTimer(clock),
    )..start();
    transports.add(transport);
    return transport;
  }

  setUp(() async {
    crypto = FakeRatchetCrypto();
    clock = FakeSignalClock();
    relay = FakeRelay();
    liveDevices = FakeLiveDevices({
      aliceUser: [liveDevice(aliceUser, aliceDevice, identity: 0x61)],
      bobUser: [liveDevice(bobUser, bobDevice, identity: 0x62)],
      malloryUser: [liveDevice(malloryUser, malloryDevice, identity: 0x63)],
    });
    alice = await VolatileDevice.open(userId: aliceUser, deviceId: aliceDevice);
    bob = await VolatileDevice.open(userId: bobUser, deviceId: bobDevice);
    mallory = await VolatileDevice.open(
      userId: malloryUser,
      deviceId: malloryDevice,
    );
    // Each pair already shares a session: the durable path started it.
    await alice.holdSession(
      peerUserId: bobUser,
      peerDeviceId: bobDevice,
      sessionId: aliceBob,
    );
    await bob.holdSession(
      peerUserId: aliceUser,
      peerDeviceId: aliceDevice,
      sessionId: aliceBob,
    );
    await mallory.holdSession(
      peerUserId: bobUser,
      peerDeviceId: bobDevice,
      sessionId: malloryBob,
    );
    await bob.holdSession(
      peerUserId: malloryUser,
      peerDeviceId: malloryDevice,
      sessionId: malloryBob,
    );
  });

  tearDown(() async {
    for (final transport in transports) {
      await transport.dispose();
    }
    transports.clear();
    await relay.close();
    for (final device in [alice, bob, mallory]) {
      await device.close();
    }
  });

  test(
    'a message sealed for device B and opened by device B round-trips',
    () async {
      final aliceTransport = transportFor(alice);
      final bobTransport = transportFor(bob);
      final bobHears = bobTransport.inbound.first;

      final sent = await aliceTransport.send(
        roomId: filled(32, 0x11),
        joinId: filled(16, 0x21),
        counter: 3,
        body: VoiceOffer(targetJoinId: filled(16, 0x22), sdp: offerSdp),
        targets: [VoiceSignalTarget(userId: bobUser, deviceId: bobDevice)],
      );

      expect(
        (sent as Success<List<VoiceSignalDelivery>>).value.single,
        isA<VoiceSignalSent>(),
      );
      final heard = await bobHears as ReceivedVoiceSignal;
      expect(heard.senderUserId, aliceUser);
      expect(heard.senderDeviceId, aliceDevice);
      expect(heard.message.header.counter, 3);
      expect(heard.message.header.joinId, filled(16, 0x21));
      final offer = heard.message.body as VoiceOffer;
      expect(offer.sdp, offerSdp);
      expect(offer.targetJoinId, filled(16, 0x22));
      // An SDP is more than the 942 bytes bucket 1024 holds under a regular
      // header, so the core seals it into 4096.
      expect(utf8.encode(offerSdp).length, greaterThan(942));
      expect(relay.carried.single.length, 4096);

      // Both sides advanced the one session they share, and neither wrote a
      // queue row of any kind.
      expect((await alice.sessionWith(bobDevice))!.stateVersion, 2);
      expect((await bob.sessionWith(aliceDevice))!.stateVersion, 2);
      for (final device in [alice, bob]) {
        expect(
          await device.database.select(device.database.outboxOperations).get(),
          isEmpty,
        );
        expect(
          await device.database.select(device.database.inboxEnvelopes).get(),
          isEmpty,
        );
      }

      // And back the other way, on the same session.
      final aliceHears = aliceTransport.inbound.first;
      await bobTransport.send(
        roomId: filled(32, 0x11),
        joinId: filled(16, 0x22),
        counter: 1,
        body: VoiceAnswer(
          targetJoinId: filled(16, 0x21),
          sdp: offerSdp,
          answersCounter: 3,
        ),
        targets: [VoiceSignalTarget(userId: aliceUser, deviceId: aliceDevice)],
      );
      final answer = await aliceHears as ReceivedVoiceSignal;
      expect(answer.senderDeviceId, bobDevice);
      expect((answer.message.body as VoiceAnswer).answersCounter, 3);
    },
  );

  test(
    'a blob opened under a session other than the sender\'s is refused',
    () async {
      final bobTransport = transportFor(bob);
      final heard = <InboundVoiceSignal>[];
      bobTransport.inbound.listen(heard.add);

      // Mallory seals, under Mallory's own session with Bob, a join whose
      // header says it is from Alice.
      final forged = VoiceSignalCodec.encode(
        VoiceSignalMessage(
          header: VoiceSignalHeader(
            roomId: filled(32, 0x11),
            joinId: filled(16, 0x23),
            senderUserId: protocolUuidBytes(aliceUser),
            senderDeviceId: protocolUuidBytes(aliceDevice),
            counter: 1,
            createdMs: 1759233600000,
          ),
          body: const VoiceJoin(),
        ),
      );
      final sealed =
          await PairwiseVoiceSignalSeal(
            sealer: mallory.sealer(crypto: crypto, liveDevices: liveDevices),
            currentUserId: malloryUser,
            currentDeviceId: malloryDevice,
          ).seal(
            payload: (forged as Success<Uint8List>).value,
            targets: [VoiceSignalTarget(userId: bobUser, deviceId: bobDevice)],
            allowedLengths: const {1024, 4096, 16384},
          );
      final frame =
          ((sealed as Success<List<VoiceSealOutcome>>).value.single
                  as VoiceSealed)
              .frame;
      await relay
          .socketFor(malloryDevice)
          .sendSignal(toDeviceId: bobDevice, blob: base64.encode(frame));
      await settle();

      expect(heard, isEmpty);
      expect(
        (await bob.sessionWith(malloryDevice))!.stateVersion,
        2,
        reason: 'the frame opened under Mallory\'s session',
      );
      expect(
        (await bob.sessionWith(aliceDevice))!.stateVersion,
        1,
        reason: 'nothing touched the session with Alice',
      );
    },
  );

  test('a failed state commit sends nothing', () async {
    final aliceTransport = transportFor(
      alice,
      volatileStore: _RefusingVolatileStore(),
    );
    final bobTransport = transportFor(bob);
    final heard = <InboundVoiceSignal>[];
    bobTransport.inbound.listen(heard.add);

    final sent = await aliceTransport.send(
      roomId: filled(32, 0x11),
      joinId: filled(16, 0x21),
      counter: 1,
      body: const VoiceJoin(),
      targets: [VoiceSignalTarget(userId: bobUser, deviceId: bobDevice)],
    );
    await settle();

    expect(
      ((sent as Success<List<VoiceSignalDelivery>>).value.single
              as VoiceSignalNotSent)
          .reason,
      VoiceSignalRefusal.sealFailed,
    );
    expect(relay.carried, isEmpty);
    expect(heard, isEmpty);
    expect((await alice.sessionWith(bobDevice))!.stateVersion, 1);
  });

  test('an off-bucket blob never reaches the socket', () async {
    // A deployment that publishes only the smallest bucket: an SDP needs
    // 4096, so it has no frame to travel in.
    final aliceTransport = transportFor(alice, buckets: const {1024});

    final sent = await aliceTransport.send(
      roomId: filled(32, 0x11),
      joinId: filled(16, 0x21),
      counter: 1,
      body: VoiceOffer(targetJoinId: filled(16, 0x22), sdp: offerSdp),
      targets: [VoiceSignalTarget(userId: bobUser, deviceId: bobDevice)],
    );

    expect(
      ((sent as Success<List<VoiceSignalDelivery>>).value.single
              as VoiceSignalNotSent)
          .reason,
      VoiceSignalRefusal.offBucket,
    );
    expect(relay.carried, isEmpty);
    expect(
      (await alice.sessionWith(bobDevice))!.stateVersion,
      1,
      reason: 'an off-bucket frame is never committed',
    );
  });

  test('a device with no session is refused rather than started', () async {
    final aliceTransport = transportFor(alice);

    final sent = await aliceTransport.send(
      roomId: filled(32, 0x11),
      joinId: filled(16, 0x21),
      counter: 1,
      body: const VoiceJoin(),
      targets: [
        VoiceSignalTarget(userId: malloryUser, deviceId: malloryDevice),
      ],
    );

    expect(
      ((sent as Success<List<VoiceSignalDelivery>>).value.single
              as VoiceSignalNotSent)
          .reason,
      VoiceSignalRefusal.noSession,
    );
    expect(relay.carried, isEmpty);
    expect(crypto.initiateCalls, 0);
    expect(await alice.sessionWith(malloryDevice), isNull);
  });
}

const offerSdp =
    'v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
    'a=group:BUNDLE 0\r\na=extmap-allow-mixed\r\na=msid-semantic: WMS\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126\r\n'
    'c=IN IP4 0.0.0.0\r\na=rtcp:9 IN IP4 0.0.0.0\r\n'
    'a=ice-ufrag:Zx1c\r\na=ice-pwd:KlqWbJ3Qm1bG5x0e7Zq3yRkS\r\n'
    'a=ice-options:trickle\r\n'
    'a=fingerprint:sha-256 4E:5B:27:32:9A:2C:84:0B:67:AF:1B:2B:4B:5F:D4:77:'
    '3D:4F:08:6A:37:B1:9C:E5:9E:22:6F:05:4A:1C:0B:7E\r\n'
    'a=setup:actpass\r\na=mid:0\r\na=sendrecv\r\na=rtcp-mux\r\n'
    'a=rtpmap:111 opus/48000/2\r\na=rtcp-fb:111 transport-cc\r\n'
    'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
    'a=rtpmap:63 red/48000/2\r\na=fmtp:63 111/111\r\n'
    'a=rtpmap:9 G722/8000\r\na=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\n'
    'a=rtpmap:13 CN/8000\r\na=rtpmap:110 telephone-event/48000\r\n'
    'a=rtpmap:126 telephone-event/8000\r\n'
    'a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n'
    'a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\n'
    'a=extmap:3 http://www.ietf.org/id/'
    'draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n'
    'a=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid\r\n'
    'a=msid:- 7b0f5b8e-1c2d-4e3f-9a8b-7c6d5e4f3a2b\r\n'
    'a=ssrc:1001 cname:Qf3n8yYz2b1LkT0w\r\n'
    'a=ssrc:1001 msid:- 7b0f5b8e-1c2d-4e3f-9a8b-7c6d5e4f3a2b\r\n';

/// The server's relay: a frame reaches the device it names if that device is
/// connected at that instant, and is dropped otherwise.
final class FakeRelay {
  final _sockets = <String, RelaySocket>{};

  /// Every frame handed on, decoded.
  final carried = <Uint8List>[];

  RelaySocket socketFor(String deviceId) =>
      _sockets.putIfAbsent(deviceId, () => RelaySocket(this));

  void _relay(String toDeviceId, String blob) {
    final target = _sockets[toDeviceId];
    if (target == null) {
      return;
    }
    carried.add(base64.decode(blob));
    target._deliver(blob);
  }

  Future<void> close() async {
    for (final socket in _sockets.values) {
      await socket.close();
    }
  }
}

final class RelaySocket implements VoiceSignalSocketPort {
  RelaySocket(this._relay);

  final FakeRelay _relay;
  final _inbound = StreamController<String>.broadcast();

  @override
  Stream<String> get inboundBlobs => _inbound.stream;

  void _deliver(String blob) => _inbound.add(blob);

  @override
  Future<Result<void>> sendSignal({
    required String toDeviceId,
    required String blob,
  }) async {
    _relay._relay(toDeviceId, blob);
    return const Result.success(null);
  }

  Future<void> close() => _inbound.close();
}

final class _RefusingVolatileStore implements PairwiseVolatileStore {
  @override
  Future<Result<void>> commitVolatileSeal(
    PairwiseVolatileSealCommit commit,
  ) async =>
      const Result.failure(StorageFailure(StorageFailureKind.unavailable));

  @override
  Future<Result<void>> commitVolatileOpen(
    PairwiseVolatileOpenCommit commit,
  ) async =>
      const Result.failure(StorageFailure(StorageFailureKind.unavailable));
}

Future<void> settle() async {
  for (var turn = 0; turn < 20; turn += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
