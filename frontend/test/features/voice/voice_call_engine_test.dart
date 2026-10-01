import 'dart:async';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/voice_peer_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/application/voice_call_engine.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_peer_model.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/call_fakes.dart';
import 'support/peer_fakes.dart';

/// The platform connection [from] opened to [to]: the one whose remote
/// description carries [to]'s ICE credentials.
FakePeerMedia connectionTo(CallDevice from, CallDevice to) =>
    from.media.opened.lastWhere(
      (connection) =>
          connection.currentRemote?.sdp.contains('a=ice-ufrag:d${to.index}-') ??
          false,
    );

Uint8List joinIdOf(CallMesh mesh, CallDevice device) => [
  for (final frame in mesh.network.frames)
    if (frame.from == device.deviceId) frame,
].last.message.header.joinId;

/// A message as [fromUserId]'s device [fromDeviceId] would seal it.
VoiceSignalMessage messageFrom({
  required String fromUserId,
  required String fromDeviceId,
  required VoiceSignalBody body,
  required Uint8List joinId,
  int counter = 1,
  String roomId = callRoomId,
}) => VoiceSignalMessage(
  header: VoiceSignalHeader(
    roomId: Uint8List.fromList([
      for (var index = 0; index < roomId.length; index += 2)
        int.parse(roomId.substring(index, index + 2), radix: 16),
    ]),
    joinId: joinId,
    senderUserId: protocolUuidBytes(fromUserId),
    senderDeviceId: protocolUuidBytes(fromDeviceId),
    counter: counter,
    createdMs: 0,
  ),
  body: body,
);

String offerSdp(String ufrag) =>
    fakeSdp(type: VoiceDescriptionType.offer, ufrag: ufrag);

void expectFullMesh(List<CallDevice> devices) {
  for (final device in devices) {
    final others = [
      for (final other in devices)
        if (other != device) other,
    ];
    expect(device.state.phase, VoiceCallPhase.inCall);
    expect(
      [
        for (final participant in device.state.participants)
          participant.deviceId,
      ],
      [for (final other in others) other.deviceId],
    );
    for (final other in others) {
      expect(device.statusOf(other), VoiceParticipantStatus.connected);
    }
    // One platform connection for each peer, and none opened twice.
    expect(device.media.opened, hasLength(others.length));
    expect(device.openConnections, hasLength(others.length));
  }
}

void main() {
  late CallMesh mesh;

  setUp(() => mesh = CallMesh());
  tearDown(() => mesh.dispose());

  group('joining', () {
    test('three devices join, and each pair holds one connection', () async {
      final devices = [mesh.device(0), mesh.device(1), mesh.device(2)];

      await mesh.joinAll(devices);

      expectFullMesh(devices);
      for (var left = 0; left < devices.length; left += 1) {
        for (var right = left + 1; right < devices.length; right += 1) {
          final between = [
            for (final frame in mesh.network.frames)
              if (frame.kind == VoiceSignalKind.offer &&
                  {frame.from, frame.to}.containsAll({
                    devices[left].deviceId,
                    devices[right].deviceId,
                  }))
                frame,
          ];
          // One negotiation for the pair, offered by the device that was
          // already in the call when the other joined (§N rule 4).
          expect(between, hasLength(1));
          expect(between.single.from, devices[left].deviceId);
        }
      }
      expect(mesh.network.invalidSends, isEmpty);
    });

    test('devices that join at the same moment still hold one connection '
        'per pair', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      final c = mesh.device(2);
      await mesh.joinAll([a]);

      final joiningB = b.engine.join(callRoomId);
      final joiningC = c.engine.join(callRoomId);
      await mesh.clock.elapse(const Duration(seconds: 30));

      expect(await joiningB, isA<VoiceJoinAnnounced>());
      expect(await joiningC, isA<VoiceJoinAnnounced>());
      expectFullMesh([a, b, c]);
      expect(mesh.network.invalidSends, isEmpty);
    });

    test('the credential is minted and the sessions started before the first '
        'frame', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);

      await mesh.joinAll([a, b]);

      for (final device in [a, b]) {
        expect(device.relay.mints, hasLength(1));
        expect(device.relay.framesAtMint, [0]);
        expect(device.sessions.prepared, [callRoomId]);
        expect(device.sessions.framesAtPreparation, [0]);
      }
      // The relay-only configuration of that credential is the one each
      // connection was opened with.
      expect(a.media.opened.single.configurations, hasLength(1));
      expect(
        a.media.opened.single.configurations.single.transportPolicy.name,
        'relay',
      );
    });

    test('the query goes out first, and the join after the first answer '
        'window', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a]);
      final start = mesh.clock.now();

      await mesh.join(b);

      final query = mesh.network
          .framesOf(VoiceSignalKind.participantsQuery, from: b.deviceId)
          .first;
      final join = mesh.network
          .framesOf(VoiceSignalKind.join, from: b.deviceId)
          .first;
      expect(query.at, start);
      expect(join.at, start.add(const Duration(seconds: 2)));
      expect(join.counter, greaterThan(query.counter));
    });

    test('a room this device may not call in is refused before anything is '
        'minted or sent', () async {
      final cases = <(RoomLifecycle?, VoiceCallEndReason)>[
        (
          RoomLifecycle.stateRecoveryRequired,
          VoiceCallEndReason.roomWaitingForState,
        ),
        (RoomLifecycle.forkQuarantined, VoiceCallEndReason.roomQuarantined),
      ];
      final a = mesh.device(0);
      for (final (lifecycle, reason) in cases) {
        mesh.room.setLifecycleForAll(lifecycle);
        final outcome = await mesh.join(a);
        expect(
          outcome,
          isA<VoiceJoinRefused>().having((o) => o.reason, 'reason', reason),
        );
        expect(a.state.phase, VoiceCallPhase.ended);
        expect(a.state.endReason, reason);
      }
      mesh.room.setLifecycleForAll(null);
      mesh.room.remove(a.userId, by: mesh.device(1).userId);
      expect(
        await mesh.join(a),
        isA<VoiceJoinRefused>().having(
          (o) => o.reason,
          'reason',
          VoiceCallEndReason.removedFromRoom,
        ),
      );

      final outsiders = CallMesh(accounts: 3, members: [0, 1]);
      addTearDown(outsiders.dispose);
      final outsider = outsiders.device(2);
      expect(
        await outsiders.join(outsider),
        isA<VoiceJoinRefused>().having(
          (o) => o.reason,
          'reason',
          VoiceCallEndReason.roomUnavailable,
        ),
      );

      expect(a.relay.mints, isEmpty);
      expect(outsider.relay.mints, isEmpty);
      expect(mesh.network.frames, isEmpty);
      expect(outsiders.network.frames, isEmpty);
    });

    test('a join that gets no credential says why and sends nothing', () async {
      final a = mesh.device(0);

      a.relay.answer = const Result.failure(
        BackendFailure(
          BackendFailureCode.throttled,
          retryAfter: Duration(seconds: 30),
        ),
      );
      final throttled = await mesh.join(a);
      expect(
        throttled,
        isA<VoiceJoinRefused>()
            .having((o) => o.reason, 'reason', VoiceCallEndReason.throttled)
            .having((o) => o.retryAt, 'retryAt', isNotNull),
      );
      expect(a.state.retryAt, (throttled as VoiceJoinRefused).retryAt);

      await mesh.clock.elapse(const Duration(seconds: 31));
      a.relay.answer = const Result.failure(
        TransportFailure(TransportFailureKind.offline),
      );
      expect(
        await mesh.join(a),
        isA<VoiceJoinRefused>().having(
          (o) => o.reason,
          'reason',
          VoiceCallEndReason.credentialFailed,
        ),
      );

      a.relay.answer = const Result.failure(
        BackendFailure(BackendFailureCode.voiceUnconfigured),
      );
      expect(
        await mesh.join(a),
        isA<VoiceJoinRefused>().having(
          (o) => o.reason,
          'reason',
          VoiceCallEndReason.voiceUnavailable,
        ),
      );
      // After `503 voice_unconfigured` nothing is asked again.
      a.relay.answer = null;
      expect(
        await mesh.join(a),
        isA<VoiceJoinRefused>().having(
          (o) => o.reason,
          'reason',
          VoiceCallEndReason.voiceUnavailable,
        ),
      );
      expect(a.relay.mints, hasLength(3));
      expect(a.sessions.prepared, isEmpty);
      expect(mesh.network.frames, isEmpty);
    });

    test(
      'leaving while the join is being prepared announces nothing',
      () async {
        final a = mesh.device(0);

        final joining = a.engine.join(callRoomId);
        await a.engine.leave();
        await mesh.clock.elapse(const Duration(seconds: 3));

        expect(
          await joining,
          isA<VoiceJoinRefused>().having(
            (o) => o.reason,
            'reason',
            VoiceCallEndReason.left,
          ),
        );
        expect(mesh.network.frames, isEmpty);
      },
    );

    test('a second join while a call runs is refused', () async {
      final a = mesh.device(0);
      await mesh.joinAll([a]);

      expect(
        await a.engine.join(callRoomId),
        isA<VoiceJoinRefused>().having(
          (o) => o.reason,
          'reason',
          VoiceCallEndReason.alreadyInCall,
        ),
      );
      expect(a.state.phase, VoiceCallPhase.inCall);
    });
  });

  group('leaving and dropping', () {
    test('a leave drops the device from every other device', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      final c = mesh.device(2);
      await mesh.joinAll([a, b, c]);

      await b.engine.leave();
      await mesh.clock.elapse(const Duration(seconds: 1));

      expect(b.state.phase, VoiceCallPhase.ended);
      expect(b.state.endReason, VoiceCallEndReason.left);
      expect(b.state.participants, isEmpty);
      expect(b.openConnections, isEmpty);
      expect(b.signalling.forgotten, hasLength(1));
      expect([
        for (final frame in mesh.network.framesOf(
          VoiceSignalKind.leave,
          from: b.deviceId,
        ))
          frame.to,
      ], unorderedEquals([a.deviceId, c.deviceId]));
      for (final (stayed, other) in [(a, c), (c, a)]) {
        expect(stayed.participant(b), isNull);
        expect(stayed.statusOf(other), VoiceParticipantStatus.connected);
        expect(stayed.openConnections, hasLength(1));
      }
    });

    test('a connection that closes, or fails, drops the device', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      final c = mesh.device(2);
      await mesh.joinAll([a, b, c]);

      connectionTo(
        a,
        c,
      ).emit(const VoiceMediaStateChanged(VoiceMediaState.closed));
      await mesh.clock.elapse(const Duration(seconds: 1));
      expect(a.participant(c), isNull);
      expect(a.statusOf(b), VoiceParticipantStatus.connected);

      connectionTo(
        b,
        a,
      ).emit(const VoiceMediaStateChanged(VoiceMediaState.failed));
      await mesh.clock.elapse(const Duration(seconds: 1));
      expect(b.participant(a), isNull);
      expect(connectionTo(b, a).closed, isTrue);
      expect(b.statusOf(c), VoiceParticipantStatus.connected);

      // The join that closed is over here: its later frames are refused.
      await c.engine.sendRoomText('still there?');
      await mesh.clock.elapse(const Duration(seconds: 1));
      expect(a.state.roomText, isEmpty);
      expect(b.state.roomText.single.text, 'still there?');
    });

    test('a device that joins again replaces its old connection', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a, b]);
      final firstJoin = joinIdOf(mesh, b);

      // B's leave never reaches A, as when an app is killed.
      mesh.network.cut.add((b.deviceId, a.deviceId));
      await b.engine.leave();
      mesh.network.cut.clear();
      await mesh.joinAll([b]);

      expect(joinIdOf(mesh, b), isNot(firstJoin));
      expect(a.media.opened, hasLength(2));
      expect(a.media.opened.first.closed, isTrue);
      expect(a.openConnections, hasLength(1));
      expect(a.statusOf(b), VoiceParticipantStatus.connected);
      expect(b.statusOf(a), VoiceParticipantStatus.connected);
    });
  });

  group('presence', () {
    test('a query gets an answer from each participant', () async {
      mesh = CallMesh(accounts: 5);
      final participants = [mesh.device(0), mesh.device(1), mesh.device(2)];
      final idle = mesh.device(3);
      await mesh.joinAll(participants);
      final joiner = mesh.device(4);

      await mesh.join(joiner);

      expect(
        {
          for (final frame in mesh.network.framesOf(
            VoiceSignalKind.participantsQuery,
            from: joiner.deviceId,
          ))
            frame.to,
        },
        {
          for (final device in [...participants, idle]) device.deviceId,
        },
      );
      final expected = {
        for (final participant in participants) participant.deviceId,
      };
      for (final participant in participants) {
        final answers = mesh.network.framesOf(
          VoiceSignalKind.participants,
          from: participant.deviceId,
          to: joiner.deviceId,
        );
        expect(answers, hasLength(1));
        final members =
            (answers.single.message.body as VoiceParticipants).members;
        // The devices it believes are in the call, itself included.
        expect({
          for (final member in members) protocolUuidString(member.deviceId),
        }, expected);
        final own = members.singleWhere(
          (member) =>
              protocolUuidString(member.deviceId) == participant.deviceId,
        );
        expect(own.joinId, joinIdOf(mesh, participant));
      }
      // Only a participant answers.
      expect(
        mesh.network.framesOf(
          VoiceSignalKind.participants,
          from: idle.deviceId,
        ),
        isEmpty,
      );

      await mesh.clock.elapse(const Duration(seconds: 25));
      expectFullMesh([...participants, joiner]);
    });
  });

  group('room text', () {
    test('room text reaches each participant', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      final c = mesh.device(2);
      await mesh.joinAll([a, b, c]);

      expect(
        await a.engine.sendRoomText('Can everyone hear me?'),
        isA<Success<void>>(),
      );
      await mesh.clock.elapse(const Duration(seconds: 1));

      expect([
        for (final frame in mesh.network.framesOf(
          VoiceSignalKind.roomText,
          from: a.deviceId,
        ))
          frame.to,
      ], unorderedEquals([b.deviceId, c.deviceId]));
      for (final other in [b, c]) {
        final entry = other.state.roomText.single;
        expect(entry.text, 'Can everyone hear me?');
        expect(entry.isOwn, isFalse);
        expect(entry.senderUserId, a.userId);
        expect(entry.senderDeviceId, a.deviceId);
      }
      // Shown on the sender because it sent it: there is no echo.
      expect(a.state.roomText.single.isOwn, isTrue);
      expect(a.state.roomText.single.text, 'Can everyone hear me?');
    });

    test('room text that cannot travel is refused, and the text goes with '
        'the call', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a, b]);
      final sent = mesh.network.frames.length;

      expect(
        await a.engine.sendRoomText('x' * 2001),
        isA<FailureResult<void>>().having(
          (result) => result.failure,
          'failure',
          const ValidationFailure(ValidationFailureKind.limitExceeded),
        ),
      );
      expect(await a.engine.sendRoomText(''), isA<FailureResult<void>>());
      expect(mesh.network.frames, hasLength(sent));
      expect(a.state.roomText, isEmpty);

      await a.engine.sendRoomText('bye');
      await mesh.clock.elapse(const Duration(seconds: 1));
      expect(b.state.roomText, hasLength(1));
      await b.engine.leave();
      expect(b.state.roomText, isEmpty);
      expect(
        await b.engine.sendRoomText('anyone?'),
        isA<FailureResult<void>>(),
      );
    });
  });

  group('the ceiling', () {
    test('an eleventh participant is refused with its reason, and announces '
        'nothing', () async {
      mesh = CallMesh(accounts: 11);
      final ten = [
        for (var index = 0; index < 10; index += 1) mesh.device(index),
      ];
      await mesh.joinAll(ten);
      expectFullMesh(ten);
      final eleventh = mesh.device(10);

      final outcome = await mesh.join(eleventh);
      await mesh.clock.elapse(const Duration(seconds: 25));

      expect(
        outcome,
        isA<VoiceJoinRefused>().having(
          (o) => o.reason,
          'reason',
          VoiceCallEndReason.callFull,
        ),
      );
      expect(eleventh.state.phase, VoiceCallPhase.ended);
      expect(eleventh.state.endReason, VoiceCallEndReason.callFull);
      expect(
        mesh.network.framesOf(VoiceSignalKind.join, from: eleventh.deviceId),
        isEmpty,
      );
      expect(eleventh.media.opened, isEmpty);
      expectFullMesh(ten);
    });

    test('of two devices that join a nine-device call at once, the one '
        'outside the ten lowest is refused', () async {
      mesh = CallMesh(accounts: 11);
      final nine = [
        for (var index = 0; index < 9; index += 1) mesh.device(index),
      ];
      await mesh.joinAll(nine);
      final tenth = mesh.device(9);
      final eleventh = mesh.device(10);
      // At once: neither hears the other before it has announced itself.
      mesh.network.cut.addAll({
        (tenth.deviceId, eleventh.deviceId),
        (eleventh.deviceId, tenth.deviceId),
      });

      final joiningTenth = tenth.engine.join(callRoomId);
      final joiningEleventh = eleventh.engine.join(callRoomId);
      await mesh.clock.elapse(const Duration(seconds: 3));
      // Each found nine and room for itself, so both announced themselves.
      expect(await joiningTenth, isA<VoiceJoinAnnounced>());
      expect(await joiningEleventh, isA<VoiceJoinAnnounced>());
      mesh.network.cut.clear();
      await mesh.clock.elapse(const Duration(seconds: 30));

      // Every device kept the ten lowest ids, so nobody holds the eleventh.
      expect(eleventh.state.endReason, VoiceCallEndReason.callFull);
      expect(eleventh.openConnections, isEmpty);
      expectFullMesh([...nine, tenth]);
      for (final device in [...nine, tenth]) {
        expect(device.participant(eleventh), isNull);
      }
    });
  });

  group('retries', () {
    test('a silent device is reported not reachable after the bounded '
        'retries', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a]);

      // B's frames reach A, and nothing reaches B.
      mesh.network.deaf.add(b.deviceId);
      await mesh.join(b);
      List<CallFrame> offers() => mesh.network.framesOf(
        VoiceSignalKind.offer,
        from: a.deviceId,
        to: b.deviceId,
      );
      final first = offers().first.at;

      await mesh.clock.elapse(
        first.add(const Duration(seconds: 19)).difference(mesh.clock.now()),
      );
      expect(a.statusOf(b), VoiceParticipantStatus.connecting);
      await mesh.clock.elapse(const Duration(seconds: 2));

      expect(a.statusOf(b), VoiceParticipantStatus.notReachable);
      // Four attempts, the first at once and then after 2, 4 and 8 seconds,
      // each under the counter of the first.
      expect(
        [for (final offer in offers()) offer.at.difference(first)],
        [
          Duration.zero,
          const Duration(seconds: 2),
          const Duration(seconds: 6),
          const Duration(seconds: 14),
        ],
      );
      expect({for (final offer in offers()) offer.counter}, hasLength(1));
      expect(a.openConnections, isEmpty);

      // Nothing more is sent to it, room text and query answers included.
      final sent = mesh.network.frames.length;
      await a.engine.sendRoomText('hello?');
      mesh.network.inject(
        toDeviceId: a.deviceId,
        fromUserId: b.userId,
        fromDeviceId: b.deviceId,
        message: messageFrom(
          fromUserId: b.userId,
          fromDeviceId: b.deviceId,
          body: const VoiceParticipantsQuery(),
          joinId: joinIdOf(mesh, b),
          counter: 40,
        ),
      );
      await mesh.clock.elapse(const Duration(minutes: 1));
      expect([
        for (final frame in mesh.network.frames.skip(sent))
          if (frame.from == a.deviceId && frame.to == b.deviceId) frame,
      ], isEmpty);
      // Nobody else waited on it.
      expect(a.state.phase, VoiceCallPhase.inCall);
    });

    test('trying again re-arms the attempts', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a]);
      mesh.network.deaf.add(b.deviceId);
      await mesh.join(b);
      await mesh.clock.elapse(const Duration(seconds: 25));
      expect(a.statusOf(b), VoiceParticipantStatus.notReachable);

      mesh.network.deaf.clear();
      await a.engine.tryAgain(b.deviceId);
      expect(a.statusOf(b), VoiceParticipantStatus.connecting);
      await mesh.clock.elapse(const Duration(seconds: 5));

      expect(a.statusOf(b), VoiceParticipantStatus.connected);
      expect(b.statusOf(a), VoiceParticipantStatus.connected);
      expect(a.openConnections, hasLength(1));
      expect(b.openConnections, hasLength(1));
    });

    test('a lost answer is sent again when the offer comes again', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a]);

      // B's first answer is lost on the way to A.
      mesh.network.dropOnce.add((
        VoiceSignalKind.answer,
        b.deviceId,
        a.deviceId,
      ));
      await mesh.join(b);
      await mesh.clock.elapse(const Duration(seconds: 25));

      expect(
        mesh.network
            .framesOf(VoiceSignalKind.answer, from: b.deviceId)
            .first
            .dropped,
        isTrue,
      );

      expect(a.statusOf(b), VoiceParticipantStatus.connected);
      expect(b.statusOf(a), VoiceParticipantStatus.connected);
      final answers = mesh.network.framesOf(
        VoiceSignalKind.answer,
        from: b.deviceId,
      );
      expect(answers.length, greaterThan(1));
      expect({for (final answer in answers) answer.counter}, hasLength(1));
    });

    test('a join announcement stops for each device that offered', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      final c = mesh.device(2);
      await mesh.joinAll([a, b]);

      await mesh.join(c);
      await mesh.clock.elapse(const Duration(seconds: 25));

      for (final participant in [a, b]) {
        expect(
          mesh.network.framesOf(
            VoiceSignalKind.join,
            from: c.deviceId,
            to: participant.deviceId,
          ),
          hasLength(1),
        );
      }
      expect(c.state.announcing, isFalse);
    });
  });

  group('removal', () {
    test('a removal closes the member\'s connections at once, and a later '
        'offer from that member is refused', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      final c = mesh.device(2);
      await mesh.joinAll([a, b, c]);
      final aToC = connectionTo(a, c);
      final bToC = connectionTo(b, c);
      final aJoin = joinIdOf(mesh, a);

      // A is busy: a send it is waiting on has not finished.
      final held = Completer<void>();
      a.signalling.holds[VoiceSignalKind.roomText] = held;
      final sending = a.engine.sendRoomText('one moment');
      await settleCall();

      mesh.room.remove(c.userId, by: a.userId);
      await settleCall();

      // Closed although A's call has not finished what it was doing.
      expect(aToC.closed, isTrue);
      expect(bToC.closed, isTrue);
      // The removed device closes its own connections and ends its call.
      expect(c.openConnections, isEmpty);
      expect(c.state.endReason, VoiceCallEndReason.removedFromRoom);

      a.signalling.holds.clear();
      held.complete();
      await sending;
      await mesh.clock.elapse(const Duration(seconds: 1));
      expect(a.participant(c), isNull);
      expect(b.participant(c), isNull);
      expect(a.statusOf(b), VoiceParticipantStatus.connected);

      // From then on their offers and announcements are refused, whatever
      // join they name.
      final opened = a.media.opened.length;
      final sent = mesh.network.frames.length;
      for (final body in <VoiceSignalBody>[
        VoiceOffer(targetJoinId: aJoin, sdp: offerSdp('removed1')),
        const VoiceJoin(),
        const VoiceParticipantsQuery(),
        VoiceRoomText('let me back in'),
      ]) {
        mesh.network.inject(
          toDeviceId: a.deviceId,
          fromUserId: c.userId,
          fromDeviceId: c.deviceId,
          message: messageFrom(
            fromUserId: c.userId,
            fromDeviceId: c.deviceId,
            body: body,
            joinId: filled(16, 0xcc),
            counter: 9,
          ),
        );
      }
      await mesh.clock.elapse(const Duration(seconds: 25));

      expect(a.media.opened, hasLength(opened));
      expect([
        for (final frame in mesh.network.frames.skip(sent))
          if (frame.from == a.deviceId) frame,
      ], isEmpty);
      expect(a.state.roomText.where((entry) => !entry.isOwn), isEmpty);
      expect(a.participant(c), isNull);
    });

    test(
      'a room that can no longer hold a call ends it on every device',
      () async {
        final devices = [mesh.device(0), mesh.device(1), mesh.device(2)];
        await mesh.joinAll(devices);

        mesh.room.setLifecycleForAll(RoomLifecycle.stateRecoveryRequired);
        await settleCall();

        for (final device in devices) {
          expect(device.openConnections, isEmpty);
          expect(
            device.state.endReason,
            VoiceCallEndReason.roomWaitingForState,
          );
        }
      },
    );
  });

  group('membership', () {
    test('a frame from a device that is not a member is refused', () async {
      mesh = CallMesh(accounts: 4, members: [0, 1, 2]);
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a, b]);
      final outsider = mesh.device(3);
      final aJoin = joinIdOf(mesh, a);
      final opened = a.media.opened.length;
      final sent = mesh.network.frames.length;

      for (final body in <VoiceSignalBody>[
        const VoiceJoin(),
        VoiceOffer(targetJoinId: aJoin, sdp: offerSdp('outsider1')),
        const VoiceParticipantsQuery(),
        VoiceRoomText('hello from outside'),
        VoiceParticipants([
          VoiceParticipant(
            userId: protocolUuidBytes(outsider.userId),
            deviceId: protocolUuidBytes(outsider.deviceId),
            joinId: filled(16, 0xee),
          ),
        ]),
      ]) {
        mesh.network.inject(
          toDeviceId: a.deviceId,
          fromUserId: outsider.userId,
          fromDeviceId: outsider.deviceId,
          message: messageFrom(
            fromUserId: outsider.userId,
            fromDeviceId: outsider.deviceId,
            body: body,
            joinId: filled(16, 0xee),
          ),
        );
      }
      await mesh.clock.elapse(const Duration(seconds: 25));

      expect(a.media.opened, hasLength(opened));
      expect([
        for (final frame in mesh.network.frames.skip(sent))
          if (frame.from == a.deviceId) frame,
      ], isEmpty);
      expect(a.state.roomText, isEmpty);
      expect([for (final p in a.state.participants) p.deviceId], [b.deviceId]);
    });

    test('a leave naming a join that is not current is ignored', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a, b]);

      // A late retry of an old call's leave cannot drop B out of this one.
      mesh.network.inject(
        toDeviceId: a.deviceId,
        fromUserId: b.userId,
        fromDeviceId: b.deviceId,
        message: messageFrom(
          fromUserId: b.userId,
          fromDeviceId: b.deviceId,
          body: const VoiceLeave(VoiceLeaveReason.userLeft),
          joinId: filled(16, 0xbb),
          counter: 40,
        ),
      );
      await mesh.clock.elapse(const Duration(seconds: 1));

      expect(a.statusOf(b), VoiceParticipantStatus.connected);
      expect(a.openConnections, hasLength(1));
    });

    test('an answer names nobody the roster does not hold', () async {
      mesh = CallMesh(accounts: 4, members: [0, 1, 2]);
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a, b]);
      final outsider = mesh.device(3);

      // B vouches for a device of an account that is not in the room, and
      // for a device of a member that no device list names.
      mesh.network.inject(
        toDeviceId: a.deviceId,
        fromUserId: b.userId,
        fromDeviceId: b.deviceId,
        message: messageFrom(
          fromUserId: b.userId,
          fromDeviceId: b.deviceId,
          body: VoiceParticipants([
            VoiceParticipant(
              userId: protocolUuidBytes(outsider.userId),
              deviceId: protocolUuidBytes(outsider.deviceId),
              joinId: filled(16, 0xe1),
            ),
            VoiceParticipant(
              userId: protocolUuidBytes(callUserId(2)),
              deviceId: protocolUuidBytes(callDeviceId(9)),
              joinId: filled(16, 0xe2),
            ),
          ]),
          joinId: joinIdOf(mesh, b),
          counter: 40,
        ),
      );
      await mesh.clock.elapse(const Duration(seconds: 25));

      expect([for (final p in a.state.participants) p.deviceId], [b.deviceId]);
    });

    test('a frame for another room is ignored', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a, b]);
      final sent = mesh.network.frames.length;

      mesh.network.inject(
        toDeviceId: a.deviceId,
        fromUserId: b.userId,
        fromDeviceId: b.deviceId,
        message: messageFrom(
          fromUserId: b.userId,
          fromDeviceId: b.deviceId,
          body: const VoiceParticipantsQuery(),
          joinId: joinIdOf(mesh, b),
          roomId: 'ab' * 32,
        ),
      );
      await mesh.clock.elapse(const Duration(seconds: 1));

      expect(mesh.network.frames, hasLength(sent));
    });
  });

  group('peers this build cannot talk to', () {
    test('a changed safety number closes that peer only', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      final c = mesh.device(2);
      await mesh.joinAll([a, b, c]);

      a.signalling.refusals[c.deviceId] = VoiceSignalRefusal.identityBlocked;
      await a.engine.sendRoomText('hi');
      await mesh.clock.elapse(const Duration(seconds: 1));

      expect(a.statusOf(c), VoiceParticipantStatus.identityBlocked);
      expect(connectionTo(a, c).closed, isTrue);
      expect(a.statusOf(b), VoiceParticipantStatus.connected);
    });

    test('a peer on another major version says so on its tile', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a, b]);

      mesh.network.injectUnsupported(
        toDeviceId: a.deviceId,
        fromUserId: b.userId,
        fromDeviceId: b.deviceId,
      );
      await mesh.clock.elapse(const Duration(seconds: 1));

      expect(a.statusOf(b), VoiceParticipantStatus.incompatibleVersion);
      expect(a.openConnections, isEmpty);
    });

    test('a microphone that cannot be opened ends the call', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a]);
      a.audio.refuse = true;

      await mesh.joinAll([b]);

      expect(a.state.endReason, VoiceCallEndReason.localFailure);
      expect(
        mesh.network.framesOf(VoiceSignalKind.leave, from: a.deviceId),
        isEmpty,
      );
    });
  });

  group('the credential', () {
    test('a refresh under an hour restarts ICE on each connection and keeps '
        'it', () async {
      final a = mesh.device(0);
      final b = mesh.device(1);
      await mesh.joinAll([a, b]);
      final toB = connectionTo(a, b);

      // A six-hour credential is refreshed once less than an hour remains.
      await mesh.clock.elapse(const Duration(hours: 5));

      expect(a.relay.mints, hasLength(2));
      expect(toB.restarts, 1);
      expect(toB.configurations, hasLength(2));
      expect(a.media.opened, hasLength(1));
      expect(a.statusOf(b), VoiceParticipantStatus.connected);
      expect(a.participant(b)!.restartingIce, isFalse);
      expect(
        mesh.network.framesOf(
          VoiceSignalKind.offer,
          from: a.deviceId,
          to: b.deviceId,
        ),
        hasLength(2),
      );
    });
  });

  test('nothing about a call reaches a log line or a string form', () async {
    final printed = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) {
        printed.add(message);
      }
    };
    final strings = <String>[];
    try {
      await runZoned(
        () async {
          final a = mesh.device(0);
          final b = mesh.device(1);
          await mesh.joinAll([a, b]);
          await a.engine.sendRoomText('the secret plan');
          await mesh.clock.elapse(const Duration(seconds: 1));
          for (final state in [...a.states, ...b.states]) {
            strings
              ..add('$state')
              ..addAll([for (final p in state.participants) '$p'])
              ..addAll([for (final entry in state.roomText) '$entry']);
          }
          strings.add('${await mesh.join(a)}');
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
    } finally {
      debugPrint = original;
    }

    expect(printed, isEmpty);
    for (final text in strings) {
      for (final secret in [
        callRoomId,
        callUserId(0),
        callUserId(1),
        callDeviceId(0),
        callDeviceId(1),
        'the secret plan',
        'Standup',
      ]) {
        expect(text.contains(secret), isFalse, reason: text);
      }
    }
  });
}
