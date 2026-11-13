import 'dart:async';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/application/chat_activity.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_channel.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/presence_fakes.dart';

/// ADR-098 D6 and the socket: presence follows the connection. A frame sealed
/// while the socket is closed is a dead skipped key on its target for good,
/// so the channel seals nothing then, and runs its handshake at the open.
void main() {
  final me = uuid(0x1000);
  final myDevice = uuid(0x900);
  final bob = uuid(0x1001);
  final b1 = uuid(0x901);

  final direct = conversationOf(0x11);

  late PresenceRig rig;
  late DateTime t0;

  setUp(() {
    rig = PresenceRig(userId: me, deviceId: myDevice);
    rig.conversations.held[direct] = PresenceDirectConversation(direct, bob);
    rig.peers.devices[bob] = [b1];
    t0 = rig.clock.now();
  });

  tearDown(() => rig.close());

  Future<void> watchFrom(String conversation) => rig.deliver(
    PresenceWatch(
      conversationId: conversationBytes(conversation),
      leaseMs: PresenceSignalLimits.watchLeaseMs,
    ),
    senderUser: bob,
    senderDevice: b1,
  );

  Future<PresenceLedgerEntry?> ledgerOf(String device) async =>
      (await rig.ledger.read(userId: bob, deviceId: device)
              as Success<PresenceLedgerEntry?>)
          .value;

  /// Every typing frame sealed to [device]: when, in milliseconds since t0, and
  /// whether it was active.
  List<(int, bool)> typingTo(String device) => [
    for (final seal in rig.sealer.of(PresenceSignalKind.typing))
      if (seal.devices.any((target) => target.key == device))
        (
          seal.at.difference(t0).inMilliseconds,
          (seal.body as PresenceTyping).active,
        ),
  ];

  group('while the socket is closed', () {
    test('T1: a chat opened on a closed socket seals no frame and spends no '
        'probe', () async {
      rig.socket.connected = false;

      await rig.show(direct);

      expect(rig.sealer.seals, isEmpty);
      expect(rig.socket.sent, isEmpty);
      expect(await ledgerOf(b1), isNull);
    });

    test('T3: a chat on screen for 2 minutes seals no frame, whatever the '
        'renewals, and one watch at the open spends one probe', () async {
      rig.socket.connected = false;

      await rig.show(direct);
      await rig.advance(const Duration(minutes: 2));

      expect(rig.sealer.seals, isEmpty);
      expect(rig.socket.sent, isEmpty);
      expect(await ledgerOf(b1), isNull);

      rig.socket.open();
      await rig.settle();

      final watches = rig.sealer.of(PresenceSignalKind.watch);
      expect(watches.map((seal) => seal.at.difference(t0).inSeconds), [120]);
      expect(rig.sealer.seals, hasLength(1));
      expect((await ledgerOf(b1))!.probesSinceHeard, 1);
    });

    test('T4: a composer holding text seals no start frame, and at the open '
        'the start is sealed at once', () async {
      await watchFrom(direct);
      final sealedBefore = rig.sealer.seals.length;
      rig.socket.connected = false;

      await rig.edit(direct);
      await rig.advance(const Duration(milliseconds: 300));
      await rig.edit(direct);

      expect(
        rig.sealer.seals.length,
        sealedBefore,
        reason: 'the lease is live, but the socket is not',
      );
      expect(typingTo(b1), isEmpty);

      // The retry pause of a start that no frame carried is not waited out.
      final openedAt = rig.clock.now();
      rig.socket.open();
      await rig.settle();

      expect(typingTo(b1), [(openedAt.difference(t0).inMilliseconds, true)]);
    });

    test('T5: the farewell seals nothing and throws nothing', () async {
      await watchFrom(direct);
      final sealedBefore = rig.sealer.seals.length;
      rig.socket.connected = false;

      await rig.channel.farewell();

      expect(rig.sealer.seals.length, sealedBefore);
      expect(rig.sealer.of(PresenceSignalKind.gone), isEmpty);
    });

    test('T6: the outage spends no live frame, so after the open L1 allows 8 '
        'again', () async {
      // The watch earns a lease. Its answer is not sealed: the socket is
      // closed, which also leaves the L1 count of the watcher at zero.
      rig.socket.connected = false;
      await watchFrom(direct);
      expect(rig.sealer.seals, isEmpty);

      // Twelve messages typed and sent, each of which would seal a start.
      for (var message = 0; message < 12; message += 1) {
        await rig.edit(direct);
        await rig.advance(const Duration(seconds: 1));
        await rig.report(ChatTextSent(direct));
      }
      expect(rig.sealer.seals, isEmpty);

      rig.socket.open();
      await rig.settle();
      for (var message = 0; message < 12; message += 1) {
        await rig.advance(const Duration(seconds: 1));
        await rig.edit(direct);
        await rig.report(ChatTextSent(direct));
      }

      expect(
        typingTo(b1),
        hasLength(PresenceChannel.liveFramesBetweenHeard),
        reason: 'the outage left every one of the 8 frames to the open',
      );
    });

    test('K4: a stop the pace held back is not sent after a close and an '
        'open: the session starts over', () async {
      await watchFrom(direct);
      await rig.edit(direct);
      await rig.advance(const Duration(seconds: 1));
      await rig.edit(direct, hasText: false);
      rig.socket.connected = false;
      await rig.advance(const Duration(seconds: 1));

      rig.socket.open();
      await rig.settle();
      await rig.advance(const Duration(seconds: 6));

      expect(typingTo(b1), [(0, true)], reason: 'no stop, and no new start');
    });

    test('T10: a send that waited for the router lock seals nothing when the '
        'socket closed meanwhile', () async {
      final held = Completer<void>();
      final lock = rig.router.exclusively(() => held.future);

      // The channel passes the first check, and waits for the lock.
      rig.visibility.show(direct);
      for (var turn = 0; turn < 30; turn += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(rig.sealer.seals, isEmpty, reason: 'the lock is held');
      rig.socket.connected = false;
      held.complete();
      await lock;
      await rig.settle();

      expect(rig.sealer.seals, isEmpty);
      expect(rig.socket.sent, isEmpty);
      expect(await ledgerOf(b1), isNull);
    });
  });

  group('at the open', () {
    test('T2: the socket opening at 3 s seals the first watch at 3.0 s and '
        'sends it', () async {
      rig.socket.connected = false;
      await rig.show(direct);
      await rig.advance(const Duration(seconds: 3));
      expect(rig.sealer.seals, isEmpty);

      rig.socket.open();
      await rig.settle();

      final watches = rig.sealer.of(PresenceSignalKind.watch);
      expect(watches, hasLength(1));
      expect(watches.single.at.difference(t0), const Duration(seconds: 3));
      expect(watches.single.devices.map((device) => device.key), [b1]);
      expect(rig.socket.sent.map((frame) => frame.toDeviceId), [b1]);
      expect((await ledgerOf(b1))!.probesSinceHeard, 1);
    });

    test(
      'an open in the background runs no round and starts no typing',
      () async {
        await watchFrom(direct);
        rig.socket.connected = false;
        await rig.show(direct);
        await rig.edit(direct);
        await rig.setForeground(foreground: false);
        final sealedBefore = rig.sealer.seals.length;

        rig.socket.open();
        await rig.settle();

        expect(rig.sealer.seals.length, sealedBefore);
      },
    );

    test('an open with "Show my online status" off seals nothing', () async {
      await rig.sharing.set(sharing: false);
      await rig.settle();
      rig.socket.connected = false;
      await rig.show(direct);

      rig.socket.open();
      await rig.settle();

      expect(rig.sealer.seals, isEmpty);
    });
  });
}
