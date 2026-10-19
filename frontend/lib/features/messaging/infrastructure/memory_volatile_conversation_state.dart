import 'dart:async';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/features/messaging/application/ports/conversation_ports.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/shared/infrastructure/time/system_time_source.dart';

final class MemoryVolatileConversationState
    implements VolatileConversationStatePort {
  MemoryVolatileConversationState({this.clock = const SystemTimeSource()});

  static const Duration maximumTypingLifetime = Duration(seconds: 15);
  static const int maximumTypingEntries = 256;
  static const int maximumPresenceDevices = 500;

  /// What expiry is measured against.
  final TimeSource clock;
  final Map<String, TypingProjection> _typing = {};
  final Map<String, Set<String>> _presence = {};
  final StreamController<void> _changes = StreamController.broadcast();
  Timer? _expiryTimer;

  @override
  Stream<List<TypingProjection>> watchTyping(String conversationId) async* {
    yield _typingFor(conversationId, _now());
    yield* _changes.stream.map((_) => _typingFor(conversationId, _now()));
  }

  @override
  Stream<PresenceProjection> watchPresence(String userId) async* {
    yield _presenceFor(userId);
    yield* _changes.stream.map((_) => _presenceFor(userId));
  }

  @override
  void applyTyping({
    required String conversationId,
    required String userId,
    required String deviceId,
    required bool isTyping,
    required DateTime expiresAt,
    required DateTime authenticatedAt,
  }) {
    final authenticated = authenticatedAt.toUtc();
    final expires = expiresAt.toUtc();
    final key = '$conversationId|${deviceId.toLowerCase()}';
    if (!isTyping || !expires.isAfter(authenticated)) {
      _typing.remove(key);
      _emit();
      return;
    }
    final maximum = authenticated.add(maximumTypingLifetime);
    if (expires.isAfter(maximum)) {
      return;
    }
    _removeExpired(authenticated);
    if (_typing.length >= maximumTypingEntries && !_typing.containsKey(key)) {
      return;
    }
    _typing[key] = TypingProjection(
      conversationId: conversationId,
      userId: userId.toLowerCase(),
      deviceId: deviceId.toLowerCase(),
      expiresAt: expires,
    );
    _scheduleExpiry();
    _emit();
  }

  @override
  void applyPresence({
    required String userId,
    required String deviceId,
    required bool socketOnline,
  }) {
    final user = userId.toLowerCase();
    final device = deviceId.toLowerCase();
    final online = _presence.putIfAbsent(user, () => <String>{});
    if (socketOnline) {
      final total = _presence.values.fold<int>(
        0,
        (sum, devices) => sum + devices.length,
      );
      if (total >= maximumPresenceDevices && !online.contains(device)) {
        return;
      }
      online.add(device);
    } else {
      online.remove(device);
      if (online.isEmpty) {
        _presence.remove(user);
      }
    }
    _emit();
  }

  @override
  void clearDisconnected() {
    _typing.clear();
    _presence.clear();
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _emit();
  }

  void dispose() {
    _expiryTimer?.cancel();
    unawaited(_changes.close());
  }

  List<TypingProjection> _typingFor(String conversationId, DateTime now) {
    _removeExpired(now);
    final values =
        _typing.values
            .where((value) => value.conversationId == conversationId)
            .toList()
          ..sort((left, right) {
            final user = left.userId.compareTo(right.userId);
            return user != 0 ? user : left.deviceId.compareTo(right.deviceId);
          });
    return List.unmodifiable(values);
  }

  PresenceProjection _presenceFor(String userId) => PresenceProjection(
    userId: userId.toLowerCase(),
    onlineDeviceCount: _presence[userId.toLowerCase()]?.length ?? 0,
  );

  void _removeExpired(DateTime now) {
    _typing.removeWhere((_, value) => !value.expiresAt.isAfter(now));
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    if (_typing.isEmpty) {
      return;
    }
    final earliest = _typing.values
        .map((value) => value.expiresAt)
        .reduce((left, right) => left.isBefore(right) ? left : right);
    final delay = earliest.difference(_now());
    _expiryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _removeExpired(_now());
      _scheduleExpiry();
      _emit();
    });
  }

  DateTime _now() => clock.now().toUtc();

  void _emit() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}
