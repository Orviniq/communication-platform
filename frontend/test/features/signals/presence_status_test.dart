import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/domain/peer_status_model.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../voice/support/signal_fakes.dart';
import 'support/presence_fakes.dart';

/// ADR-098 D4, D5, D8 and D9, as prompt 3 builds them: who is online and
/// until when, the last seen, the goodbye, and "Show my online status".
void main() {
  final me = uuid(0x1000);
  final myDevice = uuid(0x900);
  final bob = uuid(0x1001);
  final b1 = uuid(0x901);
  final b2 = uuid(0x902);
  final carol = uuid(0x1002);
  final c1 = uuid(0x911);
  final mallory = uuid(0x1003);
  final m1 = uuid(0x921);

  final direct = conversationOf(0x11);
  final groupChat = conversationOf(0x22);
  final bigGroup = conversationOf(0x44);

  late PresenceRig rig;
  late DateTime t0;

  setUp(() {
    rig = PresenceRig(userId: me, deviceId: myDevice);
    rig.conversations.held
      ..[direct] = PresenceDirectConversation(direct, bob)
      ..[groupChat] = PresenceGroupConversation(groupChat, [
        me,
        bob,
        carol,
        mallory,
      ])
      ..[bigGroup] = PresenceGroupConversation(bigGroup, [
        me,
        bob,
        carol,
        for (var member = 0; member < 30; member += 1) uuid(0x2000 + member),
      ]);
    // Mallory is not verified, so the peers answer nothing for her.
    rig.peers.devices
      ..[bob] = [b1, b2]
      ..[carol] = [c1];
    t0 = rig.clock.now();
  });

  tearDown(() => rig.close());

  Uint8List bytesOf(String conversation) => conversationBytes(conversation);

  Future<FakeOpening> watchFrom(
    String conversation, {
    String? user,
    String? device,
  }) => rig.deliver(
    PresenceWatch(
      conversationId: bytesOf(conversation),
      leaseMs: PresenceSignalLimits.watchLeaseMs,
    ),
    senderUser: user ?? bob,
    senderDevice: device ?? b1,
  );

  Future<void> hereFrom(String conversation, {String? user, String? device}) =>
      rig.deliver(
        PresenceHere(conversationId: bytesOf(conversation), typing: false),
        senderUser: user ?? bob,
        senderDevice: device ?? b1,
      );

  Future<void> typingFrom(String conversation, {String? device}) => rig.deliver(
    PresenceTyping(
      conversationId: bytesOf(conversation),
      active: true,
      ttlMs: 15000,
    ),
    senderUser: bob,
    senderDevice: device ?? b1,
  );

  Future<void> goneFrom(
    PresenceGoneReason reason, {
    String? user,
    String? device,
  }) => rig.deliver(
    PresenceGone(reason),
    senderUser: user ?? bob,
    senderDevice: device ?? b1,
  );

  Future<PeerStatus> statusOf(String user) async {
    final status = await rig.status.watchUser(user).first;
    await rig.settle();
    return status;
  }

  Future<int> onlineIn(String conversation) async {
    final count = await rig.status.watchOnlineCount(conversation).first;
    await rig.settle();
    return count;
  }

  Future<Map<String, int>> storedLastSeen(Set<String> users) async => {
    for (final seen
        in (await rig.ledger.readLastSeen(users)
                as Success<List<PresenceLastSeen>>)
            .value)
      seen.deviceId: seen.lastSeenMs,
  };

  Future<List<String>> typersIn(String conversation) async => [
    for (final typing in await rig.state.watchTyping(conversation).first)
      typing.deviceId,
  ];

  Future<void> setSharing({required bool sharing}) async {
    await rig.sharing.set(sharing: sharing);
    await rig.settle();
  }

  group('online and its expiry', () {
    test('an accepted watch, here or typing makes its sender online, and its '
        'account is online while one device is', () async {
      expect(await statusOf(bob), const PeerStatusNone());

      await watchFrom(direct);
      expect(await statusOf(bob), const PeerStatusOnline());
      expect(rig.status.isOnline(b1), isTrue);
      expect(rig.status.isOnline(b2), isFalse);

      await rig.advance(const Duration(seconds: 30));
      await hereFrom(direct, device: b2);
      await rig.advance(const Duration(seconds: 15));
      expect(rig.status.isOnline(b1), isFalse, reason: 'silent for 45 s');
      expect(await statusOf(bob), const PeerStatusOnline(), reason: 'b2 is');
    });

    test('online ends 40 s after the latest frame, which is then the last '
        'seen', () async {
      await watchFrom(direct);
      await rig.advance(const Duration(seconds: 20));
      await typingFrom(direct);

      await rig.advance(const Duration(seconds: 39));
      expect(await statusOf(bob), const PeerStatusOnline());

      await rig.advance(const Duration(seconds: 1));
      final lastSeen = t0.add(const Duration(seconds: 20));
      expect(await statusOf(bob), PeerStatusLastSeen(lastSeen));
      expect(await storedLastSeen({bob}), {
        b1: lastSeen.millisecondsSinceEpoch,
      });
    });

    test('the last seen is written when online ends and at most once a '
        'minute while it lasts', () async {
      await watchFrom(direct);
      for (var second = 10; second <= 180; second += 10) {
        await rig.advance(const Duration(seconds: 10));
        await hereFrom(direct);
      }
      await rig.advance(const Duration(seconds: 40));

      int at(int seconds) =>
          t0.add(Duration(seconds: seconds)).millisecondsSinceEpoch;
      expect(rig.lastSeen.writes, [
        (b1, at(0)),
        (b1, at(60)),
        (b1, at(120)),
        (b1, at(180)),
        // The end, with the latest frame as its time.
        (b1, at(180)),
      ]);
    });

    test('a goodbye ends it at once and is the last seen', () async {
      await watchFrom(direct);
      await rig.advance(const Duration(seconds: 5));

      await goneFrom(PresenceGoneReason.leftForeground);

      expect(
        await statusOf(bob),
        PeerStatusLastSeen(t0.add(const Duration(seconds: 5))),
      );
      expect(rig.status.isOnline(b1), isFalse);
    });

    test('a goodbye because its sender turned status off deletes that '
        "device's last seen", () async {
      await watchFrom(direct);
      await watchFrom(direct, device: b2);
      await rig.advance(const Duration(seconds: 41));
      expect(await storedLastSeen({bob}), hasLength(2));

      await watchFrom(direct);
      await goneFrom(PresenceGoneReason.statusTurnedOff);

      expect(await storedLastSeen({bob}), {b2: t0.millisecondsSinceEpoch});
      expect(await statusOf(bob), PeerStatusLastSeen(t0));
    });

    test('a group counts the other members with an online device, and a '
        'group over 32 members counts nobody', () async {
      expect(await onlineIn(groupChat), 0);

      await watchFrom(groupChat);
      await watchFrom(groupChat, device: b2);
      await watchFrom(groupChat, user: carol, device: c1);
      await watchFrom(groupChat, user: mallory, device: m1);

      expect(await onlineIn(groupChat), 2, reason: 'Mallory is not verified');
      expect(await onlineIn(bigGroup), 0);
      expect(await onlineIn(direct), 0, reason: 'a count is a group thing');

      await rig.advance(const Duration(seconds: 40));
      expect(await onlineIn(groupChat), 0);
    });

    test(
      'a group never counts this account, whichever device of it speaks',
      () async {
        await watchFrom(groupChat);
        expect(await onlineIn(groupChat), 1);

        // Verified, as the peer read answers for the user's own devices too.
        rig.peers.devices[me] = [uuid(0x903)];
        await watchFrom(groupChat, user: me, device: uuid(0x903));
        await hereFrom(groupChat, user: me, device: uuid(0x903));

        expect(
          await onlineIn(groupChat),
          1,
          reason: 'another device of this account is not "another member"',
        );
        expect(rig.status.isOnline(uuid(0x903)), isFalse);
        expect(
          rig.sealer.devicesOf(PresenceSignalKind.here),
          [b1],
          reason: 'and it is answered nothing',
        );
      },
    );

    test('a watched account answers the open chat, and its answer makes it '
        'online', () async {
      await rig.show(direct);
      expect(rig.sealer.devicesOf(PresenceSignalKind.watch), [b1, b2]);

      await hereFrom(direct);

      expect(await statusOf(bob), const PeerStatusOnline());
    });
  });

  group('the answer and its repeats', () {
    test('a query to this phone gets an answer while it is in the '
        'foreground, and none in the background', () async {
      await watchFrom(direct);
      expect(rig.sealer.devicesOf(PresenceSignalKind.here), [b1]);

      await rig.setForeground(foreground: false);
      await watchFrom(direct, device: b2);

      expect(rig.sealer.devicesOf(PresenceSignalKind.here), [b1]);
      expect(
        rig.status.isOnline(b2),
        isTrue,
        reason: 'the background still sees who asked',
      );
    });

    test('repeats stop when the asking chat closes: a watcher that stops '
        'renewing gets no typing once its lease ends', () async {
      await watchFrom(direct);
      await rig.edit(direct);
      expect(rig.sealer.devicesOf(PresenceSignalKind.typing), [b1]);

      // b1 left the chat, so no renewal comes; its lease ends at 40 s.
      await rig.advance(const Duration(seconds: 41));
      final before = rig.socket.sent.length;
      for (var second = 0; second < 30; second += 1) {
        await rig.edit(direct);
        await rig.advance(const Duration(seconds: 1));
      }

      expect(
        rig.socket.sent.skip(before).map((frame) => frame.toDeviceId),
        isNot(contains(b1)),
      );
      expect(rig.sealer.devicesOf(PresenceSignalKind.typing), [b1, b1]);
    });

    test(
      'this phone stops renewing its own watch when its chat closes',
      () async {
        await rig.show(direct);
        await hereFrom(direct);
        await rig.advance(const Duration(seconds: 25));
        expect(
          rig.sealer.devicesOf(PresenceSignalKind.watch).where((d) => d == b1),
          hasLength(2),
        );

        await rig.show(null);
        final before = rig.sealer.devicesOf(PresenceSignalKind.watch).length;
        await rig.advance(const Duration(minutes: 2));

        expect(
          rig.sealer.devicesOf(PresenceSignalKind.watch),
          hasLength(before),
        );
      },
    );

    test(
      'no status frame goes to an account this user has not verified',
      () async {
        await watchFrom(groupChat, user: mallory, device: m1);
        await rig.show(groupChat);
        await rig.advance(const Duration(seconds: 60));

        expect(
          rig.socket.sent.map((frame) => frame.toDeviceId),
          isNot(contains(m1)),
        );
        for (final seal in rig.sealer.seals) {
          expect(seal.devices.map((device) => device.key), isNot(contains(m1)));
        }
        expect(await statusOf(mallory), const PeerStatusNone());
      },
    );
  });

  group('the goodbye (D5)', () {
    test('leaving the foreground says gone to every live lease in either '
        'direction, after the pending stop', () async {
      await rig.show(direct);
      await hereFrom(direct); // b1 answers this phone's watch.
      await watchFrom(direct, device: b2); // b2 watches this phone.
      await rig.edit(direct);
      expect(rig.sealer.devicesOf(PresenceSignalKind.typing), [b2]);

      // Still typing when the app leaves the screen, 5 s after the start.
      await rig.advance(const Duration(seconds: 3));
      await rig.edit(direct);
      await rig.advance(const Duration(seconds: 2));
      await rig.setForeground(foreground: false);

      final last = rig.sealer.seals.reversed.take(2).toList().reversed;
      expect(
        [for (final seal in last) seal.message.kind],
        [PresenceSignalKind.typing, PresenceSignalKind.gone],
      );
      final gone = rig.sealer.of(PresenceSignalKind.gone).single;
      expect(
        (gone.body as PresenceGone).reason,
        PresenceGoneReason.leftForeground,
      );
      expect(gone.devices.map((device) => device.key).toSet(), {b1, b2});
    });

    test('the farewell goes to the socket before it completes, and nothing '
        'follows it until the foreground returns', () async {
      await watchFrom(direct);
      final before = rig.socket.sent.length;

      await rig.channel.farewell();

      expect(rig.socket.sent.skip(before).map((frame) => frame.toDeviceId), [
        b1,
      ]);
      expect(rig.sealer.devicesOf(PresenceSignalKind.gone), [b1]);

      // The app leaves the screen after the socket closed: no second goodbye,
      // and a watch is not answered.
      await rig.setForeground(foreground: false);
      await watchFrom(direct, device: b2);
      expect(rig.socket.sent.length, before + 1, reason: 'nothing more');

      await rig.setForeground(foreground: true);
      await rig.show(direct);
      expect(rig.sealer.devicesOf(PresenceSignalKind.watch), isNotEmpty);
    });

    test('a device with no live lease is told nothing', () async {
      await rig.channel.farewell();
      expect(rig.socket.sent, isEmpty);
    });
  });

  group('"Show my online status" (D9)', () {
    test(
      'off: a watch is committed and discarded, and nothing answers it',
      () async {
        await setSharing(sharing: false);

        final opening = await watchFrom(direct);

        expect(
          opening.commits,
          1,
          reason: 'which spares its sender a dead key',
        );
        expect(rig.sealer.seals, isEmpty);
        expect(rig.socket.sent, isEmpty);
        expect(rig.status.isOnline(b1), isFalse);
      },
    );

    test(
      'off: no watch of the chat on screen, no typing, no goodbye',
      () async {
        await setSharing(sharing: false);

        await rig.show(direct);
        await typingFrom(direct);
        await rig.edit(direct);
        await rig.advance(const Duration(minutes: 1));
        await rig.setForeground(foreground: false);
        await rig.channel.farewell();

        expect(rig.socket.sent, isEmpty);
        expect(await typersIn(direct), isEmpty);
      },
    );

    test("turning it off says gone once to the live leases, then hides "
        "everyone's state and deletes every stored last seen", () async {
      await rig.show(direct);
      await hereFrom(direct); // b1 answers this phone's watch.
      await watchFrom(groupChat, user: carol, device: c1); // c1 watches.
      await typingFrom(direct);
      await watchFrom(direct, device: b2);
      await rig.advance(const Duration(seconds: 41));
      await hereFrom(direct);
      await typingFrom(direct);
      expect(await typersIn(direct), [b1]);
      expect(await storedLastSeen({bob, carol}), isNotEmpty);

      await setSharing(sharing: false);

      final gone = rig.sealer.of(PresenceSignalKind.gone).single;
      expect(
        (gone.body as PresenceGone).reason,
        PresenceGoneReason.statusTurnedOff,
      );
      expect(gone.devices.map((device) => device.key), [b1]);
      expect(await typersIn(direct), isEmpty);
      expect(await statusOf(bob), const PeerStatusNone());
      expect(await onlineIn(groupChat), 0);
      expect(await storedLastSeen({bob, carol}), isEmpty);

      final after = rig.socket.sent.length;
      await rig.advance(const Duration(minutes: 2));
      await watchFrom(direct);
      expect(rig.socket.sent, hasLength(after));
    });

    test('on again: the chat on screen is watched anew and a watch is '
        'answered', () async {
      await rig.show(direct);
      await setSharing(sharing: false);
      final before = rig.sealer.devicesOf(PresenceSignalKind.watch).length;
      // Past P2's minute between two probes to one device.
      await rig.advance(const Duration(minutes: 1));
      expect(rig.sealer.devicesOf(PresenceSignalKind.watch), hasLength(before));

      await setSharing(sharing: true);
      expect(
        rig.sealer.devicesOf(PresenceSignalKind.watch),
        hasLength(before + 2),
      );

      await watchFrom(direct);
      expect(rig.sealer.devicesOf(PresenceSignalKind.here), [b1]);
      expect(await statusOf(bob), const PeerStatusOnline());
      expect(rig.shareStore.sharing, isTrue);
    });

    test('the stored choice is read before anything leaves', () async {
      final off = PresenceRig(userId: me, deviceId: myDevice);
      off.shareStore.sharing = false;
      addTearDown(off.close);
      off.conversations.held[direct] = PresenceDirectConversation(direct, bob);
      off.peers.devices[bob] = [b1];

      await off.show(direct);
      await off.edit(direct);

      expect(off.socket.sent, isEmpty);
    });
  });

  test('the last seen never leaves the phone', () async {
    await watchFrom(direct);
    await rig.advance(const Duration(seconds: 41));
    final seen = (await storedLastSeen({bob}))[b1]!;

    await rig.show(direct);
    await hereFrom(direct);
    await watchFrom(direct, device: b2);
    await rig.edit(direct);
    await rig.setForeground(foreground: false);

    expect(rig.sealer.payloads, isNotEmpty);
    final bigEndian = ByteData(8)..setUint64(0, seen);
    final needle = bigEndian.buffer.asUint8List().sublist(2);
    for (final payload in rig.sealer.payloads) {
      expect(_contains(payload, needle), isFalse);
    }
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var start = 0; start + needle.length <= haystack.length; start += 1) {
    var match = true;
    for (var index = 0; index < needle.length; index += 1) {
      if (haystack[start + index] != needle[index]) {
        match = false;
        break;
      }
    }
    if (match) {
      return true;
    }
  }
  return false;
}
