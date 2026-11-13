import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/application/chat_activity.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_channel.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/presence_fakes.dart';

/// ADR-098 D2 to D7, as prompt 2 builds them: the watch, the answer and the
/// lease, the typing policy, typing received, and the limits that bound the
/// frames a dropped socket turns into dead keys.
void main() {
  final me = uuid(0x1000);
  final myDevice = uuid(0x900);
  final myOtherDevice = uuid(0x9ff);
  final bob = uuid(0x1001);
  final b1 = uuid(0x901);
  final b2 = uuid(0x902);
  final carol = uuid(0x1002);
  final c1 = uuid(0x911);
  final mallory = uuid(0x1003);
  final m1 = uuid(0x921);

  final direct = conversationOf(0x11);
  final groupChat = conversationOf(0x22);
  final malloryChat = conversationOf(0x33);

  late PresenceRig rig;
  late DateTime t0;

  setUp(() {
    rig = PresenceRig(userId: me, deviceId: myDevice);
    rig.conversations.held
      ..[direct] = PresenceDirectConversation(direct, bob)
      ..[malloryChat] = PresenceDirectConversation(malloryChat, mallory)
      ..[groupChat] = PresenceGroupConversation(groupChat, [
        me,
        bob,
        carol,
        mallory,
      ]);
    // Mallory is not verified, so the peers answer nothing for her.
    rig.peers.devices
      ..[bob] = [b1, b2]
      ..[carol] = [c1];
    t0 = rig.clock.now();
  });

  tearDown(() => rig.close());

  Uint8List bytesOf(String conversation) => conversationBytes(conversation);

  Future<void> watchFrom(
    String conversation, {
    String? user,
    String? device,
    int leaseMs = PresenceSignalLimits.watchLeaseMs,
  }) => rig.deliver(
    PresenceWatch(conversationId: bytesOf(conversation), leaseMs: leaseMs),
    senderUser: user ?? bob,
    senderDevice: device ?? b1,
  );

  Future<void> typingFrom(
    String conversation, {
    required bool active,
    String? user,
    String? device,
    String? headerDevice,
  }) => rig.deliver(
    PresenceTyping(
      conversationId: bytesOf(conversation),
      active: active,
      ttlMs: active ? 15000 : null,
    ),
    senderUser: user ?? bob,
    senderDevice: device ?? b1,
    headerDevice: headerDevice,
  );

  /// Every typing frame sealed to [device]: when, in seconds since t0, and
  /// whether it was active.
  List<(int, bool)> typingTo(String device) => [
    for (final seal in rig.sealer.of(PresenceSignalKind.typing))
      if (seal.devices.any((target) => target.key == device))
        (
          seal.at.difference(t0).inSeconds,
          (seal.body as PresenceTyping).active,
        ),
  ];

  /// Edits the composer of [conversation] every second for [seconds].
  Future<void> typeFor(int seconds, {String? conversation}) async {
    for (var second = 0; second < seconds; second += 1) {
      await rig.edit(conversation ?? direct);
      await rig.advance(const Duration(seconds: 1));
    }
  }

  bool isTyping(PresenceSeal seal) =>
      seal.message.kind == PresenceSignalKind.typing;

  Future<PresenceLedgerEntry> ledgerOf(String device) async =>
      (await rig.ledger.read(userId: bob, deviceId: device)
              as Success<PresenceLedgerEntry?>)
          .value!;

  Future<List<String>> typersIn(String conversation) async => [
    for (final typing in await rig.state.watchTyping(conversation).first)
      typing.deviceId,
  ];

  group('the answer and the lease', () {
    test('a watch from a verified peer earns a here, and typing then goes to '
        'that device alone', () async {
      await watchFrom(direct);

      expect(rig.sealer.devicesOf(PresenceSignalKind.here), [b1]);
      final here = rig.sealer.of(PresenceSignalKind.here).single.body;
      expect((here as PresenceHere).typing, isFalse);

      await rig.edit(direct);

      expect(
        rig.sealer.devicesOf(PresenceSignalKind.typing),
        [b1],
        reason: 'b2 never watched, so it gets nothing',
      );
      expect(rig.socket.sent.map((frame) => frame.toDeviceId), [b1, b1]);
    });

    test('an answer while typing says so', () async {
      await rig.edit(direct);
      await watchFrom(direct);

      final here = rig.sealer.of(PresenceSignalKind.here).single.body;
      expect((here as PresenceHere).typing, isTrue);
    });

    final refusals = <String, Future<void> Function()>{
      'an unverified account': () =>
          watchFrom(malloryChat, user: mallory, device: m1),
      'an unverified member of a shared group': () =>
          watchFrom(groupChat, user: mallory, device: m1),
      'a member of no group this phone holds with it': () async {
        final other = conversationOf(0x55);
        rig.conversations.held[other] = PresenceGroupConversation(other, [
          me,
          bob,
        ]);
        await watchFrom(other, user: carol, device: c1);
      },
      'a group this account is not a member of': () async {
        final other = conversationOf(0x56);
        rig.conversations.held[other] = PresenceGroupConversation(other, [
          bob,
          carol,
        ]);
        await watchFrom(other);
      },
      'a group of more than 32 members': () async {
        final large = conversationOf(0x57);
        rig.conversations.held[large] = PresenceGroupConversation(large, [
          me,
          bob,
          for (var index = 0; index < 31; index += 1) uuid(0x2000 + index),
        ]);
        await watchFrom(large);
      },
      'another account\'s direct conversation': () =>
          watchFrom(direct, user: carol, device: c1),
      'a conversation this phone does not hold': () =>
          watchFrom(conversationOf(0x44)),
      'another device of this account': () =>
          watchFrom(groupChat, user: me, device: myOtherDevice),
      'a phone in the background': () async {
        await rig.setForeground(foreground: false);
        await watchFrom(direct);
        await rig.setForeground(foreground: true);
      },
    };
    for (final MapEntry(key: from, value: watch) in refusals.entries) {
      test('a watch from $from gets no answer and no lease', () async {
        await watch();
        await rig.edit(direct);
        await rig.edit(groupChat);

        expect(rig.sealer.of(PresenceSignalKind.here), isEmpty);
        expect(rig.sealer.of(PresenceSignalKind.typing), isEmpty);
      });
    }

    test('a header naming another device than the session authenticated is '
        'dropped', () async {
      // b2's session opened it, and it says it is b1's.
      await rig.deliver(
        PresenceWatch(conversationId: bytesOf(direct), leaseMs: 40000),
        senderUser: bob,
        senderDevice: b2,
        headerDevice: b1,
      );
      await typingFrom(direct, active: true, device: b2, headerDevice: b1);

      expect(rig.sealer.seals, isEmpty);
      expect(rig.sink.shown, isEmpty);
    });

    test('a lease ends after the 40 s its watch asked for', () async {
      await watchFrom(direct);
      await rig.advance(const Duration(seconds: 40));

      await rig.edit(direct);

      expect(rig.sealer.of(PresenceSignalKind.typing), isEmpty);
    });

    test('a lease never outlasts 60 s, whatever the watch asks', () async {
      await watchFrom(direct, leaseMs: 60000);
      await rig.advance(const Duration(seconds: 59));
      await rig.edit(direct);
      await rig.edit(direct, hasText: false);
      await rig.advance(const Duration(seconds: 1));
      await rig.edit(direct);

      expect(typingTo(b1), [(59, true)]);
    });
  });

  group('the typing policy', () {
    setUp(() => watchFrom(direct));

    test('starts at once, repeats every 10 s while edits go on, and stops 5 s '
        'after the last edit', () async {
      await typeFor(13);
      await rig.advance(const Duration(seconds: 20));

      expect(typingTo(b1), [(0, true), (10, true), (17, false)]);
      final first = rig.sealer.of(PresenceSignalKind.typing).first.body;
      expect((first as PresenceTyping).ttlMs, 15000);
    });

    test(
      'S1: a message sent after 3 s and the next typed for 8 s: the line of '
      'the next starts with its first edit, and is refreshed after 3 s',
      () async {
        await typeFor(3);
        await rig.report(ChatTextSent(direct));
        await rig.advance(const Duration(seconds: 1));
        await typeFor(8);
        await rig.advance(const Duration(seconds: 20));

        expect(typingTo(b1), [(0, true), (4, true), (7, true), (16, false)]);
      },
    );

    test('S2: a message sent after 7 s and the next typed for 8 s', () async {
      await typeFor(7);
      await rig.report(ChatTextSent(direct));
      await rig.advance(const Duration(seconds: 1));
      await typeFor(8);
      await rig.advance(const Duration(seconds: 20));

      expect(typingTo(b1), [(0, true), (8, true), (11, true), (20, false)]);
    });

    test('S3: typing resumed after a pause of 6 s shows at once, and the idle '
        'stop is not held back by a repeat', () async {
      await typeFor(3);
      await rig.advance(const Duration(seconds: 6));
      await typeFor(7);
      await rig.advance(const Duration(seconds: 20));

      expect(typingTo(b1), [
        (0, true),
        (7, false),
        (9, true),
        (19, true),
        (20, false),
      ], reason: 'the stop at 20 s, not 24 s');
    });

    test('a send ends the session and sends no frame, and the cleared composer '
        'that follows adds none', () async {
      await typeFor(6);
      await rig.report(ChatTextSent(direct));
      await rig.edit(direct, hasText: false);
      await rig.advance(const Duration(seconds: 30));

      expect(
        typingTo(b1),
        [(0, true)],
        reason: 'the message ends the line at the receiver (ADR-098 D3)',
      );
    });

    test(
      'a start after a stop leaves at once, however recent the stop',
      () async {
        await rig.edit(direct);
        await rig.advance(const Duration(seconds: 6));
        await rig.edit(direct);

        expect(typingTo(b1), [(0, true), (5, false), (6, true)]);
      },
    );

    test('with no lease an edit seals nothing, and the watch that comes later '
        'is answered with the typing and the next edit starts', () async {
      await rig.edit(groupChat);
      expect(rig.sealer.of(PresenceSignalKind.typing), isEmpty);
      expect(rig.sealer.seals.where(isTyping), isEmpty);

      await rig.advance(const Duration(seconds: 2));
      await watchFrom(groupChat, user: carol, device: c1);
      final here = rig.sealer
          .of(PresenceSignalKind.here)
          .singleWhere((seal) => seal.devices.any((d) => d.key == c1));
      expect((here.body as PresenceHere).typing, isTrue);
      expect(typingTo(c1), isEmpty);

      await rig.edit(groupChat);

      expect(typingTo(c1), [(2, true)]);
    });

    test('L1: with 8 live frames sent since the watcher spoke an edit sends '
        'nothing, and the next edit after the watcher spoke starts', () async {
      // The here answered the watch (1), then seven typing frames.
      for (var cycle = 0; cycle < 4; cycle += 1) {
        await rig.edit(direct);
        if (cycle < 3) {
          await rig.advance(const Duration(seconds: 5));
        }
      }
      expect(typingTo(b1), hasLength(7));
      await rig.report(ChatTextSent(direct));

      await rig.advance(const Duration(seconds: 2));
      await rig.edit(direct);
      expect(typingTo(b1), hasLength(7), reason: 'L1 held the start back');

      await watchFrom(direct);
      await rig.edit(direct);

      expect(typingTo(b1), hasLength(8));
      expect(typingTo(b1).last, (17, true));
    });

    test('a refused seal does not count as sent: ten edits in a second seal '
        'once, and the next edit after the session exists starts', () async {
      rig.sealer.refused[b1] = PresenceSealRefusal.noSession;
      for (var edit = 0; edit < 10; edit += 1) {
        await rig.edit(direct);
        await rig.advance(const Duration(milliseconds: 100));
      }

      expect(rig.sealer.seals.where(isTyping), hasLength(1));
      expect(typingTo(b1), isEmpty);

      // The ten edits took a second, so the next try is allowed.
      rig.sealer.refused.remove(b1);
      await rig.edit(direct);

      expect(typingTo(b1), [(1, true)]);
    });

    test('a start less than 5 s after a send is refreshed after 3 s, and the '
        'refresh after it comes 10 s later', () async {
      await rig.edit(direct);
      await rig.advance(const Duration(seconds: 1));
      await rig.report(ChatTextSent(direct));
      await rig.advance(const Duration(seconds: 4));
      await typeFor(14);
      await rig.advance(const Duration(seconds: 20));

      expect(
        typingTo(b1),
        [(0, true), (5, true), (8, true), (18, true), (23, false)],
        reason:
            'the start at 5 s, the refresh 3 s later, the repeat 10 s after '
            'that, and the idle stop 5 s after the last edit at 18 s',
      );
    });

    test(
      'a start 5 s or more after a send, or with no send, repeats at 10 s',
      () async {
        await rig.edit(direct);
        await rig.advance(const Duration(seconds: 1));
        await rig.report(ChatTextSent(direct));
        await rig.advance(const Duration(seconds: 5));
        await typeFor(12);
        await rig.advance(const Duration(seconds: 20));

        expect(typingTo(b1), [(0, true), (6, true), (16, true), (22, false)]);
      },
    );

    test('N7: a composer that flips every 200 ms for a minute sends at most '
        '24 typing frames, and at most 8 live frames go between two frames '
        'of the watcher', () async {
      for (var tick = 0; tick < 300; tick += 1) {
        if (tick % 125 == 0 && tick > 0) {
          // The watcher renews its lease, as an open chat does.
          await watchFrom(direct);
        }
        await rig.edit(direct, hasText: tick.isEven);
        await rig.advance(const Duration(milliseconds: 200));
      }

      final frames = typingTo(b1);
      expect(frames, isNotEmpty);
      expect(frames.length, lessThanOrEqualTo(24), reason: '$frames');
      for (var window = 0; window < 3; window += 1) {
        final live = [
          for (final seal in rig.sealer.seals)
            if (seal.devices.any((device) => device.key == b1) &&
                seal.at.difference(t0).inSeconds >= 25 * window &&
                seal.at.difference(t0).inSeconds < 25 * (window + 1))
              seal,
        ];
        expect(live.length, lessThanOrEqualTo(8), reason: 'window $window');
      }
    });

    test('N7: a user who types 2 s and sends every 6 s for a minute sends one '
        'typing frame for each message, and L1 holds none back', () async {
      for (var second = 0; second < 60; second += 1) {
        if (second > 0 && second % 25 == 0) {
          await watchFrom(direct);
        }
        final step = second % 6;
        if (step < 2) {
          await rig.edit(direct);
        } else if (step == 2) {
          await rig.report(ChatTextSent(direct));
        }
        await rig.advance(const Duration(seconds: 1));
      }

      expect(typingTo(b1), [
        for (var message = 0; message < 10; message += 1) (6 * message, true),
      ]);
    });

    test('clearing the composer stops at the end of the pace', () async {
      await rig.edit(direct);
      await rig.advance(const Duration(seconds: 2));
      await rig.edit(direct, hasText: false);
      await rig.advance(const Duration(seconds: 10));

      expect(typingTo(b1), [(0, true), (5, false)]);
    });

    test('leaving the chat stops typing in it', () async {
      await rig.show(direct);
      await typeFor(7);
      await rig.show(null);

      expect(typingTo(b1), [(0, true), (7, false)]);
    });

    test('a change undone inside the pace sends nothing', () async {
      await rig.edit(direct);
      await rig.advance(const Duration(seconds: 1));
      await rig.edit(direct, hasText: false);
      await rig.advance(const Duration(seconds: 1));
      await rig.edit(direct);
      await rig.advance(const Duration(seconds: 4));

      expect(typingTo(b1), [(0, true)]);
    });

    test('leaving the foreground sends no stop: its gone ends the line '
        '(ADR-101 G3)', () async {
      await typeFor(6);
      await rig.setForeground(foreground: false);
      expect(typingTo(b1), [(0, true)]);
      expect(rig.sealer.devicesOf(PresenceSignalKind.gone), [b1]);

      await rig.advance(const Duration(seconds: 14));
      await rig.setForeground(foreground: true);
      await watchFrom(direct);
      await rig.edit(direct);
      await rig.advance(const Duration(seconds: 2));
      await rig.setForeground(foreground: false);
      await rig.advance(const Duration(seconds: 30));

      expect(
        typingTo(b1),
        [(0, true), (20, true)],
        reason:
            'each departure sends gone and no stop, the session starts '
            'again when the app returns, and nothing repeats in the '
            'background',
      );
      expect(rig.sealer.devicesOf(PresenceSignalKind.gone), [b1, b1]);
    });

    test('a chat nobody watches costs nothing', () async {
      await rig.edit(groupChat);
      await rig.advance(const Duration(seconds: 30));

      expect(rig.sealer.of(PresenceSignalKind.typing), isEmpty);
    });

    test('typing goes to no device the seal refuses', () async {
      rig.sealer.refused[b1] = PresenceSealRefusal.noSession;

      await rig.edit(direct);

      expect(rig.sealer.of(PresenceSignalKind.typing), isEmpty);
      expect(rig.socket.sent.map((frame) => frame.toDeviceId), [b1]);
    });
  });

  group('typing received', () {
    test('shows the sender until its ttl, and a stop ends it', () async {
      await typingFrom(direct, active: true);

      expect(await typersIn(direct), [b1]);
      expect(
        rig.sink.shown.last.expiresAt,
        t0.add(const Duration(seconds: 15)),
      );

      await typingFrom(direct, active: false);
      expect(await typersIn(direct), isEmpty);
    });

    test('ends 15 s after the latest active frame', () async {
      await typingFrom(direct, active: true);
      await rig.advance(const Duration(seconds: 10));
      await typingFrom(direct, active: true);
      await rig.advance(const Duration(seconds: 14));
      expect(await typersIn(direct), [b1]);

      await rig.advance(const Duration(seconds: 1));
      expect(await typersIn(direct), isEmpty);
    });

    test('ends at once when a message of its sender appears', () async {
      await typingFrom(direct, active: true);
      await typingFrom(groupChat, active: true, user: carol, device: c1);

      await rig.report(ChatMessageArrived(direct, senderDeviceId: b1));

      expect(await typersIn(direct), isEmpty);
      expect(await typersIn(groupChat), [c1], reason: 'only that conversation');
    });

    test('a here that says typing shows it for 15 s', () async {
      await rig.deliver(
        PresenceHere(conversationId: bytesOf(direct), typing: true),
        senderUser: bob,
        senderDevice: b1,
      );

      expect(
        rig.sink.shown.single.expiresAt,
        t0.add(const Duration(seconds: 15)),
      );
      expect(await typersIn(direct), [b1]);
    });

    test('gone ends its typing and its lease', () async {
      await watchFrom(direct);
      await typingFrom(direct, active: true);

      await rig.deliver(
        const PresenceGone(PresenceGoneReason.leftForeground),
        senderUser: bob,
        senderDevice: b1,
      );
      await rig.edit(direct);

      expect(await typersIn(direct), isEmpty);
      expect(rig.sealer.of(PresenceSignalKind.typing), isEmpty);
    });

    test('a frame older than the newest of its sender instance is dropped, and '
        'a new instance replaces the old', () async {
      final first = Uint8List.fromList(List.filled(16, 1));
      final second = Uint8List.fromList(List.filled(16, 2));
      PresenceTyping typing({required bool active}) => PresenceTyping(
        conversationId: bytesOf(direct),
        active: active,
        ttlMs: active ? 15000 : null,
      );

      await rig.deliver(
        typing(active: true),
        senderUser: bob,
        senderDevice: b1,
        instanceId: first,
        counter: 5,
      );
      await rig.deliver(
        typing(active: false),
        senderUser: bob,
        senderDevice: b1,
        instanceId: first,
        counter: 5,
      );
      expect(await typersIn(direct), [b1], reason: 'a replay of counter 5');

      await rig.deliver(
        typing(active: false),
        senderUser: bob,
        senderDevice: b1,
        instanceId: second,
        counter: 1,
      );
      expect(await typersIn(direct), isEmpty, reason: 'the app restarted');
    });

    test('nothing is shown from an unverified account or for a conversation '
        'not shared with the sender', () async {
      await typingFrom(malloryChat, active: true, user: mallory, device: m1);
      await typingFrom(direct, active: true, user: carol, device: c1);

      expect(rig.sink.shown, isEmpty);
    });

    test('an unknown version, an unknown kind and a malformed body show '
        'nothing, and each was committed', () async {
      final openings = [
        for (final payload in [
          'CPPSV001\x02\x03',
          'CPPSV001\x01\x63',
          'CPPSV001\x01\x03\xa0',
        ])
          await rig.deliverPayload(
            Uint8List.fromList(payload.codeUnits),
            senderUser: bob,
            senderDevice: b1,
          ),
      ];

      expect(rig.sink.shown, isEmpty);
      expect(openings.map((opening) => opening.commits), [1, 1, 1]);
    });

    test('the socket closing ends every typing state', () async {
      await typingFrom(direct, active: true);

      rig.channel.socketClosed();
      await rig.settle();

      expect(await typersIn(direct), isEmpty);
    });
  });

  group('the watch and its bounds', () {
    test('a chat on screen watches every verified device of the peer, for '
        '40 s', () async {
      await rig.show(direct);

      final watch = rig.sealer.of(PresenceSignalKind.watch).single;
      expect(watch.devices.map((device) => device.key), [b1, b2]);
      expect((watch.body as PresenceWatch).leaseMs, 40000);
      expect((watch.body as PresenceWatch).conversationId, bytesOf(direct));
    });

    test('Saved Messages, an unverified peer and a chat not held watch '
        'nobody', () async {
      await rig.show(malloryChat);
      await rig.show(conversationOf(0x44));
      await rig.advance(const Duration(minutes: 5));

      expect(rig.sealer.seals, isEmpty);
    });

    test('P1: a device that never answers gets four probes, at least a '
        'minute apart, then none', () async {
      rig.peers.devices[bob] = [b1];
      await rig.show(direct);
      await rig.advance(const Duration(minutes: 30));

      final probes = [
        for (final seal in rig.sealer.of(PresenceSignalKind.watch))
          seal.at.difference(t0).inSeconds,
      ];
      expect(probes, [0, 75, 150, 225]);
    });

    test('an answer makes the device live: it is renewed every 25 s and its '
        'ledger is not spent', () async {
      rig.peers.devices[bob] = [b1];
      await rig.show(direct);
      for (var round = 0; round < 6; round += 1) {
        await rig.advance(const Duration(seconds: 1));
        await rig.deliver(
          PresenceHere(conversationId: bytesOf(direct), typing: false),
          senderUser: bob,
          senderDevice: b1,
        );
        await rig.advance(const Duration(seconds: 24));
      }

      final watches = rig.sealer.of(PresenceSignalKind.watch);
      expect(watches.map((seal) => seal.at.difference(t0).inSeconds), [
        0,
        25,
        50,
        75,
        100,
        125,
        150,
      ]);
      final ledger = await ledgerOf(b1);
      expect(ledger.tokens, 3, reason: 'one probe, on the first open');
      expect(ledger.probesSinceHeard, 0);
    });

    test('a renewal unanswered for 10 s is not renewed again: the device is '
        'probed', () async {
      rig.peers.devices[bob] = [b1];
      Future<void> answer() => rig.deliver(
        PresenceHere(conversationId: bytesOf(direct), typing: false),
        senderUser: bob,
        senderDevice: b1,
      );
      await rig.show(direct);
      await rig.advance(const Duration(seconds: 1));
      await answer();
      await rig.advance(const Duration(seconds: 25));
      await answer();
      // The renewal at 50 s goes unanswered, though b1 is heard at 70 s.
      await rig.advance(const Duration(seconds: 44));
      await typingFrom(direct, active: true);
      await rig.advance(const Duration(seconds: 5));

      expect(
        rig.sealer
            .of(PresenceSignalKind.watch)
            .map((seal) => seal.at.difference(t0).inSeconds),
        [0, 25, 50, 75],
      );
      expect(
        (await ledgerOf(b1)).probesSinceHeard,
        1,
        reason: 'the watch at 75 s was a probe',
      );
    });

    test(
      'L1: at most 8 frames go to a device between two frames from it',
      () async {
        await watchFrom(direct);
        for (var second = 0; second < 36; second += 1) {
          await rig.edit(direct, hasText: second.isEven);
          await rig.advance(const Duration(seconds: 1));
        }
        final before = rig.socket.sent.where((frame) => frame.toDeviceId == b1);
        expect(before, hasLength(8), reason: 'one here and seven typing');

        await watchFrom(direct);
        expect(
          rig.socket.sent.where((frame) => frame.toDeviceId == b1),
          hasLength(9),
          reason: 'a frame from b1 resets the count',
        );
      },
    );

    test('a group watches at most two devices of each other verified member, '
        'and none of this account', () async {
      rig.peers.devices
        ..[bob] = [b1, b2, uuid(0x903)]
        ..[me] = [myDevice, myOtherDevice];
      await rig.show(groupChat);

      expect(rig.sealer.devicesOf(PresenceSignalKind.watch), [b1, b2, c1]);
    });

    test('a group of more than 32 members watches nobody', () async {
      final large = conversationOf(0x57);
      rig.conversations.held[large] = PresenceGroupConversation(large, [
        me,
        bob,
        for (var index = 0; index < 31; index += 1) uuid(0x2000 + index),
      ]);

      await rig.show(large);

      expect(rig.sealer.seals, isEmpty);
    });

    test(
      'the presence pacer lets 16 leave at once, then 12 a second',
      () async {
        final members = [
          for (var index = 0; index < 31; index += 1) uuid(0x3000 + index),
        ];
        final big = conversationOf(0x66);
        rig.conversations.held[big] = PresenceGroupConversation(big, [
          me,
          ...members,
        ]);
        for (final (index, member) in members.indexed) {
          rig.peers.devices[member] = [
            uuid(0x4000 + 2 * index),
            uuid(0x4001 + 2 * index),
          ];
        }

        await rig.show(big);

        expect(rig.socket.sent, hasLength(62));
        final waited = rig.pacerTimer.waits.fold(
          Duration.zero,
          (sum, wait) => sum + wait,
        );
        expect(
          waited.inMicroseconds,
          closeTo((62 - 16) / 12 * 1000000, 1000),
          reason: '16 leave at once, and the other 46 at 12 a second',
        );
        expect(PresenceChannel.pacerCapacity, 16);
        expect(PresenceChannel.pacerRefillPerSecond, 12);
      },
    );
  });
}
