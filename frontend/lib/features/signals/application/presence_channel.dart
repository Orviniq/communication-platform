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
/// watcher, and when that watcher is a device of the watch on screen it
/// watches back at once (ADR-100 W1); typing goes only to devices holding a
/// live lease, never to this account's own, and only through a seal that
/// refuses an unverified account and a device with no session (T4). A chat
/// that nobody watches costs nothing.
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
/// **The socket.** Presence follows it. While it is closed no frame is sealed:
/// a frame that is not carried is a dead skipped key on its target for good,
/// and the seal moves the ratchet whether or not the socket takes the frame.
/// When it opens, the watch round of the chat on screen runs at once and each
/// typing session still wanted sends its start.
///
/// **Leaving** (D5, ADR-101 G1 to G4). The app leaving the foreground, seen by
/// the visibility or by [farewell] before the socket closes, whichever comes
/// first, sends one `gone` to every device with a live lease in either
/// direction, and nothing else. It waits for no event of the queue and reads
/// no peer: it seals with the answers the peer cache holds, however old, by
/// [goodbyeSealer]. Until the app is in the foreground again an event that
/// waits in the queue returns without work, and nothing else is sealed.
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
    required this.goodbyeSealer,
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

  /// Only the stop that follows a cleared composer waits this long after the
  /// last frame, so a change undone inside it sends nothing. A start never
  /// waits.
  static const typingPace = Duration(seconds: 5);

  /// A start less than [typingRaceWindow] after a send is refreshed
  /// [typingFirstRefresh] later instead of [typingRepeat]: the message it
  /// follows may reach the receiver after this start, and ends the line it
  /// opened (ADR-098 D3).
  static const typingRaceWindow = Duration(seconds: 5);
  static const typingFirstRefresh = Duration(seconds: 3);

  /// After a start that no frame carried, the next try waits this long.
  static const typingRetry = Duration(seconds: 1);

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

  /// The seal of the goodbye: [sealer]'s, over a view of the peer cache that
  /// serves the last answer that verified each account, however old, and
  /// never reads (ADR-101 G2).
  final PresenceSealPort goodbyeSealer;
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

  /// Whether the app left the foreground and the channel has not followed it
  /// back yet (ADR-101 G1, G4). Set at once by the first path that sees the
  /// departure, before anything is queued.
  var _departing = false;

  /// The goodbye of the departure under way. The second path that sees the
  /// same departure waits for it, and sends no `gone` of its own (G1).
  Future<void>? _goodbye;

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
            .listen((signal) => _unlessDeparting(() => _receive(signal))),
      )
      ..add(socket.opens.listen((_) => _unlessDeparting(_onSocketOpened)))
      ..add(visibility.changes.listen((_) => _onVisibilityChanged()))
      ..add(
        activity.listen((event) => _unlessDeparting(() => _onActivity(event))),
      )
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

  /// Says goodbye before the socket closes (D5, ADR-101 G1 to G3): `gone` to
  /// every device with a live lease in either direction, then nothing more
  /// until the app is in the foreground again. It waits for no event of the
  /// queue and reads no peer, and when the visibility already started this
  /// departure it sends nothing more. Completes once that `gone`, and every
  /// frame sealed before it, has gone to the socket.
  Future<void> farewell() => _depart();

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

  /// The socket closed: every typing state shown ends with it. Leases and
  /// watches stay and end by time. Nothing is sealed while the socket is
  /// closed, and the handshake runs when it opens again.
  void socketClosed() => _serially(() async => _clearShownTyping());

  /// A connection became ready: the handshake this phone could not send while
  /// it had none. The watch round of the chat on screen runs at once, and each
  /// typing session starts over: what an earlier connection carried is not
  /// known to have reached anybody, so a session that is still wanted sends its
  /// start now.
  Future<void> _onSocketOpened() async {
    if (!_foreground || !_sharing) {
      return;
    }
    final watch = _watch;
    if (watch != null) {
      await _watchRound(watch);
    }
    for (final MapEntry(key: conversation, value: typing)
        in _typingOut.entries.toList()) {
      typing
        ..sent = false
        ..failedAt = null;
      if (typing.wanted) {
        await _sendTyping(conversation, active: true, start: true);
      }
    }
  }

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
    // A frame from a device lifts L1 for it: a start held back may leave.
    for (final typing in _typingOut.values) {
      typing.failedAt = null;
    }
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
        // A device that watches is back, whatever it said before.
        _gone.remove(sender.key);
        await _send(
          PresenceHere(
            conversationId: conversationId,
            typing: _typingOut[conversation]?.wanted ?? false,
          ),
          live: [sender],
        );
        await _watchBack(conversation, sender);
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
        // A device that left forgot our watch: the one we sent it no longer
        // counts, and its return is answered with a new one (W1).
        _watch?.renewedAt.remove(sender.key);
        _watch?.answeredAt.remove(sender.key);
        _hideTypingOf(sender.key, now);
        await status.gone(
          sender,
          forget: reason == PresenceGoneReason.statusTurnedOff,
        );
    }
  }

  /// The reciprocal watch (ADR-100 W1): a watch gives a lease to the device
  /// that sent it, not to the phone that answers. So the phone that shows
  /// [conversation] and has just accepted a watch of it from a device it
  /// watches sends that device a watch of its own, at once, after the `here`.
  /// Otherwise the device could not type to this phone until the next renewal,
  /// up to [watchRenewal] later.
  ///
  /// None goes when this phone sent that device a live watch in the last
  /// [liveWindow]: the device holds a lease for it still, and two phones that
  /// both renew every [watchRenewal] would answer each other forever. It is a
  /// live frame (L1 counts it, no probe token is spent) because the device has
  /// just spoken, and it leaves the renewal timer where it is (W2). Nothing goes in the background, with the switch off, for a chat that
  /// is not on screen or to a device that the watch does not target (W3).
  Future<void> _watchBack(String conversation, PresenceDevice sender) async {
    final watch = _watch;
    if (watch == null ||
        watch.conversationId != conversation ||
        !_foreground ||
        !_sharing ||
        !watch.targets.any((target) => target.key == sender.key)) {
      return;
    }
    final renewed = watch.renewedAt[sender.key];
    if (renewed != null && clock.now().difference(renewed) < liveWindow) {
      return;
    }
    final now = clock.now();
    final sent = await _send(
      PresenceWatch(
        conversationId: _conversationBytes(conversation),
        leaseMs: PresenceSignalLimits.watchLeaseMs,
      ),
      live: [sender],
    );
    if (sent.isNotEmpty && identical(_watch, watch)) {
      watch.renewedAt[sender.key] = now;
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
    // An answer under 60 s old accepts at once; one that does not name the
    // sender's device is read again first, so a new device is not refused on
    // an old answer.
    final verified = await peers.verifiedDevices(
      {sender.userId},
      including: {sender},
    );
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

  /// The app leaving the foreground starts the goodbye at once, before the
  /// queue; the queue then follows the visibility as for any change.
  void _onVisibilityChanged() {
    if (!visibility.isForeground) {
      unawaited(_depart());
    }
    _serially(_followVisibility);
  }

  /// Starts the departure that the visibility or [farewell] saw first (G1):
  /// marks it, takes the live lease holders of this moment without an
  /// `await`, and seals `gone` to them through [_sayGoodbye]. The clean-up of
  /// the leases, the watch and the typing runs in the queue afterward. A
  /// second start of the same departure gets the same goodbye.
  Future<void> _depart() {
    if (_departing) {
      return _goodbye ?? Future<void>.value();
    }
    if (!_running || !_foreground) {
      return Future<void>.value();
    }
    _departing = true;
    final goodbye = _goodbye = _sayGoodbye(_liveLeaseHolders(clock.now()));
    _serially(() async {
      if (_foreground) {
        _leaveForeground();
        _foreground = false;
        _closeWatch();
      }
    });
    return goodbye;
  }

  /// Seals `gone` to [holders] with the answers the peer cache holds, and
  /// waits until it, and every frame sealed before it, has gone to the
  /// socket. It sends no typing stop: the `gone` ends the line at its
  /// receiver (G3). Best effort: the online window is its fallback.
  Future<void> _sayGoodbye(List<PresenceDevice> holders) async {
    if (_sharing && holders.isNotEmpty) {
      await _send(
        const PresenceGone(PresenceGoneReason.leftForeground),
        live: holders,
        goodbye: true,
      ).then<void>((_) {}, onError: (Object _) {});
    }
    await Future.wait(List.of(_inFlight));
  }

  Future<void> _followVisibility() async {
    final foreground = visibility.isForeground;
    if (foreground && _departing) {
      // Back in the foreground: the departure is over, and the queue handles
      // events again (G4).
      _departing = false;
      _goodbye = null;
    }
    // Off, nothing is watched (D9).
    final shown = foreground && _sharing
        ? visibility.visibleConversationId
        : null;
    if (_foreground && !foreground) {
      _leaveForeground();
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

  /// The clean-up of a departure, in the queue after the goodbye (G1). Typing
  /// ends and sends no stop: the `gone` ended the line at its receiver (G3).
  /// Every lease ends, since a device in the background answers nothing, and
  /// every typing state shown ends.
  void _leaveForeground() {
    for (final typing in _typingOut.values) {
      typing
        ..wanted = false
        ..sent = false
        ..cancelTimers();
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
              () => _unlessDeparting(() async {
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
        // Only the stop of a cleared composer is paced.
        await _flushTyping(conversationId, paced: !hasText);
      case ChatTextSent(:final conversationId):
        // A send ends the typing session and sends no frame: the message ends
        // the line at the receiver (ADR-098 D3). The time of the send is kept
        // for the start of the next message (N5).
        final typing =
            _typingOut[conversationId] ??
            (_foreground && _sharing
                ? (_typingOut[conversationId] = _TypingOut())
                : null);
        if (typing == null) {
          return;
        }
        typing
          ..cancelTimers()
          ..wanted = false
          ..sent = false
          ..lastSentAt = null
          ..failedAt = null
          ..sendAt = clock.now();
      case ChatMessageArrived(:final conversationId, :final senderDeviceId):
        _hideTypingOf(
          senderDeviceId.toLowerCase(),
          clock.now(),
          only: conversationId,
        );
    }
  }

  /// Sends the typing state [conversationId] wants, if it is not the state
  /// last sent. A start leaves at once. A stop leaves at once too, unless
  /// [paced]: the stop of a cleared composer waits for the end of the
  /// [typingPace] since the last frame, and a change undone inside it sends
  /// nothing. A start no frame carried is tried again by a later edit, at most
  /// once in [typingRetry].
  Future<void> _flushTyping(String conversationId, {bool paced = false}) async {
    final typing = _typingOut[conversationId];
    if (typing == null || typing.wanted == typing.sent) {
      return;
    }
    final now = clock.now();
    if (typing.wanted) {
      if (!typing.retryAllowed(now)) {
        return;
      }
      await _sendTyping(conversationId, active: true, start: true);
      return;
    }
    if (paced && !typing.paceAllows(now)) {
      typing.pace ??= timers.start(
        typing.lastSentAt!.add(typingPace).difference(now),
        () => _unlessDeparting(() async {
          typing.pace = null;
          await _flushTyping(conversationId, paced: true);
        }),
      );
      return;
    }
    await _sendTyping(conversationId, active: false);
  }

  /// Sends one typing frame to the devices holding a lease. The state counts
  /// as sent only when a frame was queued: with no lease, past L1 or with a
  /// refused seal it does not, and the next edit tries again. [start] is the
  /// first frame of a session, not a repeat.
  Future<void> _sendTyping(
    String conversationId, {
    required bool active,
    bool start = false,
  }) async {
    final typing = _typingOut[conversationId];
    if (typing == null) {
      return;
    }
    final now = clock.now();
    typing
      ..repeat?.cancel()
      ..repeat = null
      ..pace?.cancel()
      ..pace = null;
    final targets = _typingTargets(conversationId, now);
    final queued =
        targets.isNotEmpty &&
        (await _send(
          PresenceTyping(
            conversationId: _conversationBytes(conversationId),
            active: active,
            ttlMs: active ? typingTtl.inMilliseconds : null,
          ),
          live: targets,
        )).isNotEmpty;
    if (queued) {
      typing.lastSentAt = now;
    }
    if (!active) {
      typing.sent = false;
      return;
    }
    typing.sent = queued;
    if (!queued) {
      typing.failedAt = now;
      return;
    }
    typing.repeat = timers.start(
      start && typing.followsSend(now) ? typingFirstRefresh : typingRepeat,
      () => _unlessDeparting(() async {
        typing.repeat = null;
        if (typing.wanted && typing.sent && _foreground) {
          await _sendTyping(conversationId, active: true);
        }
      }),
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
  ///
  /// While the socket is closed it seals nothing (K3): a frame that is sealed
  /// and never written advanced the pairwise session of its target all the
  /// same, and a dropped frame leaves a dead skipped key there for good. A
  /// frame that is not sealed spends no probe token, adds no L1 count and moves
  /// no ratchet. The socket is asked again inside the router lock, because the
  /// wait for that lock is long enough for the socket to close.
  ///
  /// The accounts of the targets are resolved before the router lock, never
  /// inside it: the lock holds off every open and every voice seal, and a peer
  /// read is a round trip. A target its account's answer does not name is
  /// sealed nothing, as the seal would refuse it; the seal then finds each
  /// answer it needs in the cache.
  ///
  /// The [goodbye] reads no peer at all (ADR-101 G2): its targets are named by
  /// the answer the cache holds, however old, a target with none is skipped,
  /// and [goodbyeSealer] seals it from the same answers. During a departure
  /// nothing but the goodbye is sealed (G4).
  Future<List<PresenceDevice>> _send(
    PresenceSignalBody body, {
    List<PresenceDevice> live = const [],
    List<PresenceDevice> probes = const [],
    bool goodbye = false,
  }) async {
    if (!socket.isOpen || (_departing && !goodbye)) {
      return const [];
    }
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
    final candidates = [...allowedLive, ...allowedProbes];
    if (candidates.isEmpty) {
      return const [];
    }
    final users = {
      for (final device in candidates) device.userId.toLowerCase(),
    };
    final verified = goodbye
        ? {for (final user in users) user: ?await peers.peek(user)}
        : await peers.verifiedDevices(users, including: candidates.toSet());
    final targets = [
      for (final device in candidates)
        if (verified[device.userId.toLowerCase()]?.contains(device.key) ??
            false)
          device,
    ];
    if (targets.isEmpty) {
      return const [];
    }
    final payload = _encode(body);
    if (payload == null) {
      return const [];
    }
    final published = buckets.signalBuckets;
    final seal = goodbye ? goodbyeSealer : sealer;
    final queued = await router.exclusively(() async {
      if (!socket.isOpen || (_departing && !goodbye)) {
        return const <(PresenceDevice, String, Future<void>)>[];
      }
      var sealed = await seal.seal(
        payload: payload,
        targets: targets,
        allowedLengths: published,
      );
      if (_isConflict(sealed)) {
        sealed = await seal.seal(
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

  /// [_serially], for an event that the app leaving the foreground makes
  /// moot: when it starts during a departure it returns without work (G4).
  void _unlessDeparting(Future<void> Function() action) => _serially(() async {
    if (!_departing) {
      await action();
    }
  });

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
        _unlessDeparting(action);
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

  /// Whether the last frame that left carried a start and no stop since:
  /// false until a frame was queued, and false again after a stop and after a
  /// send.
  var sent = false;

  /// When the last frame of this session was queued.
  DateTime? lastSentAt;

  /// When a start was last tried and no frame was queued, and when the last
  /// message of this conversation was sent.
  DateTime? failedAt;
  DateTime? sendAt;
  PresenceTimer? idle;
  PresenceTimer? pace;
  PresenceTimer? repeat;

  bool paceAllows(DateTime now) {
    final last = lastSentAt;
    return last == null || now.difference(last) >= PresenceChannel.typingPace;
  }

  bool retryAllowed(DateTime now) {
    final failed = failedAt;
    return failed == null ||
        now.difference(failed) >= PresenceChannel.typingRetry;
  }

  bool followsSend(DateTime now) {
    final sent = sendAt;
    return sent != null &&
        now.difference(sent) < PresenceChannel.typingRaceWindow;
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
