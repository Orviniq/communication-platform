import 'dart:async';

import 'package:communication_platform/core/application/signal_router.dart';
import 'package:communication_platform/features/signals/application/chat_activity.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/peer_read_fakes.dart';
import 'support/presence_fakes.dart';

/// Peer reads leave the path of a frame: a frame waits for a peer read only
/// when no answer under 60 s old exists, and the router lock is never held
/// across one.
void main() {
  final me = uuid(0x1000);
  final myDevice = uuid(0x900);
  final bob = uuid(0x1001);
  final b1 = uuid(0x901);
  final direct = conversationOf(0x11);

  late PresenceRig rig;
  FakePeerReads? reads;

  /// A rig whose channel asks the production peer cache, over reads that
  /// name [b1] for Bob.
  PresenceRig cachedRig() {
    final made = PresenceRig(
      userId: me,
      deviceId: myDevice,
      peersFor: (clock) {
        final made = reads = FakePeerReads(clock: clock)..devices[bob] = [b1];
        return cachedPeers(
          reads: made,
          trust: FakeContactTrust(),
          clock: clock,
          currentUserId: me,
        );
      },
    );
    made.conversations.held[direct] = PresenceDirectConversation(direct, bob);
    made.peers.devices[bob] = [b1];
    return made;
  }

  tearDown(() async {
    reads
      ?..hold = false
      ..release();
    reads = null;
    rig.peers.gate?.complete();
    await rig.close();
  });

  Future<void> watchFrom({bool settle = true}) => rig.deliver(
    PresenceWatch(
      conversationId: conversationBytes(direct),
      leaseMs: PresenceSignalLimits.watchLeaseMs,
    ),
    senderUser: bob,
    senderDevice: b1,
    settle: settle,
  );

  Future<void> typingFrom({bool settle = true}) => rig.deliver(
    PresenceTyping(
      conversationId: conversationBytes(direct),
      active: true,
      ttlMs: 15000,
    ),
    senderUser: bob,
    senderDevice: b1,
    settle: settle,
  );

  Future<List<String>> typersIn(String conversation) async => [
    for (final typing in await rig.state.watchTyping(conversation).first)
      typing.deviceId,
  ];

  test('T8: the first typing frame of a session leaves while the stale '
      'answer is read again', () async {
    rig = cachedRig();
    await watchFrom();
    expect(reads!.batches, hasLength(1), reason: 'the watch read Bob');

    await rig.advance(const Duration(seconds: 11));
    reads!.hold = true;
    rig.activity.report(ChatTextEdited(direct, hasText: true));
    await rig.pump();

    expect(
      rig.sealer.devicesOf(PresenceSignalKind.typing),
      [b1],
      reason: 'the start did not wait for the read',
    );
    expect(reads!.batches, hasLength(2), reason: 'the read started');
    expect(reads!.held, hasLength(1), reason: 'and is still pending');

    reads!.release();
    await rig.settle();
  });

  test('T9: a cold account is read before the router lock, and an inbound '
      'frame opens while that read is pending', () async {
    rig = PresenceRig(userId: me, deviceId: myDevice);
    rig.conversations.held[direct] = PresenceDirectConversation(direct, bob);
    rig.peers.devices[bob] = [b1];
    final routed = <RoutedSignal>[];
    final subscription = rig.router
        .channel(SignalChannel.presence)
        .listen(routed.add);
    addTearDown(subscription.cancel);
    await watchFrom();
    expect(routed, hasLength(1));

    // The fake keeps no answer, so the start's read is a cold one.
    final gate = rig.peers.gate = Completer<void>();
    rig.activity.report(ChatTextEdited(direct, hasText: true));
    await rig.pump();

    expect(
      rig.peers.including.last.map((device) => device.key),
      [b1],
      reason: 'the start reads its target before it seals',
    );
    expect(rig.sealer.devicesOf(PresenceSignalKind.typing), isEmpty);

    await typingFrom(settle: false);

    expect(routed, hasLength(2), reason: 'opened and routed meanwhile');

    rig.peers.gate = null;
    gate.complete();
    await rig.settle();

    expect(rig.sealer.devicesOf(PresenceSignalKind.typing), [b1]);
    expect(await typersIn(direct), [b1]);
  });

  test('T10: five minutes of an open chat read Bob at most 6 times a '
      'minute, and only the first read holds a frame back', () async {
    rig = cachedRig();
    final peerReads = reads!..hold = true;
    final t0 = rig.clock.now();
    var blocking = 0;

    // Lets everything run; a read that is held while the channel is not
    // idle is one a frame waits for.
    Future<void> settle() async {
      for (var round = 0; round < 1000; round += 1) {
        var quiet = false;
        unawaited(
          Future.wait([
            rig.channel.idle,
            rig.status.idle,
          ]).then((_) => quiet = true),
        );
        await rig.pump();
        if (peerReads.held.isEmpty) {
          if (quiet) {
            return;
          }
          continue;
        }
        if (!quiet) {
          blocking += peerReads.held.length;
        }
        peerReads.release();
      }
      fail('the channel never settled');
    }

    // Bob answers each watch sealed to him, at once.
    var answered = 0;
    Future<void> answerWatches() async {
      final watches = rig.sealer.devicesOf(PresenceSignalKind.watch);
      while (answered < watches.where((device) => device == b1).length) {
        answered += 1;
        await rig.deliver(
          PresenceHere(
            conversationId: conversationBytes(direct),
            typing: false,
          ),
          senderUser: bob,
          senderDevice: b1,
          settle: false,
        );
        await settle();
      }
    }

    rig.visibility.show(direct);
    await settle();
    await answerWatches();
    for (var second = 0; second < 300; second += 1) {
      // Bob shows the chat too, and renews his own watch every 25 s.
      if (second % 25 == 1) {
        await watchFrom(settle: false);
        await settle();
        await answerWatches();
      }
      if (second % 10 == 3) {
        rig.activity.report(ChatTextEdited(direct, hasText: true));
        await settle();
      }
      await rig.timers.advance(const Duration(seconds: 1), settle: settle);
      await answerWatches();
    }

    final perMinute = List<int>.filled(5, 0);
    for (final at in peerReads.readAt) {
      final minute = at.difference(t0).inSeconds ~/ 60;
      if (minute < 5) {
        perMinute[minute] += 1;
      }
    }
    final counts =
        'reads ${peerReads.batches.length}, per minute $perMinute, '
        'blocking $blocking';
    expect(
      rig.sealer.of(PresenceSignalKind.typing).length,
      greaterThanOrEqualTo(55),
      reason: 'a start and a stop every 10 s: $counts',
    );
    expect(perMinute, everyElement(lessThanOrEqualTo(6)), reason: counts);
    expect(blocking, 1, reason: counts);
  });

  test('T11: a typing frame is accepted at once on a stale answer, and its '
      'line shows in the same settle', () async {
    rig = cachedRig();
    await watchFrom();
    await rig.advance(const Duration(seconds: 11));
    reads!.hold = true;

    await typingFrom(settle: false);

    expect(await typersIn(direct), [b1]);
    expect(reads!.held, hasLength(1), reason: 'the read is pending');

    reads!.release();
    await rig.settle();
    expect(reads!.batches, hasLength(2));
  });
}
