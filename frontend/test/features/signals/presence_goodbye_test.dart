import 'dart:async';

import 'package:communication_platform/features/signals/application/chat_activity.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_channel.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_model.dart';
import 'package:communication_platform/features/signals/infrastructure/cached_presence_peers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/peer_read_fakes.dart';
import 'support/presence_fakes.dart';

/// The goodbye never waits for the network: it does not wait for the serial
/// queue, it reads no peer, and it sends `gone` and nothing else.
void main() {
  final me = uuid(0x1000);
  final myDevice = uuid(0x900);
  final bob = uuid(0x1001);
  final b1 = uuid(0x901);
  final carol = uuid(0x1002);
  final c1 = uuid(0x911);
  final direct = conversationOf(0x11);
  final groupChat = conversationOf(0x22);

  late PresenceRig rig;
  FakePeerReads? reads;
  CachedPresencePeers? cache;
  FakePresencePeers? fresh;

  PresenceRig plainRig() {
    final made = PresenceRig(userId: me, deviceId: myDevice);
    made.conversations.held
      ..[direct] = PresenceDirectConversation(direct, bob)
      ..[groupChat] = PresenceGroupConversation(groupChat, [me, bob, carol]);
    made.peers.devices
      ..[bob] = [b1]
      ..[carol] = [c1];
    return made;
  }

  /// A rig whose seals resolve each account through the production peer
  /// cache, over reads that name [b1] for Bob, as the app's do: the goodbye's
  /// through the cache's goodbye resolver. The channel's `peek` asks that
  /// cache too, but the receive path asks [fresh], which answers at once: a
  /// device of an answer more than 60 s old could not earn a lease otherwise.
  PresenceRig agedRig() {
    final answers = fresh = FakePresencePeers()..devices[bob] = [b1];
    final made = PresenceRig(
      userId: me,
      deviceId: myDevice,
      peersFor: (clock) {
        final made = reads = FakePeerReads(clock: clock)..devices[bob] = [b1];
        cache = cachedPeers(
          reads: made,
          trust: FakeContactTrust(),
          clock: clock,
          currentUserId: me,
        );
        return _ReadsAndPeeks(reads: answers, peeks: cache!);
      },
    );
    made.conversations.held[direct] = PresenceDirectConversation(direct, bob);
    made.sealer
      ..resolver = cache
      ..goodbyeResolver = cache!.goodbyeResolver;
    return made;
  }

  tearDown(() async {
    // A read held by a test is answered, so the queue can drain and stop.
    reads
      ?..hold = false
      ..release();
    reads = null;
    cache = null;
    for (final gate in [rig.peers.gate, fresh?.gate]) {
      if (gate != null && !gate.isCompleted) {
        gate.complete();
      }
    }
    fresh = null;
    await rig.close();
  });

  Future<void> watchFrom(
    String conversation, {
    String? user,
    String? device,
    bool settle = true,
  }) => rig.deliver(
    PresenceWatch(
      conversationId: conversationBytes(conversation),
      leaseMs: PresenceSignalLimits.watchLeaseMs,
    ),
    senderUser: user ?? bob,
    senderDevice: device ?? b1,
    settle: settle,
  );

  Future<void> typingFrom(String conversation, {bool settle = true}) =>
      rig.deliver(
        PresenceTyping(
          conversationId: conversationBytes(conversation),
          active: true,
          ttlMs: 15000,
        ),
        senderUser: bob,
        senderDevice: b1,
        settle: settle,
      );

  /// Starts the farewell without waiting for it, and says whether it ended.
  bool Function() farewell() {
    var done = false;
    unawaited(rig.channel.farewell().then((_) => done = true));
    return () => done;
  }

  test('T1: the goodbye leaves while a handler in the queue waits for a peer '
      'read that never completes', () async {
    rig = plainRig();
    await watchFrom(direct);
    final sentBefore = rig.socket.sent.length;

    // Bob types: the receive path reads his account, and the read hangs.
    rig.peers.gate = Completer<void>();
    final readsBefore = rig.peers.reads.length;
    await typingFrom(direct, settle: false);
    expect(
      rig.peers.reads,
      hasLength(readsBefore + 1),
      reason: 'a handler of the queue waits for that read',
    );

    final done = farewell();
    await rig.pump();

    expect(rig.sealer.devicesOf(PresenceSignalKind.gone), [b1]);
    expect(rig.socket.sent.skip(sentBefore).map((frame) => frame.toDeviceId), [
      b1,
    ]);
    expect(done(), isTrue, reason: 'the farewell ended with the read pending');
  });

  test('T3: the goodbye reads no peer: an answer 5 minutes old seals it '
      'while every read hangs', () async {
    rig = agedRig();
    // The cache's one answer for Bob, read now.
    await cache!.verifiedDevices({bob});
    expect(reads!.batches, hasLength(1));
    await rig.advance(const Duration(minutes: 5));

    // Bob watches, 5 minutes later. The ordinary seal refuses its here: the
    // answer it would seal from is more than 60 s old.
    await watchFrom(direct);
    expect(rig.sealer.of(PresenceSignalKind.here), isEmpty);

    // Every read from now on hangs.
    reads!.hold = true;
    fresh!.gate = Completer<void>();
    final readsBefore = (reads!.batches.length, fresh!.reads.length);
    final done = farewell();
    await rig.pump();

    expect(rig.sealer.devicesOf(PresenceSignalKind.gone), [b1]);
    expect(
      rig.sealer.of(PresenceSignalKind.gone).single.goodbye,
      isTrue,
      reason: "sealed by the goodbye's seal, which serves the old answer",
    );
    expect(rig.socket.sent.map((frame) => frame.toDeviceId), [b1]);
    expect(
      (reads!.batches.length, fresh!.reads.length),
      readsBefore,
      reason: 'no read',
    );
    expect(done(), isTrue);
  });

  test('T3: a target with no answer kept is skipped, and the goodbye reads '
      'nobody', () async {
    rig = plainRig();
    await watchFrom(direct);
    await watchFrom(groupChat, user: carol, device: c1);
    // Carol's answer is gone, and every read that must name a device hangs.
    rig.peers.devices.remove(carol);
    rig.peers.gate = Completer<void>();
    final readsBefore = rig.peers.reads.length;

    final done = farewell();
    await rig.pump();

    expect(rig.sealer.devicesOf(PresenceSignalKind.gone), [b1]);
    expect(rig.peers.reads, hasLength(readsBefore), reason: 'no read');
    expect(done(), isTrue);
  });

  test('T4: the goodbye sends gone and no typing stop, also when a stop is '
      'due and the pace allows it', () async {
    rig = plainRig();
    await watchFrom(direct);
    // Typing for 6 s: the start went at 0, so the pace allows a stop.
    await rig.edit(direct);
    await rig.advance(const Duration(seconds: 3));
    await rig.edit(direct);
    await rig.advance(const Duration(seconds: 3));
    await rig.edit(direct);
    final sealedBefore = rig.sealer.seals.length;
    expect(rig.sealer.of(PresenceSignalKind.typing), hasLength(1));

    await rig.setForeground(foreground: false);

    final after = rig.sealer.seals.skip(sealedBefore);
    expect(
      [for (final seal in after) seal.message.kind],
      [PresenceSignalKind.gone],
    );
    expect(rig.sealer.devicesOf(PresenceSignalKind.gone), [b1]);
  });

  test('T2: the goodbye waits for the router lock, and for nothing else; it '
      'seals gone once the lock is free', () async {
    rig = plainRig();
    await watchFrom(direct);
    // Another action holds the lock: an open, or a voice seal.
    final lock = Completer<void>();
    final held = rig.router.exclusively(() => lock.future);

    final done = farewell();
    await rig.pump();
    expect(rig.sealer.of(PresenceSignalKind.gone), isEmpty);
    expect(done(), isFalse, reason: 'the seal waits for the lock');

    lock.complete();
    await held;
    await rig.pump();
    expect(rig.sealer.devicesOf(PresenceSignalKind.gone), [b1]);
    expect(done(), isTrue);
  });

  test('T5: during a departure the events that wait in the queue return '
      'without work, and once the app is back the watch runs again', () async {
    rig = plainRig();
    await rig.show(direct);
    await watchFrom(direct);
    // A handler waits for a read, and events queue behind it: an edit, a
    // watch, and the renewal of the watch on screen.
    final gate = rig.peers.gate = Completer<void>();
    await typingFrom(direct, settle: false);
    rig.activity.report(ChatTextEdited(direct, hasText: true));
    await watchFrom(direct, settle: false);
    await rig.timers.advance(PresenceChannel.watchRenewal, settle: rig.pump);
    final sealedBefore = rig.sealer.seals.length;
    final readsBefore = rig.peers.reads.length;

    rig.visibility.setForeground(foreground: false);
    await rig.pump();
    rig.peers.gate = null;
    gate.complete();
    await rig.settle();

    expect(
      rig.peers.reads,
      hasLength(readsBefore),
      reason: 'the queued watch and renewal read nobody',
    );
    expect(
      [
        for (final seal in rig.sealer.seals.skip(sealedBefore))
          if (seal.devices.isNotEmpty) seal.message.kind,
      ],
      [PresenceSignalKind.gone],
      reason: 'no typing start, no here and no renewal after the goodbye',
    );

    final sealedAway = rig.sealer.seals.length;
    await rig.setForeground(foreground: true);

    expect(
      rig.sealer.seals
          .skip(sealedAway)
          .where((seal) => seal.message.kind == PresenceSignalKind.watch)
          .expand((seal) => seal.devices)
          .map((device) => device.key),
      [b1],
      reason: 'the chat on screen is watched again',
    );
  });

  test('T10: with the socket closed the goodbye seals nothing, reads nobody '
      'and throws nothing', () async {
    rig = plainRig();
    await watchFrom(direct);
    final sealedBefore = rig.sealer.seals.length;
    final sentBefore = rig.socket.sent.length;
    final readsBefore = rig.peers.reads.length;
    rig.socket.connected = false;

    rig.visibility.setForeground(foreground: false);
    await rig.channel.farewell();
    await rig.settle();

    expect(rig.sealer.seals, hasLength(sealedBefore));
    expect(rig.peers.reads, hasLength(readsBefore));
    expect(rig.socket.sent, hasLength(sentBefore));
  });

  for (final farewellFirst in [false, true]) {
    test('T11: the visibility and the farewell start one departure '
        '(${farewellFirst ? 'farewell' : 'visibility'} first), and each '
        'device gets one gone', () async {
      rig = plainRig();
      await rig.show(direct);
      // b1 answers this phone's watch; c1 watches this phone.
      await rig.deliver(
        PresenceHere(conversationId: conversationBytes(direct), typing: false),
        senderUser: bob,
        senderDevice: b1,
      );
      await watchFrom(groupChat, user: carol, device: c1);
      final sentBefore = rig.socket.sent.length;

      final Future<void> farewellDone;
      if (farewellFirst) {
        farewellDone = rig.channel.farewell();
        rig.visibility.setForeground(foreground: false);
      } else {
        rig.visibility.setForeground(foreground: false);
        farewellDone = rig.channel.farewell();
      }
      await farewellDone;

      expect(
        rig.socket.sent.skip(sentBefore).map((frame) => frame.toDeviceId),
        unorderedEquals([b1, c1]),
        reason: 'the farewell ends once the one goodbye has left',
      );
      await rig.settle();
      expect(
        rig.sealer.devicesOf(PresenceSignalKind.gone),
        unorderedEquals([b1, c1]),
      );
      expect(rig.socket.sent, hasLength(sentBefore + 2));
    });
  }
}

/// Peer reads from [reads], and the answers kept from [peeks].
final class _ReadsAndPeeks implements PresencePeersPort {
  const _ReadsAndPeeks({required this.reads, required this.peeks});

  final PresencePeersPort reads;
  final PresencePeersPort peeks;

  @override
  Future<Map<String, List<String>>> verifiedDevices(
    Set<String> userIds, {
    Set<PresenceDevice> including = const {},
  }) => reads.verifiedDevices(userIds, including: including);

  @override
  Future<List<String>?> peek(String userId) => peeks.peek(userId);
}
