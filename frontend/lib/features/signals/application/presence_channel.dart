import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/signal_ports.dart';
import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/application/signal_frame_pacer.dart';
import 'package:communication_platform/core/application/signal_router.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/application/chat_activity.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_probe_ledger.dart';
import 'package:communication_platform/features/signals/application/presence_share_setting.dart';
import 'package:communication_platform/features/signals/application/presence_status_book.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_codec.dart';
import 'package:communication_platform/features/signals/domain/presence_signal_model.dart';

/// Typing and the online status over `CPPSV001` (ADR-098 D2 to D9): the
/// watch of the chat on screen, the answer and the lease it earns, typing
/// sent to the devices that hold a lease, typing received and shown, who is
/// online, and the goodbye.
///
/// **Who hears what.** A phone in the foreground watches the conversation it
/// shows: it sends a `watch` to the peer's devices, or in a group of at most
/// [maximumGroupMembers] to at most [devicesPerMember] devices of each other
/// member, and renews it every [watchRenewal]. A device in the foreground
/// answers each watch it accepts with `here` and keeps a lease for the
/// watcher; typing goes only to devices holding a live lease, never to this
/// account's own, and only through a seal that refuses an unverified account
/// and a device with no session (T4). A chat that nobody watches costs
/// nothing.
///
/// **What it costs (T6).** A watch to a device not heard from in
/// [liveWindow] is a probe, bounded by [PresenceProbeLedger]. Between two
/// frames committed from a device at most [liveFramesBetweenHeard] other
/// frames go to it. Frames leave through a pacer of 16 refilled at 12 a
/// second, beside voice's own.
///
/// **What it accepts.** A frame is read only after the router committed it,
/// only when its header names the device the session authenticated, only in
/// order within one sender instance, and only for a conversation this phone
/// holds with that sender, from an account this user has verified. Anything
/// else is dropped without an answer. Each accepted frame makes its sender
/// online in [status] (D4).
///
/// **Leaving.** On leaving the foreground, and in [farewell] before the
/// socket closes, it sends `gone` to every device with a live lease in either
/// direction (D5).
///
/// **The switch** (D9). While [sharing] is off it sends nothing, answers
/// nothing and shows nothing; the router still commits every frame, and this
/// discards it. Turning it off sends one `gone` to the live leases of that
/// moment, and nothing after.
///
/// Nothing is logged.
final class PresenceChannel {
  PresenceChannel({
    required this.currentUserId,
    required this.currentDeviceId,
    required this.router,
    required this.socket,
    required this.sealer,
    required this.buckets,
    required this.conversations,
    required this.peers,
    required PresenceLedgerPort ledger,
    required this.typingSink,
    required this.visibility,
    required this.activity,
    required this.status,
    required this.sharing,
    required this.clock,
    required this.timers,
    required SignalTimerPort pacerTimer,
    Random? random,
  }) : _ledger = PresenceProbeLedger(ledger),
       _random = random ?? Random.secure(),
       _pacer = SignalFramePacer(
         clock: clock,
         timer: pacerTimer,
         capacity: pacerCapacity,
         refillPerSecond: pacerRefillPerSecond,
       ) {
    _instanceId = _mintInstanceId();
  }

  /// The presence pacer (D7).
  static const pacerCapacity = 16;
  static const pacerRefillPerSecond = 12;

  /// A device is live for this long after its latest committed frame, and a
  /// lease lasts this long (D2, D4).
  static const liveWindow = Duration(seconds: 40);
  static const maximumLease = Duration(
    milliseconds: PresenceSignalLimits.maximumLeaseMs,
  );

  /// How often an open chat renews its watch, and how long a renewal waits
  /// for its answer (D4).
  static const watchRenewal = Duration(seconds: 25);
  static const renewalAnswerWindow = Duration(seconds: 10);

  /// The typing policy (D3).
  static const typingTtl = Duration(
    milliseconds: PresenceSignalLimits.maximumTypingTtlMs,
  );
  static const typingRepeat = Duration(seconds: 10);
  static const typingIdle = Duration(seconds: 5);
  static const typingPace = Duration(seconds: 5);

  /// The fan-out of one watch (D4).
  static const maximumGroupMembers = 32;
  static const devicesPerMember = 2;
  static const maximumPeerDevices = 10;

  /// L1 (D6).
  static const liveFramesBetweenHeard = 8;

  final String currentUserId;
  final String currentDeviceId;
  final SignalRouter router;
  final SignalSocketPort socket;
  final PresenceSealPort sealer;
  final SignalBucketsPort buckets;
  final PresenceConversationsPort conversations;
  final PresencePeersPort peers;
  final PresenceTypingSinkPort typingSink;
  final PresenceVisibilityPort visibility;
  final Stream<ChatActivity> activity;
  final PresenceStatusBook status;
  final PresenceShareSetting sharing;
  final TimeSource clock;
  final PresenceTimerPort timers;

  final PresenceProbeLedger _ledger;
  final Random _random;
  final SignalFramePacer _pacer;
  late Uint8List _instanceId;
  var _counter = 0;

  final _subscriptions = <StreamSubscription<Object?>>[];
  Future<void> _turn = Future<void>.value();
  final _inFlight = <Future<void>>{};
  var _running = false;
  var _foreground = false;

  /// "Show my online status", as this channel last applied it. Off until the
  /// stored choice is read, so nothing leaves before it is known.
  var _sharing = false;

  /// When a frame from each device was last committed, on any channel.
  final _heardAt = <String, DateTime>{};

  /// L1: frames sent to each device since it was last heard.
  final _liveFrames = <String, int>{};

  /// Devices that said `gone`, until they are heard again.
  final _gone = <String>{};

  /// The newest `(instance_id, counter)` of each sender.
  final _newest = <String, (String, int)>{};

  /// Each conversation's watchers: their devices, and when each lease ends.
  final _leases = <String, Map<String, _Lease>>{};

  /// The typing this phone shows, by device: who, and in which conversations.
  final _shownTyping = <String, _ShownTyping>{};

  final _typingOut = <String, _TypingOut>{};
  _Watch? _watch;

  /// Starts reading the router's presence frames and the screens' activity,
  /// and watches whatever is on screen now.
  void start() {
    if (_running) {
      return;
    }
    _running = true;
    _subscriptions
      ..add(
        router.heard.listen(
          (heard) => _serially(
            () => _onHeard(
              PresenceDevice(userId: heard.userId, deviceId: heard.deviceId),
            ),
          ),
        ),
      )
      ..add(
        router
            .channel(SignalChannel.presence)
            .listen((signal) => _serially(() => _receive(signal))),
      )
      ..add(visibility.changes.listen((_) => _serially(_followVisibility)))
      ..add(activity.listen((event) => _serially(() => _onActivity(event))))
      ..add(
        sharing.changes.listen(
          (on) => _serially(() => _onSharingChanged(on: on)),
        ),
      );
    _serially(() async {
      _sharing = await sharing.read();
      await _followVisibility();
    });
  }

  /// Says goodbye before the socket closes (D5): the pending typing stops
  /// and `gone` to every device with a live lease in either direction, then
  /// nothing more until the app is in the foreground again. Completes once
  /// those frames have gone to the socket.
  Future<void> farewell() async {
    _serially(() async {
      if (_foreground) {
        await _leaveForeground();
        _foreground = false;
        _closeWatch();
      }
    });
    await idle;
  }

  /// Stops everything, forgets every lease and every watch, and ends every
  /// typing state shown.
  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await idle;
    _closeWatch();
    for (final typing in _typingOut.values) {
      typing.cancelTimers();
    }
    _typingOut.clear();
    _leases.clear();
    _clearShownTyping();
  }

  /// The socket closed: every typing state shown ends with it.
  void socketClosed() => _serially(() async => _clearShownTyping());

  /// Completes once every event taken so far is handled and every frame it
  /// sealed has gone to the socket.
  Future<void> get idle async {
    while (true) {
      final turn = _turn;
      await turn;
      final inFlight = List.of(_inFlight);
      await Future.wait(inFlight);
      if (identical(turn, _turn) && _inFlight.isEmpty) {
        return;
      }
    }
  }

  // ---------------------------------------------------------------------
  // Inbound.

  Future<void> _onHeard(PresenceDevice device) async {
    final key = device.key;
    _heardAt[key] = clock.now();
    _liveFrames.remove(key);
    _gone.remove(key);
    await _ledger.heard(device);
  }

  Future<void> _receive(RoutedSignal signal) async {
    // Off, a frame was committed by the router, which spares its sender a
    // dead key, and is discarded here unread (D9).
    if (!_sharing) {
      return;
    }
    final decoding = PresenceSignalCodec.decode(signal.payload);
    // An unknown version, an unknown kind and a malformed body were committed
    // by the router and are ignored here.
    if (decoding is! DecodedPresenceSignal) {
      return;
    }
    final message = decoding.message;
    final sender = PresenceDevice(
      userId: signal.senderUserId.toLowerCase(),
      deviceId: signal.senderDeviceId.toLowerCase(),
    );
    if (!_isFromSender(message.header, sender) ||
        sender.userId == currentUserId.toLowerCase()) {
      return;
    }
    final instance = protocolBytesToHex(message.header.instanceId);
    final newest = _newest[sender.key];
    if (newest != null &&
        newest.$1 == instance &&
        message.header.counter <= newest.$2) {
      return;
    }
    _newest[sender.key] = (instance, message.header.counter);

    final now = clock.now();
    switch (message.body) {
      case PresenceWatch(:final conversationId, :final leaseMs):
        final conversation = protocolBytesToHex(conversationId);
        if (!await _accepts(conversation, sender)) {
          return;
        }
        await status.heard(sender);
        // In the background a device answers nothing: online means the app
        // is on screen (D4).
        if (!_foreground) {
          return;
        }
        final lease = Duration(milliseconds: leaseMs);
        (_leases[conversation] ??= {})[sender.key] = _Lease(
          sender,
          now.add(lease > maximumLease ? maximumLease : lease),
        );
        await _send(
          PresenceHere(
            conversationId: conversationId,
            typing: _typingOut[conversation]?.wanted ?? false,
          ),
          live: [sender],
        );
      case PresenceHere(:final conversationId, :final typing):
        final conversation = protocolBytesToHex(conversationId);
        if (!await _accepts(conversation, sender)) {
          return;
        }
        await status.heard(sender);
        final watch = _watch;
        if (watch != null && watch.conversationId == conversation) {
          watch.answeredAt[sender.key] = now;
        }
        _showTyping(conversation, sender, typing ? typingTtl : null, now);
      case PresenceTyping(:final conversationId, :final active, :final ttlMs):
        final conversation = protocolBytesToHex(conversationId);
        if (!await _accepts(conversation, sender)) {
          return;
        }
        await status.heard(sender);
        _showTyping(
          conversation,
          sender,
          active ? Duration(milliseconds: ttlMs!) : null,
          now,
        );
      case PresenceGone(:final reason):
        if (!_holdsLeaseOrWatches(sender.key) && !status.isOnline(sender.key)) {
          return;
        }
        _gone.add(sender.key);
        _heardAt.remove(sender.key);
        for (final watchers in _leases.values) {
          watchers.remove(sender.key);
        }
        _hideTypingOf(sender.key, now);
        await status.gone(
          sender,
          forget: reason == PresenceGoneReason.statusTurnedOff,
        );
    }
  }

  /// Whether [conversation] is one this phone holds with [sender], whose
  /// account this user has verified (D2).
  Future<bool> _accepts(String conversation, PresenceDevice sender) async {
    final held = await conversations.read(conversation);
    final shared = switch (held) {
      PresenceDirectConversation(:final peerUserId) =>
        peerUserId.toLowerCase() == sender.userId,
      PresenceGroupConversation(:final activeMemberUserIds) =>
        activeMemberUserIds.length <= maximumGroupMembers &&
            activeMemberUserIds.contains(sender.userId) &&
            activeMemberUserIds.contains(currentUserId.toLowerCase()),
      null => false,
    };
    if (!shared) {
      return false;
    }
    final verified = await peers.verifiedDevices({sender.userId});
    return verified[sender.userId]?.contains(sender.key) ?? false;
  }

  bool _holdsLeaseOrWatches(String key) =>
      _leases.values.any((watchers) => watchers.containsKey(key)) ||
      (_watch?.targets.any((target) => target.key == key) ?? false);

  void _showTyping(
    String conversation,
    PresenceDevice sender,
    Duration? ttl,
    DateTime now,
  ) {
    final shown = _shownTyping[sender.key] ??= _ShownTyping(sender.userId);
    if (ttl == null) {
      if (!shown.conversations.remove(conversation)) {
        return;
      }
    } else {
      shown.conversations.add(conversation);
    }
    typingSink.showTyping(
      conversationId: conversation,
      userId: sender.userId,
      deviceId: sender.key,
      active: ttl != null,
      expiresAt: now.add(ttl ?? Duration.zero),
      authenticatedAt: now,
    );
  }

  void _hideTypingOf(String key, DateTime now, {String? only}) {
    final shown = _shownTyping[key];
    if (shown == null) {
      return;
    }
    for (final conversation in List.of(shown.conversations)) {
      if (only != null && conversation != only) {
        continue;
      }
      shown.conversations.remove(conversation);
      typingSink.showTyping(
        conversationId: conversation,
        userId: shown.userId,
        deviceId: key,
        active: false,
        expiresAt: now,
        authenticatedAt: now,
      );
    }
  }

  void _clearShownTyping() {
    _shownTyping.clear();
    typingSink.clearAll();
  }

  // ---------------------------------------------------------------------
  // The chat on screen.

  Future<void> _followVisibility() async {
    final foreground = visibility.isForeground;
    // Off, nothing is watched (D9).
    final shown = foreground && _sharing
        ? visibility.visibleConversationId
        : null;
    if (_foreground && !foreground) {
      await _leaveForeground();
    }
    _foreground = foreground;
    final watched = _watch?.conversationId;
    if (shown == watched) {
      return;
    }
    if (watched != null) {
      _closeWatch();
      // Leaving the chat stops typing in it.
      final typing = _typingOut[watched];
      if (typing != null && foreground) {
        typing.wanted = false;
        typing.idle?.cancel();
        await _flushTyping(watched);
      }
    }
    if (shown != null) {
      final watch = _Watch(shown);
      _watch = watch;
      await _watchRound(watch);
      if (identical(_watch, watch)) {
        watch.timer = _periodic(watchRenewal, () => _watchRound(watch));
      }
    }
  }

  /// Leaving the foreground stops typing at once and says `gone` to every
  /// device with a live lease in either direction (D5), which ends the
  /// typing it shows too. A stop the pace holds back is not sent: the socket
  /// closes now, and a frame sealed after it closed would be a drop; the
  /// `gone` ends it instead. Every lease ends here, since a device in the
  /// background answers nothing.
  Future<void> _leaveForeground() async {
    final now = clock.now();
    final stops = <String>[];
    for (final MapEntry(key: conversation, value: typing)
        in _typingOut.entries) {
      typing
        ..wanted = false
        ..cancelTimers();
      if (!typing.sent) {
        continue;
      }
      if (typing.paceAllows(now)) {
        stops.add(conversation);
      } else {
        typing.sent = false;
      }
    }
    for (final conversation in stops) {
      await _sendTyping(conversation, active: false);
    }
    final farewell = _liveLeaseHolders(now);
    if (_sharing && farewell.isNotEmpty) {
      await _send(
        const PresenceGone(PresenceGoneReason.leftForeground),
        live: farewell,
      );
    }
    _leases.clear();
    _clearShownTyping();
  }

  /// Every device with a live lease in either direction: the devices holding
  /// an unexpired lease on a conversation of this phone, and the devices of
  /// the watch on screen that answered within [liveWindow] (D5).
  List<PresenceDevice> _liveLeaseHolders(DateTime now) {
    final holders = <String, PresenceDevice>{};
    for (final watchers in _leases.values) {
      for (final lease in watchers.values) {
        if (lease.expiresAt.isAfter(now)) {
          holders[lease.device.key] = lease.device;
        }
      }
    }
    final watch = _watch;
    if (watch != null) {
      for (final target in watch.targets) {
        final answered = watch.answeredAt[target.key];
        if (answered != null && now.difference(answered) < liveWindow) {
          holders[target.key] = target;
        }
      }
    }
    holders.removeWhere((key, _) => _gone.contains(key));
    return holders.values.toList();
  }

  /// Applies "Show my online status" (D9). Off: one `gone` to the live leases
  /// of this moment, then no watch, no lease, no typing either way. On again:
  /// the chat on screen is watched anew.
  Future<void> _onSharingChanged({required bool on}) async {
    if (on == _sharing) {
      return;
    }
    if (on) {
      _sharing = true;
      await _followVisibility();
      return;
    }
    final farewell = _liveLeaseHolders(clock.now());
    _sharing = false;
    for (final typing in _typingOut.values) {
      typing.cancelTimers();
    }
    _typingOut.clear();
    if (farewell.isNotEmpty) {
      await _send(
        const PresenceGone(PresenceGoneReason.statusTurnedOff),
        live: farewell,
      );
    }
    _closeWatch();
    _leases.clear();
    _clearShownTyping();
  }

  void _closeWatch() {
    _watch?.timer?.cancel();
    _watch = null;
  }

  /// One round of the watch of [watch]'s conversation: a live watch to each
  /// target heard from in the last [liveWindow], and a probe to each other
  /// target its ledger allows.
  Future<void> _watchRound(_Watch watch) async {
    if (!identical(_watch, watch) || !_foreground || !_sharing) {
      return;
    }
    final targets = await _watchTargets(watch.conversationId);
    if (!identical(_watch, watch)) {
      return;
    }
    watch.targets = targets;
    final now = clock.now();
    final live = <PresenceDevice>[];
    final probes = <PresenceDevice>[];
    for (final target in targets) {
      if (_gone.contains(target.key)) {
        continue;
      }
      if (_isLive(target.key, now) && !watch.renewalUnanswered(target, now)) {
        live.add(target);
      } else {
        probes.add(target);
      }
    }
    final sent = await _send(
      PresenceWatch(
        conversationId: _conversationBytes(watch.conversationId),
        leaseMs: PresenceSignalLimits.watchLeaseMs,
      ),
      live: live,
      probes: probes,
    );
    for (final device in sent) {
      if (live.contains(device)) {
        watch.renewedAt[device.key] = now;
      }
    }
  }

  /// Who a watch of [conversation] goes to (D4): every live device of a
  /// direct peer, at most [maximumPeerDevices]; in a group of at most
  /// [maximumGroupMembers], at most [devicesPerMember] of each other member,
  /// those heard from most recently, ties by device id. Only accounts this
  /// user has verified.
  Future<List<PresenceDevice>> _watchTargets(String conversation) async {
    final held = await conversations.read(conversation);
    final me = currentUserId.toLowerCase();
    final (Set<String> users, int perUser) = switch (held) {
      PresenceDirectConversation(:final peerUserId)
          when peerUserId.toLowerCase() != me =>
        ({peerUserId.toLowerCase()}, maximumPeerDevices),
      PresenceGroupConversation(:final activeMemberUserIds)
          when activeMemberUserIds.length <= maximumGroupMembers &&
              activeMemberUserIds.contains(me) =>
        ({...activeMemberUserIds}..remove(me), devicesPerMember),
      _ => (const <String>{}, 0),
    };
    if (users.isEmpty) {
      return const [];
    }
    final verified = await peers.verifiedDevices(users);
    final lastSeen = perUser < maximumPeerDevices
        ? await status.lastSeenByDevice(users)
        : const <String, int>{};
    int byNewestSeen(String left, String right) {
      final leftSeen = _newestSeen(left, lastSeen);
      final rightSeen = _newestSeen(right, lastSeen);
      if (leftSeen != rightSeen) {
        if (leftSeen == null) return 1;
        if (rightSeen == null) return -1;
        return rightSeen.compareTo(leftSeen);
      }
      return left.compareTo(right);
    }

    final targets = <PresenceDevice>[];
    for (final user in users.toList()..sort()) {
      final devices = [
        for (final device in verified[user] ?? const <String>[])
          if (device.toLowerCase() != currentDeviceId.toLowerCase())
            device.toLowerCase(),
      ]..sort(byNewestSeen);
      for (final device in devices.take(perUser)) {
        targets.add(PresenceDevice(userId: user, deviceId: device));
      }
    }
    return targets;
  }

  /// The newest of when [device] was last heard in this process and its
  /// stored last seen (D8), in milliseconds.
  int? _newestSeen(String device, Map<String, int> lastSeen) {
    final heard = _heardAt[device]?.millisecondsSinceEpoch;
    final seen = lastSeen[device];
    if (heard == null || seen == null) {
      return heard ?? seen;
    }
    return max(heard, seen);
  }

  bool _isLive(String key, DateTime now) {
    final heard = _heardAt[key];
    return heard != null && now.difference(heard) < liveWindow;
  }

  // ---------------------------------------------------------------------
  // Typing out.

  Future<void> _onActivity(ChatActivity event) async {
    switch (event) {
      case ChatTextEdited(:final conversationId, :final hasText):
        // Off, typing goes nowhere: it would tell its receiver that this
        // phone is online (D9).
        if (!_foreground || !_sharing) {
          return;
        }
        final typing = _typingOut[conversationId] ??= _TypingOut();
        typing.idle?.cancel();
        if (hasText) {
          typing
            ..wanted = true
            ..idle = timers.start(
              typingIdle,
              () => _serially(() async {
                typing
                  ..wanted = false
                  ..idle = null;
                await _flushTyping(conversationId);
              }),
            );
        } else {
          typing
            ..wanted = false
            ..idle = null;
        }
        await _flushTyping(conversationId);
      case ChatTextSent(:final conversationId):
        final typing = _typingOut[conversationId];
        if (typing == null) {
          return;
        }
        typing
          ..wanted = false
          ..idle?.cancel()
          ..idle = null;
        await _flushTyping(conversationId);
      case ChatMessageArrived(:final conversationId, :final senderDeviceId):
        _hideTypingOf(
          senderDeviceId.toLowerCase(),
          clock.now(),
          only: conversationId,
        );
    }
  }

  /// Sends the typing state [conversationId] wants, if it is not the state
  /// last sent: now, or at the end of the [typingPace] since the last frame.
  /// A change undone inside the pace sends nothing.
  Future<void> _flushTyping(String conversationId) async {
    final typing = _typingOut[conversationId];
    if (typing == null || typing.wanted == typing.sent) {
      return;
    }
    final now = clock.now();
    if (!typing.paceAllows(now)) {
      typing.pace ??= timers.start(
        typing.lastSentAt!.add(typingPace).difference(now),
        () => _serially(() async {
          typing.pace = null;
          await _flushTyping(conversationId);
        }),
      );
      return;
    }
    await _sendTyping(conversationId, active: typing.wanted);
  }

  Future<void> _sendTyping(
    String conversationId, {
    required bool active,
  }) async {
    final typing = _typingOut[conversationId];
    if (typing == null) {
      return;
    }
    final now = clock.now();
    typing
      ..sent = active
      ..lastSentAt = now
      ..repeat?.cancel()
      ..repeat = null;
    if (active) {
      typing.repeat = timers.start(
        typingRepeat,
        () => _serially(() async {
          typing.repeat = null;
          if (typing.wanted && typing.sent && _foreground) {
            await _sendTyping(conversationId, active: true);
          }
        }),
      );
    }
    final targets = _typingTargets(conversationId, now);
    if (targets.isEmpty) {
      return;
    }
    await _send(
      PresenceTyping(
        conversationId: _conversationBytes(conversationId),
        active: active,
        ttlMs: active ? typingTtl.inMilliseconds : null,
      ),
      live: targets,
    );
  }

  /// The devices holding a live lease on [conversationId] (D3).
  List<PresenceDevice> _typingTargets(String conversationId, DateTime now) {
    final watchers = _leases[conversationId];
    if (watchers == null) {
      return const [];
    }
    watchers.removeWhere((_, lease) => !lease.expiresAt.isAfter(now));
    return [
      for (final MapEntry(:key, :value) in watchers.entries)
        if (!_gone.contains(key)) value.device,
    ];
  }

  // ---------------------------------------------------------------------
  // Sending.

  /// Seals [body] once for every device of [live] that L1 still allows and
  /// every device of [probes] its ledger allows, commits it, and hands one
  /// paced frame for each to the socket. Answers the devices sealed to.
  Future<List<PresenceDevice>> _send(
    PresenceSignalBody body, {
    List<PresenceDevice> live = const [],
    List<PresenceDevice> probes = const [],
  }) async {
    final now = clock.now();
    final own = currentDeviceId.toLowerCase();
    final me = currentUserId.toLowerCase();
    final seen = <String>{};
    final allowedLive = <PresenceDevice>[];
    for (final device in live) {
      if (device.key != own &&
          device.userId.toLowerCase() != me &&
          seen.add(device.key) &&
          (_liveFrames[device.key] ?? 0) < liveFramesBetweenHeard) {
        allowedLive.add(device);
      }
    }
    final allowedProbes = <PresenceDevice>[];
    for (final device in probes) {
      if (device.key != own &&
          device.userId.toLowerCase() != me &&
          seen.add(device.key) &&
          await _ledger.allows(device, now)) {
        allowedProbes.add(device);
      }
    }
    final targets = [...allowedLive, ...allowedProbes];
    if (targets.isEmpty) {
      return const [];
    }
    final payload = _encode(body);
    if (payload == null) {
      return const [];
    }
    final published = buckets.signalBuckets;
    final queued = await router.exclusively(() async {
      var sealed = await sealer.seal(
        payload: payload,
        targets: targets,
        allowedLengths: published,
      );
      if (_isConflict(sealed)) {
        sealed = await sealer.seal(
          payload: payload,
          targets: targets,
          allowedLengths: published,
        );
      }
      if (sealed case FailureResult()) {
        return const <(PresenceDevice, String, Future<void>)>[];
      }
      final outcomes = (sealed as Success<List<PresenceSealOutcome>>).value;
      return [
        for (final outcome in outcomes)
          if (outcome case PresenceSealed(
            :final device,
            :final frame,
          ) when published.contains(frame.length) && targets.contains(device))
            (device, base64.encode(frame), _pacer.acquire()),
      ];
    });
    final sent = <PresenceDevice>[];
    for (final (device, _, _) in queued) {
      sent.add(device);
      if (allowedProbes.contains(device)) {
        await _ledger.recordProbe(device, now);
      } else {
        _liveFrames[device.key] = (_liveFrames[device.key] ?? 0) + 1;
      }
    }
    // In the order the sessions advanced, each when the pacer lets it go.
    _track(() async {
      for (final (device, blob, slot) in queued) {
        await slot;
        await socket.sendSignal(toDeviceId: device.deviceId, blob: blob);
      }
    });
    return sent;
  }

  Uint8List? _encode(PresenceSignalBody body) {
    if (_counter >= PresenceSignalLimits.maximumCounter) {
      _instanceId = _mintInstanceId();
      _counter = 0;
    }
    _counter += 1;
    final encoded = PresenceSignalCodec.encode(
      PresenceSignalMessage(
        header: PresenceSignalHeader(
          senderUserId: protocolUuidBytes(currentUserId),
          senderDeviceId: protocolUuidBytes(currentDeviceId),
          instanceId: _instanceId,
          counter: _counter,
        ),
        body: body,
      ),
    );
    return encoded is Success<Uint8List> ? encoded.value : null;
  }

  // ---------------------------------------------------------------------
  // Plumbing.

  /// Runs [action] after every event taken before it.
  void _serially(Future<void> Function() action) {
    if (!_running) {
      return;
    }
    _turn = _turn
        .then((_) => _running ? action() : null)
        .then<void>((_) {}, onError: (Object _) {});
  }

  void _track(Future<void> Function() action) {
    late final Future<void> future;
    future = action()
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _inFlight.remove(future));
    _inFlight.add(future);
  }

  PresenceTimer _periodic(Duration every, Future<void> Function() action) {
    final periodic = _Periodic();
    void arm() {
      periodic.current = timers.start(every, () {
        if (periodic.cancelled) {
          return;
        }
        arm();
        _serially(action);
      });
    }

    arm();
    return periodic;
  }

  Uint8List _mintInstanceId() => Uint8List.fromList([
    for (var index = 0; index < PresenceSignalLimits.instanceIdBytes; index++)
      _random.nextInt(256),
  ]);

  static Uint8List _conversationBytes(String conversationId) =>
      Uint8List.fromList([
        for (var index = 0; index < conversationId.length; index += 2)
          int.parse(conversationId.substring(index, index + 2), radix: 16),
      ]);

  bool _isFromSender(PresenceSignalHeader header, PresenceDevice sender) {
    try {
      return _same(header.senderUserId, protocolUuidBytes(sender.userId)) &&
          _same(header.senderDeviceId, protocolUuidBytes(sender.deviceId));
    } on FormatException {
      return false;
    }
  }

  static bool _isConflict(Result<Object?> result) =>
      result is FailureResult<Object?> &&
      result.failure is ValidationFailure &&
      (result.failure as ValidationFailure).kind ==
          ValidationFailureKind.conflict;
}

final class _Lease {
  const _Lease(this.device, this.expiresAt);

  final PresenceDevice device;
  final DateTime expiresAt;
}

final class _ShownTyping {
  _ShownTyping(this.userId);

  final String userId;
  final conversations = <String>{};
}

/// The typing this phone sends in one conversation.
final class _TypingOut {
  /// Whether the composer is being typed into: edited in the last
  /// [PresenceChannel.typingIdle] and not empty, sent, cleared or left since.
  var wanted = false;

  /// The state the last frame carried.
  var sent = false;
  DateTime? lastSentAt;
  PresenceTimer? idle;
  PresenceTimer? pace;
  PresenceTimer? repeat;

  bool paceAllows(DateTime now) {
    final last = lastSentAt;
    return last == null || now.difference(last) >= PresenceChannel.typingPace;
  }

  void cancelTimers() {
    idle?.cancel();
    pace?.cancel();
    repeat?.cancel();
    idle = pace = repeat = null;
  }
}

/// The watch of the conversation on screen.
final class _Watch {
  _Watch(this.conversationId);

  final String conversationId;
  PresenceTimer? timer;
  var targets = const <PresenceDevice>[];

  /// When each device was last sent a live watch, and last answered.
  final renewedAt = <String, DateTime>{};
  final answeredAt = <String, DateTime>{};

  /// A device that did not answer a renewal within
  /// [PresenceChannel.renewalAnswerWindow] is not renewed again; it is probed
  /// instead (D4).
  bool renewalUnanswered(PresenceDevice device, DateTime now) {
    final renewed = renewedAt[device.key];
    if (renewed == null ||
        now.difference(renewed) < PresenceChannel.renewalAnswerWindow) {
      return false;
    }
    final answered = answeredAt[device.key];
    return answered == null || answered.isBefore(renewed);
  }
}

final class _Periodic implements PresenceTimer {
  PresenceTimer? current;
  var cancelled = false;

  @override
  void cancel() {
    cancelled = true;
    current?.cancel();
  }
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
