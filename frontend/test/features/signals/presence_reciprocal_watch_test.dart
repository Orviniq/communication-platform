import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/application/chat_activity.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/presence_fakes.dart';

/// ADR-100 W1 to W4: a phone that accepts the watch of a peer while it shows
/// that chat sends the peer a watch at once, so the peer can type to it
/// without waiting for the renewal that comes up to 25 s later.
void main() {
  final me = uuid(0x1000);
  final myDevice = uuid(0x900);
  final bob = uuid(0x1001);
  final b1 = uuid(0x901);
  final b2 = uuid(0x902);
  final b3 = uuid(0x903);
  final carol = uuid(0x1002);
  final c1 = uuid(0x911);

  final direct = conversationOf(0x11);
  final otherChat = conversationOf(0x55);
  final groupChat = conversationOf(0x22);

  late PresenceRig rig;
  late DateTime t0;

  setUp(() {
    rig = PresenceRig(userId: me, deviceId: myDevice);
    rig.conversations.held
      ..[direct] = PresenceDirectConversation(direct, bob)
      ..[otherChat] = PresenceDirectConversation(otherChat, bob)
      ..[groupChat] = PresenceGroupConversation(groupChat, [me, bob, carol]);
    rig.peers.devices[bob] = [b1];
    t0 = rig.clock.now();
  });

  tearDown(() => rig.close());

  Future<void> watchFrom(String conversation, {String? user, String? device}) =>
      rig.deliver(
        PresenceWatch(
          conversationId: conversationBytes(conversation),
          leaseMs: PresenceSignalLimits.watchLeaseMs,
        ),
        senderUser: user ?? bob,
        senderDevice: device ?? b1,
      );

  Future<void> hereFrom(String conversation, {String? user, String? device}) =>
      rig.deliver(
        PresenceHere(
          conversationId: conversationBytes(conversation),
          typing: false,
        ),
        senderUser: user ?? bob,
        senderDevice: device ?? b1,
      );

  /// Moves the clock to [offset] after t0.
  Future<void> at(Duration offset) =>
      rig.advance(t0.add(offset).difference(rig.clock.now()));

  /// Every frame sealed to [device]: its kind and when, in milliseconds since
  /// t0.
  List<(String, int)> framesTo(String device) => [
    for (final seal in rig.sealer.seals)
      if (seal.devices.any((target) => target.key == device))
        (seal.message.kind.name, seal.at.difference(t0).inMilliseconds),
  ];

  /// When each watch was sealed to [device], in milliseconds since t0.
  List<int> watchesTo(String device) => [
    for (final (kind, at) in framesTo(device))
      if (kind == 'watch') at,
  ];

  Future<PresenceLedgerEntry> ledgerOf(String device) async =>
      (await rig.ledger.read(userId: bob, deviceId: device)
              as Success<PresenceLedgerEntry?>)
          .value!;

  group('a new watcher is answered at once', () {
    test('T1: the watch of a peer that arrives 2 s after the first probe earns '
        'a here and a live watch, and the renewal at 25 s is a live watch '
        'too', () async {
      await rig.show(direct);
      await at(const Duration(seconds: 2));

      await watchFrom(direct);
      await at(const Duration(milliseconds: 2500));
      await hereFrom(direct);
      await at(const Duration(seconds: 25));

      expect(framesTo(b1), [
        ('watch', 0),
        ('here', 2000),
        ('watch', 2000),
        ('watch', 25000),
      ]);
      final ledger = await ledgerOf(b1);
      expect(
        ledger.tokens,
        3,
        reason:
            'only the first watch was a probe: the other two went to a '
            'device that had just spoken',
      );
      expect(ledger.probesSinceHeard, 0);
    });

    test('T2: two minutes of renewals from both sides seal one watch for each '
        '25 s and one here for each watch of the peer, and no reciprocal '
        'watch', () async {
      await rig.show(direct);
      await at(const Duration(seconds: 1));
      await hereFrom(direct);
      for (var round = 1; round <= 4; round += 1) {
        // Our renewal leaves at 25 s, 50 s, and so on; the peer answers it,
        // and renews its own watch 5 s later.
        await at(Duration(seconds: 25 * round));
        await at(Duration(milliseconds: 25000 * round + 500));
        await hereFrom(direct);
        await at(Duration(seconds: 25 * round + 5));
        await watchFrom(direct);
      }
      await at(const Duration(minutes: 2));

      expect(watchesTo(b1), [0, 25000, 50000, 75000, 100000]);
      expect(
        [
          for (final (kind, at) in framesTo(b1))
            if (kind == 'here') at,
        ],
        [30000, 55000, 80000, 105000],
      );
      expect(rig.sealer.seals, hasLength(9));
      expect((await ledgerOf(b1)).tokens, 3, reason: 'one probe, at 0');
    });

    test('T4: a watch for a chat that is not on screen earns a here and no '
        'watch', () async {
      await rig.show(direct);
      final before = rig.sealer.seals.length;

      await watchFrom(otherChat);

      expect(framesTo(b1).skip(before).map((frame) => frame.$1), ['here']);

      await rig.show(null);
      final shownNone = rig.sealer.seals.length;
      await watchFrom(direct);

      expect(
        rig.sealer.seals.skip(shownNone).map((seal) => seal.message.kind.name),
        ['here'],
        reason: 'no chat is on screen',
      );
    });

    test('T5: in the background nothing leaves, and with the switch off '
        'nothing leaves', () async {
      await rig.show(direct);
      await rig.setForeground(foreground: false);
      final background = rig.sealer.seals.length;

      await watchFrom(direct);

      expect(rig.sealer.seals, hasLength(background));

      await rig.setForeground(foreground: true);
      await rig.sharing.set(sharing: false);
      await rig.settle();
      final off = rig.sealer.seals.length;

      await watchFrom(direct);

      expect(rig.sealer.seals, hasLength(off));
    });

    test('T6: in a group of 3 the watches of two members earn one reciprocal '
        'watch each, and a device that the watch does not target earns '
        'none', () async {
      rig.peers.devices
        ..[bob] = [b1, b2, b3]
        ..[carol] = [c1];
      await rig.show(groupChat);
      await at(const Duration(seconds: 2));

      await watchFrom(groupChat);
      await at(const Duration(seconds: 3));
      await watchFrom(groupChat, user: carol, device: c1);

      expect(watchesTo(b1), [0, 2000]);
      expect(watchesTo(c1), [0, 3000]);

      // A group watch goes to two devices of each member: b3 is not one.
      await watchFrom(groupChat, device: b3);

      expect(framesTo(b3), [('here', 3000)]);
      expect(watchesTo(b2), [0], reason: 'b2 has not spoken');
    });

    test('T6: a member of a group of more than 32 members earns nothing, '
        'because nothing is watched there and nothing accepted', () async {
      final large = conversationOf(0x57);
      final members = [
        me,
        bob,
        for (var index = 0; index < 31; index += 1) uuid(0x2000 + index),
      ];
      rig.conversations.held[large] = PresenceGroupConversation(large, members);
      await rig.show(large);

      await watchFrom(large);

      expect(rig.sealer.seals, isEmpty);
    });

    test('T7: after a gone of the peer, a new watch clears the gone state and '
        'earns a reciprocal watch', () async {
      await rig.show(direct);
      await at(const Duration(seconds: 1));
      await hereFrom(direct);
      // Our live watch at 25 s is the last one in 40 s when the peer returns.
      await at(const Duration(seconds: 26));
      await hereFrom(direct);
      await at(const Duration(seconds: 30));
      await rig.deliver(
        const PresenceGone(PresenceGoneReason.leftForeground),
        senderUser: bob,
        senderDevice: b1,
      );
      await at(const Duration(seconds: 32));
      final before = rig.sealer.seals.length;

      await watchFrom(direct);

      expect(framesTo(b1).skip(framesTo(b1).length - 2), [
        ('here', 32000),
        ('watch', 32000),
      ]);
      expect(rig.sealer.seals.length, before + 2);

      // The gone state is cleared: typing goes to the peer again, and the
      // renewal at 50 s is a live watch to it.
      await rig.edit(direct);
      expect(rig.sealer.devicesOf(PresenceSignalKind.typing), [b1]);
      await hereFrom(direct);
      await at(const Duration(seconds: 50));
      expect(watchesTo(b1), [0, 25000, 32000, 50000]);
    });

    test('T8: after a late join the live frames to the peer between two of '
        'its frames never exceed 8', () async {
      await rig.show(direct);
      await at(const Duration(seconds: 2));
      await watchFrom(direct);

      for (var message = 0; message < 12; message += 1) {
        await rig.edit(direct);
        await rig.advance(const Duration(seconds: 1));
        await rig.report(ChatTextSent(direct));
      }

      final sinceTheWatch = [
        for (final (kind, at) in framesTo(b1))
          if (at >= 2000) kind,
      ];
      expect(
        sinceTheWatch,
        hasLength(8),
        reason: 'the here and the reciprocal watch count: 2 + 6 typing',
      );
      expect(sinceTheWatch.take(2), ['here', 'watch']);
    });

    test('T9: a watch that arrives on a closed socket seals nothing, and the '
        'open sends one watch through the watch round', () async {
      await rig.show(direct);
      await at(const Duration(seconds: 2));
      final before = rig.sealer.seals.length;
      rig.socket.connected = false;

      await watchFrom(direct);

      expect(rig.sealer.seals, hasLength(before));

      await at(const Duration(seconds: 4));
      rig.socket.open();
      await rig.settle();

      expect(framesTo(b1), [('watch', 0), ('watch', 4000)]);
      expect(
        (await ledgerOf(b1)).tokens,
        3,
        reason: 'the watch at the open was live, not a probe',
      );
    });
  });
}
