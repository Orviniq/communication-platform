import 'dart:async';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_peer_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/application/voice_peer_connection.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/domain/voice_peer_model.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/peer_fakes.dart';
import 'support/relay_fakes.dart';
import 'support/signal_fakes.dart';

const lowDevice = '00000000-0000-4000-8000-00000000000a';
const highDevice = '00000000-0000-4000-8000-00000000000b';
const lowUser = '00000000-0000-4000-8000-000000001001';
const highUser = '00000000-0000-4000-8000-000000001002';
const malloryUser = '00000000-0000-4000-8000-000000001003';
const malloryDevice = '00000000-0000-4000-8000-00000000000c';

final room = filled(32, 0x11);

RelayCredential relayCredential({
  String username = relayUsername,
  String password = relayPassword,
}) => RelayCredential(
  urls: relayUrls,
  username: username,
  credential: password,
  lifetime: const Duration(hours: 6),
  expiresAt: DateTime.utc(2026, 9, 30, 18),
);

/// One device of the call, holding its one connection to the other.
final class End {
  End({
    required this.userId,
    required this.deviceId,
    required this.joinId,
    required this.media,
    required this.audio,
    required this.signalling,
  });

  final String userId;
  final String deviceId;
  final Uint8List joinId;
  final FakePeerMediaPort media;
  final FakeLocalAudioPort audio;
  final FakePeerSignalling signalling;
  final events = <VoicePeerEvent>[];
  late final VoicePeerConnection connection;

  FakePeerMedia get platform => media.opened.single;

  List<VoiceSignalKind> get sentKinds => [
    for (final signal in signalling.sent) signal.kind,
  ];

  List<SentPeerSignal> sentOf(VoiceSignalKind kind) => [
    for (final signal in signalling.sent)
      if (signal.kind == kind) signal,
  ];
}

End end({
  required String name,
  required String userId,
  required String deviceId,
  required int joinByte,
}) => End(
  userId: userId,
  deviceId: deviceId,
  joinId: filled(16, joinByte),
  media: FakePeerMediaPort(name),
  audio: FakeLocalAudioPort(),
  signalling: FakePeerSignalling(userId: userId, deviceId: deviceId),
);

Future<Result<VoicePeerConnection>> openConnection(
  End self,
  End peer, {
  RelayIceConfiguration? configuration,
}) => VoicePeerConnection.open(
  join: VoiceLocalJoin(
    roomId: room,
    joinId: self.joinId,
    deviceId: self.deviceId,
  ),
  peer: VoicePeerAddress(
    userId: peer.userId,
    deviceId: peer.deviceId,
    joinId: peer.joinId,
  ),
  configuration: configuration ?? relayCredential().iceConfiguration,
  media: self.media,
  localAudio: self.audio,
  signalling: self.signalling,
  timer: HeldSignalTimer(),
);

/// Two devices, each with its connection to the other.
Future<(End, End)> openPair({
  String aDevice = lowDevice,
  String bDevice = highDevice,
}) async {
  final a = end(name: 'a', userId: lowUser, deviceId: aDevice, joinByte: 0xa1);
  final b = end(name: 'b', userId: highUser, deviceId: bDevice, joinByte: 0xb1);
  for (final (self, peer) in [(a, b), (b, a)]) {
    final opened = await openConnection(self, peer);
    self.connection = (opened as Success<VoicePeerConnection>).value;
    self.connection.events.listen(self.events.add);
  }
  return (a, b);
}

/// Hands [to] every message [from] sent that [to] has not taken, in order,
/// as the transport would: authenticated as [from]'s device.
Future<List<VoicePeerIntake>> deliver(End from, End to) async => [
  for (final signal in from.signalling.takeUndelivered())
    await to.connection.receive(
      received(signal.message, userId: from.userId, deviceId: from.deviceId),
    ),
];

/// Delivers in both directions until neither device has anything to send.
Future<void> exchange(End a, End b) async {
  for (var round = 0; round < 20; round += 1) {
    await settle();
    if (!a.signalling.hasUndelivered && !b.signalling.hasUndelivered) {
      return;
    }
    await deliver(a, b);
    await deliver(b, a);
  }
  fail('the two devices never went quiet');
}

/// A message as [from]'s transport would have sealed it, with any field of
/// its header replaced.
VoiceSignalMessage messageFrom(
  End from,
  VoiceSignalBody body, {
  required int counter,
  Uint8List? roomId,
  Uint8List? joinId,
  String? claimedUserId,
  String? claimedDeviceId,
}) => VoiceSignalMessage(
  header: VoiceSignalHeader(
    roomId: roomId ?? room,
    joinId: joinId ?? from.joinId,
    senderUserId: protocolUuidBytes(claimedUserId ?? from.userId),
    senderDeviceId: protocolUuidBytes(claimedDeviceId ?? from.deviceId),
    counter: counter,
    createdMs: 0,
  ),
  body: body,
);

void expectNegotiated(End a, End b) {
  expect(a.platform.signalingState, FakeSignalingState.stable);
  expect(b.platform.signalingState, FakeSignalingState.stable);
  expect(a.platform.currentLocal?.sdp, b.platform.currentRemote?.sdp);
  expect(a.platform.currentRemote?.sdp, b.platform.currentLocal?.sdp);
  expect(a.platform.currentLocal, isNotNull);
  expect(a.platform.currentRemote, isNotNull);
  expect(a.connection.state, VoicePeerState.connected);
  expect(b.connection.state, VoicePeerState.connected);
  expect(a.media.opened, hasLength(1));
  expect(b.media.opened, hasLength(1));
}

void main() {
  test('the two ends of a connection agree on the polite peer', () async {
    // The lower device id is the polite peer (voice_peer_model_test.dart).
    final (low, high) = await openPair();
    final (reversedHigh, reversedLow) = await openPair(
      aDevice: highDevice,
      bDevice: lowDevice,
    );

    expect(low.connection.isPolite, isTrue);
    expect(high.connection.isPolite, isFalse);
    expect(reversedLow.connection.isPolite, isTrue);
    expect(reversedHigh.connection.isPolite, isFalse);
  });

  group('negotiation', () {
    test('the device that negotiates offers, and the other answers', () async {
      final (participant, joiner) = await openPair(
        aDevice: highDevice,
        bDevice: lowDevice,
      );

      await participant.connection.negotiate();
      await settle();

      final offer = participant.sentOf(VoiceSignalKind.offer).single;
      final offerBody = offer.message.body as VoiceOffer;
      expect(offerBody.targetJoinId, joiner.joinId);
      expect(offer.message.header.joinId, participant.joinId);
      expect(offer.message.header.roomId, room);
      expect(offer.target.deviceId, joiner.deviceId);
      expect(
        VoiceSessionDescription(
          type: VoiceDescriptionType.offer,
          sdp: offerBody.sdp,
        ).isAudioOnly,
        isTrue,
      );

      await exchange(participant, joiner);

      final answer = joiner.sentOf(VoiceSignalKind.answer).single;
      expect(
        (answer.message.body as VoiceAnswer).answersCounter,
        offer.counter,
      );
      expect(joiner.sentOf(VoiceSignalKind.offer), isEmpty);
      expectNegotiated(participant, joiner);
      expect(participant.events, contains(isA<VoicePeerAnswered>()));
      expect(
        participant.events.whereType<VoicePeerStateChanged>().map(
          (event) => event.state,
        ),
        [VoicePeerState.connected],
      );
    });

    test(
      'negotiating again, or after an answered offer, sends nothing',
      () async {
        final (participant, joiner) = await openPair();

        await participant.connection.negotiate();
        await exchange(participant, joiner);
        final sent = participant.signalling.sent.length;

        await participant.connection.negotiate();
        await joiner.connection.negotiate();
        await settle();

        expect(participant.signalling.sent, hasLength(sent));
        expect(joiner.sentOf(VoiceSignalKind.offer), isEmpty);
      },
    );

    for (final (label, aDevice, bDevice) in [
      ('the first device sorts lower', lowDevice, highDevice),
      ('the second device sorts lower', highDevice, lowDevice),
    ]) {
      for (final politeFirst in [true, false]) {
        test(
          'glare ends in one negotiated connection when $label '
          '(${politeFirst ? 'polite' : 'impolite'} offer delivered first)',
          () async {
            final (a, b) = await openPair(aDevice: aDevice, bDevice: bDevice);
            final polite = a.connection.isPolite ? a : b;
            final impolite = a.connection.isPolite ? b : a;

            await Future.wait([
              a.connection.negotiate(),
              b.connection.negotiate(),
            ]);
            await settle();
            expect(a.sentOf(VoiceSignalKind.offer), hasLength(1));
            expect(b.sentOf(VoiceSignalKind.offer), hasLength(1));
            final impoliteOffer =
                impolite.sentOf(VoiceSignalKind.offer).single.message.body
                    as VoiceOffer;

            final List<VoicePeerIntake> atImpolite;
            final List<VoicePeerIntake> atPolite;
            if (politeFirst) {
              atImpolite = await deliver(polite, impolite);
              atPolite = await deliver(impolite, polite);
            } else {
              atPolite = await deliver(impolite, polite);
              atImpolite = await deliver(polite, impolite);
            }
            await exchange(a, b);

            expect(atImpolite.first, VoicePeerIntake.collisionIgnored);
            expect(atPolite.first, VoicePeerIntake.applied);
            expectNegotiated(a, b);
            // The negotiated offer is the impolite device's; the polite
            // device's own offer was rolled back and never applied.
            expect(polite.platform.currentRemote?.sdp, impoliteOffer.sdp);
            expect(polite.platform.rollbacks, 1);
            expect(impolite.platform.rollbacks, 0);
            expect(
              impolite.platform.remoteDescriptionsApplied.map(
                (description) => description.type,
              ),
              [VoiceDescriptionType.answer],
            );
            expect(polite.sentOf(VoiceSignalKind.answer), hasLength(1));
            expect(impolite.sentOf(VoiceSignalKind.answer), isEmpty);
          },
        );
      }
    }

    test(
      'the polite peer rolls back, and the impolite peer ignores the offer',
      () async {
        final (polite, impolite) = await openPair();

        await Future.wait([
          polite.connection.negotiate(),
          impolite.connection.negotiate(),
        ]);
        await settle();

        // The impolite device keeps its own offer and applies nothing.
        final atImpolite = await deliver(polite, impolite);
        expect(atImpolite.first, VoicePeerIntake.collisionIgnored);
        expect(
          impolite.platform.signalingState,
          FakeSignalingState.haveLocalOffer,
        );
        expect(
          impolite.platform.calls,
          isNot(contains('setRemoteDescription')),
        );
        expect(impolite.platform.calls, isNot(contains('rollbackLocalOffer')));

        // The polite device rolls its own back before it applies the other,
        // because the platform does no implicit rollback.
        polite.platform.calls.clear();
        final atPolite = await deliver(impolite, polite);
        expect(atPolite.first, VoicePeerIntake.applied);
        expect(polite.platform.calls.take(4), [
          'rollbackLocalOffer',
          'setRemoteDescription',
          'createAnswer',
          'setLocalDescription',
        ]);

        await exchange(polite, impolite);
        expectNegotiated(polite, impolite);
        expect(impolite.events, contains(isA<VoicePeerAnswered>()));
      },
    );

    test('a retried offer is taken once, and answered once', () async {
      final (participant, joiner) = await openPair();

      await participant.connection.negotiate();
      await settle();
      final first = await deliver(participant, joiner);
      expect(first.first, VoicePeerIntake.applied);

      expect(await participant.connection.resend(), VoiceSignalKind.offer);
      final offers = participant.sentOf(VoiceSignalKind.offer);
      expect(offers, hasLength(2));
      expect(offers.last.counter, offers.first.counter);

      final retried = await deliver(participant, joiner);
      expect(retried, [VoicePeerIntake.duplicate]);
      expect(joiner.sentOf(VoiceSignalKind.answer), hasLength(1));
    });

    test(
      'an answer for an offer that is not outstanding is discarded',
      () async {
        final (participant, joiner) = await openPair();
        await participant.connection.negotiate();
        await settle();

        final stale = await participant.connection.receive(
          received(
            messageFrom(
              joiner,
              VoiceAnswer(
                targetJoinId: participant.joinId,
                sdp: fakeSdp(type: VoiceDescriptionType.answer, ufrag: 'late'),
                answersCounter: 999,
              ),
              counter: 7,
            ),
            userId: joiner.userId,
            deviceId: joiner.deviceId,
          ),
        );

        expect(stale, VoicePeerIntake.superseded);
        expect(participant.platform.remoteDescriptionsApplied, isEmpty);
        expect(
          participant.platform.signalingState,
          FakeSignalingState.haveLocalOffer,
        );
      },
    );

    test(
      'the joiner answers again when asked, with its first counter',
      () async {
        final (participant, joiner) = await openPair();
        await participant.connection.negotiate();
        await exchange(participant, joiner);

        expect(await joiner.connection.resend(), VoiceSignalKind.answer);

        final answers = joiner.sentOf(VoiceSignalKind.answer);
        expect(answers, hasLength(2));
        expect(answers.last.counter, answers.first.counter);
        expect(await deliver(joiner, participant), [VoicePeerIntake.duplicate]);
        expect(await participant.connection.resend(), isNull);
      },
    );
  });

  group('the channel', () {
    test(
      'a description that comes from a different device is refused',
      () async {
        final (participant, joiner) = await openPair();
        final mallory = end(
          name: 'm',
          userId: malloryUser,
          deviceId: malloryDevice,
          joinByte: 0xc1,
        );
        final offer = VoiceOffer(
          targetJoinId: joiner.joinId,
          sdp: fakeSdp(type: VoiceDescriptionType.offer, ufrag: 'mallory'),
        );

        final outcomes = [
          // Another member's device, speaking for itself.
          await joiner.connection.receive(
            received(
              messageFrom(mallory, offer, counter: 1),
              userId: malloryUser,
              deviceId: malloryDevice,
            ),
          ),
          // Another device whose header claims to be the peer: the session
          // authenticated who sent it, and that is what counts.
          await joiner.connection.receive(
            received(
              messageFrom(
                mallory,
                offer,
                counter: 2,
                joinId: participant.joinId,
                claimedUserId: participant.userId,
                claimedDeviceId: participant.deviceId,
              ),
              userId: malloryUser,
              deviceId: malloryDevice,
            ),
          ),
          // The peer's own account, from a device this connection is not for.
          await joiner.connection.receive(
            received(
              messageFrom(
                mallory,
                offer,
                counter: 3,
                claimedUserId: participant.userId,
              ),
              userId: participant.userId,
              deviceId: malloryDevice,
            ),
          ),
          // Candidates are held to the same rule.
          await joiner.connection.receive(
            received(
              messageFrom(
                mallory,
                VoiceCandidates(
                  targetJoinId: joiner.joinId,
                  candidates: [fakeRelayCandidate('mallory')],
                  end: true,
                ),
                counter: 4,
              ),
              userId: malloryUser,
              deviceId: malloryDevice,
            ),
          ),
        ];

        expect(outcomes, everyElement(VoicePeerIntake.wrongSender));
        expect(joiner.platform.calls, isEmpty);
        expect(joiner.signalling.sent, isEmpty);
      },
    );

    test('a description for another room or another join is refused', () async {
      final (participant, joiner) = await openPair();
      VoiceOffer offerTo(Uint8List joinId) => VoiceOffer(
        targetJoinId: joinId,
        sdp: fakeSdp(type: VoiceDescriptionType.offer, ufrag: 'other'),
      );
      Future<VoicePeerIntake> take(VoiceSignalMessage message) =>
          joiner.connection.receive(
            received(
              message,
              userId: participant.userId,
              deviceId: participant.deviceId,
            ),
          );

      expect(
        await take(
          messageFrom(participant, offerTo(filled(16, 0x99)), counter: 1),
        ),
        VoicePeerIntake.wrongJoin,
      );
      expect(
        await take(
          messageFrom(
            participant,
            offerTo(joiner.joinId),
            counter: 2,
            joinId: filled(16, 0x98),
          ),
        ),
        VoicePeerIntake.wrongJoin,
      );
      expect(
        await take(
          messageFrom(
            participant,
            offerTo(joiner.joinId),
            counter: 3,
            roomId: filled(32, 0x97),
          ),
        ),
        VoicePeerIntake.wrongJoin,
      );
      expect(
        await take(messageFrom(participant, const VoiceJoin(), counter: 4)),
        VoicePeerIntake.notForConnection,
      );
      expect(
        await take(
          messageFrom(
            participant,
            const VoiceLeave(VoiceLeaveReason.userLeft),
            counter: 5,
          ),
        ),
        VoicePeerIntake.notForConnection,
      );
      expect(joiner.platform.calls, isEmpty);
    });

    test('candidates follow the description they belong to', () async {
      final (participant, joiner) = await openPair();
      final offerSent = Completer<void>();
      participant.signalling.holds[VoiceSignalKind.offer] = offerSent;

      unawaited(participant.connection.negotiate());
      await settle();
      // Gathering has completed, and the batch waits for the offer.
      expect(participant.signalling.sent, isEmpty);

      offerSent.complete();
      await settle();
      expect(participant.sentKinds, [
        VoiceSignalKind.offer,
        VoiceSignalKind.candidates,
      ]);
      final batch =
          participant.sentOf(VoiceSignalKind.candidates).single.message.body
              as VoiceCandidates;
      expect(batch.end, isTrue);
      expect(batch.targetJoinId, joiner.joinId);
      expect(batch.candidates.single.candidate, contains('typ relay'));
    });

    test(
      'an abandoned generation\'s candidates and completion are not sent',
      () async {
        final (polite, impolite) = await openPair();
        polite.platform.autoGather = false;
        impolite.platform.autoGather = false;
        await Future.wait([
          polite.connection.negotiate(),
          impolite.connection.negotiate(),
        ]);
        final abandoned = ufragOf(polite.platform.pendingLocal!.sdp)!;

        // The impolite device's offer makes the polite one roll back and
        // answer, on new ICE credentials.
        await deliver(impolite, polite);
        await settle();
        final current = ufragOf(polite.platform.currentLocal!.sdp)!;
        expect(current, isNot(abandoned));

        // The rolled-back offer's session reports late: a completion first,
        // then a candidate of its own. libwebrtc names no generation on either.
        polite.platform
          ..emit(const VoiceCandidateGatheringComplete())
          ..emit(VoiceLocalCandidateGathered(fakeRelayCandidate(abandoned)));
        await settle();
        expect(polite.sentOf(VoiceSignalKind.candidates), isEmpty);

        // The answer's own generation still goes, ended by its completion.
        polite.platform.gather([fakeRelayCandidate(current)]);
        await settle();
        final batch =
            polite.sentOf(VoiceSignalKind.candidates).single.message.body
                as VoiceCandidates;
        expect(batch.candidates.single.candidate, contains('ufrag $current'));
        expect(batch.end, isTrue);
      },
    );

    test('candidates that arrive before the description are held', () async {
      final (participant, joiner) = await openPair();
      await participant.connection.negotiate();
      await settle();

      final [offer, candidates] = participant.signalling.takeUndelivered();
      Future<VoicePeerIntake> take(SentPeerSignal signal) =>
          joiner.connection.receive(
            received(
              signal.message,
              userId: participant.userId,
              deviceId: participant.deviceId,
            ),
          );
      expect(await take(candidates), VoicePeerIntake.applied);
      expect(joiner.platform.calls, isNot(contains('addRemoteCandidate')));
      expect(await take(offer), VoicePeerIntake.applied);

      expect(
        joiner.platform.calls.indexOf('addRemoteCandidate'),
        greaterThan(joiner.platform.calls.indexOf('setRemoteDescription')),
      );
      expect(joiner.platform.remoteCandidates, hasLength(1));
    });

    test('a frame the transport refused is reported upward', () async {
      final (participant, _) = await openPair();
      participant.signalling.refuseWith = VoiceSignalRefusal.noSession;

      await participant.connection.negotiate();
      await settle();

      expect(
        participant.events.whereType<VoicePeerSignalNotSent>().map(
          (event) => (event.kind, event.reason),
        ),
        contains((VoiceSignalKind.offer, VoiceSignalRefusal.noSession)),
      );
    });
  });

  group('media', () {
    test('no video track and no data channel is ever created', () async {
      final (participant, joiner) = await openPair();

      // One hold on the microphone, and one platform connection carrying it.
      expect(joiner.audio.holds, hasLength(1));
      expect(joiner.platform.audio, same(joiner.audio.holds.single));

      Future<VoicePeerIntake> offerWith(List<String> sections, int counter) =>
          joiner.connection.receive(
            received(
              messageFrom(
                participant,
                VoiceOffer(
                  targetJoinId: joiner.joinId,
                  sdp: fakeSdp(
                    type: VoiceDescriptionType.offer,
                    ufrag: 'shape$counter',
                    sections: sections,
                  ),
                ),
                counter: counter,
              ),
              userId: participant.userId,
              deviceId: participant.deviceId,
            ),
          );

      // A section that would bring a video track or a data channel into
      // being on this side never reaches the platform.
      expect(
        await offerWith(['audio', 'video'], 1),
        VoicePeerIntake.refusedMedia,
      );
      expect(await offerWith(['video'], 2), VoicePeerIntake.refusedMedia);
      expect(
        await offerWith(['audio', 'application'], 3),
        VoicePeerIntake.refusedMedia,
      );
      expect(
        await offerWith(['audio', 'audio'], 4),
        VoicePeerIntake.refusedMedia,
      );
      expect(joiner.platform.calls, isEmpty);
      expect(joiner.signalling.sent, isEmpty);

      // Nor does an answer that carries one.
      await participant.connection.negotiate();
      await settle();
      final offer = participant.sentOf(VoiceSignalKind.offer).single;
      final answer = await participant.connection.receive(
        received(
          messageFrom(
            joiner,
            VoiceAnswer(
              targetJoinId: participant.joinId,
              sdp: fakeSdp(
                type: VoiceDescriptionType.answer,
                ufrag: 'shape',
                sections: ['audio', 'video'],
              ),
              answersCounter: offer.counter,
            ),
            counter: 1,
          ),
          userId: joiner.userId,
          deviceId: joiner.deviceId,
        ),
      );
      expect(answer, VoicePeerIntake.refusedMedia);
      expect(participant.platform.remoteDescriptionsApplied, isEmpty);

      // And every description this device sends is one audio section.
      await exchange(participant, joiner);
      for (final signal in [
        ...participant.signalling.sent,
        ...joiner.signalling.sent,
      ]) {
        final body = signal.message.body;
        final sdp = switch (body) {
          VoiceOffer(:final sdp) || VoiceAnswer(:final sdp) => sdp,
          _ => null,
        };
        if (sdp != null) {
          expect(
            VoiceSessionDescription(
              type: VoiceDescriptionType.offer,
              sdp: sdp,
            ).isAudioOnly,
            isTrue,
          );
        }
      }
    });

    test('the configuration holds no STUN server', () async {
      final (participant, joiner) = await openPair();
      await participant.connection.negotiate();
      await exchange(participant, joiner);
      await participant.connection.restartIce(
        relayCredential(username: 'next', password: 'next').iceConfiguration,
      );
      await exchange(participant, joiner);

      final configurations = [
        ...participant.platform.configurations,
        ...joiner.platform.configurations,
      ];
      expect(configurations, hasLength(3));
      for (final configuration in configurations) {
        expect(configuration.transportPolicy, IceTransportPolicy.relay);
        expect(configuration.servers, isNotEmpty);
        for (final server in configuration.servers) {
          expect(server.url, startsWith('turn:'));
          expect(server.url, isNot(contains('stun')));
        }
      }
      // A credential naming a STUN server cannot be built in the first place.
      expect(
        () => RelayCredential(
          urls: const ['stun:chat.orviniq.com:3478'],
          username: relayUsername,
          credential: relayPassword,
          lifetime: const Duration(hours: 6),
          expiresAt: DateTime.utc(2026, 9, 30, 18),
        ),
        throwsArgumentError,
      );
    });
  });

  group('ICE restart', () {
    test('an ICE restart applies the new credential and does not close the '
        'connection', () async {
      final (participant, joiner) = await openPair();
      await participant.connection.negotiate();
      await exchange(participant, joiner);
      expectNegotiated(participant, joiner);
      final before = participant.platform.currentLocal!.sdp;
      final next = relayCredential(
        username: '1757373600:NextNextNextNextNextNe==',
        password: 'NextPasswordNextPassword0=',
      );

      final restarted = await participant.connection.restartIce(
        next.iceConfiguration,
      );

      expect(restarted, isA<Success<void>>());
      final applied = participant.platform.configurations.last;
      expect(applied, same(next.iceConfiguration));
      expect(
        applied.servers.map((server) => (server.username, server.credential)),
        everyElement((next.username, next.credential)),
      );
      expect(participant.platform.restarts, 1);
      expect(participant.connection.isRestartingIce, isTrue);
      final restartOffer =
          participant.sentOf(VoiceSignalKind.offer).last.message.body
              as VoiceOffer;
      expect(ufragOf(restartOffer.sdp), isNot(ufragOf(before)));

      await exchange(participant, joiner);

      expect(participant.connection.isRestartingIce, isFalse);
      expectNegotiated(participant, joiner);
      expect(participant.platform.closed, isFalse);
      expect(joiner.platform.closed, isFalse);
      expect(participant.audio.holds.single.released, isFalse);
      expect(joiner.audio.holds.single.released, isFalse);
      expect(
        ufragOf(joiner.platform.currentRemote!.sdp),
        ufragOf(restartOffer.sdp),
      );
      // The restart gathered again and sent the new candidates.
      expect(participant.sentOf(VoiceSignalKind.candidates), hasLength(2));
      expect(
        participant.events.whereType<VoicePeerIceRestart>().map(
          (event) => event.inProgress,
        ),
        [true, false],
      );
      for (final device in [participant, joiner]) {
        expect(
          device.events.whereType<VoicePeerStateChanged>().map(
            (event) => event.state,
          ),
          [VoicePeerState.connected],
        );
      }
    });

    test('a restart asked for while an offer is outstanding waits', () async {
      final (participant, joiner) = await openPair();
      await participant.connection.negotiate();
      await settle();

      await participant.connection.restartIce(
        relayCredential(username: 'next', password: 'next').iceConfiguration,
      );
      expect(participant.sentOf(VoiceSignalKind.offer), hasLength(1));
      expect(participant.connection.isRestartingIce, isTrue);

      await exchange(participant, joiner);

      expect(participant.sentOf(VoiceSignalKind.offer), hasLength(2));
      expect(participant.platform.restarts, 1);
      expect(participant.connection.isRestartingIce, isFalse);
      expectNegotiated(participant, joiner);
    });

    test(
      'a restart the polite peer loses to a collision is offered again',
      () async {
        final (polite, impolite) = await openPair();
        await polite.connection.negotiate();
        await exchange(polite, impolite);
        final next = relayCredential(username: 'next', password: 'next');

        await Future.wait([
          polite.connection.restartIce(next.iceConfiguration),
          impolite.connection.restartIce(next.iceConfiguration),
        ]);
        await exchange(polite, impolite);

        expectNegotiated(polite, impolite);
        expect(polite.platform.rollbacks, 1);
        expect(polite.platform.restarts, 2);
        expect(impolite.platform.restarts, 1);
        expect(polite.connection.isRestartingIce, isFalse);
        expect(impolite.connection.isRestartingIce, isFalse);
        expect(polite.platform.closed, isFalse);
        expect(impolite.platform.closed, isFalse);
      },
    );

    test(
      'before anything is negotiated, the configuration is only applied',
      () async {
        final (participant, _) = await openPair();
        final next = relayCredential(username: 'next', password: 'next');

        await participant.connection.restartIce(next.iceConfiguration);

        expect(
          participant.platform.configurations.last,
          same(next.iceConfiguration),
        );
        expect(participant.platform.restarts, 0);
        expect(participant.signalling.sent, isEmpty);
        expect(participant.connection.isRestartingIce, isFalse);
      },
    );
  });

  group('state', () {
    test(
      'connected, disconnected, failed and closed are reported upward',
      () async {
        final (participant, _) = await openPair();
        final platform = participant.platform;
        expect(participant.connection.state, VoicePeerState.connecting);

        for (final state in [
          VoiceMediaState.connecting,
          VoiceMediaState.connected,
          VoiceMediaState.disconnected,
          VoiceMediaState.connected,
          VoiceMediaState.failed,
        ]) {
          platform.emit(VoiceMediaStateChanged(state));
        }
        await settle();
        await participant.connection.close();
        await settle();

        expect(
          participant.events.whereType<VoicePeerStateChanged>().map(
            (event) => event.state,
          ),
          [
            VoicePeerState.connected,
            VoicePeerState.disconnected,
            VoicePeerState.connected,
            VoicePeerState.failed,
            VoicePeerState.closed,
          ],
        );
        expect(participant.connection.state, VoicePeerState.closed);
      },
    );

    test('closing releases the track and the platform connection', () async {
      final (participant, joiner) = await openPair();
      await participant.connection.negotiate();
      await exchange(participant, joiner);

      await participant.connection.close();
      await participant.connection.close();

      expect(participant.platform.closed, isTrue);
      expect(participant.audio.holds.single.released, isTrue);
      expect(participant.audio.holds.single.releases, 1);
      expect(
        await participant.connection.receive(
          received(
            messageFrom(
              joiner,
              VoiceCandidates(
                targetJoinId: participant.joinId,
                candidates: [fakeRelayCandidate('late')],
                end: true,
              ),
              counter: 40,
            ),
            userId: joiner.userId,
            deviceId: joiner.deviceId,
          ),
        ),
        VoicePeerIntake.closed,
      );
      expect(await participant.connection.resend(), isNull);
    });

    test('the platform closing the connection closes it here', () async {
      final (participant, _) = await openPair();

      participant.platform.emit(
        const VoiceMediaStateChanged(VoiceMediaState.closed),
      );
      await settle();

      expect(participant.connection.state, VoicePeerState.closed);
      expect(participant.audio.holds.single.released, isTrue);
    });

    test(
      'a platform refusal of this device\'s own offer is a failure',
      () async {
        final (participant, _) = await openPair();
        participant.platform.failing.add('createOffer');

        await participant.connection.negotiate();
        await settle();

        expect(participant.connection.state, VoicePeerState.failed);
        expect(participant.signalling.sent, isEmpty);
        // A failed connection stays failed whatever the platform says next.
        participant.platform.emit(
          const VoiceMediaStateChanged(VoiceMediaState.connected),
        );
        await settle();
        expect(participant.connection.state, VoicePeerState.failed);
      },
    );

    test('the hold is given back when no platform connection opens', () async {
      final device = end(
        name: 'a',
        userId: lowUser,
        deviceId: lowDevice,
        joinByte: 0xa1,
      );
      final peer = end(
        name: 'b',
        userId: highUser,
        deviceId: highDevice,
        joinByte: 0xb1,
      );
      device.media.refuse = true;

      final opened = await openConnection(device, peer);

      expect(opened, isA<FailureResult<VoicePeerConnection>>());
      expect(device.audio.holds.single.released, isTrue);
    });

    test('a connection to this device itself is refused', () async {
      final device = end(
        name: 'a',
        userId: lowUser,
        deviceId: lowDevice,
        joinByte: 0xa1,
      );

      final opened = await openConnection(device, device);

      expect(opened, isA<FailureResult<VoicePeerConnection>>());
      expect(device.audio.holds, isEmpty);
      expect(device.media.opened, isEmpty);
    });
  });

  test(
    'no description, candidate or credential reaches a log line or a string',
    () async {
      const nextUsername = '1757373600:NextNextNextNextNextNe==';
      const nextPassword = 'NextPasswordNextPassword0=';
      final printed = <String>[];
      final written = <String>[];
      // Restored inside the body: a foundation debug variable must not
      // outlive the test.
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) {
          printed.add(message);
        }
      };
      try {
        await runZoned(
          () async {
            final (participant, joiner) = await openPair();
            await participant.connection.negotiate();
            await exchange(participant, joiner);
            await participant.connection.restartIce(
              relayCredential(
                username: nextUsername,
                password: nextPassword,
              ).iceConfiguration,
            );
            await exchange(participant, joiner);
            final intakes = await deliver(joiner, participant);
            await participant.connection.close();
            await settle();
            for (final device in [participant, joiner]) {
              final platform = device.platform;
              written
                ..addAll(intakes.map((intake) => intake.toString()))
                ..addAll(device.events.map((event) => event.toString()))
                ..add(device.connection.toString())
                ..add(device.connection.join.toString())
                ..add(device.connection.peer.toString())
                ..add(platform.currentLocal.toString())
                ..add(platform.currentRemote.toString())
                ..addAll(platform.remoteCandidates.map((it) => it.toString()));
              for (final signal in device.signalling.sent) {
                written
                  ..add(signal.message.toString())
                  ..add(signal.message.header.toString())
                  ..add(signal.message.body.toString());
              }
            }
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => printed.add(line),
          ),
        );
      } finally {
        debugPrint = original;
      }

      expect(written, isNotEmpty);
      for (final text in [...printed, ...written]) {
        for (final secret in [
          'a=fingerprint',
          'ice-pwd',
          'ice-ufrag',
          'typ relay',
          '198.51.100.7',
          relayUsername,
          relayPassword,
          nextUsername,
          nextPassword,
        ]) {
          expect(text, isNot(contains(secret)));
        }
      }
    },
  );
}
