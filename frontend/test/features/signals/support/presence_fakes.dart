import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/application/signal_router.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/messaging/infrastructure/memory_volatile_conversation_state.dart';
import 'package:communication_platform/features/pairwise/application/ports/pairwise_orchestration_ports.dart';
import 'package:communication_platform/features/signals/application/chat_activity.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_channel.dart';
import 'package:communication_platform/features/signals/application/presence_share_setting.dart';
import 'package:communication_platform/features/signals/application/presence_status_book.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_codec.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_model.dart';
import 'package:communication_platform/features/signals/infrastructure/presence_adapters.dart';

import '../../voice/support/signal_fakes.dart';

/// Timers that fire only when [advance] moves [clock] past them.
final class ManualPresenceTimers implements PresenceTimerPort {
  ManualPresenceTimers(this.clock);

  final FakeSignalClock clock;
  final _pending = <_ManualTimer>[];

  @override
  PresenceTimer start(Duration delay, void Function() callback) {
    final timer = _ManualTimer(
      clock.now().add(delay.isNegative ? Duration.zero : delay),
      callback,
    );
    _pending.add(timer);
    return timer;
  }

  /// Moves the clock by [duration], firing every timer that falls due on the
  /// way, in order, and letting [settle] run after each.
  Future<void> advance(
    Duration duration, {
    required Future<void> Function() settle,
  }) async {
    final target = clock.now().add(duration);
    while (true) {
      _pending.removeWhere((timer) => timer.cancelled);
      final due = _pending.where((timer) => !timer.due.isAfter(target));
      if (due.isEmpty) {
        break;
      }
      final next = due.reduce(
        (left, right) => right.due.isBefore(left.due) ? right : left,
      );
      if (next.due.isAfter(clock.now())) {
        clock.advance(next.due.difference(clock.now()));
      }
      _pending.remove(next);
      next.callback();
      await settle();
    }
    if (target.isAfter(clock.now())) {
      clock.advance(target.difference(clock.now()));
    }
    await settle();
  }
}

final class _ManualTimer implements PresenceTimer {
  _ManualTimer(this.due, this.callback);

  final DateTime due;
  final void Function() callback;
  var cancelled = false;

  @override
  void cancel() => cancelled = true;
}

/// One seal: the payload, decoded, the devices it was sealed to, and whether
/// the goodbye's seal made it.
final class PresenceSeal {
  const PresenceSeal(
    this.message,
    this.devices,
    this.at, {
    this.goodbye = false,
  });

  final PresenceSignalMessage message;
  final List<PresenceDevice> devices;
  final DateTime at;
  final bool goodbye;

  PresenceSignalBody get body => message.body;
}

/// Seals every target into a 1024-byte frame, except a device named in
/// [refused], and keeps every seal. [goodbye] is the goodbye's seal, kept in
/// the same record.
final class RecordingPresenceSealer implements PresenceSealPort {
  RecordingPresenceSealer(this.clock);

  final FakeSignalClock clock;
  final seals = <PresenceSeal>[];

  /// Every payload sealed, byte for byte.
  final payloads = <Uint8List>[];
  final refused = <String, PresenceSealRefusal>{};

  /// When set, a target is sealed only when this resolver's answer for its
  /// account names the device, as the production seal resolves each account
  /// under the router lock; any other is refused as unverified.
  PairwiseLiveDeviceResolverPort? resolver;

  /// [resolver], for [goodbye].
  PairwiseLiveDeviceResolverPort? goodbyeResolver;

  late final PresenceSealPort goodbye = _RecordingGoodbyeSeal(this);

  @override
  Future<Result<List<PresenceSealOutcome>>> seal({
    required Uint8List payload,
    required List<PresenceDevice> targets,
    required Set<int> allowedLengths,
  }) => _seal(payload, targets, resolver, goodbye: false);

  Future<Result<List<PresenceSealOutcome>>> _seal(
    Uint8List payload,
    List<PresenceDevice> targets,
    PairwiseLiveDeviceResolverPort? resolver, {
    required bool goodbye,
  }) async {
    final named = <String, Set<String>>{};
    if (resolver != null) {
      for (final user in {
        for (final target in targets) target.userId.toLowerCase(),
      }) {
        named[user] = switch (await resolver.resolveVerifiedLiveDevices(user)) {
          Success(value: final devices) => {
            for (final device in devices) device.deviceId.toLowerCase(),
          },
          FailureResult() => const {},
        };
      }
    }
    final outcomes = [
      for (final target in targets)
        if (refused[target.key] case final reason?)
          PresenceSealRefused(target, reason)
        else if (resolver != null &&
            !(named[target.userId.toLowerCase()]?.contains(target.key) ??
                false))
          PresenceSealRefused(target, PresenceSealRefusal.unverified)
        else
          PresenceSealed(target, Uint8List(1024)),
    ];
    payloads.add(Uint8List.fromList(payload));
    final decoded = PresenceSignalCodec.decode(payload);
    seals.add(
      PresenceSeal(
        (decoded as DecodedPresenceSignal).message,
        [
          for (final outcome in outcomes)
            if (outcome is PresenceSealed) outcome.device,
        ],
        clock.now(),
        goodbye: goodbye,
      ),
    );
    return Result.success(outcomes);
  }

  /// Every device sealed a frame of [kind], in order.
  List<String> devicesOf(PresenceSignalKind kind) => [
    for (final seal in seals)
      if (seal.message.kind == kind)
        for (final device in seal.devices) device.key,
  ];

  List<PresenceSeal> of(PresenceSignalKind kind) => [
    for (final seal in seals)
      if (seal.message.kind == kind && seal.devices.isNotEmpty) seal,
  ];
}

final class _RecordingGoodbyeSeal implements PresenceSealPort {
  const _RecordingGoodbyeSeal(this.record);

  final RecordingPresenceSealer record;

  @override
  Future<Result<List<PresenceSealOutcome>>> seal({
    required Uint8List payload,
    required List<PresenceDevice> targets,
    required Set<int> allowedLengths,
  }) => record._seal(payload, targets, record.goodbyeResolver, goodbye: true);
}

/// The last seen in [delegate], with every write on the record.
final class RecordingLastSeen implements PresenceLastSeenPort {
  RecordingLastSeen(this.delegate);

  final PresenceLastSeenPort delegate;

  /// Each write: the device and the time it wrote.
  final writes = <(String, int)>[];
  var forgets = 0;

  @override
  Future<Result<List<PresenceLastSeen>>> readLastSeen(Set<String> userIds) =>
      delegate.readLastSeen(userIds);

  @override
  Future<Result<void>> writeLastSeen(PresenceDevice device, int lastSeenMs) {
    writes.add((device.key, lastSeenMs));
    return delegate.writeLastSeen(device, lastSeenMs);
  }

  @override
  Future<Result<void>> forgetLastSeen([PresenceDevice? device]) {
    forgets += 1;
    return delegate.forgetLastSeen(device);
  }
}

final class FakePresenceConversations implements PresenceConversationsPort {
  final held = <String, PresenceConversation>{};

  @override
  Future<PresenceConversation?> read(String conversationId) async =>
      held[conversationId];
}

/// The verified accounts and their live devices. An account absent from
/// [devices] is unverified. It keeps no answer: every call is a read.
final class FakePresencePeers implements PresencePeersPort {
  final devices = <String, List<String>>{};
  final reads = <Set<String>>[];

  /// The devices each read had to name, in the order of [reads].
  final including = <Set<PresenceDevice>>[];

  /// While set, a read that has to name a device waits for it: the read a
  /// frame makes before the router lock, and the receive path's.
  Completer<void>? gate;

  @override
  Future<Map<String, List<String>>> verifiedDevices(
    Set<String> userIds, {
    Set<PresenceDevice> including = const {},
  }) async {
    reads.add(userIds);
    this.including.add(including);
    final held = gate;
    if (held != null && including.isNotEmpty) {
      await held.future;
    }
    return {for (final user in userIds) user: ?devices[user]};
  }

  @override
  Future<List<String>?> peek(String userId) async => devices[userId];
}

final class ShownTyping {
  const ShownTyping({
    required this.conversationId,
    required this.userId,
    required this.deviceId,
    required this.active,
    required this.expiresAt,
  });

  final String conversationId;
  final String userId;
  final String deviceId;
  final bool active;
  final DateTime expiresAt;
}

/// Keeps every call, and hands each on to [forward] when there is one.
final class RecordingTypingSink implements PresenceTypingSinkPort {
  RecordingTypingSink([this.forward]);

  final PresenceTypingSinkPort? forward;
  final shown = <ShownTyping>[];
  var cleared = 0;

  @override
  void showTyping({
    required String conversationId,
    required String userId,
    required String deviceId,
    required bool active,
    required DateTime expiresAt,
    required DateTime authenticatedAt,
  }) {
    shown.add(
      ShownTyping(
        conversationId: conversationId,
        userId: userId,
        deviceId: deviceId,
        active: active,
        expiresAt: expiresAt,
      ),
    );
    forward?.showTyping(
      conversationId: conversationId,
      userId: userId,
      deviceId: deviceId,
      active: active,
      expiresAt: expiresAt,
      authenticatedAt: authenticatedAt,
    );
  }

  @override
  void clearAll() {
    cleared += 1;
    forward?.clearAll();
  }
}

final class FakePresenceVisibility implements PresenceVisibilityPort {
  final _changes = StreamController<void>.broadcast(sync: true);
  String? _conversation;
  bool _foreground = true;

  @override
  String? get visibleConversationId => _foreground ? _conversation : null;

  @override
  bool get isForeground => _foreground;

  @override
  Stream<void> get changes => _changes.stream;

  void show(String? conversationId) {
    _conversation = conversationId;
    _changes.add(null);
  }

  void setForeground({required bool foreground}) {
    _foreground = foreground;
    _changes.add(null);
  }

  Future<void> close() => _changes.close();
}

String uuid(int value) =>
    '00000000-0000-4000-8000-${value.toRadixString(16).padLeft(12, '0')}';

String conversationOf(int value) =>
    value.toRadixString(16).padLeft(2, '0') * 32;

Uint8List conversationBytes(String conversationId) => Uint8List.fromList([
  for (var index = 0; index < conversationId.length; index += 2)
    int.parse(conversationId.substring(index, index + 2), radix: 16),
]);

/// One phone's presence channel over fakes, with a router fed by a fake
/// socket and opener.
final class PresenceRig {
  /// [peersFor] builds the peer reads the channel asks instead of [peers],
  /// on this rig's clock.
  PresenceRig({
    required this.userId,
    required this.deviceId,
    PresencePeersPort Function(FakeSignalClock clock)? peersFor,
  }) {
    router = SignalRouter(
      socket: socket,
      opener: opener,
      buckets: const FixedSignalBuckets(),
    )..start();
    channel = PresenceChannel(
      currentUserId: userId,
      currentDeviceId: deviceId,
      router: router,
      socket: socket,
      sealer: sealer,
      goodbyeSealer: sealer.goodbye,
      buckets: const FixedSignalBuckets(),
      conversations: conversations,
      peers: peersFor?.call(clock) ?? peers,
      ledger: ledger,
      typingSink: sink,
      visibility: visibility,
      activity: activity.events,
      status: status,
      sharing: sharing,
      clock: clock,
      timers: timers,
      pacerTimer: pacerTimer,
    )..start();
  }

  final String userId;
  final String deviceId;
  final clock = FakeSignalClock();
  late final socket = FakeSignalSocket(clock);
  final opener = FakeSignalOpener();
  late final sealer = RecordingPresenceSealer(clock);
  final conversations = FakePresenceConversations();
  final peers = FakePresencePeers();
  final ledger = MemoryPresenceLedger();

  /// "Show my online status", on until a test turns it off.
  final shareStore = MemoryPresenceSharePreference();
  late final sharing = PresenceShareSetting(shareStore);

  /// Who this phone sees online, and the last seen it keeps in [ledger].
  late final lastSeen = RecordingLastSeen(ledger);
  late final status = PresenceStatusBook(
    store: lastSeen,
    sharing: sharing,
    conversations: conversations,
    clock: clock,
    timers: timers,
  );

  /// The typing state the chat headers read, on this rig's clock.
  late final state = MemoryVolatileConversationState(clock: clock);
  late final sink = RecordingTypingSink(VolatileStateTypingSink(state));
  final visibility = FakePresenceVisibility();
  final activity = ChatActivityHub();
  late final timers = ManualPresenceTimers(clock);

  /// The presence pacer's waits, each on the record.
  late final pacerTimer = FakeSignalTimer(clock);
  late final SignalRouter router;
  late final PresenceChannel channel;

  var _marker = 0;
  final _instances = <String, Uint8List>{};
  final _counters = <String, int>{};

  Future<void> settle() async {
    await pump();
    await channel.idle;
    await status.idle;
  }

  /// Lets every microtask and zero timer run, without waiting for the channel
  /// to be idle: a test that holds a read looks at what moved meanwhile.
  Future<void> pump() async {
    for (var turn = 0; turn < 30; turn += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> advance(Duration duration) =>
      timers.advance(duration, settle: settle);

  /// Delivers [body] as a frame that [senderDevice] of [senderUser] sealed,
  /// its header naming [headerDevice] (the sender unless said otherwise).
  Future<FakeOpening> deliver(
    PresenceSignalBody body, {
    required String senderUser,
    required String senderDevice,
    String? headerDevice,
    String? headerUser,
    Uint8List? instanceId,
    int? counter,
    bool settle = true,
  }) {
    final key = senderDevice.toLowerCase();
    final instance =
        instanceId ??
        (_instances[key] ??= Uint8List.fromList(
          List<int>.filled(16, (key.hashCode & 0x7f) + 1),
        ));
    final next = counter ?? (_counters[key] = (_counters[key] ?? 0) + 1);
    final payload =
        (PresenceSignalCodec.encode(
                  PresenceSignalMessage(
                    header: PresenceSignalHeader(
                      senderUserId: protocolUuidBytes(headerUser ?? senderUser),
                      senderDeviceId: protocolUuidBytes(
                        headerDevice ?? senderDevice,
                      ),
                      instanceId: instance,
                      counter: next,
                    ),
                    body: body,
                  ),
                )
                as Success<Uint8List>)
            .value;
    return deliverPayload(
      payload,
      senderUser: senderUser,
      senderDevice: senderDevice,
      settle: settle,
    );
  }

  /// Hands [payload] to the router as a frame. With [settle] false it only
  /// [pump]s, so a held read is not waited for.
  Future<FakeOpening> deliverPayload(
    Uint8List payload, {
    required String senderUser,
    required String senderDevice,
    bool settle = true,
  }) async {
    _marker = _marker % 255 + 1;
    final opening = FakeOpening(
      senderUserId: senderUser,
      senderDeviceId: senderDevice,
      payload: payload,
    );
    opener.openings[_marker] = opening;
    socket.deliver(base64.encode(Uint8List(1024)..[0] = _marker));
    await (settle ? this.settle() : pump());
    return opening;
  }

  /// Reports [activity] from a chat screen, and lets the channel handle it.
  Future<void> report(ChatActivity event) async {
    activity.report(event);
    await settle();
  }

  Future<void> edit(String conversationId, {bool hasText = true}) =>
      report(ChatTextEdited(conversationId, hasText: hasText));

  /// Puts [conversationId] on screen, or none, and lets the channel follow.
  Future<void> show(String? conversationId) async {
    visibility.show(conversationId);
    await settle();
  }

  Future<void> setForeground({required bool foreground}) async {
    visibility.setForeground(foreground: foreground);
    await settle();
  }

  Future<void> close() async {
    await channel.stop();
    await status.dispose();
    await sharing.dispose();
    await router.dispose();
    await socket.close();
    await visibility.close();
    state.dispose();
    await activity.dispose();
  }
}
