import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/signal_ports.dart';
import 'package:communication_platform/core/application/signal_router.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/messaging/infrastructure/memory_volatile_conversation_state.dart';
import 'package:communication_platform/features/signals/application/chat_activity.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_channel.dart';
import 'package:communication_platform/features/signals/application/presence_share_setting.dart';
import 'package:communication_platform/features/signals/application/presence_status_book.dart';
import 'package:communication_platform/features/signals/domain/peer_status_model.dart';
import 'package:communication_platform/features/signals/infrastructure/presence_adapters.dart';
import 'package:communication_platform/features/voice/infrastructure/pairwise_voice_signal_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/volatile_pairwise_harness.dart';
import '../voice/support/signal_fakes.dart';
import 'support/presence_fakes.dart';

/// Typing between two faked phones, each with its own database, sessions,
/// sealer, opener, router and presence channel, joined by a relay that
/// behaves as the server does: a frame reaches the device it names if that
/// device is connected, and is dropped otherwise (T4, T5).
void main() {
  final aliceUser = testUuid(3001);
  final aliceDevice = testUuid(801);
  final bobUser = testUuid(3002);
  final bobDevice = testUuid(802);
  final bobTablet = testUuid(804);
  final malloryUser = testUuid(3003);
  final malloryDevice = testUuid(803);
  final aliceBob = filled(16, 0xab);
  final aliceMallory = filled(16, 0xac);
  final direct = conversationOf(0x11);
  final malloryChat = conversationOf(0x33);

  late FakeRatchetCrypto crypto;
  late FakeLiveDevices liveDevices;
  late FakeSignalClock clock;
  late _Relay relay;
  late VolatileDevice alice;
  late VolatileDevice bob;
  final phones = <_Phone>[];

  /// [peers] is what this phone's verified-peer reads answer, which the seal
  /// checks again against [liveDevices].
  _Phone phoneFor(
    VolatileDevice device, {
    required Map<String, PresenceConversation> conversations,
    required Map<String, List<String>> peers,
  }) {
    final socket = relay.socketFor(device.deviceId);
    final router = SignalRouter(
      socket: socket,
      opener: PairwiseVoiceSignalOpen(
        device.opener(crypto: crypto, liveDevices: liveDevices),
      ),
      buckets: const FixedSignalBuckets(),
    )..start();
    final phone = _Phone(
      router: router,
      clock: clock,
      device: device,
      sealer: PairwisePresenceSeal(
        sealer: device.sealer(crypto: crypto, liveDevices: liveDevices),
        currentUserId: device.userId,
        currentDeviceId: device.deviceId,
      ),
      socket: socket,
      conversations: FakePresenceConversations()..held.addAll(conversations),
      peers: FakePresencePeers()..devices.addAll(peers),
    );
    phones.add(phone);
    return phone;
  }

  setUp(() async {
    crypto = FakeRatchetCrypto();
    clock = FakeSignalClock();
    relay = _Relay();
    liveDevices = FakeLiveDevices(
      {
        aliceUser: [liveDevice(aliceUser, aliceDevice, identity: 0x61)],
        bobUser: [
          liveDevice(bobUser, bobDevice, identity: 0x62),
          liveDevice(bobUser, bobTablet, identity: 0x64),
        ],
      },
      failures: {
        // Mallory's account is not verified on Alice's phone.
        malloryUser: const SecurityFailure(SecurityFailureKind.policyBlocked),
      },
    );
    alice = await VolatileDevice.open(userId: aliceUser, deviceId: aliceDevice);
    bob = await VolatileDevice.open(userId: bobUser, deviceId: bobDevice);
    // Alice and Bob's phone share a session; Bob's tablet has none with
    // Alice, and Mallory has one.
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
    await alice.holdSession(
      peerUserId: malloryUser,
      peerDeviceId: malloryDevice,
      sessionId: aliceMallory,
    );
  });

  tearDown(() async {
    for (final phone in phones) {
      await phone.close();
    }
    phones.clear();
    await relay.close();
    await alice.close();
    await bob.close();
  });

  test('a phone that watches a chat sees its peer type in it, through the '
      'one session the two share', () async {
    final alicePhone = phoneFor(
      alice,
      conversations: {direct: PresenceDirectConversation(direct, bobUser)},
      peers: {
        bobUser: [bobDevice],
      },
    );
    final bobPhone = phoneFor(
      bob,
      conversations: {direct: PresenceDirectConversation(direct, aliceUser)},
      peers: {
        aliceUser: [aliceDevice],
      },
    );

    // Bob opens the chat: a watch to Alice, and her answer.
    bobPhone.visibility.show(direct);
    await _settleAll(phones);
    // Alice types.
    alicePhone.activity.report(ChatTextEdited(direct, hasText: true));
    await _settleAll(phones);

    final typing = await bobPhone.state.watchTyping(direct).first;
    expect(typing.map((entry) => entry.deviceId), [aliceDevice]);
    expect(typing.single.userId, aliceUser);
    // Watch, here and typing: three frames, each a 1024-byte blob.
    expect(relay.carried, hasLength(3));
    expect(relay.carried.map((frame) => frame.length), everyElement(1024));
    expect((await alice.sessionWith(bobDevice))!.stateVersion, 4);
    expect((await bob.sessionWith(aliceDevice))!.stateVersion, 4);
    for (final device in [alice, bob]) {
      expect(
        await device.database.select(device.database.outboxOperations).get(),
        isEmpty,
        reason: 'nothing about a frame is queued',
      );
    }

    // Alice sends: the stop waits out the 5 s pace, then clears Bob's line.
    clock.advance(const Duration(seconds: 5));
    alicePhone.activity.report(ChatTextSent(direct));
    await _settleAll(phones);
    expect(await bobPhone.state.watchTyping(direct).first, isEmpty);
  });

  test('no frame goes to a device with no session, or to an account the seal '
      'does not find verified', () async {
    final alicePhone = phoneFor(
      alice,
      conversations: {
        direct: PresenceDirectConversation(direct, bobUser),
        malloryChat: PresenceDirectConversation(malloryChat, malloryUser),
      },
      // A stale read that still names Mallory, and Bob's tablet.
      peers: {
        bobUser: [bobDevice, bobTablet],
        malloryUser: [malloryDevice],
      },
    );
    relay
      ..socketFor(bobDevice)
      ..socketFor(bobTablet);
    relay.socketFor(malloryDevice);

    alicePhone.visibility.show(direct);
    await _settleAll(phones);
    alicePhone.visibility.show(malloryChat);
    await _settleAll(phones);

    expect(relay.carriedTo, [bobDevice]);
    expect(crypto.initiateCalls, 0, reason: 'no session is started');
    expect(await alice.sessionWith(bobTablet), isNull);
    expect(
      (await alice.sessionWith(malloryDevice))!.stateVersion,
      1,
      reason: 'nothing was sealed to Mallory',
    );
  });

  test('two phones exchange the online status: an open chat sees its peer '
      'online, and its last seen once the peer leaves', () async {
    final alicePhone = phoneFor(
      alice,
      conversations: {direct: PresenceDirectConversation(direct, bobUser)},
      peers: {
        bobUser: [bobDevice],
      },
    );
    final bobPhone = phoneFor(
      bob,
      conversations: {direct: PresenceDirectConversation(direct, aliceUser)},
      peers: {
        aliceUser: [aliceDevice],
      },
    );

    // Bob opens the chat: his watch reaches Alice, whose answer reaches him.
    bobPhone.visibility.show(direct);
    await _settleAll(phones);
    expect(
      await bobPhone.status.watchUser(aliceUser).first,
      const PeerStatusOnline(),
    );
    expect(
      await alicePhone.status.watchUser(bobUser).first,
      const PeerStatusOnline(),
      reason: 'a watch is a presence frame too',
    );

    // Alice leaves the app: her goodbye reaches Bob before her socket closes.
    clock.advance(const Duration(seconds: 3));
    await alicePhone.channel.farewell();
    await _settleAll(phones);
    expect(
      await bobPhone.status.watchUser(aliceUser).first,
      PeerStatusLastSeen(clock.now()),
    );
    expect(relay.carried.map((frame) => frame.length), everyElement(1024));
  });

  test('a phone with status off answers nothing and sees nothing, and its '
      'sessions still move with every frame', () async {
    final alicePhone = phoneFor(
      alice,
      conversations: {direct: PresenceDirectConversation(direct, bobUser)},
      peers: {
        bobUser: [bobDevice],
      },
    );
    final bobPhone = phoneFor(
      bob,
      conversations: {direct: PresenceDirectConversation(direct, aliceUser)},
      peers: {
        aliceUser: [aliceDevice],
      },
    );
    await alicePhone.sharing.set(sharing: false);
    await _settleAll(phones);

    bobPhone.visibility.show(direct);
    await _settleAll(phones);

    expect(relay.carriedTo, [aliceDevice], reason: "Bob's watch, unanswered");
    expect(
      await bobPhone.status.watchUser(aliceUser).first,
      const PeerStatusNone(),
    );
    expect(
      await alicePhone.status.watchUser(bobUser).first,
      const PeerStatusNone(),
    );
    expect(
      (await alice.sessionWith(bobDevice))!.stateVersion,
      2,
      reason: 'the watch was opened and committed all the same',
    );
  });
}

Future<void> _settleAll(List<_Phone> phones) async {
  for (var round = 0; round < 4; round += 1) {
    for (var turn = 0; turn < 30; turn += 1) {
      await Future<void>.delayed(Duration.zero);
    }
    for (final phone in phones) {
      await phone.channel.idle;
      await phone.status.idle;
    }
  }
}

final class _Phone {
  _Phone({
    required this.router,
    required this.clock,
    required VolatileDevice device,
    required PresenceSealPort sealer,
    required SignalSocketPort socket,
    required PresenceConversationsPort conversations,
    required PresencePeersPort peers,
  }) {
    channel = PresenceChannel(
      currentUserId: device.userId,
      currentDeviceId: device.deviceId,
      router: router,
      socket: socket,
      sealer: sealer,
      buckets: const FixedSignalBuckets(),
      conversations: conversations,
      peers: peers,
      ledger: ledger,
      typingSink: VolatileStateTypingSink(state),
      visibility: visibility,
      activity: activity.events,
      status: status = PresenceStatusBook(
        store: ledger,
        sharing: sharing,
        conversations: conversations,
        clock: clock,
        timers: timers,
      ),
      sharing: sharing,
      clock: clock,
      timers: timers,
      pacerTimer: FakeSignalTimer(clock),
    )..start();
  }

  final SignalRouter router;
  final FakeSignalClock clock;
  late final timers = ManualPresenceTimers(clock);
  final ledger = MemoryPresenceLedger();
  final shareStore = MemoryPresenceSharePreference();
  late final sharing = PresenceShareSetting(shareStore);
  late final PresenceStatusBook status;
  final visibility = FakePresenceVisibility();
  final activity = ChatActivityHub();
  late final state = MemoryVolatileConversationState(clock: clock);
  late final PresenceChannel channel;

  Future<void> close() async {
    await channel.stop();
    await status.dispose();
    await sharing.dispose();
    await router.dispose();
    await visibility.close();
    await activity.dispose();
    state.dispose();
  }
}

/// The relay: a frame reaches the device it names if that device has a
/// socket, and is dropped otherwise.
final class _Relay {
  final _sockets = <String, _RelaySocket>{};
  final carried = <Uint8List>[];
  final carriedTo = <String>[];

  _RelaySocket socketFor(String deviceId) =>
      _sockets.putIfAbsent(deviceId, () => _RelaySocket(this));

  void _relay(String toDeviceId, String blob) {
    final target = _sockets[toDeviceId];
    if (target == null) {
      return;
    }
    carried.add(base64.decode(blob));
    carriedTo.add(toDeviceId);
    target._inbound.add(blob);
  }

  Future<void> close() async {
    for (final socket in _sockets.values) {
      await socket.close();
    }
  }
}

final class _RelaySocket implements SignalSocketPort {
  _RelaySocket(this._relay);

  final _Relay _relay;
  final _inbound = StreamController<String>.broadcast();

  @override
  Stream<String> get inboundBlobs => _inbound.stream;

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
