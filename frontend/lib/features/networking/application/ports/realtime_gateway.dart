import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/networking/domain/realtime_event.dart';

abstract interface class RealtimeReconnectHook implements Port {
  Future<void> onDisconnected({
    required RealtimeCloseReason reason,
    required ReconnectAction action,
  });
}

abstract interface class RealtimeGateway implements Port {
  Stream<RealtimeEvent> get events;

  /// Whether a connection that can carry a frame exists now: true once
  /// [connect] succeeded, false after [close] and after the transport is lost.
  bool get isOpen;

  /// Emits once after each successful [connect], when [isOpen] is true. A
  /// failed [connect], and a [connect] that finds the connection open already,
  /// emit nothing. A broadcast stream that outlives every connection.
  Stream<void> get opens;

  Future<Result<void>> connect();

  Future<Result<void>> send(Map<String, Object?> frame);

  void markStableConnection();

  Future<void> close();
}
