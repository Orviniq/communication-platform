import 'dart:async';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/signals/application/ports/presence_ports.dart';
import 'package:communication_platform/features/signals/application/presence_share_setting.dart';
import 'package:communication_platform/features/signals/domain/peer_status_model.dart';

/// The online state of each peer device and the last seen of each peer, as
/// this phone saw them (ADR-098 D4, D8, D9).
///
/// **Online.** A device is online from any presence frame the channel
/// accepted from it (`watch`, `here` or `typing`) until [onlineWindow] after
/// the latest one, or until its `gone`. An account is online while one of its
/// devices is. A group counts the members with an online device; only a
/// verified account's frame is ever accepted, so the count is a lower bound.
///
/// **The last seen** of a device is this phone's clock at the latest presence
/// frame it accepted from that device, a `gone` included. It is written when
/// the device's online state ends, and at most once every
/// [lastSeenWriteInterval] while it lasts, so a process that dies keeps a
/// time. A durable message moves nothing, so a peer whose status is off never
/// gains a time. Nothing of it leaves the phone.
///
/// **The switch.** While "Show my online status" is off, nothing is taken in
/// and nothing is shown. Turning it off forgets every online state and
/// deletes every stored last seen.
///
/// Nothing is logged.
final class PresenceStatusBook {
  PresenceStatusBook({
    required this.store,
    required this.sharing,
    required this.conversations,
    required this.clock,
    required this.timers,
  }) {
    _sharingChanges = sharing.changes.listen(
      (on) => _serially(() => _onSharingChanged(on)),
    );
  }

  static const onlineWindow = Duration(seconds: 40);
  static const lastSeenWriteInterval = Duration(minutes: 1);

  /// The largest group that shows an online count, as the largest that is
  /// watched (D4).
  static const maximumGroupMembers = 32;

  final PresenceLastSeenPort store;
  final PresenceShareSetting sharing;
  final PresenceConversationsPort conversations;
  final TimeSource clock;
  final PresenceTimerPort timers;

  final _online = <String, _OnlineDevice>{};
  final _changes = StreamController<void>.broadcast();
  late final StreamSubscription<bool> _sharingChanges;
  PresenceTimer? _expiry;
  Future<void> _turn = Future<void>.value();
  var _disposed = false;

  /// An accepted `watch`, `here` or `typing` from [device].
  Future<void> heard(PresenceDevice device) {
    final at = clock.now();
    return _serially(() async {
      if (!await sharing.read()) {
        return;
      }
      final online = _online[device.key];
      final entry = online ?? _OnlineDevice(device);
      entry.lastFrameAt = at;
      _online[device.key] = entry;
      final written = entry.writtenAt;
      if (written == null || !at.isBefore(written.add(lastSeenWriteInterval))) {
        entry.writtenAt = at;
        await store.writeLastSeen(device, at.millisecondsSinceEpoch);
      }
      _armExpiry();
      if (online == null) {
        _emit();
      }
    });
  }

  /// An accepted `gone` from [device]: its online state ends at once. A
  /// `gone` because the sender turned its status off deletes its last seen
  /// ([forget]); any other is its last seen.
  Future<void> gone(PresenceDevice device, {required bool forget}) {
    final at = clock.now();
    return _serially(() async {
      if (!await sharing.read()) {
        return;
      }
      _online.remove(device.key);
      if (forget) {
        await store.forgetLastSeen(device);
      } else {
        await store.writeLastSeen(device, at.millisecondsSinceEpoch);
      }
      _armExpiry();
      _emit();
    });
  }

  /// Whether [deviceKey] is online now.
  bool isOnline(String deviceKey) {
    final online = _online[deviceKey];
    return online != null && _isLive(online, clock.now());
  }

  /// When each device of [userIds] was last seen, in milliseconds by device
  /// key: now for one that is online, else its stored last seen.
  Future<Map<String, int>> lastSeenByDevice(Set<String> userIds) async {
    final users = {for (final user in userIds) user.toLowerCase()};
    final seen = <String, int>{};
    final read = await store.readLastSeen(users);
    if (read case Success(value: final rows)) {
      for (final row in rows) {
        seen[row.deviceId.toLowerCase()] = row.lastSeenMs;
      }
    }
    final now = clock.now();
    for (final online in _online.values) {
      if (users.contains(online.device.userId.toLowerCase()) &&
          _isLive(online, now)) {
        seen[online.device.key] = online.lastFrameAt.millisecondsSinceEpoch;
      }
    }
    return seen;
  }

  /// The status of [userId] now, and on every change.
  Stream<PeerStatus> watchUser(String userId) {
    final user = userId.toLowerCase();
    return _watch(() => _statusOf(user));
  }

  /// How many other members of the group [conversationId] are online now,
  /// and on every change: 0 for a group over [maximumGroupMembers], for any
  /// other conversation, and while the switch is off.
  Stream<int> watchOnlineCount(String conversationId) =>
      _watch(() => _onlineCountIn(conversationId));

  /// Completes once every change taken so far is stored.
  Future<void> get idle async {
    while (true) {
      final turn = _turn;
      await turn;
      if (identical(turn, _turn)) {
        return;
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _expiry?.cancel();
    _expiry = null;
    await _sharingChanges.cancel();
    await idle;
    await _changes.close();
  }

  Future<void> _onSharingChanged(bool on) async {
    if (!on) {
      _online.clear();
      _expiry?.cancel();
      _expiry = null;
      await store.forgetLastSeen();
    }
    _emit();
  }

  Future<PeerStatus> _statusOf(String user) async {
    if (!await sharing.read()) {
      return const PeerStatusNone();
    }
    final now = clock.now();
    if (_online.values.any(
      (online) =>
          online.device.userId.toLowerCase() == user && _isLive(online, now),
    )) {
      return const PeerStatusOnline();
    }
    final read = await store.readLastSeen({user});
    if (read case Success(value: final rows) when rows.isNotEmpty) {
      final newest = rows
          .map((row) => row.lastSeenMs)
          .reduce((left, right) => left > right ? left : right);
      return PeerStatusLastSeen(DateTime.fromMillisecondsSinceEpoch(newest));
    }
    return const PeerStatusNone();
  }

  Future<int> _onlineCountIn(String conversationId) async {
    if (!await sharing.read()) {
      return 0;
    }
    final held = await conversations.read(conversationId);
    if (held is! PresenceGroupConversation ||
        held.activeMemberUserIds.length > maximumGroupMembers) {
      return 0;
    }
    final now = clock.now();
    return {
      for (final online in _online.values)
        if (_isLive(online, now)) online.device.userId.toLowerCase(),
    }.where(held.activeMemberUserIds.contains).length;
  }

  /// Ends the online state of every device silent for [onlineWindow], each
  /// with its latest frame as its last seen.
  Future<void> _expire() async {
    final now = clock.now();
    final ended = [
      for (final online in _online.values)
        if (!_isLive(online, now)) online,
    ];
    for (final online in ended) {
      _online.remove(online.device.key);
      await store.writeLastSeen(
        online.device,
        online.lastFrameAt.millisecondsSinceEpoch,
      );
    }
    _armExpiry();
    if (ended.isNotEmpty) {
      _emit();
    }
  }

  void _armExpiry() {
    _expiry?.cancel();
    _expiry = null;
    if (_online.isEmpty || _disposed) {
      return;
    }
    final earliest = _online.values
        .map((online) => online.lastFrameAt)
        .reduce((left, right) => left.isBefore(right) ? left : right);
    _expiry = timers.start(
      earliest.add(onlineWindow).difference(clock.now()),
      () => _serially(_expire),
    );
  }

  static bool _isLive(_OnlineDevice online, DateTime now) =>
      now.isBefore(online.lastFrameAt.add(onlineWindow));

  Stream<T> _watch<T>(Future<T> Function() read) {
    late final StreamController<T> controller;
    StreamSubscription<void>? changes;
    Future<void> pending = Future<void>.value();
    T? last;
    var emitted = false;
    void refresh() {
      pending = pending
          .then((_) async {
            final value = await read();
            if (controller.isClosed || (emitted && value == last)) {
              return;
            }
            emitted = true;
            last = value;
            controller.add(value);
          })
          .then<void>((_) {}, onError: (Object _) {});
    }

    controller = StreamController<T>(
      onListen: () {
        changes = _changes.stream.listen((_) => refresh());
        refresh();
      },
      onCancel: () async {
        await changes?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<void> _serially(Future<void> Function() action) {
    final run = _turn.then((_) => _disposed ? null : action());
    _turn = run.then<void>((_) {}, onError: (Object _) {});
    return _turn;
  }

  void _emit() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}

final class _OnlineDevice {
  _OnlineDevice(this.device);

  final PresenceDevice device;
  late DateTime lastFrameAt;
  DateTime? writtenAt;
}
