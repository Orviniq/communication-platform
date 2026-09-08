sealed class RealtimeEvent {
  const RealtimeEvent();
}

final class RealtimeEnvelope extends RealtimeEvent {
  const RealtimeEnvelope({
    required this.id,
    required this.sequence,
    required this.blob,
  });

  final String id;
  final int sequence;
  final String blob;
}

final class RealtimeSignal extends RealtimeEvent {
  const RealtimeSignal(this.blob);

  final String blob;
}

/// Unknown future event types are retained as unsupported transport events.
final class UnsupportedRealtimeEvent extends RealtimeEvent {
  const UnsupportedRealtimeEvent();
}

enum RealtimeCloseReason {
  authenticationFailed,
  revoked,
  protocolViolation,
  originRejected,
  normal,
  transportLost,
}

enum ReconnectAction {
  refreshThenReconnectOnce,
  reconnectWithBackoff,
  stopRevoked,
  openCircuit,
  stopOriginRejected,
  none,
}
